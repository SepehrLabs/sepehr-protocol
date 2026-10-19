// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SepehrCore} from "../../src/SepehrCore.sol";
import {SepehrSubscriptions} from "../../src/SepehrSubscriptions.sol";
import {ISepehrCore} from "../../src/interfaces/ISepehrCore.sol";
import {Percentages} from "../../src/libraries/Percentages.sol";
import {SepehrErrors} from "../../src/libraries/SepehrErrors.sol";
import {SepehrEvents} from "../../src/libraries/SepehrEvents.sol";
import {MockAdapter} from "../../src/mocks/MockAdapter.sol";
import {MockDex} from "../../src/mocks/MockDex.sol";
import {MockFlashLoan} from "../../src/mocks/MockFlashLoan.sol";
import {MockChainlinkAggregator} from "../helpers/MockChainlinkAggregator.sol";
import {SepehrStack} from "../helpers/SepehrStack.sol";
import {MockERC20, SequentialMockAdapter} from "./SepehrCore.Triggers.t.sol";

/// @notice Lot 6: stop-loss and take-profit (`setExitOrder`, `close`) and open execution
/// (`setOpenExecutionHF`, anyone rescuing under it).
contract SepehrCoreExitOrdersTest is SepehrStack {
    SepehrCore internal core;
    SepehrSubscriptions internal subs;
    MockAdapter internal adapter;
    MockFlashLoan internal flashLoan;
    MockDex internal dex;
    MockERC20 internal usdc;
    MockERC20 internal debtToken;
    MockERC20 internal collateralToken;
    MockChainlinkAggregator internal collateralFeed;

    address internal timelock = makeAddr("timelock");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    bytes32 internal constant KEY = keccak256("AAVE_V3");
    uint256 internal constant DEBT = 1000e18;
    uint256 internal constant COLLATERAL = 1500e18;
    uint256 internal constant STOP_LOSS = 0.9e8;
    uint256 internal constant TAKE_PROFIT = 1.6e8;
    uint256 internal constant SHIELD_FEE_BPS = 20;

    function setUp() public {
        vm.warp(10_000);
        adapter = new MockAdapter();
        flashLoan = new MockFlashLoan();
        dex = new MockDex();
        usdc = new MockERC20("USDC", "USDC");
        debtToken = new MockERC20("Debt Token", "DEBT");
        collateralToken = new MockERC20("Collateral Token", "COLL");
        (core, subs) = _deployStack(address(this), timelock, makeAddr("guardian"), address(usdc), 0, type(uint256).max);

        collateralFeed = new MockChainlinkAggregator(8, 1e8);
        vm.startPrank(timelock);
        core.addAdapter(KEY, address(adapter));
        core.addKeeper(keeper);
        core.addFlashLoanProvider(address(flashLoan));
        core.addDexRouter(address(dex));
        core.setAssetOracle(address(collateralToken), address(collateralFeed), 1 hours);
        core.setAssetOracle(address(debtToken), address(new MockChainlinkAggregator(8, 1e8)), 1 hours);
        vm.stopPrank();

        usdc.mint(alice, 200e6);
        vm.startPrank(alice);
        usdc.approve(address(subs), type(uint256).max);
        subs.subscribe(1, false);
        vm.stopPrank();

        adapter.setDelegation(alice, true);
        adapter.setHealthFactor(alice, 2e18);
        adapter.setDebt(alice, address(debtToken), DEBT);
        vm.prank(alice);
        core.enableProtection(KEY, 1.3e18, 250, 1.5e18);

        debtToken.mint(address(flashLoan), 10 * DEBT);
        debtToken.mint(address(dex), 10 * DEBT);
        collateralToken.mint(address(adapter), COLLATERAL);
    }

    function _setOrder(
        uint256 stopLoss,
        uint256 takeProfit
    ) internal {
        vm.prank(alice);
        core.setExitOrder(KEY, address(collateralToken), stopLoss, takeProfit);
    }

    /// @dev The collateral's oracle price, and a DEX that sells at it.
    function _price(
        uint256 price
    ) internal {
        collateralFeed.setAnswer(int256(price));
        dex.setExchangeRate(price * 1e10);
    }

    function _close(
        address caller,
        address collateralAsset,
        uint256 collateralAmount
    ) internal {
        address[] memory providers = new address[](1);
        providers[0] = address(flashLoan);
        vm.prank(caller);
        core.close(alice, KEY, address(debtToken), collateralAsset, collateralAmount, providers, address(dex), "");
    }

    /// @dev What a close keeps from the sale: the flash loan, its fee and the plan's fee on the debt.
    function _owed() internal view returns (uint256) {
        return DEBT + Percentages.applyBps(DEBT, flashLoan.feeBps()) + Percentages.applyBps(DEBT, SHIELD_FEE_BPS);
    }

    // ─── setExitOrder ───────────────────────────────────────────

    function test_setExitOrder_storesTheOrderAndEmitsIt() public {
        vm.expectEmit(true, true, true, true, address(core));
        emit SepehrEvents.ExitOrderSet(alice, KEY, address(collateralToken), STOP_LOSS, TAKE_PROFIT);
        _setOrder(STOP_LOSS, TAKE_PROFIT);

        ISepehrCore.ExitOrder memory order = core.getExitOrder(alice, KEY);
        assertEq(order.priceAsset, address(collateralToken));
        assertEq(order.stopLossUsd, STOP_LOSS);
        assertEq(order.takeProfitUsd, TAKE_PROFIT);
    }

    function test_setExitOrder_withBothPricesZero_removesTheOrder() public {
        _setOrder(STOP_LOSS, TAKE_PROFIT);

        vm.expectEmit(true, true, true, true, address(core));
        emit SepehrEvents.ExitOrderSet(alice, KEY, address(0), 0, 0);
        _setOrder(0, 0);

        assertEq(core.getExitOrder(alice, KEY).priceAsset, address(0), "no order left");
    }

    function test_setExitOrder_acceptsASingleSide() public {
        _setOrder(STOP_LOSS, 0);
        assertEq(core.getExitOrder(alice, KEY).stopLossUsd, STOP_LOSS);
        _setOrder(0, TAKE_PROFIT);
        assertEq(core.getExitOrder(alice, KEY).takeProfitUsd, TAKE_PROFIT);
    }

    function test_setExitOrder_revertsWithoutProtection() public {
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.ProtectionNotEnabled.selector, bob, KEY));
        vm.prank(bob);
        core.setExitOrder(KEY, address(collateralToken), STOP_LOSS, 0);
    }

    function test_setExitOrder_revertsWithoutAnOracleForThePriceAsset() public {
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.MissingAssetOracle.selector, address(usdc)));
        vm.prank(alice);
        core.setExitOrder(KEY, address(usdc), STOP_LOSS, 0);
    }

    function test_setExitOrder_revertsWhenTheStopLossIsNotBelowTheTakeProfit() public {
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.InvalidExitOrder.selector, TAKE_PROFIT, TAKE_PROFIT));
        _setOrder(TAKE_PROFIT, TAKE_PROFIT);
    }

    function test_setExitOrder_revertsWhenPaused() public {
        core.pause();
        vm.expectRevert(SepehrErrors.ContractPaused.selector);
        _setOrder(STOP_LOSS, 0);
    }

    function test_disableProtection_removesTheOrder() public {
        _setOrder(STOP_LOSS, TAKE_PROFIT);
        vm.prank(alice);
        core.disableProtection(KEY);
        assertEq(core.getExitOrder(alice, KEY).priceAsset, address(0));
    }

    function test_unsubscribe_removesTheOrder() public {
        _setOrder(STOP_LOSS, TAKE_PROFIT);
        vm.prank(alice);
        subs.unsubscribe();
        assertEq(core.getExitOrder(alice, KEY).priceAsset, address(0));
    }

    // ─── close ──────────────────────────────────────────────────

    function test_close_atTheStopLoss_repaysTheDebtSellsTheCollateralAndPaysTheUser() public {
        _setOrder(STOP_LOSS, TAKE_PROFIT);
        _price(STOP_LOSS);
        uint256 proceeds = (COLLATERAL * STOP_LOSS) / 1e8;
        uint256 fee = Percentages.applyBps(DEBT, SHIELD_FEE_BPS);
        uint256 lenderBefore = debtToken.balanceOf(address(flashLoan));

        vm.expectEmit(true, true, true, true, address(core));
        emit SepehrEvents.PositionClosed(alice, KEY, keeper, DEBT, COLLATERAL, STOP_LOSS, fee);
        _close(keeper, address(collateralToken), COLLATERAL);

        assertEq(debtToken.balanceOf(address(0xdead)), DEBT, "the whole debt repaid");
        assertEq(collateralToken.balanceOf(address(adapter)), 0, "all the collateral sold");
        assertEq(debtToken.balanceOf(alice), proceeds - _owed(), "the rest of the sale goes to the user");
        assertEq(debtToken.balanceOf(address(flashLoan)) - lenderBefore, Percentages.applyBps(DEBT, 9), "loan repaid");
        assertEq(debtToken.balanceOf(address(core)), fee, "the core keeps exactly the fee");
        (uint256 ownerShare, uint256 keeperShare) = Percentages.splitFee(fee);
        assertEq(core.ownerFeeBalances(address(debtToken)), ownerShare);
        assertEq(core.keeperFeeBalances(keeper, address(debtToken)), keeperShare);
        assertEq(core.getExitOrder(alice, KEY).priceAsset, address(0), "the order is spent");
    }

    function test_close_atTheTakeProfit() public {
        _setOrder(0, TAKE_PROFIT);
        _price(TAKE_PROFIT);
        _close(keeper, address(collateralToken), COLLATERAL);
        assertEq(debtToken.balanceOf(alice), (COLLATERAL * TAKE_PROFIT) / 1e8 - _owed());
    }

    function test_close_inTheDebtAsset_sellsNothing() public {
        vm.prank(alice);
        core.setExitOrder(KEY, address(debtToken), 1.1e8, 0);
        debtToken.mint(address(adapter), COLLATERAL);

        _close(keeper, address(debtToken), COLLATERAL);

        assertEq(debtToken.balanceOf(alice), COLLATERAL - _owed());
    }

    function test_close_revertsBetweenTheStopLossAndTheTakeProfit() public {
        _setOrder(STOP_LOSS, TAKE_PROFIT);
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.ExitConditionNotMet.selector, 1e8));
        _close(keeper, address(collateralToken), COLLATERAL);
    }

    function test_close_revertsAboveAStopLossAlone() public {
        _setOrder(STOP_LOSS, 0);
        _price(TAKE_PROFIT);
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.ExitConditionNotMet.selector, TAKE_PROFIT));
        _close(keeper, address(collateralToken), COLLATERAL);
    }

    function test_close_revertsWithoutAnOrder() public {
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.NoExitOrder.selector, alice, KEY));
        _close(keeper, address(collateralToken), COLLATERAL);
    }

    function test_close_revertsForANonKeeper_evenWithOpenExecution() public {
        vm.prank(timelock);
        core.setOpenExecutionHF(1.15e18);
        _setOrder(STOP_LOSS, 0);
        _price(STOP_LOSS);
        vm.expectRevert(SepehrErrors.NotKeeper.selector);
        _close(bob, address(collateralToken), COLLATERAL);
    }

    function test_close_revertsWithoutCollateralToSell() public {
        _setOrder(STOP_LOSS, 0);
        _price(STOP_LOSS);
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        _close(keeper, address(collateralToken), 0);
    }

    function test_close_revertsWithoutDebt() public {
        _setOrder(STOP_LOSS, 0);
        _price(STOP_LOSS);
        adapter.setDebt(alice, address(debtToken), 0);
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.NoDebtToRepay.selector, alice, address(debtToken)));
        _close(keeper, address(collateralToken), COLLATERAL);
    }

    function test_close_revertsWhenTheSaleFallsUnderTheOracleFloor() public {
        _setOrder(STOP_LOSS, 0);
        _price(STOP_LOSS);
        dex.setExchangeRate(0.8e18);
        vm.expectRevert(bytes("MockDex: slippage"));
        _close(keeper, address(collateralToken), COLLATERAL);
    }

    function test_close_revertsWithoutDelegation() public {
        _setOrder(STOP_LOSS, 0);
        _price(STOP_LOSS);
        adapter.setDelegation(alice, false);
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.DelegationRevoked.selector, alice, KEY));
        _close(keeper, address(collateralToken), COLLATERAL);
    }

    function test_close_revertsOnAStalePrice() public {
        _setOrder(STOP_LOSS, 0);
        _price(STOP_LOSS);
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(
            abi.encodeWithSelector(
                SepehrErrors.StaleOraclePrice.selector, address(collateralToken), 10_000, block.timestamp
            )
        );
        _close(keeper, address(collateralToken), COLLATERAL);
    }

    // ─── Open execution ─────────────────────────────────────────

    bytes32 internal constant OPEN_KEY = keccak256("OPEN");

    /// @dev Alice at a 1.1 health factor on an adapter a rescue lifts to 1.5, in the debt asset.
    function _protectOpen() internal {
        SequentialMockAdapter seq = new SequentialMockAdapter(1.1e18, 1.5e18);
        seq.setDelegation(alice, true);
        debtToken.mint(address(seq), 10 * DEBT);
        vm.prank(timelock);
        core.addAdapter(OPEN_KEY, address(seq));
        vm.prank(alice);
        core.enableProtection(OPEN_KEY, 1.3e18, 250, 1.5e18);
    }

    function _openRescue(
        address caller
    ) internal {
        address[] memory providers = new address[](1);
        providers[0] = address(flashLoan);
        vm.prank(caller);
        core.execute(alice, OPEN_KEY, address(debtToken), address(debtToken), DEBT, providers, address(dex), "");
    }

    function test_setOpenExecutionHF_storesItAndEmits() public {
        vm.expectEmit(true, true, true, true, address(core));
        emit SepehrEvents.OpenExecutionHFUpdated(0, 1.15e18);
        vm.prank(timelock);
        core.setOpenExecutionHF(1.15e18);
        assertEq(core.openExecutionHF(), 1.15e18);

        vm.prank(timelock);
        core.setOpenExecutionHF(0);
        assertEq(core.openExecutionHF(), 0, "turned off");
    }

    function test_setOpenExecutionHF_revertsForAnyoneButTheTimelock() public {
        vm.expectRevert(SepehrErrors.NotTimelock.selector);
        core.setOpenExecutionHF(1.15e18);
    }

    function test_setOpenExecutionHF_revertsFromTheLowestThreshold() public {
        uint256 min = core.MIN_HF_THRESHOLD();
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.OpenExecutionHFTooHigh.selector, min, min));
        vm.prank(timelock);
        core.setOpenExecutionHF(min);
    }

    function test_execute_anyoneRescuesUnderTheOpenExecutionLine_andEarnsTheKeeperShare() public {
        vm.prank(timelock);
        core.setOpenExecutionHF(1.15e18);
        _protectOpen();

        _openRescue(bob);

        (, uint256 keeperShare) = Percentages.splitFee(Percentages.applyBps(DEBT, SHIELD_FEE_BPS));
        assertEq(core.keeperFeeBalances(bob, address(debtToken)), keeperShare);
        vm.prank(bob);
        core.withdrawKeeperFees(address(debtToken));
        assertEq(debtToken.balanceOf(bob), keeperShare, "the caller withdraws its share");
    }

    function test_execute_revertsForANonKeeper_whenOpenExecutionIsOff() public {
        _protectOpen();
        vm.expectRevert(SepehrErrors.NotKeeper.selector);
        _openRescue(bob);
    }

    function test_execute_revertsForANonKeeper_aboveTheOpenExecutionLine() public {
        vm.prank(timelock);
        core.setOpenExecutionHF(1.05e18);
        _protectOpen();
        vm.expectRevert(SepehrErrors.NotKeeper.selector);
        _openRescue(bob);
    }
}
