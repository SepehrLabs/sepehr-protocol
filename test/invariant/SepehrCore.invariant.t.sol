// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {SepehrCore} from "../../src/SepehrCore.sol";
import {ISepehrCore} from "../../src/interfaces/ISepehrCore.sol";
import {MockAdapter} from "../../src/mocks/MockAdapter.sol";
import {MockDex} from "../../src/mocks/MockDex.sol";
import {MockFlashLoan} from "../../src/mocks/MockFlashLoan.sol";
import {MockOracle} from "../../src/mocks/MockOracle.sol";
import {SepehrCoreHandler, InvariantERC20} from "./SepehrCoreHandler.sol";

contract SepehrCoreInvariantTest is Test {
    SepehrCore public core;
    MockOracle public oracle;
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
        oracle = new MockOracle();
        usdc = new InvariantERC20("USD Coin", "USDC");
        weth = new InvariantERC20("Wrapped Ether", "WETH");
        adapter = new MockAdapter();
        flashLoan = new MockFlashLoan();
        dex = new MockDex();

        core = new SepehrCore(owner, timelock, guardian, address(oracle), 500e8, 30);

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
            ISepehrCore.Subscription memory sub = core.getSubscription(actor);
            assertTrue(sub.tier <= 4, "tier must be 0-4");
        }
    }

    // ── Invariant 2: tier==0 implies expiresAt==0 and vice versa ───

    function invariant_zeroTierImpliesZeroExpiry() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actors(i);
            ISepehrCore.Subscription memory sub = core.getSubscription(actor);
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
            assertLe(prot.repayPercentBps, core.MAX_REPAY_BPS(), "repay above maximum");
        }
    }

    // ── Invariant 4: Active subscription has valid tier ────────────

    function invariant_activeSubscriptionHasValidTier() public view {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actors(i);
            ISepehrCore.Subscription memory sub = core.getSubscription(actor);
            if (sub.expiresAt > block.timestamp) {
                assertTrue(sub.tier >= 1 && sub.tier <= 4, "active sub must have tier 1-4");
            }
        }
    }

    // ── Invariant 5: Fee BPS never changed without timelock ─────────

    function invariant_feeBpsIsSet() public view {
        assertEq(core.feeBps(), 30, "feeBps should remain 30 (only timelock can change)");
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
}
