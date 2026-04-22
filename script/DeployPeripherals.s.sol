// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {SepehrCore} from "../src/SepehrCore.sol";
import {AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {CompoundV3Adapter} from "../src/adapters/CompoundV3Adapter.sol";
import {CamelotRouter} from "../src/dex/CamelotRouter.sol";
import {TraderJoeV22Router} from "../src/dex/TraderJoeV22Router.sol";
import {UniV2ForkRouter} from "../src/dex/UniV2ForkRouter.sol";
import {UniswapV3Router} from "../src/dex/UniswapV3Router.sol";
import {VelodromeRouter} from "../src/dex/VelodromeRouter.sol";
import {AaveFlashLoanProvider} from "../src/flash/AaveFlashLoanProvider.sol";
import {BalancerFlashLoanProvider} from "../src/flash/BalancerFlashLoanProvider.sol";
import {UniswapV3FlashLoanProvider} from "../src/flash/UniswapV3FlashLoanProvider.sol";

contract DeployPeripherals is Script {
    /// @notice Arbitrum One.
    uint256 internal constant ARBITRUM_ONE_CHAIN_ID = 42_161;
    /// @notice Arbitrum Sepolia (public testnet).
    uint256 internal constant ARBITRUM_SEPOLIA_CHAIN_ID = 421_614;

    function run() external {
        // ADR-0011: V1 is a mono-Arbitrum deploy. Peripherals (adapters, flash providers,
        // DEX routers) are intentionally generic — they compile and run on every supported
        // chain so we keep audit coverage on them — but the *deploy script* still refuses
        // any target other than Arbitrum One or Sepolia. Pairing peripherals with a core
        // on the wrong chain would produce a half-alive system that can't be executed
        // against.
        require(
            block.chainid == ARBITRUM_ONE_CHAIN_ID || block.chainid == ARBITRUM_SEPOLIA_CHAIN_ID,
            "DeployPeripherals: only Arbitrum One or Arbitrum Sepolia"
        );

        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address coreAddr = vm.envAddress("SEPEHR_CORE");

        vm.startBroadcast(deployer);

        _deployFlashProviders();
        _deployDexRouters();
        _deployAdapters();

        vm.stopBroadcast();

        console.log("Peripherals deployed. Register them via SepehrTimelock on core:", coreAddr);
    }

    function _deployFlashProviders() internal {
        // C10: flash providers expose an owner-gated `sweep` for accidentally-donated
        // tokens. The timelock (via SEPEHR_OWNER) owns them; deployer is never owner.
        address owner = vm.envAddress("SEPEHR_OWNER");

        address aavePool = vm.envOr("AAVE_POOL", address(0));
        if (aavePool != address(0)) {
            AaveFlashLoanProvider aaveFlash = new AaveFlashLoanProvider(aavePool, owner);
            console.log("AaveFlashLoanProvider:", address(aaveFlash));
        }

        address balancerVault = vm.envOr("BALANCER_VAULT", address(0));
        if (balancerVault != address(0)) {
            BalancerFlashLoanProvider balancerFlash = new BalancerFlashLoanProvider(balancerVault, owner);
            console.log("BalancerFlashLoanProvider:", address(balancerFlash));
        }

        address uniV3Pool = vm.envOr("UNIV3_FLASH_POOL", address(0));
        if (uniV3Pool != address(0)) {
            UniswapV3FlashLoanProvider uniFlash = new UniswapV3FlashLoanProvider(uniV3Pool, owner);
            console.log("UniswapV3FlashLoanProvider:", address(uniFlash));
        }
    }

    function _deployDexRouters() internal {
        address uniV3SwapRouter = vm.envOr("UNIV3_SWAP_ROUTER", address(0));
        address uniV3Factory = vm.envOr("UNIV3_FACTORY", address(0));
        if (uniV3SwapRouter != address(0) && uniV3Factory != address(0)) {
            uint24 defaultFee = uint24(vm.envOr("UNIV3_DEFAULT_FEE", uint256(3000)));
            UniswapV3Router v3Router = new UniswapV3Router(uniV3SwapRouter, uniV3Factory, defaultFee);
            console.log("UniswapV3Router:", address(v3Router));
        }

        address uniV2Router = vm.envOr("UNIV2_ROUTER", address(0));
        if (uniV2Router != address(0)) {
            UniV2ForkRouter v2Router = new UniV2ForkRouter(uniV2Router);
            console.log("UniV2ForkRouter:", address(v2Router));
        }

        address veloRouter = vm.envOr("VELODROME_ROUTER", address(0));
        address veloFactory = vm.envOr("VELODROME_FACTORY", address(0));
        if (veloRouter != address(0) && veloFactory != address(0)) {
            bool defaultStable = vm.envOr("VELODROME_DEFAULT_STABLE", false);
            VelodromeRouter vRouter = new VelodromeRouter(veloRouter, veloFactory, defaultStable);
            console.log("VelodromeRouter:", address(vRouter));
        }

        address camelotRouter = vm.envOr("CAMELOT_ROUTER", address(0));
        if (camelotRouter != address(0)) {
            address referrer = vm.envOr("CAMELOT_REFERRER", address(0));
            CamelotRouter cRouter = new CamelotRouter(camelotRouter, referrer);
            console.log("CamelotRouter:", address(cRouter));
        }

        address tjRouter = vm.envOr("TRADERJOE_ROUTER", address(0));
        address tjFactory = vm.envOr("TRADERJOE_FACTORY", address(0));
        if (tjRouter != address(0) && tjFactory != address(0)) {
            uint256 defaultBinStep = vm.envOr("TRADERJOE_DEFAULT_BIN_STEP", uint256(20));
            TraderJoeV22Router tjR = new TraderJoeV22Router(tjRouter, tjFactory, defaultBinStep);
            console.log("TraderJoeV22Router:", address(tjR));
        }
    }

    function _deployAdapters() internal {
        address coreAddr = vm.envAddress("SEPEHR_CORE");

        address aavePool = vm.envOr("AAVE_POOL", address(0));
        address aToken = vm.envOr("AAVE_ATOKEN", address(0));
        if (aavePool != address(0) && aToken != address(0)) {
            AaveV3Adapter aaveAdapter = new AaveV3Adapter(aavePool, aToken, coreAddr);
            console.log("AaveV3Adapter:", address(aaveAdapter));
        }

        address comet = vm.envOr("COMPOUND_V3_COMET", address(0));
        if (comet != address(0)) {
            CompoundV3Adapter compAdapter = new CompoundV3Adapter(comet, coreAddr);
            console.log("CompoundV3Adapter:", address(compAdapter));
        }
    }
}
