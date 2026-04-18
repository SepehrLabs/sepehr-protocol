// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {SepehrCore} from "../../src/SepehrCore.sol";
import {ISepehrCore} from "../../src/interfaces/ISepehrCore.sol";
import {SepehrErrors} from "../../src/libraries/SepehrErrors.sol";
import {SepehrEvents} from "../../src/libraries/SepehrEvents.sol";

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

contract SepehrCoreSubscriptionsTest is Test {
    SepehrCore public core;
    MockERC20 public usdc;

    address public timelock = makeAddr("timelock");
    address public guardian = makeAddr("guardian");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 constant MONTHLY_PERIOD = 30 days;
    uint256 constant ANNUAL_PERIOD = 365 days;

    // Tier prices (6-decimal USDC)
    uint256 constant SHIELD_MONTHLY = 9_000_000;
    uint256 constant GUARDIAN_MONTHLY = 49_000_000;
    uint256 constant WATCHTOWER_MONTHLY = 200_000_000;
    uint256 constant SHIELD_ANNUAL = 86_400_000;
    uint256 constant GUARDIAN_ANNUAL = 470_400_000;
    uint256 constant WATCHTOWER_ANNUAL = 1_920_000_000;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC");

        core = new SepehrCore(address(this), timelock, guardian, address(usdc), 500e8);

        usdc.mint(alice, 10_000e6);
        usdc.mint(bob, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(core), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(core), type(uint256).max);
    }

    // ─── subscribe (monthly) ────────────────────────────────────

    function test_subscribe_tier1_monthly() public {
        vm.prank(alice);
        core.subscribe(1, false);

        ISepehrCore.Subscription memory sub = core.getSubscription(alice);
        assertEq(sub.tier, 1);
        assertFalse(sub.annual);
        assertEq(sub.expiresAt, block.timestamp + MONTHLY_PERIOD);
    }

    function test_subscribe_tier2_monthly() public {
        vm.prank(alice);
        core.subscribe(2, false);

        ISepehrCore.Subscription memory sub = core.getSubscription(alice);
        assertEq(sub.tier, 2);
        assertEq(sub.expiresAt, block.timestamp + MONTHLY_PERIOD);
    }

    function test_subscribe_tier3_monthly() public {
        vm.prank(alice);
        core.subscribe(3, false);

        ISepehrCore.Subscription memory sub = core.getSubscription(alice);
        assertEq(sub.tier, 3);
    }

    function test_subscribe_emitsEvent_monthly() public {
        vm.prank(alice);

        vm.expectEmit(true, false, false, true, address(core));
        emit SepehrEvents.Subscribed(alice, block.timestamp + MONTHLY_PERIOD, 1, false, block.chainid);

        core.subscribe(1, false);
    }

    function test_subscribe_transfersMonthlyPayment() public {
        uint256 balanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        core.subscribe(1, false);

        assertEq(balanceBefore - usdc.balanceOf(alice), SHIELD_MONTHLY);
        assertEq(usdc.balanceOf(address(core)), SHIELD_MONTHLY);
    }

    function test_subscribe_transfersCorrectAmountPerTier() public {
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        core.subscribe(2, false);
        assertEq(balBefore - usdc.balanceOf(alice), GUARDIAN_MONTHLY);
    }

    // ─── subscribe (annual) ─────────────────────────────────────

    function test_subscribe_tier1_annual() public {
        vm.prank(alice);
        core.subscribe(1, true);

        ISepehrCore.Subscription memory sub = core.getSubscription(alice);
        assertEq(sub.tier, 1);
        assertTrue(sub.annual);
        assertEq(sub.expiresAt, block.timestamp + ANNUAL_PERIOD);
    }

    function test_subscribe_tier2_annual() public {
        vm.prank(alice);
        core.subscribe(2, true);

        ISepehrCore.Subscription memory sub = core.getSubscription(alice);
        assertEq(sub.tier, 2);
        assertTrue(sub.annual);
        assertEq(sub.expiresAt, block.timestamp + ANNUAL_PERIOD);
    }

    function test_subscribe_tier3_annual() public {
        usdc.mint(alice, 2000e6);
        vm.prank(alice);
        core.subscribe(3, true);

        ISepehrCore.Subscription memory sub = core.getSubscription(alice);
        assertEq(sub.tier, 3);
        assertTrue(sub.annual);
    }

    function test_subscribe_emitsEvent_annual() public {
        vm.prank(alice);

        vm.expectEmit(true, false, false, true, address(core));
        emit SepehrEvents.Subscribed(alice, block.timestamp + ANNUAL_PERIOD, 1, true, block.chainid);

        core.subscribe(1, true);
    }

    function test_subscribe_transfersAnnualPayment() public {
        uint256 balanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        core.subscribe(1, true);

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
        core.subscribe(0, false);
    }

    function test_subscribe_revertsOnTierFive() public {
        vm.expectRevert(SepehrErrors.InvalidTier.selector);
        vm.prank(alice);
        core.subscribe(5, false);
    }

    function test_subscribe_revertsOnTierAboveFour() public {
        vm.expectRevert(SepehrErrors.InvalidTier.selector);
        vm.prank(alice);
        core.subscribe(255, false);
    }

    function test_subscribe_revertsOnTitanSelfSubscribe() public {
        vm.expectRevert(SepehrErrors.TitanSelfSubscribeNotAllowed.selector);
        vm.prank(alice);
        core.subscribe(4, false);
    }

    function test_subscribe_revertsOnTitanSelfSubscribe_annual() public {
        vm.expectRevert(SepehrErrors.TitanSelfSubscribeNotAllowed.selector);
        vm.prank(alice);
        core.subscribe(4, true);
    }

    function test_subscribe_revertsWhenAlreadyActive() public {
        vm.prank(alice);
        core.subscribe(1, false);

        vm.expectRevert(SepehrErrors.SubscriptionAlreadyActive.selector);
        vm.prank(alice);
        core.subscribe(2, false);
    }

    function test_subscribe_succeedsAfterExpiry() public {
        vm.prank(alice);
        core.subscribe(1, false);

        vm.warp(block.timestamp + MONTHLY_PERIOD + 1);

        vm.prank(alice);
        core.subscribe(2, false);

        ISepehrCore.Subscription memory sub = core.getSubscription(alice);
        assertEq(sub.tier, 2);
    }

    // ─── renew ──────────────────────────────────────────────────

    function test_renew_extendsFromExpiry_whenStillActive() public {
        vm.prank(alice);
        core.subscribe(1, false);

        uint256 originalExpiry = core.getSubscription(alice).expiresAt;

        vm.warp(block.timestamp + 15 days);
        vm.prank(alice);
        core.renew();

        ISepehrCore.Subscription memory sub = core.getSubscription(alice);
        assertEq(sub.expiresAt, originalExpiry + MONTHLY_PERIOD);
    }

    function test_renew_extendsFromNow_whenExpired() public {
        vm.prank(alice);
        core.subscribe(1, false);

        uint256 originalExpiry = core.getSubscription(alice).expiresAt;

        vm.warp(originalExpiry + 7 days);
        uint256 renewTime = block.timestamp;

        vm.prank(alice);
        core.renew();

        ISepehrCore.Subscription memory sub = core.getSubscription(alice);
        assertEq(sub.expiresAt, renewTime + MONTHLY_PERIOD);
    }

    function test_renew_annual_extendsCorrectDuration() public {
        vm.prank(alice);
        core.subscribe(1, true);

        uint256 originalExpiry = core.getSubscription(alice).expiresAt;

        vm.warp(block.timestamp + 100 days);
        vm.prank(alice);
        core.renew();

        ISepehrCore.Subscription memory sub = core.getSubscription(alice);
        assertEq(sub.expiresAt, originalExpiry + ANNUAL_PERIOD);
    }

    function test_renew_emitsEvent() public {
        vm.prank(alice);
        core.subscribe(1, false);

        uint256 expectedExpiry = block.timestamp + MONTHLY_PERIOD + MONTHLY_PERIOD;

        vm.prank(alice);

        vm.expectEmit(true, false, false, true, address(core));
        emit SepehrEvents.Renewed(alice, expectedExpiry, 1, false);

        core.renew();
    }

    function test_renew_transfersPayment() public {
        vm.prank(alice);
        core.subscribe(1, false);

        uint256 balanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        core.renew();

        assertEq(balanceBefore - usdc.balanceOf(alice), SHIELD_MONTHLY);
    }

    function test_renew_revertsWhenNoSubscription() public {
        vm.expectRevert(SepehrErrors.SubscriptionNotFound.selector);
        vm.prank(alice);
        core.renew();
    }

    function test_renew_revertsForTitanUser() public {
        core.grantTitanSubscription(alice, 365 days);

        vm.expectRevert(SepehrErrors.TitanSelfSubscribeNotAllowed.selector);
        vm.prank(alice);
        core.renew();
    }

    // ─── unsubscribe ────────────────────────────────────────────

    function test_unsubscribe_clearsData() public {
        vm.prank(alice);
        core.subscribe(1, false);

        vm.prank(alice);
        core.unsubscribe();

        ISepehrCore.Subscription memory sub = core.getSubscription(alice);
        assertEq(sub.tier, 0);
        assertEq(sub.expiresAt, 0);
        assertFalse(sub.annual);
        assertEq(sub.collateralValueUsdSnapshot, 0);
    }

    function test_unsubscribe_emitsEvent() public {
        vm.prank(alice);
        core.subscribe(1, false);

        vm.prank(alice);

        vm.expectEmit(true, false, false, false, address(core));
        emit SepehrEvents.Unsubscribed(alice);

        core.unsubscribe();
    }

    function test_unsubscribe_revertsWhenNoneExists() public {
        vm.expectRevert(SepehrErrors.SubscriptionNotFound.selector);
        vm.prank(alice);
        core.unsubscribe();
    }

    function test_unsubscribe_revertsWhenAlreadyUnsubscribed() public {
        vm.prank(alice);
        core.subscribe(1, false);

        vm.prank(alice);
        core.unsubscribe();

        vm.expectRevert(SepehrErrors.SubscriptionNotFound.selector);
        vm.prank(alice);
        core.unsubscribe();
    }

    // ─── subscription expiry ────────────────────────────────────

    function test_subscription_isActive_beforeExpiry() public {
        vm.prank(alice);
        core.subscribe(1, false);

        ISepehrCore.Subscription memory sub = core.getSubscription(alice);
        assertTrue(sub.expiresAt > block.timestamp);
    }

    function test_subscription_isExpired_atExactExpiry() public {
        vm.prank(alice);
        core.subscribe(1, false);

        vm.warp(block.timestamp + MONTHLY_PERIOD);

        vm.prank(alice);
        core.subscribe(1, false);
    }

    function test_subscription_isExpired_afterExpiry() public {
        vm.prank(alice);
        core.subscribe(1, false);

        vm.warp(block.timestamp + MONTHLY_PERIOD + 1);

        vm.prank(alice);
        core.subscribe(2, false);

        ISepehrCore.Subscription memory sub = core.getSubscription(alice);
        assertEq(sub.tier, 2);
    }

    // ─── Titan (owner-granted) ──────────────────────────────────

    function test_grantTitan_setsSubscription() public {
        core.grantTitanSubscription(alice, 365 days);

        ISepehrCore.Subscription memory sub = core.getSubscription(alice);
        assertEq(sub.tier, 4);
        assertEq(sub.expiresAt, block.timestamp + 365 days);
    }

    function test_grantTitan_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(core));
        emit SepehrEvents.TitanSubscriptionGranted(alice, block.timestamp + 365 days);

        core.grantTitanSubscription(alice, 365 days);
    }

    function test_grantTitan_revertsFromNonOwner() public {
        vm.expectRevert(SepehrErrors.NotOwner.selector);
        vm.prank(alice);
        core.grantTitanSubscription(bob, 365 days);
    }

    function test_grantTitan_revertsOnZeroAddress() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        core.grantTitanSubscription(address(0), 365 days);
    }

    function test_grantTitan_revertsOnZeroDuration() public {
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        core.grantTitanSubscription(alice, 0);
    }

    // ─── paused state ───────────────────────────────────────────

    function test_subscribe_revertsWhenPaused() public {
        core.pause();

        vm.expectRevert(SepehrErrors.ContractPaused.selector);
        vm.prank(alice);
        core.subscribe(1, false);
    }

    function test_renew_revertsWhenPaused() public {
        vm.prank(alice);
        core.subscribe(1, false);

        core.pause();

        vm.expectRevert(SepehrErrors.ContractPaused.selector);
        vm.prank(alice);
        core.renew();
    }

    // ─── multiple users ─────────────────────────────────────────

    function test_subscribe_multipleUsersIndependent() public {
        vm.prank(alice);
        core.subscribe(1, false);

        vm.prank(bob);
        core.subscribe(3, false);

        ISepehrCore.Subscription memory subAlice = core.getSubscription(alice);
        ISepehrCore.Subscription memory subBob = core.getSubscription(bob);

        assertEq(subAlice.tier, 1);
        assertEq(subBob.tier, 3);
    }

    // ─── A10: withdrawOwnerFees hardcodes destination to owner() ──

    /// @dev A10: the previous signature accepted an arbitrary `to` address — a compromised
    /// owner key could drain all accrued subscription revenue to a private wallet in a single
    /// transaction. The fix removes the parameter and always sends to the current `owner()`,
    /// so an adversarial transfer requires `transferOwnership` + `acceptOwnership` on the
    /// Ownable2Step path first, which gives users at least one block of observability.
    function test_withdrawOwnerFees_sendsOnlyToCurrentOwner() public {
        vm.prank(alice);
        core.subscribe(1, false); // 9_000_000 USDC accrued to ownerFeeBalances

        address ownerAddr = core.owner();
        uint256 ownerBalBefore = usdc.balanceOf(ownerAddr);

        // Event must carry `to = owner()`, not some arbitrary recipient.
        vm.expectEmit(true, true, false, true, address(core));
        emit SepehrEvents.OwnerFeesWithdrawn(address(usdc), ownerAddr, SHIELD_MONTHLY);

        core.withdrawOwnerFees(address(usdc));

        assertEq(usdc.balanceOf(ownerAddr) - ownerBalBefore, SHIELD_MONTHLY);
        assertEq(core.ownerFeeBalances(address(usdc)), 0);
    }

    function test_withdrawOwnerFees_revertsFromNonOwner() public {
        vm.prank(alice);
        core.subscribe(1, false);

        vm.expectRevert(SepehrErrors.NotOwner.selector);
        vm.prank(alice);
        core.withdrawOwnerFees(address(usdc));
    }

    function test_withdrawOwnerFees_revertsOnZeroAsset() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        core.withdrawOwnerFees(address(0));
    }

    function test_withdrawOwnerFees_revertsOnZeroBalance() public {
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        core.withdrawOwnerFees(address(usdc));
    }
}
