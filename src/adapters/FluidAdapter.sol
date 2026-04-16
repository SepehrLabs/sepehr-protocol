// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {IFluidVault} from "../interfaces/external/IFluidVault.sol";
import {AegisErrors} from "../libraries/AegisErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title FluidAdapter
/// @notice Protocol adapter for Fluid (Instadapp) vault positions. Handles health factor
///         queries, debt repayment, and collateral withdrawal on behalf of users.
contract FluidAdapter is IProtocolAdapter {
    using SafeERC20 for IERC20;

    IFluidVault public immutable VAULT;

    constructor(
        address vault
    ) {
        if (vault == address(0)) revert AegisErrors.ZeroAddress();
        VAULT = IFluidVault(vault);
    }

    /// @inheritdoc IProtocolAdapter
    function getHealthFactor(
        address user
    ) external view returns (uint256 healthFactor) {
        return VAULT.getHealthFactor(user);
    }

    /// @inheritdoc IProtocolAdapter
    function checkDelegation(
        address user
    ) external view returns (bool delegated) {
        return VAULT.isAuth(user, address(this));
    }

    /// @inheritdoc IProtocolAdapter
    function repay(
        address user,
        address debtAsset,
        uint256 amount
    ) external {
        if (amount == 0) revert AegisErrors.ZeroAmount();
        IERC20(debtAsset).forceApprove(address(VAULT), amount);
        VAULT.repay(user, amount);
    }

    /// @inheritdoc IProtocolAdapter
    function withdrawCollateral(
        address user,
        address,
        uint256 amount,
        address recipient
    ) external {
        if (amount == 0) revert AegisErrors.ZeroAmount();
        if (recipient == address(0)) revert AegisErrors.ZeroAddress();
        // Adapter must be authorized via isAuth for the user's vault position.
        // The vault sends collateral directly to the recipient.
        VAULT.withdraw(amount, recipient);
    }

    /// @inheritdoc IProtocolAdapter
    function getCollateralValueUsd(
        address user
    ) external view returns (uint256 usdValue) {
        return VAULT.getCollateralValueUsd(user);
    }
}
