// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BalancerFlashLoanProvider} from "../../../src/flash/BalancerFlashLoanProvider.sol";
import {SepehrErrors} from "../../../src/libraries/SepehrErrors.sol";
import {
    MaliciousBalancerVault,
    MockBalancerFeesCollector,
    MockBalancerVault
} from "../../helpers/MockBalancerVault.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {SimpleCallback} from "../../helpers/SimpleCallback.sol";
import {Test} from "forge-std/Test.sol";

contract BalancerFlashLoanProviderTest is Test {
    BalancerFlashLoanProvider provider;
    MockBalancerVault vault;
    MockBalancerFeesCollector feesCollector;
    MockERC20 token;
    SimpleCallback callback;

    uint256 constant VAULT_LIQUIDITY = 1_000_000e18;
    uint256 constant BORROW_AMOUNT = 100e18;
    address constant OWNER = address(0xA11CE);

    function setUp() public {
        feesCollector = new MockBalancerFeesCollector();
        vault = new MockBalancerVault(address(feesCollector));
        token = new MockERC20("DAI", "DAI");
        callback = new SimpleCallback();
        provider = new BalancerFlashLoanProvider(address(vault), OWNER);

        token.mint(address(vault), VAULT_LIQUIDITY);
    }

    // ── Constructor ──────────────────────────────────────────────────────

    function test_constructor_setsVault() public view {
        assertEq(address(provider.VAULT()), address(vault));
    }

    function test_constructor_setsOwner() public view {
        assertEq(provider.owner(), OWNER);
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new BalancerFlashLoanProvider(address(0), OWNER);
    }

    // ── flashBorrow ──────────────────────────────────────────────────────

    function test_flashBorrow_successfulBorrowAndRepay() public {
        provider.flashBorrow(address(token), BORROW_AMOUNT, address(callback), "bal_data");

        assertEq(callback.lastAsset(), address(token));
        assertEq(callback.lastAmount(), BORROW_AMOUNT);
        assertEq(callback.lastFee(), 0);
        assertEq(callback.lastData(), "bal_data");
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

    // ── receiveFlashLoan ─────────────────────────────────────────────────

    function test_receiveFlashLoan_revertsIfCallerNotVault() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = BORROW_AMOUNT;
        uint256[] memory feeAmounts = new uint256[](1);

        vm.expectRevert(SepehrErrors.InvalidFlashLoanCallback.selector);
        provider.receiveFlashLoan(tokens, amounts, feeAmounts, "");
    }

    function test_receiveFlashLoan_revertsIfNoActiveLoan() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = BORROW_AMOUNT;
        uint256[] memory feeAmounts = new uint256[](1);

        vm.prank(address(vault));
        vm.expectRevert(SepehrErrors.InvalidFlashLoanCallback.selector);
        provider.receiveFlashLoan(tokens, amounts, feeAmounts, "");
    }

    function test_receiveFlashLoan_revertsOnMultiTokenCallback() public {
        // C5: a future Vault upgrade (or compromise) pushing 2-token flash loans
        // must not desynchronise the callback. The provider should bound
        // tokens.length == 1 and revert otherwise.
        MaliciousBalancerVault badVault = new MaliciousBalancerVault(address(feesCollector));
        BalancerFlashLoanProvider badProvider = new BalancerFlashLoanProvider(address(badVault), OWNER);
        token.mint(address(badVault), VAULT_LIQUIDITY);

        vm.expectRevert(SepehrErrors.InvalidFlashLoanCallback.selector);
        badProvider.flashBorrow(address(token), BORROW_AMOUNT, address(callback), "");
    }

    // ── getFlashLoanFeeBps ───────────────────────────────────────────────

    function test_getFlashLoanFeeBps_returnsZeroByDefault() public view {
        assertEq(provider.getFlashLoanFeeBps(address(token)), 0);
    }

    function test_getFlashLoanFeeBps_reflectsCollectorFee() public {
        // 0.1% = 10 bps = 1e15 in 18-decimal
        feesCollector.setFlashLoanFeePercentage(1e15);
        assertEq(provider.getFlashLoanFeeBps(address(token)), 10);
    }

    // C3: sub-1-bp fees must round up rather than truncate to 0. A 0.5-bp fee (5e13) used to
    // report 0 bps, under-funding the repay and causing DoS. Ceiling-division fixes this.
    function test_getFlashLoanFeeBps_subBasisPointRoundsUp() public {
        feesCollector.setFlashLoanFeePercentage(5e13); // 0.5 bps
        assertEq(provider.getFlashLoanFeeBps(address(token)), 1, "half-bp should report 1 bp");
    }

    function test_getFlashLoanFeeBps_oneWeiFeeRoundsUp() public {
        feesCollector.setFlashLoanFeePercentage(1);
        assertEq(provider.getFlashLoanFeeBps(address(token)), 1, "dust fee should report 1 bp");
    }

    function test_getFlashLoanFeeBps_exactBasisPointBoundary() public {
        feesCollector.setFlashLoanFeePercentage(1e14); // exactly 1 bp
        assertEq(provider.getFlashLoanFeeBps(address(token)), 1);

        feesCollector.setFlashLoanFeePercentage(2e14); // exactly 2 bps
        assertEq(provider.getFlashLoanFeeBps(address(token)), 2);
    }

    function test_getFlashLoanFeeBps_zeroStaysZero() public {
        feesCollector.setFlashLoanFeePercentage(0);
        assertEq(provider.getFlashLoanFeeBps(address(token)), 0);
    }

    // C2: re-entry on the same provider must revert.
    function test_flashBorrow_revertsOnConcurrentInvocation() public {
        callback.setReentrantProvider(address(provider));
        callback.setReentrantAsset(address(token));
        callback.setReentrantAmount(BORROW_AMOUNT);
        callback.setReentrantTrigger(true);

        vm.expectRevert();
        provider.flashBorrow(address(token), BORROW_AMOUNT, address(callback), "");
    }

    // C9: per-invocation context (callback + userData) must survive a round-trip
    // through the Vault's `userData` bytes instead of provider storage.
    function test_flashBorrow_forwardsLargeUserDataVerbatim() public {
        bytes memory payload = hex"deadbeefcafebabefeedfacebeefcafebabefeedface0102030405060708090a0b0c0d0e0f10";
        provider.flashBorrow(address(token), BORROW_AMOUNT, address(callback), payload);
        assertEq(callback.lastData(), payload);
    }

    // ── isAvailable ──────────────────────────────────────────────────────

    function test_isAvailable_trueWhenEnoughLiquidity() public view {
        assertTrue(provider.isAvailable(address(token), BORROW_AMOUNT));
    }

    function test_isAvailable_falseWhenInsufficientLiquidity() public view {
        assertFalse(provider.isAvailable(address(token), VAULT_LIQUIDITY + 1));
    }

    // ── C10: sweep ───────────────────────────────────────────────────────

    function test_sweep_ownerRecoversDonatedTokens() public {
        uint256 donation = 42e18;
        token.mint(address(provider), donation);

        address recipient = address(0xBEEF);
        vm.prank(OWNER);
        provider.sweep(address(token), recipient);

        assertEq(token.balanceOf(address(provider)), 0);
        assertEq(token.balanceOf(recipient), donation);
    }

    function test_sweep_revertsWhenNotOwner() public {
        token.mint(address(provider), 1e18);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(this)));
        provider.sweep(address(token), address(0xBEEF));
    }

    function test_sweep_revertsOnZeroRecipient() public {
        token.mint(address(provider), 1e18);
        vm.prank(OWNER);
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        provider.sweep(address(token), address(0));
    }

    // ── Fuzz ─────────────────────────────────────────────────────────────

    function testFuzz_flashBorrow_zeroFee(
        uint128 amount
    ) public {
        vm.assume(amount > 0 && amount <= VAULT_LIQUIDITY);
        provider.flashBorrow(address(token), uint256(amount), address(callback), "fuzz");
        assertEq(callback.lastFee(), 0);
    }
}
