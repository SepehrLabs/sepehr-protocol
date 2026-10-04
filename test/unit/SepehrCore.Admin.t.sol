// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {SepehrCore} from "../../src/SepehrCore.sol";
import {IProtocolAdapter} from "../../src/interfaces/IProtocolAdapter.sol";
import {ISepehrCore} from "../../src/interfaces/ISepehrCore.sol";
import {SepehrErrors} from "../../src/libraries/SepehrErrors.sol";
import {SepehrEvents} from "../../src/libraries/SepehrEvents.sol";
import {MockAdapter} from "../../src/mocks/MockAdapter.sol";
import {MockChainlinkAggregator} from "../helpers/MockChainlinkAggregator.sol";

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
}

contract SepehrCoreAdminTest is Test {
    SepehrCore public core;
    MockAdapter public adapter;
    MockERC20 public usdc;

    address public timelock = makeAddr("timelock");
    address public guardian = makeAddr("guardian");
    address public owner;

    bytes32 public constant PROTOCOL_KEY = keccak256("AAVE_V3");

    function setUp() public {
        owner = address(this);
        adapter = new MockAdapter();
        usdc = new MockERC20("USD Coin", "USDC");

        core = new SepehrCore(owner, timelock, guardian, address(usdc), 500e8, type(uint256).max, block.chainid);
    }

    // ─── addAdapter ─────────────────────────────────────────────

    function test_addAdapter_viaTimelock() public {
        vm.prank(timelock);
        core.addAdapter(PROTOCOL_KEY, address(adapter));

        (IProtocolAdapter adapterResult, bool enabled,) = core.adapters(PROTOCOL_KEY);
        assertEq(address(adapterResult), address(adapter));
        assertTrue(enabled);
    }

    function test_addAdapter_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(core));
        emit SepehrEvents.AdapterAdded(PROTOCOL_KEY, address(adapter));

        vm.prank(timelock);
        core.addAdapter(PROTOCOL_KEY, address(adapter));
    }

    function test_addAdapter_setsAddedAtTimestamp() public {
        uint256 ts = 1_700_000_000;
        vm.warp(ts);

        vm.prank(timelock);
        core.addAdapter(PROTOCOL_KEY, address(adapter));

        (,, uint256 addedAt) = core.adapters(PROTOCOL_KEY);
        assertEq(addedAt, ts);
    }

    function test_addAdapter_revertsOnNonTimelock() public {
        vm.expectRevert(SepehrErrors.NotTimelock.selector);
        core.addAdapter(PROTOCOL_KEY, address(adapter));
    }

    function test_addAdapter_revertsFromGuardian() public {
        vm.expectRevert(SepehrErrors.NotTimelock.selector);
        vm.prank(guardian);
        core.addAdapter(PROTOCOL_KEY, address(adapter));
    }

    function test_addAdapter_revertsOnZeroAddress() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        vm.prank(timelock);
        core.addAdapter(PROTOCOL_KEY, address(0));
    }

    function test_addAdapter_revertsWhenAlreadyRegistered() public {
        vm.prank(timelock);
        core.addAdapter(PROTOCOL_KEY, address(adapter));

        MockAdapter adapter2 = new MockAdapter();
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.AdapterAlreadyRegistered.selector, PROTOCOL_KEY));
        vm.prank(timelock);
        core.addAdapter(PROTOCOL_KEY, address(adapter2));
    }

    // ─── removeAdapter ──────────────────────────────────────────

    function test_removeAdapter() public {
        vm.prank(timelock);
        core.addAdapter(PROTOCOL_KEY, address(adapter));

        vm.prank(timelock);
        core.removeAdapter(PROTOCOL_KEY);

        (IProtocolAdapter adapterResult,,) = core.adapters(PROTOCOL_KEY);
        assertEq(address(adapterResult), address(0));
    }

    function test_removeAdapter_emitsEvent() public {
        vm.prank(timelock);
        core.addAdapter(PROTOCOL_KEY, address(adapter));

        vm.expectEmit(true, false, false, false, address(core));
        emit SepehrEvents.AdapterRemoved(PROTOCOL_KEY);

        vm.prank(timelock);
        core.removeAdapter(PROTOCOL_KEY);
    }

    function test_removeAdapter_revertsOnNonTimelock() public {
        vm.prank(timelock);
        core.addAdapter(PROTOCOL_KEY, address(adapter));

        vm.expectRevert(SepehrErrors.NotTimelock.selector);
        core.removeAdapter(PROTOCOL_KEY);
    }

    function test_removeAdapter_revertsWhenNotRegistered() public {
        bytes32 unknownKey = keccak256("UNKNOWN");
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.AdapterNotRegistered.selector, unknownKey));
        vm.prank(timelock);
        core.removeAdapter(unknownKey);
    }

    // ─── addKeeper ──────────────────────────────────────────────

    function test_addKeeper() public {
        address keeper = makeAddr("keeper");

        vm.prank(timelock);
        core.addKeeper(keeper);

        assertTrue(core.keepers(keeper));
        assertTrue(core.isKeeper(keeper));
    }

    function test_addKeeper_emitsEvent() public {
        address keeper = makeAddr("keeper");

        vm.expectEmit(true, false, false, false, address(core));
        emit SepehrEvents.KeeperAdded(keeper);

        vm.prank(timelock);
        core.addKeeper(keeper);
    }

    function test_addKeeper_revertsOnNonTimelock() public {
        address keeper = makeAddr("keeper");

        vm.expectRevert(SepehrErrors.NotTimelock.selector);
        core.addKeeper(keeper);
    }

    function test_addKeeper_revertsOnZeroAddress() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        vm.prank(timelock);
        core.addKeeper(address(0));
    }

    // ─── removeKeeper ───────────────────────────────────────────

    function test_removeKeeper() public {
        address keeper = makeAddr("keeper");

        vm.prank(timelock);
        core.addKeeper(keeper);

        vm.prank(timelock);
        core.removeKeeper(keeper);

        assertFalse(core.keepers(keeper));
        assertFalse(core.isKeeper(keeper));
    }

    function test_removeKeeper_emitsEvent() public {
        address keeper = makeAddr("keeper");

        vm.prank(timelock);
        core.addKeeper(keeper);

        vm.expectEmit(true, false, false, false, address(core));
        emit SepehrEvents.KeeperRemoved(keeper);

        vm.prank(timelock);
        core.removeKeeper(keeper);
    }

    function test_removeKeeper_revertsOnNonTimelock() public {
        vm.expectRevert(SepehrErrors.NotTimelock.selector);
        core.removeKeeper(makeAddr("keeper"));
    }

    // ─── setTierFeeBps ──────────────────────────────────────────

    function test_setTierFeeBps() public {
        vm.prank(timelock);
        core.setTierFeeBps(1, 50);

        assertEq(core.TIER_FEE_BPS(0), 50);
    }

    function test_setTierFeeBps_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(core));
        emit SepehrEvents.TierFeeBpsUpdated(1, 20, 50);

        vm.prank(timelock);
        core.setTierFeeBps(1, 50);
    }

    function test_setTierFeeBps_revertsOnNonTimelock() public {
        vm.expectRevert(SepehrErrors.NotTimelock.selector);
        core.setTierFeeBps(1, 50);
    }

    function test_setTierFeeBps_revertsOnInvalidTier() public {
        vm.expectRevert(SepehrErrors.InvalidTier.selector);
        vm.prank(timelock);
        core.setTierFeeBps(0, 50);
    }

    function test_setTierFeeBps_revertsOnTierFive() public {
        vm.expectRevert(SepehrErrors.InvalidTier.selector);
        vm.prank(timelock);
        core.setTierFeeBps(5, 50);
    }

    function test_setTierFeeBps_canSetToZero() public {
        vm.prank(timelock);
        core.setTierFeeBps(1, 0);

        assertEq(core.TIER_FEE_BPS(0), 0);
    }

    function test_setTierFeeBps_allTiers() public {
        vm.startPrank(timelock);
        core.setTierFeeBps(1, 15);
        core.setTierFeeBps(2, 8);
        core.setTierFeeBps(3, 3);
        core.setTierFeeBps(4, 2);
        vm.stopPrank();

        assertEq(core.TIER_FEE_BPS(0), 15);
        assertEq(core.TIER_FEE_BPS(1), 8);
        assertEq(core.TIER_FEE_BPS(2), 3);
        assertEq(core.TIER_FEE_BPS(3), 2);
    }

    /// @dev A8: timelock cannot raise any tier fee above `MAX_TIER_FEE_BPS` (1%).
    function test_setTierFeeBps_revertsAboveMaxFeeBps() public {
        uint256 max = core.MAX_TIER_FEE_BPS();
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.TierFeeBpsTooHigh.selector, max + 1, max));
        vm.prank(timelock);
        core.setTierFeeBps(1, max + 1);
    }

    function test_setTierFeeBps_allowsExactlyMaxFeeBps() public {
        uint256 max = core.MAX_TIER_FEE_BPS();
        vm.prank(timelock);
        core.setTierFeeBps(2, max);
        assertEq(core.TIER_FEE_BPS(1), max);
    }

    // ─── A13: setTierPrice ──────────────────────────────────────

    function test_setTierPrice_monthly_happyPath() public {
        uint256 old = core.TIER_PRICES_MONTHLY_USD_6(0);
        uint256 newPrice = old + 1_000_000; // $1 bump
        vm.prank(timelock);
        core.setTierPrice(1, false, newPrice);
        assertEq(core.TIER_PRICES_MONTHLY_USD_6(0), newPrice);
    }

    function test_setTierPrice_annual_happyPath() public {
        uint256 old = core.TIER_PRICES_ANNUAL_USD_6(1);
        uint256 newPrice = old - 10_000_000; // $10 discount
        vm.prank(timelock);
        core.setTierPrice(2, true, newPrice);
        assertEq(core.TIER_PRICES_ANNUAL_USD_6(1), newPrice);
    }

    function test_setTierPrice_emitsEvent() public {
        uint256 old = core.TIER_PRICES_MONTHLY_USD_6(2);
        uint256 newPrice = old + 5_000_000;
        vm.expectEmit(true, false, false, true, address(core));
        emit SepehrEvents.TierPriceUpdated(3, false, old, newPrice);
        vm.prank(timelock);
        core.setTierPrice(3, false, newPrice);
    }

    function test_setTierPrice_revertsOnNonTimelock() public {
        vm.expectRevert(SepehrErrors.NotTimelock.selector);
        core.setTierPrice(1, false, 10_000_000);
    }

    function test_setTierPrice_revertsOnTierZero() public {
        vm.expectRevert(SepehrErrors.InvalidTier.selector);
        vm.prank(timelock);
        core.setTierPrice(0, false, 10_000_000);
    }

    function test_setTierPrice_revertsOnTierFour() public {
        vm.expectRevert(SepehrErrors.InvalidTier.selector);
        vm.prank(timelock);
        core.setTierPrice(4, false, 10_000_000);
    }

    function test_setTierPrice_revertsOnZeroPrice() public {
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        vm.prank(timelock);
        core.setTierPrice(1, false, 0);
    }

    function test_setTierPrice_revertsOnAboveMaxDeviation() public {
        uint256 old = core.TIER_PRICES_MONTHLY_USD_6(0);
        uint256 cap = core.MAX_TIER_PRICE_DEVIATION_BPS();
        uint256 tooHigh = (old * (10_000 + cap)) / 10_000 + 1;
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.TierPriceDeviationTooLarge.selector, old, tooHigh));
        vm.prank(timelock);
        core.setTierPrice(1, false, tooHigh);
    }

    function test_setTierPrice_revertsOnBelowMinDeviation() public {
        uint256 old = core.TIER_PRICES_MONTHLY_USD_6(1);
        uint256 cap = core.MAX_TIER_PRICE_DEVIATION_BPS();
        uint256 tooLow = (old * (10_000 - cap)) / 10_000 - 1;
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.TierPriceDeviationTooLarge.selector, old, tooLow));
        vm.prank(timelock);
        core.setTierPrice(2, false, tooLow);
    }

    function test_setTierPrice_allowsExactlyMaxDeviation() public {
        uint256 old = core.TIER_PRICES_ANNUAL_USD_6(2);
        uint256 cap = core.MAX_TIER_PRICE_DEVIATION_BPS();
        uint256 maxAllowed = (old * (10_000 + cap)) / 10_000;
        vm.prank(timelock);
        core.setTierPrice(3, true, maxAllowed);
        assertEq(core.TIER_PRICES_ANNUAL_USD_6(2), maxAllowed);
    }

    // ─── M1 · tier price cooldown ───────────────────────────────

    function test_setTierPrice_firstCallSkipsCooldown() public {
        uint256 old = core.TIER_PRICES_MONTHLY_USD_6(0);
        uint256 next = (old * 9000) / 10_000; // -10%
        vm.prank(timelock);
        core.setTierPrice(1, false, next);
        assertEq(core.tierPriceLastUpdatedAt(1, false), block.timestamp);
    }

    function test_setTierPrice_revertsWhenInsideCooldown() public {
        uint256 old = core.TIER_PRICES_MONTHLY_USD_6(0);
        uint256 first = (old * 9000) / 10_000;
        vm.prank(timelock);
        core.setTierPrice(1, false, first);

        uint256 lastUpdate = core.tierPriceLastUpdatedAt(1, false);
        uint256 nextAllowed = lastUpdate + core.TIER_PRICE_UPDATE_COOLDOWN();
        vm.warp(nextAllowed - 1);

        uint256 second = (first * 9000) / 10_000;
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.TierPriceCooldown.selector, lastUpdate, nextAllowed));
        vm.prank(timelock);
        core.setTierPrice(1, false, second);
    }

    function test_setTierPrice_allowsExactlyAtCooldownBoundary() public {
        uint256 old = core.TIER_PRICES_MONTHLY_USD_6(0);
        uint256 first = (old * 9000) / 10_000;
        vm.prank(timelock);
        core.setTierPrice(1, false, first);

        vm.warp(block.timestamp + core.TIER_PRICE_UPDATE_COOLDOWN());

        uint256 second = (first * 9000) / 10_000;
        vm.prank(timelock);
        core.setTierPrice(1, false, second);
        assertEq(core.TIER_PRICES_MONTHLY_USD_6(0), second);
    }

    function test_setTierPrice_cooldownIsPerKey() public {
        // A cooldown set on (tier=1, monthly) must not block (tier=2, monthly) or (tier=1, annual).
        uint256 oldM1 = core.TIER_PRICES_MONTHLY_USD_6(0);
        vm.prank(timelock);
        core.setTierPrice(1, false, (oldM1 * 9000) / 10_000);

        uint256 oldM2 = core.TIER_PRICES_MONTHLY_USD_6(1);
        vm.prank(timelock);
        core.setTierPrice(2, false, (oldM2 * 9000) / 10_000);

        uint256 oldA1 = core.TIER_PRICES_ANNUAL_USD_6(0);
        vm.prank(timelock);
        core.setTierPrice(1, true, (oldA1 * 9000) / 10_000);
    }

    // ─── pause ──────────────────────────────────────────────────

    function test_pause_byGuardian() public {
        vm.prank(guardian);
        core.pause();

        assertTrue(core.paused());
        assertEq(core.pausedUntil(), block.timestamp + core.MAX_PAUSE_DURATION());
    }

    function test_pause_byOwner() public {
        core.pause();

        assertTrue(core.paused());
        assertEq(core.pausedUntil(), block.timestamp + core.MAX_PAUSE_DURATION());
    }

    function test_pause_emitsEvent_fromGuardian() public {
        uint256 expectedUntil = block.timestamp + core.MAX_PAUSE_DURATION();
        vm.expectEmit(true, false, false, true, address(core));
        emit SepehrEvents.EmergencyPaused(guardian, expectedUntil);

        vm.prank(guardian);
        core.pause();
    }

    function test_pause_emitsEvent_fromOwner() public {
        uint256 expectedUntil = block.timestamp + core.MAX_PAUSE_DURATION();
        vm.expectEmit(true, false, false, true, address(core));
        emit SepehrEvents.EmergencyPaused(owner, expectedUntil);

        core.pause();
    }

    function test_pause_revertsFromRandomAddress() public {
        address rando = makeAddr("rando");
        vm.expectRevert(SepehrErrors.NotPauseGuardian.selector);
        vm.prank(rando);
        core.pause();
    }

    /// @dev A11: the pause must auto-expire after `MAX_PAUSE_DURATION`. Without this, a
    /// compromised owner/guardian can indefinitely censor user-facing functions.
    function test_pause_autoExpiresAfterMaxDuration() public {
        core.pause();
        assertTrue(core.paused());

        vm.warp(block.timestamp + core.MAX_PAUSE_DURATION());
        assertFalse(core.paused(), "pause must auto-expire exactly at MAX_PAUSE_DURATION");
    }

    function test_pause_stillActiveJustBeforeExpiry() public {
        core.pause();
        vm.warp(block.timestamp + core.MAX_PAUSE_DURATION() - 1);
        assertTrue(core.paused(), "pause must still be active 1s before expiry");
    }

    function test_pause_rePauseExtendsExpiry() public {
        core.pause();
        uint256 firstUntil = core.pausedUntil();

        vm.warp(block.timestamp + 1 days);
        core.pause();
        uint256 secondUntil = core.pausedUntil();

        assertGt(secondUntil, firstUntil, "re-pause must extend expiry");
        assertEq(secondUntil, block.timestamp + core.MAX_PAUSE_DURATION());
    }

    // ─── unpause ────────────────────────────────────────────────

    function test_unpause_byOwner() public {
        core.pause();
        assertTrue(core.paused());

        core.unpause();
        assertFalse(core.paused());
        assertEq(core.pausedUntil(), 0);
    }

    function test_unpause_emitsEvent() public {
        core.pause();

        vm.expectEmit(true, false, false, false, address(core));
        emit SepehrEvents.Unpaused(owner);

        core.unpause();
    }

    function test_unpause_guardianCannotUnpause() public {
        core.pause();

        vm.expectRevert(SepehrErrors.NotOwner.selector);
        vm.prank(guardian);
        core.unpause();
    }

    function test_unpause_revertsFromRandomAddress() public {
        core.pause();

        address rando = makeAddr("rando");
        vm.expectRevert(SepehrErrors.NotOwner.selector);
        vm.prank(rando);
        core.unpause();
    }

    function test_unpause_revertsFromTimelock() public {
        core.pause();

        vm.expectRevert(SepehrErrors.NotOwner.selector);
        vm.prank(timelock);
        core.unpause();
    }

    // ─── Non-timelock admin calls revert ────────────────────────

    function test_addFlashLoanProvider_revertsOnNonTimelock() public {
        vm.expectRevert(SepehrErrors.NotTimelock.selector);
        core.addFlashLoanProvider(makeAddr("provider"));
    }

    function test_removeFlashLoanProvider_revertsOnNonTimelock() public {
        vm.expectRevert(SepehrErrors.NotTimelock.selector);
        core.removeFlashLoanProvider(makeAddr("provider"));
    }

    function test_addDexRouter_revertsOnNonTimelock() public {
        vm.expectRevert(SepehrErrors.NotTimelock.selector);
        core.addDexRouter(makeAddr("dex"));
    }

    function test_removeDexRouter_revertsOnNonTimelock() public {
        vm.expectRevert(SepehrErrors.NotTimelock.selector);
        core.removeDexRouter(makeAddr("dex"));
    }

    function test_setAdapterEnabled_revertsOnNonTimelock() public {
        vm.prank(timelock);
        core.addAdapter(PROTOCOL_KEY, address(adapter));

        vm.expectRevert(SepehrErrors.NotTimelock.selector);
        core.setAdapterEnabled(PROTOCOL_KEY, false);
    }

    function test_setPauseGuardian_revertsOnNonTimelock() public {
        vm.expectRevert(SepehrErrors.NotTimelock.selector);
        core.setPauseGuardian(makeAddr("newGuardian"));
    }

    // ─── Flash loan provider management ─────────────────────────

    function test_addFlashLoanProvider_viaTimelock() public {
        address provider = makeAddr("provider");

        vm.prank(timelock);
        core.addFlashLoanProvider(provider);

        assertTrue(core.allowedFlashProviders(provider));
    }

    function test_removeFlashLoanProvider_viaTimelock() public {
        address provider = makeAddr("provider");

        vm.prank(timelock);
        core.addFlashLoanProvider(provider);

        vm.prank(timelock);
        core.removeFlashLoanProvider(provider);

        assertFalse(core.allowedFlashProviders(provider));
    }

    // ─── DEX router management ──────────────────────────────────

    function test_addDexRouter_viaTimelock() public {
        address router = makeAddr("router");

        vm.prank(timelock);
        core.addDexRouter(router);

        assertTrue(core.allowedDexRouters(router));
    }

    function test_removeDexRouter_viaTimelock() public {
        address router = makeAddr("router");

        vm.prank(timelock);
        core.addDexRouter(router);

        vm.prank(timelock);
        core.removeDexRouter(router);

        assertFalse(core.allowedDexRouters(router));
    }

    /// @dev A14: add emits DexRouterAdded so off-chain monitors can detect whitelist changes.
    function test_addDexRouter_emitsEvent() public {
        address router = makeAddr("router-a");
        vm.expectEmit(true, false, false, false, address(core));
        emit SepehrEvents.DexRouterAdded(router);
        vm.prank(timelock);
        core.addDexRouter(router);
    }

    /// @dev A14: remove emits DexRouterRemoved.
    function test_removeDexRouter_emitsEvent() public {
        address router = makeAddr("router-r");
        vm.prank(timelock);
        core.addDexRouter(router);

        vm.expectEmit(true, false, false, false, address(core));
        emit SepehrEvents.DexRouterRemoved(router);
        vm.prank(timelock);
        core.removeDexRouter(router);
    }

    // ─── setAdapterEnabled ──────────────────────────────────────

    function test_setAdapterEnabled_disable() public {
        vm.prank(timelock);
        core.addAdapter(PROTOCOL_KEY, address(adapter));

        vm.prank(timelock);
        core.setAdapterEnabled(PROTOCOL_KEY, false);

        (, bool enabled,) = core.adapters(PROTOCOL_KEY);
        assertFalse(enabled);
    }

    function test_setAdapterEnabled_reenable() public {
        vm.prank(timelock);
        core.addAdapter(PROTOCOL_KEY, address(adapter));

        vm.prank(timelock);
        core.setAdapterEnabled(PROTOCOL_KEY, false);

        vm.prank(timelock);
        core.setAdapterEnabled(PROTOCOL_KEY, true);

        (, bool enabled,) = core.adapters(PROTOCOL_KEY);
        assertTrue(enabled);
    }

    function test_setAdapterEnabled_emitsDisabledEvent() public {
        vm.prank(timelock);
        core.addAdapter(PROTOCOL_KEY, address(adapter));

        vm.expectEmit(true, false, false, false, address(core));
        emit SepehrEvents.AdapterDisabled(PROTOCOL_KEY);

        vm.prank(timelock);
        core.setAdapterEnabled(PROTOCOL_KEY, false);
    }

    function test_setAdapterEnabled_emitsEnabledEvent() public {
        vm.prank(timelock);
        core.addAdapter(PROTOCOL_KEY, address(adapter));

        vm.prank(timelock);
        core.setAdapterEnabled(PROTOCOL_KEY, false);

        vm.expectEmit(true, false, false, false, address(core));
        emit SepehrEvents.AdapterEnabled(PROTOCOL_KEY);

        vm.prank(timelock);
        core.setAdapterEnabled(PROTOCOL_KEY, true);
    }

    // ─── setPauseGuardian ───────────────────────────────────────

    function test_setPauseGuardian_viaTimelock() public {
        address newGuardian = makeAddr("newGuardian");

        vm.prank(timelock);
        core.setPauseGuardian(newGuardian);

        assertEq(core.pauseGuardian(), newGuardian);
    }

    function test_setPauseGuardian_emitsEvent() public {
        address newGuardian = makeAddr("newGuardian");

        vm.expectEmit(true, true, false, false, address(core));
        emit SepehrEvents.PauseGuardianUpdated(guardian, newGuardian);

        vm.prank(timelock);
        core.setPauseGuardian(newGuardian);
    }

    function test_setPauseGuardian_revertsOnZeroAddress() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        vm.prank(timelock);
        core.setPauseGuardian(address(0));
    }

    // ─── Constructor validation ─────────────────────────────────

    function test_constructor_revertsOnZeroTimelock() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new SepehrCore(owner, address(0), guardian, address(usdc), 500e8, type(uint256).max, block.chainid);
    }

    function test_constructor_revertsOnZeroGuardian() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new SepehrCore(owner, timelock, address(0), address(usdc), 500e8, type(uint256).max, block.chainid);
    }

    function test_constructor_revertsOnZeroUsdc() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new SepehrCore(owner, timelock, guardian, address(0), 500e8, type(uint256).max, block.chainid);
    }

    function test_constructor_setsInitialValues() public {
        assertEq(core.timelock(), timelock);
        assertEq(core.pauseGuardian(), guardian);
        assertEq(core.minCollateralUsd(), 500e8);
        assertEq(address(core.usdc()), address(usdc));
        assertEq(core.owner(), owner);
        assertEq(core.expectedChainId(), block.chainid);
    }

    function test_constructor_revertsOnZeroExpectedChainId() public {
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        new SepehrCore(owner, timelock, guardian, address(usdc), 500e8, type(uint256).max, 0);
    }

    function test_constructor_revertsOnWrongChainId() public {
        uint256 fakeChainId = block.chainid + 1;
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.WrongChain.selector, fakeChainId, block.chainid));
        new SepehrCore(owner, timelock, guardian, address(usdc), 500e8, type(uint256).max, fakeChainId);
    }

    // ─── setMinCollateralUsd (A7) ───────────────────────────────

    function test_setMinCollateralUsd_viaTimelock() public {
        vm.prank(timelock);
        core.setMinCollateralUsd(1000e8);
        assertEq(core.minCollateralUsd(), 1000e8);
    }

    function test_setMinCollateralUsd_revertsOnNonTimelock() public {
        vm.expectRevert(SepehrErrors.NotTimelock.selector);
        core.setMinCollateralUsd(1000e8);
    }

    function test_setMinCollateralUsd_emitsEvent() public {
        vm.expectEmit(false, false, false, true, address(core));
        emit SepehrEvents.MinCollateralUsdUpdated(500e8, 250e8);

        vm.prank(timelock);
        core.setMinCollateralUsd(250e8);
    }

    function test_setMinCollateralUsd_allowsZeroToDisableGate() public {
        vm.prank(timelock);
        core.setMinCollateralUsd(0);
        assertEq(core.minCollateralUsd(), 0);
    }

    // ─── Tier pricing defaults ──────────────────────────────────

    function test_tierFeeBps_defaults() public view {
        assertEq(core.TIER_FEE_BPS(0), 20); // Shield
        assertEq(core.TIER_FEE_BPS(1), 10); // Guardian
        assertEq(core.TIER_FEE_BPS(2), 5); // Watchtower
        assertEq(core.TIER_FEE_BPS(3), 5); // Titan
    }

    function test_tierMaxCollateral_defaults() public view {
        assertEq(core.TIER_MAX_COLLATERAL_USD_8(0), 15_000e8);
        assertEq(core.TIER_MAX_COLLATERAL_USD_8(1), 100_000e8);
        assertEq(core.TIER_MAX_COLLATERAL_USD_8(2), 300_000e8);
        assertEq(core.TIER_MAX_COLLATERAL_USD_8(3), type(uint256).max);
    }

    function test_tierPricesMonthly_defaults() public view {
        assertEq(core.TIER_PRICES_MONTHLY_USD_6(0), 9_000_000);
        assertEq(core.TIER_PRICES_MONTHLY_USD_6(1), 49_000_000);
        assertEq(core.TIER_PRICES_MONTHLY_USD_6(2), 200_000_000);
    }

    function test_tierPricesAnnual_defaults() public view {
        assertEq(core.TIER_PRICES_ANNUAL_USD_6(0), 86_400_000);
        assertEq(core.TIER_PRICES_ANNUAL_USD_6(1), 470_400_000);
        assertEq(core.TIER_PRICES_ANNUAL_USD_6(2), 1_920_000_000);
    }

    // ─── A22: full-array getters for tier pricing state ────────

    function test_getTierFeeBps_returnsAllFour() public view {
        uint256[4] memory arr = core.getTierFeeBps();
        assertEq(arr[0], 20);
        assertEq(arr[1], 10);
        assertEq(arr[2], 5);
        assertEq(arr[3], 5);
    }

    function test_getTierPricesMonthly_returnsAllThree() public view {
        uint256[3] memory arr = core.getTierPricesMonthly();
        assertEq(arr[0], 9_000_000);
        assertEq(arr[1], 49_000_000);
        assertEq(arr[2], 200_000_000);
    }

    function test_getTierPricesAnnual_returnsAllThree() public view {
        uint256[3] memory arr = core.getTierPricesAnnual();
        assertEq(arr[0], 86_400_000);
        assertEq(arr[1], 470_400_000);
        assertEq(arr[2], 1_920_000_000);
    }

    function test_getTierMaxCollateralUsd_returnsAllFour() public view {
        uint256[4] memory arr = core.getTierMaxCollateralUsd();
        assertEq(arr[0], 15_000e8);
        assertEq(arr[1], 100_000e8);
        assertEq(arr[2], 300_000e8);
        assertEq(arr[3], type(uint256).max);
    }

    // ─── D1/D4: canonical-route registry ───────────────────────

    function test_setCanonicalRoute_storesData() public {
        address router = makeAddr("router");
        address tokenIn = makeAddr("in");
        address tokenOut = makeAddr("out");
        bytes memory data = abi.encode(uint24(500));

        vm.prank(timelock);
        core.setCanonicalRoute(router, tokenIn, tokenOut, data);

        (bool set, bytes memory stored) = core.getCanonicalRoute(router, tokenIn, tokenOut);
        assertTrue(set);
        assertEq(stored, data);
    }

    function test_setCanonicalRoute_emitsEvent() public {
        address router = makeAddr("router");
        address tokenIn = makeAddr("in");
        address tokenOut = makeAddr("out");
        bytes memory data = abi.encode(uint24(500));

        vm.expectEmit(true, true, true, true, address(core));
        emit SepehrEvents.CanonicalRouteSet(router, tokenIn, tokenOut, data);

        vm.prank(timelock);
        core.setCanonicalRoute(router, tokenIn, tokenOut, data);
    }

    function test_setCanonicalRoute_revertsFromNonTimelock() public {
        vm.expectRevert(SepehrErrors.NotTimelock.selector);
        core.setCanonicalRoute(makeAddr("r"), makeAddr("i"), makeAddr("o"), "");
    }

    function test_setCanonicalRoute_revertsOnZeroAddress() public {
        vm.startPrank(timelock);
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        core.setCanonicalRoute(address(0), makeAddr("i"), makeAddr("o"), "");
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        core.setCanonicalRoute(makeAddr("r"), address(0), makeAddr("o"), "");
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        core.setCanonicalRoute(makeAddr("r"), makeAddr("i"), address(0), "");
        vm.stopPrank();
    }

    function test_setCanonicalRoute_revertsOnSameToken() public {
        address tok = makeAddr("tok");
        vm.prank(timelock);
        vm.expectRevert(SepehrErrors.SameToken.selector);
        core.setCanonicalRoute(makeAddr("r"), tok, tok, "");
    }

    function test_clearCanonicalRoute_clearsData() public {
        address router = makeAddr("router");
        address tokenIn = makeAddr("in");
        address tokenOut = makeAddr("out");

        vm.startPrank(timelock);
        core.setCanonicalRoute(router, tokenIn, tokenOut, abi.encode(uint24(500)));
        core.clearCanonicalRoute(router, tokenIn, tokenOut);
        vm.stopPrank();

        (bool set,) = core.getCanonicalRoute(router, tokenIn, tokenOut);
        assertFalse(set);
    }

    function test_clearCanonicalRoute_emitsEvent() public {
        address router = makeAddr("router");
        address tokenIn = makeAddr("in");
        address tokenOut = makeAddr("out");

        vm.expectEmit(true, true, true, true, address(core));
        emit SepehrEvents.CanonicalRouteCleared(router, tokenIn, tokenOut);

        vm.prank(timelock);
        core.clearCanonicalRoute(router, tokenIn, tokenOut);
    }

    function test_clearCanonicalRoute_revertsFromNonTimelock() public {
        vm.expectRevert(SepehrErrors.NotTimelock.selector);
        core.clearCanonicalRoute(makeAddr("r"), makeAddr("i"), makeAddr("o"));
    }

    /// @dev M3: freezes the deploy-time default. Flipping this to `true` at construction
    /// would brick every trigger until the canonical-route registry is seeded, so the
    /// deploy script also `require`s this is off post-deploy.
    function test_strictCanonicalRoutes_defaultIsOff() public view {
        assertFalse(core.strictCanonicalRoutes());
    }

    function test_setStrictCanonicalRoutes_togglesFlag() public {
        assertFalse(core.strictCanonicalRoutes());

        vm.prank(timelock);
        core.setStrictCanonicalRoutes(true);
        assertTrue(core.strictCanonicalRoutes());

        vm.prank(timelock);
        core.setStrictCanonicalRoutes(false);
        assertFalse(core.strictCanonicalRoutes());
    }

    function test_setStrictCanonicalRoutes_emitsEvent() public {
        vm.expectEmit(false, false, false, true, address(core));
        emit SepehrEvents.StrictCanonicalRoutesUpdated(true);

        vm.prank(timelock);
        core.setStrictCanonicalRoutes(true);
    }

    function test_setStrictCanonicalRoutes_revertsFromNonTimelock() public {
        vm.expectRevert(SepehrErrors.NotTimelock.selector);
        core.setStrictCanonicalRoutes(true);
    }

    function test_canonicalRoute_keyDirectionSensitive() public {
        address router = makeAddr("router");
        address a = makeAddr("a");
        address b = makeAddr("b");
        bytes memory data = abi.encode(uint24(500));

        vm.prank(timelock);
        core.setCanonicalRoute(router, a, b, data);

        // Setting (a, b) should not populate (b, a).
        (bool setAB,) = core.getCanonicalRoute(router, a, b);
        (bool setBA,) = core.getCanonicalRoute(router, b, a);
        assertTrue(setAB);
        assertFalse(setBA);
    }

    // ─── D2: asset oracle registry ──────────────────────────────

    function test_setAssetOracle_storesAggregatorAndStaleness() public {
        address asset = makeAddr("asset");
        MockChainlinkAggregator agg = new MockChainlinkAggregator(8, 1e8);

        vm.prank(timelock);
        core.setAssetOracle(asset, address(agg), 1 hours);

        (address storedAgg, uint256 storedStale) = _readAssetOracle(asset);
        assertEq(storedAgg, address(agg));
        assertEq(storedStale, 1 hours);
    }

    function test_setAssetOracle_emitsEvent() public {
        address asset = makeAddr("asset");
        MockChainlinkAggregator agg = new MockChainlinkAggregator(8, 1e8);

        vm.expectEmit(true, true, false, true, address(core));
        emit SepehrEvents.AssetOracleSet(asset, address(agg), 30 minutes);

        vm.prank(timelock);
        core.setAssetOracle(asset, address(agg), 30 minutes);
    }

    function test_setAssetOracle_revertsFromNonTimelock() public {
        MockChainlinkAggregator agg = new MockChainlinkAggregator(8, 1e8);
        vm.expectRevert(SepehrErrors.NotTimelock.selector);
        core.setAssetOracle(makeAddr("asset"), address(agg), 1 hours);
    }

    function test_setAssetOracle_revertsOnZeroAsset() public {
        MockChainlinkAggregator agg = new MockChainlinkAggregator(8, 1e8);
        vm.prank(timelock);
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        core.setAssetOracle(address(0), address(agg), 1 hours);
    }

    function test_setAssetOracle_revertsOnZeroAggregator() public {
        vm.prank(timelock);
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        core.setAssetOracle(makeAddr("asset"), address(0), 1 hours);
    }

    function test_setAssetOracle_revertsOnZeroStaleness() public {
        MockChainlinkAggregator agg = new MockChainlinkAggregator(8, 1e8);
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.InvalidOracleStaleness.selector, uint256(0)));
        core.setAssetOracle(makeAddr("asset"), address(agg), 0);
    }

    function test_setAssetOracle_revertsWhenStalenessAboveCap() public {
        MockChainlinkAggregator agg = new MockChainlinkAggregator(8, 1e8);
        uint256 tooStale = core.MAX_ORACLE_STALENESS() + 1;
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.InvalidOracleStaleness.selector, tooStale));
        core.setAssetOracle(makeAddr("asset"), address(agg), tooStale);
    }

    function test_setAssetOracle_revertsOnWrongDecimals() public {
        MockChainlinkAggregator agg = new MockChainlinkAggregator(18, 1e18);
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.InvalidOracleDecimals.selector, uint8(18), uint8(8)));
        core.setAssetOracle(makeAddr("asset"), address(agg), 1 hours);
    }

    function test_clearAssetOracle_removesEntry() public {
        address asset = makeAddr("asset");
        MockChainlinkAggregator agg = new MockChainlinkAggregator(8, 1e8);

        vm.prank(timelock);
        core.setAssetOracle(asset, address(agg), 1 hours);

        vm.prank(timelock);
        core.clearAssetOracle(asset);

        (address storedAgg, uint256 storedStale) = _readAssetOracle(asset);
        assertEq(storedAgg, address(0));
        assertEq(storedStale, 0);
    }

    function test_clearAssetOracle_emitsEvent() public {
        address asset = makeAddr("asset");
        vm.expectEmit(true, false, false, true, address(core));
        emit SepehrEvents.AssetOracleCleared(asset);
        vm.prank(timelock);
        core.clearAssetOracle(asset);
    }

    function test_clearAssetOracle_revertsFromNonTimelock() public {
        vm.expectRevert(SepehrErrors.NotTimelock.selector);
        core.clearAssetOracle(makeAddr("asset"));
    }

    function test_setStrictOraclePricing_togglesFlag() public {
        assertFalse(core.strictOraclePricing());
        vm.prank(timelock);
        core.setStrictOraclePricing(true);
        assertTrue(core.strictOraclePricing());
        vm.prank(timelock);
        core.setStrictOraclePricing(false);
        assertFalse(core.strictOraclePricing());
    }

    function test_setStrictOraclePricing_emitsEvent() public {
        vm.expectEmit(false, false, false, true, address(core));
        emit SepehrEvents.StrictOraclePricingUpdated(true);
        vm.prank(timelock);
        core.setStrictOraclePricing(true);
    }

    function test_setStrictOraclePricing_revertsFromNonTimelock() public {
        vm.expectRevert(SepehrErrors.NotTimelock.selector);
        core.setStrictOraclePricing(true);
    }

    // ─── C2: renounceOwnership must be disabled ───────────────────────

    /// @dev C2: allowing `renounceOwnership` would permanently disable fee withdrawal,
    /// adapter registration, and every timelock-gated mutation — the override must revert
    /// regardless of caller identity.
    function test_renounceOwnership_revertsFromOwner() public {
        vm.expectRevert(SepehrErrors.OwnershipCannotBeRenounced.selector);
        core.renounceOwnership();
    }

    function test_renounceOwnership_revertsFromNonOwner() public {
        // Ownable gates `renounceOwnership` to the owner; the override runs first on any
        // call path (it's `public pure`), so a non-owner also sees our custom error.
        vm.prank(makeAddr("random"));
        vm.expectRevert(SepehrErrors.OwnershipCannotBeRenounced.selector);
        core.renounceOwnership();
    }

    function _readAssetOracle(
        address asset
    ) internal view returns (address agg, uint256 stale) {
        (agg, stale) = _callAssetOracles(asset);
    }

    function _callAssetOracles(
        address asset
    ) internal view returns (address agg, uint256 stale) {
        (bool ok, bytes memory ret) = address(core).staticcall(abi.encodeWithSignature("assetOracles(address)", asset));
        require(ok, "assetOracles call failed");
        (agg, stale) = abi.decode(ret, (address, uint256));
    }
}
