// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AggregatorRouter} from "../../../src/dex/AggregatorRouter.sol";
import {SepehrErrors} from "../../../src/libraries/SepehrErrors.sol";
import {MockAggregator} from "../../helpers/MockAggregator.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Test} from "forge-std/Test.sol";

contract AggregatorRouterTest is Test {
    AggregatorRouter internal router;
    AggregatorRouter internal holderRouter;
    MockAggregator internal aggregator;
    MockERC20 internal weth;
    MockERC20 internal usdc;

    uint256 internal constant AMOUNT = 10e18;
    uint256 internal constant OUT = 25_000e18;

    function setUp() public {
        weth = new MockERC20("WETH", "WETH");
        usdc = new MockERC20("USDC", "USDC");
        aggregator = new MockAggregator();
        router = new AggregatorRouter(address(aggregator), address(aggregator), _selectors());
        holderRouter = new AggregatorRouter(address(aggregator), address(aggregator.holder()), _selectors());
        usdc.mint(address(aggregator), 1_000_000e18);
        weth.mint(address(this), 100e18);
        weth.approve(address(router), type(uint256).max);
        weth.approve(address(holderRouter), type(uint256).max);
    }

    function _selectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = MockAggregator.sell.selector;
        selectors[1] = MockAggregator.fail.selector;
    }

    /// @dev The calldata the keeper builds: this router as recipient, WETH sold for USDC.
    function _route(
        AggregatorRouter via,
        uint256 pull,
        uint256 out,
        bool viaHolder
    ) internal view returns (bytes memory) {
        return abi.encodeCall(MockAggregator.sell, (address(weth), address(usdc), pull, out, address(via), viaHolder));
    }

    // ── Constructor ──────────────────────────────────────────────────────

    function test_constructor_fixesTheTargetSpenderAndSelectors() public view {
        assertEq(router.TARGET(), address(aggregator));
        assertEq(router.SPENDER(), address(aggregator));
        assertTrue(router.allowedSelectors(MockAggregator.sell.selector));
        assertFalse(router.allowedSelectors(bytes4(0xdeadbeef)));
    }

    function test_constructor_rejectsZeroAddressesAndAnEmptyList() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new AggregatorRouter(address(0), address(aggregator), _selectors());
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new AggregatorRouter(address(aggregator), address(0), _selectors());
        vm.expectRevert(SepehrErrors.InvalidRouteData.selector);
        new AggregatorRouter(address(aggregator), address(aggregator), new bytes4[](0));
    }

    // ── swap ─────────────────────────────────────────────────────────────

    function test_swap_sellsThroughTheAggregator_andHandsBackOutputAndUnsoldInput() public {
        // The keeper quoted a little under what the core sells: 9.99 of the 10 WETH.
        uint256 sold = AMOUNT * 999 / 1000;
        uint256 out = router.swap(address(weth), address(usdc), AMOUNT, OUT, _route(router, sold, OUT, false));

        assertEq(out, OUT);
        assertEq(usdc.balanceOf(address(this)), OUT, "output to the caller");
        assertEq(weth.balanceOf(address(this)), 100e18 - sold, "unsold WETH back to the caller");
        assertEq(weth.balanceOf(address(router)), 0, "nothing left in the router");
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(weth.allowance(address(router), address(aggregator)), 0, "approval cleared");
    }

    function test_swap_approvesTheSpender_notTheTarget() public {
        holderRouter.swap(address(weth), address(usdc), AMOUNT, OUT, _route(holderRouter, AMOUNT, OUT, true));
        assertEq(usdc.balanceOf(address(this)), OUT);
        assertEq(weth.allowance(address(holderRouter), address(aggregator.holder())), 0, "approval cleared");
    }

    function test_swap_rejectsAFunctionTheRouterDoesNotAllow() public {
        bytes memory data = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1));
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.SelectorNotAllowed.selector, bytes4(0xdeadbeef)));
        router.swap(address(weth), address(usdc), AMOUNT, 0, data);
    }

    function test_swap_rejectsMalformedRequests() public {
        vm.expectRevert(SepehrErrors.InvalidRouteData.selector);
        router.swap(address(weth), address(usdc), AMOUNT, 0, hex"e21f");
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        router.swap(address(weth), address(usdc), 0, 0, _route(router, AMOUNT, OUT, false));
        vm.expectRevert(SepehrErrors.SameToken.selector);
        router.swap(address(weth), address(weth), AMOUNT, 0, _route(router, AMOUNT, OUT, false));
    }

    function test_swap_revertsUnderTheCallersMinimum() public {
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.SlippageExceeded.selector, OUT - 1, OUT));
        router.swap(address(weth), address(usdc), AMOUNT, OUT, _route(router, AMOUNT, OUT - 1, false));
    }

    function test_swap_revertsWhenTheOutputGoesElsewhere() public {
        address thief = makeAddr("thief");
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.SlippageExceeded.selector, 0, OUT));
        bytes memory data =
            abi.encodeCall(MockAggregator.sell, (address(weth), address(usdc), AMOUNT, OUT, thief, false));
        router.swap(address(weth), address(usdc), AMOUNT, OUT, data);
    }

    function test_swap_cannotTakeMoreThanItWasGiven() public {
        vm.expectRevert();
        router.swap(address(weth), address(usdc), AMOUNT, 0, _route(router, AMOUNT + 1, OUT, false));
    }

    function test_swap_bubblesTheAggregatorsRevert() public {
        vm.expectRevert(bytes("MockAggregator: no route"));
        router.swap(address(weth), address(usdc), AMOUNT, 0, abi.encodeCall(MockAggregator.fail, ()));
    }

    function test_swap_cannotBeReentered() public {
        aggregator.setReenter(true);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        router.swap(address(weth), address(usdc), AMOUNT, OUT, _route(router, AMOUNT, OUT, false));
    }

    function test_getQuote_isAlwaysZero() public view {
        assertEq(router.getQuote(address(weth), address(usdc), AMOUNT), 0);
    }
}
