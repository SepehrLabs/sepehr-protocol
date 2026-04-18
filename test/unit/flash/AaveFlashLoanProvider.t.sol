// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AaveFlashLoanProvider} from "../../../src/flash/AaveFlashLoanProvider.sol";
import {SepehrErrors} from "../../../src/libraries/SepehrErrors.sol";
import {MockAavePool} from "../../helpers/MockAavePool.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {SimpleCallback} from "../../helpers/SimpleCallback.sol";
import {Test} from "forge-std/Test.sol";

contract AaveFlashLoanProviderTest is Test {
    AaveFlashLoanProvider provider;
    MockAavePool pool;
    MockERC20 token;
    SimpleCallback callback;

    uint256 constant POOL_LIQUIDITY = 1_000_000e18;
    uint256 constant BORROW_AMOUNT = 100e18;

    function setUp() public {
        pool = new MockAavePool();
        token = new MockERC20("USDC", "USDC");
        callback = new SimpleCallback();
        provider = new AaveFlashLoanProvider(address(pool));

        token.mint(address(pool), POOL_LIQUIDITY);
    }

    // ── Constructor ──────────────────────────────────────────────────────

    function test_constructor_setsPool() public view {
        assertEq(address(provider.POOL()), address(pool));
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new AaveFlashLoanProvider(address(0));
    }

    // ── flashBorrow ──────────────────────────────────────────────────────

    function test_flashBorrow_successfulBorrowAndRepay() public {
        uint256 fee = (BORROW_AMOUNT * pool.premiumTotal()) / 10_000;
        token.mint(address(callback), fee);

        provider.flashBorrow(address(token), BORROW_AMOUNT, address(callback), "test_data");

        assertEq(callback.lastAsset(), address(token));
        assertEq(callback.lastAmount(), BORROW_AMOUNT);
        assertEq(callback.lastFee(), fee);
        assertEq(callback.lastData(), "test_data");
    }

    function test_flashBorrow_revertsOnZeroCallback() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        provider.flashBorrow(address(token), BORROW_AMOUNT, address(0), "");
    }

    function test_flashBorrow_revertsOnZeroAmount() public {
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        provider.flashBorrow(address(token), 0, address(callback), "");
    }

    function test_flashBorrow_revertsWhenCallbackDoesNotRepay() public {
        callback.setShouldRepay(false);
        vm.expectRevert();
        provider.flashBorrow(address(token), BORROW_AMOUNT, address(callback), "");
    }

    function test_flashBorrow_clearsActiveStateAfterSuccess() public {
        uint256 fee = (BORROW_AMOUNT * pool.premiumTotal()) / 10_000;
        token.mint(address(callback), fee);
        provider.flashBorrow(address(token), BORROW_AMOUNT, address(callback), "data");

        // A second borrow should work (proves state was cleared)
        token.mint(address(callback), fee);
        provider.flashBorrow(address(token), BORROW_AMOUNT, address(callback), "data2");
        assertEq(callback.lastData(), "data2");
    }

    // ── executeOperation ─────────────────────────────────────────────────

    function test_executeOperation_revertsIfCallerNotPool() public {
        vm.expectRevert(SepehrErrors.InvalidFlashLoanCallback.selector);
        provider.executeOperation(address(token), BORROW_AMOUNT, 0, address(provider), "");
    }

    function test_executeOperation_revertsIfInitiatorNotSelf() public {
        vm.prank(address(pool));
        vm.expectRevert(SepehrErrors.InvalidFlashLoanCallback.selector);
        provider.executeOperation(address(token), BORROW_AMOUNT, 0, address(0xdead), "");
    }

    function test_executeOperation_revertsIfNoActiveLoan() public {
        vm.prank(address(pool));
        vm.expectRevert(SepehrErrors.InvalidFlashLoanCallback.selector);
        provider.executeOperation(address(token), BORROW_AMOUNT, 0, address(provider), "");
    }

    // ── getFlashLoanFeeBps ───────────────────────────────────────────────

    function test_getFlashLoanFeeBps_returnsPoolPremium() public view {
        assertEq(provider.getFlashLoanFeeBps(address(token)), 5);
    }

    function test_getFlashLoanFeeBps_reflectsUpdatedPremium() public {
        pool.setPremiumTotal(9);
        assertEq(provider.getFlashLoanFeeBps(address(token)), 9);
    }

    // ── isAvailable ──────────────────────────────────────────────────────

    function test_isAvailable_trueWhenEnoughLiquidity() public view {
        assertTrue(provider.isAvailable(address(token), BORROW_AMOUNT));
    }

    function test_isAvailable_falseWhenInsufficientLiquidity() public view {
        assertFalse(provider.isAvailable(address(token), POOL_LIQUIDITY + 1));
    }

    function test_isAvailable_trueWhenExactBalance() public view {
        assertTrue(provider.isAvailable(address(token), POOL_LIQUIDITY));
    }

    // C2: a re-entrant flashBorrow must revert rather than overwrite the callback slot.
    function test_flashBorrow_revertsOnConcurrentInvocation() public {
        uint256 fee = (BORROW_AMOUNT * pool.premiumTotal()) / 10_000;
        token.mint(address(callback), fee * 2);
        callback.setReentrantProvider(address(provider));
        callback.setReentrantAsset(address(token));
        callback.setReentrantAmount(BORROW_AMOUNT);
        callback.setReentrantTrigger(true);

        vm.expectRevert();
        provider.flashBorrow(address(token), BORROW_AMOUNT, address(callback), "");
    }

    // ── Fuzz ─────────────────────────────────────────────────────────────

    function testFuzz_flashBorrow_correctFeeForwarded(
        uint128 amount
    ) public {
        vm.assume(amount > 0 && amount <= POOL_LIQUIDITY);
        uint256 fee = (uint256(amount) * pool.premiumTotal()) / 10_000;
        token.mint(address(callback), fee);

        provider.flashBorrow(address(token), uint256(amount), address(callback), "fuzz");
        assertEq(callback.lastFee(), fee);
    }
}
