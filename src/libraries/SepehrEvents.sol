// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library SepehrEvents {
    // ─── Subscriptions ───────────────────────────────────────────
    event Subscribed(address indexed user, uint256 expiresAt, uint8 tier, bool annual, uint256 chainId);
    event Renewed(address indexed user, uint256 newExpiresAt, uint8 tier, bool annual);
    event Unsubscribed(address indexed user);
    event TierUpgraded(address indexed user, uint8 oldTier, uint8 newTier);
    event TitanSubscriptionGranted(address indexed user, uint256 expiresAt);
    /// @notice M-1: `amount` of `user`'s payment was earned and moved to the owner's revenue.
    event RevenueSettled(address indexed user, uint256 amount);

    // ─── Positions ───────────────────────────────────────────────
    event ProtectionEnabled(
        address indexed user, bytes32 indexed protocolKey, uint256 thresholdHF, uint256 maxSlippageBps, uint256 targetHF
    );
    event ProtectionDisabled(address indexed user, bytes32 indexed protocolKey);
    /// @notice A18: emitted when `unsubscribe` iterates and wipes the user's `_protections`
    /// entries. `count` is the number of protocol keys cleared in this call.
    event UserProtectionsCleared(address indexed user, uint256 count);
    /// @notice M-2: a position's TVL snapshot lowered to its current collateral value.
    event CollateralSnapshotRefreshed(
        address indexed user, bytes32 indexed protocolKey, uint256 oldValueUsd, uint256 newValueUsd
    );
    event ProtectionUpdated(
        address indexed user,
        bytes32 indexed protocolKey,
        uint256 newThresholdHF,
        uint256 newMaxSlippageBps,
        uint256 newTargetHF
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
    /// @dev I-1: `asset` is the trigger's debt asset, the token the fee accrues in.
    event FeeCollected(
        address indexed keeper, address indexed asset, uint256 totalFee, uint256 ownerShare, uint256 keeperShare
    );
    /// @notice H-3 / L-2: tokens a trigger did not consume, sent back to the protected user.
    event SurplusReturned(address indexed user, address indexed asset, uint256 amount);
    /// @notice Lot 6: anyone may now rescue under `newHF` (0: keepers only).
    event OpenExecutionHFUpdated(uint256 oldHF, uint256 newHF);
    /// @notice Lot 6: a position's stop-loss and take-profit, on `priceAsset`'s oracle price.
    event ExitOrderSet(
        address indexed user,
        bytes32 indexed protocolKey,
        address priceAsset,
        uint256 stopLossUsd,
        uint256 takeProfitUsd
    );
    /// @notice Lot 6: an exit order closed the position: the whole debt repaid, the collateral sold.
    event PositionClosed(
        address indexed user,
        bytes32 indexed protocolKey,
        address indexed keeper,
        uint256 debtRepaid,
        uint256 collateralSold,
        uint256 price,
        uint256 fee
    );
    /// @notice Lot 6: a rescue repaid `repaid` of `asset` from the user's wallet, plus `fee`.
    event RepaidFromWallet(
        address indexed user, bytes32 indexed protocolKey, address indexed asset, uint256 repaid, uint256 fee
    );
    event OwnerFeesWithdrawn(address indexed asset, address indexed to, uint256 amount);
    event KeeperFeesWithdrawn(address indexed keeper, address indexed asset, uint256 amount);
    event TierFeeBpsUpdated(uint8 indexed tier, uint256 oldBps, uint256 newBps);
    event MinCollateralUsdUpdated(uint256 oldMin, uint256 newMin);
    /// @notice G4: emitted when the timelock updates the protocol-wide TVL cap (USD-8).
    /// `oldCap` and `newCap` are the prior and new ceilings; `protectedCollateralUsd` is
    /// not changed by this call so existing positions remain enabled even if the new cap
    /// is below the current running total — only future `enableProtection` calls are gated.
    event TvlCapUpdated(uint256 oldCap, uint256 newCap);
    /// @notice A13: emitted when the timelock updates a tier's subscription price. `annual`
    /// discriminates monthly (`false`) vs annual (`true`) schedule so off-chain indexers can
    /// reconstruct either curve without extra state.
    event TierPriceUpdated(uint8 indexed tier, bool annual, uint256 oldPrice, uint256 newPrice);

    // ─── Admin ───────────────────────────────────────────────────
    event AdapterAdded(bytes32 indexed protocolKey, address adapter);
    event AdapterRemoved(bytes32 indexed protocolKey);
    event AdapterEnabled(bytes32 indexed protocolKey);
    event AdapterDisabled(bytes32 indexed protocolKey);
    event KeeperAdded(address indexed keeper);
    event KeeperRemoved(address indexed keeper);
    event FlashLoanProviderAdded(address indexed provider);
    event FlashLoanProviderRemoved(address indexed provider);
    /// @notice A17: emitted when a whitelisted flash-loan provider reverts during `flashBorrow`
    /// inside `_borrowFlashLoan`. Surfaces the provider-side revert data that `try/catch` would
    /// otherwise swallow, making misconfigurations diagnosable without re-triggering the failure.
    event FlashAttemptFailed(address indexed provider, bytes reason);
    /// @notice L-5: the L2 sequencer uptime feed (address(0) disables the check).
    event SequencerUptimeFeedSet(address indexed feed);
    event DexRouterAdded(address indexed router);
    event DexRouterRemoved(address indexed router);
    event PauseGuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    /// @notice Governance moved to another timelock.
    event TimelockUpdated(address indexed oldTimelock, address indexed newTimelock);
    event CanonicalRouteSet(address indexed router, address indexed tokenIn, address indexed tokenOut, bytes data);
    event CanonicalRouteCleared(address indexed router, address indexed tokenIn, address indexed tokenOut);
    event StrictCanonicalRoutesUpdated(bool enabled);
    event AssetOracleSet(address indexed asset, address indexed aggregator, uint256 maxStaleness);
    event AssetOracleCleared(address indexed asset);
    event StrictOraclePricingUpdated(bool enabled);

    // ─── Emergency ───────────────────────────────────────────────
    event EmergencyPaused(address indexed by, uint256 pausedUntil);
    event Unpaused(address indexed by);
}
