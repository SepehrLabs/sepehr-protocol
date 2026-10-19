// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script, console} from "forge-std/Script.sol";

import {SepehrCore} from "../src/SepehrCore.sol";
import {IProtocolAdapter} from "../src/interfaces/IProtocolAdapter.sol";

/// @title ExecuteTestnetTimelockV2
/// @notice Part 2 of the Bloc 5.1 split deploy. Reads the addresses
///         persisted by `DeployTestnetArbitrumSepoliaV2.s.sol` and
///         executes the admin ops it scheduled: addAdapter, addKeeper,
///         addFlashLoanProvider, setAssetOracle and addDexRouter on the
///         core. The timelock enforces the 300-second delay,
///         counted from the block that mined the schedule: the script
///         asks the timelock whether each op is ready before
///         broadcasting anything.
///
/// Required env:
///   DEPLOYER_ADDRESS (must match the proposer of the scheduled ops)
///
/// Reads:
///   deployments/arbitrum-sepolia-v2.json (written by Phase 2 deploy)
contract ExecuteTestnetTimelockV2 is Script {
    uint256 internal constant ARBITRUM_SEPOLIA_CHAIN_ID = 421_614;
    uint256 internal constant ORACLE_STALENESS = 86_400; // must match deploy script

    function run() external {
        require(block.chainid == ARBITRUM_SEPOLIA_CHAIN_ID, "ExecuteTestnetTimelockV2: wrong chain (expected 421614)");

        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        string memory json = vm.readFile("deployments/arbitrum-sepolia-v2.json");
        address timelockAddr = vm.parseJsonAddress(json, ".timelock");
        address coreAddr = vm.parseJsonAddress(json, ".core");
        address aaveAdapter = vm.parseJsonAddress(json, ".aaveAdapter");
        address aaveFlash = vm.parseJsonAddress(json, ".aaveFlash");
        address dexRouter = vm.parseJsonAddress(json, ".dexRouter");
        address usdcOracle = vm.parseJsonAddress(json, ".usdcOracle");
        address usdc = vm.parseJsonAddress(json, ".usdc");
        address keeper = vm.parseJsonAddress(json, ".keeper");
        bytes32 aaveKey = vm.parseJsonBytes32(json, ".aaveKey");

        TimelockController timelock = TimelockController(payable(timelockAddr));
        SepehrCore core = SepehrCore(coreAddr);

        bytes memory dataAddAdapter = abi.encodeWithSignature("addAdapter(bytes32,address)", aaveKey, aaveAdapter);
        bytes memory dataAddKeeper = abi.encodeWithSignature("addKeeper(address)", keeper);
        bytes memory dataAddFlash = abi.encodeWithSignature("addFlashLoanProvider(address)", aaveFlash);
        bytes memory dataSetOracle =
            abi.encodeWithSignature("setAssetOracle(address,address,uint256)", usdc, usdcOracle, ORACLE_STALENESS);
        bytes memory dataAddRouter = abi.encodeWithSignature("addDexRouter(address)", dexRouter);

        _requireReady(timelock, coreAddr, dataAddAdapter, "addAdapter");
        _requireReady(timelock, coreAddr, dataAddKeeper, "addKeeper");
        _requireReady(timelock, coreAddr, dataAddFlash, "addFlashLoanProvider");
        _requireReady(timelock, coreAddr, dataSetOracle, "setAssetOracle");
        _requireReady(timelock, coreAddr, dataAddRouter, "addDexRouter");

        vm.startBroadcast(deployer);

        timelock.execute(address(core), 0, dataAddAdapter, bytes32(0), bytes32(0));
        timelock.execute(address(core), 0, dataAddKeeper, bytes32(0), bytes32(0));
        timelock.execute(address(core), 0, dataAddFlash, bytes32(0), bytes32(0));
        timelock.execute(address(core), 0, dataSetOracle, bytes32(0), bytes32(0));
        timelock.execute(address(core), 0, dataAddRouter, bytes32(0), bytes32(0));

        vm.stopBroadcast();

        // ─── Post-execute sanity ─────────────────────────────────

        (IProtocolAdapter registered, bool enabled,) = core.adapters(aaveKey);
        require(address(registered) == aaveAdapter, "execute: adapter mismatch");
        require(enabled, "execute: adapter disabled");
        require(core.keepers(keeper), "execute: keeper not set");
        require(core.allowedFlashProviders(aaveFlash), "execute: flash provider not set");
        require(core.allowedDexRouters(dexRouter), "execute: dex router not set");

        (bool ok, bytes memory ret) = address(core).staticcall(abi.encodeWithSignature("assetOracles(address)", usdc));
        require(ok, "execute: oracle getter failed");
        (address aggr, uint256 maxStale) = abi.decode(ret, (address, uint256));
        require(aggr == usdcOracle, "execute: oracle mismatch");
        require(maxStale == ORACLE_STALENESS, "execute: staleness mismatch");

        console.log("TESTNET_V2_EXECUTE_COMPLETE");
    }

    /// @dev Reverts with the op's timelock state unless it can execute now.
    function _requireReady(
        TimelockController timelock,
        address target,
        bytes memory data,
        string memory label
    ) internal view {
        bytes32 id = timelock.hashOperation(target, 0, data, bytes32(0), bytes32(0));
        TimelockController.OperationState state = timelock.getOperationState(id);
        if (state == TimelockController.OperationState.Ready) return;
        if (state == TimelockController.OperationState.Waiting) {
            revert(
                string.concat(
                    "ExecuteTestnetTimelockV2: ",
                    label,
                    " ready at ",
                    vm.toString(timelock.getTimestamp(id)),
                    ", now ",
                    vm.toString(block.timestamp)
                )
            );
        }
        revert(
            string.concat(
                "ExecuteTestnetTimelockV2: ",
                label,
                state == TimelockController.OperationState.Done ? " already executed" : " never scheduled"
            )
        );
    }
}
