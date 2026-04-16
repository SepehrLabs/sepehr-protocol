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

    constructor(
        address comptroller,
        address cToken
    ) {
        if (comptroller == address(0)) revert SepehrErrors.ZeroAddress();
        if (cToken == address(0)) revert SepehrErrors.ZeroAddress();
        COMPTROLLER = IComptroller(comptroller);
        CTOKEN = ICToken(cToken);
    }

    /// @inheritdoc IProtocolAdapter
    function getHealthFactor(
        address user
    ) external view returns (uint256) {
        (, uint256 liquidity, uint256 shortfall) = COMPTROLLER.getAccountLiquidity(user);
        if (shortfall > 0) return 0;
        if (liquidity > 0) return type(uint256).max;
        return 1e18;
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
    ) external {
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
    ) external {
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        if (recipient == address(0)) revert SepehrErrors.ZeroAddress();

        uint256 exchangeRate = CTOKEN.exchangeRateCurrent();
        uint256 cTokenAmount = (amount * 1e18 + exchangeRate - 1) / exchangeRate;

        IERC20(address(CTOKEN)).safeTransferFrom(user, address(this), cTokenAmount);
        CTOKEN.redeemUnderlying(amount);
        IERC20(collateralAsset).safeTransfer(recipient, amount);
    }

    /// @inheritdoc IProtocolAdapter
    function getCollateralValueUsd(
        address user
    ) external view returns (uint256 usdValue) {
        ICompoundOracle oracle = ICompoundOracle(COMPTROLLER.oracle());
        uint256 price = oracle.getUnderlyingPrice(address(CTOKEN));
        uint256 cTokenBalance = CTOKEN.balanceOf(user);
        uint256 exchangeRate = CTOKEN.exchangeRateStored();
        uint256 underlyingBalance = cTokenBalance * exchangeRate / 1e18;
        usdValue = underlyingBalance * price / 1e18;
    }
}
