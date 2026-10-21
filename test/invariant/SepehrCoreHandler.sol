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

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract InvariantERC20 is ERC20 {
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

contract SepehrCoreHandler is Test {
    SepehrCore public core;
    SepehrSubscriptions public subs;
    InvariantERC20 public usdc;
    InvariantERC20 public weth;
    MockAdapter public adapter;
    MockFlashLoan public flashLoan;
    MockDex public dex;

    address public timelock;
    bytes32 public constant PROTOCOL_KEY = keccak256("aave-v3-eth");

    address[] public actors;
    mapping(address => bool) public isActor;
    uint256 public subscribeCalls;
    uint256 public unsubscribeCalls;
    uint256 public enableProtectionCalls;
    uint256 public disableProtectionCalls;
    uint256 public executeCalls;
    uint256 public executeReverts;
    uint256 public refreshCalls;
    /// @dev Ghost: each position's snapshot when it was last enabled, which a refresh may
    /// only lower (KupiaSec, 2026-10-20).
    mapping(address => uint256) public snapshotAtEnable;
    uint256 public releaseCalls;

    constructor(
        SepehrCore _core,
        InvariantERC20 _usdc,
        InvariantERC20 _weth,
        MockAdapter _adapter,
        MockFlashLoan _flashLoan,
        MockDex _dex,
        address _timelock
    ) {
        core = _core;
        subs = SepehrSubscriptions(address(_core.subscriptions()));
        usdc = _usdc;
        weth = _weth;
        adapter = _adapter;
        flashLoan = _flashLoan;
        dex = _dex;
        timelock = _timelock;

        for (uint256 i = 0; i < 5; i++) {
            address actor = address(uint160(0x1000 + i));
            actors.push(actor);
            isActor[actor] = true;
            usdc.mint(actor, 10_000e6);
            vm.prank(actor);
            usdc.approve(address(subs), type(uint256).max);
        }
    }

    function _getActor(
        uint256 seed
    ) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function subscribe(
        uint256 actorSeed,
        uint8 tier,
        bool annual
    ) external {
        address actor = _getActor(actorSeed);
        tier = uint8(bound(tier, 1, 3));

        ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(actor);
        if (sub.expiresAt > block.timestamp) return;

        vm.prank(actor);
        try subs.subscribe(tier, annual) {
            subscribeCalls++;
        } catch {}
    }

    function unsubscribe(
        uint256 actorSeed
    ) external {
        address actor = _getActor(actorSeed);

        ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(actor);
        if (sub.tier == 0) return;

        vm.prank(actor);
        try subs.unsubscribe() {
            unsubscribeCalls++;
        } catch {}
    }

    /// @dev M-1: a renewal settles what was earned and carries the rest into a new window.
    function renew(
        uint256 actorSeed
    ) external {
        address actor = _getActor(actorSeed);
        uint8 tier = subs.getSubscription(actor).tier;
        if (tier == 0 || tier == 4) return;
        vm.prank(actor);
        try subs.renew() {} catch {}
    }

    /// @dev A12: a tier change credits the unused part of what was paid.
    function upgradeTier(
        uint256 actorSeed,
        uint8 tier,
        bool annual
    ) external {
        address actor = _getActor(actorSeed);
        vm.prank(actor);
        try subs.upgradeTier(uint8(bound(tier, 1, 3)), annual) {} catch {}
    }

    /// @dev M-1: anyone settles, and the owner withdraws what was settled.
    function settleAndWithdraw(
        uint256 actorSeed,
        bool withdraw
    ) external {
        address[] memory one = new address[](1);
        one[0] = _getActor(actorSeed);
        subs.settle(one);
        if (withdraw && subs.ownerRevenue() > 0) {
            vm.prank(subs.owner());
            subs.withdrawRevenue();
        }
    }

    function enableProtection(
        uint256 actorSeed,
        uint256 thresholdHF,
        uint256 slippageBps,
        uint256 targetHF
    ) external {
        address actor = _getActor(actorSeed);
        thresholdHF = bound(thresholdHF, 1.2e18, 5e18);
        slippageBps = bound(slippageBps, 0, 2000);
        // Spans invalid targets too (below threshold + gap, above the maximum): the core must
        // refuse them, which invariant_protectionParamsBounded checks.
        targetHF = bound(targetHF, 1e18, 3e18);

        ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(actor);
        if (sub.tier == 0 || sub.expiresAt <= block.timestamp) return;

        ISepehrCore.PositionProtection memory prot = core.getProtection(actor, PROTOCOL_KEY);
        if (prot.enabled) return;

        adapter.setDelegation(actor, true);

        vm.prank(actor);
        try core.enableProtection(PROTOCOL_KEY, thresholdHF, slippageBps, targetHF) {
            enableProtectionCalls++;
            snapshotAtEnable[actor] = core.protectionCollateralSnapshot(actor, PROTOCOL_KEY);
        } catch {}
    }

    /// @dev The fuzzed `enableProtection` above mostly sends parameters the core refuses, so it
    /// almost never enables a position: this one enables with a valid rule and collateral within
    /// the plan's cap, so the TVL invariants see real snapshots.
    function enableValidProtection(
        uint256 actorSeed,
        uint256 collateralUsd
    ) external {
        address actor = _getActor(actorSeed);
        ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(actor);
        if (sub.tier == 0 || sub.expiresAt <= block.timestamp) return;
        if (core.getProtection(actor, PROTOCOL_KEY).enabled) return;

        adapter.setCollateralValueUsd(actor, bound(collateralUsd, 500e8, 15_000e8));
        adapter.setDelegation(actor, true);

        vm.prank(actor);
        try core.enableProtection(PROTOCOL_KEY, 1.2e18, 100, 1.35e18) {
            enableProtectionCalls++;
            snapshotAtEnable[actor] = core.protectionCollateralSnapshot(actor, PROTOCOL_KEY);
        } catch {}
    }

    function disableProtection(
        uint256 actorSeed
    ) external {
        address actor = _getActor(actorSeed);

        ISepehrCore.PositionProtection memory prot = core.getProtection(actor, PROTOCOL_KEY);
        if (!prot.enabled) return;

        vm.prank(actor);
        try core.disableProtection(PROTOCOL_KEY) {
            disableProtectionCalls++;
        } catch {}
    }

    /// @dev Moves an actor's collateral so enables clear the $500 floor and snapshots drift.
    function setCollateral(
        uint256 actorSeed,
        uint256 valueUsd
    ) external {
        adapter.setCollateralValueUsd(_getActor(actorSeed), bound(valueUsd, 0, 400_000e8));
    }

    /// @dev M-2: anyone re-reads a position's snapshot.
    function refreshSnapshot(
        uint256 actorSeed,
        uint256 callerSeed
    ) external {
        address actor = _getActor(actorSeed);
        if (!core.getProtection(actor, PROTOCOL_KEY).enabled) return;

        vm.prank(_getActor(callerSeed));
        try core.refreshCollateralSnapshot(actor, PROTOCOL_KEY) {
            refreshCalls++;
        } catch {}
    }

    /// @dev KupiaSec (2026-10-20): a deposit borrowed for one transaction around a refresh of
    /// the subscriber's own snapshot, then withdrawn.
    function inflateAndRefresh(
        uint256 actorSeed,
        uint256 extraUsd
    ) external {
        address actor = _getActor(actorSeed);
        if (!core.getProtection(actor, PROTOCOL_KEY).enabled) return;

        uint256 value = adapter.getCollateralValueUsd(actor);
        adapter.setCollateralValueUsd(actor, value + bound(extraUsd, 1, 10_000_000e8));
        vm.prank(actor);
        try core.refreshCollateralSnapshot(actor, PROTOCOL_KEY) {
            refreshCalls++;
        } catch {}
        adapter.setCollateralValueUsd(actor, value);
    }

    /// @dev M-2: anyone releases an expired subscription's protections.
    function releaseExpired(
        uint256 actorSeed,
        uint256 callerSeed
    ) external {
        address actor = _getActor(actorSeed);
        if (subs.getSubscription(actor).expiresAt > block.timestamp) return;

        vm.prank(_getActor(callerSeed));
        try core.releaseExpiredProtections(actor) {
            releaseCalls++;
        } catch {}
    }

    function warpTime(
        uint256 seconds_
    ) external {
        seconds_ = bound(seconds_, 1, 60 days);
        vm.warp(block.timestamp + seconds_);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}
