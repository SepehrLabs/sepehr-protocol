// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script, console} from "forge-std/Script.sol";

import {SepehrCore} from "../src/SepehrCore.sol";
import {AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {AaveFlashLoanProvider} from "../src/flash/AaveFlashLoanProvider.sol";
import {MockChainlinkAggregator} from "../test/helpers/MockChainlinkAggregator.sol";

/// @title DeployTestnetArbitrumSepoliaV2
/// @notice Bloc 5.1 testnet dry-run on Arbitrum Sepolia (chainId
///         421614) with a **5-minute timelock delay**. Splits the old
///         schedule+execute flow in two: this script only *schedules*
///         the admin ops; `ExecuteTestnetTimelockV2.s.sol` runs after
///         the delay elapses.
///
///         Uses OZ `TimelockController` directly with `minDelay = 300`
///         because `SepehrTimelock.MIN_DELAY = 48 hours` is hardcoded
///         and cannot be lowered for testnet. Mainnet keeps going
///         through `SepehrTimelock` — this is a documented deviation
///         (see `docs/testnet/arbitrum-sepolia-quickstart.md` §1).
///
/// Required env (same set as Bloc 5 script + nothing new):
///   DEPLOYER_ADDRESS, SEPEHR_OWNER, SEPEHR_PAUSE_GUARDIAN,
///   KEEPER_ADDRESS, USDC_ADDRESS, AAVE_POOL, AAVE_ATOKEN,
///   PROTOCOL_KEY_AAVE
///
/// Optional env (carried over from V1):
///   SEPEHR_MIN_COLLATERAL_USD (default 0),
///   SEPEHR_TVL_CAP_USD (default type(uint256).max),
///   WETH_ADDRESS (unused in V2 — WETH oracle omitted for now),
///   MOCK_ETH_PRICE_USD_8 (default $3000 * 1e8),
///   MOCK_USDC_PRICE_USD_8 (default $1 * 1e8)
///
/// Output: writes `deployments/arbitrum-sepolia-v2.json` with every
/// address + the `earliestExecuteTimestamp` so the execute script can
/// guard against running too early.
contract DeployTestnetArbitrumSepoliaV2 is Script {
    uint256 internal constant ARBITRUM_SEPOLIA_CHAIN_ID = 421_614;
    uint256 internal constant TESTNET_TIMELOCK_DELAY = 300; // 5 min
    uint256 internal constant ORACLE_STALENESS = 86_400; // 1 day (MAX_ORACLE_STALENESS)

    function run() external {
        require(
            block.chainid == ARBITRUM_SEPOLIA_CHAIN_ID, "DeployTestnetArbitrumSepoliaV2: wrong chain (expected 421614)"
        );

        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address owner = vm.envAddress("SEPEHR_OWNER");
        address pauseGuardian = vm.envAddress("SEPEHR_PAUSE_GUARDIAN");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address aavePool = vm.envAddress("AAVE_POOL");
        address aToken = vm.envAddress("AAVE_ATOKEN");
        address keeper = vm.envAddress("KEEPER_ADDRESS");
        bytes32 aaveKey = vm.envBytes32("PROTOCOL_KEY_AAVE");

        uint256 minCollateralUsd = vm.envOr("SEPEHR_MIN_COLLATERAL_USD", uint256(0));
        uint256 tvlCapUsd = vm.envOr("SEPEHR_TVL_CAP_USD", type(uint256).max);

        // ─── Deploy contracts ────────────────────────────────────

        vm.startBroadcast(deployer);

        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = deployer;
        TimelockController timelock = new TimelockController(TESTNET_TIMELOCK_DELAY, proposers, executors, address(0));
        console.log("TIMELOCK", address(timelock));

        SepehrCore core =
            new SepehrCore(owner, address(timelock), pauseGuardian, usdc, minCollateralUsd, tvlCapUsd, block.chainid);
        console.log("CORE", address(core));

        AaveV3Adapter aaveAdapter = new AaveV3Adapter(aavePool, aToken, address(core));
        console.log("ADAPTER_AAVE_V3", address(aaveAdapter));

        AaveFlashLoanProvider aaveFlash = new AaveFlashLoanProvider(aavePool, address(timelock));
        console.log("FLASH_AAVE", address(aaveFlash));

        uint256 ethPrice = vm.envOr("MOCK_ETH_PRICE_USD_8", uint256(300_000_000_000));
        uint256 usdcPrice = vm.envOr("MOCK_USDC_PRICE_USD_8", uint256(100_000_000));
        MockChainlinkAggregator ethOracle = new MockChainlinkAggregator(8, int256(ethPrice));
        MockChainlinkAggregator usdcOracle = new MockChainlinkAggregator(8, int256(usdcPrice));
        console.log("MOCK_ETH_ORACLE", address(ethOracle));
        console.log("MOCK_USDC_ORACLE", address(usdcOracle));

        // ─── Schedule admin ops ──────────────────────────────────
        // Delay = 300s. Execute script will run these same calls after
        // the delay elapses. All ops share (predecessor=0, salt=0) so
        // their IDs are deterministic from (target, data).
        bytes memory dataAddAdapter =
            abi.encodeWithSignature("addAdapter(bytes32,address)", aaveKey, address(aaveAdapter));
        bytes memory dataAddKeeper = abi.encodeWithSignature("addKeeper(address)", keeper);
        bytes memory dataAddFlash = abi.encodeWithSignature("addFlashLoanProvider(address)", address(aaveFlash));
        bytes memory dataSetOracle = abi.encodeWithSignature(
            "setAssetOracle(address,address,uint256)", usdc, address(usdcOracle), ORACLE_STALENESS
        );

        timelock.schedule(address(core), 0, dataAddAdapter, bytes32(0), bytes32(0), TESTNET_TIMELOCK_DELAY);
        timelock.schedule(address(core), 0, dataAddKeeper, bytes32(0), bytes32(0), TESTNET_TIMELOCK_DELAY);
        timelock.schedule(address(core), 0, dataAddFlash, bytes32(0), bytes32(0), TESTNET_TIMELOCK_DELAY);
        timelock.schedule(address(core), 0, dataSetOracle, bytes32(0), bytes32(0), TESTNET_TIMELOCK_DELAY);

        vm.stopBroadcast();

        uint256 earliest = block.timestamp + TESTNET_TIMELOCK_DELAY;
        console.log("EARLIEST_EXECUTE_TIMESTAMP", earliest);
        console.log("SCHEDULE_BLOCK", block.number);

        // ─── Persist JSON for ExecuteTimelockV2 ──────────────────
        string memory key = "deploy";
        vm.serializeAddress(key, "timelock", address(timelock));
        vm.serializeAddress(key, "core", address(core));
        vm.serializeAddress(key, "aaveAdapter", address(aaveAdapter));
        vm.serializeAddress(key, "aaveFlash", address(aaveFlash));
        vm.serializeAddress(key, "ethOracle", address(ethOracle));
        vm.serializeAddress(key, "usdcOracle", address(usdcOracle));
        vm.serializeAddress(key, "usdc", usdc);
        vm.serializeAddress(key, "keeper", keeper);
        vm.serializeBytes32(key, "aaveKey", aaveKey);
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeUint(key, "scheduleBlock", block.number);
        vm.serializeUint(key, "earliestExecuteTimestamp", earliest);
        string memory finalJson = vm.serializeUint(key, "timelockDelaySeconds", TESTNET_TIMELOCK_DELAY);
        vm.writeJson(finalJson, "deployments/arbitrum-sepolia-v2.json");

        console.log("TESTNET_V2_SCHEDULE_COMPLETE");
    }
}
