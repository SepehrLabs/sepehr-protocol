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
    error SlippageExceeded(uint256 actualOut, uint256 minExpected);
    error PostExecutionHFBelowThreshold(uint256 hfAfter, uint256 threshold);
    error HealthFactorNotImproved(uint256 hfBefore, uint256 hfAfter);

    error SubscriptionExpired();
    error SubscriptionNotFound();
    error SubscriptionAlreadyActive();
    error InvalidTier();
    error TitanSelfSubscribeNotAllowed();
    error InsufficientPayment(uint256 required, uint256 provided);

    error BelowMinimumCollateral(uint256 usdValue, uint256 minimumUsd);
    error ThresholdTooLow(uint256 threshold, uint256 minimum);
    error RepayPercentTooHigh(uint256 bps, uint256 maxBps);
    error InvalidSlippage(uint256 bps);

    error AdapterNotRegistered(bytes32 protocolKey);
    error AdapterAlreadyRegistered(bytes32 protocolKey);
    error AdapterDisabled(bytes32 protocolKey);
    error DelegationRevoked(address user, bytes32 protocolKey);

    error NoFlashLoanAvailable();
    error InvalidFlashLoanCallback();

    error ProtectionNotEnabled(address user, bytes32 protocolKey);
    error ProtectionAlreadyEnabled(address user, bytes32 protocolKey);

    error ZeroAddress();
    error ZeroAmount();
}
