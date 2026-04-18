// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {CurveLlamalendAdapter} from "../../../src/adapters/CurveLlamalendAdapter.sol";
import {SepehrErrors} from "../../../src/libraries/SepehrErrors.sol";
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
    address internal core = makeAddr("core");

    function setUp() public {
        collateralToken = new MockERC20("WETH", "WETH");
        borrowedToken = new MockERC20("crvUSD", "crvUSD");
        priceOracle = makeAddr("priceOracle");

        controller = new MockCurveController(address(collateralToken), address(borrowedToken));

        adapter = new CurveLlamalendAdapter(address(controller), priceOracle, core);
    }

    // ─── Constructor ───────────────────────────────────────────────────

    function test_constructor_revertsOnZeroController() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new CurveLlamalendAdapter(address(0), priceOracle, core);
    }

    function test_constructor_revertsOnZeroPriceOracle() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new CurveLlamalendAdapter(address(controller), address(0), core);
    }

    function test_constructor_revertsOnZeroCore() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new CurveLlamalendAdapter(address(controller), priceOracle, address(0));
    }

    function test_constructor_storesImmutables() public view {
        assertEq(address(adapter.CONTROLLER()), address(controller));
        assertEq(adapter.PRICE_ORACLE(), priceOracle);
        assertEq(adapter.core(), core);
    }

    // ─── getHealthFactor ───────────────────────────────────────────────

    /// @dev B18: zero-debt positions return `type(uint256).max`. Tests exercising the health-
    /// conversion math need a non-zero debt in `user_state[2]` or they short-circuit to max.
    function _seedDebt(
        address u
    ) internal {
        controller.setUserState(u, 0, 0, 1, 0);
    }

    function test_getHealthFactor_zeroDebtReturnsMax() public view {
        // B18: no debt ⇒ HF = type(uint256).max regardless of Curve's `health` return value.
        assertEq(adapter.getHealthFactor(user), type(uint256).max);
    }

    function test_getHealthFactor_returnsOneAtThreshold() public {
        // Curve health = 0 is the liquidation boundary ⇒ HF = 1.0.
        _seedDebt(user);
        controller.setHealth(user, 0);
        assertEq(adapter.getHealthFactor(user), 1e18);
    }

    function test_getHealthFactor_returnsZeroWhenClamped() public {
        // health ≤ -1e18 ⇒ HF = 0 (margin gone, position unredeemable).
        _seedDebt(user);
        controller.setHealth(user, -1e18);
        assertEq(adapter.getHealthFactor(user), 0);
        controller.setHealth(user, -2e18);
        assertEq(adapter.getHealthFactor(user), 0);
    }

    function test_getHealthFactor_negativeButAboveFloor() public {
        // health = -0.5e18 ⇒ HF = 0.5e18 (below liquidation, not yet worthless).
        _seedDebt(user);
        controller.setHealth(user, -0.5e18);
        assertEq(adapter.getHealthFactor(user), 0.5e18);
    }

    function test_getHealthFactor_convertsPositiveHealth() public {
        _seedDebt(user);
        controller.setHealth(user, 0.5e18);
        assertEq(adapter.getHealthFactor(user), 1.5e18);
    }

    function test_getHealthFactor_highHealth() public {
        _seedDebt(user);
        controller.setHealth(user, 2e18);
        assertEq(adapter.getHealthFactor(user), 3e18);
    }

    function test_getHealthFactor_differentUsers() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        _seedDebt(alice);
        _seedDebt(bob);
        controller.setHealth(alice, 0.1e18);
        controller.setHealth(bob, 1e18);

        assertEq(adapter.getHealthFactor(alice), 1.1e18);
        assertEq(adapter.getHealthFactor(bob), 2e18);
    }

    // ─── checkDelegation ───────────────────────────────────────────────

    function test_checkDelegation_alwaysReturnsFalse() public view {
        // Curve LLAMMA exposes no per-spender delegation primitive; the adapter must
        // report `false` so `enableProtection` cannot be armed for unsupported positions.
        assertFalse(adapter.checkDelegation(user));
    }

    function test_checkDelegation_falseForAnyAddress() public {
        assertFalse(adapter.checkDelegation(makeAddr("random")));
        assertFalse(adapter.checkDelegation(address(0)));
    }

    // ─── repay ─────────────────────────────────────────────────────────

    function test_repay_revertsWhenNotCore() public {
        vm.expectRevert(SepehrErrors.NotAuthorized.selector);
        adapter.repay(user, address(borrowedToken), 1e18);
    }

    function test_repay_revertsOnZeroAmount() public {
        vm.prank(core);
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        adapter.repay(user, address(borrowedToken), 0);
    }

    function test_repay_approvesControllerAndCallsRepay() public {
        uint256 amount = 100e18;
        borrowedToken.mint(address(adapter), amount);

        vm.prank(core);
        adapter.repay(user, address(borrowedToken), amount);

        assertEq(controller.repayCallCount(), 1);
        (uint256 repaidAmount, address _for) = controller.repayCalls(0);
        assertEq(repaidAmount, amount);
        assertEq(_for, user);
    }

    function test_repay_transfersTokensToController() public {
        uint256 amount = 75e18;
        borrowedToken.mint(address(adapter), amount);

        vm.prank(core);
        adapter.repay(user, address(borrowedToken), amount);

        assertEq(borrowedToken.balanceOf(address(controller)), amount);
        assertEq(borrowedToken.balanceOf(address(adapter)), 0);
    }

    // ─── withdrawCollateral ────────────────────────────────────────────

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

    function test_withdrawCollateral_callsRemoveCollateral() public {
        uint256 amount = 10e18;
        collateralToken.mint(address(controller), amount);

        vm.prank(core);
        adapter.withdrawCollateral(user, address(collateralToken), amount, recipient);

        assertEq(controller.removeCollateralCallCount(), 1);
        (uint256 removedAmount) = controller.removeCollateralCalls(0);
        assertEq(removedAmount, amount);
    }

    function test_withdrawCollateral_transfersCollateralToRecipient() public {
        uint256 amount = 5e18;
        collateralToken.mint(address(controller), amount);

        vm.prank(core);
        adapter.withdrawCollateral(user, address(collateralToken), amount, recipient);

        assertEq(collateralToken.balanceOf(recipient), amount);
        assertEq(collateralToken.balanceOf(address(adapter)), 0);
    }

    function test_withdrawCollateral_doesNotSweepPreExistingDonation() public {
        // Audit B21: a pre-existing donation on the adapter (from an errant transfer or a
        // griefing depositor) must stay put — the function should only forward the delta
        // pulled in by `remove_collateral`, never the adapter's full `balanceOf`.
        uint256 donation = 3e18;
        uint256 withdraw = 5e18;
        collateralToken.mint(address(adapter), donation);
        collateralToken.mint(address(controller), withdraw);

        vm.prank(core);
        adapter.withdrawCollateral(user, address(collateralToken), withdraw, recipient);

        assertEq(collateralToken.balanceOf(recipient), withdraw, "recipient got exactly withdraw amount");
        assertEq(collateralToken.balanceOf(address(adapter)), donation, "donation stays on the adapter");
    }

    // ─── getCollateralValueUsd ─────────────────────────────────────────

    function test_getCollateralValueUsd_returnsZeroWhenBothZero() public {
        controller.setUserState(user, 0, 0, 0, 0);
        assertEq(adapter.getCollateralValueUsd(user), 0);
    }

    function test_getCollateralValueUsd_stablecoinOnly() public {
        // Stablecoin only — price doesn't matter because collateral=0.
        controller.setUserState(user, 0, 500e18, 0, 0);
        assertEq(adapter.getCollateralValueUsd(user), 500e8);
    }

    function test_getCollateralValueUsd_collateralOnly() public {
        // 100e18 collateral @ $2500 (WAD) → USD-18 = 250_000e18 → USD-8 = 250_000e8.
        controller.setUserState(user, 100e18, 0, 0, 0);
        controller.setPrice(2500e18);
        assertEq(adapter.getCollateralValueUsd(user), 250_000e8);
    }

    function test_getCollateralValueUsd_bothNonZero() public {
        // 100e18 coll @ $2500 = 250_000e18 USD-18; + 200e18 stab = 250_200e18; → 250_200e8 USD-8.
        controller.setUserState(user, 100e18, 200e18, 0, 0);
        controller.setPrice(2500e18);
        assertEq(adapter.getCollateralValueUsd(user), 250_200e8);
    }

    // ─── Fuzz tests ────────────────────────────────────────────────────

    function testFuzz_getHealthFactor_belowFloorReturnsZero(
        int256 health
    ) public {
        health = bound(health, type(int256).min, -1e18);
        _seedDebt(user);
        controller.setHealth(user, health);
        assertEq(adapter.getHealthFactor(user), 0);
    }

    function testFuzz_getHealthFactor_aboveFloorAddsOne(
        int256 health
    ) public {
        health = bound(health, -1e18 + 1, type(int128).max);
        _seedDebt(user);
        controller.setHealth(user, health);
        assertEq(adapter.getHealthFactor(user), uint256(int256(1e18) + health));
    }

    function testFuzz_repayAmount(
        uint256 amount
    ) public {
        amount = bound(amount, 1, type(uint128).max);
        borrowedToken.mint(address(adapter), amount);

        vm.prank(core);
        adapter.repay(user, address(borrowedToken), amount);

        assertEq(controller.repayCallCount(), 1);
        (uint256 repaidAmount, address _for) = controller.repayCalls(0);
        assertEq(repaidAmount, amount);
        assertEq(_for, user);
    }

    function testFuzz_getCollateralValueUsd(
        uint128 collateral,
        uint128 stablecoin,
        uint64 priceWad
    ) public {
        vm.assume(priceWad > 0);

        controller.setUserState(user, collateral, stablecoin, 0, 0);
        controller.setPrice(uint256(priceWad));

        uint256 collateralUsd18 = uint256(collateral) * uint256(priceWad) / 1e18;
        uint256 expected = (collateralUsd18 + uint256(stablecoin)) / 1e10;
        assertEq(adapter.getCollateralValueUsd(user), expected);
    }
}
