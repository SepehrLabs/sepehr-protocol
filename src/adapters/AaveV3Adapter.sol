// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {IAavePool} from "../interfaces/external/IAavePool.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title AaveV3Adapter
/// @notice Protocol adapter for Aave V3 positions. Handles health factor queries,
///         debt repayment, and collateral withdrawal on behalf of users.
/// @dev M-3: a position may hold several collaterals. The adapter withdraws whichever one the
///      rescue names, through that asset's aToken, which the user approves to this adapter one
///      asset at a time. The keeper picks the collateral among the approved ones.
contract AaveV3Adapter is IProtocolAdapter {
    using SafeERC20 for IERC20;

    /// @notice One collateral of a position: what an app shows and asks the user to approve.
    struct Collateral {
        address asset;
        address aToken;
        string symbol;
        uint256 balance;
        uint256 allowance;
    }

    IAavePool public immutable POOL;
    address public immutable core;

    modifier onlyCore() {
        if (msg.sender != core) revert SepehrErrors.NotAuthorized();
        _;
    }

    constructor(
        address pool,
        address _core
    ) {
        if (pool == address(0)) revert SepehrErrors.ZeroAddress();
        if (_core == address(0)) revert SepehrErrors.ZeroAddress();
        POOL = IAavePool(pool);
        core = _core;
    }

    /// @inheritdoc IProtocolAdapter
    function getHealthFactor(
        address user
    ) external view returns (uint256 healthFactor) {
        (,,,,, healthFactor) = POOL.getUserAccountData(user);
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev True when at least one asset the user supplies as collateral can be withdrawn: they
    ///      hold its aToken and approved it to this adapter. Audit B20: the approval must be
    ///      effectively unlimited (>= 2**128), since a rescue may pull a large share. M-3: an
    ///      approval on a collateral the user does not hold does not count. Assets are found
    ///      through Aave's user configuration, whose bit `2 * id + 1` marks a collateral.
    function checkDelegation(
        address user
    ) external view returns (bool delegated) {
        uint256 config = POOL.getUserConfiguration(user);
        address[] memory reserves = POOL.getReservesList();
        for (uint256 id = 0; id < reserves.length; id++) {
            if ((config >> (2 * id + 1)) & 1 == 0) continue;
            if (isDelegated(user, reserves[id])) return true;
        }
    }

    /// @notice Every asset `user` supplies as collateral, with their aToken balance and the
    ///         allowance this adapter holds on it, in one read for apps. A symbol the token
    ///         does not expose as a string is left empty.
    /// @param user The position owner.
    /// @return list One entry per collateral, in reserve order.
    function collateralsOf(
        address user
    ) external view returns (Collateral[] memory list) {
        uint256 config = POOL.getUserConfiguration(user);
        address[] memory reserves = POOL.getReservesList();
        uint256 count;
        for (uint256 id = 0; id < reserves.length; id++) {
            if ((config >> (2 * id + 1)) & 1 == 1) count++;
        }
        list = new Collateral[](count);
        uint256 next;
        for (uint256 id = 0; id < reserves.length; id++) {
            if ((config >> (2 * id + 1)) & 1 == 0) continue;
            address asset = reserves[id];
            (,,,,,,,, address aToken,,,,,,) = POOL.getReserveData(asset);
            string memory symbol;
            try IERC20Metadata(asset).symbol() returns (string memory s) {
                symbol = s;
            } catch {}
            list[next++] = Collateral({
                asset: asset,
                aToken: aToken,
                symbol: symbol,
                balance: IERC20(aToken).balanceOf(user),
                allowance: IERC20(aToken).allowance(user, address(this))
            });
        }
    }

    /// @notice Whether the rescue can withdraw `asset` from `user`'s position: they hold its
    ///         aToken and approved it to this adapter without practical limit.
    /// @param user The position owner.
    /// @param asset The underlying collateral asset.
    /// @return True when `asset` can be withdrawn.
    function isDelegated(
        address user,
        address asset
    ) public view returns (bool) {
        (,,,,,,,, address aToken,,,,,,) = POOL.getReserveData(asset);
        if (aToken == address(0)) return false;
        return IERC20(aToken).allowance(user, address(this)) >= type(uint128).max && IERC20(aToken).balanceOf(user) != 0;
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
        // M-3: any reserve the user supplies, through its own aToken; an asset Aave does not list has none.
        (,,,,,,,, address aToken,,,,,,) = POOL.getReserveData(collateralAsset);
        if (aToken == address(0)) revert SepehrErrors.UnsupportedCollateral(collateralAsset);
        IERC20(aToken).safeTransferFrom(user, address(this), amount);
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
