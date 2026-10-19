// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {SepehrCore} from "../../src/SepehrCore.sol";
import {SepehrSubscriptions} from "../../src/SepehrSubscriptions.sol";
import {AggregatorRouter} from "../../src/dex/AggregatorRouter.sol";
import {IDexRouter} from "../../src/interfaces/IDexRouter.sol";
import {IFlashLoanProvider} from "../../src/interfaces/IFlashLoanProvider.sol";
import {ISepehrCallback} from "../../src/interfaces/ISepehrCallback.sol";
import {ISepehrCore} from "../../src/interfaces/ISepehrCore.sol";
import {ISepehrSubscriptions} from "../../src/interfaces/ISepehrSubscriptions.sol";
import {Percentages} from "../../src/libraries/Percentages.sol";
import {SepehrErrors} from "../../src/libraries/SepehrErrors.sol";
import {SepehrEvents} from "../../src/libraries/SepehrEvents.sol";
import {MockAdapter} from "../../src/mocks/MockAdapter.sol";
import {MockDex} from "../../src/mocks/MockDex.sol";
import {MockFlashLoan} from "../../src/mocks/MockFlashLoan.sol";
import {MockAggregator} from "../helpers/MockAggregator.sol";
import {MockChainlinkAggregator} from "../helpers/MockChainlinkAggregator.sol";
import {SepehrStack} from "../helpers/SepehrStack.sol";

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

