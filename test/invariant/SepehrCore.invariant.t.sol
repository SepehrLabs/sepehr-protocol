// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {SepehrCore} from "../../src/SepehrCore.sol";
import {SepehrSubscriptions} from "../../src/SepehrSubscriptions.sol";
import {ISepehrCore} from "../../src/interfaces/ISepehrCore.sol";
import {ISepehrSubscriptions} from "../../src/interfaces/ISepehrSubscriptions.sol";
import {MockAdapter} from "../../src/mocks/MockAdapter.sol";
import {MockDex} from "../../src/mocks/MockDex.sol";
import {MockFlashLoan} from "../../src/mocks/MockFlashLoan.sol";
import {SepehrStack} from "../helpers/SepehrStack.sol";
import {InvariantERC20, SepehrCoreHandler} from "./SepehrCoreHandler.sol";

contract SepehrCoreInvariantTest is SepehrStack {
    SepehrCore public core;
    SepehrSubscriptions public subs;
    InvariantERC20 public usdc;
    InvariantERC20 public weth;
    MockAdapter public adapter;
    MockFlashLoan public flashLoan;
    MockDex public dex;
    SepehrCoreHandler public handler;

    address public owner = address(this);
    address public timelock = makeAddr("timelock");
    address public guardian = makeAddr("guardian");
    address public keeper = makeAddr("keeper");

    bytes32 public constant PROTOCOL_KEY = keccak256("aave-v3-eth");

    function setUp() public {
        usdc = new InvariantERC20("USD Coin", "USDC");
        weth = new InvariantERC20("Wrapped Ether", "WETH");
        adapter = new MockAdapter();
        flashLoan = new MockFlashLoan();
        dex = new MockDex();

        (core, subs) = _deployStack(owner, timelock, guardian, address(usdc), 500e8, type(uint256).max);

        vm.startPrank(timelock);
        core.addAdapter(PROTOCOL_KEY, address(adapter));
        core.addKeeper(keeper);
        core.addFlashLoanProvider(address(flashLoan));
        core.addDexRouter(address(dex));
        vm.stopPrank();

        handler = new SepehrCoreHandler(core, usdc, weth, adapter, flashLoan, dex, timelock);

        targetContract(address(handler));
    }

    // ── Invariant 1: Subscription tier is always 0 or 1-4 ──────────

    function invariant_subscriptionTierBounded() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actors(i);
            ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(actor);
            assertTrue(sub.tier <= 4, "tier must be 0-4");
        }
    }

    // ── Invariant 2: tier==0 implies expiresAt==0 and vice versa ───

    function invariant_zeroTierImpliesZeroExpiry() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actors(i);
            ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(actor);
            if (sub.tier == 0) {
                assertEq(sub.expiresAt, 0, "tier 0 must have expiresAt 0");
            }
            if (sub.expiresAt == 0) {
                assertEq(sub.tier, 0, "expiresAt 0 must have tier 0");
            }
        }
    }

    // ── Invariant 3: Protection params are always within bounds ─────

    function invariant_protectionParamsBounded() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actors(i);
            ISepehrCore.PositionProtection memory prot = core.getProtection(actor, PROTOCOL_KEY);
            if (!prot.enabled) continue;
            assertGe(prot.thresholdHF, core.MIN_HF_THRESHOLD(), "threshold below minimum");
            assertLe(prot.maxSlippageBps, core.MAX_SLIPPAGE_BPS(), "slippage above maximum");
            assertGe(prot.targetHF, prot.thresholdHF + core.MIN_TARGET_GAP(), "target too close to threshold");
            assertLe(prot.targetHF, core.MAX_TARGET_HF(), "target above maximum");
        }
    }

    // ── Invariant 4: Active subscription has valid tier ────────────

    function invariant_activeSubscriptionHasValidTier() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actors(i);
            ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(actor);
            if (sub.expiresAt > block.timestamp) {
                assertTrue(sub.tier >= 1 && sub.tier <= 4, "active sub must have tier 1-4");
            }
        }
    }

    // ── Invariant 5: Tier fee BPS unchanged without timelock ───────

    function invariant_tierFeeBpsUnchanged() public view {
        assertEq(subs.TIER_FEE_BPS(0), 20, "Shield fee should remain 20 bps");
        assertEq(subs.TIER_FEE_BPS(1), 15, "Guardian fee should remain 15 bps");
        assertEq(subs.TIER_FEE_BPS(2), 10, "Watchtower fee should remain 10 bps");
        assertEq(subs.TIER_FEE_BPS(3), 10, "Titan fee should remain 10 bps");
    }

    // ── Invariant 6: Adapter remains registered ─────────────────────

    function invariant_adapterRegistered() public view {
        (,, uint256 addedAt) = core.adapters(PROTOCOL_KEY);
        assertGt(addedAt, 0, "adapter should remain registered");
    }

    // ── Invariant 7: Keeper remains registered ────────────────────

    function invariant_keeperRegistered() public view {
        assertTrue(core.isKeeper(keeper), "keeper should remain registered");
    }

    // ── Invariant 8: Pause state is consistent ──────────────────────

    function invariant_pauseStateConsistent() public view {
        assertFalse(core.paused(), "handler never pauses");
    }

    // ── Invariant 9 (A25/E3): USDC treasury never under-funds fee ledger ─
    //
    // The central A1 + A2 accounting bug from the audit — where subscription
    // USDC was permanently locked because `ownerFeeBalances[usdc]` was never
    // credited — would manifest as `usdc.balanceOf(core) < ownerFeeBalances[usdc]`
    // (after a full withdrawal the treasury would go negative). This invariant
    // formalises the guarantee that the ledger is always fully backed and would
    // have caught A1/A2 during fuzzing.
    //
    // The handler never invokes `execute`, so keeper fees are not accrued here;
    // we still read `keeperFeeBalances[keeper][usdc]` to keep the check complete
    // if future handler actions add trigger simulation.
    function invariant_usdcTreasuryCoversFeeLedger() public view {
        uint256 ledger = core.ownerFeeBalances(address(usdc)) + core.keeperFeeBalances(keeper, address(usdc));
        assertGe(usdc.balanceOf(address(core)), ledger, "USDC treasury under-funded");
    }

    // ── M-1: the plans' USDC is the settled revenue plus every unsettled prepayment ──

    function invariant_subscriptionsTreasuryIsRevenuePlusUnsettledPrepayments() public view {
        uint256 unsettled;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            (uint256 paid,, uint256 settled) = subs.subscriptionPayments(handler.actors(i));
            unsettled += paid - settled;
        }
        assertEq(usdc.balanceOf(address(subs)), subs.ownerRevenue() + unsettled, "plans treasury mismatch");
    }

    // ── M-2: the TVL running total is the sum of the position snapshots ──

    function invariant_protectedCollateralIsTheSumOfSnapshots() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            sum += core.protectionCollateralSnapshot(handler.actors(i), PROTOCOL_KEY);
        }
        assertEq(core.protectedCollateralUsd(), sum);
    }
}
