// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {BalancerFlashLoanProvider} from "../../../src/flash/BalancerFlashLoanProvider.sol";
import {AegisErrors} from "../../../src/libraries/AegisErrors.sol";
import {MockBalancerFeesCollector, MockBalancerVault} from "../../helpers/MockBalancerVault.sol";
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

    function setUp() public {
        feesCollector = new MockBalancerFeesCollector();
        vault = new MockBalancerVault(address(feesCollector));
        token = new MockERC20("DAI", "DAI");
        callback = new SimpleCallback();
        provider = new BalancerFlashLoanProvider(address(vault));

        token.mint(address(vault), VAULT_LIQUIDITY);
    }

    // ── Constructor ──────────────────────────────────────────────────────

    function test_constructor_setsVault() public view {
        assertEq(address(provider.VAULT()), address(vault));
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(AegisErrors.ZeroAddress.selector);
        new BalancerFlashLoanProvider(address(0));
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
        vm.expectRevert(AegisErrors.ZeroAddress.selector);
        provider.flashBorrow(address(token), BORROW_AMOUNT, address(0), "");
    }

    function test_flashBorrow_revertsOnZeroAmount() public {
        vm.expectRevert(AegisErrors.ZeroAmount.selector);
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

        vm.expectRevert(AegisErrors.InvalidFlashLoanCallback.selector);
        provider.receiveFlashLoan(tokens, amounts, feeAmounts, "");
    }

    function test_receiveFlashLoan_revertsIfNoActiveLoan() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = BORROW_AMOUNT;
        uint256[] memory feeAmounts = new uint256[](1);

        vm.prank(address(vault));
        vm.expectRevert(AegisErrors.InvalidFlashLoanCallback.selector);
        provider.receiveFlashLoan(tokens, amounts, feeAmounts, "");
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

    // ── isAvailable ──────────────────────────────────────────────────────

    function test_isAvailable_trueWhenEnoughLiquidity() public view {
        assertTrue(provider.isAvailable(address(token), BORROW_AMOUNT));
    }

    function test_isAvailable_falseWhenInsufficientLiquidity() public view {
        assertFalse(provider.isAvailable(address(token), VAULT_LIQUIDITY + 1));
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
