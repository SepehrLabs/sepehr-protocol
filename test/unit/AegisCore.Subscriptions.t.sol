// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {AegisCore} from "../../src/AegisCore.sol";
import {IAegisCore} from "../../src/interfaces/IAegisCore.sol";
import {AegisErrors} from "../../src/libraries/AegisErrors.sol";
import {AegisEvents} from "../../src/libraries/AegisEvents.sol";
import {MockOracle} from "../../src/mocks/MockOracle.sol";

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

contract AegisCoreSubscriptionsTest is Test {
    AegisCore public core;
    MockOracle public oracle;
    MockERC20 public usdc;

    address public timelock = makeAddr("timelock");
    address public guardian = makeAddr("guardian");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 constant SUBSCRIPTION_PERIOD = 30 days;

    // Tier prices in 6-decimal USD
    uint256 constant TIER1_PRICE = 9_990_000;
    uint256 constant TIER2_PRICE = 29_990_000;
    uint256 constant TIER3_PRICE = 79_990_000;
    uint256 constant TIER4_PRICE = 149_990_000;

    function setUp() public {
        oracle = new MockOracle();
        usdc = new MockERC20("USD Coin", "USDC");

        core = new AegisCore(address(this), timelock, guardian, address(oracle), 500e8, 30);

        // Fund alice and bob with USDC and approve the core contract
        usdc.mint(alice, 1000e6);
        usdc.mint(bob, 1000e6);
        vm.prank(alice);
        usdc.approve(address(core), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(core), type(uint256).max);
    }

    // ─── subscribe ──────────────────────────────────────────────

    function test_subscribe_tier1() public {
        vm.prank(alice);
        core.subscribe(1, address(usdc));

        IAegisCore.Subscription memory sub = core.getSubscription(alice);
        assertEq(sub.tier, 1);
        assertEq(sub.expiresAt, block.timestamp + SUBSCRIPTION_PERIOD);
    }

    function test_subscribe_tier2() public {
        vm.prank(alice);
        core.subscribe(2, address(usdc));

        IAegisCore.Subscription memory sub = core.getSubscription(alice);
        assertEq(sub.tier, 2);
        assertEq(sub.expiresAt, block.timestamp + SUBSCRIPTION_PERIOD);
    }

    function test_subscribe_tier3() public {
        vm.prank(alice);
        core.subscribe(3, address(usdc));

        IAegisCore.Subscription memory sub = core.getSubscription(alice);
        assertEq(sub.tier, 3);
    }

    function test_subscribe_tier4() public {
        usdc.mint(alice, 200e6); // top up for tier4
        vm.prank(alice);
        core.subscribe(4, address(usdc));

        IAegisCore.Subscription memory sub = core.getSubscription(alice);
        assertEq(sub.tier, 4);
    }

    function test_subscribe_emitsEvent() public {
        vm.prank(alice);

        vm.expectEmit(true, false, false, true, address(core));
        emit AegisEvents.Subscribed(alice, block.timestamp + SUBSCRIPTION_PERIOD, 1, block.chainid);

        core.subscribe(1, address(usdc));
    }

    function test_subscribe_transfersPayment() public {
        uint256 balanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        core.subscribe(1, address(usdc));

        uint256 balanceAfter = usdc.balanceOf(alice);
        assertEq(balanceBefore - balanceAfter, TIER1_PRICE);
        assertEq(usdc.balanceOf(address(core)), TIER1_PRICE);
    }

    function test_subscribe_transfersCorrectAmountPerTier() public {
        // Tier 2
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        core.subscribe(2, address(usdc));
        assertEq(balBefore - usdc.balanceOf(alice), TIER2_PRICE);
    }

    // ─── subscribe reverts ──────────────────────────────────────

    function test_subscribe_revertsOnTierZero() public {
        vm.expectRevert(AegisErrors.InvalidTier.selector);
        vm.prank(alice);
        core.subscribe(0, address(usdc));
    }

    function test_subscribe_revertsOnTierFive() public {
        vm.expectRevert(AegisErrors.InvalidTier.selector);
        vm.prank(alice);
        core.subscribe(5, address(usdc));
    }

    function test_subscribe_revertsOnTierAboveFour() public {
        vm.expectRevert(AegisErrors.InvalidTier.selector);
        vm.prank(alice);
        core.subscribe(255, address(usdc));
    }

    function test_subscribe_revertsWhenAlreadyActive() public {
        vm.prank(alice);
        core.subscribe(1, address(usdc));

        vm.expectRevert(AegisErrors.SubscriptionAlreadyActive.selector);
        vm.prank(alice);
        core.subscribe(2, address(usdc));
    }

    function test_subscribe_succeedsAfterExpiry() public {
        vm.prank(alice);
        core.subscribe(1, address(usdc));

        // Warp past expiry
        vm.warp(block.timestamp + SUBSCRIPTION_PERIOD + 1);

        vm.prank(alice);
        core.subscribe(2, address(usdc));

        IAegisCore.Subscription memory sub = core.getSubscription(alice);
        assertEq(sub.tier, 2);
    }

    // ─── renew ──────────────────────────────────────────────────

    function test_renew_extendsFromExpiry_whenStillActive() public {
        vm.prank(alice);
        core.subscribe(1, address(usdc));

        // Read the actual expiresAt from the contract
        uint256 originalExpiry = core.getSubscription(alice).expiresAt;

        // Renew while subscription is still active (halfway through)
        vm.warp(block.timestamp + 15 days);
        vm.prank(alice);
        core.renew(address(usdc));

        IAegisCore.Subscription memory sub = core.getSubscription(alice);
        // Should extend from the original expiry, not from now
        assertEq(sub.expiresAt, originalExpiry + SUBSCRIPTION_PERIOD);
    }

    function test_renew_extendsFromNow_whenExpired() public {
        vm.prank(alice);
        core.subscribe(1, address(usdc));

        uint256 originalExpiry = core.getSubscription(alice).expiresAt;

        // Warp past expiry
        vm.warp(originalExpiry + 7 days);
        uint256 renewTime = block.timestamp;

        vm.prank(alice);
        core.renew(address(usdc));

        IAegisCore.Subscription memory sub = core.getSubscription(alice);
        // Should extend from now (block.timestamp), not from old expiry
        assertEq(sub.expiresAt, renewTime + SUBSCRIPTION_PERIOD);
    }

    function test_renew_emitsEvent() public {
        vm.prank(alice);
        core.subscribe(1, address(usdc));

        uint256 expectedExpiry = block.timestamp + SUBSCRIPTION_PERIOD + SUBSCRIPTION_PERIOD;

        vm.prank(alice);

        vm.expectEmit(true, false, false, true, address(core));
        emit AegisEvents.Renewed(alice, expectedExpiry, 1);

        core.renew(address(usdc));
    }

    function test_renew_transfersPayment() public {
        vm.prank(alice);
        core.subscribe(1, address(usdc));

        uint256 balanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        core.renew(address(usdc));

        assertEq(balanceBefore - usdc.balanceOf(alice), TIER1_PRICE);
    }

    function test_renew_revertsWhenNoSubscription() public {
        vm.expectRevert(AegisErrors.SubscriptionNotFound.selector);
        vm.prank(alice);
        core.renew(address(usdc));
    }

    // ─── unsubscribe ────────────────────────────────────────────

    function test_unsubscribe_clearsData() public {
        vm.prank(alice);
        core.subscribe(1, address(usdc));

        vm.prank(alice);
        core.unsubscribe();

        IAegisCore.Subscription memory sub = core.getSubscription(alice);
        assertEq(sub.tier, 0);
        assertEq(sub.expiresAt, 0);
        assertEq(sub.collateralValueUsdSnapshot, 0);
    }

    function test_unsubscribe_emitsEvent() public {
        vm.prank(alice);
        core.subscribe(1, address(usdc));

        vm.prank(alice);

        vm.expectEmit(true, false, false, false, address(core));
        emit AegisEvents.Unsubscribed(alice);

        core.unsubscribe();
    }

    function test_unsubscribe_revertsWhenNoneExists() public {
        vm.expectRevert(AegisErrors.SubscriptionNotFound.selector);
        vm.prank(alice);
        core.unsubscribe();
    }

    function test_unsubscribe_revertsWhenAlreadyUnsubscribed() public {
        vm.prank(alice);
        core.subscribe(1, address(usdc));

        vm.prank(alice);
        core.unsubscribe();

        vm.expectRevert(AegisErrors.SubscriptionNotFound.selector);
        vm.prank(alice);
        core.unsubscribe();
    }

    // ─── subscription expiry ────────────────────────────────────

    function test_subscription_isActive_beforeExpiry() public {
        vm.prank(alice);
        core.subscribe(1, address(usdc));

        IAegisCore.Subscription memory sub = core.getSubscription(alice);
        assertTrue(sub.expiresAt > block.timestamp);
    }

    function test_subscription_isExpired_atExactExpiry() public {
        vm.prank(alice);
        core.subscribe(1, address(usdc));

        // Warp to exact expiry
        vm.warp(block.timestamp + SUBSCRIPTION_PERIOD);

        // The subscription is expired at exactly expiresAt because the check is <=
        // Verify by trying to subscribe again (should succeed if expired)
        vm.prank(alice);
        core.subscribe(1, address(usdc));
    }

    function test_subscription_isExpired_afterExpiry() public {
        vm.prank(alice);
        core.subscribe(1, address(usdc));

        vm.warp(block.timestamp + SUBSCRIPTION_PERIOD + 1);

        // Can re-subscribe since the old one expired
        vm.prank(alice);
        core.subscribe(2, address(usdc));

        IAegisCore.Subscription memory sub = core.getSubscription(alice);
        assertEq(sub.tier, 2);
    }

    // ─── paused state ───────────────────────────────────────────

    function test_subscribe_revertsWhenPaused() public {
        core.pause();

        vm.expectRevert(AegisErrors.ContractPaused.selector);
        vm.prank(alice);
        core.subscribe(1, address(usdc));
    }

    function test_renew_revertsWhenPaused() public {
        vm.prank(alice);
        core.subscribe(1, address(usdc));

        core.pause();

        vm.expectRevert(AegisErrors.ContractPaused.selector);
        vm.prank(alice);
        core.renew(address(usdc));
    }

    // ─── multiple users ─────────────────────────────────────────

    function test_subscribe_multipleUsersIndependent() public {
        vm.prank(alice);
        core.subscribe(1, address(usdc));

        vm.prank(bob);
        core.subscribe(3, address(usdc));

        IAegisCore.Subscription memory subAlice = core.getSubscription(alice);
        IAegisCore.Subscription memory subBob = core.getSubscription(bob);

        assertEq(subAlice.tier, 1);
        assertEq(subBob.tier, 3);
    }
}
