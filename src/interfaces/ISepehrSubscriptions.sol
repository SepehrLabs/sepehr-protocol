// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {ISepehrCore} from "./ISepehrCore.sol";

/// @title ISepehrSubscriptions
/// @notice Public interface of SepehrSubscriptions: the plans users pay for, and what SepehrCore
///         reads of them before it protects or rescues a position.
interface ISepehrSubscriptions {
    // ─── Structs ─────────────────────────────────────────────────

    struct Subscription {
        uint8 tier; // 1-4
        bool annual;
        uint256 expiresAt;
    }

    /// @notice What SepehrCore needs of a user's plan, in one read.
    struct Plan {
        uint8 tier; // 0 without a subscription
        uint256 expiresAt;
        uint256 maxCollateralUsd; // USD-8; type(uint256).max for Titan
        uint256 feeBps; // trigger fee on the repaid amount
    }

    // ─── User Actions ────────────────────────────────────────────

    /// @notice Subscribe to Sepehr protection (tiers 1-3 self-service, tier 4 owner-granted).
    /// @param tier The subscription tier (1-3).
    /// @param annual Whether to subscribe for a full year (20% discount).
    function subscribe(
        uint8 tier,
        bool annual
    ) external;

    /// @notice Renew the subscription for another billing period.
    function renew() external;

    /// @notice Cancel the subscription; the unused part of what was paid is refunded and
    ///         every protection is cleared.
    function unsubscribe() external;

    /// @notice Change tier or billing cadence of an active subscription, crediting the unused
    ///         part of what was paid.
    /// @param newTier Target tier (1-3).
    /// @param newAnnual Whether the new period is a full year.
    function upgradeTier(
        uint8 newTier,
        bool newAnnual
    ) external;

    // ─── Views ───────────────────────────────────────────────────

    /// @notice The SepehrCore this contract serves.
    function core() external view returns (ISepehrCore);

    /// @notice The user's subscription record.
    /// @param user The subscriber.
    /// @return The tier, cadence and expiry.
    function getSubscription(
        address user
    ) external view returns (Subscription memory);

    /// @notice The user's plan as SepehrCore checks it: tier, expiry, collateral cap and fee.
    /// @param user The subscriber.
    /// @return The plan; tier 0 when the user never subscribed or cancelled.
    function planOf(
        address user
    ) external view returns (Plan memory);
}
