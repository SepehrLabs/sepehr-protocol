// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UniswapV3Router} from "../../../src/dex/UniswapV3Router.sol";
import {SepehrErrors} from "../../../src/libraries/SepehrErrors.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {MockUniswapV3Pool} from "../../helpers/MockUniswapV3Pool.sol";
import {MockV3Factory} from "../../helpers/MockV3Factory.sol";
import {MockV3SwapRouter} from "../../helpers/MockV3SwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract UniswapV3RouterTest is Test {
    UniswapV3Router router;
    MockV3SwapRouter swapRouter;
    MockV3Factory factory;
    MockUniswapV3Pool pool;
    MockERC20 tokenIn;
    MockERC20 tokenOut;

    uint24 constant DEFAULT_FEE = 3000;
    uint256 constant SWAP_AMOUNT = 100e18;

    function setUp() public {
        tokenIn = new MockERC20("WETH", "WETH");
        tokenOut = new MockERC20("USDC", "USDC");
        swapRouter = new MockV3SwapRouter();
        factory = new MockV3Factory();
        pool = new MockUniswapV3Pool(address(tokenIn), address(tokenOut), DEFAULT_FEE);
        router = new UniswapV3Router(address(swapRouter), address(factory), DEFAULT_FEE);

        tokenOut.mint(address(swapRouter), 1_000_000e18);
        factory.setPool(address(tokenIn), address(tokenOut), DEFAULT_FEE, address(pool));
    }

    // ── Constructor ──────────────────────────────────────────────────────

    function test_constructor_setsImmutables() public view {
        assertEq(address(router.SWAP_ROUTER()), address(swapRouter));
        assertEq(address(router.FACTORY()), address(factory));
        assertEq(router.DEFAULT_FEE(), DEFAULT_FEE);
    }

    function test_constructor_revertsOnZeroSwapRouter() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new UniswapV3Router(address(0), address(factory), DEFAULT_FEE);
    }

    function test_constructor_revertsOnZeroFactory() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new UniswapV3Router(address(swapRouter), address(0), DEFAULT_FEE);
    }

    // ── swap ─────────────────────────────────────────────────────────────

    function test_swap_successWithDefaultFee() public {
        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        uint256 amountOut = router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, "");
        assertEq(amountOut, SWAP_AMOUNT);
        assertEq(tokenOut.balanceOf(address(this)), SWAP_AMOUNT);
    }

    function test_swap_successWithCustomFee() public {
        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        uint256 amountOut = router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, abi.encode(uint24(500)));
        assertEq(amountOut, SWAP_AMOUNT);
    }

    // D3: sqrtPriceLimitX96 must be forwarded when passed in extended routeData.
    function test_swap_forwardsSqrtPriceLimit() public {
        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        uint160 expectedLimit = uint160(1 << 95); // any nonzero value
        bytes memory routeData = abi.encode(uint24(500), expectedLimit);
        uint256 amountOut = router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, routeData);
        assertEq(amountOut, SWAP_AMOUNT);
        assertEq(swapRouter.lastSqrtPriceLimitX96(), expectedLimit, "sqrtPriceLimit forwarded to SwapRouter");
    }

    function test_swap_defaultsSqrtPriceLimitToZero() public {
        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, "");
        assertEq(swapRouter.lastSqrtPriceLimitX96(), 0, "zero limit when routeData empty");
    }

    function test_swap_revertsOnMalformedRouteData() public {
        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        bytes memory bogus = hex"de";
        vm.expectRevert(SepehrErrors.InvalidRouteData.selector);
        router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, bogus);
    }

    // D9: caller-supplied deadline (96-byte encoding) is forwarded to the SwapRouter.
    function test_swap_forwardsDeadlineFromRouteData() public {
        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        uint256 customDeadline = block.timestamp + 900;
        uint160 customLimit = uint160(1 << 95);
        bytes memory routeData = abi.encode(customDeadline, uint24(500), customLimit);
        router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, routeData);

        assertEq(swapRouter.lastDeadline(), customDeadline, "deadline not forwarded");
        assertEq(swapRouter.lastFee(), uint24(500), "fee not forwarded");
        assertEq(swapRouter.lastSqrtPriceLimitX96(), customLimit, "sqrt limit not forwarded");
    }

    function test_swap_revertsOnZeroAmount() public {
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        router.swap(address(tokenIn), address(tokenOut), 0, 0, "");
    }

    function test_swap_revertsOnSameToken() public {
        // Audit D12: self-swaps short-circuit with SameToken instead of bubbling a deep
        // Uniswap revert.
        vm.expectRevert(SepehrErrors.SameToken.selector);
        router.swap(address(tokenIn), address(tokenIn), 1e18, 0, "");
    }

    function test_swap_revertsOnSlippage() public {
        swapRouter.setExchangeRate(0.5e18);
        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        vm.expectRevert();
        router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, SWAP_AMOUNT, "");
    }

    function test_swap_respectsExchangeRate() public {
        swapRouter.setExchangeRate(2e18);
        tokenOut.mint(address(swapRouter), 1_000_000e18);
        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        uint256 amountOut = router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, "");
        assertEq(amountOut, SWAP_AMOUNT * 2);
    }

    // ── getQuote ─────────────────────────────────────────────────────────

    function test_getQuote_returnsZeroIfNoPool() public view {
        assertEq(router.getQuote(address(tokenIn), address(0xdead), SWAP_AMOUNT), 0);
    }

    function test_getQuote_returnsZeroIfSqrtPriceZero() public view {
        assertEq(router.getQuote(address(tokenIn), address(tokenOut), SWAP_AMOUNT), 0);
    }

    function test_getQuote_estimatesForZeroForOne() public {
        // sqrtPriceX96 = 2^96 corresponds to price = 1.0
        uint160 sqrtPriceX96 = uint160(1 << 96);
        pool.setSlot0(sqrtPriceX96, 0);

        uint256 quote = router.getQuote(address(tokenIn), address(tokenOut), SWAP_AMOUNT);
        // With fee deduction: 100e18 * (1M - 3000) / 1M = 99.7e18
        assertEq(quote, (SWAP_AMOUNT * 997_000) / 1_000_000);
    }

    function test_getQuote_estimatesForOneForZero() public {
        uint160 sqrtPriceX96 = uint160(1 << 96);
        pool.setSlot0(sqrtPriceX96, 0);

        uint256 quote = router.getQuote(address(tokenOut), address(tokenIn), SWAP_AMOUNT);
        assertEq(quote, (SWAP_AMOUNT * 997_000) / 1_000_000);
    }

    // ── Fuzz ─────────────────────────────────────────────────────────────

    function testFuzz_swap_outputMatchesRate(
        uint128 amount
    ) public {
        vm.assume(amount > 0 && amount < 1_000_000e18);
        tokenIn.mint(address(this), amount);
        tokenIn.approve(address(router), amount);

        uint256 amountOut = router.swap(address(tokenIn), address(tokenOut), amount, 0, "");
        assertEq(amountOut, amount);
    }

    // ── D5: allowance reset + dust sweep ────────────────────────────────

    function test_swap_resetsAllowance() public {
        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, "");
        assertEq(IERC20(address(tokenIn)).allowance(address(router), address(swapRouter)), 0);
    }

    function test_swap_sweepsPreSeededDust() public {
        uint256 dust = 7e18;
        tokenIn.mint(address(router), dust);

        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        uint256 callerBefore = tokenIn.balanceOf(address(this));
        router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, "");

        assertEq(tokenIn.balanceOf(address(router)), 0, "dust left behind in router");
        assertEq(tokenIn.balanceOf(address(this)), callerBefore - SWAP_AMOUNT + dust, "dust not swept to caller");
    }
}
