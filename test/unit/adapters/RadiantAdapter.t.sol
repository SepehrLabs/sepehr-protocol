// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {RadiantAdapter} from "../../../src/adapters/RadiantAdapter.sol";
import {SepehrErrors} from "../../../src/libraries/SepehrErrors.sol";
import {MockAavePoolAdapter} from "../../helpers/MockAavePoolAdapter.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {Test} from "forge-std/Test.sol";

contract RadiantAdapterTest is Test {
    RadiantAdapter internal adapter;
    MockAavePoolAdapter internal pool;
    MockERC20 internal debtToken;
    MockERC20 internal rToken;
    MockERC20 internal collateralToken;

    address internal user = makeAddr("user");
    address internal recipient = makeAddr("recipient");
    address internal core = makeAddr("core");

    function setUp() public {
        debtToken = new MockERC20("Debt", "DEBT");
        rToken = new MockERC20("rToken", "rTKN");
        collateralToken = new MockERC20("Collateral", "COL");
        pool = new MockAavePoolAdapter(address(collateralToken));
        adapter = new RadiantAdapter(address(pool), address(rToken), core);
    }

    function test_constructor_revertsOnZeroPool() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new RadiantAdapter(address(0), address(rToken), core);
    }

    function test_constructor_revertsOnZeroRToken() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new RadiantAdapter(address(pool), address(0), core);
    }

    function test_constructor_revertsOnZeroCore() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new RadiantAdapter(address(pool), address(rToken), address(0));
    }

    function test_constructor_storesImmutables() public view {
        assertEq(address(adapter.POOL()), address(pool));
        assertEq(adapter.RTOKEN(), address(rToken));
        assertEq(adapter.core(), core);
    }

    function test_getHealthFactor_returnsPoolValue() public {
        pool.setUserAccountData(user, 100e8, 50e8, 25e8, 8000, 7500, 1.1e18);
        assertEq(adapter.getHealthFactor(user), 1.1e18);
    }

    function test_checkDelegation_reflectsAllowance() public {
        assertFalse(adapter.checkDelegation(user));
        vm.prank(user);
        rToken.approve(address(adapter), 1);
        assertTrue(adapter.checkDelegation(user));
    }

    function test_repay_revertsWhenNotCore() public {
        vm.expectRevert(SepehrErrors.NotAuthorized.selector);
        adapter.repay(user, address(debtToken), 1e18);
    }

    function test_repay_revertsOnZero() public {
        vm.prank(core);
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        adapter.repay(user, address(debtToken), 0);
    }

    function test_repay_approvesPoolAndSendsTokens() public {
        debtToken.mint(address(adapter), 100e18);
        vm.prank(core);
        adapter.repay(user, address(debtToken), 100e18);
        assertEq(pool.repayCallCount(), 1);
        assertEq(debtToken.balanceOf(address(pool)), 100e18);
    }

    function test_withdrawCollateral_revertsWhenNotCore() public {
        vm.expectRevert(SepehrErrors.NotAuthorized.selector);
        adapter.withdrawCollateral(user, address(collateralToken), 1e18, recipient);
    }

    function test_withdrawCollateral_revertsOnZeroAmount() public {
        vm.prank(core);
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        adapter.withdrawCollateral(user, address(collateralToken), 0, recipient);
    }

    function test_withdrawCollateral_revertsOnZeroRecipient() public {
        vm.prank(core);
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        adapter.withdrawCollateral(user, address(collateralToken), 1e18, address(0));
    }

    function test_withdrawCollateral_fullFlow() public {
        rToken.mint(user, 5e18);
        collateralToken.mint(address(pool), 5e18);
        vm.prank(user);
        rToken.approve(address(adapter), 5e18);

        vm.prank(core);
        adapter.withdrawCollateral(user, address(collateralToken), 5e18, recipient);

        assertEq(collateralToken.balanceOf(recipient), 5e18);
        assertEq(pool.withdrawCallCount(), 1);
    }

    function test_getCollateralValueUsd_returnsTotalCollateralBase() public {
        pool.setUserAccountData(user, 75_000e8, 0, 0, 0, 0, 0);
        assertEq(adapter.getCollateralValueUsd(user), 75_000e8);
    }

    function testFuzz_repayAmount(
        uint256 amount
    ) public {
        amount = bound(amount, 1, type(uint128).max);
        debtToken.mint(address(adapter), amount);
        vm.prank(core);
        adapter.repay(user, address(debtToken), amount);
        assertEq(debtToken.balanceOf(address(pool)), amount);
    }
}
