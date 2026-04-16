// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {FluidAdapter} from "../../../src/adapters/FluidAdapter.sol";
import {AegisErrors} from "../../../src/libraries/AegisErrors.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {MockFluidVault} from "../../helpers/MockFluidVault.sol";
import {Test} from "forge-std/Test.sol";

contract FluidAdapterTest is Test {
    FluidAdapter internal adapter;
    MockFluidVault internal vault;
    MockERC20 internal debtToken;
    MockERC20 internal collateralToken;

    address internal user = makeAddr("user");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        debtToken = new MockERC20("Debt Token", "DEBT");
        collateralToken = new MockERC20("Collateral", "COL");

        vault = new MockFluidVault(address(debtToken));
        adapter = new FluidAdapter(address(vault));
    }

    // ─── Constructor ───────────────────────────────────────────────────

    function test_constructor_revertsOnZeroVault() public {
        vm.expectRevert(AegisErrors.ZeroAddress.selector);
        new FluidAdapter(address(0));
    }

    function test_constructor_storesImmutable() public view {
        assertEq(address(adapter.VAULT()), address(vault));
    }

    // ─── getHealthFactor ───────────────────────────────────────────────

    function test_getHealthFactor_delegatesToVault() public {
        uint256 expectedHF = 1.8e18;
        vault.setHealthFactor(user, expectedHF);

        assertEq(adapter.getHealthFactor(user), expectedHF);
    }

    function test_getHealthFactor_differentUsers() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        vault.setHealthFactor(alice, 3e18);
        vault.setHealthFactor(bob, 1.1e18);

        assertEq(adapter.getHealthFactor(alice), 3e18);
        assertEq(adapter.getHealthFactor(bob), 1.1e18);
    }

    function test_getHealthFactor_returnsZeroForUnknownUser() public {
        address unknown = makeAddr("unknown");
        assertEq(adapter.getHealthFactor(unknown), 0);
    }

    // ─── checkDelegation ───────────────────────────────────────────────

    function test_checkDelegation_returnsTrueWhenAuthorized() public {
        vault.setAuth(user, address(adapter), true);

        assertTrue(adapter.checkDelegation(user));
    }

    function test_checkDelegation_returnsFalseWhenNotAuthorized() public view {
        assertFalse(adapter.checkDelegation(user));
    }

    function test_checkDelegation_returnsFalseAfterRevocation() public {
        vault.setAuth(user, address(adapter), true);
        assertTrue(adapter.checkDelegation(user));

        vault.setAuth(user, address(adapter), false);
        assertFalse(adapter.checkDelegation(user));
    }

    // ─── repay ─────────────────────────────────────────────────────────

    function test_repay_revertsOnZeroAmount() public {
        vm.expectRevert(AegisErrors.ZeroAmount.selector);
        adapter.repay(user, address(debtToken), 0);
    }

    function test_repay_approvesVaultAndCallsRepay() public {
        uint256 amount = 100e18;
        debtToken.mint(address(adapter), amount);

        adapter.repay(user, address(debtToken), amount);

        assertEq(vault.repayCallCount(), 1);
        (address onBehalfOf, uint256 repaidAmount) = vault.repayCalls(0);
        assertEq(onBehalfOf, user);
        assertEq(repaidAmount, amount);
    }

    function test_repay_transfersTokensToVault() public {
        uint256 amount = 75e18;
        debtToken.mint(address(adapter), amount);

        adapter.repay(user, address(debtToken), amount);

        assertEq(debtToken.balanceOf(address(vault)), amount);
        assertEq(debtToken.balanceOf(address(adapter)), 0);
    }

    // ─── withdrawCollateral ────────────────────────────────────────────

    function test_withdrawCollateral_revertsOnZeroAmount() public {
        vm.expectRevert(AegisErrors.ZeroAmount.selector);
        adapter.withdrawCollateral(user, address(collateralToken), 0, recipient);
    }

    function test_withdrawCollateral_revertsOnZeroRecipient() public {
        vm.expectRevert(AegisErrors.ZeroAddress.selector);
        adapter.withdrawCollateral(user, address(collateralToken), 1e18, address(0));
    }

    function test_withdrawCollateral_callsVaultWithdraw() public {
        uint256 amount = 10e18;
        // Fund the vault so it can send tokens to recipient
        collateralToken.mint(address(vault), amount);

        // The FluidAdapter calls VAULT.withdraw(amount, recipient) using debtToken as underlying
        // but the vault's withdraw sends UNDERLYING (debtToken) — for this test, fund with debtToken
        debtToken.mint(address(vault), amount);

        adapter.withdrawCollateral(user, address(collateralToken), amount, recipient);

        assertEq(vault.withdrawCallCount(), 1);
        (uint256 withdrawnAmount, address to) = vault.withdrawCalls(0);
        assertEq(withdrawnAmount, amount);
        assertEq(to, recipient);
    }

    // ─── getCollateralValueUsd ─────────────────────────────────────────

    function test_getCollateralValueUsd_delegatesToVault() public {
        uint256 collateralValue = 250_000e8;
        vault.setCollateralValueUsd(user, collateralValue);

        assertEq(adapter.getCollateralValueUsd(user), collateralValue);
    }

    function test_getCollateralValueUsd_returnsZeroForUnknownUser() public {
        address nobody = makeAddr("nobody");
        assertEq(adapter.getCollateralValueUsd(nobody), 0);
    }

    function test_getCollateralValueUsd_differentUsers() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        vault.setCollateralValueUsd(alice, 100_000e8);
        vault.setCollateralValueUsd(bob, 999_999e8);

        assertEq(adapter.getCollateralValueUsd(alice), 100_000e8);
        assertEq(adapter.getCollateralValueUsd(bob), 999_999e8);
    }

    // ─── Fuzz tests ────────────────────────────────────────────────────

    function testFuzz_getHealthFactor(
        uint256 hf
    ) public {
        vault.setHealthFactor(user, hf);
        assertEq(adapter.getHealthFactor(user), hf);
    }

    function testFuzz_repayAmount(
        uint256 amount
    ) public {
        amount = bound(amount, 1, type(uint128).max);
        debtToken.mint(address(adapter), amount);

        adapter.repay(user, address(debtToken), amount);

        assertEq(vault.repayCallCount(), 1);
        (, uint256 repaidAmount) = vault.repayCalls(0);
        assertEq(repaidAmount, amount);
    }

    function testFuzz_getCollateralValueUsd(
        uint256 usdValue
    ) public {
        vault.setCollateralValueUsd(user, usdValue);
        assertEq(adapter.getCollateralValueUsd(user), usdValue);
    }
}
