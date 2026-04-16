// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

library AegisEvents {
    // ─── Subscriptions ───────────────────────────────────────────
    event Subscribed(address indexed user, uint256 expiresAt, uint8 tier, uint256 chainId);
    event Renewed(address indexed user, uint256 newExpiresAt, uint8 tier);
    event Unsubscribed(address indexed user);
    event TierUpgraded(address indexed user, uint8 oldTier, uint8 newTier);

    // ─── Positions ───────────────────────────────────────────────
    event ProtectionEnabled(
        address indexed user,
        bytes32 indexed protocolKey,
        uint256 thresholdHF,
        uint256 maxSlippageBps,
        uint256 repayPercentBps
    );
    event ProtectionDisabled(address indexed user, bytes32 indexed protocolKey);
    event ProtectionUpdated(
        address indexed user,
        bytes32 indexed protocolKey,
        uint256 newThresholdHF,
        uint256 newMaxSlippageBps,
        uint256 newRepayPercentBps
    );

    // ─── Triggers ────────────────────────────────────────────────
    event Triggered(
        address indexed user,
        bytes32 indexed protocolKey,
        address indexed keeper,
        uint256 repayAmount,
        uint256 collateralWithdrawn,
        uint256 hfBefore,
        uint256 hfAfter,
        uint256 feeTaken
    );

    // ─── Fees ────────────────────────────────────────────────────
    event FeeCollected(address indexed keeper, uint256 totalFee, uint256 ownerShare, uint256 keeperShare);
    event OwnerFeesWithdrawn(address indexed to, uint256 amount);
    event KeeperFeesWithdrawn(address indexed keeper, uint256 amount);
    event FeeBpsUpdated(uint256 oldBps, uint256 newBps);

    // ─── Admin ───────────────────────────────────────────────────
    event AdapterAdded(bytes32 indexed protocolKey, address adapter);
    event AdapterRemoved(bytes32 indexed protocolKey);
    event AdapterEnabled(bytes32 indexed protocolKey);
    event AdapterDisabled(bytes32 indexed protocolKey);
    event KeeperAdded(address indexed keeper);
    event KeeperRemoved(address indexed keeper);
    event FlashLoanProviderAdded(address indexed provider);
    event FlashLoanProviderRemoved(address indexed provider);
    event PauseGuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

    // ─── Emergency ───────────────────────────────────────────────
    event EmergencyPaused(address indexed by);
    event Unpaused(address indexed by);
}
