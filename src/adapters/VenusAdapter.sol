// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {ICToken, ICompoundOracle, IComptroller} from "../interfaces/external/ICToken.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title VenusAdapter
/// @notice Protocol adapter for Venus (BSC). Venus is a Compound V2 fork where
///         Comptroller is replaced with the Venus-branded equivalent and cTokens
///         become vTokens; both implement the same ABI used by Compound V2.
contract VenusAdapter is IProtocolAdapter {
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
        return IERC20(address(VTOKEN)).allowance(user, address(this)) > 0;
    }

    /// @inheritdoc IProtocolAdapter
    function repay(
        address user,
        address debtAsset,
        uint256 amount
    ) external onlyCore {
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        IERC20(debtAsset).forceApprove(address(VTOKEN), amount);
        VTOKEN.repayBorrowBehalf(user, amount);
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

        uint256 exchangeRate = VTOKEN.exchangeRateCurrent();
        uint256 vTokenAmount = (amount * 1e18 + exchangeRate - 1) / exchangeRate;

        IERC20(address(VTOKEN)).safeTransferFrom(user, address(this), vTokenAmount);
        VTOKEN.redeemUnderlying(amount);
        IERC20(collateralAsset).safeTransfer(recipient, amount);
    }

    /// @inheritdoc IProtocolAdapter
    function getCollateralValueUsd(
        address user
    ) external view returns (uint256 usdValue) {
        ICompoundOracle oracle = ICompoundOracle(COMPTROLLER.oracle());
        uint256 price = oracle.getUnderlyingPrice(address(VTOKEN));
        uint256 vTokenBalance = VTOKEN.balanceOf(user);
        uint256 exchangeRate = VTOKEN.exchangeRateStored();
        uint256 underlyingBalance = vTokenBalance * exchangeRate / 1e18;
        usdValue = underlyingBalance * price / 1e18;
    }
}
