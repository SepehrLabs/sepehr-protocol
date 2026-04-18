// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {UniV2ForkRouter} from "../../../src/dex/UniV2ForkRouter.sol";
import {SepehrErrors} from "../../../src/libraries/SepehrErrors.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {MockPartialPullRouter} from "../../helpers/MockPartialPullRouter.sol";
import {MockV2Router} from "../../helpers/MockV2Router.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract UniV2ForkRouterTest is Test {
    UniV2ForkRouter router;
    MockV2Router externalRouter;
    MockERC20 tokenIn;
    MockERC20 tokenOut;

    uint256 constant SWAP_AMOUNT = 100e18;

    function setUp() public {
        tokenIn = new MockERC20("WETH", "WETH");
        tokenOut = new MockERC20("USDC", "USDC");
        externalRouter = new MockV2Router();
        router = new UniV2ForkRouter(address(externalRouter));

        tokenOut.mint(address(externalRouter), 1_000_000e18);
    }

    function test_constructor_setsRouter() public view {
        assertEq(address(router.ROUTER()), address(externalRouter));
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new UniV2ForkRouter(address(0));
    }

    function test_swap_success() public {
        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        uint256 amountOut = router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, "");
        assertEq(amountOut, SWAP_AMOUNT);
        assertEq(tokenOut.balanceOf(address(this)), SWAP_AMOUNT);
    }

    function test_swap_revertsOnZeroAmount() public {
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        router.swap(address(tokenIn), address(tokenOut), 0, 0, "");
    }

    function test_swap_revertsOnSlippage() public {
        externalRouter.setExchangeRate(0.5e18);
        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        vm.expectRevert();
        router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, SWAP_AMOUNT, "");
    }

    function test_swap_respectsExchangeRate() public {
        externalRouter.setExchangeRate(3e18);
        tokenOut.mint(address(externalRouter), 1_000_000e18);
        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        uint256 amountOut = router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, "");
        assertEq(amountOut, SWAP_AMOUNT * 3);
    }

    function test_getQuote_returnsExpectedAmount() public view {
        uint256 quote = router.getQuote(address(tokenIn), address(tokenOut), SWAP_AMOUNT);
        assertEq(quote, SWAP_AMOUNT);
    }

    function test_getQuote_reflectsRate() public {
        externalRouter.setExchangeRate(2e18);
        uint256 quote = router.getQuote(address(tokenIn), address(tokenOut), SWAP_AMOUNT);
        assertEq(quote, SWAP_AMOUNT * 2);
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
        // Seed dust directly on the Sepehr router before the swap (simulates
        // residual balance from a prior misbehaving swap).
        uint256 dust = 7e18;
        tokenIn.mint(address(router), dust);

        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        uint256 callerBefore = tokenIn.balanceOf(address(this));
        router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, "");

        assertEq(tokenIn.balanceOf(address(router)), 0, "dust left behind in router");
        // Caller paid SWAP_AMOUNT to router, got `dust` back via sweep.
        assertEq(tokenIn.balanceOf(address(this)), callerBefore - SWAP_AMOUNT + dust, "dust not swept to caller");
    }

    function test_swap_sweepsDustFromPartialPullRouter() public {
        // Swap through a fee-on-transfer–style external router that pulls only
        // 90% of amountIn, leaving 10% dust inside the Sepehr wrapper.
        MockPartialPullRouter fotExt = new MockPartialPullRouter();
        fotExt.setPullRatio(0.9e18);
        tokenOut.mint(address(fotExt), 1_000_000e18);

        UniV2ForkRouter fotWrapper = new UniV2ForkRouter(address(fotExt));

        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(fotWrapper), SWAP_AMOUNT);

        uint256 callerBefore = tokenIn.balanceOf(address(this));
        uint256 amountOut = fotWrapper.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, "");

        uint256 expectedDust = SWAP_AMOUNT - (SWAP_AMOUNT * 9 / 10);
        assertEq(amountOut, (SWAP_AMOUNT * 9) / 10, "amountOut scales with pull ratio");
        assertEq(tokenIn.balanceOf(address(fotWrapper)), 0, "dust left behind in router");
        assertEq(tokenIn.balanceOf(address(this)), callerBefore - SWAP_AMOUNT + expectedDust, "dust not swept");
        assertEq(IERC20(address(tokenIn)).allowance(address(fotWrapper), address(fotExt)), 0, "allowance not reset");
    }

    // ── D9: caller-supplied deadline ────────────────────────────────────

    function test_swap_forwardsDeadlineFromRouteData() public {
        uint256 customDeadline = block.timestamp + 600;
        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, abi.encode(customDeadline));
        assertEq(externalRouter.lastDeadline(), customDeadline);
    }

    function test_swap_revertsOnMalformedRouteData() public {
        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        bytes memory bogus = hex"deadbeef";
        vm.expectRevert(SepehrErrors.InvalidRouteData.selector);
        router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, bogus);
    }
}
