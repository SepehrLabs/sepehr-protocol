// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @notice Minimal Balancer V2 Vault interface for flash loans.
interface IBalancerVault {
    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;

    function getProtocolFeesCollector() external view returns (address);
}

/// @notice Minimal Balancer V2 ProtocolFeesCollector interface.
interface IBalancerFeesCollector {
    function getFlashLoanFeePercentage() external view returns (uint256);
}
