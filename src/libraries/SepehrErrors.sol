// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library SepehrErrors {
    error NotKeeper();
    error NotOwner();
    error NotTimelock();
    error NotPauseGuardian();
    error NotAuthorized();

    error ContractPaused();

    /// @notice Reverts every SepehrCore entry-point (mutative + user-state views) whenever
    /// `block.chainid` differs from the `expectedChainId` captured at construction. V1 pivots
    /// mono-Arbitrum so a contract deployed on the wrong chain (including via an EVM-compatible
    /// rollup misconfiguration) is fully inert instead of half-alive. See ADR-0011.
    /// @param expected The chain ID authorized for this contract instance.
    /// @param actual The chain ID reported by the current transaction's EVM context.
    error WrongChain(uint256 expected, uint256 actual);

    error CooldownActive(uint256 remaining);
    error HealthFactorAboveThreshold(uint256 current, uint256 threshold);
    error MaxRepayExceeded(uint256 requested, uint256 maxAllowed);
    error RepayExceedsUserLimit(uint256 requested, uint256 allowed);
    error SlippageExceeded(uint256 actualOut, uint256 minExpected);
    /// @notice The rescue left the core with less debt asset than the flash-loan repayment plus
    /// the trigger fee (for instance a fee-on-transfer collateral).
    error InsufficientRescueProceeds(uint256 available, uint256 required);
    error HealthFactorNotImproved(uint256 hfBefore, uint256 hfAfter);
    error ImplausibleHealthFactor(uint256 hf, uint256 floor);
    error DebtAssetMismatch(address expected, address provided);
    /// @notice M-6: the adapter reports no debt of `debtAsset` for `user`.
    error NoDebtToRepay(address user, address debtAsset);
    error CollateralAssetMismatch(address expected, address provided);
    error UnsupportedTokenBehavior(address token);

    error SubscriptionExpired();
    error SubscriptionNotFound();
    error SubscriptionAlreadyActive();
    error InvalidTier();
    error TitanSelfSubscribeNotAllowed();
    error InsufficientPayment(uint256 required, uint256 provided);
    error SameTierUpgrade();
    error UpgradeTierPathInvalid(uint8 fromTier, uint8 toTier);

    error BelowMinimumCollateral(uint256 usdValue, uint256 minimumUsd);
    error TierCollateralCapExceeded(uint256 usdValue, uint256 capUsd);
    /// @notice G4: thrown by `enableProtection` when adding the new position's snapshotted
    /// collateral USD value would push the protocol-wide `protectedCollateralUsd` above
    /// `tvlCapUsd`. `attempted` is the prospective new total; `cap` is the configured ceiling.
    error TvlCapExceeded(uint256 attempted, uint256 cap);
    error ThresholdTooLow(uint256 threshold, uint256 minimum);
    error RepayPercentTooHigh(uint256 bps, uint256 maxBps);
    error InvalidSlippage(uint256 bps);
    error TierFeeBpsTooHigh(uint256 bps, uint256 maxBps);
    error TierPriceDeviationTooLarge(uint256 oldPrice, uint256 newPrice);
    error TierPriceCooldown(uint256 lastUpdate, uint256 nextAllowed);

    error AdapterNotRegistered(bytes32 protocolKey);
    error AdapterAlreadyRegistered(bytes32 protocolKey);
    error AdapterDisabled(bytes32 protocolKey);
    error DelegationRevoked(address user, bytes32 protocolKey);

    error NoFlashLoanAvailable();
    error InvalidFlashLoanCallback();
    error ConcurrentFlashLoan();
    error UnsupportedPoolFee(uint24 fee);
    error NoCanonicalRoute(address router, address tokenIn, address tokenOut);
    error SameToken();
    error InvalidRouteData();

    error MissingAssetOracle(address asset);
    error StaleOraclePrice(address asset, uint256 updatedAt, uint256 nowTs);
    error InvalidOraclePrice(address asset, int256 answer);
    error InvalidOracleStaleness(uint256 maxStaleness);
    error InvalidOracleDecimals(uint8 actual, uint8 expected);
    /// @notice L-5: the L2 sequencer uptime feed reports the sequencer down, or an invalid round.
    error SequencerDown();
    /// @notice L-5: the sequencer came back up less than `SEQUENCER_GRACE_PERIOD` ago.
    error SequencerGracePeriodNotOver(uint256 upSince);
    /// @notice I-2: a repay share this low makes every trigger revert.
    error RepayPercentTooLow(uint256 provided, uint256 min);

    error ProtectionNotEnabled(address user, bytes32 protocolKey);
    error ProtectionAlreadyEnabled(address user, bytes32 protocolKey);

    error ZeroAddress();
    error ZeroAmount();

    error OwnershipCannotBeRenounced();
}
