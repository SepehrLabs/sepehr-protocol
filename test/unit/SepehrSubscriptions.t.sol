// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {SepehrCore} from "../../src/SepehrCore.sol";
import {SepehrSubscriptions} from "../../src/SepehrSubscriptions.sol";
import {ISepehrCore} from "../../src/interfaces/ISepehrCore.sol";
import {ISepehrSubscriptions} from "../../src/interfaces/ISepehrSubscriptions.sol";
import {SepehrErrors} from "../../src/libraries/SepehrErrors.sol";
import {SepehrEvents} from "../../src/libraries/SepehrEvents.sol";
import {SepehrStack} from "../helpers/SepehrStack.sol";

contract MockERC20 is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract SepehrSubscriptionsTest is SepehrStack {
    SepehrCore public core;
    SepehrSubscriptions public subs;
    MockERC20 public usdc;

    address public timelock = makeAddr("timelock");
    address public guardian = makeAddr("guardian");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 constant MONTHLY_PERIOD = 30 days;
    uint256 constant ANNUAL_PERIOD = 365 days;

    // Tier prices (6-decimal USDC)
    uint256 constant SHIELD_MONTHLY = 4_990_000;
    uint256 constant GUARDIAN_MONTHLY = 14_990_000;
    uint256 constant WATCHTOWER_MONTHLY = 49_990_000;
    uint256 constant SHIELD_ANNUAL = 49_000_000;
    uint256 constant GUARDIAN_ANNUAL = 149_000_000;
    uint256 constant WATCHTOWER_ANNUAL = 499_000_000;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC");

        (core, subs) = _deployStack(address(this), timelock, guardian, address(usdc), 500e8, type(uint256).max);

        usdc.mint(alice, 10_000e6);
        usdc.mint(bob, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(subs), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(subs), type(uint256).max);
    }

    // ─── subscribe (monthly) ────────────────────────────────────

    function test_subscribe_tier1_monthly() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(alice);
        assertEq(sub.tier, 1);
        assertFalse(sub.annual);
        assertEq(sub.expiresAt, block.timestamp + MONTHLY_PERIOD);
    }

    function test_subscribe_tier2_monthly() public {
        vm.prank(alice);
        subs.subscribe(2, false);

        ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(alice);
        assertEq(sub.tier, 2);
        assertEq(sub.expiresAt, block.timestamp + MONTHLY_PERIOD);
    }

    function test_subscribe_tier3_monthly() public {
        vm.prank(alice);
        subs.subscribe(3, false);

        ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(alice);
        assertEq(sub.tier, 3);
    }

    function test_subscribe_emitsEvent_monthly() public {
        vm.prank(alice);

        vm.expectEmit(true, false, false, true, address(subs));
        emit SepehrEvents.Subscribed(alice, block.timestamp + MONTHLY_PERIOD, 1, false, block.chainid);

        subs.subscribe(1, false);
    }

    function test_subscribe_transfersMonthlyPayment() public {
        uint256 balanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        subs.subscribe(1, false);

        assertEq(balanceBefore - usdc.balanceOf(alice), SHIELD_MONTHLY);
        assertEq(usdc.balanceOf(address(subs)), SHIELD_MONTHLY);
    }

    function test_subscribe_transfersCorrectAmountPerTier() public {
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        subs.subscribe(2, false);
        assertEq(balBefore - usdc.balanceOf(alice), GUARDIAN_MONTHLY);
    }

    // ─── subscribe (annual) ─────────────────────────────────────

    function test_subscribe_tier1_annual() public {
        vm.prank(alice);
        subs.subscribe(1, true);

        ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(alice);
        assertEq(sub.tier, 1);
        assertTrue(sub.annual);
        assertEq(sub.expiresAt, block.timestamp + ANNUAL_PERIOD);
    }

    function test_subscribe_tier2_annual() public {
        vm.prank(alice);
        subs.subscribe(2, true);

        ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(alice);
        assertEq(sub.tier, 2);
        assertTrue(sub.annual);
        assertEq(sub.expiresAt, block.timestamp + ANNUAL_PERIOD);
    }

    function test_subscribe_tier3_annual() public {
        usdc.mint(alice, 2000e6);
        vm.prank(alice);
        subs.subscribe(3, true);

        ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(alice);
        assertEq(sub.tier, 3);
        assertTrue(sub.annual);
    }

    function test_subscribe_emitsEvent_annual() public {
        vm.prank(alice);

        vm.expectEmit(true, false, false, true, address(subs));
        emit SepehrEvents.Subscribed(alice, block.timestamp + ANNUAL_PERIOD, 1, true, block.chainid);

        subs.subscribe(1, true);
    }

    function test_subscribe_transfersAnnualPayment() public {
        uint256 balanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        subs.subscribe(1, true);

        assertEq(balanceBefore - usdc.balanceOf(alice), SHIELD_ANNUAL);
    }

    function test_subscribe_annualDiscount() public {
        // Annual price should be less than 12x monthly
        assertLt(SHIELD_ANNUAL, SHIELD_MONTHLY * 12);
        assertLt(GUARDIAN_ANNUAL, GUARDIAN_MONTHLY * 12);
        assertLt(WATCHTOWER_ANNUAL, WATCHTOWER_MONTHLY * 12);
    }

    // ─── subscribe reverts ──────────────────────────────────────

    function test_subscribe_revertsOnTierZero() public {
        vm.expectRevert(SepehrErrors.InvalidTier.selector);
        vm.prank(alice);
        subs.subscribe(0, false);
    }

    function test_subscribe_revertsOnTierFive() public {
        vm.expectRevert(SepehrErrors.InvalidTier.selector);
        vm.prank(alice);
        subs.subscribe(5, false);
    }

    function test_subscribe_revertsOnTierAboveFour() public {
        vm.expectRevert(SepehrErrors.InvalidTier.selector);
        vm.prank(alice);
        subs.subscribe(255, false);
    }

    function test_subscribe_revertsOnTitanSelfSubscribe() public {
        vm.expectRevert(SepehrErrors.TitanSelfSubscribeNotAllowed.selector);
        vm.prank(alice);
        subs.subscribe(4, false);
    }

    function test_subscribe_revertsOnTitanSelfSubscribe_annual() public {
        vm.expectRevert(SepehrErrors.TitanSelfSubscribeNotAllowed.selector);
        vm.prank(alice);
        subs.subscribe(4, true);
    }

    function test_subscribe_revertsWhenAlreadyActive() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        vm.expectRevert(SepehrErrors.SubscriptionAlreadyActive.selector);
        vm.prank(alice);
        subs.subscribe(2, false);
    }

    function test_subscribe_succeedsAfterExpiry() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        vm.warp(block.timestamp + MONTHLY_PERIOD + 1);

        vm.prank(alice);
        subs.subscribe(2, false);

        ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(alice);
        assertEq(sub.tier, 2);
    }

    // ─── renew ──────────────────────────────────────────────────

    function test_renew_extendsFromExpiry_whenStillActive() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        uint256 originalExpiry = subs.getSubscription(alice).expiresAt;

        vm.warp(block.timestamp + 15 days);
        vm.prank(alice);
        subs.renew();

        ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(alice);
        assertEq(sub.expiresAt, originalExpiry + MONTHLY_PERIOD);
    }

    function test_renew_extendsFromNow_whenExpired() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        uint256 originalExpiry = subs.getSubscription(alice).expiresAt;

        vm.warp(originalExpiry + 7 days);
        uint256 renewTime = block.timestamp;

        vm.prank(alice);
        subs.renew();

        ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(alice);
        assertEq(sub.expiresAt, renewTime + MONTHLY_PERIOD);
    }

    function test_renew_annual_extendsCorrectDuration() public {
        vm.prank(alice);
        subs.subscribe(1, true);

        uint256 originalExpiry = subs.getSubscription(alice).expiresAt;

        vm.warp(block.timestamp + 100 days);
        vm.prank(alice);
        subs.renew();

        ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(alice);
        assertEq(sub.expiresAt, originalExpiry + ANNUAL_PERIOD);
    }

    function test_renew_emitsEvent() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        uint256 expectedExpiry = block.timestamp + MONTHLY_PERIOD + MONTHLY_PERIOD;

        vm.prank(alice);

        vm.expectEmit(true, false, false, true, address(subs));
        emit SepehrEvents.Renewed(alice, expectedExpiry, 1, false);

        subs.renew();
    }

    function test_renew_transfersPayment() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        uint256 balanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        subs.renew();

        assertEq(balanceBefore - usdc.balanceOf(alice), SHIELD_MONTHLY);
    }

    function test_renew_revertsWhenNoSubscription() public {
        vm.expectRevert(SepehrErrors.SubscriptionNotFound.selector);
        vm.prank(alice);
        subs.renew();
    }

    function test_renew_revertsForTitanUser() public {
        subs.grantTitanSubscription(alice, 365 days);

        vm.expectRevert(SepehrErrors.TitanSelfSubscribeNotAllowed.selector);
        vm.prank(alice);
        subs.renew();
    }

    // ─── unsubscribe ────────────────────────────────────────────

    function test_unsubscribe_clearsData() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        vm.prank(alice);
        subs.unsubscribe();

        ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(alice);
        assertEq(sub.tier, 0);
        assertEq(sub.expiresAt, 0);
        assertFalse(sub.annual);
    }

    function test_unsubscribe_emitsEvent() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        vm.prank(alice);

        vm.expectEmit(true, false, false, false, address(subs));
        emit SepehrEvents.Unsubscribed(alice);

        subs.unsubscribe();
    }

    function test_unsubscribe_revertsWhenNoneExists() public {
        vm.expectRevert(SepehrErrors.SubscriptionNotFound.selector);
        vm.prank(alice);
        subs.unsubscribe();
    }

    function test_unsubscribe_revertsWhenAlreadyUnsubscribed() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        vm.prank(alice);
        subs.unsubscribe();

        vm.expectRevert(SepehrErrors.SubscriptionNotFound.selector);
        vm.prank(alice);
        subs.unsubscribe();
    }

    // ─── subscription expiry ────────────────────────────────────

    function test_subscription_isActive_beforeExpiry() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(alice);
        assertTrue(sub.expiresAt > block.timestamp);
    }

    function test_subscription_isExpired_atExactExpiry() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        vm.warp(block.timestamp + MONTHLY_PERIOD);

        vm.prank(alice);
        subs.subscribe(1, false);
    }

    function test_subscription_isExpired_afterExpiry() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        vm.warp(block.timestamp + MONTHLY_PERIOD + 1);

        vm.prank(alice);
        subs.subscribe(2, false);

        ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(alice);
        assertEq(sub.tier, 2);
    }

    // ─── Titan (owner-granted) ──────────────────────────────────

    function test_grantTitan_setsSubscription() public {
        subs.grantTitanSubscription(alice, 365 days);

        ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(alice);
        assertEq(sub.tier, 4);
        assertEq(sub.expiresAt, block.timestamp + 365 days);
    }

    function test_grantTitan_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(subs));
        emit SepehrEvents.TitanSubscriptionGranted(alice, block.timestamp + 365 days);

        subs.grantTitanSubscription(alice, 365 days);
    }

    function test_grantTitan_revertsFromNonOwner() public {
        vm.expectRevert(SepehrErrors.NotOwner.selector);
        vm.prank(alice);
        subs.grantTitanSubscription(bob, 365 days);
    }

    function test_grantTitan_revertsOnZeroAddress() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        subs.grantTitanSubscription(address(0), 365 days);
    }

    function test_grantTitan_revertsOnZeroDuration() public {
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        subs.grantTitanSubscription(alice, 0);
    }

    function test_grantTitan_revertsOverAnActivePaidPlan() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        vm.expectRevert(SepehrErrors.SubscriptionAlreadyActive.selector);
        subs.grantTitanSubscription(alice, 30 days);
    }

    // ─── paused state ───────────────────────────────────────────

    function test_subscribe_revertsWhenPaused() public {
        core.pause();

        vm.expectRevert(SepehrErrors.ContractPaused.selector);
        vm.prank(alice);
        subs.subscribe(1, false);
    }

    function test_renew_revertsWhenPaused() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        core.pause();

        vm.expectRevert(SepehrErrors.ContractPaused.selector);
        vm.prank(alice);
        subs.renew();
    }

    // ─── multiple users ─────────────────────────────────────────

    function test_subscribe_multipleUsersIndependent() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        vm.prank(bob);
        subs.subscribe(3, false);

        ISepehrSubscriptions.Subscription memory subAlice = subs.getSubscription(alice);
        ISepehrSubscriptions.Subscription memory subBob = subs.getSubscription(bob);

        assertEq(subAlice.tier, 1);
        assertEq(subBob.tier, 3);
    }

    // ─── M-1: settled revenue, the only USDC the owner withdraws ──

    function test_settle_movesTheEarnedPartToOwnerRevenue_proRata() public {
        vm.prank(alice);
        subs.subscribe(1, false);
        vm.warp(block.timestamp + MONTHLY_PERIOD / 3);

        address[] memory users = new address[](1);
        users[0] = alice;
        vm.expectEmit(true, false, false, true, address(subs));
        emit SepehrEvents.RevenueSettled(alice, SHIELD_MONTHLY / 3);
        vm.prank(bob); // anyone may settle
        subs.settle(users);

        assertEq(subs.ownerRevenue(), SHIELD_MONTHLY / 3);
        assertEq(subs.refundableOf(alice), SHIELD_MONTHLY - SHIELD_MONTHLY / 3);
        // Settling again at once moves nothing more.
        subs.settle(users);
        assertEq(subs.ownerRevenue(), SHIELD_MONTHLY / 3);
    }

    function test_settle_afterExpiry_earnsTheWholePayment() public {
        vm.prank(alice);
        subs.subscribe(2, false);
        vm.warp(block.timestamp + MONTHLY_PERIOD + 1);

        address[] memory users = new address[](1);
        users[0] = alice;
        subs.settle(users);
        assertEq(subs.ownerRevenue(), GUARDIAN_MONTHLY);
        assertEq(subs.refundableOf(alice), 0);
    }

    /// @dev A10: the revenue always goes to `owner()`.
    function test_withdrawRevenue_sendsOnlyTheSettledRevenueToTheOwner() public {
        vm.prank(alice);
        subs.subscribe(1, false);
        vm.warp(block.timestamp + MONTHLY_PERIOD / 2);
        address[] memory users = new address[](1);
        users[0] = alice;
        subs.settle(users);

        address ownerAddr = subs.owner();
        uint256 before = usdc.balanceOf(ownerAddr);
        vm.expectEmit(true, true, false, true, address(subs));
        emit SepehrEvents.OwnerFeesWithdrawn(address(usdc), ownerAddr, SHIELD_MONTHLY / 2);
        subs.withdrawRevenue();

        assertEq(usdc.balanceOf(ownerAddr) - before, SHIELD_MONTHLY / 2);
        assertEq(subs.ownerRevenue(), 0);
        assertEq(usdc.balanceOf(address(subs)), SHIELD_MONTHLY - SHIELD_MONTHLY / 2, "unearned half stays");
    }

    function test_withdrawRevenue_revertsFromNonOwner() public {
        vm.expectRevert(SepehrErrors.NotOwner.selector);
        vm.prank(alice);
        subs.withdrawRevenue();
    }

    function test_withdrawRevenue_revertsWithNothingSettled() public {
        vm.prank(alice);
        subs.subscribe(1, false);
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        subs.withdrawRevenue();
    }

    /// @dev M-1 (audit): the owner withdrawing everything withdrawable never touches what other
    /// subscribers prepaid; each still gets their unused part back.
    function test_ownerWithdrawal_neverReducesAnotherSubscribersRefund() public {
        vm.prank(alice);
        subs.subscribe(3, false);
        vm.prank(bob);
        subs.subscribe(3, false);
        vm.warp(block.timestamp + MONTHLY_PERIOD / 4);

        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        subs.settle(users);
        subs.withdrawRevenue();

        uint256 before = usdc.balanceOf(bob);
        vm.prank(bob);
        subs.unsubscribe();
        assertEq(usdc.balanceOf(bob) - before, WATCHTOWER_MONTHLY - WATCHTOWER_MONTHLY / 4, "bob's unused part");
        before = usdc.balanceOf(alice);
        vm.prank(alice);
        subs.unsubscribe();
        assertEq(usdc.balanceOf(alice) - before, WATCHTOWER_MONTHLY - WATCHTOWER_MONTHLY / 4, "alice's unused part");
        assertEq(usdc.balanceOf(address(subs)), 0, "nothing left over");
    }

    // ─── A12: upgradeTier ──────────────────────────────────────

    function test_upgradeTier_shieldToGuardian_monthly_chargesDelta() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        uint256 aliceBalBefore = usdc.balanceOf(alice);
        uint256 expectedDelta = GUARDIAN_MONTHLY - SHIELD_MONTHLY;

        vm.prank(alice);
        subs.upgradeTier(2, false);

        assertEq(usdc.balanceOf(alice), aliceBalBefore - expectedDelta, "alice should pay delta");
        ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(alice);
        assertEq(sub.tier, 2, "tier should be Guardian");
        assertEq(sub.annual, false, "annual should be false");
        assertEq(sub.expiresAt, block.timestamp + MONTHLY_PERIOD, "new period resets");
    }

    function test_upgradeTier_guardianToShield_monthly_refundsDifference() public {
        vm.prank(alice);
        subs.subscribe(2, false);

        uint256 aliceBalBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        subs.upgradeTier(1, false);

        assertGt(usdc.balanceOf(alice), aliceBalBefore, "alice should receive refund (downgrade)");
        ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(alice);
        assertEq(sub.tier, 1, "tier should be Shield");
    }

    function test_upgradeTier_switchMonthlyToAnnual_sameTier_allowed() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        vm.prank(alice);
        subs.upgradeTier(1, true);

        ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(alice);
        assertEq(sub.tier, 1, "tier stays Shield");
        assertEq(sub.annual, true, "annual flag flipped");
        assertEq(sub.expiresAt, block.timestamp + ANNUAL_PERIOD, "annual period starts");
    }

    function test_upgradeTier_revertsOnSameTierSameCadence() public {
        vm.prank(alice);
        subs.subscribe(2, false);

        vm.prank(alice);
        vm.expectRevert(SepehrErrors.SameTierUpgrade.selector);
        subs.upgradeTier(2, false);
    }

    function test_upgradeTier_revertsOnTier0() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        vm.prank(alice);
        vm.expectRevert(SepehrErrors.InvalidTier.selector);
        subs.upgradeTier(0, false);
    }

    function test_upgradeTier_revertsOnTier5() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        vm.prank(alice);
        vm.expectRevert(SepehrErrors.InvalidTier.selector);
        subs.upgradeTier(5, false);
    }

    function test_upgradeTier_revertsOnTitanSelfUpgrade() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        vm.prank(alice);
        vm.expectRevert(SepehrErrors.TitanSelfSubscribeNotAllowed.selector);
        subs.upgradeTier(4, false);
    }

    function test_upgradeTier_revertsWhenNoSubscription() public {
        vm.prank(alice);
        vm.expectRevert(SepehrErrors.SubscriptionNotFound.selector);
        subs.upgradeTier(2, false);
    }

    function test_upgradeTier_revertsWhenExpired() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        vm.warp(block.timestamp + MONTHLY_PERIOD + 1);

        vm.prank(alice);
        vm.expectRevert(SepehrErrors.SubscriptionExpired.selector);
        subs.upgradeTier(2, false);
    }

    function test_upgradeTier_revertsForTitanHolder() public {
        subs.grantTitanSubscription(alice, 30 days);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.UpgradeTierPathInvalid.selector, uint8(4), uint8(2)));
        subs.upgradeTier(2, false);
    }

    function test_upgradeTier_revertsWhenPaused() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        vm.prank(guardian);
        core.pause();

        vm.prank(alice);
        vm.expectRevert(SepehrErrors.ContractPaused.selector);
        subs.upgradeTier(2, false);
    }

    function test_upgradeTier_proRataCredit_halfwayThrough() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        // Halfway through month, upgrading to Guardian monthly should credit ~SHIELD_MONTHLY/2.
        vm.warp(block.timestamp + MONTHLY_PERIOD / 2);

        uint256 aliceBalBefore = usdc.balanceOf(alice);
        uint256 credit = SHIELD_MONTHLY / 2;
        uint256 expectedDelta = GUARDIAN_MONTHLY - credit;

        vm.prank(alice);
        subs.upgradeTier(2, false);

        assertEq(usdc.balanceOf(alice), aliceBalBefore - expectedDelta, "half-period credit applied");
    }

    function test_upgradeTier_emitsTierUpgradedAndSubscribed() public {
        vm.prank(alice);
        subs.subscribe(1, false);

        vm.expectEmit(true, false, false, true);
        emit SepehrEvents.TierUpgraded(alice, 1, 2);
        vm.expectEmit(true, false, false, true);
        emit SepehrEvents.Subscribed(alice, block.timestamp + MONTHLY_PERIOD, 2, false, block.chainid);

        vm.prank(alice);
        subs.upgradeTier(2, false);
    }

    function test_upgradeTier_creditUnaffectedByTheOwnerWithdrawingRevenue() public {
        vm.prank(alice);
        subs.subscribe(2, false);
        vm.warp(block.timestamp + MONTHLY_PERIOD / 2);
        address[] memory users = new address[](1);
        users[0] = alice;
        subs.settle(users);
        subs.withdrawRevenue();

        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        subs.upgradeTier(3, false);

        assertEq(
            aliceBalBefore - usdc.balanceOf(alice),
            WATCHTOWER_MONTHLY - GUARDIAN_MONTHLY / 2,
            "the unused half of Guardian is still credited"
        );
    }

    // ─── M-1: refunds and credits follow what was paid ──────────────

    function _paid(
        address user
    ) internal view returns (uint256 paid, uint256 startedAt) {
        (paid, startedAt,) = subs.subscriptionPayments(user);
    }

    function test_subscribe_recordsWhatWasPaid() public {
        vm.prank(alice);
        subs.subscribe(2, true);

        (uint256 paid, uint256 startedAt) = _paid(alice);
        assertEq(paid, GUARDIAN_ANNUAL);
        assertEq(startedAt, block.timestamp);
    }

    /// @dev M-1 (audit PoC): prepaying years before a +50% price rise refunds what was paid,
    /// not the stacked years at the new price.
    function test_unsubscribe_refundsWhatWasPaidAfterAPriceRise() public {
        usdc.mint(alice, 100_000e6);
        vm.startPrank(alice);
        subs.subscribe(3, true);
        for (uint256 i = 0; i < 9; i++) {
            subs.renew();
        }
        vm.stopPrank();
        uint256 paidTotal = WATCHTOWER_ANNUAL * 10;
        (uint256 paid,) = _paid(alice);
        assertEq(paid, paidTotal);

        vm.prank(timelock);
        subs.setTierPrice(3, true, (WATCHTOWER_ANNUAL * 15) / 10);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        subs.unsubscribe();

        assertEq(usdc.balanceOf(alice) - before, paidTotal, "refund is what was paid, unused");
        (paid,) = _paid(alice);
        assertEq(paid, 0, "payment record cleared");
    }

    function test_unsubscribe_refundIsUnchangedByAPriceCut() public {
        vm.prank(alice);
        subs.subscribe(2, false);
        vm.warp(block.timestamp + MONTHLY_PERIOD / 2);

        vm.prank(timelock);
        subs.setTierPrice(2, false, GUARDIAN_MONTHLY / 2);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        subs.unsubscribe();

        assertEq(usdc.balanceOf(alice) - before, GUARDIAN_MONTHLY / 2, "half of what was paid");
    }

    /// @dev M-1: the earned third of the first window is settled; its unused two thirds carry
    /// into a new window that runs from now to the extended expiry.
    function test_renew_whileActive_carriesTheUnusedPartIntoANewWindow() public {
        vm.startPrank(alice);
        subs.subscribe(1, false);
        uint256 startedAt = vm.getBlockTimestamp();
        vm.warp(startedAt + 10 days);
        subs.renew();
        vm.stopPrank();

        (uint256 paid, uint256 windowStart) = _paid(alice);
        assertEq(paid, SHIELD_MONTHLY - SHIELD_MONTHLY / 3 + SHIELD_MONTHLY);
        assertEq(windowStart, startedAt + 10 days);
        assertEq(subs.ownerRevenue(), SHIELD_MONTHLY / 3);
        assertEq(subs.getSubscription(alice).expiresAt, startedAt + 2 * MONTHLY_PERIOD);
    }

    function test_renew_afterExpiry_opensANewWindow() public {
        vm.prank(alice);
        subs.subscribe(1, false);
        vm.warp(block.timestamp + MONTHLY_PERIOD + 1 days);

        vm.prank(alice);
        subs.renew();

        (uint256 paid, uint256 startedAt) = _paid(alice);
        assertEq(paid, SHIELD_MONTHLY);
        assertEq(startedAt, block.timestamp);
    }

    function test_upgradeTier_creditFollowsWhatWasPaidAfterAPriceRise() public {
        vm.prank(alice);
        subs.subscribe(1, false);
        vm.warp(block.timestamp + MONTHLY_PERIOD / 2);

        vm.prank(timelock);
        subs.setTierPrice(1, false, (SHIELD_MONTHLY * 15) / 10);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        subs.upgradeTier(2, false);

        assertEq(before - usdc.balanceOf(alice), GUARDIAN_MONTHLY - SHIELD_MONTHLY / 2, "credit from what was paid");
        (uint256 paid, uint256 startedAt) = _paid(alice);
        assertEq(paid, GUARDIAN_MONTHLY);
        assertEq(startedAt, block.timestamp);
    }

    function test_grantTitan_clearsAnExpiredPayment() public {
        vm.prank(alice);
        subs.subscribe(1, false);
        vm.warp(block.timestamp + MONTHLY_PERIOD + 1);

        subs.grantTitanSubscription(alice, 30 days);

        (uint256 paid,) = _paid(alice);
        assertEq(paid, 0);
    }

    // ─── planOf: what SepehrCore reads ─────────────────────────

    function test_planOf_returnsTheTierExpiryCapAndFee() public {
        vm.prank(alice);
        subs.subscribe(2, true);
        ISepehrSubscriptions.Plan memory plan = subs.planOf(alice);
        assertEq(plan.tier, 2);
        assertEq(plan.expiresAt, block.timestamp + ANNUAL_PERIOD);
        assertEq(plan.maxCollateralUsd, 100_000e8);
        assertEq(plan.feeBps, 15);

        subs.grantTitanSubscription(bob, 30 days);
        plan = subs.planOf(bob);
        assertEq(plan.tier, 4);
        assertEq(plan.maxCollateralUsd, type(uint256).max);
        assertEq(plan.feeBps, 10);
    }

    function test_planOf_isEmptyWithoutASubscription() public view {
        ISepehrSubscriptions.Plan memory plan = subs.planOf(alice);
        assertEq(plan.tier, 0);
        assertEq(plan.expiresAt, 0);
    }

    // ─── Governance and deployment ─────────────────────────────

    function test_setTimelock_movesGovernance() public {
        address next = makeAddr("next timelock");
        vm.expectEmit(true, true, false, false, address(subs));
        emit SepehrEvents.TimelockUpdated(timelock, next);
        vm.prank(timelock);
        subs.setTimelock(next);
        assertEq(subs.timelock(), next);

        vm.expectRevert(SepehrErrors.NotTimelock.selector);
        vm.prank(timelock);
        subs.setTierFeeBps(1, 30);
        vm.prank(next);
        subs.setTierFeeBps(1, 30);
        assertEq(subs.TIER_FEE_BPS(0), 30);
    }

    function test_setTimelock_revertsFromAnyoneElseOrOnZero() public {
        vm.expectRevert(SepehrErrors.NotTimelock.selector);
        subs.setTimelock(alice);
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        vm.prank(timelock);
        subs.setTimelock(address(0));
    }

    function test_coreAndSubscriptionsNameEachOther() public view {
        assertEq(address(subs.core()), address(core));
        assertEq(address(core.subscriptions()), address(subs));
    }

    function test_coreRefusesSubscriptionsNamingAnotherCore() public {
        SepehrSubscriptions other =
            new SepehrSubscriptions(address(this), timelock, address(usdc), block.chainid, makeAddr("another core"));
        vm.expectRevert(SepehrErrors.CoreMismatch.selector);
        new SepehrCore(address(this), timelock, guardian, address(other), 0, type(uint256).max, block.chainid);
    }

    function test_constructor_revertsOnZeroAddressesAndWrongChain() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new SepehrSubscriptions(address(this), address(0), address(usdc), block.chainid, address(core));
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new SepehrSubscriptions(address(this), timelock, address(0), block.chainid, address(core));
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new SepehrSubscriptions(address(this), timelock, address(usdc), block.chainid, address(0));
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        new SepehrSubscriptions(address(this), timelock, address(usdc), 0, address(core));
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.WrongChain.selector, block.chainid + 1, block.chainid));
        new SepehrSubscriptions(address(this), timelock, address(usdc), block.chainid + 1, address(core));
    }

    function test_unsubscribe_clearsTheProtectionsInTheCore() public {
        vm.prank(alice);
        subs.subscribe(1, false);
        vm.expectCall(address(core), abi.encodeCall(core.clearProtections, (alice)));
        vm.prank(alice);
        subs.unsubscribe();
    }
}
