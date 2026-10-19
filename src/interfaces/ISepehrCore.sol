// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {ISepehrSubscriptions} from "./ISepehrSubscriptions.sol";

/// @title ISepehrCore
/// @notice Public interface for the SepehrCore contract.
interface ISepehrCore {
    // ─── Structs ─────────────────────────────────────────────────

    struct PositionProtection {
        bool enabled;
        uint256 thresholdHF; // WAD: the keeper may rescue the position below it
        uint256 maxSlippageBps;
        uint256 targetHF; // WAD: the health factor a rescue brings the position back to
    }

    /// @notice Lot 6: closes the position once `priceAsset`'s oracle price, in the feed's decimals
    /// (8 for Chainlink's USD feeds), reaches the stop-loss (at or below) or the take-profit (at
    /// or above); 0 leaves a side off.
    struct ExitOrder {
        address priceAsset;
        uint256 stopLossUsd;
        uint256 takeProfitUsd;
    }

    // ─── User Actions ────────────────────────────────────────────

    /// @notice Enable Sepehr protection on a protocol position; needs an active plan.
    /// @param protocolKey The protocol key.
    /// @param thresholdHF Health factor (WAD) under which the keeper may rescue the position.
    /// @param maxSlippageBps Maximum slippage on the rescue swap, in bps.
    /// @param targetHF Health factor (WAD) a rescue brings the position back to.
    function enableProtection(
        bytes32 protocolKey,
        uint256 thresholdHF,
        uint256 maxSlippageBps,
        uint256 targetHF
    ) external;

    /// @notice Disable Sepehr protection on a specific protocol position.
    /// @param protocolKey The protocol key.
    function disableProtection(
        bytes32 protocolKey
    ) external;

    /// @notice Update protection parameters for an already-enabled position.
    /// @param protocolKey The protocol key.
    /// @param thresholdHF New health-factor threshold (WAD).
    /// @param maxSlippageBps New maximum slippage in bps.
    /// @param targetHF New target health factor (WAD).
    function updateProtection(
        bytes32 protocolKey,
        uint256 thresholdHF,
        uint256 maxSlippageBps,
        uint256 targetHF
    ) external;

    /// @notice Set, change or remove (both prices 0) the stop-loss and take-profit of a
    /// protected position.
    /// @param protocolKey The protocol key.
    /// @param priceAsset Asset whose oracle price triggers the close; needs a registered oracle.
    /// @param stopLossUsd Close at or below this oracle price; 0 for none.
    /// @param takeProfitUsd Close at or above this oracle price; 0 for none.
    function setExitOrder(
        bytes32 protocolKey,
        address priceAsset,
        uint256 stopLossUsd,
        uint256 takeProfitUsd
    ) external;

    // ─── Keeper Actions ──────────────────────────────────────────

    /// @notice Close a position whose exit order the oracle price triggered: repay the whole
    /// debt in `debtAsset`, sell `collateralAmount` of `collateralAsset`, send the rest to the user.
    /// @param user The position's owner.
    /// @param protocolKey The protocol key.
    /// @param debtAsset The debt repaid in full.
    /// @param collateralAsset The collateral sold.
    /// @param collateralAmount How much of it to withdraw and sell, all the keeper read.
    /// @param flashProviders Ordered list of flash-loan provider addresses to try.
    /// @param dexRouter The DEX router to use for the collateral→debt swap.
    /// @param dexRouteData Encoded route hints for the DEX.
    function close(
        address user,
        bytes32 protocolKey,
        address debtAsset,
        address collateralAsset,
        uint256 collateralAmount,
        address[] calldata flashProviders,
        address dexRouter,
        bytes calldata dexRouteData
    ) external;

    /// @notice Execute a liquidation-protection trigger: the debt asset the user approved repays
    /// first, a flash loan against the collateral covers the rest. Keepers only, or anyone when
    /// the health factor is under a non-zero `openExecutionHF`.
    /// @param user The user to protect.
    /// @param protocolKey The protocol key.
    /// @param debtAsset The debt token to repay.
    /// @param collateralAsset The collateral token to withdraw and swap.
    /// @param repayAmount The amount of debt to repay.
    /// @param flashProviders Ordered list of flash-loan provider addresses to try.
    /// @param dexRouter The DEX router to use for the collateral→debt swap.
    /// @param dexRouteData Encoded route hints for the DEX.
    /// @return hfAfter The position's health factor after the rescue. A keeper simulating the
    /// call reads it to size `repayAmount` for the target.
    function execute(
        address user,
        bytes32 protocolKey,
        address debtAsset,
        address collateralAsset,
        uint256 repayAmount,
        address[] calldata flashProviders,
        address dexRouter,
        bytes calldata dexRouteData
    ) external returns (uint256 hfAfter);

    // ─── Subscriptions ───────────────────────────────────────────

    /// @notice Wipe every protection of `user`; called by SepehrSubscriptions when they cancel.
    /// @param user The subscriber who cancelled.
    function clearProtections(
        address user
    ) external;

    // ─── Views ───────────────────────────────────────────────────

    /// @notice The SepehrSubscriptions this core reads plans from.
    function subscriptions() external view returns (ISepehrSubscriptions);

    /// @notice Whether the core is paused; SepehrSubscriptions follows it.
    function paused() external view returns (bool);

    /// @notice A position's protection settings.
    /// @param user The position's owner.
    /// @param protocolKey The protocol key.
    /// @return The protection; `enabled` is false when there is none.
    function getProtection(
        address user,
        bytes32 protocolKey
    ) external view returns (PositionProtection memory);

    /// @notice The health factor under which anyone may rescue a position; 0 when only keepers may.
    /// @return The open-execution health factor, WAD.
    function openExecutionHF() external view returns (uint256);

    /// @notice A position's stop-loss and take-profit.
    /// @param user The position's owner.
    /// @param protocolKey The protocol key.
    /// @return The order; a zero `priceAsset` means none.
    function getExitOrder(
        address user,
        bytes32 protocolKey
    ) external view returns (ExitOrder memory);

    /// @notice Whether `addr` is a whitelisted keeper.
    /// @param addr The address to check.
    /// @return True when `addr` may execute rescues and exit orders.
    function isKeeper(
        address addr
    ) external view returns (bool);
}
