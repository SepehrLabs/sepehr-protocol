// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {SepehrCore} from "../src/SepehrCore.sol";
import {SepehrSubscriptions} from "../src/SepehrSubscriptions.sol";
import {AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {CompoundV3Adapter} from "../src/adapters/CompoundV3Adapter.sol";
import {AggregatorRouter} from "../src/dex/AggregatorRouter.sol";
import {AggregatorSelectors} from "../src/dex/AggregatorSelectors.sol";
import {UniswapV3Router} from "../src/dex/UniswapV3Router.sol";
import {AaveFlashLoanProvider} from "../src/flash/AaveFlashLoanProvider.sol";
import {MorphoBlueFlashLoanProvider} from "../src/flash/MorphoBlueFlashLoanProvider.sol";
import {MockChainlinkAggregator} from "../test/helpers/MockChainlinkAggregator.sol";

/// @notice Arbitrum One fork deployment for the swap-route acceptance test (the
/// `test:keeper-fork` script of the e2e workspace). Deploys the real SepehrCore with an
/// AaveV3Adapter (every Aave collateral) and a CompoundV3Adapter, the Morpho Blue and Aave flash
/// loan providers and the Uniswap V3 router, all on top of the forked protocols. SepehrCore
/// prices assets through settable mock feeds, which the test also hands to the lending
/// protocols, so that one answer moves both. Prints `LABEL 0x…` lines.
///
/// NEVER use outside a disposable Anvil fork: the deployer EOA plays the timelock.
///
/// Required env: DEPLOYER_ADDRESS, KEEPER_ADDRESS, AAVE_POOL, AAVE_KEY, COMPOUND_COMET,
/// COMPOUND_KEY (protocol key names), MORPHO_BLUE, UNIV3_SWAP_ROUTER, UNIV3_FACTORY,
/// USDC_ADDRESS, and the comma-separated ORACLE_ASSETS with ORACLE_PRICES (8 decimals).
/// Optional: KYBERSWAP_ROUTER and VELORA_AUGUSTUS deploy and whitelist their AggregatorRouters.
contract E2ESwapRoutesForkDeploy is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address aavePool = vm.envAddress("AAVE_POOL");
        address[] memory oracleAssets = vm.envAddress("ORACLE_ASSETS", ",");
        uint256[] memory prices = vm.envUint("ORACLE_PRICES", ",");
        require(prices.length == oracleAssets.length, "lists differ in length");

        vm.startBroadcast(deployer);

        SepehrSubscriptions subscriptions = new SepehrSubscriptions(
            deployer,
            deployer,
            vm.envAddress("USDC_ADDRESS"),
            block.chainid,
            vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1)
        );
        SepehrCore core =
            new SepehrCore(deployer, deployer, deployer, address(subscriptions), 0, type(uint256).max, block.chainid);
        console.log("SUBSCRIPTIONS", address(subscriptions));
        core.addKeeper(vm.envAddress("KEEPER_ADDRESS"));
        console.log("CORE", address(core));

        for (uint256 i = 0; i < oracleAssets.length; i++) {
            MockChainlinkAggregator feed = new MockChainlinkAggregator(8, int256(prices[i]));
            core.setAssetOracle(oracleAssets[i], address(feed), 86_400);
            console.log(string.concat("FEED_", vm.toString(i)), address(feed));
        }

        AaveV3Adapter aave = new AaveV3Adapter(aavePool, address(core));
        core.addAdapter(keccak256(bytes(vm.envString("AAVE_KEY"))), address(aave));
        console.log("AAVE_ADAPTER", address(aave));

        CompoundV3Adapter compound = new CompoundV3Adapter(vm.envAddress("COMPOUND_COMET"), address(core));
        core.addAdapter(keccak256(bytes(vm.envString("COMPOUND_KEY"))), address(compound));
        console.log("COMPOUND_ADAPTER", address(compound));

        MorphoBlueFlashLoanProvider morphoFlash =
            new MorphoBlueFlashLoanProvider(vm.envAddress("MORPHO_BLUE"), deployer);
        AaveFlashLoanProvider aaveFlash = new AaveFlashLoanProvider(aavePool, deployer);
        core.addFlashLoanProvider(address(morphoFlash));
        core.addFlashLoanProvider(address(aaveFlash));
        console.log("FLASH_MORPHO", address(morphoFlash));
        console.log("FLASH_AAVE", address(aaveFlash));

        UniswapV3Router router =
            new UniswapV3Router(vm.envAddress("UNIV3_SWAP_ROUTER"), vm.envAddress("UNIV3_FACTORY"), 500);
        core.addDexRouter(address(router));
        console.log("DEX_ROUTER", address(router));

        // Lot 7, optional: the KyberSwap and Velora routers, for a fork at the latest block (the
        // aggregators' APIs quote the live chain).
        address kyberSwap = vm.envOr("KYBERSWAP_ROUTER", address(0));
        if (kyberSwap != address(0)) {
            AggregatorRouter kyber = new AggregatorRouter(kyberSwap, kyberSwap, AggregatorSelectors.kyberSwap());
            core.addDexRouter(address(kyber));
            console.log("KYBER_ROUTER", address(kyber));
        }
        address velora = vm.envOr("VELORA_AUGUSTUS", address(0));
        if (velora != address(0)) {
            AggregatorRouter veloraRouter = new AggregatorRouter(velora, velora, AggregatorSelectors.velora());
            core.addDexRouter(address(veloraRouter));
            console.log("VELORA_ROUTER", address(veloraRouter));
        }

        vm.stopBroadcast();
    }
}
