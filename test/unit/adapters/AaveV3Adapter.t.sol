// SPDX-License-Identifier: UNLICENSED
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
        adapter = new AaveV3Adapter(address(pool), address(aToken), core);
    }

    // ─── Constructor ───────────────────────────────────────────────────

    function test_constructor_revertsOnZeroPool() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new AaveV3Adapter(address(0), address(aToken), core);
    }

    function test_constructor_revertsOnZeroAToken() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new AaveV3Adapter(address(pool), address(0), core);
    }

    function test_constructor_revertsOnZeroCore() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new AaveV3Adapter(address(pool), address(aToken), address(0));
    }

    function test_constructor_storesImmutables() public view {
        assertEq(address(adapter.POOL()), address(pool));
        assertEq(adapter.ATOKEN(), address(aToken));
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

    function test_checkDelegation_returnsTrueWhenAllowanceGtZero() public {
        vm.prank(user);
        aToken.approve(address(adapter), 1);

        assertTrue(adapter.checkDelegation(user));
    }

    function test_checkDelegation_returnsFalseWhenAllowanceZero() public view {
        assertFalse(adapter.checkDelegation(user));
    }

    function test_checkDelegation_returnsTrueWithMaxAllowance() public {
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
}
