// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {SepehrCore} from "../../src/SepehrCore.sol";
import {IDexRouter} from "../../src/interfaces/IDexRouter.sol";
import {ISepehrCore} from "../../src/interfaces/ISepehrCore.sol";
import {Percentages} from "../../src/libraries/Percentages.sol";
import {SepehrErrors} from "../../src/libraries/SepehrErrors.sol";
import {SepehrEvents} from "../../src/libraries/SepehrEvents.sol";
import {MockAdapter} from "../../src/mocks/MockAdapter.sol";
import {MockDex} from "../../src/mocks/MockDex.sol";
import {MockFlashLoan} from "../../src/mocks/MockFlashLoan.sol";
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

contract SepehrCoreTriggersTest is Test {
    SepehrCore public core;
    MockAdapter public adapter;
    MockFlashLoan public flashLoan;
    MockDex public dex;
    MockERC20 public usdc;
    MockERC20 public debtToken;
    MockERC20 public collateralToken;

    address public timelock = makeAddr("timelock");
    address public guardian = makeAddr("guardian");
    address public keeper = makeAddr("keeper");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    bytes32 public constant PROTOCOL_KEY = keccak256("AAVE_V3");
    uint256 public constant REPAY_AMOUNT = 1000e18;
    uint256 public constant HF_BELOW_THRESHOLD = 1.1e18;
    uint256 public constant HF_ABOVE_THRESHOLD = 1.5e18;
    uint256 public constant THRESHOLD_HF = 1.3e18;
    /// @dev H-2: a rescue that improves the HF without clearing the 1.3 threshold.
    uint256 public constant HF_PARTIAL_RESCUE = 1.25e18;
    uint256 public constant MONTHLY_PERIOD = 30 days;

    // Shield tier fee: 20 bps (0.20%)
    uint256 public constant SHIELD_FEE_BPS = 20;

    function setUp() public {
        vm.warp(10_000);

        adapter = new MockAdapter();
        flashLoan = new MockFlashLoan();
        dex = new MockDex();
        usdc = new MockERC20("USDC", "USDC");
        debtToken = new MockERC20("Debt Token", "DEBT");
        collateralToken = new MockERC20("Collateral Token", "COLL");

        // A7 gate intentionally disabled (0) for trigger-path tests; the gate is exercised
        // separately in the Admin and Subscriptions suites where it is load-bearing.
        core = new SepehrCore(address(this), timelock, guardian, address(usdc), 0, type(uint256).max, block.chainid);

        vm.startPrank(timelock);
        core.addAdapter(PROTOCOL_KEY, address(adapter));
        core.addKeeper(keeper);
        core.addFlashLoanProvider(address(flashLoan));
        core.addDexRouter(address(dex));
        vm.stopPrank();

        // Subscribe alice (Shield tier — monthly)
        usdc.mint(alice, 200e6);
        vm.prank(alice);
        usdc.approve(address(core), type(uint256).max);
        vm.prank(alice);
        core.subscribe(1, false);

        adapter.setDelegation(alice, true);

        vm.prank(alice);
        core.enableProtection(PROTOCOL_KEY, THRESHOLD_HF, 250, 2500);

        adapter.setHealthFactor(alice, HF_BELOW_THRESHOLD);
        adapter.setDebt(alice, address(debtToken), REPAY_AMOUNT * 100);

        debtToken.mint(address(flashLoan), REPAY_AMOUNT * 2);
        collateralToken.mint(address(adapter), REPAY_AMOUNT * 2);
        debtToken.mint(address(dex), REPAY_AMOUNT * 2);
    }

    // ─── Helpers ────────────────────────────────────────────────

    function _buildFlashProviders() internal view returns (address[] memory) {
        address[] memory providers = new address[](1);
        providers[0] = address(flashLoan);
        return providers;
    }

    // ─── A7: minCollateralUsd gate in enableProtection ─────────────

    /// @dev A7: once the timelock sets `minCollateralUsd > 0`, `enableProtection` must
    /// reject users whose adapter-reported collateral is below the floor. Without this
    /// the tier tagging is meaningless for triggers against dust positions.
    function test_enableProtection_revertsWhenCollateralBelowMin() public {
        vm.prank(timelock);
        core.setMinCollateralUsd(1000e8); // $1,000 floor

        adapter.setCollateralValueUsd(bob, 500e8); // $500, below floor
        adapter.setDelegation(bob, true);

        // Give bob a Shield subscription so the gate — not the subscription check — is what reverts.
        usdc.mint(bob, 200e6);
        vm.prank(bob);
        usdc.approve(address(core), type(uint256).max);
        vm.prank(bob);
        core.subscribe(1, false);

        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.BelowMinimumCollateral.selector, 500e8, 1000e8));
        vm.prank(bob);
        core.enableProtection(PROTOCOL_KEY, THRESHOLD_HF, 250, 2500);
    }

    function test_enableProtection_succeedsWhenCollateralAtMin() public {
        vm.prank(timelock);
        core.setMinCollateralUsd(1000e8);

        adapter.setCollateralValueUsd(bob, 1000e8);
        adapter.setDelegation(bob, true);

        usdc.mint(bob, 200e6);
        vm.prank(bob);
        usdc.approve(address(core), type(uint256).max);
        vm.prank(bob);
        core.subscribe(1, false);

        vm.prank(bob);
        core.enableProtection(PROTOCOL_KEY, THRESHOLD_HF, 250, 2500);

        ISepehrCore.PositionProtection memory p = core.getProtection(bob, PROTOCOL_KEY);
        assertTrue(p.enabled);
    }

    // ─── Success ────────────────────────────────────────────────

    function test_execute_success() public {
        SequentialMockAdapter seqAdapter = new SequentialMockAdapter(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        seqAdapter.setDelegation(alice, true);
        debtToken.mint(address(seqAdapter), REPAY_AMOUNT * 10);

        bytes32 seqKey = keccak256("SEQ_PROTOCOL");
        vm.prank(timelock);
        core.addAdapter(seqKey, address(seqAdapter));

        vm.prank(alice);
        core.enableProtection(seqKey, THRESHOLD_HF, 250, 2500);

        address[] memory providers = _buildFlashProviders();

        vm.prank(keeper);
        core.execute(alice, seqKey, address(debtToken), address(debtToken), REPAY_AMOUNT, providers, address(dex), "");

        assertEq(core.lastTriggerTime(alice, seqKey), block.timestamp);

        // Fee uses per-tier BPS (Shield = 20 bps). Per-asset accounting separates the Shield
        // monthly subscription ($9 USDC, 6 decimals) from the trigger fee in the debt asset.
        uint256 totalFee = Percentages.applyBps(REPAY_AMOUNT, SHIELD_FEE_BPS);
        (uint256 ownerShare, uint256 keeperShare) = Percentages.splitFee(totalFee);
        uint256 shieldMonthly = 9_000_000;
        assertEq(core.ownerFeeBalances(address(debtToken)), ownerShare);
        assertEq(core.ownerFeeBalances(address(usdc)), shieldMonthly);
        assertEq(core.keeperFeeBalances(keeper, address(debtToken)), keeperShare);
    }

    function test_execute_emitsTriggeredEvent() public {
        SequentialMockAdapter seqAdapter = new SequentialMockAdapter(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        seqAdapter.setDelegation(alice, true);
        debtToken.mint(address(seqAdapter), REPAY_AMOUNT * 10);

        bytes32 seqKey = keccak256("SEQ_PROTOCOL_2");
        vm.prank(timelock);
        core.addAdapter(seqKey, address(seqAdapter));
        vm.prank(alice);
        core.enableProtection(seqKey, THRESHOLD_HF, 250, 2500);

        address[] memory providers = _buildFlashProviders();

        vm.expectEmit(true, true, true, false, address(core));
        emit SepehrEvents.Triggered(alice, seqKey, keeper, REPAY_AMOUNT, 0, HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD, 0);

        vm.prank(keeper);
        core.execute(alice, seqKey, address(debtToken), address(debtToken), REPAY_AMOUNT, providers, address(dex), "");
    }

    function test_execute_emitsFeeCollectedEvent() public {
        SequentialMockAdapter seqAdapter = new SequentialMockAdapter(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        seqAdapter.setDelegation(alice, true);
        debtToken.mint(address(seqAdapter), REPAY_AMOUNT * 10);

        bytes32 seqKey = keccak256("SEQ_PROTOCOL_3");
        vm.prank(timelock);
        core.addAdapter(seqKey, address(seqAdapter));
        vm.prank(alice);
        core.enableProtection(seqKey, THRESHOLD_HF, 250, 2500);

        address[] memory providers = _buildFlashProviders();

        uint256 totalFee = Percentages.applyBps(REPAY_AMOUNT, SHIELD_FEE_BPS);
        (uint256 ownerShare, uint256 keeperShare) = Percentages.splitFee(totalFee);

        vm.expectEmit(true, true, false, true, address(core));
        emit SepehrEvents.FeeCollected(keeper, address(debtToken), totalFee, ownerShare, keeperShare);

        vm.prank(keeper);
        core.execute(alice, seqKey, address(debtToken), address(debtToken), REPAY_AMOUNT, providers, address(dex), "");
    }

    // ─── Per-tier fee validation ────────────────────────────────

    function test_execute_guardianTierUsesCorrectFee() public {
        // Subscribe bob as Guardian (tier 2) — fee should be 10 bps
        usdc.mint(bob, 200e6);
        vm.prank(bob);
        usdc.approve(address(core), type(uint256).max);
        vm.prank(bob);
        core.subscribe(2, false);

        SequentialMockAdapter seqAdapter = new SequentialMockAdapter(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        seqAdapter.setDelegation(bob, true);
        debtToken.mint(address(seqAdapter), REPAY_AMOUNT * 10);

        bytes32 seqKey = keccak256("GUARDIAN_FEE_PROTOCOL");
        vm.prank(timelock);
        core.addAdapter(seqKey, address(seqAdapter));

        vm.prank(bob);
        core.enableProtection(seqKey, THRESHOLD_HF, 250, 2500);

        address[] memory providers = _buildFlashProviders();

        vm.prank(keeper);
        core.execute(bob, seqKey, address(debtToken), address(debtToken), REPAY_AMOUNT, providers, address(dex), "");

        // Guardian fee = 10 bps. Per-asset accounting: USDC holds subscription revenue
        // (Shield $9 from setUp + Guardian $49 here); debt asset holds the trigger fee.
        uint256 totalFee = Percentages.applyBps(REPAY_AMOUNT, 10);
        (uint256 ownerShare, uint256 keeperShare) = Percentages.splitFee(totalFee);
        uint256 subscriptionRevenue = 9_000_000 + 49_000_000;
        assertEq(core.ownerFeeBalances(address(debtToken)), ownerShare);
        assertEq(core.ownerFeeBalances(address(usdc)), subscriptionRevenue);
        assertEq(core.keeperFeeBalances(keeper, address(debtToken)), keeperShare);
    }

    // ─── Reverts ────────────────────────────────────────────────

    function test_execute_revertsOnNonKeeper() public {
        address notKeeper = makeAddr("notKeeper");
        address[] memory providers = _buildFlashProviders();

        vm.expectRevert(SepehrErrors.NotKeeper.selector);
        vm.prank(notKeeper);
        core.execute(
            alice, PROTOCOL_KEY, address(debtToken), address(collateralToken), REPAY_AMOUNT, providers, address(dex), ""
        );
    }

    function test_execute_revertsWhenPaused() public {
        core.pause();
        address[] memory providers = _buildFlashProviders();

        vm.expectRevert(SepehrErrors.ContractPaused.selector);
        vm.prank(keeper);
        core.execute(
            alice, PROTOCOL_KEY, address(debtToken), address(collateralToken), REPAY_AMOUNT, providers, address(dex), ""
        );
    }

    function test_execute_revertsWhenHFAboveThreshold() public {
        adapter.setHealthFactor(alice, HF_ABOVE_THRESHOLD);
        address[] memory providers = _buildFlashProviders();

        vm.expectRevert(
            abi.encodeWithSelector(SepehrErrors.HealthFactorAboveThreshold.selector, HF_ABOVE_THRESHOLD, THRESHOLD_HF)
        );
        vm.prank(keeper);
        core.execute(
            alice, PROTOCOL_KEY, address(debtToken), address(collateralToken), REPAY_AMOUNT, providers, address(dex), ""
        );
    }

    function test_execute_revertsOnCooldown() public {
        SequentialMockAdapter seqAdapter = new SequentialMockAdapter(HF_BELOW_THRESHOLD, HF_PARTIAL_RESCUE);
        seqAdapter.setDelegation(alice, true);
        debtToken.mint(address(seqAdapter), REPAY_AMOUNT * 10);

        bytes32 seqKey = keccak256("COOLDOWN_PROTOCOL");
        vm.prank(timelock);
        core.addAdapter(seqKey, address(seqAdapter));
        vm.prank(alice);
        core.enableProtection(seqKey, THRESHOLD_HF, 250, 2500);

        address[] memory providers = _buildFlashProviders();

        vm.prank(keeper);
        core.execute(alice, seqKey, address(debtToken), address(debtToken), REPAY_AMOUNT, providers, address(dex), "");

        // H-2: the HF has not fallen 1% below what the trigger left, so the cooldown holds.
        seqAdapter.reset(HF_PARTIAL_RESCUE, HF_ABOVE_THRESHOLD);

        uint256 remaining = 3600;
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.CooldownActive.selector, remaining));
        vm.prank(keeper);
        core.execute(alice, seqKey, address(debtToken), address(debtToken), REPAY_AMOUNT, providers, address(dex), "");
    }

    function test_execute_succeedsAfterCooldown() public {
        SequentialMockAdapter seqAdapter = new SequentialMockAdapter(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        seqAdapter.setDelegation(alice, true);
        debtToken.mint(address(seqAdapter), REPAY_AMOUNT * 20);

        bytes32 seqKey = keccak256("COOLDOWN_PASS_PROTOCOL");
        vm.prank(timelock);
        core.addAdapter(seqKey, address(seqAdapter));
        vm.prank(alice);
        core.enableProtection(seqKey, THRESHOLD_HF, 250, 2500);

        address[] memory providers = _buildFlashProviders();

        debtToken.mint(address(flashLoan), REPAY_AMOUNT * 10);
        vm.prank(keeper);
        core.execute(alice, seqKey, address(debtToken), address(debtToken), REPAY_AMOUNT, providers, address(dex), "");

        vm.warp(block.timestamp + 3601);
        seqAdapter.reset(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        debtToken.mint(address(flashLoan), REPAY_AMOUNT * 10);

        vm.prank(keeper);
        core.execute(alice, seqKey, address(debtToken), address(debtToken), REPAY_AMOUNT, providers, address(dex), "");
    }

    function test_execute_revertsWhenSubscriptionExpired() public {
        vm.warp(block.timestamp + MONTHLY_PERIOD + 1);

        address[] memory providers = _buildFlashProviders();

        vm.expectRevert(SepehrErrors.SubscriptionExpired.selector);
        vm.prank(keeper);
        core.execute(
            alice, PROTOCOL_KEY, address(debtToken), address(collateralToken), REPAY_AMOUNT, providers, address(dex), ""
        );
    }

    function test_execute_revertsWhenProtectionNotEnabled() public {
        bytes32 unknownKey = keccak256("UNKNOWN_PROTOCOL");

        vm.prank(timelock);
        core.addAdapter(unknownKey, address(adapter));

        address[] memory providers = _buildFlashProviders();

        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.ProtectionNotEnabled.selector, alice, unknownKey));
        vm.prank(keeper);
        core.execute(
            alice, unknownKey, address(debtToken), address(collateralToken), REPAY_AMOUNT, providers, address(dex), ""
        );
    }

    function test_execute_revertsWhenDelegationRevoked() public {
        adapter.setDelegation(alice, false);

        address[] memory providers = _buildFlashProviders();

        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.DelegationRevoked.selector, alice, PROTOCOL_KEY));
        vm.prank(keeper);
        core.execute(
            alice, PROTOCOL_KEY, address(debtToken), address(collateralToken), REPAY_AMOUNT, providers, address(dex), ""
        );
    }

    function test_execute_revertsWhenNoFlashProviderAvailable() public {
        adapter.setHealthFactor(alice, HF_BELOW_THRESHOLD);

        address[] memory emptyProviders = new address[](0);

        vm.expectRevert(SepehrErrors.NoFlashLoanAvailable.selector);
        vm.prank(keeper);
        core.execute(
            alice,
            PROTOCOL_KEY,
            address(debtToken),
            address(collateralToken),
            REPAY_AMOUNT,
            emptyProviders,
            address(dex),
            ""
        );
    }

    function test_execute_revertsWhenFlashProviderUnavailable() public {
        adapter.setHealthFactor(alice, HF_BELOW_THRESHOLD);

        flashLoan.setShouldRevert(true);

        address[] memory providers = _buildFlashProviders();

        vm.expectRevert(SepehrErrors.NoFlashLoanAvailable.selector);
        vm.prank(keeper);
        core.execute(
            alice, PROTOCOL_KEY, address(debtToken), address(collateralToken), REPAY_AMOUNT, providers, address(dex), ""
        );
    }

    /// @dev A17: a provider that reports `isAvailable == true` but reverts inside `flashBorrow`
    /// triggers the `catch (bytes memory reason)` path; `_borrowFlashLoan` must emit
    /// `FlashAttemptFailed(provider, reason)` with the exact upstream revert bytes, then
    /// re-raise those bytes once no provider is left (L-1).
    function test_execute_emitsFlashAttemptFailedOnProviderRevert() public {
        adapter.setHealthFactor(alice, HF_BELOW_THRESHOLD);

        bytes memory reason = abi.encodeWithSignature("Error(string)", "oracle-stale");
        flashLoan.setRevertOnFlashBorrow(true, reason);

        address[] memory providers = _buildFlashProviders();

        vm.expectEmit(true, false, false, true, address(core));
        emit SepehrEvents.FlashAttemptFailed(address(flashLoan), reason);
        vm.expectRevert(reason);
        vm.prank(keeper);
        core.execute(
            alice, PROTOCOL_KEY, address(debtToken), address(collateralToken), REPAY_AMOUNT, providers, address(dex), ""
        );
    }

    /// @dev L-1: a provider that reverts without data leaves nothing to re-raise, so the
    /// trigger still reports `NoFlashLoanAvailable`.
    function test_execute_revertsNoFlashLoanAvailableWhenProviderRevertsWithoutData() public {
        adapter.setHealthFactor(alice, HF_BELOW_THRESHOLD);
        flashLoan.setRevertOnFlashBorrow(true, "");

        address[] memory providers = _buildFlashProviders();

        vm.expectRevert(SepehrErrors.NoFlashLoanAvailable.selector);
        vm.prank(keeper);
        core.execute(
            alice, PROTOCOL_KEY, address(debtToken), address(collateralToken), REPAY_AMOUNT, providers, address(dex), ""
        );
    }

    /// @dev M-6: no debt in `debtAsset` stops the trigger instead of skipping the repay limit.
    function test_execute_revertsWhenUserHasNoDebtInDebtAsset() public {
        adapter.setDebt(alice, address(debtToken), 0);

        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.NoDebtToRepay.selector, alice, address(debtToken)));
        vm.prank(keeper);
        core.execute(
            alice,
            PROTOCOL_KEY,
            address(debtToken),
            address(collateralToken),
            REPAY_AMOUNT,
            _buildFlashProviders(),
            address(dex),
            ""
        );
    }

    function test_execute_revertsOnZeroRepayAmount() public {
        adapter.setHealthFactor(alice, HF_BELOW_THRESHOLD);
        address[] memory providers = _buildFlashProviders();

        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        vm.prank(keeper);
        core.execute(alice, PROTOCOL_KEY, address(debtToken), address(collateralToken), 0, providers, address(dex), "");
    }

    function test_execute_revertsOnUnauthorizedDexRouter() public {
        adapter.setHealthFactor(alice, HF_BELOW_THRESHOLD);
        address[] memory providers = _buildFlashProviders();
        address fakeDex = makeAddr("fakeDex");

        vm.expectRevert(SepehrErrors.NotAuthorized.selector);
        vm.prank(keeper);
        core.execute(
            alice, PROTOCOL_KEY, address(debtToken), address(collateralToken), REPAY_AMOUNT, providers, fakeDex, ""
        );
    }

    function test_execute_revertsWhenNoSubscription() public {
        address bob = makeAddr("bob");
        address[] memory providers = _buildFlashProviders();

        vm.expectRevert(SepehrErrors.SubscriptionNotFound.selector);
        vm.prank(keeper);
        core.execute(
            bob, PROTOCOL_KEY, address(debtToken), address(collateralToken), REPAY_AMOUNT, providers, address(dex), ""
        );
    }

    // ─── D1/D4: canonical-route substitution at swap time ──────────

    /// @dev When governance has registered a canonical routeData for
    /// (dex, collateralAsset, debtAsset), SepehrCore must substitute it in — the
    /// keeper's `dexRouteData` argument is ignored.
    function test_execute_substitutesCanonicalRouteData() public {
        SequentialMockAdapter seqAdapter = new SequentialMockAdapter(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        seqAdapter.setDelegation(alice, true);

        bytes32 seqKey = keccak256("SEQ_CANONICAL");
        vm.prank(timelock);
        core.addAdapter(seqKey, address(seqAdapter));

        vm.prank(alice);
        core.enableProtection(seqKey, THRESHOLD_HF, 250, 2500);

        collateralToken.mint(address(seqAdapter), REPAY_AMOUNT * 10);
        debtToken.mint(address(dex), REPAY_AMOUNT * 10);

        // C1: cross-asset triggers size the collateral withdrawal via the oracle pair, so both
        // sides must be registered. Matched 1:1 prices keep the sizing straightforward here.
        MockChainlinkAggregator collAgg = new MockChainlinkAggregator(8, 1e8);
        MockChainlinkAggregator debtAgg = new MockChainlinkAggregator(8, 1e8);
        vm.startPrank(timelock);
        core.setAssetOracle(address(collateralToken), address(collAgg), 1 hours);
        core.setAssetOracle(address(debtToken), address(debtAgg), 1 hours);
        vm.stopPrank();

        bytes memory canonical = abi.encode(uint24(500), uint160(42));
        vm.prank(timelock);
        core.setCanonicalRoute(address(dex), address(collateralToken), address(debtToken), canonical);

        bytes memory keeperSupplied = abi.encode(uint24(10_000)); // attacker steering: thin pool
        address[] memory providers = _buildFlashProviders();

        vm.prank(keeper);
        core.execute(
            alice,
            seqKey,
            address(debtToken),
            address(collateralToken),
            REPAY_AMOUNT,
            providers,
            address(dex),
            keeperSupplied
        );

        assertEq(dex.lastRouteData(), canonical, "canonical data should override keeper-supplied");
    }

    /// @dev In strict mode, a pair without a canonical route registered must
    /// cause `execute` to revert — eliminating the keeper-pool-steering surface.
    function test_execute_strictMode_revertsWhenNoCanonicalRoute() public {
        SequentialMockAdapter seqAdapter = new SequentialMockAdapter(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        seqAdapter.setDelegation(alice, true);

        bytes32 seqKey = keccak256("SEQ_STRICT");
        vm.prank(timelock);
        core.addAdapter(seqKey, address(seqAdapter));

        vm.prank(alice);
        core.enableProtection(seqKey, THRESHOLD_HF, 250, 2500);

        collateralToken.mint(address(seqAdapter), REPAY_AMOUNT * 10);
        debtToken.mint(address(dex), REPAY_AMOUNT * 10);

        // C1: cross-asset triggers require both oracles registered for safe sizing.
        MockChainlinkAggregator collAgg = new MockChainlinkAggregator(8, 1e8);
        MockChainlinkAggregator debtAgg = new MockChainlinkAggregator(8, 1e8);
        vm.startPrank(timelock);
        core.setAssetOracle(address(collateralToken), address(collAgg), 1 hours);
        core.setAssetOracle(address(debtToken), address(debtAgg), 1 hours);
        vm.stopPrank();

        vm.prank(timelock);
        core.setStrictCanonicalRoutes(true);

        address[] memory providers = _buildFlashProviders();

        // L-1: the flash provider's try/catch re-raises the callback's own error.
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                SepehrErrors.NoCanonicalRoute.selector, address(dex), address(collateralToken), address(debtToken)
            )
        );
        core.execute(
            alice, seqKey, address(debtToken), address(collateralToken), REPAY_AMOUNT, providers, address(dex), ""
        );

        // Once a canonical route is registered, the same call succeeds.
        bytes memory canonical = abi.encode(uint24(500));
        vm.prank(timelock);
        core.setCanonicalRoute(address(dex), address(collateralToken), address(debtToken), canonical);

        vm.prank(keeper);
        core.execute(
            alice, seqKey, address(debtToken), address(collateralToken), REPAY_AMOUNT, providers, address(dex), ""
        );
        assertEq(dex.lastRouteData(), canonical);
    }

    // ─── D2: oracle-derived minOut floor ──────────────────────────

    /// @dev D2: when oracles are registered for both sides and the DEX returns less than
    /// `expected * (1 - maxSlippageBps)`, the swap must revert. Here the collateral feed
    /// prices the asset at 2x the debt feed, so oracle-expected out = 2 * collateralNeeded.
    /// The MockDex returns 1:1 (deliberate under-execution), so the oracle floor fires.
    function test_execute_oracleFloor_revertsOnDepressedSwap() public {
        bytes32 seqKey = keccak256("SEQ_ORACLE_DEPRESSED");
        _setupForSwap(seqKey);

        MockChainlinkAggregator collAgg = new MockChainlinkAggregator(8, 2e8); // $2 per unit
        MockChainlinkAggregator debtAgg = new MockChainlinkAggregator(8, 1e8); // $1 per unit

        vm.startPrank(timelock);
        core.setAssetOracle(address(collateralToken), address(collAgg), 1 hours);
        core.setAssetOracle(address(debtToken), address(debtAgg), 1 hours);
        vm.stopPrank();

        address[] memory providers = _buildFlashProviders();
        vm.prank(keeper);
        vm.expectRevert(bytes("MockDex: slippage"));
        core.execute(
            alice, seqKey, address(debtToken), address(collateralToken), REPAY_AMOUNT, providers, address(dex), ""
        );
    }

    /// @dev Sanity path: with matched prices (1:1) and a 1:1 MockDex, the oracle floor
    /// is below the solvency floor so execution succeeds — exercising that the oracle
    /// branch does not accidentally block legitimate swaps.
    function test_execute_oracleFloor_passesWhenSwapMatchesPrice() public {
        bytes32 seqKey = keccak256("SEQ_ORACLE_OK");
        _setupForSwap(seqKey);

        MockChainlinkAggregator collAgg = new MockChainlinkAggregator(8, 1e8);
        MockChainlinkAggregator debtAgg = new MockChainlinkAggregator(8, 1e8);

        vm.startPrank(timelock);
        core.setAssetOracle(address(collateralToken), address(collAgg), 1 hours);
        core.setAssetOracle(address(debtToken), address(debtAgg), 1 hours);
        vm.stopPrank();

        address[] memory providers = _buildFlashProviders();
        vm.prank(keeper);
        core.execute(
            alice, seqKey, address(debtToken), address(collateralToken), REPAY_AMOUNT, providers, address(dex), ""
        );
        assertEq(core.lastTriggerTime(alice, seqKey), block.timestamp);
    }

    /// @dev C1: cross-asset triggers size the collateral withdrawal via an inverse oracle
    /// projection, so BOTH sides must be registered. Missing either oracle reverts via
    /// `MissingAssetOracle`, re-raised as is by the flash-loan try/catch (L-1).
    /// (Previously the oracle-floor check was advisory and the trigger would silently run on
    /// keeper-sized input — that was the unit-conflation bug C1 now closes.)
    function test_execute_crossAsset_revertsWhenOnlyOneSideOracleRegistered() public {
        bytes32 seqKey = keccak256("SEQ_ORACLE_PARTIAL");
        _setupForSwap(seqKey);

        MockChainlinkAggregator collAgg = new MockChainlinkAggregator(8, 2e8);

        vm.prank(timelock);
        core.setAssetOracle(address(collateralToken), address(collAgg), 1 hours);
        // debtToken oracle deliberately left unregistered

        address[] memory providers = _buildFlashProviders();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.MissingAssetOracle.selector, address(debtToken)));
        core.execute(
            alice, seqKey, address(debtToken), address(collateralToken), REPAY_AMOUNT, providers, address(dex), ""
        );
    }

    /// @dev Strict oracle pricing: a missing oracle for either side must block the
    /// trigger outright. The inner `MissingAssetOracle` revert reaches the keeper as is (L-1).
    function test_execute_strictOracle_revertsWhenOracleMissing() public {
        bytes32 seqKey = keccak256("SEQ_ORACLE_STRICT_MISSING");
        _setupForSwap(seqKey);

        vm.prank(timelock);
        core.setStrictOraclePricing(true);

        address[] memory providers = _buildFlashProviders();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.MissingAssetOracle.selector, address(collateralToken)));
        core.execute(
            alice, seqKey, address(debtToken), address(collateralToken), REPAY_AMOUNT, providers, address(dex), ""
        );
    }

    /// @dev Same-asset triggers never reach the oracle branch (no swap), so strict
    /// mode cannot block them.
    function test_execute_strictOracle_doesNotRequireOracleWhenNoSwap() public {
        SequentialMockAdapter seqAdapter = new SequentialMockAdapter(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        seqAdapter.setDelegation(alice, true);
        debtToken.mint(address(seqAdapter), REPAY_AMOUNT * 10);

        bytes32 seqKey = keccak256("SEQ_ORACLE_STRICT_NOSWAP");
        vm.prank(timelock);
        core.addAdapter(seqKey, address(seqAdapter));

        vm.prank(alice);
        core.enableProtection(seqKey, THRESHOLD_HF, 250, 2500);

        vm.prank(timelock);
        core.setStrictOraclePricing(true);

        address[] memory providers = _buildFlashProviders();
        vm.prank(keeper);
        core.execute(alice, seqKey, address(debtToken), address(debtToken), REPAY_AMOUNT, providers, address(dex), "");
        assertEq(core.lastTriggerTime(alice, seqKey), block.timestamp);
    }

    /// @dev A stale oracle reading (updatedAt older than the configured staleness)
    /// must revert via `StaleOraclePrice`, wrapped by the flash-loan try/catch.
    function test_execute_oracleFloor_revertsOnStalePrice() public {
        bytes32 seqKey = keccak256("SEQ_ORACLE_STALE");
        _setupForSwap(seqKey);

        MockChainlinkAggregator collAgg = new MockChainlinkAggregator(8, 1e8);
        MockChainlinkAggregator debtAgg = new MockChainlinkAggregator(8, 1e8);

        vm.startPrank(timelock);
        core.setAssetOracle(address(collateralToken), address(collAgg), 30 minutes);
        core.setAssetOracle(address(debtToken), address(debtAgg), 30 minutes);
        vm.stopPrank();

        // Make the collateral feed stale: push its updatedAt into the past, then warp forward
        // beyond the 30-minute staleness window.
        collAgg.setUpdatedAt(block.timestamp);
        vm.warp(block.timestamp + 31 minutes);

        address[] memory providers = _buildFlashProviders();
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                SepehrErrors.StaleOraclePrice.selector, address(collateralToken), uint256(10_000), block.timestamp
            )
        );
        core.execute(
            alice, seqKey, address(debtToken), address(collateralToken), REPAY_AMOUNT, providers, address(dex), ""
        );
    }

    /// @dev Non-positive oracle answer (0 or negative) is a Chainlink "no valid round"
    /// signal and must block the trigger rather than be coerced to uint256.
    function test_execute_oracleFloor_revertsOnZeroAnswer() public {
        bytes32 seqKey = keccak256("SEQ_ORACLE_ZERO");
        _setupForSwap(seqKey);

        MockChainlinkAggregator collAgg = new MockChainlinkAggregator(8, 1e8);
        MockChainlinkAggregator debtAgg = new MockChainlinkAggregator(8, 0);

        vm.startPrank(timelock);
        core.setAssetOracle(address(collateralToken), address(collAgg), 1 hours);
        core.setAssetOracle(address(debtToken), address(debtAgg), 1 hours);
        vm.stopPrank();

        address[] memory providers = _buildFlashProviders();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.InvalidOraclePrice.selector, address(debtToken), int256(0)));
        core.execute(
            alice, seqKey, address(debtToken), address(collateralToken), REPAY_AMOUNT, providers, address(dex), ""
        );
    }

    // ─── H-3 / L-2 / I-1: what a trigger keeps, returns and reports ───────

    /// @dev Debt asset the core keeps from a trigger: the flash loan, its fee and the Shield fee.
    function _owed(
        uint256 repay
    ) internal view returns (uint256) {
        return repay + Percentages.applyBps(repay, flashLoan.feeBps()) + Percentages.applyBps(repay, SHIELD_FEE_BPS);
    }

    function _protectWith(
        bytes32 key,
        address adapter_
    ) internal {
        vm.prank(timelock);
        core.addAdapter(key, adapter_);
        vm.prank(alice);
        core.enableProtection(key, THRESHOLD_HF, 250, 2500);
    }

    function _registerParityOracles() internal {
        MockChainlinkAggregator collAgg = new MockChainlinkAggregator(8, 1e8);
        MockChainlinkAggregator debtAgg = new MockChainlinkAggregator(8, 1e8);
        vm.startPrank(timelock);
        core.setAssetOracle(address(collateralToken), address(collAgg), 1 hours);
        core.setAssetOracle(address(debtToken), address(debtAgg), 1 hours);
        vm.stopPrank();
    }

    /// @dev I-1: `Triggered.collateralWithdrawn` reports what left the position.
    function test_execute_reportsCollateralWithdrawn() public {
        SequentialMockAdapter seqAdapter = new SequentialMockAdapter(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        seqAdapter.setDelegation(alice, true);
        debtToken.mint(address(seqAdapter), REPAY_AMOUNT * 10);
        bytes32 seqKey = keccak256("SEQ_I1");
        _protectWith(seqKey, address(seqAdapter));

        uint256 totalFee = Percentages.applyBps(REPAY_AMOUNT, SHIELD_FEE_BPS);
        vm.expectEmit(true, true, true, true, address(core));
        emit SepehrEvents.Triggered(
            alice, seqKey, keeper, REPAY_AMOUNT, _owed(REPAY_AMOUNT), HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD, totalFee
        );
        vm.prank(keeper);
        core.execute(
            alice,
            seqKey,
            address(debtToken),
            address(debtToken),
            REPAY_AMOUNT,
            _buildFlashProviders(),
            address(dex),
            ""
        );
    }

    /// @dev H-3: the slippage headroom a fair swap did not use goes to the user, not the owner.
    function test_execute_returnsUnusedSlippageHeadroomToUser() public {
        bytes32 seqKey = keccak256("SEQ_H3");
        _setupForSwap(seqKey);
        _registerParityOracles();

        uint256 owed = _owed(REPAY_AMOUNT);
        // Parity oracles: the core withdraws `owed` grossed up by the 2.5% slippage and MockDex
        // swaps it 1:1, so everything above `owed` is unused headroom.
        uint256 headroom = Math.mulDiv(owed, 10_000, 10_000 - 250, Math.Rounding.Ceil) - owed;
        uint256 aliceBefore = debtToken.balanceOf(alice);

        vm.expectEmit(true, true, false, true, address(core));
        emit SepehrEvents.SurplusReturned(alice, address(debtToken), headroom);
        vm.prank(keeper);
        core.execute(
            alice,
            seqKey,
            address(debtToken),
            address(collateralToken),
            REPAY_AMOUNT,
            _buildFlashProviders(),
            address(dex),
            ""
        );

        assertEq(debtToken.balanceOf(alice) - aliceBefore, headroom, "headroom returned to the user");
        (uint256 ownerShare,) = Percentages.splitFee(Percentages.applyBps(REPAY_AMOUNT, SHIELD_FEE_BPS));
        assertEq(core.ownerFeeBalances(address(debtToken)), ownerShare, "owner keeps only the trigger fee");
    }

    /// @dev L-2: collateral the router hands back unspent goes to the user, and the core counts
    /// what it received rather than what the router reports.
    function test_execute_returnsCollateralTheRouterLeftUnspent() public {
        bytes32 seqKey = keccak256("SEQ_L2_ROUTER");
        _setupForSwap(seqKey);
        _registerParityOracles();
        LeftoverDex leftoverDex = new LeftoverDex();
        leftoverDex.configure(9000, 1.2e18);
        debtToken.mint(address(leftoverDex), REPAY_AMOUNT * 2);
        vm.prank(timelock);
        core.addDexRouter(address(leftoverDex));

        uint256 owed = _owed(REPAY_AMOUNT);
        uint256 collateralNeeded = Math.mulDiv(owed, 10_000, 10_000 - 250, Math.Rounding.Ceil);
        uint256 pulled = (collateralNeeded * 9000) / 10_000;
        uint256 received = (pulled * 1.2e18) / 1e18;
        uint256 collateralBefore = collateralToken.balanceOf(alice);
        uint256 debtBefore = debtToken.balanceOf(alice);

        vm.prank(keeper);
        core.execute(
            alice,
            seqKey,
            address(debtToken),
            address(collateralToken),
            REPAY_AMOUNT,
            _buildFlashProviders(),
            address(leftoverDex),
            ""
        );

        assertEq(collateralToken.balanceOf(alice) - collateralBefore, collateralNeeded - pulled, "unspent collateral");
        assertEq(debtToken.balanceOf(alice) - debtBefore, received - owed, "measured swap surplus");
    }

    /// @dev L-2: a repay surplus the adapter sweeps back to the core goes to the user.
    function test_execute_returnsAdapterRepaySurplusToUser() public {
        RefundingRepayAdapter refunding = new RefundingRepayAdapter(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD, 100e18);
        refunding.setDelegation(alice, true);
        debtToken.mint(address(refunding), REPAY_AMOUNT * 10);
        bytes32 seqKey = keccak256("SEQ_L2_REPAY");
        _protectWith(seqKey, address(refunding));
        uint256 aliceBefore = debtToken.balanceOf(alice);

        vm.prank(keeper);
        core.execute(
            alice,
            seqKey,
            address(debtToken),
            address(debtToken),
            REPAY_AMOUNT,
            _buildFlashProviders(),
            address(dex),
            ""
        );

        assertEq(debtToken.balanceOf(alice) - aliceBefore, 100e18);
    }

    /// @dev A withdrawal short of what the trigger owes reverts with the shortfall.
    function test_execute_revertsWhenProceedsFallShortOfOwed() public {
        ShortWithdrawAdapter short = new ShortWithdrawAdapter(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        short.setDelegation(alice, true);
        debtToken.mint(address(short), REPAY_AMOUNT * 10);
        bytes32 seqKey = keccak256("SEQ_SHORT");
        _protectWith(seqKey, address(short));

        uint256 owed = _owed(REPAY_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.InsufficientRescueProceeds.selector, owed - 1, owed));
        vm.prank(keeper);
        core.execute(
            alice,
            seqKey,
            address(debtToken),
            address(debtToken),
            REPAY_AMOUNT,
            _buildFlashProviders(),
            address(dex),
            ""
        );
    }

    // ─── L-5: L2 sequencer uptime ─────────────────────────────────────

    /// @dev A cross-asset trigger with parity oracles and a sequencer feed reporting `answer`
    /// since `startedAt`.
    function _triggerSwapWithSequencer(
        int256 answer,
        uint256 startedAt
    ) internal {
        bytes32 seqKey = keccak256(abi.encode("SEQ_L5", answer, startedAt));
        _setupForSwap(seqKey);
        _registerParityOracles();
        MockChainlinkAggregator sequencer = new MockChainlinkAggregator(0, answer);
        sequencer.setUpdatedAt(startedAt);
        vm.prank(timelock);
        core.setSequencerUptimeFeed(address(sequencer));

        vm.prank(keeper);
        core.execute(
            alice,
            seqKey,
            address(debtToken),
            address(collateralToken),
            REPAY_AMOUNT,
            _buildFlashProviders(),
            address(dex),
            ""
        );
    }

    function test_execute_revertsWhileTheSequencerIsDown() public {
        vm.expectRevert(SepehrErrors.SequencerDown.selector);
        this.triggerSwapWithSequencer(1, block.timestamp - 2 hours);
    }

    function test_execute_revertsOnAnInvalidSequencerRound() public {
        vm.expectRevert(SepehrErrors.SequencerDown.selector);
        this.triggerSwapWithSequencer(0, 0);
    }

    function test_execute_revertsDuringTheSequencerGracePeriod() public {
        uint256 upSince = block.timestamp - 30 minutes;
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.SequencerGracePeriodNotOver.selector, upSince));
        this.triggerSwapWithSequencer(0, upSince);
    }

    function test_execute_runsOnceTheSequencerHasBeenUpPastTheGracePeriod() public {
        _triggerSwapWithSequencer(0, block.timestamp - 2 hours);
    }

    /// @dev External hop so `vm.expectRevert` sees the trigger's revert, not the setup calls.
    function triggerSwapWithSequencer(
        int256 answer,
        uint256 startedAt
    ) external {
        _triggerSwapWithSequencer(answer, startedAt);
    }

    // ─── I-2: repay share floor ───────────────────────────────────────

    function test_enableProtection_revertsBelowTheMinimumRepayShare() public {
        bytes32 key = keccak256("I2_ENABLE");
        vm.prank(timelock);
        core.addAdapter(key, address(adapter));

        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.RepayPercentTooLow.selector, 0, 100));
        vm.prank(alice);
        core.enableProtection(key, THRESHOLD_HF, 250, 0);

        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.RepayPercentTooLow.selector, 99, 100));
        vm.prank(alice);
        core.enableProtection(key, THRESHOLD_HF, 250, 99);

        vm.prank(alice);
        core.enableProtection(key, THRESHOLD_HF, 250, 100);
    }

    function test_updateProtection_revertsBelowTheMinimumRepayShare() public {
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.RepayPercentTooLow.selector, 0, 100));
        vm.prank(alice);
        core.updateProtection(PROTOCOL_KEY, THRESHOLD_HF, 250, 0);
    }

    /// @dev Internal helper — wires a fresh SequentialMockAdapter under `seqKey`,
    /// enables alice's protection against it, and funds the DEX + adapter so a
    /// collateral→debt swap is possible. Keeps each D2 test self-contained.
    function _setupForSwap(
        bytes32 seqKey
    ) internal {
        SequentialMockAdapter seqAdapter = new SequentialMockAdapter(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        seqAdapter.setDelegation(alice, true);

        vm.prank(timelock);
        core.addAdapter(seqKey, address(seqAdapter));

        vm.prank(alice);
        core.enableProtection(seqKey, THRESHOLD_HF, 250, 2500);

        collateralToken.mint(address(seqAdapter), REPAY_AMOUNT * 2);
        debtToken.mint(address(dex), REPAY_AMOUNT * 2);
    }

    /// @dev When collateralAsset == debtAsset (no swap), the canonical route
    /// registry is never consulted — even in strict mode. This keeps adapters
    /// that settle in the debt asset working without a registry entry.
    function test_execute_strictMode_doesNotRequireRouteWhenNoSwap() public {
        SequentialMockAdapter seqAdapter = new SequentialMockAdapter(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        seqAdapter.setDelegation(alice, true);
        debtToken.mint(address(seqAdapter), REPAY_AMOUNT * 10);

        bytes32 seqKey = keccak256("SEQ_NOSWAP");
        vm.prank(timelock);
        core.addAdapter(seqKey, address(seqAdapter));

        vm.prank(alice);
        core.enableProtection(seqKey, THRESHOLD_HF, 250, 2500);

        vm.prank(timelock);
        core.setStrictCanonicalRoutes(true);

        address[] memory providers = _buildFlashProviders();

        vm.prank(keeper);
        core.execute(
            alice,
            seqKey,
            address(debtToken),
            address(debtToken), // same asset — no swap, registry not consulted
            REPAY_AMOUNT,
            providers,
            address(dex),
            ""
        );

        assertEq(core.lastTriggerTime(alice, seqKey), block.timestamp);
    }

    /// @dev A16: cooldown is keyed by `(user, protocolKey)`. A trigger on one protocol must
    /// NOT lock out a concurrent trigger on another protocol for the same user — otherwise an
    /// adversary could freeze protection on the critical position by triggering a low-stakes
    /// one first.
    function test_execute_cooldownIsPerProtocol() public {
        // Two adapters, same user, both below threshold.
        SequentialMockAdapter adapterA = new SequentialMockAdapter(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        adapterA.setDelegation(alice, true);
        debtToken.mint(address(adapterA), REPAY_AMOUNT * 10);
        bytes32 keyA = keccak256("COOLDOWN_INDEPENDENT_A");
        vm.prank(timelock);
        core.addAdapter(keyA, address(adapterA));

        SequentialMockAdapter adapterB = new SequentialMockAdapter(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        adapterB.setDelegation(alice, true);
        debtToken.mint(address(adapterB), REPAY_AMOUNT * 10);
        bytes32 keyB = keccak256("COOLDOWN_INDEPENDENT_B");
        vm.prank(timelock);
        core.addAdapter(keyB, address(adapterB));

        vm.startPrank(alice);
        core.enableProtection(keyA, THRESHOLD_HF, 250, 2500);
        core.enableProtection(keyB, THRESHOLD_HF, 250, 2500);
        vm.stopPrank();

        address[] memory providers = _buildFlashProviders();

        // Fire on protocol A.
        vm.prank(keeper);
        core.execute(alice, keyA, address(debtToken), address(debtToken), REPAY_AMOUNT, providers, address(dex), "");
        uint256 tA = core.lastTriggerTime(alice, keyA);
        assertEq(tA, block.timestamp, "A cooldown registered");
        assertEq(core.lastTriggerTime(alice, keyB), 0, "B cooldown untouched");

        // Pre-A16 this would revert with CooldownActive; now it must succeed.
        vm.prank(keeper);
        core.execute(alice, keyB, address(debtToken), address(debtToken), REPAY_AMOUNT, providers, address(dex), "");
        assertEq(core.lastTriggerTime(alice, keyB), block.timestamp, "B cooldown independent");
        assertEq(core.lastTriggerTime(alice, keyA), tA, "A cooldown unchanged by B trigger");
    }

    // ─── A18: unsubscribe clears protections ──────────────────────

    /// @dev A18: `unsubscribe` must iterate `_userProtocols[msg.sender]` and wipe each
    /// `_protections[user][key]`, so a later re-subscribe starts from a clean slate instead
    /// of silently re-activating stale threshold/slippage params.
    function test_unsubscribe_clearsProtectionState() public {
        // Setup: register a second protocol, enable protection on both.
        bytes32 keyB = keccak256("SECOND_PROTOCOL");
        MockAdapter adapterB = new MockAdapter();
        adapterB.setDelegation(alice, true);
        vm.prank(timelock);
        core.addAdapter(keyB, address(adapterB));

        vm.prank(alice);
        core.enableProtection(keyB, THRESHOLD_HF, 200, 3000);

        // Sanity: both keys enabled.
        ISepehrCore.PositionProtection memory pA = core.getProtection(alice, PROTOCOL_KEY);
        ISepehrCore.PositionProtection memory pB = core.getProtection(alice, keyB);
        assertTrue(pA.enabled);
        assertTrue(pB.enabled);

        bytes32[] memory before = core.getUserProtocols(alice);
        assertEq(before.length, 2);

        // Need USDC balance for the refund path. Mint and warp mid-period so refund is non-zero
        // but bounded by ownerFeeBalances[usdc] (which holds alice's $9 setUp subscription).
        vm.warp(block.timestamp + 10 days);

        vm.prank(alice);
        core.unsubscribe();

        // A18: protections are wiped.
        pA = core.getProtection(alice, PROTOCOL_KEY);
        pB = core.getProtection(alice, keyB);
        assertFalse(pA.enabled, "protection A not cleared");
        assertFalse(pB.enabled, "protection B not cleared");
        assertEq(pA.thresholdHF, 0);
        assertEq(pB.thresholdHF, 0);

        bytes32[] memory after_ = core.getUserProtocols(alice);
        assertEq(after_.length, 0, "user protocols list not cleared");
    }

    /// @dev A18: emits `UserProtectionsCleared(user, count)` with the correct count.
    function test_unsubscribe_emitsUserProtectionsCleared() public {
        bytes32[] memory prior = core.getUserProtocols(alice);
        assertEq(prior.length, 1, "setUp enabled exactly one protection for alice");

        vm.expectEmit(true, false, false, true, address(core));
        emit SepehrEvents.UserProtectionsCleared(alice, 1);

        vm.prank(alice);
        core.unsubscribe();
    }

    /// @dev A18: getUserProtocols reflects enable/disable flow.
    function test_getUserProtocols_tracksEnableDisable() public {
        // setUp already enabled PROTOCOL_KEY → 1 entry.
        bytes32[] memory list = core.getUserProtocols(alice);
        assertEq(list.length, 1);
        assertEq(list[0], PROTOCOL_KEY);

        // Enable a second protocol.
        bytes32 keyB = keccak256("UP_KEY_B");
        MockAdapter adapterB = new MockAdapter();
        adapterB.setDelegation(alice, true);
        vm.prank(timelock);
        core.addAdapter(keyB, address(adapterB));
        vm.prank(alice);
        core.enableProtection(keyB, THRESHOLD_HF, 200, 2500);

        list = core.getUserProtocols(alice);
        assertEq(list.length, 2);

        // Disable the first: swap-pop leaves keyB in slot 0.
        vm.prank(alice);
        core.disableProtection(PROTOCOL_KEY);
        list = core.getUserProtocols(alice);
        assertEq(list.length, 1);
        assertEq(list[0], keyB);

        // Disable the last.
        vm.prank(alice);
        core.disableProtection(keyB);
        list = core.getUserProtocols(alice);
        assertEq(list.length, 0);
    }

    // ─── H-2: partial rescues and re-triggers in a falling market ─────────

    function _protectWithSequence(
        bytes32 key,
        uint256 initialHF,
        uint256 postRepayHF
    ) internal returns (SequentialMockAdapter seqAdapter) {
        seqAdapter = new SequentialMockAdapter(initialHF, postRepayHF);
        seqAdapter.setDelegation(alice, true);
        debtToken.mint(address(seqAdapter), REPAY_AMOUNT * 10);
        debtToken.mint(address(flashLoan), REPAY_AMOUNT * 10);
        _protectWith(key, address(seqAdapter));
    }

    function _trigger(
        bytes32 key
    ) internal {
        vm.prank(keeper);
        core.execute(
            alice, key, address(debtToken), address(debtToken), REPAY_AMOUNT, _buildFlashProviders(), address(dex), ""
        );
    }

    /// @dev H-2: a rescue that improves the HF is accepted even when it does not clear the
    /// threshold, and the HF it leaves is recorded.
    function test_execute_acceptsPartialRescueBelowThreshold() public {
        bytes32 key = keccak256("H2_PARTIAL");
        _protectWithSequence(key, HF_BELOW_THRESHOLD, HF_PARTIAL_RESCUE);

        _trigger(key);

        assertEq(core.lastTriggerHealthFactor(alice, key), HF_PARTIAL_RESCUE);
        assertEq(core.lastTriggerTime(alice, key), block.timestamp);
    }

    /// @dev H-2: inside the cooldown, a HF 1% below what the last trigger left re-opens it.
    function test_execute_retriggersDuringCooldownWhenHealthFactorFallsFurther() public {
        bytes32 key = keccak256("H2_RETRIGGER");
        SequentialMockAdapter seqAdapter = _protectWithSequence(key, HF_BELOW_THRESHOLD, HF_PARTIAL_RESCUE);
        _trigger(key);

        vm.warp(block.timestamp + 20 minutes);
        uint256 retriggerBelow = (HF_PARTIAL_RESCUE * (10_000 - core.RETRIGGER_HF_DROP_BPS())) / 10_000;
        seqAdapter.reset(retriggerBelow - 1, HF_PARTIAL_RESCUE);
        _trigger(key);

        assertEq(core.lastTriggerTime(alice, key), block.timestamp);
    }

    /// @dev H-2: at exactly the 1% line the cooldown still holds.
    function test_execute_cooldownHoldsAtTheRetriggerLine() public {
        bytes32 key = keccak256("H2_LINE");
        SequentialMockAdapter seqAdapter = _protectWithSequence(key, HF_BELOW_THRESHOLD, HF_PARTIAL_RESCUE);
        _trigger(key);

        vm.warp(block.timestamp + 20 minutes);
        uint256 retriggerBelow = (HF_PARTIAL_RESCUE * (10_000 - core.RETRIGGER_HF_DROP_BPS())) / 10_000;
        seqAdapter.reset(retriggerBelow, HF_PARTIAL_RESCUE);

        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.CooldownActive.selector, 40 minutes));
        _trigger(key);
    }

    /// @dev H09 still holds: a trigger that does not raise the HF reverts.
    function test_execute_revertsWhenRescueDoesNotImproveHealthFactor() public {
        bytes32 key = keccak256("H2_NO_IMPROVEMENT");
        _protectWithSequence(key, HF_BELOW_THRESHOLD, HF_BELOW_THRESHOLD);

        vm.expectRevert(
            abi.encodeWithSelector(
                SepehrErrors.HealthFactorNotImproved.selector, HF_BELOW_THRESHOLD, HF_BELOW_THRESHOLD
            )
        );
        _trigger(key);
    }

    /// @dev A16: the same-protocol cooldown still gates re-entry. Once A16 keys cooldown by
    /// protocolKey, firing twice on the same key within COOLDOWN_SECONDS must still revert.
    function test_execute_sameProtocolCooldownStillEnforced() public {
        SequentialMockAdapter seqAdapter = new SequentialMockAdapter(HF_BELOW_THRESHOLD, HF_PARTIAL_RESCUE);
        seqAdapter.setDelegation(alice, true);
        debtToken.mint(address(seqAdapter), REPAY_AMOUNT * 10);
        bytes32 seqKey = keccak256("SAME_KEY_COOLDOWN");
        vm.prank(timelock);
        core.addAdapter(seqKey, address(seqAdapter));

        vm.prank(alice);
        core.enableProtection(seqKey, THRESHOLD_HF, 250, 2500);

        address[] memory providers = _buildFlashProviders();

        vm.prank(keeper);
        core.execute(alice, seqKey, address(debtToken), address(debtToken), REPAY_AMOUNT, providers, address(dex), "");

        // Retry while the HF still sits where the trigger left it (H-2: no 1% drop).
        seqAdapter.reset(HF_PARTIAL_RESCUE, HF_ABOVE_THRESHOLD);
        debtToken.mint(address(flashLoan), REPAY_AMOUNT * 2);

        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.CooldownActive.selector, 3600));
        vm.prank(keeper);
        core.execute(alice, seqKey, address(debtToken), address(debtToken), REPAY_AMOUNT, providers, address(dex), "");
    }

    /// @notice B15: `hfBefore` below `MIN_PLAUSIBLE_HF_WAD` must revert — this is the on-chain
    /// backstop against an oracle-manipulated adapter reporting a near-zero HF to extract fees.
    function test_execute_revertsOnImplausiblyLowHF() public {
        uint256 tooLow = core.MIN_PLAUSIBLE_HF_WAD() - 1;
        adapter.setHealthFactor(alice, tooLow);
        address[] memory providers = _buildFlashProviders();

        vm.expectRevert(
            abi.encodeWithSelector(SepehrErrors.ImplausibleHealthFactor.selector, tooLow, core.MIN_PLAUSIBLE_HF_WAD())
        );
        vm.prank(keeper);
        core.execute(
            alice, PROTOCOL_KEY, address(debtToken), address(collateralToken), REPAY_AMOUNT, providers, address(dex), ""
        );
    }

    /// @notice B15: `hfBefore` exactly at the floor still reverts (`<` vs `<=` boundary).
    function test_execute_acceptsHFAtPlausibleFloor() public {
        uint256 floor = core.MIN_PLAUSIBLE_HF_WAD();
        adapter.setHealthFactor(alice, floor);
        address[] memory providers = _buildFlashProviders();

        // At the floor HF is plausible; revert source is now HealthFactorAboveThreshold? No —
        // floor (0.5e18) < THRESHOLD_HF (1.3e18), so we would fall through the B15 check and
        // into the normal trigger path. Use a SequentialMockAdapter for the full trip.
        SequentialMockAdapter seqAdapter = new SequentialMockAdapter(floor, HF_ABOVE_THRESHOLD);
        seqAdapter.setDelegation(alice, true);
        debtToken.mint(address(seqAdapter), REPAY_AMOUNT * 10);

        bytes32 seqKey = keccak256("B15_FLOOR_PROTOCOL");
        vm.prank(timelock);
        core.addAdapter(seqKey, address(seqAdapter));
        vm.prank(alice);
        core.enableProtection(seqKey, THRESHOLD_HF, 250, 2500);

        debtToken.mint(address(flashLoan), REPAY_AMOUNT * 10);
        vm.prank(keeper);
        core.execute(alice, seqKey, address(debtToken), address(debtToken), REPAY_AMOUNT, providers, address(dex), "");
    }
}

