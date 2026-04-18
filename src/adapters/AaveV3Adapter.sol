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
    address public immutable core;

    modifier onlyCore() {
        if (msg.sender != core) revert SepehrErrors.NotAuthorized();
        _;
    }

    constructor(
        address pool,
        address aToken,
        address _core
    ) {
        if (pool == address(0)) revert SepehrErrors.ZeroAddress();
        if (aToken == address(0)) revert SepehrErrors.ZeroAddress();
        if (_core == address(0)) revert SepehrErrors.ZeroAddress();
        POOL = IAavePool(pool);
        ATOKEN = aToken;
        core = _core;
    }

    /// @inheritdoc IProtocolAdapter
    function getHealthFactor(
        address user
    ) external view returns (uint256 healthFactor) {
        (,,,,, healthFactor) = POOL.getUserAccountData(user);
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Audit B20: require an effectively-unlimited approval (>= 2**128) rather than any
    ///      non-zero allowance. A 1-wei dust approval was previously enough to pass
    ///      `enableProtection`, but the subsequent trigger would revert in `safeTransferFrom`
    ///      because the adapter pulls the user's entire aToken share. Standard wallet "approve
    ///      max" sets `type(uint256).max`, which sits far above this threshold.
    function checkDelegation(
        address user
    ) external view returns (bool delegated) {
        return IERC20(ATOKEN).allowance(user, address(this)) >= type(uint128).max;
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Audit B13: try variable-rate debt (mode 2) first; on failure (e.g. user holds only
    ///      stable-rate debt on legacy markets), fall back to stable mode 1. Aave reverts with
    ///      `NO_DEBT_OF_SELECTED_TYPE` if the mode is wrong, which we catch here.
    ///      Audit B12: after the protocol call, sweep any residual `debtAsset` balance back to
    ///      Core. Aave's `repay` caps at the user's outstanding debt; if the keeper submitted a
    ///      slightly stale amount the surplus would otherwise be stranded in this adapter.
    function repay(
        address user,
        address debtAsset,
        uint256 amount
    ) external onlyCore {
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        IERC20(debtAsset).forceApprove(address(POOL), amount);
        try POOL.repay(debtAsset, amount, 2, user) returns (uint256) {}
        catch {
            POOL.repay(debtAsset, amount, 1, user);
        }
        uint256 surplus = IERC20(debtAsset).balanceOf(address(this));
        if (surplus > 0) {
            IERC20(debtAsset).safeTransfer(core, surplus);
        }
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
        IERC20(ATOKEN).safeTransferFrom(user, address(this), amount);
        POOL.withdraw(collateralAsset, amount, recipient);
    }

    /// @inheritdoc IProtocolAdapter
    function getCollateralValueUsd(
        address user
    ) external view returns (uint256 usdValue) {
        (usdValue,,,,,) = POOL.getUserAccountData(user);
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Reads the Aave V3 variable-rate debt token balance for `debtAsset`.
    function getDebt(
        address user,
        address debtAsset
    ) external view returns (uint256 debt) {
        (,,,,,,,,,, address variableDebtToken,,,,) = POOL.getReserveData(debtAsset);
        if (variableDebtToken == address(0)) return 0;
        return IERC20(variableDebtToken).balanceOf(user);
    }
}
