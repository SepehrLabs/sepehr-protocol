// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script, console} from "forge-std/Script.sol";

import {SepehrCore} from "../src/SepehrCore.sol";
import {AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {IProtocolAdapter} from "../src/interfaces/IProtocolAdapter.sol";

/// @title ReplaceTestnetAaveAdapter
/// @notice Replaces the Aave adapter of the Arbitrum Sepolia core with the multi-collateral one
///         (lot 4), under the same protocol key, through the 300-second timelock. Protections
///         keep their settings; each user approves the aTokens of their collateral to the new
///         adapter before it can rescue them.
///
///         `schedule()` deploys the adapter on the pool of the current one and schedules the
///         batch removeAdapter + addAdapter. `execute()`, once the delay has passed, runs the
///         batch and records the new adapter in deployments/arbitrum-sepolia-v2.json.
///
/// Required env:
///   DEPLOYER_ADDRESS   proposer and executor of the timelock
///   NEW_AAVE_ADAPTER   execute() only: the address schedule() printed
contract ReplaceTestnetAaveAdapter is Script {
    uint256 internal constant ARBITRUM_SEPOLIA_CHAIN_ID = 421_614;
    string internal constant DEPLOYMENT = "deployments/arbitrum-sepolia-v2.json";

    /// @notice Deploys the new adapter and schedules its swap with the current one.
    function schedule() external {
        (TimelockController timelock, SepehrCore core, bytes32 key) = _load();
        (IProtocolAdapter current,,) = core.adapters(key);
        address pool = address(AaveV3Adapter(address(current)).POOL());

        vm.startBroadcast(vm.envAddress("DEPLOYER_ADDRESS"));
        AaveV3Adapter adapter = new AaveV3Adapter(pool, address(core));
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            _batch(core, key, address(adapter));
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), timelock.getMinDelay());
        vm.stopBroadcast();

        console.log("NEW_AAVE_ADAPTER", address(adapter));
    }

    /// @notice Runs the scheduled swap once the timelock allows it, then records the new adapter.
    function execute() external {
        (TimelockController timelock, SepehrCore core, bytes32 key) = _load();
        address next = vm.envAddress("NEW_AAVE_ADAPTER");
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _batch(core, key, next);
        bytes32 id = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), bytes32(0));
        if (!timelock.isOperationReady(id)) {
            revert(
                string.concat(
                    "ReplaceTestnetAaveAdapter: not ready (ready at ",
                    vm.toString(timelock.getTimestamp(id)),
                    ", now ",
                    vm.toString(block.timestamp),
                    "; 0 means never scheduled, 1 already executed)"
                )
            );
        }

        vm.startBroadcast(vm.envAddress("DEPLOYER_ADDRESS"));
        timelock.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));
        vm.stopBroadcast();

        (IProtocolAdapter registered, bool enabled,) = core.adapters(key);
        require(address(registered) == next, "ReplaceTestnetAaveAdapter: adapter mismatch");
        require(enabled, "ReplaceTestnetAaveAdapter: adapter disabled");
        vm.writeJson(vm.toString(next), DEPLOYMENT, ".aaveAdapter");
        console.log("AAVE_ADAPTER_REPLACED", next);
    }

    function _load() internal view returns (TimelockController timelock, SepehrCore core, bytes32 key) {
        require(block.chainid == ARBITRUM_SEPOLIA_CHAIN_ID, "ReplaceTestnetAaveAdapter: wrong chain");
        string memory json = vm.readFile(DEPLOYMENT);
        timelock = TimelockController(payable(vm.parseJsonAddress(json, ".timelock")));
        core = SepehrCore(vm.parseJsonAddress(json, ".core"));
        key = vm.parseJsonBytes32(json, ".aaveKey");
    }

    /// @dev removeAdapter then addAdapter under the same key, in one timelock operation.
    function _batch(
        SepehrCore core,
        bytes32 key,
        address adapter
    ) internal pure returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads) {
        targets = new address[](2);
        targets[0] = address(core);
        targets[1] = address(core);
        values = new uint256[](2);
        payloads = new bytes[](2);
        payloads[0] = abi.encodeCall(SepehrCore.removeAdapter, (key));
        payloads[1] = abi.encodeCall(SepehrCore.addAdapter, (key, adapter));
    }
}