/// @dev A mock adapter that simulates HF improvement after repayment.
contract SequentialMockAdapter {
    mapping(address => bool) public delegations;
    uint256 public currentHF;
    uint256 public postRepayHF;

    constructor(
        uint256 _initialHF,
        uint256 _postRepayHF
    ) {
        currentHF = _initialHF;
        postRepayHF = _postRepayHF;
    }

    function reset(
        uint256 _initialHF,
        uint256 _postRepayHF
    ) external {
        currentHF = _initialHF;
        postRepayHF = _postRepayHF;
    }

    function setDelegation(
        address user,
        bool delegated
    ) external {
        delegations[user] = delegated;
    }

    function getHealthFactor(
        address
    ) external view returns (uint256) {
        return currentHF;
    }

    function checkDelegation(
        address user
    ) external view returns (bool) {
        return delegations[user];
    }

    function repay(
        address,
        address debtAsset,
        uint256 amount
    ) external virtual {
        ERC20(debtAsset).transfer(address(0xdead), amount);
        currentHF = postRepayHF;
    }

    function withdrawCollateral(
        address,
        address collateralAsset,
        uint256 amount,
        address recipient
    ) external virtual {
        ERC20(collateralAsset).transfer(recipient, amount);
    }

    function getCollateralValueUsd(
        address
    ) external pure returns (uint256) {
        return 10_000e8; // $10k — below Shield tier cap ($15k) so execute() passes H01 check
    }

    /// @dev M-6: SepehrCore rejects a zero debt, so the mock owes enough for any test repay.
    function getDebt(
        address,
        address
    ) external pure returns (uint256) {
        return 1_000_000e18;
    }
}

