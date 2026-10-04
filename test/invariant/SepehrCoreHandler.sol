// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {SepehrCore} from "../../src/SepehrCore.sol";
import {ISepehrCore} from "../../src/interfaces/ISepehrCore.sol";
import {MockAdapter} from "../../src/mocks/MockAdapter.sol";
import {MockDex} from "../../src/mocks/MockDex.sol";
import {MockFlashLoan} from "../../src/mocks/MockFlashLoan.sol";

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
            usdc.approve(address(core), type(uint256).max);
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

        ISepehrCore.Subscription memory sub = core.getSubscription(actor);
        if (sub.expiresAt > block.timestamp) return;

        vm.prank(actor);
        try core.subscribe(tier, annual) {
            subscribeCalls++;
        } catch {}
    }

    function unsubscribe(
        uint256 actorSeed
    ) external {
        address actor = _getActor(actorSeed);

        ISepehrCore.Subscription memory sub = core.getSubscription(actor);
        if (sub.tier == 0) return;

        vm.prank(actor);
        try core.unsubscribe() {
            unsubscribeCalls++;
        } catch {}
    }

    function enableProtection(
        uint256 actorSeed,
        uint256 thresholdHF,
        uint256 slippageBps,
        uint256 repayBps
    ) external {
        address actor = _getActor(actorSeed);
        thresholdHF = bound(thresholdHF, 1.2e18, 5e18);
        slippageBps = bound(slippageBps, 0, 2000);
        repayBps = bound(repayBps, 1, 5000);

        ISepehrCore.Subscription memory sub = core.getSubscription(actor);
        if (sub.tier == 0 || sub.expiresAt <= block.timestamp) return;

        ISepehrCore.PositionProtection memory prot = core.getProtection(actor, PROTOCOL_KEY);
        if (prot.enabled) return;

        adapter.setDelegation(actor, true);

        vm.prank(actor);
        try core.enableProtection(PROTOCOL_KEY, thresholdHF, slippageBps, repayBps) {
            enableProtectionCalls++;
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

    /// @dev M-2: anyone releases an expired subscription's protections.
    function releaseExpired(
        uint256 actorSeed,
        uint256 callerSeed
    ) external {
        address actor = _getActor(actorSeed);
        if (core.getSubscription(actor).expiresAt > block.timestamp) return;

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
