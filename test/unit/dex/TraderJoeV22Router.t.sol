// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {TraderJoeV22Router} from "../../../src/dex/TraderJoeV22Router.sol";
import {AegisErrors} from "../../../src/libraries/AegisErrors.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {MockLBFactory, MockLBPair, MockLBRouter} from "../../helpers/MockLBRouter.sol";
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
        vm.expectRevert(AegisErrors.ZeroAddress.selector);
        new TraderJoeV22Router(address(0), address(factory), DEFAULT_BIN_STEP);
    }

    function test_constructor_revertsOnZeroFactory() public {
        vm.expectRevert(AegisErrors.ZeroAddress.selector);
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
        vm.expectRevert(AegisErrors.ZeroAmount.selector);
        router.swap(address(tokenIn), address(tokenOut), 0, 0, "");
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
}
