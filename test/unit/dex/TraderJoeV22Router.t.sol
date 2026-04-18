// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {TraderJoeV22Router} from "../../../src/dex/TraderJoeV22Router.sol";
import {SepehrErrors} from "../../../src/libraries/SepehrErrors.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {MockLBFactory, MockLBPair, MockLBRouter} from "../../helpers/MockLBRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract TraderJoeV22RouterTest is Test {
    TraderJoeV22Router router;
    MockLBRouter externalRouter;
    MockLBFactory factory;
    MockLBPair pair;
    MockERC20 tokenIn;
    MockERC20 tokenOut;

    uint256 constant DEFAULT_BIN_STEP = 20;
    uint256 constant SWAP_AMOUNT = 100e18;

    function setUp() public {
        tokenIn = new MockERC20("WETH", "WETH");
        tokenOut = new MockERC20("USDC", "USDC");
        externalRouter = new MockLBRouter();
        factory = new MockLBFactory();
        pair = new MockLBPair(address(tokenOut), uint128(SWAP_AMOUNT));
        router = new TraderJoeV22Router(address(externalRouter), address(factory), DEFAULT_BIN_STEP);

        tokenOut.mint(address(externalRouter), 1_000_000e18);
        factory.setPair(address(tokenIn), address(tokenOut), DEFAULT_BIN_STEP, address(pair));
    }

    function test_constructor_setsImmutables() public view {
        assertEq(address(router.ROUTER()), address(externalRouter));
        assertEq(address(router.LB_FACTORY()), address(factory));
        assertEq(router.DEFAULT_BIN_STEP(), DEFAULT_BIN_STEP);
    }

    function test_constructor_revertsOnZeroRouter() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new TraderJoeV22Router(address(0), address(factory), DEFAULT_BIN_STEP);
    }

    function test_constructor_revertsOnZeroFactory() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new TraderJoeV22Router(address(externalRouter), address(0), DEFAULT_BIN_STEP);
    }

    function test_swap_successWithDefaultBinStep() public {
        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        uint256 amountOut = router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, "");
        assertEq(amountOut, SWAP_AMOUNT);
    }

    function test_swap_successWithCustomBinStep() public {
        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        uint256 amountOut = router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, abi.encode(uint256(25)));
        assertEq(amountOut, SWAP_AMOUNT);
    }

    function test_swap_revertsOnZeroAmount() public {
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        router.swap(address(tokenIn), address(tokenOut), 0, 0, "");
    }

    function test_swap_revertsOnSameToken() public {
        // Audit D12: self-swap short-circuits to SameToken before the LB router is invoked.
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

    function test_getQuote_returnsZeroIfNoPair() public view {
        uint256 quote = router.getQuote(address(tokenIn), address(0xdead), SWAP_AMOUNT);
        assertEq(quote, 0);
    }

    function test_getQuote_reflectsUpdatedPairOutput() public {
        pair.setMockAmountOut(uint128(50e18));
        uint256 quote = router.getQuote(address(tokenIn), address(tokenOut), SWAP_AMOUNT);
        assertEq(quote, 50e18);
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

    // ── D8 + D9: per-call version + caller-supplied deadline ─────────────

    function test_swap_overridesVersionAndDeadlineViaRouteData() public {
        // D8: caller selects Version.V2_1 (ordinal 2) for deeper TJ pool liquidity.
        // D9: caller-supplied deadline forwarded verbatim to the external router.
        uint256 customDeadline = block.timestamp + 600;
        uint8 v21 = 2;

        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        bytes memory routeData = abi.encode(customDeadline, uint256(25), v21);
        router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, routeData);

        assertEq(uint8(externalRouter.lastVersion()), v21, "version not forwarded");
        assertEq(externalRouter.lastBinStep(), 25, "binStep not forwarded");
        assertEq(externalRouter.lastDeadline(), customDeadline, "deadline not forwarded");
    }

    function test_swap_revertsOnInvalidVersion() public {
        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        uint8 invalidVersion = 4;
        bytes memory routeData = abi.encode(block.timestamp, uint256(25), invalidVersion);
        vm.expectRevert(SepehrErrors.InvalidRouteData.selector);
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
