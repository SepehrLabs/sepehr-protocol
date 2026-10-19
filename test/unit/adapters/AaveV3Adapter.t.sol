// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AaveV3Adapter} from "../../../src/adapters/AaveV3Adapter.sol";
import {SepehrErrors} from "../../../src/libraries/SepehrErrors.sol";
import {MockAavePoolAdapter} from "../../helpers/MockAavePoolAdapter.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {Test} from "forge-std/Test.sol";

contract AaveV3AdapterTest is Test {
    AaveV3Adapter internal adapter;
    MockAavePoolAdapter internal pool;
    MockERC20 internal debtToken;
    MockERC20 internal aToken;
    MockERC20 internal collateralToken;

    address internal user = makeAddr("user");
    address internal recipient = makeAddr("recipient");
    address internal core = makeAddr("core");

    function setUp() public {
        debtToken = new MockERC20("Debt Token", "DEBT");
        aToken = new MockERC20("aToken", "aTKN");
        collateralToken = new MockERC20("Collateral", "COL");

        pool = new MockAavePoolAdapter(address(collateralToken));
        pool.setAToken(address(collateralToken), address(aToken));
        pool.addReserve(address(collateralToken));
        // Reserve 0 used as collateral: bit 2 * 0 + 1.
        pool.setUserConfiguration(user, 1 << 1);
        adapter = new AaveV3Adapter(address(pool), core);
    }

    // ─── Constructor ───────────────────────────────────────────────────

    function test_constructor_revertsOnZeroPool() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new AaveV3Adapter(address(0), core);
    }

    function test_constructor_revertsOnZeroCore() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new AaveV3Adapter(address(pool), address(0));
    }

    function test_constructor_storesImmutables() public view {
        assertEq(address(adapter.POOL()), address(pool));
        assertEq(adapter.core(), core);
    }

    // ─── getHealthFactor ───────────────────────────────────────────────

    function test_getHealthFactor_returnsCorrectValue() public {
        uint256 expectedHF = 1.5e18;
        pool.setUserAccountData(user, 100e8, 50e8, 25e8, 8000, 7500, expectedHF);

        uint256 hf = adapter.getHealthFactor(user);
        assertEq(hf, expectedHF);
    }

    function test_getHealthFactor_differentUsers() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        pool.setUserAccountData(alice, 200e8, 100e8, 50e8, 8000, 7500, 2e18);
        pool.setUserAccountData(bob, 300e8, 250e8, 10e8, 8500, 8000, 1.05e18);

        assertEq(adapter.getHealthFactor(alice), 2e18);
        assertEq(adapter.getHealthFactor(bob), 1.05e18);
    }

    function test_getHealthFactor_returnsZeroForUnknownUser() public {
        address unknown = makeAddr("unknown");
        assertEq(adapter.getHealthFactor(unknown), 0);
    }

    // ─── checkDelegation ───────────────────────────────────────────────

    function test_checkDelegation_returnsFalseWhenDustAllowance() public {
        // Audit B20: dust approvals must not pass delegation — the trigger would
        // revert on the aToken transferFrom that pulls the user's full share.
        vm.prank(user);
        aToken.approve(address(adapter), 1);

        assertFalse(adapter.checkDelegation(user));
    }

    function test_checkDelegation_returnsFalseWhenAllowanceZero() public view {
        assertFalse(adapter.checkDelegation(user));
    }

    function test_checkDelegation_returnsFalseBelowThreshold() public {
        // Audit B20: boundary — allowance just below the threshold fails.
        vm.prank(user);
        aToken.approve(address(adapter), uint256(type(uint128).max) - 1);

        assertFalse(adapter.checkDelegation(user));
    }

    function test_checkDelegation_returnsTrueAtThreshold() public {
        aToken.mint(user, 1e18);
        // Audit B20: boundary — allowance exactly at the threshold passes.
        vm.prank(user);
        aToken.approve(address(adapter), uint256(type(uint128).max));

        assertTrue(adapter.checkDelegation(user));
    }

    /// @dev M-3: an approval without any of the aToken is not a usable delegation.
    function test_checkDelegation_returnsFalseWhenUserHoldsNoAToken() public {
        address empty = makeAddr("empty");
        pool.setUserConfiguration(empty, 1 << 1);
        vm.prank(empty);
        aToken.approve(address(adapter), type(uint256).max);

        assertFalse(adapter.checkDelegation(empty));
    }

    /// @dev An approved aToken that the user does not use as collateral does not count.
    function test_checkDelegation_ignoresAssetsNotUsedAsCollateral() public {
        aToken.mint(user, 1e18);
        vm.prank(user);
        aToken.approve(address(adapter), type(uint256).max);
        pool.setUserConfiguration(user, 1 << 0); // borrowing reserve 0, not collateral

        assertFalse(adapter.checkDelegation(user));
    }

    /// @dev M-3: with several collaterals, one approved collateral is enough for the core;
    ///      the keeper withdraws among the approved ones.
    function test_checkDelegation_trueWhenAnyCollateralIsApproved() public {
        (MockERC20 second, MockERC20 secondAToken) = _secondCollateral();
        aToken.mint(user, 1e18); // held, not approved
        secondAToken.mint(user, 1e18);
        vm.prank(user);
        secondAToken.approve(address(adapter), type(uint256).max);

        assertTrue(adapter.checkDelegation(user));
        assertFalse(adapter.isDelegated(user, address(collateralToken)));
        assertTrue(adapter.isDelegated(user, address(second)));
    }

    function test_isDelegated_falseForAnAssetAaveDoesNotList() public {
        assertFalse(adapter.isDelegated(user, makeAddr("unlisted")));
    }

    function test_collateralsOf_listsEachCollateralWithBalanceAndAllowance() public {
        (MockERC20 second, MockERC20 secondAToken) = _secondCollateral();
        aToken.mint(user, 3e18);
        secondAToken.mint(user, 2e18);
        vm.prank(user);
        secondAToken.approve(address(adapter), type(uint256).max);

        AaveV3Adapter.Collateral[] memory list = adapter.collateralsOf(user);

        assertEq(list.length, 2);
        assertEq(list[0].asset, address(collateralToken));
        assertEq(list[0].aToken, address(aToken));
        assertEq(list[0].symbol, "COL");
        assertEq(list[0].balance, 3e18);
        assertEq(list[0].allowance, 0);
        assertEq(list[1].asset, address(second));
        assertEq(list[1].symbol, "SEC");
        assertEq(list[1].allowance, type(uint256).max);
    }

    function test_collateralsOf_leavesOutReservesNotUsedAsCollateral() public {
        _secondCollateral();
        pool.setUserConfiguration(user, (1 << 1) | (1 << 2)); // reserve 1 borrowed, not collateral
        AaveV3Adapter.Collateral[] memory list = adapter.collateralsOf(user);
        assertEq(list.length, 1);
        assertEq(list[0].asset, address(collateralToken));
    }

    function test_collateralsOf_isEmptyWithoutCollateral() public {
        assertEq(adapter.collateralsOf(makeAddr("nobody")).length, 0);
    }

    /// @dev Lists a second collateral (reserve 1) that `user` also supplies.
    function _secondCollateral() internal returns (MockERC20 second, MockERC20 secondAToken) {
        second = new MockERC20("Second", "SEC");
        secondAToken = new MockERC20("aSecond", "aSEC");
        pool.setAToken(address(second), address(secondAToken));
        pool.addReserve(address(second));
        pool.setUserConfiguration(user, (1 << 1) | (1 << 3));
    }

    function test_checkDelegation_returnsTrueWithMaxAllowance() public {
        aToken.mint(user, 1e18);
        vm.prank(user);
        aToken.approve(address(adapter), type(uint256).max);

        assertTrue(adapter.checkDelegation(user));
    }

    // ─── repay ─────────────────────────────────────────────────────────

    function test_repay_revertsWhenNotCore() public {
        vm.expectRevert(SepehrErrors.NotAuthorized.selector);
        adapter.repay(user, address(debtToken), 1e18);
    }

    function test_repay_revertsOnZeroAmount() public {
        vm.prank(core);
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        adapter.repay(user, address(debtToken), 0);
    }

    function test_repay_approvesPoolAndCallsRepay() public {
        uint256 amount = 100e18;
        debtToken.mint(address(adapter), amount);

        vm.prank(core);
        adapter.repay(user, address(debtToken), amount);

        assertEq(pool.repayCallCount(), 1);
        (address asset, uint256 repaidAmount, uint256 rateMode, address onBehalfOf) = pool.repayCalls(0);
        assertEq(asset, address(debtToken));
        assertEq(repaidAmount, amount);
        assertEq(rateMode, 2);
        assertEq(onBehalfOf, user);
    }

    function test_repay_transfersTokensToPool() public {
        uint256 amount = 50e18;
        debtToken.mint(address(adapter), amount);

        vm.prank(core);
        adapter.repay(user, address(debtToken), amount);

        assertEq(debtToken.balanceOf(address(pool)), amount);
        assertEq(debtToken.balanceOf(address(adapter)), 0);
    }

    /// @dev B12: when Aave accepts less than the supplied amount (user debt fully repaid mid-flight),
    /// the adapter must sweep the surplus back to Core instead of stranding it.
    function test_repay_sweepsSurplusToCoreWhenPoolAcceptsPartial() public {
        uint256 amount = 100e18;
        uint256 cap = 70e18;
        debtToken.mint(address(adapter), amount);
        pool.setRepayCap(cap);

        vm.prank(core);
        adapter.repay(user, address(debtToken), amount);

        assertEq(debtToken.balanceOf(address(pool)), cap);
        assertEq(debtToken.balanceOf(address(core)), amount - cap);
        assertEq(debtToken.balanceOf(address(adapter)), 0);
    }

    /// @dev B13: if the user holds only stable-rate debt on a legacy market, Aave reverts on
    /// mode=2. The adapter must catch that and retry with mode=1.
    function test_repay_fallsBackToStableWhenVariableReverts() public {
        uint256 amount = 40e18;
        debtToken.mint(address(adapter), amount);
        pool.setRevertOnVariableMode(true);

        vm.prank(core);
        adapter.repay(user, address(debtToken), amount);

        // The variable-mode call reverts and rolls back its recorded entry, so only the
        // successful mode=1 call is observable.
        assertEq(pool.repayCallCount(), 1);
        (,, uint256 mode,) = pool.repayCalls(0);
        assertEq(mode, 1);
        assertEq(debtToken.balanceOf(address(pool)), amount);
        assertEq(debtToken.balanceOf(address(adapter)), 0);
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

    /// @dev An asset Aave does not list has no aToken to pull: refused.
    function test_withdrawCollateral_revertsForAnAssetAaveDoesNotList() public {
        address unlisted = makeAddr("unlisted");
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.UnsupportedCollateral.selector, unlisted));
        vm.prank(core);
        adapter.withdrawCollateral(user, unlisted, 1e18, recipient);
    }

    /// @dev M-3: a second collateral is withdrawn through its own aToken.
    function test_withdrawCollateral_pullsTheNamedCollateralsAToken() public {
        (MockERC20 second, MockERC20 secondAToken) = _secondCollateral();
        uint256 amount = 5e18;
        aToken.mint(user, amount);
        secondAToken.mint(user, amount);
        second.mint(address(pool), amount);
        vm.prank(user);
        secondAToken.approve(address(adapter), type(uint256).max);

        vm.prank(core);
        adapter.withdrawCollateral(user, address(second), amount, recipient);

        assertEq(secondAToken.balanceOf(user), 0);
        assertEq(aToken.balanceOf(user), amount);
        (address asset,,) = pool.withdrawCalls(0);
        assertEq(asset, address(second));
    }

    function test_withdrawCollateral_transfersATokensAndCallsWithdraw() public {
        uint256 amount = 10e18;
        aToken.mint(user, amount);
        collateralToken.mint(address(pool), amount);

        vm.prank(user);
        aToken.approve(address(adapter), amount);

        vm.prank(core);
        adapter.withdrawCollateral(user, address(collateralToken), amount, recipient);

        // aTokens moved from user to adapter
        assertEq(aToken.balanceOf(user), 0);
        assertEq(aToken.balanceOf(address(adapter)), amount);

        // Pool withdraw was called
        assertEq(pool.withdrawCallCount(), 1);
        (address asset, uint256 withdrawnAmount, address to) = pool.withdrawCalls(0);
        assertEq(asset, address(collateralToken));
        assertEq(withdrawnAmount, amount);
        assertEq(to, recipient);

        // Collateral sent to recipient
        assertEq(collateralToken.balanceOf(recipient), amount);
    }

    // ─── getCollateralValueUsd ─────────────────────────────────────────

    function test_getCollateralValueUsd_returnsTotalCollateralBase() public {
        uint256 collateralValue = 500_000e8;
        pool.setUserAccountData(user, collateralValue, 200_000e8, 100_000e8, 8000, 7500, 1.8e18);

        assertEq(adapter.getCollateralValueUsd(user), collateralValue);
    }

    function test_getCollateralValueUsd_returnsZeroForUnknownUser() public {
        address nobody = makeAddr("nobody");
        assertEq(adapter.getCollateralValueUsd(nobody), 0);
    }

    // ─── Fuzz tests ────────────────────────────────────────────────────

    function testFuzz_getHealthFactor(
        uint256 hf
    ) public {
        pool.setUserAccountData(user, 0, 0, 0, 0, 0, hf);
        assertEq(adapter.getHealthFactor(user), hf);
    }

    function testFuzz_repayAmount(
        uint256 amount
    ) public {
        amount = bound(amount, 1, type(uint128).max);
        debtToken.mint(address(adapter), amount);

        vm.prank(core);
        adapter.repay(user, address(debtToken), amount);

        assertEq(pool.repayCallCount(), 1);
        (, uint256 repaidAmount,,) = pool.repayCalls(0);
        assertEq(repaidAmount, amount);
    }

    function testFuzz_getCollateralValueUsd(
        uint256 collateralValue
    ) public {
        pool.setUserAccountData(user, collateralValue, 0, 0, 0, 0, 0);
        assertEq(adapter.getCollateralValueUsd(user), collateralValue);
    }

    // ─── getDebt ───────────────────────────────────────────────────────

    function test_getDebt_readsTheVariableDebtToken() public {
        MockERC20 variableDebt = new MockERC20("variableDebt", "vDEBT");
        pool.setVariableDebtToken(address(debtToken), address(variableDebt));
        variableDebt.mint(user, 1234e18);

        assertEq(adapter.getDebt(user, address(debtToken)), 1234e18);
    }

    function test_getDebt_isZeroForAnAssetWithoutAReserve() public view {
        assertEq(adapter.getDebt(user, address(debtToken)), 0);
    }
}
