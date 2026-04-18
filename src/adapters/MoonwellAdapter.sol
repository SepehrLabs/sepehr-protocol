// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {ICToken, ICompoundOracle, IComptroller} from "../interfaces/external/ICToken.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title MoonwellAdapter
/// @notice Protocol adapter for Moonwell (Base, Optimism). Moonwell is a Compound V2
///         fork with Comptroller and mTokens exposing the same liquidity-accounting
///         and redeem/repay surface as Compound V2.
/// @dev Audit B16: share the same hardening as the other CompoundV2-fork adapters — inherit
///      ReentrancyGuard, accrue interest explicitly, and read `exchangeRateStored()` to keep
///      the redeem path free of state-mutating getter calls that could fan out to a custom IRM.
contract MoonwellAdapter is IProtocolAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IComptroller public immutable COMPTROLLER;
    ICToken public immutable MTOKEN;
    address public immutable core;

    modifier onlyCore() {
        if (msg.sender != core) revert SepehrErrors.NotAuthorized();
        _;
    }

    constructor(
        address comptroller,
        address mToken,
        address _core
    ) {
        if (comptroller == address(0)) revert SepehrErrors.ZeroAddress();
        if (mToken == address(0)) revert SepehrErrors.ZeroAddress();
        if (_core == address(0)) revert SepehrErrors.ZeroAddress();
        COMPTROLLER = IComptroller(comptroller);
        MTOKEN = ICToken(mToken);
        core = _core;
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Moonwell Comptroller returns (0, 0, 0) for both zero-debt and
    ///      perfectly-balanced accounts. Only the latter is at liquidation
    ///      risk, so we disambiguate by summing borrows across all markets the
    ///      user has entered. Pure zero-debt returns max — otherwise 1e18.
    function getHealthFactor(
        address user
    ) external view returns (uint256) {
        (, uint256 liquidity, uint256 shortfall) = COMPTROLLER.getAccountLiquidity(user);
        if (shortfall > 0) return 0;
        if (liquidity > 0) return type(uint256).max;
        address[] memory assets = COMPTROLLER.getAssetsIn(user);
        for (uint256 i = 0; i < assets.length; ++i) {
            if (ICToken(assets[i]).borrowBalanceStored(user) > 0) return 1e18;
        }
        return type(uint256).max;
    }

    /// @inheritdoc IProtocolAdapter
    function checkDelegation(
        address user
    ) external view returns (bool delegated) {
        return IERC20(address(MTOKEN)).allowance(user, address(this)) > 0;
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Audit B12: sweep residual `debtAsset` back to Core after `repayBorrowBehalf`, which
    ///      caps at the user's outstanding debt and may return surplus to this adapter.
    ///      Audit B16: `nonReentrant` — CompoundV2-fork defense-in-depth against IRM-callback reentrancy.
    function repay(
        address user,
        address debtAsset,
        uint256 amount
    ) external onlyCore nonReentrant {
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        IERC20(debtAsset).forceApprove(address(MTOKEN), amount);
        MTOKEN.repayBorrowBehalf(user, amount);
        uint256 surplus = IERC20(debtAsset).balanceOf(address(this));
        if (surplus > 0) {
            IERC20(debtAsset).safeTransfer(core, surplus);
        }
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Audit B16: explicit `accrueInterest()` + `exchangeRateStored()` in place of
    ///      `exchangeRateCurrent()` (state-mutating), plus `nonReentrant` as belt-and-braces.
    function withdrawCollateral(
        address user,
        address collateralAsset,
        uint256 amount,
        address recipient
    ) external onlyCore nonReentrant {
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        if (recipient == address(0)) revert SepehrErrors.ZeroAddress();

        MTOKEN.accrueInterest();
        uint256 exchangeRate = MTOKEN.exchangeRateStored();
        uint256 mTokenAmount = (amount * 1e18 + exchangeRate - 1) / exchangeRate;

        IERC20(address(MTOKEN)).safeTransferFrom(user, address(this), mTokenAmount);
        MTOKEN.redeemUnderlying(amount);
        IERC20(collateralAsset).safeTransfer(recipient, amount);
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Sums value across all mTokens the user has entered, not just the
    ///      constructor-wired MTOKEN. Querying a single mToken would let users
    ///      evade tier caps by parking collateral in other Moonwell markets.
    function getCollateralValueUsd(
        address user
    ) external view returns (uint256 usdValue) {
        ICompoundOracle oracle = ICompoundOracle(COMPTROLLER.oracle());
        address[] memory assets = COMPTROLLER.getAssetsIn(user);
        for (uint256 i = 0; i < assets.length; ++i) {
            ICToken market = ICToken(assets[i]);
            uint256 mTokenBalance = market.balanceOf(user);
            if (mTokenBalance == 0) continue;
            uint256 exchangeRate = market.exchangeRateStored();
            uint256 price = oracle.getUnderlyingPrice(assets[i]);
            uint256 underlyingBalance = mTokenBalance * exchangeRate / 1e18;
            usdValue += underlyingBalance * price / 1e18;
        }
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Returns the stored (not accrued) borrow balance on this mToken; 0 if
    ///      `debtAsset` is not the mToken's underlying.
    function getDebt(
        address user,
        address debtAsset
    ) external view returns (uint256 debt) {
        if (debtAsset != MTOKEN.underlying()) return 0;
        return MTOKEN.borrowBalanceStored(user);
    }
}
