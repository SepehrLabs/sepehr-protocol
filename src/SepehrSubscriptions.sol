// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ISepehrCore} from "./interfaces/ISepehrCore.sol";
import {ISepehrSubscriptions} from "./interfaces/ISepehrSubscriptions.sol";
import {SepehrErrors} from "./libraries/SepehrErrors.sol";
import {SepehrEvents} from "./libraries/SepehrEvents.sol";

/// @title SepehrSubscriptions
/// @notice The plans users pay for: subscriptions, renewals, tier changes and cancellations,
///         tier prices, collateral caps and trigger fees. SepehrCore reads a user's plan from
///         here (`planOf`) before it protects or rescues a position, and clears the user's
///         protections when they cancel.
/// @dev M-1: what a subscriber paid is earned by the protocol pro rata over the paid window.
///      `settle` moves the earned part to `ownerRevenue`, the only USDC the owner may withdraw;
///      the unearned part stays in the contract for refunds and tier-change credits, so one
///      user's refund never comes out of another's prepayment.
contract SepehrSubscriptions is ISepehrSubscriptions, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Constants ───────────────────────────────────────────────
    uint256 public constant MONTHLY_PERIOD = 30 days;
    uint256 public constant ANNUAL_PERIOD = 365 days;

    /// @notice A8: ceiling on any tier's trigger fee. A timelock proposal cannot raise a fee
    /// past 1 % of the repaid amount; anything above requires a contract migration.
    uint256 public constant MAX_TIER_FEE_BPS = 100;

    /// @notice A13: largest change one `setTierPrice` may make, in basis points of the old price.
    uint256 public constant MAX_TIER_PRICE_DEVIATION_BPS = 5000;

    /// @notice M1: minimum interval between two `setTierPrice` calls on the same (tier, annual)
    /// key, so two ±50 % moves cannot compound inside two timelock cycles.
    uint256 public constant TIER_PRICE_UPDATE_COOLDOWN = 7 days;

    uint256[3] public TIER_PRICES_MONTHLY_USD_6 = [
        4_990_000, // Shield: $4.99/mo
        14_990_000, // Guardian: $14.99/mo
        49_990_000 // Watchtower: $49.99/mo
    ];

    uint256[3] public TIER_PRICES_ANNUAL_USD_6 = [
        49_000_000, // Shield: $49/yr
        149_000_000, // Guardian: $149/yr
        499_000_000 // Watchtower: $499/yr
    ];

    uint256[4] public TIER_FEE_BPS = [
        20, // Shield: 0.20%
        15, // Guardian: 0.15%
        10, // Watchtower: 0.10%
        10 // Titan: 0.10%
    ];

    uint256[4] public TIER_MAX_COLLATERAL_USD_8 = [
        15_000e8, // Shield: up to $15k
        100_000e8, // Guardian: up to $100k
        300_000e8, // Watchtower: up to $300k
        type(uint256).max // Titan: unlimited
    ];

    // ─── State ───────────────────────────────────────────────────
    /// @notice Subscription payment token.
    IERC20 public immutable usdc;
    /// @notice ADR-0011: chain this instance operates on; every mutation checks it.
    uint256 public immutable expectedChainId;
    /// @notice Sole caller of the price and fee setters, and of `setTimelock`.
    address public timelock;
    /// @notice The SepehrCore whose pause applies here and whose protections a cancellation
    /// clears. Deployed right after this contract, at an address known in advance; its
    /// constructor checks that it is the core named here.
    ISepehrCore public immutable core;

    mapping(address user => Subscription) internal _subscriptions;

    /// @notice M-1: the current paid window: what the user paid for it, when it started, and
    /// how much of it `settle` already counted as earned.
    struct SubscriptionPayment {
        uint256 paid;
        uint256 startedAt;
        uint256 settled;
    }

    mapping(address user => SubscriptionPayment) public subscriptionPayments;

    /// @notice M-1: subscription revenue earned and settled, the only USDC the owner may withdraw.
    uint256 public ownerRevenue;

    /// @notice M1: when `setTierPrice` last changed each (tier, annual) price.
    mapping(uint8 tier => mapping(bool annual => uint256 lastUpdatedAt)) public tierPriceLastUpdatedAt;

    // ─── Modifiers ───────────────────────────────────────────────
    modifier onlyExpectedChain() {
        if (block.chainid != expectedChainId) {
            revert SepehrErrors.WrongChain(expectedChainId, block.chainid);
        }
        _;
    }

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert SepehrErrors.NotTimelock();
        _;
    }

    /// @dev Subscribing follows SepehrCore's pause.
    modifier whenCoreLive() {
        if (core.paused()) revert SepehrErrors.ContractPaused();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────
    /// @param _owner Protocol owner: grants Titan, withdraws earned revenue.
    /// @param _timelock Governance delay; sole caller of the price, fee and timelock setters.
    /// @param _usdc Subscription payment token.
    /// @param _expectedChainId ADR-0011: must equal `block.chainid` at deploy time.
    /// @param _core The SepehrCore deployed next, which checks it is the core named here.
    constructor(
        address _owner,
        address _timelock,
        address _usdc,
        uint256 _expectedChainId,
        address _core
    ) Ownable(_owner) {
        if (_timelock == address(0) || _usdc == address(0) || _core == address(0)) {
            revert SepehrErrors.ZeroAddress();
        }
        if (_expectedChainId == 0) revert SepehrErrors.ZeroAmount();
        if (block.chainid != _expectedChainId) revert SepehrErrors.WrongChain(_expectedChainId, block.chainid);
        timelock = _timelock;
        usdc = IERC20(_usdc);
        expectedChainId = _expectedChainId;
        core = ISepehrCore(_core);
    }

    // ─── User: Subscriptions ─────────────────────────────────────

    /// @inheritdoc ISepehrSubscriptions
    function subscribe(
        uint8 tier,
        bool annual
    ) external override onlyExpectedChain nonReentrant whenCoreLive {
        if (tier == 0 || tier > 4) revert SepehrErrors.InvalidTier();
        if (tier == 4) revert SepehrErrors.TitanSelfSubscribeNotAllowed();
        if (_subscriptions[msg.sender].expiresAt > block.timestamp) {
            revert SepehrErrors.SubscriptionAlreadyActive();
        }
        _settle(msg.sender);

        uint256 price = _price(tier, annual);
        usdc.safeTransferFrom(msg.sender, address(this), price);

        uint256 expiresAt = block.timestamp + _duration(annual);
        _subscriptions[msg.sender] = Subscription({tier: tier, annual: annual, expiresAt: expiresAt});
        subscriptionPayments[msg.sender] = SubscriptionPayment({paid: price, startedAt: block.timestamp, settled: 0});

        emit SepehrEvents.Subscribed(msg.sender, expiresAt, tier, annual, block.chainid);
    }

    /// @inheritdoc ISepehrSubscriptions
    /// @dev M-1: the earned part of the current window is settled first; an active window's
    /// unused part carries into the new window, which runs from now to the extended expiry.
    function renew() external override onlyExpectedChain nonReentrant whenCoreLive {
        Subscription storage sub = _subscriptions[msg.sender];
        if (sub.tier == 0) revert SepehrErrors.SubscriptionNotFound();
        if (sub.tier == 4) revert SepehrErrors.TitanSelfSubscribeNotAllowed();
        _settle(msg.sender);

        uint256 price = _price(sub.tier, sub.annual);
        usdc.safeTransferFrom(msg.sender, address(this), price);

        uint256 carried = _unsettled(msg.sender);
        uint256 duration = _duration(sub.annual);
        sub.expiresAt = (sub.expiresAt > block.timestamp ? sub.expiresAt : block.timestamp) + duration;
        subscriptionPayments[msg.sender] =
            SubscriptionPayment({paid: carried + price, startedAt: block.timestamp, settled: 0});

        emit SepehrEvents.Renewed(msg.sender, sub.expiresAt, sub.tier, sub.annual);
    }

    /// @inheritdoc ISepehrSubscriptions
    /// @dev A12: the unused part of what the user paid is credited against the new price; a
    /// credit larger than the price is refunded. Titan (tier 4) stays owner-granted.
    function upgradeTier(
        uint8 newTier,
        bool newAnnual
    ) external override onlyExpectedChain nonReentrant whenCoreLive {
        if (newTier == 0 || newTier > 4) revert SepehrErrors.InvalidTier();
        if (newTier == 4) revert SepehrErrors.TitanSelfSubscribeNotAllowed();

        Subscription storage sub = _subscriptions[msg.sender];
        if (sub.tier == 0) revert SepehrErrors.SubscriptionNotFound();
        if (sub.expiresAt <= block.timestamp) revert SepehrErrors.SubscriptionExpired();
        if (sub.tier == 4) revert SepehrErrors.UpgradeTierPathInvalid(4, newTier);
        if (sub.tier == newTier && sub.annual == newAnnual) revert SepehrErrors.SameTierUpgrade();
        _settle(msg.sender);

        uint256 credit = _unsettled(msg.sender);
        uint256 newPrice = _price(newTier, newAnnual);
        if (newPrice > credit) {
            usdc.safeTransferFrom(msg.sender, address(this), newPrice - credit);
        } else if (newPrice < credit) {
            usdc.safeTransfer(msg.sender, credit - newPrice);
        }

        uint8 oldTier = sub.tier;
        sub.tier = newTier;
        sub.annual = newAnnual;
        sub.expiresAt = block.timestamp + _duration(newAnnual);
        subscriptionPayments[msg.sender] = SubscriptionPayment({paid: newPrice, startedAt: block.timestamp, settled: 0});

        emit SepehrEvents.TierUpgraded(msg.sender, oldTier, newTier);
        emit SepehrEvents.Subscribed(msg.sender, sub.expiresAt, newTier, newAnnual, block.chainid);
    }

    /// @inheritdoc ISepehrSubscriptions
    /// @dev H25 / M-1: refunds the unused part of what the user paid, which settlement keeps in
    /// the contract. Titan grants were never paid and refund nothing. Not paused: a user may
    /// always leave.
    function unsubscribe() external override onlyExpectedChain nonReentrant {
        if (_subscriptions[msg.sender].tier == 0) revert SepehrErrors.SubscriptionNotFound();
        _settle(msg.sender);
        uint256 refund = _unsettled(msg.sender);

        delete _subscriptions[msg.sender];
        delete subscriptionPayments[msg.sender];
        core.clearProtections(msg.sender);

        if (refund > 0) usdc.safeTransfer(msg.sender, refund);
        emit SepehrEvents.Unsubscribed(msg.sender);
    }

    // ─── Revenue (M-1) ───────────────────────────────────────────

    /// @notice Count as owner revenue what each of `users` has earned the protocol so far.
    /// @dev Callable by anyone: it only moves the earned part of each paid window, pro rata to
    /// the time elapsed, out of what refunds may draw on.
    /// @param users Subscribers to settle.
    function settle(
        address[] calldata users
    ) external onlyExpectedChain {
        for (uint256 i = 0; i < users.length; i++) {
            _settle(users[i]);
        }
    }

    /// @notice Withdraw the settled subscription revenue to the owner.
    /// @dev A10: the recipient is always `owner()`. Unearned prepayments stay in the contract.
    function withdrawRevenue() external onlyExpectedChain nonReentrant {
        if (msg.sender != owner()) revert SepehrErrors.NotOwner();
        uint256 amount = ownerRevenue;
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        ownerRevenue = 0;
        address to = owner();
        usdc.safeTransfer(to, amount);
        emit SepehrEvents.OwnerFeesWithdrawn(address(usdc), to, amount);
    }

    // ─── Owner ───────────────────────────────────────────────────

    /// @notice Grant a Titan (tier 4) subscription free of charge.
    /// @dev Owner-only so partners and testers can be onboarded at once. Refuses to overwrite an
    /// active paid plan, which would void its prepaid time without a refund.
    /// @param user Recipient of the Titan subscription.
    /// @param durationSeconds Length of the subscription from now.
    function grantTitanSubscription(
        address user,
        uint256 durationSeconds
    ) external onlyExpectedChain {
        if (msg.sender != owner()) revert SepehrErrors.NotOwner();
        if (user == address(0)) revert SepehrErrors.ZeroAddress();
        if (durationSeconds == 0) revert SepehrErrors.ZeroAmount();
        Subscription storage existing = _subscriptions[user];
        if (existing.tier != 0 && existing.tier != 4 && existing.expiresAt > block.timestamp) {
            revert SepehrErrors.SubscriptionAlreadyActive();
        }
        _settle(user);

        _subscriptions[user] = Subscription({tier: 4, annual: false, expiresAt: block.timestamp + durationSeconds});
        delete subscriptionPayments[user];

        emit SepehrEvents.TitanSubscriptionGranted(user, block.timestamp + durationSeconds);
    }

    // ─── Admin (Timelock-gated) ──────────────────────────────────

    /// @notice Update one tier's trigger fee.
    /// @param tier Tier index in [1, 4].
    /// @param newBps Fee in basis points of the repaid amount; at most `MAX_TIER_FEE_BPS`.
    function setTierFeeBps(
        uint8 tier,
        uint256 newBps
    ) external onlyExpectedChain onlyTimelock {
        if (tier == 0 || tier > 4) revert SepehrErrors.InvalidTier();
        if (newBps > MAX_TIER_FEE_BPS) revert SepehrErrors.TierFeeBpsTooHigh(newBps, MAX_TIER_FEE_BPS);
        uint256 old = TIER_FEE_BPS[tier - 1];
        TIER_FEE_BPS[tier - 1] = newBps;
        emit SepehrEvents.TierFeeBpsUpdated(tier, old, newBps);
    }

    /// @notice Update the USDC-6 price of a tier, monthly or annual.
    /// @dev A13 / M1: at most ±`MAX_TIER_PRICE_DEVIATION_BPS` per call, and one call per
    /// (tier, annual) per `TIER_PRICE_UPDATE_COOLDOWN` after the first. A price change never
    /// alters what a paid window refunds (M-1).
    /// @param tier Tier index in [1, 3].
    /// @param annual True for the annual price, false for the monthly one.
    /// @param newPrice Replacement price in USDC-6 units.
    function setTierPrice(
        uint8 tier,
        bool annual,
        uint256 newPrice
    ) external onlyExpectedChain onlyTimelock {
        if (tier == 0 || tier >= 4) revert SepehrErrors.InvalidTier();
        if (newPrice == 0) revert SepehrErrors.ZeroAmount();
        uint256 lastUpdate = tierPriceLastUpdatedAt[tier][annual];
        if (lastUpdate != 0 && block.timestamp < lastUpdate + TIER_PRICE_UPDATE_COOLDOWN) {
            revert SepehrErrors.TierPriceCooldown(lastUpdate, lastUpdate + TIER_PRICE_UPDATE_COOLDOWN);
        }

        uint256 old = _price(tier, annual);
        uint256 minAllowed = (old * (10_000 - MAX_TIER_PRICE_DEVIATION_BPS)) / 10_000;
        uint256 maxAllowed = (old * (10_000 + MAX_TIER_PRICE_DEVIATION_BPS)) / 10_000;
        if (newPrice < minAllowed || newPrice > maxAllowed) {
            revert SepehrErrors.TierPriceDeviationTooLarge(old, newPrice);
        }
        if (annual) TIER_PRICES_ANNUAL_USD_6[tier - 1] = newPrice;
        else TIER_PRICES_MONTHLY_USD_6[tier - 1] = newPrice;
        tierPriceLastUpdatedAt[tier][annual] = block.timestamp;
        emit SepehrEvents.TierPriceUpdated(tier, annual, old, newPrice);
    }

    /// @notice Hand governance to another timelock (a multisig-driven one, for instance).
    /// @dev Called by the current timelock, so the change waits out its delay in public.
    /// @param newTimelock The new sole caller of the timelock-gated setters.
    function setTimelock(
        address newTimelock
    ) external onlyExpectedChain onlyTimelock {
        if (newTimelock == address(0)) revert SepehrErrors.ZeroAddress();
        emit SepehrEvents.TimelockUpdated(timelock, newTimelock);
        timelock = newTimelock;
    }

    // ─── Views ───────────────────────────────────────────────────

    /// @inheritdoc ISepehrSubscriptions
    function getSubscription(
        address user
    ) external view override onlyExpectedChain returns (Subscription memory) {
        return _subscriptions[user];
    }

    /// @inheritdoc ISepehrSubscriptions
    function planOf(
        address user
    ) external view override onlyExpectedChain returns (Plan memory plan) {
        Subscription storage sub = _subscriptions[user];
        if (sub.tier == 0) return plan;
        plan = Plan({
            tier: sub.tier,
            expiresAt: sub.expiresAt,
            maxCollateralUsd: TIER_MAX_COLLATERAL_USD_8[sub.tier - 1],
            feeBps: TIER_FEE_BPS[sub.tier - 1]
        });
    }

    /// @notice M-1: what `user` would get back by cancelling now.
    /// @param user The subscriber.
    /// @return The unused part of what they paid for the current window.
    function refundableOf(
        address user
    ) external view onlyExpectedChain returns (uint256) {
        SubscriptionPayment storage payment = subscriptionPayments[user];
        return payment.paid - _earned(user);
    }

    /// @notice Every tier's trigger fee, in basis points.
    function getTierFeeBps() external view returns (uint256[4] memory) {
        return TIER_FEE_BPS;
    }

    /// @notice Every self-service tier's monthly price, USDC-6.
    function getTierPricesMonthly() external view returns (uint256[3] memory) {
        return TIER_PRICES_MONTHLY_USD_6;
    }

    /// @notice Every self-service tier's annual price, USDC-6.
    function getTierPricesAnnual() external view returns (uint256[3] memory) {
        return TIER_PRICES_ANNUAL_USD_6;
    }

    /// @notice Every tier's collateral cap, USD-8.
    function getTierMaxCollateralUsd() external view returns (uint256[4] memory) {
        return TIER_MAX_COLLATERAL_USD_8;
    }

    // ─── Internal ────────────────────────────────────────────────

    function _price(
        uint8 tier,
        bool annual
    ) private view returns (uint256) {
        return annual ? TIER_PRICES_ANNUAL_USD_6[tier - 1] : TIER_PRICES_MONTHLY_USD_6[tier - 1];
    }

    function _duration(
        bool annual
    ) private pure returns (uint256) {
        return annual ? ANNUAL_PERIOD : MONTHLY_PERIOD;
    }

    /// @dev M-1: what the protocol has earned of the current window, pro rata to the time elapsed.
    function _earned(
        address user
    ) private view returns (uint256) {
        SubscriptionPayment storage payment = subscriptionPayments[user];
        if (payment.paid == 0) return 0;
        uint256 expiresAt = _subscriptions[user].expiresAt;
        if (block.timestamp >= expiresAt) return payment.paid;
        return (payment.paid * (block.timestamp - payment.startedAt)) / (expiresAt - payment.startedAt);
    }

    /// @dev What the user paid for the current window and settlement has not taken.
    function _unsettled(
        address user
    ) private view returns (uint256) {
        SubscriptionPayment storage payment = subscriptionPayments[user];
        return payment.paid - payment.settled;
    }

    /// @dev M-1: move the earned and not yet settled part of `user`'s window to `ownerRevenue`.
    function _settle(
        address user
    ) private {
        SubscriptionPayment storage payment = subscriptionPayments[user];
        uint256 earned = _earned(user);
        if (earned <= payment.settled) return;
        uint256 amount = earned - payment.settled;
        payment.settled = earned;
        ownerRevenue += amount;
        emit SepehrEvents.RevenueSettled(user, amount);
    }
}
