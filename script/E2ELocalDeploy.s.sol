// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script, console} from "forge-std/Script.sol";

import {SepehrCore} from "../src/SepehrCore.sol";
import {AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {CompoundV3Adapter} from "../src/adapters/CompoundV3Adapter.sol";
import {UniswapV3Router} from "../src/dex/UniswapV3Router.sol";
import {AaveFlashLoanProvider} from "../src/flash/AaveFlashLoanProvider.sol";
import {BalancerFlashLoanProvider} from "../src/flash/BalancerFlashLoanProvider.sol";
import {UniswapV3FlashLoanProvider} from "../src/flash/UniswapV3FlashLoanProvider.sol";
import {MockChainlinkAggregator} from "../test/helpers/MockChainlinkAggregator.sol";

/// @notice End-to-end test deployment. Deploys with a zero-delay timelock so
/// adapter / keeper / flash / router / oracle registration happens inline.
///
/// NEVER use for mainnet or testnet — production deploys MUST use the 48h
/// timelock from `DeployCore.s.sol` per `docs/audits/DEPLOYMENT-POLICY.md`.
///
/// Required env (all addresses 0x-prefixed):
///   DEPLOYER_ADDRESS    — anvil account 0
///   KEEPER_ADDRESS      — keeper to whitelist (usually the same as deployer)
///   USDC_ADDRESS        — canonical USDC on the forked chain
///   WETH_ADDRESS        — canonical WETH on the forked chain
///   AAVE_POOL           — Aave v3 pool
///   AAVE_ATOKEN         — any aToken (used for adapter construction)
///   PROTOCOL_KEY_AAVE   — bytes32 protocol key for the Aave adapter registry entry
///
/// Optional (each one gated — absent = skip):
///   COMPOUND_V3_COMET   — Compound v3 USDC comet
///   PROTOCOL_KEY_COMP   — bytes32 key for the Compound adapter entry
///   BALANCER_VAULT      — Balancer vault address
///   UNIV3_FLASH_POOL    — concrete Uniswap v3 pool used as flash source
///   UNIV3_SWAP_ROUTER   — Uniswap v3 SwapRouter
///   UNIV3_FACTORY       — Uniswap v3 factory
contract E2ELocalDeploy is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address keeper = vm.envAddress("KEEPER_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address weth = vm.envAddress("WETH_ADDRESS");

        vm.startBroadcast(deployer);

        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = deployer;
        TimelockController timelock = new TimelockController(0, proposers, executors, address(0));
        SepehrCore core =
            new SepehrCore(deployer, address(timelock), deployer, usdc, 0, type(uint256).max, block.chainid);
        console.log("TIMELOCK", address(timelock));
        console.log("CORE", address(core));

        MockChainlinkAggregator ethOracle = new MockChainlinkAggregator(8, 300_000_000_000);
        MockChainlinkAggregator btcOracle = new MockChainlinkAggregator(8, 6_500_000_000_000);
        MockChainlinkAggregator usdcOracle = new MockChainlinkAggregator(8, 100_000_000);
        console.log("MOCK_ETH_ORACLE", address(ethOracle));
        console.log("MOCK_BTC_ORACLE", address(btcOracle));
        console.log("MOCK_USDC_ORACLE", address(usdcOracle));

        address aavePool = vm.envAddress("AAVE_POOL");
        address aToken = vm.envAddress("AAVE_ATOKEN");
        AaveV3Adapter aaveAdapter = new AaveV3Adapter(aavePool, aToken, address(core));
        AaveFlashLoanProvider aaveFlash = new AaveFlashLoanProvider(aavePool, address(timelock));
        console.log("ADAPTER_AAVE_V3", address(aaveAdapter));
        console.log("FLASH_AAVE", address(aaveFlash));

        address compAdapter;
        {
            address comet = vm.envOr("COMPOUND_V3_COMET", address(0));
            if (comet != address(0)) {
                compAdapter = address(new CompoundV3Adapter(comet, address(core)));
                console.log("ADAPTER_COMPOUND_V3", compAdapter);
            }
        }

        address balFlash;
        {
            address balVault = vm.envOr("BALANCER_VAULT", address(0));
            if (balVault != address(0)) {
                balFlash = address(new BalancerFlashLoanProvider(balVault, address(timelock)));
                console.log("FLASH_BALANCER", balFlash);
            }
        }

        address univ3Flash;
        {
            address univ3Pool = vm.envOr("UNIV3_FLASH_POOL", address(0));
            if (univ3Pool != address(0)) {
                univ3Flash = address(new UniswapV3FlashLoanProvider(univ3Pool, address(timelock)));
                console.log("FLASH_UNI_V3", univ3Flash);
            }
        }

        address univ3Router;
        {
            address swapRouter = vm.envOr("UNIV3_SWAP_ROUTER", address(0));
            address factory = vm.envOr("UNIV3_FACTORY", address(0));
            if (swapRouter != address(0) && factory != address(0)) {
                univ3Router = address(new UniswapV3Router(swapRouter, factory, uint24(3000)));
                console.log("DEX_UNI_V3", univ3Router);
            }
        }

        vm.stopBroadcast();

        bytes32 aaveKey = vm.envBytes32("PROTOCOL_KEY_AAVE");
        _tlExec(
            deployer,
            timelock,
            address(core),
            abi.encodeWithSignature("addAdapter(bytes32,address)", aaveKey, address(aaveAdapter))
        );
        if (compAdapter != address(0)) {
            bytes32 compKey = vm.envBytes32("PROTOCOL_KEY_COMP");
            _tlExec(
                deployer,
                timelock,
                address(core),
                abi.encodeWithSignature("addAdapter(bytes32,address)", compKey, compAdapter)
            );
        }
        _tlExec(deployer, timelock, address(core), abi.encodeWithSignature("addKeeper(address)", keeper));
        _tlExec(
            deployer,
            timelock,
            address(core),
            abi.encodeWithSignature("addFlashLoanProvider(address)", address(aaveFlash))
        );
        if (balFlash != address(0)) {
            _tlExec(
                deployer, timelock, address(core), abi.encodeWithSignature("addFlashLoanProvider(address)", balFlash)
            );
        }
        if (univ3Flash != address(0)) {
            _tlExec(
                deployer, timelock, address(core), abi.encodeWithSignature("addFlashLoanProvider(address)", univ3Flash)
            );
        }
        if (univ3Router != address(0)) {
            _tlExec(deployer, timelock, address(core), abi.encodeWithSignature("addDexRouter(address)", univ3Router));
        }
        _tlExec(
            deployer,
            timelock,
            address(core),
            abi.encodeWithSignature(
                "setAssetOracle(address,address,uint256)", weth, address(ethOracle), uint256(86_400)
            )
        );
        _tlExec(
            deployer,
            timelock,
            address(core),
            abi.encodeWithSignature(
                "setAssetOracle(address,address,uint256)", usdc, address(usdcOracle), uint256(86_400)
            )
        );
        {
            address wbtc = vm.envOr("WBTC_ADDRESS", address(0));
            if (wbtc != address(0)) {
                _tlExec(
                    deployer,
                    timelock,
                    address(core),
                    abi.encodeWithSignature(
                        "setAssetOracle(address,address,uint256)", wbtc, address(btcOracle), uint256(86_400)
                    )
                );
            }
        }

        console.log("E2E_DEPLOY_COMPLETE");
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
