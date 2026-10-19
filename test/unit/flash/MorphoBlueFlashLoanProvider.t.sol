// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MorphoBlueFlashLoanProvider} from "../../../src/flash/MorphoBlueFlashLoanProvider.sol";
import {SepehrErrors} from "../../../src/libraries/SepehrErrors.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {MockMorphoFlashLoan} from "../../helpers/MockMorphoFlashLoan.sol";
import {SimpleCallback} from "../../helpers/SimpleCallback.sol";
import {Test} from "forge-std/Test.sol";

contract MorphoBlueFlashLoanProviderTest is Test {
    MorphoBlueFlashLoanProvider provider;
    MockMorphoFlashLoan morpho;
    MockERC20 token;
    SimpleCallback callback;

    uint256 constant MORPHO_LIQUIDITY = 1_000_000e18;
    uint256 constant BORROW_AMOUNT = 100e18;
    address constant OWNER = address(0xA11CE);

    function setUp() public {
        morpho = new MockMorphoFlashLoan();
        token = new MockERC20("USDC", "USDC");
        callback = new SimpleCallback();
        provider = new MorphoBlueFlashLoanProvider(address(morpho), OWNER);

        token.mint(address(morpho), MORPHO_LIQUIDITY);
    }

    // ── Constructor ──────────────────────────────────────────────────────

    function test_constructor_setsMorphoAndOwner() public view {
        assertEq(address(provider.MORPHO()), address(morpho));
        assertEq(provider.owner(), OWNER);
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new MorphoBlueFlashLoanProvider(address(0), OWNER);
    }

    // ── flashBorrow ──────────────────────────────────────────────────────

    function test_flashBorrow_lendsWithoutFeeAndMorphoGetsItBack() public {
        provider.flashBorrow(address(token), BORROW_AMOUNT, address(callback), "morpho_data");

        assertEq(callback.lastAsset(), address(token));
        assertEq(callback.lastAmount(), BORROW_AMOUNT);
        assertEq(callback.lastFee(), 0);
        assertEq(callback.lastData(), "morpho_data");
        assertEq(token.balanceOf(address(morpho)), MORPHO_LIQUIDITY);
        assertEq(token.balanceOf(address(provider)), 0);
    }

    function test_flashBorrow_leavesNoAllowanceBehind() public {
        provider.flashBorrow(address(token), BORROW_AMOUNT, address(callback), "");
        assertEq(token.allowance(address(provider), address(morpho)), 0);
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
        provider.flashBorrow(address(token), BORROW_AMOUNT, address(callback), "first");
        provider.flashBorrow(address(token), BORROW_AMOUNT, address(callback), "second");
        assertEq(callback.lastData(), "second");
    }

    function test_flashBorrow_revertsOnConcurrentInvocation() public {
        callback.setReentrantProvider(address(provider));
        callback.setReentrantAsset(address(token));
        callback.setReentrantAmount(BORROW_AMOUNT);
        callback.setReentrantTrigger(true);

        vm.expectRevert(SepehrErrors.ConcurrentFlashLoan.selector);
        provider.flashBorrow(address(token), BORROW_AMOUNT, address(callback), "");
    }

    function test_flashBorrow_forwardsLargeDataVerbatim() public {
        bytes memory payload = hex"deadbeefcafebabefeedfacebeefcafebabefeedface0102030405060708090a0b0c0d0e0f10";
        provider.flashBorrow(address(token), BORROW_AMOUNT, address(callback), payload);
        assertEq(callback.lastData(), payload);
    }

    // ── onMorphoFlashLoan ────────────────────────────────────────────────

    function test_onMorphoFlashLoan_revertsIfCallerNotMorpho() public {
        vm.expectRevert(SepehrErrors.InvalidFlashLoanCallback.selector);
        provider.onMorphoFlashLoan(BORROW_AMOUNT, abi.encode(address(token), address(callback), bytes("")));
    }

    function test_onMorphoFlashLoan_revertsIfNoActiveLoan() public {
        vm.prank(address(morpho));
        vm.expectRevert(SepehrErrors.InvalidFlashLoanCallback.selector);
        provider.onMorphoFlashLoan(BORROW_AMOUNT, abi.encode(address(token), address(callback), bytes("")));
    }

    // ── getFlashLoanFeeBps / isAvailable ─────────────────────────────────

    function test_getFlashLoanFeeBps_isZero() public view {
        assertEq(provider.getFlashLoanFeeBps(address(token)), 0);
    }

    function test_isAvailable_followsMorphoBalance() public view {
        assertTrue(provider.isAvailable(address(token), MORPHO_LIQUIDITY));
        assertFalse(provider.isAvailable(address(token), MORPHO_LIQUIDITY + 1));
    }

    // ── sweep ────────────────────────────────────────────────────────────

    function test_sweep_ownerRecoversDonatedTokens() public {
        token.mint(address(provider), 42e18);
        vm.prank(OWNER);
        provider.sweep(address(token), address(0xBEEF));
        assertEq(token.balanceOf(address(provider)), 0);
        assertEq(token.balanceOf(address(0xBEEF)), 42e18);
    }

    function test_sweep_doesNothingOnZeroBalance() public {
        vm.prank(OWNER);
        provider.sweep(address(token), address(0xBEEF));
        assertEq(token.balanceOf(address(0xBEEF)), 0);
    }

    function test_sweep_revertsWhenNotOwner() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(this)));
        provider.sweep(address(token), address(0xBEEF));
    }

    function test_sweep_revertsOnZeroRecipient() public {
        vm.prank(OWNER);
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        provider.sweep(address(token), address(0));
    }

    // ── Fuzz ─────────────────────────────────────────────────────────────

    function testFuzz_flashBorrow_returnsEveryAmountToMorpho(
        uint128 amount
    ) public {
        vm.assume(amount > 0 && amount <= MORPHO_LIQUIDITY);
        provider.flashBorrow(address(token), uint256(amount), address(callback), "fuzz");
        assertEq(callback.lastFee(), 0);
        assertEq(token.balanceOf(address(morpho)), MORPHO_LIQUIDITY);
        assertEq(token.allowance(address(provider), address(morpho)), 0);
    }
}
