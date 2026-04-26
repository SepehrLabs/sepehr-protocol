// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CamelotRouter} from "../../src/dex/CamelotRouter.sol";
import {UniV2ForkRouter} from "../../src/dex/UniV2ForkRouter.sol";
import {UniswapV3Router} from "../../src/dex/UniswapV3Router.sol";
import {ForkTestBase} from "./ForkTestBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
