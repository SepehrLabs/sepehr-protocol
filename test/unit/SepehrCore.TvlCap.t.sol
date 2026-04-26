// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {SepehrCore} from "../../src/SepehrCore.sol";
import {SepehrErrors} from "../../src/libraries/SepehrErrors.sol";
import {SepehrEvents} from "../../src/libraries/SepehrEvents.sol";
import {MockAdapter} from "../../src/mocks/MockAdapter.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @notice G4: protocol-wide TVL cap (sum of snapshotted collateral USD-8) gates
/// `enableProtection` against unbounded protocol exposure. Lowering the cap below
/// the running total never disables already-enabled positions; the running total is
/// decremented by the snapshot taken at enable time, so price drift between enable
/// and disable cannot underflow the running total.
contract SepehrCoreTvlCapTest is Test {
    SepehrCore public core;
    MockAdapter public adapter;
    MockERC20 public usdc;

    address public timelock = makeAddr("timelock");
    address public guardian = makeAddr("guardian");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    bytes32 public constant PROTOCOL_KEY_AAVE = keccak256("AAVE_V3");
    bytes32 public constant PROTOCOL_KEY_MORPHO = keccak256("MORPHO_BLUE");
    uint256 public constant THRESHOLD_HF = 1.3e18;
    uint256 public constant SLIPPAGE_BPS = 250;
    uint256 public constant REPAY_BPS = 2500;

    /// @dev V1 launch cap is $75k expressed in USD-8; chosen to mirror the deploy
    /// script default so the unit tests assert the same boundary the production
    /// configuration will hit on day one.
    uint256 public constant TVL_CAP_75K_USD8 = 7_500_000_000_000;

    function setUp() public {
        vm.warp(10_000);

        adapter = new MockAdapter();
        usdc = new MockERC20("USD Coin", "USDC");

        core = new SepehrCore(address(this), timelock, guardian, address(usdc), 0, TVL_CAP_75K_USD8, block.chainid);

        vm.prank(timelock);
        core.addAdapter(PROTOCOL_KEY_AAVE, address(adapter));
        vm.prank(timelock);
        core.addAdapter(PROTOCOL_KEY_MORPHO, address(adapter));

        usdc.mint(alice, 1000e6);
        usdc.mint(bob, 1000e6);
        vm.prank(alice);
        usdc.approve(address(core), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(core), type(uint256).max);

        vm.prank(alice);
        core.subscribe(1, false);
        vm.prank(bob);
        core.subscribe(1, false);

        adapter.setDelegation(alice, true);
        adapter.setDelegation(bob, true);
    }

    // ─── Constructor / Setter ────────────────────────────────────

    function test_constructor_setsTvlCapUsd() public view {
        assertEq(core.tvlCapUsd(), TVL_CAP_75K_USD8);
        assertEq(core.protectedCollateralUsd(), 0);
    }

    function test_setTvlCapUsd_revertsWhenNotTimelock() public {
        vm.expectRevert(SepehrErrors.NotTimelock.selector);
        vm.prank(alice);
        core.setTvlCapUsd(1000e8);
    }

    function test_setTvlCapUsd_emitsEventAndUpdatesValue() public {
        vm.expectEmit(false, false, false, true);
        emit SepehrEvents.TvlCapUpdated(TVL_CAP_75K_USD8, 1000e8);
        vm.prank(timelock);
        core.setTvlCapUsd(1000e8);
        assertEq(core.tvlCapUsd(), 1000e8);
    }

    /// @dev Lowering the cap below the running total must not retroactively disable any
    /// existing position — only future `enableProtection` calls are gated. This is the
    /// invariant that lets governance tighten the cap safely without bricking users.
    function test_setTvlCapUsd_belowRunningTotal_doesNotDisableExistingPositions() public {
        adapter.setCollateralValueUsd(alice, 50_000e8);
        vm.prank(alice);
        core.enableProtection(PROTOCOL_KEY_AAVE, THRESHOLD_HF, SLIPPAGE_BPS, REPAY_BPS);
        assertEq(core.protectedCollateralUsd(), 50_000e8);

        vm.prank(timelock);
        core.setTvlCapUsd(10_000e8); // far below the 50k currently protected

        // The position remains active; protectedCollateralUsd is unchanged.
        assertEq(core.protectedCollateralUsd(), 50_000e8);
        assertTrue(core.getProtection(alice, PROTOCOL_KEY_AAVE).enabled);
    }

    // ─── enableProtection: cap accounting ───────────────────────

    function test_enableProtection_belowCap_incrementsRunningTotal() public {
        adapter.setCollateralValueUsd(alice, 30_000e8);

        vm.prank(alice);
        core.enableProtection(PROTOCOL_KEY_AAVE, THRESHOLD_HF, SLIPPAGE_BPS, REPAY_BPS);

        assertEq(core.protectedCollateralUsd(), 30_000e8);
        assertEq(core.protectionCollateralSnapshot(alice, PROTOCOL_KEY_AAVE), 30_000e8);
    }

    function test_enableProtection_atExactlyCap_isAllowed() public {
        adapter.setCollateralValueUsd(alice, TVL_CAP_75K_USD8);
        vm.prank(alice);
        core.enableProtection(PROTOCOL_KEY_AAVE, THRESHOLD_HF, SLIPPAGE_BPS, REPAY_BPS);
        assertEq(core.protectedCollateralUsd(), TVL_CAP_75K_USD8);
    }

    function test_enableProtection_oneWeiAboveCap_reverts() public {
        adapter.setCollateralValueUsd(alice, TVL_CAP_75K_USD8 + 1);

        vm.expectRevert(
            abi.encodeWithSelector(SepehrErrors.TvlCapExceeded.selector, TVL_CAP_75K_USD8 + 1, TVL_CAP_75K_USD8)
        );
        vm.prank(alice);
        core.enableProtection(PROTOCOL_KEY_AAVE, THRESHOLD_HF, SLIPPAGE_BPS, REPAY_BPS);
    }

    /// @dev Two enable calls that individually fit the cap but together exceed it: the
    /// second call must revert because the cap is enforced against the *running total*,
    /// not the per-position size.
    function test_enableProtection_secondPositionExceedsCap_reverts() public {
        adapter.setCollateralValueUsd(alice, 60_000e8);
        vm.prank(alice);
        core.enableProtection(PROTOCOL_KEY_AAVE, THRESHOLD_HF, SLIPPAGE_BPS, REPAY_BPS);

        adapter.setCollateralValueUsd(bob, 20_000e8);
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.TvlCapExceeded.selector, 80_000e8, TVL_CAP_75K_USD8));
        vm.prank(bob);
        core.enableProtection(PROTOCOL_KEY_AAVE, THRESHOLD_HF, SLIPPAGE_BPS, REPAY_BPS);

        assertEq(core.protectedCollateralUsd(), 60_000e8);
    }

    function test_enableProtection_capDisabled_byMaxUint_neverReverts() public {
        vm.prank(timelock);
        core.setTvlCapUsd(type(uint256).max);

        adapter.setCollateralValueUsd(alice, 1_000_000_000e8); // absurd value
        vm.prank(alice);
        core.enableProtection(PROTOCOL_KEY_AAVE, THRESHOLD_HF, SLIPPAGE_BPS, REPAY_BPS);
        assertEq(core.protectedCollateralUsd(), 1_000_000_000e8);
    }

    /// @dev When the A7 floor is configured *and* the user's collateral is below it,
    /// the floor revert wins: the cap-accounting code path is skipped so no snapshot
    /// is recorded. Belt-and-braces — both gates use the same `getCollateralValueUsd`
    /// read so they cannot disagree on the value.
    function test_enableProtection_belowMinCollateral_revertsBeforeCapCheck() public {
        vm.prank(timelock);
        core.setMinCollateralUsd(1000e8);
        adapter.setCollateralValueUsd(alice, 500e8);

        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.BelowMinimumCollateral.selector, 500e8, 1000e8));
        vm.prank(alice);
        core.enableProtection(PROTOCOL_KEY_AAVE, THRESHOLD_HF, SLIPPAGE_BPS, REPAY_BPS);

        assertEq(core.protectedCollateralUsd(), 0);
        assertEq(core.protectionCollateralSnapshot(alice, PROTOCOL_KEY_AAVE), 0);
    }

    // ─── disableProtection: snapshot-based decrement ────────────

    function test_disableProtection_decrementsByOriginalSnapshot() public {
        adapter.setCollateralValueUsd(alice, 30_000e8);
        vm.prank(alice);
        core.enableProtection(PROTOCOL_KEY_AAVE, THRESHOLD_HF, SLIPPAGE_BPS, REPAY_BPS);

        // Live collateral value rallies after enable; the snapshot must be unaffected.
        adapter.setCollateralValueUsd(alice, 90_000e8);

        vm.prank(alice);
        core.disableProtection(PROTOCOL_KEY_AAVE);

        assertEq(core.protectedCollateralUsd(), 0);
        assertEq(core.protectionCollateralSnapshot(alice, PROTOCOL_KEY_AAVE), 0);
    }

    /// @dev Critical safety property: a price rally after enable must not be exploitable
    /// to over-decrement the running total below zero (which checked arithmetic would
    /// catch as a revert, bricking exit). Using the snapshot makes this impossible
    /// regardless of how the live `getCollateralValueUsd` value drifts.
    function test_disableProtection_neverUnderflows_evenIfPriceMovedAfterEnable() public {
        adapter.setCollateralValueUsd(alice, 30_000e8);
        vm.prank(alice);
        core.enableProtection(PROTOCOL_KEY_AAVE, THRESHOLD_HF, SLIPPAGE_BPS, REPAY_BPS);

        adapter.setCollateralValueUsd(bob, 20_000e8);
        vm.prank(bob);
        core.enableProtection(PROTOCOL_KEY_AAVE, THRESHOLD_HF, SLIPPAGE_BPS, REPAY_BPS);

        // Total = 50_000e8. Now alice's live value rallies; her snapshot is still 30k.
        adapter.setCollateralValueUsd(alice, 200_000e8);

        vm.prank(alice);
        core.disableProtection(PROTOCOL_KEY_AAVE);

        // 50_000 - 30_000 = 20_000 (bob's snapshot), not 50_000 - 200_000 (would underflow).
        assertEq(core.protectedCollateralUsd(), 20_000e8);
    }

    // ─── unsubscribe: aggregate decrement across all positions ──

    function test_unsubscribe_decrementsRunningTotalAcrossAllProtections() public {
        adapter.setCollateralValueUsd(alice, 25_000e8);
        vm.prank(alice);
        core.enableProtection(PROTOCOL_KEY_AAVE, THRESHOLD_HF, SLIPPAGE_BPS, REPAY_BPS);
        vm.prank(alice);
        core.enableProtection(PROTOCOL_KEY_MORPHO, THRESHOLD_HF, SLIPPAGE_BPS, REPAY_BPS);
        // Two positions × 25k each (the snapshot is taken from the live value at each
        // enable call; we did not change it between calls).
        assertEq(core.protectedCollateralUsd(), 50_000e8);

        vm.prank(alice);
        core.unsubscribe();

        assertEq(core.protectedCollateralUsd(), 0);
        assertEq(core.protectionCollateralSnapshot(alice, PROTOCOL_KEY_AAVE), 0);
        assertEq(core.protectionCollateralSnapshot(alice, PROTOCOL_KEY_MORPHO), 0);
    }

    /// @dev If a user enables and disables before unsubscribing, the snapshot is already
    /// cleared — `unsubscribe` must not double-decrement.
    function test_unsubscribe_doesNotDoubleDecrement_afterPartialDisable() public {
        adapter.setCollateralValueUsd(alice, 25_000e8);
        vm.prank(alice);
        core.enableProtection(PROTOCOL_KEY_AAVE, THRESHOLD_HF, SLIPPAGE_BPS, REPAY_BPS);
        vm.prank(alice);
        core.enableProtection(PROTOCOL_KEY_MORPHO, THRESHOLD_HF, SLIPPAGE_BPS, REPAY_BPS);
        assertEq(core.protectedCollateralUsd(), 50_000e8);

        vm.prank(alice);
        core.disableProtection(PROTOCOL_KEY_AAVE);
        assertEq(core.protectedCollateralUsd(), 25_000e8);

        vm.prank(alice);
        core.unsubscribe();
        assertEq(core.protectedCollateralUsd(), 0);
    }

    // ─── Re-enable after disable: snapshot uses the *new* live value ──

    function test_reEnableProtection_afterDisable_usesCurrentLiveCollateralValue() public {
        adapter.setCollateralValueUsd(alice, 30_000e8);
        vm.prank(alice);
        core.enableProtection(PROTOCOL_KEY_AAVE, THRESHOLD_HF, SLIPPAGE_BPS, REPAY_BPS);
        vm.prank(alice);
        core.disableProtection(PROTOCOL_KEY_AAVE);

        adapter.setCollateralValueUsd(alice, 40_000e8);
        vm.prank(alice);
        core.enableProtection(PROTOCOL_KEY_AAVE, THRESHOLD_HF, SLIPPAGE_BPS, REPAY_BPS);

        assertEq(core.protectedCollateralUsd(), 40_000e8);
        assertEq(core.protectionCollateralSnapshot(alice, PROTOCOL_KEY_AAVE), 40_000e8);
    }
}
