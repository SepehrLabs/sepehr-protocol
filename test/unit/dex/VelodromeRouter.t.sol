// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {VelodromeRouter} from "../../../src/dex/VelodromeRouter.sol";
import {AegisErrors} from "../../../src/libraries/AegisErrors.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {MockVeloRouter} from "../../helpers/MockVeloRouter.sol";
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
        vm.expectRevert(AegisErrors.ZeroAddress.selector);
        new VelodromeRouter(address(0), POOL_FACTORY, false);
    }

    function test_constructor_revertsOnZeroFactory() public {
        vm.expectRevert(AegisErrors.ZeroAddress.selector);
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
