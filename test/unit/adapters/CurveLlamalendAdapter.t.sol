// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {CurveLlamalendAdapter} from "../../../src/adapters/CurveLlamalendAdapter.sol";
import {AegisErrors} from "../../../src/libraries/AegisErrors.sol";
import {MockCurveController} from "../../helpers/MockCurveController.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {Test} from "forge-std/Test.sol";

contract CurveLlamalendAdapterTest is Test {
    CurveLlamalendAdapter internal adapter;
    MockCurveController internal controller;
    MockERC20 internal collateralToken;
    MockERC20 internal borrowedToken;
    address internal priceOracle;

    address internal user = makeAddr("user");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        collateralToken = new MockERC20("WETH", "WETH");
        borrowedToken = new MockERC20("crvUSD", "crvUSD");
        priceOracle = makeAddr("priceOracle");

        controller = new MockCurveController(address(collateralToken), address(borrowedToken));

        adapter = new CurveLlamalendAdapter(address(controller), priceOracle);
    }

    // ─── Constructor ───────────────────────────────────────────────────

    function test_constructor_revertsOnZeroController() public {
        vm.expectRevert(AegisErrors.ZeroAddress.selector);
        new CurveLlamalendAdapter(address(0), priceOracle);
    }

    function test_constructor_revertsOnZeroPriceOracle() public {
        vm.expectRevert(AegisErrors.ZeroAddress.selector);
        new CurveLlamalendAdapter(address(controller), address(0));
    }

    function test_constructor_storesImmutables() public view {
        assertEq(address(adapter.CONTROLLER()), address(controller));
        assertEq(adapter.PRICE_ORACLE(), priceOracle);
    }

    // ─── getHealthFactor ───────────────────────────────────────────────

    function test_getHealthFactor_returnsZeroWhenHealthIsZero() public {
        controller.setHealth(user, 0);
        assertEq(adapter.getHealthFactor(user), 0);
    }

    function test_getHealthFactor_returnsZeroWhenHealthIsNegative() public {
        controller.setHealth(user, -1e18);
        assertEq(adapter.getHealthFactor(user), 0);
    }

    function test_getHealthFactor_convertsPositiveHealth() public {
        // health = 0.5e18 → HF = 1e18 + 0.5e18 = 1.5e18
        controller.setHealth(user, 0.5e18);
        assertEq(adapter.getHealthFactor(user), 1.5e18);
    }

    function test_getHealthFactor_atThreshold() public {
        // health = 0 → HF = 0 (at liquidation)
        controller.setHealth(user, 0);
        assertEq(adapter.getHealthFactor(user), 0);
    }

    function test_getHealthFactor_highHealth() public {
        // health = 2e18 → HF = 1e18 + 2e18 = 3e18
        controller.setHealth(user, 2e18);
        assertEq(adapter.getHealthFactor(user), 3e18);
    }

    function test_getHealthFactor_differentUsers() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        controller.setHealth(alice, 0.1e18);
        controller.setHealth(bob, 1e18);

        assertEq(adapter.getHealthFactor(alice), 1.1e18);
        assertEq(adapter.getHealthFactor(bob), 2e18);
    }

    // ─── checkDelegation ───────────────────────────────────────────────

    function test_checkDelegation_alwaysReturnsTrue() public view {
        assertTrue(adapter.checkDelegation(user));
    }

    function test_checkDelegation_trueForAnyAddress() public {
        assertTrue(adapter.checkDelegation(makeAddr("random")));
        assertTrue(adapter.checkDelegation(address(0)));
    }

    // ─── repay ─────────────────────────────────────────────────────────

    function test_repay_revertsOnZeroAmount() public {
        vm.expectRevert(AegisErrors.ZeroAmount.selector);
        adapter.repay(user, address(borrowedToken), 0);
    }

    function test_repay_approvesControllerAndCallsRepay() public {
        uint256 amount = 100e18;
        borrowedToken.mint(address(adapter), amount);

        adapter.repay(user, address(borrowedToken), amount);

        assertEq(controller.repayCallCount(), 1);
        (uint256 repaidAmount, address _for) = controller.repayCalls(0);
        assertEq(repaidAmount, amount);
        assertEq(_for, user);
    }

    function test_repay_transfersTokensToController() public {
        uint256 amount = 75e18;
        borrowedToken.mint(address(adapter), amount);

        adapter.repay(user, address(borrowedToken), amount);

        assertEq(borrowedToken.balanceOf(address(controller)), amount);
        assertEq(borrowedToken.balanceOf(address(adapter)), 0);
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

    function test_withdrawCollateral_callsRemoveCollateral() public {
        uint256 amount = 10e18;
        collateralToken.mint(address(controller), amount);

        adapter.withdrawCollateral(user, address(collateralToken), amount, recipient);

        assertEq(controller.removeCollateralCallCount(), 1);
        (uint256 removedAmount) = controller.removeCollateralCalls(0);
        assertEq(removedAmount, amount);
    }

    function test_withdrawCollateral_transfersCollateralToRecipient() public {
        uint256 amount = 5e18;
        collateralToken.mint(address(controller), amount);

        adapter.withdrawCollateral(user, address(collateralToken), amount, recipient);

        assertEq(collateralToken.balanceOf(recipient), amount);
        assertEq(collateralToken.balanceOf(address(adapter)), 0);
    }

    // ─── getCollateralValueUsd ─────────────────────────────────────────

    function test_getCollateralValueUsd_returnsZeroWhenBothZero() public {
        controller.setUserState(user, 0, 0, 0, 0);
        assertEq(adapter.getCollateralValueUsd(user), 0);
    }

    function test_getCollateralValueUsd_stablecoinOnly() public {
        // stablecoin=500e18, collateral=0
        // result = (500e18 + 0) / 1e10 = 500e8
        controller.setUserState(user, 0, 500e18, 0, 0);
        assertEq(adapter.getCollateralValueUsd(user), 500e8);
    }

    function test_getCollateralValueUsd_collateralOnly() public {
        // collateral=100e18, stablecoin=0
        // result = (100e18 + 0) / 1e10 = 100e8
        controller.setUserState(user, 100e18, 0, 0, 0);
        assertEq(adapter.getCollateralValueUsd(user), 100e8);
    }

    function test_getCollateralValueUsd_bothNonZero() public {
        // collateral=100e18, stablecoin=200e18
        // result = (200e18 + 100e18) / 1e10 = 300e8
        controller.setUserState(user, 100e18, 200e18, 0, 0);
        assertEq(adapter.getCollateralValueUsd(user), 300e8);
    }

    // ─── Fuzz tests ────────────────────────────────────────────────────

    function testFuzz_getHealthFactor_negativeReturnsZero(
        int256 health
    ) public {
        health = bound(health, type(int256).min, 0);
        controller.setHealth(user, health);
        assertEq(adapter.getHealthFactor(user), 0);
    }

    function testFuzz_getHealthFactor_positiveAddsOne(
        int256 health
    ) public {
        health = bound(health, 1, type(int128).max);
        controller.setHealth(user, health);
        assertEq(adapter.getHealthFactor(user), 1e18 + uint256(health));
    }

    function testFuzz_repayAmount(
        uint256 amount
    ) public {
        amount = bound(amount, 1, type(uint128).max);
        borrowedToken.mint(address(adapter), amount);

        adapter.repay(user, address(borrowedToken), amount);

        assertEq(controller.repayCallCount(), 1);
        (uint256 repaidAmount, address _for) = controller.repayCalls(0);
        assertEq(repaidAmount, amount);
        assertEq(_for, user);
    }

    function testFuzz_getCollateralValueUsd(
        uint256 collateral,
        uint256 stablecoin
    ) public {
        collateral = bound(collateral, 0, type(uint128).max);
        stablecoin = bound(stablecoin, 0, type(uint128).max);

        controller.setUserState(user, collateral, stablecoin, 0, 0);

        if (collateral == 0 && stablecoin == 0) {
            assertEq(adapter.getCollateralValueUsd(user), 0);
        } else {
            uint256 expected = (stablecoin + collateral) / 1e10;
            assertEq(adapter.getCollateralValueUsd(user), expected);
        }
    }
}
