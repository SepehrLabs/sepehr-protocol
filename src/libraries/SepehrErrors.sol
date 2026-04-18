// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

library SepehrErrors {
    error NotKeeper();
    error NotOwner();
    error NotTimelock();
    error NotPauseGuardian();
    error NotAuthorized();

    error ContractPaused();

    error CooldownActive(uint256 remaining);
    error HealthFactorAboveThreshold(uint256 current, uint256 threshold);
    error MaxRepayExceeded(uint256 requested, uint256 maxAllowed);
    error RepayExceedsUserLimit(uint256 requested, uint256 allowed);
    error SlippageExceeded(uint256 actualOut, uint256 minExpected);
    error PostExecutionHFBelowThreshold(uint256 hfAfter, uint256 threshold);
    error HealthFactorNotImproved(uint256 hfBefore, uint256 hfAfter);
    error ImplausibleHealthFactor(uint256 hf, uint256 floor);
    error DebtAssetMismatch(address expected, address provided);
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
    error ThresholdTooLow(uint256 threshold, uint256 minimum);
    error RepayPercentTooHigh(uint256 bps, uint256 maxBps);
    error InvalidSlippage(uint256 bps);
    error TierFeeBpsTooHigh(uint256 bps, uint256 maxBps);
    error TierPriceDeviationTooLarge(uint256 oldPrice, uint256 newPrice);

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

    error ProtectionNotEnabled(address user, bytes32 protocolKey);
    error ProtectionAlreadyEnabled(address user, bytes32 protocolKey);

    error ZeroAddress();
    error ZeroAmount();
}
