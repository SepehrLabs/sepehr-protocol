// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {ICToken, ICompoundOracle, IComptroller} from "../interfaces/external/ICToken.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CompoundV2Adapter
/// @notice Protocol adapter for Compound V2 positions. Uses Comptroller liquidity
///         data for health factor approximation and handles cToken-based repay/withdraw.
/// @dev Audit B16: inherits ReentrancyGuard and gates state-changing functions with
///      nonReentrant. Compound V2's interest-rate-model callbacks have historically been
///      reentrancy vectors when combined with unaudited custom IRMs (as used by some
///      Venus/Moonwell markets). `withdrawCollateral` explicitly calls `accrueInterest()`
///      and reads `exchangeRateStored()` instead of invoking the state-mutating
///      `exchangeRateCurrent()`, so the IRM hook runs exactly once in a controlled spot.
contract CompoundV2Adapter is IProtocolAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IComptroller public immutable COMPTROLLER;
    ICToken public immutable CTOKEN;
    address public immutable core;

    modifier onlyCore() {
        if (msg.sender != core) revert SepehrErrors.NotAuthorized();
        _;
    }

    constructor(
        address comptroller,
        address cToken,
        address _core
    ) {
        if (comptroller == address(0)) revert SepehrErrors.ZeroAddress();
        if (cToken == address(0)) revert SepehrErrors.ZeroAddress();
        if (_core == address(0)) revert SepehrErrors.ZeroAddress();
        COMPTROLLER = IComptroller(comptroller);
        CTOKEN = ICToken(cToken);
        core = _core;
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Compound V2's Comptroller returns (0, 0, 0) for both zero-debt and
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
    /// @dev Audit B20: require an effectively-unlimited approval (>= 2**128) — dust approvals
    ///      would pass `enableProtection` but the trigger's cToken `safeTransferFrom` would
    ///      revert. Wallet "approve max" sets `type(uint256).max`, which is ≫ this threshold.
    function checkDelegation(
        address user
    ) external view returns (bool delegated) {
        return IERC20(address(CTOKEN)).allowance(user, address(this)) >= type(uint128).max;
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Audit B12: Compound V2 `repayBorrowBehalf` caps at the user's outstanding debt; any
    ///      unused `debtAsset` must be swept back to Core so it isn't stranded in the adapter.
    ///      Audit B16: `nonReentrant` defends against IRM-callback reentrancy on non-stock markets.
    function repay(
        address user,
        address debtAsset,
        uint256 amount
    ) external onlyCore nonReentrant {
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        IERC20(debtAsset).forceApprove(address(CTOKEN), amount);
        CTOKEN.repayBorrowBehalf(user, amount);
        uint256 surplus = IERC20(debtAsset).balanceOf(address(this));
        if (surplus > 0) {
            IERC20(debtAsset).safeTransfer(core, surplus);
        }
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Audit B16: drive interest accrual explicitly via `accrueInterest()`, then read the
    ///      stored exchange rate. `exchangeRateCurrent()` is a state-mutating call disguised as a
    ///      getter — routing through it once, mid-withdraw, fans out to an IRM that on custom-IRM
    ///      markets has historically enabled reentrancy. `nonReentrant` is the belt-and-braces guard.
    function withdrawCollateral(
        address user,
        address collateralAsset,
        uint256 amount,
        address recipient
    ) external onlyCore nonReentrant {
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        if (recipient == address(0)) revert SepehrErrors.ZeroAddress();

        CTOKEN.accrueInterest();
        uint256 exchangeRate = CTOKEN.exchangeRateStored();
        uint256 cTokenAmount = (amount * 1e18 + exchangeRate - 1) / exchangeRate;

        IERC20(address(CTOKEN)).safeTransferFrom(user, address(this), cTokenAmount);
        CTOKEN.redeemUnderlying(amount);
        IERC20(collateralAsset).safeTransfer(recipient, amount);
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Sums value across all cTokens the user has entered, not just the
    ///      constructor-wired CTOKEN. Querying a single cToken would let users
    ///      evade tier caps by parking collateral in other Compound markets.
    ///      Compound V2 oracle returns 1e(36 - underlyingDecimals) so
    ///      `underlyingBalance * price / 1e18` yields USD-18 scaled by the
    ///      decimal normalization built into the oracle.
    function getCollateralValueUsd(
        address user
    ) external view returns (uint256 usdValue) {
        ICompoundOracle oracle = ICompoundOracle(COMPTROLLER.oracle());
        address[] memory assets = COMPTROLLER.getAssetsIn(user);
        for (uint256 i = 0; i < assets.length; ++i) {
            ICToken market = ICToken(assets[i]);
            uint256 cTokenBalance = market.balanceOf(user);
            if (cTokenBalance == 0) continue;
            uint256 exchangeRate = market.exchangeRateStored();
            uint256 price = oracle.getUnderlyingPrice(assets[i]);
            uint256 underlyingBalance = cTokenBalance * exchangeRate / 1e18;
            usdValue += underlyingBalance * price / 1e18;
        }
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Returns the stored (not accrued) borrow balance on this cToken; 0 if
    ///      `debtAsset` is not the cToken's underlying.
    function getDebt(
        address user,
        address debtAsset
    ) external view returns (uint256 debt) {
        if (debtAsset != CTOKEN.underlying()) return 0;
        return CTOKEN.borrowBalanceStored(user);
    }
}
