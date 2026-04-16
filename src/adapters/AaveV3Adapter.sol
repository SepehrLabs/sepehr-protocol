// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {IAavePool} from "../interfaces/external/IAavePool.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title AaveV3Adapter
/// @notice Protocol adapter for Aave V3 positions. Handles health factor queries,
///         debt repayment, and collateral withdrawal on behalf of users.
contract AaveV3Adapter is IProtocolAdapter {
    using SafeERC20 for IERC20;

    IAavePool public immutable POOL;
    address public immutable ATOKEN;

    constructor(
        address pool,
        address aToken
    ) {
        if (pool == address(0)) revert SepehrErrors.ZeroAddress();
        if (aToken == address(0)) revert SepehrErrors.ZeroAddress();
        POOL = IAavePool(pool);
        ATOKEN = aToken;
    }

    /// @inheritdoc IProtocolAdapter
    function getHealthFactor(
        address user
    ) external view returns (uint256 healthFactor) {
        (,,,,, healthFactor) = POOL.getUserAccountData(user);
    }

    /// @inheritdoc IProtocolAdapter
    function checkDelegation(
        address user
    ) external view returns (bool delegated) {
        return IERC20(ATOKEN).allowance(user, address(this)) > 0;
    }

    /// @inheritdoc IProtocolAdapter
    function repay(
        address user,
        address debtAsset,
        uint256 amount
    ) external {
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        IERC20(debtAsset).forceApprove(address(POOL), amount);
        POOL.repay(debtAsset, amount, 2, user);
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
        IERC20(ATOKEN).safeTransferFrom(user, address(this), amount);
        POOL.withdraw(collateralAsset, amount, recipient);
    }

    /// @inheritdoc IProtocolAdapter
    function getCollateralValueUsd(
        address user
    ) external view returns (uint256 usdValue) {
        (usdValue,,,,,) = POOL.getUserAccountData(user);
    }
}
