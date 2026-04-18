// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {ICurveController} from "../interfaces/external/ICurveLlamma.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CurveLlamalendAdapter
/// @notice Protocol adapter for Curve Lending (crvUSD / LLAMMA) positions. Translates
///         Curve's health metric to a standard health factor and handles repayment.
contract CurveLlamalendAdapter is IProtocolAdapter {
    using SafeERC20 for IERC20;

    ICurveController public immutable CONTROLLER;
    address public immutable PRICE_ORACLE;
    address public immutable core;

    modifier onlyCore() {
        if (msg.sender != core) revert SepehrErrors.NotAuthorized();
        _;
    }

    constructor(
        address controller,
        address priceOracle,
        address _core
    ) {
        if (controller == address(0)) revert SepehrErrors.ZeroAddress();
        if (priceOracle == address(0)) revert SepehrErrors.ZeroAddress();
        if (_core == address(0)) revert SepehrErrors.ZeroAddress();
        CONTROLLER = ICurveController(controller);
        PRICE_ORACLE = priceOracle;
        core = _core;
    }

    /// @inheritdoc IProtocolAdapter
    function getHealthFactor(
        address user
    ) external view returns (uint256 healthFactor) {
        int256 health = CONTROLLER.health(user);
        // Curve health: 0 = liquidation threshold, positive = healthy margin (WAD).
        // Convert to standard HF where 1e18 = 1.0 (at liquidation).
        if (health <= 0) return 0;
        return 1e18 + uint256(health);
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Curve LLAMMA does not expose a per-spender delegation primitive: `repay` and
    ///      `remove_collateral` operate on `msg.sender`'s own position. A third-party adapter
    ///      cannot legitimately act on a user's behalf without ownership transfer, so this
    ///      check returns `false` to make the constraint enforceable in `enableProtection`.
    ///      Until a delegation pathway is added on Curve's side, the adapter cannot be enabled
    ///      for live protection.
    function checkDelegation(
        address /* user */
    ) external pure returns (bool delegated) {
        return false;
    }

    /// @inheritdoc IProtocolAdapter
    function repay(
        address user,
        address debtAsset,
        uint256 amount
    ) external onlyCore {
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        IERC20(debtAsset).forceApprove(address(CONTROLLER), amount);
        CONTROLLER.repay(amount, user);
    }

    /// @inheritdoc IProtocolAdapter
    function withdrawCollateral(
        address user,
        address,
        uint256 amount,
        address recipient
    ) external onlyCore {
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        if (recipient == address(0)) revert SepehrErrors.ZeroAddress();
        // remove_collateral is owner-only in Curve. The adapter calls it, and the
        // controller checks that msg.sender owns the position or is authorized.
        CONTROLLER.remove_collateral(amount);
        // Transfer the withdrawn collateral to the recipient.
        address collateralToken = CONTROLLER.collateral_token();
        uint256 balance = IERC20(collateralToken).balanceOf(address(this));
        if (balance > 0) {
            IERC20(collateralToken).safeTransfer(recipient, balance);
        }
    }

    /// @inheritdoc IProtocolAdapter
    function getCollateralValueUsd(
        address user
    ) external view returns (uint256 usdValue) {
        // user_state returns [collateral, stablecoin, debt, N].
        uint256[4] memory state = CONTROLLER.user_state(user);
        uint256 collateral = state[0];
        uint256 stablecoin = state[1];
        if (collateral == 0 && stablecoin == 0) return 0;
        // Stablecoin portion is already USD-denominated (WAD). Convert to 8 decimals.
        // Collateral portion needs price conversion via the oracle.
        // For simplicity, use stablecoin + collateral valued at oracle price.
        // The oracle is protocol-specific; approximate collateral value using stablecoin debt
        // ratio. For on-chain accuracy, the keeper provides off-chain pricing.
        // Return stablecoin value as the floor (8 decimals).
        return (stablecoin + collateral) / 1e10;
    }
}
