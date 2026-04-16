// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {UniV2ForkRouter} from "../../../src/dex/UniV2ForkRouter.sol";
import {AegisErrors} from "../../../src/libraries/AegisErrors.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {MockV2Router} from "../../helpers/MockV2Router.sol";
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
        vm.expectRevert(AegisErrors.ZeroAddress.selector);
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
}
