// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {SepehrCore} from "../../src/SepehrCore.sol";
import {IProtocolAdapter} from "../../src/interfaces/IProtocolAdapter.sol";
import {ISepehrCore} from "../../src/interfaces/ISepehrCore.sol";
import {SepehrErrors} from "../../src/libraries/SepehrErrors.sol";
import {MockAdapter} from "../../src/mocks/MockAdapter.sol";

contract GuardMockERC20 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

/// @notice Verifies the `onlyExpectedChain` gate introduced with the V1 Arbitrum pivot.
/// ADR-0011: SepehrCore must be fully inert on any chain whose `block.chainid` differs from
/// the `expectedChainId` captured at deploy. The guard protects mutative functions AND the
/// user-state view getters (subscription, protection, keeper, save-credits, user-protocols);
/// pure-constant getters (`paused()`, `TIER_FEE_BPS(...)`) stay callable because they expose
/// no user-specific state.
contract SepehrCoreChainGuardTest is Test {
    SepehrCore internal core;
    GuardMockERC20 internal usdc;
    MockAdapter internal adapter;

    address internal owner;
    address internal timelock = makeAddr("timelock");
    address internal guardian = makeAddr("guardian");
    address internal user = makeAddr("user");
    address internal keeper = makeAddr("keeper");

    uint256 internal expectedChainId;
    uint256 internal wrongChainId;

    bytes32 internal constant PROTOCOL_KEY = keccak256("aave-v3-arb");

    function setUp() public {
        owner = address(this);
        usdc = new GuardMockERC20();
        adapter = new MockAdapter();

        expectedChainId = block.chainid;
        wrongChainId = expectedChainId == 1 ? 42_161 : 1;

        core = new SepehrCore(owner, timelock, guardian, address(usdc), 500e8, type(uint256).max, expectedChainId);

        vm.prank(timelock);
        core.addAdapter(PROTOCOL_KEY, address(adapter));
        vm.prank(timelock);
        core.addKeeper(keeper);
    }

    function _expectWrongChainRevert() internal {
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.WrongChain.selector, expectedChainId, wrongChainId));
    }

    // ─── Mutative entry-points ─────────────────────────────────────

    function test_subscribe_revertsOnWrongChain() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        vm.prank(user);
        core.subscribe(1, false);
    }

    function test_renew_revertsOnWrongChain() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        vm.prank(user);
        core.renew();
    }

    function test_upgradeTier_revertsOnWrongChain() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        vm.prank(user);
        core.upgradeTier(2, false);
    }

    function test_unsubscribe_revertsOnWrongChain() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        vm.prank(user);
        core.unsubscribe();
    }

    function test_enableProtection_revertsOnWrongChain() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        vm.prank(user);
        core.enableProtection(PROTOCOL_KEY, 1.5e18, 100, 5000);
    }

    function test_disableProtection_revertsOnWrongChain() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        vm.prank(user);
        core.disableProtection(PROTOCOL_KEY);
    }

    function test_updateProtection_revertsOnWrongChain() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        vm.prank(user);
        core.updateProtection(PROTOCOL_KEY, 1.5e18, 100, 5000);
    }

    function test_execute_revertsOnWrongChain() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        address[] memory flashProviders = new address[](0);
        vm.prank(keeper);
        core.execute(user, PROTOCOL_KEY, address(usdc), address(usdc), 0, flashProviders, address(0), bytes(""));
    }

    function test_pause_revertsOnWrongChain() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        vm.prank(guardian);
        core.pause();
    }

    function test_unpause_revertsOnWrongChain() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        core.unpause();
    }

    function test_grantTitanSubscription_revertsOnWrongChain() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        core.grantTitanSubscription(user, 30 days);
    }

    function test_withdrawOwnerFees_revertsOnWrongChain() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        core.withdrawOwnerFees(address(usdc));
    }

    function test_withdrawKeeperFees_revertsOnWrongChain() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        vm.prank(keeper);
        core.withdrawKeeperFees(address(usdc));
    }

    // ─── Timelock admin functions ──────────────────────────────────

    function test_addAdapter_revertsOnWrongChain() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        vm.prank(timelock);
        core.addAdapter(keccak256("new-key"), address(adapter));
    }

    function test_removeAdapter_revertsOnWrongChain() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        vm.prank(timelock);
        core.removeAdapter(PROTOCOL_KEY);
    }

    function test_addKeeper_revertsOnWrongChain() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        vm.prank(timelock);
        core.addKeeper(makeAddr("new-keeper"));
    }

    function test_setTierFeeBps_revertsOnWrongChain() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        vm.prank(timelock);
        core.setTierFeeBps(1, 50);
    }

    function test_setTvlCapUsd_revertsOnWrongChain() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        vm.prank(timelock);
        core.setTvlCapUsd(1_000_000_000_000);
    }

    function test_setPauseGuardian_revertsOnWrongChain() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        vm.prank(timelock);
        core.setPauseGuardian(makeAddr("new-guardian"));
    }

    // ─── User-state view getters ───────────────────────────────────

    function test_getSubscription_revertsOnWrongChain() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        core.getSubscription(user);
    }

    function test_getProtection_revertsOnWrongChain() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        core.getProtection(user, PROTOCOL_KEY);
    }

    function test_isKeeper_revertsOnWrongChain() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        core.isKeeper(keeper);
    }

    function test_getSaveCredits_revertsOnWrongChain() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        core.getSaveCredits(user);
    }

    function test_getUserProtocols_revertsOnWrongChain() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        core.getUserProtocols(user);
    }

    // ─── Pure-constant getters must stay callable ──────────────────

    function test_tierFeeBpsGetter_unaffectedByChainGuard() public {
        vm.chainId(wrongChainId);
        uint256 fee = core.TIER_FEE_BPS(0);
        assertEq(fee, 20, "TIER_FEE_BPS should remain queryable cross-chain");
    }

    function test_tierMaxCollateralGetter_unaffectedByChainGuard() public {
        vm.chainId(wrongChainId);
        uint256 cap = core.TIER_MAX_COLLATERAL_USD_8(0);
        assertEq(cap, 1_500_000_000_000, "Tier 1 cap should remain queryable cross-chain");
    }

    function test_paused_unaffectedByChainGuard() public {
        vm.chainId(wrongChainId);
        assertFalse(core.paused(), "paused() should remain queryable cross-chain");
    }

    function test_expectedChainIdGetter_unaffectedByChainGuard() public {
        vm.chainId(wrongChainId);
        assertEq(core.expectedChainId(), expectedChainId, "expectedChainId must remain queryable");
    }

    // ─── Restoring the chain re-enables the contract ───────────────

    function test_restoringChainId_reenablesMutations() public {
        vm.chainId(wrongChainId);
        _expectWrongChainRevert();
        vm.prank(user);
        core.getSubscription(user);

        vm.chainId(expectedChainId);
        ISepehrCore.Subscription memory sub = core.getSubscription(user);
        assertEq(sub.tier, 0, "default tier");
        assertEq(sub.expiresAt, 0, "default expiry");
    }
}
