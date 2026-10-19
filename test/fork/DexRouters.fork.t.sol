// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CamelotRouter} from "../../src/dex/CamelotRouter.sol";
import {UniV2ForkRouter} from "../../src/dex/UniV2ForkRouter.sol";
import {UniswapV3Router} from "../../src/dex/UniswapV3Router.sol";
import {ForkTestBase} from "./ForkTestBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IChainlinkFeed {
    function latestAnswer() external view returns (int256);
}

// ═══════════════════════════════════════════════════════════════════════
//  Uniswap V3 Router on Arbitrum One: one route per V1 collateral
// ═══════════════════════════════════════════════════════════════════════

/// @notice The routes the keeper builds for the four V1 collaterals (D2), swapped through the
///         real SwapRouter. WETH and WBTC have deep direct pools; wstETH and ARB only reach USDC
///         through WETH, and their direct pools hold a few hundred dollars.
contract UniswapV3RouterArbitrumForkTest is ForkTestBase {
    address constant SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address constant WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;
    address constant ARB = 0x912CE59144191C1204E64559FE8253a0e49E6548;
    address constant ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address constant WBTC_USD = 0xd0C7101eACbB49F3deCcCc166d238410D6D46d57;
    address constant ARB_USD = 0xb2A824043730FE05F3DA2efaFa1CBbe83fa548D6;

    UniswapV3Router internal router;
    bool internal _forked;
    address internal swapper;

    function setUp() public {
        _forked = _tryCreateFork("RPC_ARBITRUM_PRIMARY_HTTP");
        if (!_forked) return;

        router = new UniswapV3Router(SWAP_ROUTER, FACTORY, 500);
        swapper = makeAddr("swapper");
    }

    function _swap(
        address tokenIn,
        uint256 amountIn,
        bytes memory routeData
    ) internal returns (uint256 amountOut) {
        deal(tokenIn, swapper, amountIn);
        vm.startPrank(swapper);
        IERC20(tokenIn).approve(address(router), amountIn);
        amountOut = router.swap(tokenIn, USDC, amountIn, 0, routeData);
        vm.stopPrank();
    }

    /// @dev USDC (6 decimals) that `amount` (`decimals`) is worth at the Chainlink price (8 decimals).
    function _usdcAt(
        address feed,
        uint256 amount,
        uint8 decimals
    ) internal view returns (uint256) {
        return amount * uint256(IChainlinkFeed(feed).latestAnswer()) / 10 ** (decimals + 2);
    }

    function test_weth_directPoolLandsWithinOnePercentOfChainlink() public {
        if (!_forked) return;
        uint256 out = _swap(WETH, 10 ether, abi.encode(uint24(500)));
        assertGe(out, _usdcAt(ETH_USD, 10 ether, 18) * 99 / 100);
    }

    function test_wbtc_directPoolLandsWithinOnePercentOfChainlink() public {
        if (!_forked) return;
        uint256 out = _swap(WBTC, 0.5e8, abi.encode(uint24(500)));
        assertGe(out, _usdcAt(WBTC_USD, 0.5e8, 8) * 99 / 100);
    }

    function test_arb_pathThroughWethLandsWithinTwoPercentOfChainlink() public {
        if (!_forked) return;
        bytes memory path = abi.encodePacked(ARB, uint24(500), WETH, uint24(500), USDC);
        uint256 out = _swap(ARB, 50_000e18, abi.encode(path));
        assertGe(out, _usdcAt(ARB_USD, 50_000e18, 18) * 98 / 100);
    }

    function test_arb_pathThroughWethBeatsTheDirectPool() public {
        if (!_forked) return;
        uint256 snapshot = vm.snapshotState();
        uint256 direct = _swap(ARB, 50_000e18, abi.encode(uint24(3000)));
        vm.revertToState(snapshot);
        bytes memory path = abi.encodePacked(ARB, uint24(500), WETH, uint24(500), USDC);
        uint256 viaWeth = _swap(ARB, 50_000e18, abi.encode(path));
        assertGt(viaWeth, direct);
    }

    function test_wstEth_pathThroughWethBeatsTheDirectPoolByFar() public {
        if (!_forked) return;
        uint256 snapshot = vm.snapshotState();
        uint256 direct = _swap(WSTETH, 10 ether, abi.encode(uint24(3000)));
        vm.revertToState(snapshot);
        bytes memory path = abi.encodePacked(WSTETH, uint24(100), WETH, uint24(500), USDC);
        uint256 viaWeth = _swap(WSTETH, 10 ether, abi.encode(path));
        // wstETH is worth more than ETH: ten of them fetch more than ten ETH would.
        assertGe(viaWeth, _usdcAt(ETH_USD, 10 ether, 18));
        assertGt(viaWeth, direct * 10);
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Uniswap V3 Router Fork Tests
// ═══════════════════════════════════════════════════════════════════════

contract UniswapV3RouterForkTest is ForkTestBase {
    address constant SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint24 constant DEFAULT_FEE = 3000; // 0.3%

    UniswapV3Router internal router;
    bool internal _forked;
    address internal swapper;

    function setUp() public {
        _forked = _tryCreateFork("RPC_ETHEREUM_PRIMARY_HTTP");
        if (!_forked) return;

        router = new UniswapV3Router(SWAP_ROUTER, FACTORY, DEFAULT_FEE);
        swapper = makeAddr("swapper");
    }

    function test_swap_wethToUsdc() public {
        if (!_forked) return;

        uint256 amountIn = 1 ether;
        deal(WETH, swapper, amountIn);

        vm.startPrank(swapper);
        IERC20(WETH).approve(address(router), amountIn);
        uint256 amountOut = router.swap(WETH, USDC, amountIn, 0, "");
        vm.stopPrank();

        assertGt(amountOut, 0, "Should receive USDC from swap");
        assertEq(IERC20(USDC).balanceOf(swapper), amountOut, "Swapper should hold the output USDC");
    }

    function test_swap_usdcToWeth() public {
        if (!_forked) return;

        uint256 amountIn = 1000e6; // 1000 USDC
        deal(USDC, swapper, amountIn);

        vm.startPrank(swapper);
        IERC20(USDC).approve(address(router), amountIn);
        uint256 amountOut = router.swap(USDC, WETH, amountIn, 0, "");
        vm.stopPrank();

        assertGt(amountOut, 0, "Should receive WETH from swap");
        assertEq(IERC20(WETH).balanceOf(swapper), amountOut, "Swapper should hold the output WETH");
    }

    function test_swap_respectsMinAmountOut() public {
        if (!_forked) return;

        uint256 amountIn = 1 ether;
        deal(WETH, swapper, amountIn);

        // Set minAmountOut absurdly high so the swap reverts
        uint256 absurdMin = type(uint128).max;

        vm.startPrank(swapper);
        IERC20(WETH).approve(address(router), amountIn);
        vm.expectRevert();
        router.swap(WETH, USDC, amountIn, absurdMin, "");
        vm.stopPrank();
    }

    function test_getQuote_returnsNonZeroForValidPair() public {
        if (!_forked) return;

        uint256 quote = router.getQuote(WETH, USDC, 1 ether);
        assertGt(quote, 0, "Quote should be > 0 for WETH/USDC pair");
    }

    function test_getQuote_returnsZeroForInvalidPair() public {
        if (!_forked) return;

        address FAKE_TOKEN = makeAddr("fakeToken");
        uint256 quote = router.getQuote(WETH, FAKE_TOKEN, 1 ether);
        assertEq(quote, 0, "Quote should be 0 for non-existent pool");
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  UniswapV2 Fork Router Fork Tests
// ═══════════════════════════════════════════════════════════════════════

contract UniV2ForkRouterForkTest is ForkTestBase {
    address constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    UniV2ForkRouter internal router;
    bool internal _forked;
    address internal swapper;

    function setUp() public {
        _forked = _tryCreateFork("RPC_ETHEREUM_PRIMARY_HTTP");
        if (!_forked) return;

        router = new UniV2ForkRouter(UNISWAP_V2_ROUTER);
        swapper = makeAddr("swapper");
    }

    function test_swap_wethToUsdc() public {
        if (!_forked) return;

        uint256 amountIn = 1 ether;
        deal(WETH, swapper, amountIn);

        vm.startPrank(swapper);
        IERC20(WETH).approve(address(router), amountIn);
        uint256 amountOut = router.swap(WETH, USDC, amountIn, 0, "");
        vm.stopPrank();

        assertGt(amountOut, 0, "Should receive USDC from V2 swap");
        assertEq(IERC20(USDC).balanceOf(swapper), amountOut, "Swapper should hold the output USDC");
    }

    function test_swap_usdcToWeth() public {
        if (!_forked) return;

        uint256 amountIn = 1000e6;
        deal(USDC, swapper, amountIn);

        vm.startPrank(swapper);
        IERC20(USDC).approve(address(router), amountIn);
        uint256 amountOut = router.swap(USDC, WETH, amountIn, 0, "");
        vm.stopPrank();

        assertGt(amountOut, 0, "Should receive WETH from V2 swap");
        assertEq(IERC20(WETH).balanceOf(swapper), amountOut, "Swapper should hold the output WETH");
    }

    function test_getQuote_returnsNonZero() public {
        if (!_forked) return;

        uint256 quote = router.getQuote(WETH, USDC, 1 ether);
        assertGt(quote, 0, "Quote should be > 0 for WETH/USDC on Uniswap V2");
    }

    function test_swap_respectsMinAmountOut() public {
        if (!_forked) return;

        uint256 amountIn = 1 ether;
        deal(WETH, swapper, amountIn);

        uint256 absurdMin = type(uint128).max;

        vm.startPrank(swapper);
        IERC20(WETH).approve(address(router), amountIn);
        vm.expectRevert();
        router.swap(WETH, USDC, amountIn, absurdMin, "");
        vm.stopPrank();
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Camelot Router Fork Tests (Arbitrum)
//
//  D6: verifies CamelotRouter's minimal ABI matches the live Arbitrum
//  Camelot router deployed at CAMELOT_ROUTER below. Skips cleanly when
//  RPC_ARBITRUM_PRIMARY_HTTP is not set.
// ═══════════════════════════════════════════════════════════════════════

contract CamelotRouterForkTest is ForkTestBase {
    address constant CAMELOT_ROUTER = 0xc873fEcbd354f5A56E00E710B90EF4201db2448d;
    address constant WETH_ARB = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant USDC_ARB = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    CamelotRouter internal router;
    bool internal _forked;
    address internal swapper;

    function setUp() public {
        _forked = _tryCreateFork("RPC_ARBITRUM_PRIMARY_HTTP");
        if (!_forked) return;

        router = new CamelotRouter(CAMELOT_ROUTER, address(0));
        swapper = makeAddr("swapper");
    }

    function test_swap_wethToUsdc() public {
        if (!_forked) return;

        uint256 amountIn = 1 ether;
        deal(WETH_ARB, swapper, amountIn);

        vm.startPrank(swapper);
        IERC20(WETH_ARB).approve(address(router), amountIn);
        uint256 amountOut = router.swap(WETH_ARB, USDC_ARB, amountIn, 0, "");
        vm.stopPrank();

        assertGt(amountOut, 0, "Should receive USDC from Camelot swap");
        assertEq(IERC20(USDC_ARB).balanceOf(swapper), amountOut, "Swapper should hold the output USDC");
    }

    function test_getQuote_returnsNonZero() public {
        if (!_forked) return;

        uint256 quote = router.getQuote(WETH_ARB, USDC_ARB, 1 ether);
        assertGt(quote, 0, "Quote should be > 0 for WETH/USDC on Camelot Arbitrum");
    }

    function test_swap_respectsMinAmountOut() public {
        if (!_forked) return;

        uint256 amountIn = 1 ether;
        deal(WETH_ARB, swapper, amountIn);

        uint256 absurdMin = type(uint128).max;

        vm.startPrank(swapper);
        IERC20(WETH_ARB).approve(address(router), amountIn);
        vm.expectRevert();
        router.swap(WETH_ARB, USDC_ARB, amountIn, absurdMin, "");
        vm.stopPrank();
    }
}