/// @notice L-2: repays like AaveV3Adapter does when asked for more than the debt, sweeping
/// `refund` of the repay amount back to the core.
contract RefundingRepayAdapter is SequentialMockAdapter {
    uint256 public immutable refund;

    constructor(
        uint256 _initialHF,
        uint256 _postRepayHF,
        uint256 _refund
    ) SequentialMockAdapter(_initialHF, _postRepayHF) {
        refund = _refund;
    }

    function repay(
        address,
        address debtAsset,
        uint256 amount
    ) external override {
        ERC20(debtAsset).transfer(address(0xdead), amount - refund);
        ERC20(debtAsset).transfer(msg.sender, refund);
        currentHF = postRepayHF;
    }
}

/// @notice Delivers one unit less collateral than asked, like a fee-on-transfer token.
contract ShortWithdrawAdapter is SequentialMockAdapter {
    constructor(
        uint256 _initialHF,
        uint256 _postRepayHF
    ) SequentialMockAdapter(_initialHF, _postRepayHF) {}

    function withdrawCollateral(
        address,
        address collateralAsset,
        uint256 amount,
        address recipient
    ) external override {
        ERC20(collateralAsset).transfer(recipient, amount - 1);
    }
}

/// @notice L-2: consumes `pullBps` of the input, pays `rateWad` per unit consumed, and reports
/// twice what it paid, so a test can tell measured balances from the router's own claim.
contract LeftoverDex is IDexRouter {
    uint256 public pullBps = 10_000;
    uint256 public rateWad = 1e18;

    function configure(
        uint256 _pullBps,
        uint256 _rateWad
    ) external {
        pullBps = _pullBps;
        rateWad = _rateWad;
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256,
        bytes calldata
    ) external returns (uint256) {
        uint256 pulled = (amountIn * pullBps) / 10_000;
        ERC20(tokenIn).transferFrom(msg.sender, address(this), pulled);
        uint256 out = (pulled * rateWad) / 1e18;
        ERC20(tokenOut).transfer(msg.sender, out);
        return out * 2;
    }

    function getQuote(
        address,
        address,
        uint256 amountIn
    ) external view returns (uint256) {
        return (amountIn * rateWad) / 1e18;
    }
}
