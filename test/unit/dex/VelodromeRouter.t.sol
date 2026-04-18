// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {VelodromeRouter} from "../../../src/dex/VelodromeRouter.sol";
import {SepehrErrors} from "../../../src/libraries/SepehrErrors.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {MockVeloRouter} from "../../helpers/MockVeloRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract VelodromeRouterTest is Test {
    VelodromeRouter router;
    MockVeloRouter externalRouter;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    address constant POOL_FACTORY = address(0xFACE);

    uint256 constant SWAP_AMOUNT = 100e18;

    function setUp() public {
        tokenIn = new MockERC20("WETH", "WETH");
        tokenOut = new MockERC20("USDC", "USDC");
        externalRouter = new MockVeloRouter();
        router = new VelodromeRouter(address(externalRouter), POOL_FACTORY, false);

        tokenOut.mint(address(externalRouter), 1_000_000e18);
    }

    function test_constructor_setsImmutables() public view {
        assertEq(address(router.ROUTER()), address(externalRouter));
        assertEq(router.POOL_FACTORY(), POOL_FACTORY);
        assertFalse(router.DEFAULT_STABLE());
    }

    function test_constructor_revertsOnZeroRouter() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new VelodromeRouter(address(0), POOL_FACTORY, false);
    }

    function test_constructor_revertsOnZeroFactory() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new VelodromeRouter(address(externalRouter), address(0), false);
    }

    function test_swap_successWithDefaultStable() public {
        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        uint256 amountOut = router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, "");
        assertEq(amountOut, SWAP_AMOUNT);
    }

    function test_swap_successWithCustomStable() public {
        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        uint256 amountOut = router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, abi.encode(true));
        assertEq(amountOut, SWAP_AMOUNT);
    }

    function test_swap_revertsOnZeroAmount() public {
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        router.swap(address(tokenIn), address(tokenOut), 0, 0, "");
    }

    function test_swap_revertsOnSameToken() public {
        // Audit D12: self-swap short-circuits to SameToken before touching the external router.
        vm.expectRevert(SepehrErrors.SameToken.selector);
        router.swap(address(tokenIn), address(tokenIn), 1e18, 0, "");
    }

    function test_swap_revertsOnSlippage() public {
        externalRouter.setExchangeRate(0.5e18);
        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        vm.expectRevert();
        router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, SWAP_AMOUNT, "");
    }

    function test_getQuote_returnsExpectedAmount() public view {
        uint256 quote = router.getQuote(address(tokenIn), address(tokenOut), SWAP_AMOUNT);
        assertEq(quote, SWAP_AMOUNT);
    }

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
        assertEq(IERC20(address(tokenIn)).allowance(address(router), address(externalRouter)), 0);
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

    // ── D7 + D9: per-call factory override + caller-supplied deadline ────

    function test_swap_overridesFactoryAndDeadlineViaRouteData() public {
        // D7: alternate factory (e.g. Aerodrome Slipstream) passed via routeData.
        // D9: caller-supplied deadline is forwarded verbatim to the external router.
        address altFactory = address(0xBEEF);
        uint256 customDeadline = block.timestamp + 300;

        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        bytes memory routeData = abi.encode(customDeadline, true, altFactory);
        router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, routeData);

        assertEq(externalRouter.lastFactory(), altFactory, "factory not forwarded");
        assertTrue(externalRouter.lastStable(), "stable not forwarded");
        assertEq(externalRouter.lastDeadline(), customDeadline, "deadline not forwarded");
    }

    function test_swap_revertsOnZeroFactoryInRouteData() public {
        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        bytes memory routeData = abi.encode(block.timestamp, false, address(0));
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, routeData);
    }

    function test_swap_revertsOnMalformedRouteData() public {
        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        bytes memory bogus = hex"deadbeef";
        vm.expectRevert(SepehrErrors.InvalidRouteData.selector);
        router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, bogus);
    }
}
