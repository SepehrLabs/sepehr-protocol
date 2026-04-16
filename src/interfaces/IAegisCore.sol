// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title IAegisCore
/// @notice Public interface for the AegisCore contract.
interface IAegisCore {
    // ─── Structs ─────────────────────────────────────────────────

    struct Subscription {
        uint8 tier; // 1-4
        uint256 expiresAt;
        uint256 collateralValueUsdSnapshot;
    }

    struct PositionProtection {
        bool enabled;
        uint256 thresholdHF; // WAD
        uint256 maxSlippageBps;
        uint256 repayPercentBps;
    }

    // ─── User Actions ────────────────────────────────────────────

    /// @notice Subscribe to AEGIS protection.
    /// @param tier The subscription tier (1-4).
    /// @param paymentToken The token to pay with (USDC or WETH).
    function subscribe(
        uint8 tier,
        address paymentToken
    ) external;

    /// @notice Renew an existing subscription for another billing period.
    /// @param paymentToken The token to pay with.
    function renew(
        address paymentToken
    ) external;

    /// @notice Cancel the subscription. Remaining time is forfeited.
    function unsubscribe() external;

    /// @notice Enable AEGIS protection on a specific protocol position.
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

    /// @notice Disable AEGIS protection on a specific protocol position.
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
}