contract SepehrCoreTriggersTest is SepehrStack {
    SepehrCore public core;
    SepehrSubscriptions public subs;
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
    /// @dev The target a rescue brings the position back to: rescues may land up to
    /// `TARGET_TOLERANCE` (0.05) above it, so HF_ABOVE_THRESHOLD (1.5) is a full rescue.
    uint256 public constant TARGET_HF = 1.5e18;
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
        (core, subs) = _deployStack(address(this), timelock, guardian, address(usdc), 0, type(uint256).max);

        vm.startPrank(timelock);
        core.addAdapter(PROTOCOL_KEY, address(adapter));
        core.addKeeper(keeper);
        core.addFlashLoanProvider(address(flashLoan));
        core.addDexRouter(address(dex));
        vm.stopPrank();

        // Subscribe alice (Shield tier — monthly)
        usdc.mint(alice, 200e6);
        vm.prank(alice);
        usdc.approve(address(subs), type(uint256).max);
        vm.prank(alice);
        subs.subscribe(1, false);

        adapter.setDelegation(alice, true);

        vm.prank(alice);
        core.enableProtection(PROTOCOL_KEY, THRESHOLD_HF, 250, TARGET_HF);

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
        usdc.approve(address(subs), type(uint256).max);
        vm.prank(bob);
        subs.subscribe(1, false);

        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.BelowMinimumCollateral.selector, 500e8, 1000e8));
        vm.prank(bob);
        core.enableProtection(PROTOCOL_KEY, THRESHOLD_HF, 250, TARGET_HF);
    }

    function test_enableProtection_succeedsWhenCollateralAtMin() public {
        vm.prank(timelock);
        core.setMinCollateralUsd(1000e8);

        adapter.setCollateralValueUsd(bob, 1000e8);
        adapter.setDelegation(bob, true);

        usdc.mint(bob, 200e6);
        vm.prank(bob);
        usdc.approve(address(subs), type(uint256).max);
        vm.prank(bob);
        subs.subscribe(1, false);

        vm.prank(bob);
        core.enableProtection(PROTOCOL_KEY, THRESHOLD_HF, 250, TARGET_HF);

        ISepehrCore.PositionProtection memory p = core.getProtection(bob, PROTOCOL_KEY);
        assertTrue(p.enabled);
    }

    // ─── Lot 6: repay from the wallet ──────────────────────────

    bytes32 internal constant WALLET_KEY = keccak256("WALLET_PROTOCOL");

    /// @dev Alice protected on an adapter that repays to 0xdead and holds the debt token as
    /// collateral (a rescue without a swap).
    function _walletProtected() internal returns (SequentialMockAdapter seq) {
        seq = new SequentialMockAdapter(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        seq.setDelegation(alice, true);
        debtToken.mint(address(seq), REPAY_AMOUNT * 10);
        vm.prank(timelock);
        core.addAdapter(WALLET_KEY, address(seq));
        vm.prank(alice);
        core.enableProtection(WALLET_KEY, THRESHOLD_HF, 250, TARGET_HF);
    }

    function _executeWallet() internal {
        vm.prank(keeper);
        core.execute(
            alice,
            WALLET_KEY,
            address(debtToken),
            address(debtToken),
            REPAY_AMOUNT,
            _buildFlashProviders(),
            address(dex),
            ""
        );
    }

    function test_execute_walletCoversTheRescue_withoutAFlashLoanOrASale() public {
        SequentialMockAdapter seq = _walletProtected();
        uint256 fee = Percentages.applyBps(REPAY_AMOUNT, SHIELD_FEE_BPS);
        debtToken.mint(alice, 10 * REPAY_AMOUNT);
        vm.prank(alice);
        debtToken.approve(address(core), type(uint256).max);
        uint256 lenderBefore = debtToken.balanceOf(address(flashLoan));
        uint256 collateralBefore = debtToken.balanceOf(address(seq));

        vm.expectEmit(true, true, true, true, address(core));
        emit SepehrEvents.RepaidFromWallet(alice, WALLET_KEY, address(debtToken), REPAY_AMOUNT, fee);
        vm.expectEmit(true, true, true, true, address(core));
        emit SepehrEvents.Triggered(
            alice, WALLET_KEY, keeper, REPAY_AMOUNT, 0, HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD, fee
        );
        _executeWallet();

        assertEq(debtToken.balanceOf(alice), 10 * REPAY_AMOUNT - REPAY_AMOUNT - fee, "only repay and fee taken");
        assertEq(debtToken.balanceOf(address(flashLoan)), lenderBefore, "no flash loan");
        assertEq(debtToken.balanceOf(address(seq)), collateralBefore, "no collateral sold");
        assertEq(debtToken.balanceOf(address(0xdead)), REPAY_AMOUNT, "debt repaid");
        assertEq(debtToken.balanceOf(address(core)), fee, "the core keeps exactly the fee");
        assertEq(core.ownerFeeBalances(address(debtToken)) + core.keeperFeeBalances(keeper, address(debtToken)), fee);
    }

    function test_execute_walletCoversPart_aFlashLoanAndTheCollateralTheRest() public {
        SequentialMockAdapter seq = _walletProtected();
        uint256 allowance = REPAY_AMOUNT / 4;
        debtToken.mint(alice, 10 * REPAY_AMOUNT);
        vm.prank(alice);
        debtToken.approve(address(core), allowance);
        uint256 walletRepay = (allowance * 10_000) / (10_000 + SHIELD_FEE_BPS);
        uint256 walletFee = Percentages.applyBps(walletRepay, SHIELD_FEE_BPS);
        uint256 totalFee = Percentages.applyBps(REPAY_AMOUNT, SHIELD_FEE_BPS);
        uint256 flashAmount = REPAY_AMOUNT - walletRepay;
        uint256 flashFee = (flashAmount * flashLoan.feeBps()) / 10_000;
        uint256 lenderBefore = debtToken.balanceOf(address(flashLoan));
        uint256 collateralBefore = debtToken.balanceOf(address(seq));

        vm.expectEmit(true, true, true, true, address(core));
        emit SepehrEvents.RepaidFromWallet(alice, WALLET_KEY, address(debtToken), walletRepay, walletFee);
        _executeWallet();

        assertEq(10 * REPAY_AMOUNT - debtToken.balanceOf(alice), walletRepay + walletFee, "wallet share");
        assertLe(walletRepay + walletFee, allowance, "never past the allowance");
        assertEq(debtToken.balanceOf(address(flashLoan)) - lenderBefore, flashFee, "flash loan of the rest");
        assertEq(
            collateralBefore - debtToken.balanceOf(address(seq)),
            flashAmount + flashFee + totalFee - walletFee,
            "collateral covers the rest and its fee"
        );
        assertEq(debtToken.balanceOf(address(0xdead)), REPAY_AMOUNT, "whole repayment made");
        assertEq(debtToken.balanceOf(address(core)), totalFee, "the core keeps exactly the fee");
    }

    function test_execute_walletShareIsLimitedByTheBalance() public {
        _walletProtected();
        uint256 balance = REPAY_AMOUNT / 10;
        debtToken.mint(alice, balance);
        vm.prank(alice);
        debtToken.approve(address(core), type(uint256).max);
        uint256 walletRepay = (balance * 10_000) / (10_000 + SHIELD_FEE_BPS);

        _executeWallet();

        assertEq(balance - debtToken.balanceOf(alice), walletRepay + Percentages.applyBps(walletRepay, SHIELD_FEE_BPS));
        assertEq(debtToken.balanceOf(address(0xdead)), REPAY_AMOUNT, "whole repayment made");
    }

    function test_execute_withoutAnAllowance_takesNothingFromTheWallet() public {
        _walletProtected();
        debtToken.mint(alice, REPAY_AMOUNT);
        vm.recordLogs();
        _executeWallet();
        assertEq(debtToken.balanceOf(alice), REPAY_AMOUNT, "wallet untouched");
        bytes32 walletEvent = SepehrEvents.RepaidFromWallet.selector;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != walletEvent, "no wallet repayment");
        }
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
        core.enableProtection(seqKey, THRESHOLD_HF, 250, TARGET_HF);

        address[] memory providers = _buildFlashProviders();

        vm.prank(keeper);
        core.execute(alice, seqKey, address(debtToken), address(debtToken), REPAY_AMOUNT, providers, address(dex), "");

        assertEq(seqAdapter.currentHF(), HF_ABOVE_THRESHOLD, "rescue ran");

        // Fee uses per-tier BPS (Shield = 20 bps), in the debt asset. The Shield monthly
        // subscription ($4.99 USDC, 6 decimals) sits in SepehrSubscriptions, not in the core (M-1).
        uint256 totalFee = Percentages.applyBps(REPAY_AMOUNT, SHIELD_FEE_BPS);
        (uint256 ownerShare, uint256 keeperShare) = Percentages.splitFee(totalFee);
        uint256 shieldMonthly = 4_990_000;
        assertEq(core.ownerFeeBalances(address(debtToken)), ownerShare);
        assertEq(core.ownerFeeBalances(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(subs)), shieldMonthly);
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
        core.enableProtection(seqKey, THRESHOLD_HF, 250, TARGET_HF);

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
        core.enableProtection(seqKey, THRESHOLD_HF, 250, TARGET_HF);

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
        // Subscribe bob as Guardian (tier 2) — fee should be 15 bps
        usdc.mint(bob, 200e6);
        vm.prank(bob);
        usdc.approve(address(subs), type(uint256).max);
        vm.prank(bob);
        subs.subscribe(2, false);

        SequentialMockAdapter seqAdapter = new SequentialMockAdapter(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        seqAdapter.setDelegation(bob, true);
        debtToken.mint(address(seqAdapter), REPAY_AMOUNT * 10);

        bytes32 seqKey = keccak256("GUARDIAN_FEE_PROTOCOL");
        vm.prank(timelock);
        core.addAdapter(seqKey, address(seqAdapter));

        vm.prank(bob);
        core.enableProtection(seqKey, THRESHOLD_HF, 250, TARGET_HF);

        address[] memory providers = _buildFlashProviders();

        vm.prank(keeper);
        core.execute(bob, seqKey, address(debtToken), address(debtToken), REPAY_AMOUNT, providers, address(dex), "");

        // Guardian fee = 15 bps, in the debt asset. The subscriptions (Shield $4.99 from setUp +
        // Guardian $14.99 here) sit in SepehrSubscriptions (M-1).
        uint256 totalFee = Percentages.applyBps(REPAY_AMOUNT, 15);
        (uint256 ownerShare, uint256 keeperShare) = Percentages.splitFee(totalFee);
        uint256 subscriptionRevenue = 4_990_000 + 14_990_000;
        assertEq(core.ownerFeeBalances(address(debtToken)), ownerShare);
        assertEq(core.ownerFeeBalances(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(subs)), subscriptionRevenue);
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
        core.enableProtection(seqKey, THRESHOLD_HF, 250, TARGET_HF);

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
        core.enableProtection(seqKey, THRESHOLD_HF, 250, TARGET_HF);

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
        uint256 hfAfter = core.execute(
            alice, seqKey, address(debtToken), address(collateralToken), REPAY_AMOUNT, providers, address(dex), ""
        );
        assertEq(hfAfter, HF_ABOVE_THRESHOLD, "rescue ran");
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
        core.enableProtection(seqKey, THRESHOLD_HF, 250, TARGET_HF);

        vm.prank(timelock);
        core.setStrictOraclePricing(true);

        address[] memory providers = _buildFlashProviders();
        vm.prank(keeper);
        core.execute(alice, seqKey, address(debtToken), address(debtToken), REPAY_AMOUNT, providers, address(dex), "");
        assertEq(seqAdapter.currentHF(), HF_ABOVE_THRESHOLD, "rescue ran");
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
        core.enableProtection(key, THRESHOLD_HF, 250, TARGET_HF);
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

    /// @dev Lot 7: through an aggregator, the keeper's calldata sells a little under what the core
    /// withdraws. The unsold collateral and the output above what the rescue owes go to the user.
    function test_execute_throughAnAggregator_returnsTheUnsoldCollateralAndTheSurplus() public {
        bytes32 seqKey = keccak256("SEQ_AGGREGATOR");
        _setupForSwap(seqKey);
        _registerParityOracles();
        MockAggregator aggregator = new MockAggregator();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MockAggregator.sell.selector;
        AggregatorRouter aggregatorRouter = new AggregatorRouter(address(aggregator), address(aggregator), selectors);
        vm.prank(timelock);
        core.addDexRouter(address(aggregatorRouter));
        debtToken.mint(address(aggregator), REPAY_AMOUNT * 2);

        // Parity oracles, 2.5 % slippage: the core withdraws `owed` grossed up by the slippage.
        uint256 owed = _owed(REPAY_AMOUNT);
        uint256 withdrawn = Math.mulDiv(owed, 10_000, 10_000 - 250, Math.Rounding.Ceil);
        uint256 sold = (withdrawn * 999) / 1000;
        bytes memory route = abi.encodeCall(
            MockAggregator.sell,
            (address(collateralToken), address(debtToken), sold, sold, address(aggregatorRouter), false)
        );
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
            address(aggregatorRouter),
            route
        );

        assertEq(collateralToken.balanceOf(alice) - collateralBefore, withdrawn - sold, "unsold collateral back");
        assertEq(debtToken.balanceOf(alice) - debtBefore, sold - owed, "output above the debt owed back");
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

    // ─── D1/D4: strict mode without a swap ────────────────────────────

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
        core.enableProtection(seqKey, THRESHOLD_HF, 250, TARGET_HF);

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
        core.enableProtection(seqKey, THRESHOLD_HF, 250, TARGET_HF);

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

        assertEq(seqAdapter.currentHF(), HF_ABOVE_THRESHOLD, "rescue ran");
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
        core.enableProtection(keyB, THRESHOLD_HF, 200, TARGET_HF);

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
        subs.unsubscribe();

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
        subs.unsubscribe();
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
        core.enableProtection(keyB, THRESHOLD_HF, 200, TARGET_HF);

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

    // ─── Rescue to a target: partial rescues, no cooldown, upper bound ─────────

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
    ) internal returns (uint256 hfAfter) {
        vm.prank(keeper);
        hfAfter = core.execute(
            alice, key, address(debtToken), address(debtToken), REPAY_AMOUNT, _buildFlashProviders(), address(dex), ""
        );
    }

    /// @dev The keeper sizes its repayment by simulating `execute`: the call returns the HF it left.
    function test_execute_returnsTheHealthFactorAfterTheRescue() public {
        bytes32 key = keccak256("TARGET_RETURN");
        _protectWithSequence(key, HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);

        assertEq(_trigger(key), HF_ABOVE_THRESHOLD);
    }

    /// @dev H-2: a rescue that improves the HF is accepted even when it stops short of the
    /// threshold, which happens when the repay cap is below what the target needs.
    function test_execute_acceptsPartialRescueBelowThreshold() public {
        bytes32 key = keccak256("H2_PARTIAL");
        _protectWithSequence(key, HF_BELOW_THRESHOLD, HF_PARTIAL_RESCUE);

        assertEq(_trigger(key), HF_PARTIAL_RESCUE);
    }

    /// @dev No cooldown: a position a rescue left under its threshold is rescued again at once,
    /// in the same block.
    function test_execute_rescuesAgainAtOnceWhileStillBelowTheThreshold() public {
        bytes32 key = keccak256("TARGET_CHAIN");
        SequentialMockAdapter seqAdapter = _protectWithSequence(key, HF_BELOW_THRESHOLD, HF_PARTIAL_RESCUE);

        assertEq(_trigger(key), HF_PARTIAL_RESCUE);
        seqAdapter.reset(HF_PARTIAL_RESCUE, HF_ABOVE_THRESHOLD);
        assertEq(_trigger(key), HF_ABOVE_THRESHOLD);
    }

    /// @dev Once a rescue has brought the position back above its threshold, the next one needs
    /// the health factor to fall back under it: the threshold-to-target gap replaces the cooldown.
    function test_execute_waitsForANewFallOnceTheRescueClearedTheThreshold() public {
        bytes32 key = keccak256("TARGET_HYSTERESIS");
        SequentialMockAdapter seqAdapter = _protectWithSequence(key, HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        _trigger(key);

        vm.expectRevert(
            abi.encodeWithSelector(SepehrErrors.HealthFactorAboveThreshold.selector, HF_ABOVE_THRESHOLD, THRESHOLD_HF)
        );
        _trigger(key);

        seqAdapter.reset(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        assertEq(_trigger(key), HF_ABOVE_THRESHOLD);
    }

    /// @dev The keeper's fee grows with the amount repaid: a rescue that lifts the HF past the
    /// target plus the tolerance repaid more than the user asked for.
    function test_execute_revertsWhenTheRescueOvershootsTheTarget() public {
        bytes32 key = keccak256("TARGET_OVERSHOOT");
        uint256 ceiling = TARGET_HF + core.TARGET_TOLERANCE();
        _protectWithSequence(key, HF_BELOW_THRESHOLD, ceiling + 1);

        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.RescueOvershootsTarget.selector, ceiling + 1, ceiling));
        _trigger(key);
    }

    function test_execute_acceptsARescueAtTheTargetTolerance() public {
        bytes32 key = keccak256("TARGET_CEILING");
        uint256 ceiling = TARGET_HF + core.TARGET_TOLERANCE();
        _protectWithSequence(key, HF_BELOW_THRESHOLD, ceiling);

        assertEq(_trigger(key), ceiling);
    }

    /// @dev One rescue repays at most `MAX_REPAY_BPS` of the debt, whatever the target needs.
    function test_execute_revertsWhenTheRepayExceedsTheCap() public {
        uint256 debt = REPAY_AMOUNT * 10;
        adapter.setDebt(alice, address(debtToken), debt);
        uint256 cap = (debt * core.MAX_REPAY_BPS()) / 10_000;

        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.MaxRepayExceeded.selector, cap + 1, cap));
        vm.prank(keeper);
        core.execute(
            alice,
            PROTOCOL_KEY,
            address(debtToken),
            address(debtToken),
            cap + 1,
            _buildFlashProviders(),
            address(dex),
            ""
        );
    }

    function test_execute_acceptsARepayAtTheCap() public {
        bytes32 key = keccak256("TARGET_CAP");
        SequentialMockAdapter seqAdapter = _protectWithSequence(key, HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        // SequentialMockAdapter owes 1,000,000e18: half of it is the cap. The flash loan lends it,
        // and the adapter's collateral pays the loan and the fee back.
        uint256 cap = (1_000_000e18 * core.MAX_REPAY_BPS()) / 10_000;
        debtToken.mint(address(flashLoan), cap);
        debtToken.mint(address(seqAdapter), cap * 2);

        vm.prank(keeper);
        uint256 hfAfter = core.execute(
            alice, key, address(debtToken), address(debtToken), cap, _buildFlashProviders(), address(dex), ""
        );
        assertEq(hfAfter, HF_ABOVE_THRESHOLD);
    }

    // ─── Protection parameters: the target ─────────

    function test_enableProtection_storesTheTargetAndEmitsIt() public {
        bytes32 key = keccak256("TARGET_STORED");
        MockAdapter other = new MockAdapter();
        other.setDelegation(alice, true);
        vm.prank(timelock);
        core.addAdapter(key, address(other));

        vm.expectEmit(true, true, false, true, address(core));
        emit SepehrEvents.ProtectionEnabled(alice, key, THRESHOLD_HF, 250, TARGET_HF);
        vm.prank(alice);
        core.enableProtection(key, THRESHOLD_HF, 250, TARGET_HF);

        ISepehrCore.PositionProtection memory prot = core.getProtection(alice, key);
        assertEq(prot.thresholdHF, THRESHOLD_HF);
        assertEq(prot.targetHF, TARGET_HF);
    }

    /// @dev The target must sit `MIN_TARGET_GAP` above the threshold: the gap is what stops a
    /// rescue from being followed by another as soon as the price twitches.
    function test_enableProtection_revertsWhenTheTargetIsTooCloseToTheThreshold() public {
        bytes32 key = keccak256("TARGET_TOO_CLOSE");
        MockAdapter other = new MockAdapter();
        other.setDelegation(alice, true);
        vm.prank(timelock);
        core.addAdapter(key, address(other));
        uint256 minimum = THRESHOLD_HF + core.MIN_TARGET_GAP();

        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.TargetTooLow.selector, minimum - 1, minimum));
        vm.prank(alice);
        core.enableProtection(key, THRESHOLD_HF, 250, minimum - 1);

        vm.prank(alice);
        core.enableProtection(key, THRESHOLD_HF, 250, minimum);
        assertEq(core.getProtection(alice, key).targetHF, minimum);
    }

    function test_enableProtection_revertsWhenTheTargetIsTooHigh() public {
        bytes32 key = keccak256("TARGET_TOO_HIGH");
        MockAdapter other = new MockAdapter();
        other.setDelegation(alice, true);
        vm.prank(timelock);
        core.addAdapter(key, address(other));
        uint256 maximum = core.MAX_TARGET_HF();

        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.TargetTooHigh.selector, maximum + 1, maximum));
        vm.prank(alice);
        core.enableProtection(key, THRESHOLD_HF, 250, maximum + 1);

        vm.prank(alice);
        core.enableProtection(key, THRESHOLD_HF, 250, maximum);
        assertEq(core.getProtection(alice, key).targetHF, maximum);
    }

    function test_updateProtection_validatesAndStoresTheTarget() public {
        uint256 minimum = THRESHOLD_HF + core.MIN_TARGET_GAP();
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.TargetTooLow.selector, THRESHOLD_HF, minimum));
        vm.prank(alice);
        core.updateProtection(PROTOCOL_KEY, THRESHOLD_HF, 250, THRESHOLD_HF);

        vm.expectEmit(true, true, false, true, address(core));
        emit SepehrEvents.ProtectionUpdated(alice, PROTOCOL_KEY, THRESHOLD_HF, 250, 2e18);
        vm.prank(alice);
        core.updateProtection(PROTOCOL_KEY, THRESHOLD_HF, 250, 2e18);
        assertEq(core.getProtection(alice, PROTOCOL_KEY).targetHF, 2e18);
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
        core.enableProtection(seqKey, THRESHOLD_HF, 250, TARGET_HF);

        debtToken.mint(address(flashLoan), REPAY_AMOUNT * 10);
        vm.prank(keeper);
        core.execute(alice, seqKey, address(debtToken), address(debtToken), REPAY_AMOUNT, providers, address(dex), "");
    }

    // ─── Protection settings the core refuses ──────────────────

    function test_enableProtection_revertsWhenAlreadyEnabled() public {
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.ProtectionAlreadyEnabled.selector, alice, PROTOCOL_KEY));
        vm.prank(alice);
        core.enableProtection(PROTOCOL_KEY, THRESHOLD_HF, 250, TARGET_HF);
    }

    function test_enableProtection_revertsWithoutADelegation() public {
        bytes32 key = keccak256("UNDELEGATED");
        MockAdapter undelegated = new MockAdapter();
        vm.prank(timelock);
        core.addAdapter(key, address(undelegated));

        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.DelegationRevoked.selector, alice, key));
        vm.prank(alice);
        core.enableProtection(key, THRESHOLD_HF, 250, TARGET_HF);
    }

    function test_enableProtection_revertsOnAnUnregisteredAdapter() public {
        bytes32 key = keccak256("UNREGISTERED");
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.AdapterNotRegistered.selector, key));
        vm.prank(alice);
        core.enableProtection(key, THRESHOLD_HF, 250, TARGET_HF);
    }

    function test_enableProtection_revertsOnADisabledAdapter() public {
        vm.prank(timelock);
        core.setAdapterEnabled(PROTOCOL_KEY, false);

        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.AdapterDisabled.selector, PROTOCOL_KEY));
        vm.prank(alice);
        core.enableProtection(PROTOCOL_KEY, THRESHOLD_HF, 250, TARGET_HF);
    }

    function test_enableProtection_revertsUnderTheMinimumThreshold() public {
        uint256 threshold = core.MIN_HF_THRESHOLD() - 1;
        vm.expectRevert(
            abi.encodeWithSelector(SepehrErrors.ThresholdTooLow.selector, threshold, core.MIN_HF_THRESHOLD())
        );
        vm.prank(alice);
        core.enableProtection(keccak256("ANY"), threshold, 250, TARGET_HF);
    }

    function test_enableProtection_revertsOverTheMaximumSlippage() public {
        uint256 bps = core.MAX_SLIPPAGE_BPS() + 1;
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.InvalidSlippage.selector, bps));
        vm.prank(alice);
        core.enableProtection(keccak256("ANY"), THRESHOLD_HF, bps, TARGET_HF);
    }

    function test_updateProtection_revertsWithoutAProtection() public {
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.ProtectionNotEnabled.selector, bob, PROTOCOL_KEY));
        vm.prank(bob);
        core.updateProtection(PROTOCOL_KEY, THRESHOLD_HF, 250, TARGET_HF);
    }

    function test_disableProtection_revertsWithoutAProtection() public {
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.ProtectionNotEnabled.selector, bob, PROTOCOL_KEY));
        vm.prank(bob);
        core.disableProtection(PROTOCOL_KEY);
    }

    // ─── Flash loan callback and swap output ───────────────────

    function test_onFlashLoan_revertsOutsideARescue() public {
        vm.expectRevert(SepehrErrors.InvalidFlashLoanCallback.selector);
        vm.prank(bob);
        core.onFlashLoan(address(debtToken), REPAY_AMOUNT, 0, "");
    }

    /// @dev H28: a whitelisted provider that calls back with another amount than it lent.
    function test_execute_revertsWhenTheProviderAltersTheLoan() public {
        AlteringFlashLoan altering = new AlteringFlashLoan();
        vm.prank(timelock);
        core.addFlashLoanProvider(address(altering));
        address[] memory providers = new address[](1);
        providers[0] = address(altering);

        vm.expectRevert(SepehrErrors.InvalidFlashLoanCallback.selector);
        vm.prank(keeper);
        core.execute(
            alice, PROTOCOL_KEY, address(debtToken), address(debtToken), REPAY_AMOUNT, providers, address(dex), ""
        );
    }

    /// @dev L-2: the core measures what the router delivered, not what it reports.
    function test_execute_revertsWhenTheRouterDeliversLessThanTheFloor() public {
        bytes32 seqKey = keccak256("SEQ_SHORT_CHANGE");
        _setupForSwap(seqKey);
        _registerParityOracles();
        LeftoverDex shortChanging = new LeftoverDex();
        shortChanging.configure(10_000, 0.9e18);
        debtToken.mint(address(shortChanging), REPAY_AMOUNT * 2);
        vm.prank(timelock);
        core.addDexRouter(address(shortChanging));

        vm.expectPartialRevert(SepehrErrors.SlippageExceeded.selector);
        vm.prank(keeper);
        core.execute(
            alice,
            seqKey,
            address(debtToken),
            address(collateralToken),
            REPAY_AMOUNT,
            _buildFlashProviders(),
            address(shortChanging),
            ""
        );
    }

    // ─── Fee withdrawals ────────────────────────────────────────

    /// @dev One Shield rescue of REPAY_AMOUNT; returns the owner's and the keeper's shares.
    function _rescueForFees() internal returns (uint256 ownerShare, uint256 keeperShare) {
        SequentialMockAdapter seqAdapter = new SequentialMockAdapter(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        seqAdapter.setDelegation(alice, true);
        debtToken.mint(address(seqAdapter), REPAY_AMOUNT * 10);
        bytes32 seqKey = keccak256("SEQ_FEES");
        _protectWith(seqKey, address(seqAdapter));

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
        return Percentages.splitFee(Percentages.applyBps(REPAY_AMOUNT, SHIELD_FEE_BPS));
    }

    function test_withdrawOwnerFees_sendsTheOwnerShareToTheOwner() public {
        (uint256 ownerShare,) = _rescueForFees();
        uint256 before = debtToken.balanceOf(address(this));

        vm.expectEmit(true, true, false, true, address(core));
        emit SepehrEvents.OwnerFeesWithdrawn(address(debtToken), address(this), ownerShare);
        core.withdrawOwnerFees(address(debtToken));

        assertEq(debtToken.balanceOf(address(this)) - before, ownerShare);
        assertEq(core.ownerFeeBalances(address(debtToken)), 0);
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        core.withdrawOwnerFees(address(debtToken));
    }

    function test_withdrawOwnerFees_revertsForAnyoneButTheOwner() public {
        _rescueForFees();
        vm.expectRevert(SepehrErrors.NotOwner.selector);
        vm.prank(keeper);
        core.withdrawOwnerFees(address(debtToken));
    }

    function test_withdrawOwnerFees_revertsOnTheZeroAsset() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        core.withdrawOwnerFees(address(0));
    }

    function test_withdrawKeeperFees_paysTheKeeperItsShare() public {
        (, uint256 keeperShare) = _rescueForFees();

        vm.expectEmit(true, true, false, true, address(core));
        emit SepehrEvents.KeeperFeesWithdrawn(keeper, address(debtToken), keeperShare);
        vm.prank(keeper);
        core.withdrawKeeperFees(address(debtToken));

        assertEq(debtToken.balanceOf(keeper), keeperShare);
        assertEq(core.keeperFeeBalances(keeper, address(debtToken)), 0);
    }

    function test_withdrawKeeperFees_revertsWithoutFeesOrOnTheZeroAsset() public {
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        vm.prank(bob);
        core.withdrawKeeperFees(address(debtToken));

        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        vm.prank(keeper);
        core.withdrawKeeperFees(address(0));
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

/// @dev H28: a whitelisted provider that calls the core back with another amount than it lent.
contract AlteringFlashLoan is IFlashLoanProvider {
    function flashBorrow(
        address asset,
        uint256 amount,
        address callback,
        bytes calldata data
    ) external {
        ISepehrCallback(callback).onFlashLoan(asset, amount - 1, 0, data);
    }

    function getFlashLoanFeeBps(
        address
    ) external pure returns (uint256) {
        return 0;
    }

    function isAvailable(
        address,
        uint256
    ) external pure returns (bool) {
        return true;
    }
}
