// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title ISepehrCore
/// @notice Public interface for the SepehrCore contract.
interface ISepehrCore {
    // ─── Structs ─────────────────────────────────────────────────

    struct Subscription {
        uint8 tier; // 1-4
        bool annual;
        uint256 expiresAt;
    }

    struct PositionProtection {
        bool enabled;
        uint256 thresholdHF; // WAD
        uint256 maxSlippageBps;
        uint256 repayPercentBps;
    }

    // ─── User Actions ────────────────────────────────────────────

    /// @notice Subscribe to Sepehr protection (tiers 1-3 self-service, tier 4 owner-only).
    /// @param tier The subscription tier (1-3).
    /// @param annual Whether to subscribe for a full year (20% discount).
    function subscribe(
        uint8 tier,
        bool annual
    ) external;

    /// @notice Renew an existing subscription for another billing period.
    function renew() external;

    /// @notice Cancel the subscription. Remaining time is forfeited.
    function unsubscribe() external;

    /// @notice Upgrade (or change billing cadence on) an active subscription.
    /// @dev A12: callers pay the full price of the new tier/period; the unused pro-rata
    /// portion of the existing subscription is credited against the new price so users
    /// upgrading mid-period are not double-billed. Remaining time is forfeited — the
    /// new period starts now. Tier 4 is owner-granted and cannot be self-upgraded to.
    /// @param newTier The new tier (1-3).
    /// @param newAnnual True for annual billing, false for monthly.
    function upgradeTier(
        uint8 newTier,
        bool newAnnual
    ) external;

    /// @notice Enable Sepehr protection on a specific protocol position.
    /// @param protocolKey The keccak256 key identifying the protocol.
    /// @param thresholdHF The health-factor threshold that triggers protection (WAD).
    /// @param maxSlippageBps Maximum acceptable slippage in basis points.
    /// @param repayPercentBps Percentage of debt to repay per trigger (in bps, max 5000).
    function enableProtection(
        bytes32 protocolKey,
        uint256 thresholdHF,
        uint256 maxSlippageBps,
        uint256 repayPercentBps
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
    /// @param repayPercentBps New repay percentage in bps.
    function updateProtection(
        bytes32 protocolKey,
        uint256 thresholdHF,
        uint256 maxSlippageBps,
        uint256 repayPercentBps
    ) external;

    // ─── Keeper Actions ──────────────────────────────────────────

    /// @notice Execute a liquidation-protection trigger.
    /// @dev A15: the USD value credited to `saveCredits[user]` is computed on-chain from the
    /// registered debt-asset oracle rather than being taken from the keeper, so a misbehaving
    /// keeper cannot inflate or suppress the user-facing "money saved" metric. If no debt-asset
    /// oracle is registered, the trigger still succeeds but no save credit is accrued.
    /// @param user The user to protect.
    /// @param protocolKey The protocol key.
    /// @param debtAsset The debt token to repay.
    /// @param collateralAsset The collateral token to withdraw and swap.
    /// @param repayAmount The amount of debt to repay.
    /// @param flashProviders Ordered list of flash-loan provider addresses to try.
    /// @param dexRouter The DEX router to use for the collateral→debt swap.
    /// @param dexRouteData Encoded route hints for the DEX.
    function execute(
        address user,
        bytes32 protocolKey,
        address debtAsset,
        address collateralAsset,
        uint256 repayAmount,
        address[] calldata flashProviders,
        address dexRouter,
        bytes calldata dexRouteData
    ) external;

    // ─── Views ───────────────────────────────────────────────────

    function getSubscription(
        address user
    ) external view returns (Subscription memory);

    function getProtection(
        address user,
        bytes32 protocolKey
    ) external view returns (PositionProtection memory);

    function isKeeper(
        address addr
    ) external view returns (bool);

    function getSaveCredits(
        address user
    ) external view returns (uint256);
}
