// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title SepehrTimelock
/// @notice Thin wrapper around OZ TimelockController with a 48-hour delay.
///         All admin mutations on SepehrCore (addAdapter, setFeeBps, addKeeper, etc.)
///         are gated behind this timelock.
contract SepehrTimelock is TimelockController {
    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(minDelay, proposers, executors, admin) {}
}
