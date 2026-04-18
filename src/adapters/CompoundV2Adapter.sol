// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {ICToken, ICompoundOracle, IComptroller} from "../interfaces/external/ICToken.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CompoundV2Adapter
/// @notice Protocol adapter for Compound V2 positions. Uses Comptroller liquidity
///         data for health factor approximation and handles cToken-based repay/withdraw.
contract CompoundV2Adapter is IProtocolAdapter {
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
    function checkDelegation(
        address user
    ) external view returns (bool delegated) {
        return IERC20(address(CTOKEN)).allowance(user, address(this)) > 0;
    }

    /// @inheritdoc IProtocolAdapter
    function repay(
        address user,
        address debtAsset,
        uint256 amount
    ) external onlyCore {
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        IERC20(debtAsset).forceApprove(address(CTOKEN), amount);
        CTOKEN.repayBorrowBehalf(user, amount);
    }

    /// @inheritdoc IProtocolAdapter
    function withdrawCollateral(
        address user,
        address collateralAsset,
        uint256 amount,
        address recipient
    ) external onlyCore {
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        if (recipient == address(0)) revert SepehrErrors.ZeroAddress();

        uint256 exchangeRate = CTOKEN.exchangeRateCurrent();
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
