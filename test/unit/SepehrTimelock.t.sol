// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {SepehrCore} from "../../src/SepehrCore.sol";
import {SepehrTimelock} from "../../src/SepehrTimelock.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {SepehrStack} from "../helpers/SepehrStack.sol";

/// @notice The timelock as DeployCore sets it up: the owner (a Safe on mainnet) proposes,
///         executes and cancels; nobody administers it but itself.
contract SepehrTimelockTest is SepehrStack {
    SepehrTimelock internal timelock;
    SepehrCore internal core;

    address internal proposer = makeAddr("proposer");
    address internal stranger = makeAddr("stranger");
    address internal newKeeper = makeAddr("newKeeper");
    bytes internal addKeeperCall;

    function setUp() public {
        address[] memory roles = new address[](1);
        roles[0] = proposer;
        timelock = new SepehrTimelock(48 hours, roles, roles, address(0));
        MockERC20 usdc = new MockERC20("USDC", "USDC");
        (core,) = _deployStack(proposer, address(timelock), makeAddr("guardian"), address(usdc), 0, type(uint256).max);
        addKeeperCall = abi.encodeCall(SepehrCore.addKeeper, (newKeeper));
    }

    function _schedule() internal {
        vm.prank(proposer);
        timelock.schedule(address(core), 0, addKeeperCall, bytes32(0), bytes32(0), 48 hours);
    }

    function _execute() internal {
        vm.prank(proposer);
        timelock.execute(address(core), 0, addKeeperCall, bytes32(0), bytes32(0));
    }

    function test_constructor_revertsUnderTheMinimumDelay() public {
        address[] memory none = new address[](0);
        vm.expectRevert(abi.encodeWithSelector(SepehrTimelock.DelayBelowMinimum.selector, 48 hours - 1, 48 hours));
        new SepehrTimelock(48 hours - 1, none, none, address(0));
    }

    function test_constructor_givesTheProposerItsRolesAndNobodyTheAdmin() public view {
        assertEq(timelock.getMinDelay(), 48 hours);
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), proposer));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), proposer));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), proposer));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), proposer));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
    }

    function test_aCoreChangeWaitsTheDelay() public {
        _schedule();

        vm.warp(block.timestamp + 48 hours - 1);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        _execute();

        vm.warp(block.timestamp + 1);
        _execute();
        assertTrue(core.isKeeper(newKeeper));
    }

    function test_schedule_revertsForAnyoneButTheProposer() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, timelock.PROPOSER_ROLE()
            )
        );
        vm.prank(stranger);
        timelock.schedule(address(core), 0, addKeeperCall, bytes32(0), bytes32(0), 48 hours);
    }

    function test_execute_revertsForAnyoneButTheExecutor() public {
        _schedule();
        vm.warp(block.timestamp + 48 hours);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, timelock.EXECUTOR_ROLE()
            )
        );
        vm.prank(stranger);
        timelock.execute(address(core), 0, addKeeperCall, bytes32(0), bytes32(0));
    }

    function test_aCancelledChangeNeverRuns() public {
        _schedule();
        bytes32 id = timelock.hashOperation(address(core), 0, addKeeperCall, bytes32(0), bytes32(0));
        vm.prank(proposer);
        timelock.cancel(id);

        vm.warp(block.timestamp + 48 hours);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        _execute();
        assertFalse(core.isKeeper(newKeeper));
    }
}
