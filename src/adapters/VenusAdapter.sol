// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {ICToken, ICompoundOracle, IComptroller} from "../interfaces/external/ICToken.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title VenusAdapter
/// @notice Protocol adapter for Venus (BSC). Venus is a Compound V2 fork where
///         Comptroller is replaced with the Venus-branded equivalent and cTokens
///         become vTokens; both implement the same ABI used by Compound V2.
/// @dev Audit B16: Venus has shipped custom interest-rate-model contracts in the past, and
///      `vToken.exchangeRateCurrent()` invokes the IRM as a side effect. Inherit
///      ReentrancyGuard, drive interest accrual explicitly via `accrueInterest()` in a
///      controlled spot, and read `exchangeRateStored()` to keep the IRM hook out of the
///      redeem path.
contract VenusAdapter is IProtocolAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IComptroller public immutable COMPTROLLER;
    ICToken public immutable VTOKEN;
    address public immutable core;

    modifier onlyCore() {
        if (msg.sender != core) revert SepehrErrors.NotAuthorized();
        _;
    }

    constructor(
        address comptroller,
        address vToken,
        address _core
    ) {
        if (comptroller == address(0)) revert SepehrErrors.ZeroAddress();
        if (vToken == address(0)) revert SepehrErrors.ZeroAddress();
        if (_core == address(0)) revert SepehrErrors.ZeroAddress();
        COMPTROLLER = IComptroller(comptroller);
        VTOKEN = ICToken(vToken);
        core = _core;
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Venus Comptroller returns (0, 0, 0) for both zero-debt and
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
    /// @dev Audit B20: see CompoundV2Adapter — require an effectively-unlimited approval
    ///      (>= 2**128) so dust approvals can't pass `enableProtection`.
    function checkDelegation(
        address user
    ) external view returns (bool delegated) {
        return IERC20(address(VTOKEN)).allowance(user, address(this)) >= type(uint128).max;
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Audit B12: sweep residual `debtAsset` back to Core after `repayBorrowBehalf`, which
    ///      caps at the user's outstanding debt and may return surplus to this adapter.
    ///      Audit B16: `nonReentrant` — Venus has shipped custom IRMs historically vulnerable
    ///      to reentrancy when combined with external-call hooks.
    function repay(
        address user,
        address debtAsset,
        uint256 amount
    ) external onlyCore nonReentrant {
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        IERC20(debtAsset).forceApprove(address(VTOKEN), amount);
        VTOKEN.repayBorrowBehalf(user, amount);
        uint256 surplus = IERC20(debtAsset).balanceOf(address(this));
        if (surplus > 0) {
            IERC20(debtAsset).safeTransfer(core, surplus);
        }
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Audit B16: explicit `accrueInterest()` + `exchangeRateStored()` in place of the
    ///      state-mutating `exchangeRateCurrent()`, plus `nonReentrant` to blunt any IRM-callback
    ///      reentrancy vector on non-stock Venus markets.
    function withdrawCollateral(
        address user,
        address collateralAsset,
        uint256 amount,
        address recipient
    ) external onlyCore nonReentrant {
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        if (recipient == address(0)) revert SepehrErrors.ZeroAddress();

        VTOKEN.accrueInterest();
        uint256 exchangeRate = VTOKEN.exchangeRateStored();
        uint256 vTokenAmount = (amount * 1e18 + exchangeRate - 1) / exchangeRate;

        IERC20(address(VTOKEN)).safeTransferFrom(user, address(this), vTokenAmount);
        VTOKEN.redeemUnderlying(amount);
        IERC20(collateralAsset).safeTransfer(recipient, amount);
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Sums value across all vTokens the user has entered, not just the
    ///      constructor-wired VTOKEN. Querying a single vToken would let users
    ///      evade tier caps by parking collateral in other Venus markets.
    function getCollateralValueUsd(
        address user
    ) external view returns (uint256 usdValue) {
        ICompoundOracle oracle = ICompoundOracle(COMPTROLLER.oracle());
        address[] memory assets = COMPTROLLER.getAssetsIn(user);
        for (uint256 i = 0; i < assets.length; ++i) {
            ICToken market = ICToken(assets[i]);
            uint256 vTokenBalance = market.balanceOf(user);
            if (vTokenBalance == 0) continue;
            uint256 exchangeRate = market.exchangeRateStored();
            uint256 price = oracle.getUnderlyingPrice(assets[i]);
            uint256 underlyingBalance = vTokenBalance * exchangeRate / 1e18;
            usdValue += underlyingBalance * price / 1e18;
        }
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Returns the stored (not accrued) borrow balance on this vToken; 0 if
    ///      `debtAsset` is not the vToken's underlying.
    function getDebt(
        address user,
        address debtAsset
    ) external view returns (uint256 debt) {
        if (debtAsset != VTOKEN.underlying()) return 0;
        return VTOKEN.borrowBalanceStored(user);
    }
}
