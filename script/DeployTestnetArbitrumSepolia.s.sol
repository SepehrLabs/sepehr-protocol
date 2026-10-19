// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script, console} from "forge-std/Script.sol";

import {SepehrCore} from "../src/SepehrCore.sol";
import {SepehrSubscriptions} from "../src/SepehrSubscriptions.sol";
import {AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {AaveFlashLoanProvider} from "../src/flash/AaveFlashLoanProvider.sol";
import {MockChainlinkAggregator} from "../test/helpers/MockChainlinkAggregator.sol";

/// @title DeployTestnetArbitrumSepolia
/// @notice Public dry-run deploy on Arbitrum Sepolia (chainId 421614).
///         Reuses the `E2ELocalDeploy` pattern: OZ `TimelockController`
///         with delay 0 so adapter/keeper/oracle registration is inline.
///
///         **TESTNET ONLY** — mainnet deploys MUST use `DeployCore.s.sol`
///         with `SepehrTimelock` (48h hardcoded floor). The deviations
///         (zero-delay timelock, owner = pause guardian = deployer, mock
///         oracles) are listed in `docs/testnet/arbitrum-sepolia-quickstart.md`.
///
/// Required env (all 0x-prefixed):
///   DEPLOYER_ADDRESS        — EOA signing the broadcast
///   SEPEHR_OWNER            — protocol owner (usually = deployer on testnet)
///   SEPEHR_PAUSE_GUARDIAN   — pause guardian (usually = deployer on testnet)
///   USDC_ADDRESS            — Circle USDC testnet (0x75faf114...)
///   AAVE_POOL               — Aave V3 pool (0xBfC91D59...)
///   PROTOCOL_KEY_AAVE       — bytes32 registry key for the Aave entry
///   KEEPER_ADDRESS          — keeper to whitelist
///
/// Optional env:
///   SEPEHR_MIN_COLLATERAL_USD  — default 0 (no floor on testnet)
///   SEPEHR_TVL_CAP_USD         — default type(uint256).max (no cap on testnet)
///   WETH_ADDRESS               — if set, enable oracle for WETH
///   MOCK_ETH_PRICE_USD_8       — price for mock ETH oracle (default $3000)
///   MOCK_USDC_PRICE_USD_8      — price for mock USDC oracle (default $1)
contract DeployTestnetArbitrumSepolia is Script {
    uint256 internal constant ARBITRUM_SEPOLIA_CHAIN_ID = 421_614;

    function run() external {
        require(
            block.chainid == ARBITRUM_SEPOLIA_CHAIN_ID, "DeployTestnetArbitrumSepolia: wrong chain (expected 421614)"
        );

        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address owner = vm.envAddress("SEPEHR_OWNER");
        address pauseGuardian = vm.envAddress("SEPEHR_PAUSE_GUARDIAN");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address aavePool = vm.envAddress("AAVE_POOL");
        address keeper = vm.envAddress("KEEPER_ADDRESS");
        bytes32 aaveKey = vm.envBytes32("PROTOCOL_KEY_AAVE");

        uint256 minCollateralUsd = vm.envOr("SEPEHR_MIN_COLLATERAL_USD", uint256(0));
        uint256 tvlCapUsd = vm.envOr("SEPEHR_TVL_CAP_USD", type(uint256).max);

        vm.startBroadcast(deployer);

        // 1. Zero-delay timelock — deployer is both proposer and executor,
        //    admin = address(0) so the timelock is self-administered.
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = deployer;
        TimelockController timelock = new TimelockController(0, proposers, executors, address(0));
        console.log("TIMELOCK", address(timelock));

        // 2. Core: owner is the env-provided EOA, timelock is the fresh OZ
        //    TimelockController above. expectedChainId is block.chainid so the
        //    contract locks itself to Arbitrum Sepolia at construction.
        SepehrSubscriptions subscriptions = new SepehrSubscriptions(
            owner, address(timelock), usdc, block.chainid, vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1)
        );
        console.log("SUBSCRIPTIONS", address(subscriptions));
        SepehrCore core = new SepehrCore(
            owner, address(timelock), pauseGuardian, address(subscriptions), minCollateralUsd, tvlCapUsd, block.chainid
        );
        console.log("CORE", address(core));

        // 3. Aave V3 adapter on the real Sepolia pool (any of its collaterals).
        AaveV3Adapter aaveAdapter = new AaveV3Adapter(aavePool, address(core));
        console.log("ADAPTER_AAVE_V3", address(aaveAdapter));

        // 4. Aave flash loan provider — timelock-owned so the ownership
        //    surface matches production even in testnet.
        AaveFlashLoanProvider aaveFlash = new AaveFlashLoanProvider(aavePool, address(timelock));
        console.log("FLASH_AAVE", address(aaveFlash));

        // 5. Mock Chainlink oracles (static prices). The Subscribe Shield
        //    testnet flow doesn't read oracles, but a mock USDC/ETH pair lets
        //    tier-cap pre-flight succeed once a position is opened. Mainnet
        //    uses Chainlink feeds — documented deviation.
        uint256 ethPrice = vm.envOr("MOCK_ETH_PRICE_USD_8", uint256(300_000_000_000)); // $3000 * 1e8
        uint256 usdcPrice = vm.envOr("MOCK_USDC_PRICE_USD_8", uint256(100_000_000)); // $1 * 1e8
        MockChainlinkAggregator ethOracle = new MockChainlinkAggregator(8, int256(ethPrice));
        MockChainlinkAggregator usdcOracle = new MockChainlinkAggregator(8, int256(usdcPrice));
        console.log("MOCK_ETH_ORACLE", address(ethOracle));
        console.log("MOCK_USDC_ORACLE", address(usdcOracle));

        vm.stopBroadcast();

        // 6. Timelock-gated admin ops, executed inline via schedule+execute.
        _tlExec(
            deployer,
            timelock,
            address(core),
            abi.encodeWithSignature("addAdapter(bytes32,address)", aaveKey, address(aaveAdapter))
        );
        _tlExec(deployer, timelock, address(core), abi.encodeWithSignature("addKeeper(address)", keeper));
        _tlExec(
            deployer,
            timelock,
            address(core),
            abi.encodeWithSignature("addFlashLoanProvider(address)", address(aaveFlash))
        );
        _tlExec(
            deployer,
            timelock,
            address(core),
            abi.encodeWithSignature(
                "setAssetOracle(address,address,uint256)", usdc, address(usdcOracle), uint256(86_400)
            )
        );

        address weth = vm.envOr("WETH_ADDRESS", address(0));
        if (weth != address(0)) {
            _tlExec(
                deployer,
                timelock,
                address(core),
                abi.encodeWithSignature(
                    "setAssetOracle(address,address,uint256)", weth, address(ethOracle), uint256(86_400)
                )
            );
        }

        console.log("TESTNET_DEPLOY_COMPLETE");
    }

    function _tlExec(
        address sender,
        TimelockController tl,
        address target,
        bytes memory data
    ) internal {
        vm.startBroadcast(sender);
        tl.schedule(target, 0, data, bytes32(0), bytes32(0), 0);
        tl.execute(target, 0, data, bytes32(0), bytes32(0));
        vm.stopBroadcast();
    }
}
