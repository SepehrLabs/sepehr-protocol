// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {IAavePool} from "../interfaces/external/IAavePool.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title RadiantAdapter
/// @notice Protocol adapter for Radiant Capital (Arbitrum, BSC). Radiant is an
///         Aave-fork cross-chain money market whose LendingPool re-exposes the
///         Aave user-account surface (getUserAccountData, repay, withdraw) and
///         issues rTokens with a standard ERC20 allowance model for delegation.
contract RadiantAdapter is IProtocolAdapter {
    using SafeERC20 for IERC20;

    IAavePool public immutable POOL;
    address public immutable RTOKEN;
    address public immutable core;

    modifier onlyCore() {
        if (msg.sender != core) revert SepehrErrors.NotAuthorized();
        _;
    }

    constructor(
        address pool,
        address rToken,
        address _core
    ) {
        if (pool == address(0)) revert SepehrErrors.ZeroAddress();
        if (rToken == address(0)) revert SepehrErrors.ZeroAddress();
        if (_core == address(0)) revert SepehrErrors.ZeroAddress();
        POOL = IAavePool(pool);
        RTOKEN = rToken;
        core = _core;
    }

    /// @inheritdoc IProtocolAdapter
    function getHealthFactor(
        address user
    ) external view returns (uint256 healthFactor) {
        (,,,,, healthFactor) = POOL.getUserAccountData(user);
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Audit B20: see AaveV3Adapter — require an effectively-unlimited approval
    ///      (>= 2**128) so dust approvals can't pass `enableProtection`.
    function checkDelegation(
        address user
    ) external view returns (bool delegated) {
        return IERC20(RTOKEN).allowance(user, address(this)) >= type(uint128).max;
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Audit B13: variable (mode 2) first, stable (mode 1) fallback.
    ///      Audit B12: sweep any residual `debtAsset` balance back to Core after the protocol call.
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
        IERC20(RTOKEN).safeTransferFrom(user, address(this), amount);
        POOL.withdraw(collateralAsset, amount, recipient);
    }

    /// @inheritdoc IProtocolAdapter
    function getCollateralValueUsd(
        address user
    ) external view returns (uint256 usdValue) {
        (usdValue,,,,,) = POOL.getUserAccountData(user);
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Radiant reuses the Aave V2/V3 reserve layout; reads the variable debt token balance.
    function getDebt(
        address user,
        address debtAsset
    ) external view returns (uint256 debt) {
        (,,,,,,,,,, address variableDebtToken,,,,) = POOL.getReserveData(debtAsset);
        if (variableDebtToken == address(0)) return 0;
        return IERC20(variableDebtToken).balanceOf(user);
    }
}
