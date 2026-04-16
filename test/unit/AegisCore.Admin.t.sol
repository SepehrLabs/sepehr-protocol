// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {AegisCore} from "../../src/AegisCore.sol";
import {IAegisCore} from "../../src/interfaces/IAegisCore.sol";
import {IProtocolAdapter} from "../../src/interfaces/IProtocolAdapter.sol";
import {AegisErrors} from "../../src/libraries/AegisErrors.sol";
import {AegisEvents} from "../../src/libraries/AegisEvents.sol";
import {MockAdapter} from "../../src/mocks/MockAdapter.sol";
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
}

contract AegisCoreAdminTest is Test {
    AegisCore public core;
    MockOracle public oracle;
    MockAdapter public adapter;

    address public timelock = makeAddr("timelock");
    address public guardian = makeAddr("guardian");
    address public owner;

    bytes32 public constant PROTOCOL_KEY = keccak256("AAVE_V3");

    function setUp() public {
        owner = address(this);
        oracle = new MockOracle();
        adapter = new MockAdapter();

        core = new AegisCore(owner, timelock, guardian, address(oracle), 500e8, 30);
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
        emit AegisEvents.AdapterAdded(PROTOCOL_KEY, address(adapter));

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
        vm.expectRevert(AegisErrors.NotTimelock.selector);
        core.addAdapter(PROTOCOL_KEY, address(adapter));
    }

    function test_addAdapter_revertsFromGuardian() public {
        vm.expectRevert(AegisErrors.NotTimelock.selector);
        vm.prank(guardian);
        core.addAdapter(PROTOCOL_KEY, address(adapter));
    }

    function test_addAdapter_revertsOnZeroAddress() public {
        vm.expectRevert(AegisErrors.ZeroAddress.selector);
        vm.prank(timelock);
        core.addAdapter(PROTOCOL_KEY, address(0));
    }

    function test_addAdapter_revertsWhenAlreadyRegistered() public {
        vm.prank(timelock);
        core.addAdapter(PROTOCOL_KEY, address(adapter));

        MockAdapter adapter2 = new MockAdapter();
        vm.expectRevert(abi.encodeWithSelector(AegisErrors.AdapterAlreadyRegistered.selector, PROTOCOL_KEY));
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
        emit AegisEvents.AdapterRemoved(PROTOCOL_KEY);

        vm.prank(timelock);
        core.removeAdapter(PROTOCOL_KEY);
    }

    function test_removeAdapter_revertsOnNonTimelock() public {
        vm.prank(timelock);
        core.addAdapter(PROTOCOL_KEY, address(adapter));

        vm.expectRevert(AegisErrors.NotTimelock.selector);
        core.removeAdapter(PROTOCOL_KEY);
    }

    function test_removeAdapter_revertsWhenNotRegistered() public {
        bytes32 unknownKey = keccak256("UNKNOWN");
        vm.expectRevert(abi.encodeWithSelector(AegisErrors.AdapterNotRegistered.selector, unknownKey));
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
        emit AegisEvents.KeeperAdded(keeper);

        vm.prank(timelock);
        core.addKeeper(keeper);
    }

    function test_addKeeper_revertsOnNonTimelock() public {
        address keeper = makeAddr("keeper");

        vm.expectRevert(AegisErrors.NotTimelock.selector);
        core.addKeeper(keeper);
    }

    function test_addKeeper_revertsOnZeroAddress() public {
        vm.expectRevert(AegisErrors.ZeroAddress.selector);
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
        emit AegisEvents.KeeperRemoved(keeper);

        vm.prank(timelock);
        core.removeKeeper(keeper);
    }

    function test_removeKeeper_revertsOnNonTimelock() public {
        vm.expectRevert(AegisErrors.NotTimelock.selector);
        core.removeKeeper(makeAddr("keeper"));
    }

    // ─── setFeeBps ──────────────────────────────────────────────

    function test_setFeeBps() public {
        vm.prank(timelock);
        core.setFeeBps(50);

        assertEq(core.feeBps(), 50);
    }

    function test_setFeeBps_emitsEvent() public {
        vm.expectEmit(false, false, false, true, address(core));
        emit AegisEvents.FeeBpsUpdated(30, 50);

        vm.prank(timelock);
        core.setFeeBps(50);
    }

    function test_setFeeBps_revertsOnNonTimelock() public {
        vm.expectRevert(AegisErrors.NotTimelock.selector);
        core.setFeeBps(50);
    }

    function test_setFeeBps_canSetToZero() public {
        vm.prank(timelock);
        core.setFeeBps(0);

        assertEq(core.feeBps(), 0);
    }

    // ─── pause ──────────────────────────────────────────────────

    function test_pause_byGuardian() public {
        vm.prank(guardian);
        core.pause();

        assertTrue(core.paused());
    }

    function test_pause_byOwner() public {
        core.pause();

        assertTrue(core.paused());
    }

    function test_pause_emitsEvent_fromGuardian() public {
        vm.expectEmit(true, false, false, false, address(core));
        emit AegisEvents.EmergencyPaused(guardian);

        vm.prank(guardian);
        core.pause();
    }

    function test_pause_emitsEvent_fromOwner() public {
        vm.expectEmit(true, false, false, false, address(core));
        emit AegisEvents.EmergencyPaused(owner);

        core.pause();
    }

    function test_pause_revertsFromRandomAddress() public {
        address rando = makeAddr("rando");
        vm.expectRevert(AegisErrors.NotPauseGuardian.selector);
        vm.prank(rando);
        core.pause();
    }

    // ─── unpause ────────────────────────────────────────────────

    function test_unpause_byOwner() public {
        core.pause();
        assertTrue(core.paused());

        core.unpause();
        assertFalse(core.paused());
    }

    function test_unpause_emitsEvent() public {
        core.pause();

        vm.expectEmit(true, false, false, false, address(core));
        emit AegisEvents.Unpaused(owner);

        core.unpause();
    }

    function test_unpause_guardianCannotUnpause() public {
        core.pause();

        vm.expectRevert(AegisErrors.NotOwner.selector);
        vm.prank(guardian);
        core.unpause();
    }

    function test_unpause_revertsFromRandomAddress() public {
        core.pause();

        address rando = makeAddr("rando");
        vm.expectRevert(AegisErrors.NotOwner.selector);
        vm.prank(rando);
        core.unpause();
    }

    function test_unpause_revertsFromTimelock() public {
        core.pause();

        vm.expectRevert(AegisErrors.NotOwner.selector);
        vm.prank(timelock);
        core.unpause();
    }

    // ─── Non-timelock admin calls revert ────────────────────────

    function test_addFlashLoanProvider_revertsOnNonTimelock() public {
        vm.expectRevert(AegisErrors.NotTimelock.selector);
        core.addFlashLoanProvider(makeAddr("provider"));
    }

    function test_removeFlashLoanProvider_revertsOnNonTimelock() public {
        vm.expectRevert(AegisErrors.NotTimelock.selector);
        core.removeFlashLoanProvider(makeAddr("provider"));
    }

    function test_addDexRouter_revertsOnNonTimelock() public {
        vm.expectRevert(AegisErrors.NotTimelock.selector);
        core.addDexRouter(makeAddr("dex"));
    }

    function test_removeDexRouter_revertsOnNonTimelock() public {
        vm.expectRevert(AegisErrors.NotTimelock.selector);
        core.removeDexRouter(makeAddr("dex"));
    }

    function test_setAdapterEnabled_revertsOnNonTimelock() public {
        vm.prank(timelock);
        core.addAdapter(PROTOCOL_KEY, address(adapter));

        vm.expectRevert(AegisErrors.NotTimelock.selector);
        core.setAdapterEnabled(PROTOCOL_KEY, false);
    }

    function test_setPauseGuardian_revertsOnNonTimelock() public {
        vm.expectRevert(AegisErrors.NotTimelock.selector);
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
        emit AegisEvents.AdapterDisabled(PROTOCOL_KEY);

        vm.prank(timelock);
        core.setAdapterEnabled(PROTOCOL_KEY, false);
    }

    function test_setAdapterEnabled_emitsEnabledEvent() public {
        vm.prank(timelock);
        core.addAdapter(PROTOCOL_KEY, address(adapter));

        vm.prank(timelock);
        core.setAdapterEnabled(PROTOCOL_KEY, false);

        vm.expectEmit(true, false, false, false, address(core));
        emit AegisEvents.AdapterEnabled(PROTOCOL_KEY);

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
        emit AegisEvents.PauseGuardianUpdated(guardian, newGuardian);

        vm.prank(timelock);
        core.setPauseGuardian(newGuardian);
    }

    function test_setPauseGuardian_revertsOnZeroAddress() public {
        vm.expectRevert(AegisErrors.ZeroAddress.selector);
        vm.prank(timelock);
        core.setPauseGuardian(address(0));
    }

    // ─── Constructor validation ─────────────────────────────────

    function test_constructor_revertsOnZeroTimelock() public {
        vm.expectRevert(AegisErrors.ZeroAddress.selector);
        new AegisCore(owner, address(0), guardian, address(oracle), 500e8, 30);
    }

    function test_constructor_revertsOnZeroGuardian() public {
        vm.expectRevert(AegisErrors.ZeroAddress.selector);
        new AegisCore(owner, timelock, address(0), address(oracle), 500e8, 30);
    }

    function test_constructor_revertsOnZeroOracle() public {
        vm.expectRevert(AegisErrors.ZeroAddress.selector);
        new AegisCore(owner, timelock, guardian, address(0), 500e8, 30);
    }

    function test_constructor_setsInitialValues() public {
        assertEq(core.timelock(), timelock);
        assertEq(core.pauseGuardian(), guardian);
        assertEq(core.minCollateralUsd(), 500e8);
        assertEq(core.feeBps(), 30);
        assertEq(core.owner(), owner);
    }
}
