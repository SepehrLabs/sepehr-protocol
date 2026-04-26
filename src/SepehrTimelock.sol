// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title SepehrTimelock
/// @notice Thin wrapper around OZ TimelockController with a 48-hour floor on `minDelay`.
///         All admin mutations on SepehrCore (addAdapter, setFeeBps, addKeeper, etc.)
///         are gated behind this timelock.
/// @dev The constructor asserts `minDelay >= MIN_DELAY` to prevent a deployer
///      misconfiguration or malicious deploy script from producing an instant-exec
///      timelock. A deploy with `minDelay=0` would otherwise let a compromised
///      proposer/executor addAdapter(maliciousAdapter) → execute → drain in a
///      single block, bypassing the announce-on-chain guarantee.
contract SepehrTimelock is TimelockController {
    /// @notice Minimum acceptable delay (48 hours). Enforced at construction.
    uint256 public constant MIN_DELAY = 48 hours;

    error DelayBelowMinimum(uint256 requested, uint256 minimum);

    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(minDelay, proposers, executors, admin) {
        if (minDelay < MIN_DELAY) revert DelayBelowMinimum(minDelay, MIN_DELAY);
    }
}
