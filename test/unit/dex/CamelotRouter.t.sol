// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CamelotRouter} from "../../../src/dex/CamelotRouter.sol";
import {SepehrErrors} from "../../../src/libraries/SepehrErrors.sol";
import {MockCamelotExtRouter} from "../../helpers/MockCamelotExtRouter.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract CamelotRouterTest is Test {
    CamelotRouter router;
    MockCamelotExtRouter externalRouter;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    address constant REFERRER = address(0xBEEF);

    uint256 constant SWAP_AMOUNT = 100e18;

    function setUp() public {
        tokenIn = new MockERC20("WETH", "WETH");
        tokenOut = new MockERC20("USDC", "USDC");
        externalRouter = new MockCamelotExtRouter();
        router = new CamelotRouter(address(externalRouter), REFERRER);

        tokenOut.mint(address(externalRouter), 1_000_000e18);
    }

    function test_constructor_setsImmutables() public view {
        assertEq(address(router.ROUTER()), address(externalRouter));
        assertEq(router.REFERRER(), REFERRER);
    }

    function test_constructor_revertsOnZeroRouter() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new CamelotRouter(address(0), REFERRER);
    }

    function test_constructor_allowsZeroReferrer() public {
        CamelotRouter r = new CamelotRouter(address(externalRouter), address(0));
        assertEq(r.REFERRER(), address(0));
    }

    function test_swap_success() public {
        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        uint256 amountOut = router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, "");
        assertEq(amountOut, SWAP_AMOUNT);
    }

    function test_swap_passesReferrer() public {
        tokenIn.mint(address(this), SWAP_AMOUNT);
        tokenIn.approve(address(router), SWAP_AMOUNT);

        router.swap(address(tokenIn), address(tokenOut), SWAP_AMOUNT, 0, "");
        assertEq(externalRouter.lastReferrer(), REFERRER);
    }

    function test_swap_revertsOnZeroAmount() public {
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        router.swap(address(tokenIn), address(tokenOut), 0, 0, "");
    }

    function test_swap_revertsOnSameToken() public {
        // Audit D12: self-swap short-circuits to SameToken before touching Camelot.
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
