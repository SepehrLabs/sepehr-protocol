// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {SepehrCore} from "../src/SepehrCore.sol";
import {MorphoBlueAdapter} from "../src/adapters/MorphoBlueAdapter.sol";
import {UniswapV3Router} from "../src/dex/UniswapV3Router.sol";
import {AaveFlashLoanProvider} from "../src/flash/AaveFlashLoanProvider.sol";
import {IMorpho} from "../src/interfaces/external/IMorpho.sol";
import {MockAavePool} from "../test/helpers/MockAavePool.sol";
import {MockChainlinkAggregator} from "../test/helpers/MockChainlinkAggregator.sol";
import {MockTokenDecimals} from "../test/helpers/MockTokenDecimals.sol";
import {MockV3Factory} from "../test/helpers/MockV3Factory.sol";
import {MockV3SwapRouter} from "../test/helpers/MockV3SwapRouter.sol";
import {MorphoLike, MorphoLikeOracle} from "../test/helpers/MorphoLike.sol";
import {Multicall3Lite} from "../test/helpers/Multicall3Lite.sol";

/// @notice Local (no fork) deployment for the keeper acceptance test
/// (the `test:keeper-local` script of the e2e workspace). Deploys the real SepehrCore,
/// MorphoBlueAdapter, AaveFlashLoanProvider and UniswapV3Router on top of
/// accounting-faithful mocks, registers them, and prints `LABEL 0x…` lines.
///
/// NEVER use outside a disposable Anvil: the deployer EOA plays the timelock.
///
/// Required env: DEPLOYER_ADDRESS (anvil account 0), KEEPER_ADDRESS (anvil account 1).
contract E2EKeeperLocalDeploy is Script {
    bytes32 internal constant MORPHO_KEY = keccak256("morpho-blue-arbitrum");
    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant ETH_USD_8 = 3300e8;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address keeper = vm.envAddress("KEEPER_ADDRESS");
        console.log("START_BLOCK", block.number);

        vm.startBroadcast(deployer);

        MockTokenDecimals usdc = new MockTokenDecimals("USD Coin", "USDC", 6);
        MockTokenDecimals weth = new MockTokenDecimals("Wrapped Ether", "WETH", 18);

        MorphoLike morpho = new MorphoLike();
        MorphoLikeOracle morphoOracle = new MorphoLikeOracle();
        morphoOracle.setPrice(ETH_USD_8 * 1e16);
        bytes32 marketId = morpho.createMarket(
            IMorpho.MarketParams({
                loanToken: address(usdc),
                collateralToken: address(weth),
                oracle: address(morphoOracle),
                // MorphoLike accrues no interest: no IRM, which the adapter reads as a flat rate.
                irm: address(0),
                lltv: LLTV
            })
        );

        SepehrCore core =
            new SepehrCore(deployer, deployer, deployer, address(usdc), 0, type(uint256).max, block.chainid);
        MockChainlinkAggregator usdcFeed = new MockChainlinkAggregator(8, 1e8);
        MorphoBlueAdapter adapter = new MorphoBlueAdapter(address(morpho), marketId, address(usdcFeed), address(core));

        MockAavePool flashPool = new MockAavePool();
        AaveFlashLoanProvider flash = new AaveFlashLoanProvider(address(flashPool), deployer);

        MockV3SwapRouter swapRouter = new MockV3SwapRouter();
        // USDC (6 decimals) per WETH, minus a 0.05 % pool fee.
        swapRouter.setExchangeRate(ETH_USD_8 / 100 * 9995 / 10_000);
        UniswapV3Router router = new UniswapV3Router(address(swapRouter), address(new MockV3Factory()), 500);

        MockChainlinkAggregator ethFeed = new MockChainlinkAggregator(8, int256(ETH_USD_8));
        Multicall3Lite multicall = new Multicall3Lite();

        core.addAdapter(MORPHO_KEY, address(adapter));
        core.addKeeper(keeper);
        core.addFlashLoanProvider(address(flash));
        core.addDexRouter(address(router));
        core.setAssetOracle(address(weth), address(ethFeed), 3600);
        core.setAssetOracle(address(usdc), address(usdcFeed), 86_400);

        usdc.mint(address(morpho), 10_000_000e6);
        usdc.mint(address(flashPool), 10_000_000e6);
        usdc.mint(address(swapRouter), 10_000_000e6);

        vm.stopBroadcast();

        console.log("CORE", address(core));
        console.log("ADAPTER", address(adapter));
        console.log("MORPHO", address(morpho));
        console.log("MORPHO_ORACLE", address(morphoOracle));
        console.log("USDC", address(usdc));
        console.log("WETH", address(weth));
        console.log("FLASH", address(flash));
        console.log("DEX_ROUTER", address(router));
        console.log("SWAP_ROUTER", address(swapRouter));
        console.log("ETH_FEED", address(ethFeed));
        console.log("USDC_FEED", address(usdcFeed));
        console.log("MULTICALL", address(multicall));
    }
}
