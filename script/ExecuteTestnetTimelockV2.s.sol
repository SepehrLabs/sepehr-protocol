// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script, console} from "forge-std/Script.sol";

import {SepehrCore} from "../src/SepehrCore.sol";
import {IProtocolAdapter} from "../src/interfaces/IProtocolAdapter.sol";

/// @title ExecuteTestnetTimelockV2
/// @notice Part 2 of the Bloc 5.1 split deploy. Reads the addresses
///         persisted by `DeployTestnetArbitrumSepoliaV2.s.sol` and
///         executes the four admin ops it scheduled (addAdapter,
///         addKeeper, addFlashLoanProvider, setAssetOracle). The
///         timelock enforces the 300-second delay: running this too
///         early reverts with `TimelockUnexpectedOperationState`.
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
        address usdcOracle = vm.parseJsonAddress(json, ".usdcOracle");
        address usdc = vm.parseJsonAddress(json, ".usdc");
        address keeper = vm.parseJsonAddress(json, ".keeper");
        bytes32 aaveKey = vm.parseJsonBytes32(json, ".aaveKey");
        uint256 earliest = vm.parseJsonUint(json, ".earliestExecuteTimestamp");

        // Fail-fast if the operator calls execute too early. The
        // TimelockController would revert anyway, but a pre-flight check
        // gives a clearer error message.
        require(
            block.timestamp >= earliest,
            string.concat(
                "ExecuteTestnetTimelockV2: delay not elapsed. Earliest=",
                vm.toString(earliest),
                " now=",
                vm.toString(block.timestamp)
            )
        );

        TimelockController timelock = TimelockController(payable(timelockAddr));
        SepehrCore core = SepehrCore(coreAddr);

        bytes memory dataAddAdapter = abi.encodeWithSignature("addAdapter(bytes32,address)", aaveKey, aaveAdapter);
        bytes memory dataAddKeeper = abi.encodeWithSignature("addKeeper(address)", keeper);
        bytes memory dataAddFlash = abi.encodeWithSignature("addFlashLoanProvider(address)", aaveFlash);
        bytes memory dataSetOracle =
            abi.encodeWithSignature("setAssetOracle(address,address,uint256)", usdc, usdcOracle, ORACLE_STALENESS);

        vm.startBroadcast(deployer);

        timelock.execute(address(core), 0, dataAddAdapter, bytes32(0), bytes32(0));
        timelock.execute(address(core), 0, dataAddKeeper, bytes32(0), bytes32(0));
        timelock.execute(address(core), 0, dataAddFlash, bytes32(0), bytes32(0));
        timelock.execute(address(core), 0, dataSetOracle, bytes32(0), bytes32(0));

        vm.stopBroadcast();

        // ─── Post-execute sanity ─────────────────────────────────

        (IProtocolAdapter registered, bool enabled,) = core.adapters(aaveKey);
        require(address(registered) == aaveAdapter, "execute: adapter mismatch");
        require(enabled, "execute: adapter disabled");
        require(core.keepers(keeper), "execute: keeper not set");
        require(core.allowedFlashProviders(aaveFlash), "execute: flash provider not set");

        (bool ok, bytes memory ret) = address(core).staticcall(abi.encodeWithSignature("assetOracles(address)", usdc));
        require(ok, "execute: oracle getter failed");
        (address aggr, uint256 maxStale) = abi.decode(ret, (address, uint256));
        require(aggr == usdcOracle, "execute: oracle mismatch");
        require(maxStale == ORACLE_STALENESS, "execute: staleness mismatch");

        console.log("TESTNET_V2_EXECUTE_COMPLETE");
    }
}
