// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {ICToken, ICompoundOracle, IComptroller} from "../interfaces/external/ICToken.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MoonwellAdapter
/// @notice Protocol adapter for Moonwell (Base, Optimism). Moonwell is a Compound V2
///         fork with Comptroller and mTokens exposing the same liquidity-accounting
///         and redeem/repay surface as Compound V2.
contract MoonwellAdapter is IProtocolAdapter {
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
        return IERC20(address(MTOKEN)).allowance(user, address(this)) > 0;
    }

    /// @inheritdoc IProtocolAdapter
    function repay(
        address user,
        address debtAsset,
        uint256 amount
    ) external onlyCore {
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        IERC20(debtAsset).forceApprove(address(MTOKEN), amount);
        MTOKEN.repayBorrowBehalf(user, amount);
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

        uint256 exchangeRate = MTOKEN.exchangeRateCurrent();
        uint256 mTokenAmount = (amount * 1e18 + exchangeRate - 1) / exchangeRate;

        IERC20(address(MTOKEN)).safeTransferFrom(user, address(this), mTokenAmount);
        MTOKEN.redeemUnderlying(amount);
        IERC20(collateralAsset).safeTransfer(recipient, amount);
    }

    /// @inheritdoc IProtocolAdapter
    function getCollateralValueUsd(
        address user
    ) external view returns (uint256 usdValue) {
        ICompoundOracle oracle = ICompoundOracle(COMPTROLLER.oracle());
        uint256 price = oracle.getUnderlyingPrice(address(MTOKEN));
        uint256 mTokenBalance = MTOKEN.balanceOf(user);
        uint256 exchangeRate = MTOKEN.exchangeRateStored();
        uint256 underlyingBalance = mTokenBalance * exchangeRate / 1e18;
        usdValue = underlyingBalance * price / 1e18;
    }
}
