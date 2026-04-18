// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IDexRouter} from "./interfaces/IDexRouter.sol";
import {IFlashLoanProvider} from "./interfaces/IFlashLoanProvider.sol";
import {IProtocolAdapter} from "./interfaces/IProtocolAdapter.sol";
import {ISepehrCallback} from "./interfaces/ISepehrCallback.sol";
import {ISepehrCore} from "./interfaces/ISepehrCore.sol";
import {HealthFactorMath} from "./libraries/HealthFactorMath.sol";
import {Percentages} from "./libraries/Percentages.sol";
import {SepehrErrors} from "./libraries/SepehrErrors.sol";
import {SepehrEvents} from "./libraries/SepehrEvents.sol";

contract SepehrCore is ISepehrCore, ISepehrCallback, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Constants ───────────────────────────────────────────────
    uint256 public constant MIN_HF_THRESHOLD = 1.2e18;
    uint256 public constant MAX_REPAY_BPS = 5000;
    /// @notice Maximum slippage a user may configure for collateral→debt swaps during triggers.
    /// @dev Capped at 3% because the swap route and router are keeper-controlled: wider caps
    /// permit a keeper to sandwich their own trigger and capture the difference as MEV. 3% is
    /// the industry-typical upper bound for distressed-position swaps; above this, the keeper
    /// should simulate with a tighter bound off-chain.
    uint256 public constant MAX_SLIPPAGE_BPS = 300;
    uint256 public constant COOLDOWN_SECONDS = 3600;
    uint256 public constant MONTHLY_PERIOD = 30 days;
    uint256 public constant ANNUAL_PERIOD = 365 days;

    /// @notice Hard ceiling on any per-tier trigger fee. A8: `setTierFeeBps` must not be able to
    /// raise the fee beyond this value, because existing subscribers cannot revoke faster than
    /// the timelock can propose — a compromised/malicious timelock proposal could otherwise set
    /// a fee of e.g. 99.99% and capture user collateral on every trigger. 100 bps = 1% is well
    /// above the highest launched tier (20 bps); anything above this requires a contract
    /// migration rather than a parameter tweak.
    uint256 public constant MAX_TIER_FEE_BPS = 100;

    /// @notice Maximum duration a single `pause()` call may freeze the contract. A11: without an
    /// auto-expiry a compromised owner/guardian key can permanently censor protections; the
    /// contract must eventually un-freeze itself so users can at least unsubscribe and call
    /// `disableProtection` without waiting on a human. 7 days is long enough for a legitimate
    /// incident response (timelock + review) and short enough to avoid indefinite lockout.
    uint256 public constant MAX_PAUSE_DURATION = 7 days;

    uint256[3] public TIER_PRICES_MONTHLY_USD_6 = [
        9_000_000, // Shield: $9/mo
        49_000_000, // Guardian: $49/mo
        200_000_000 // Watchtower: $200/mo
    ];

    uint256[3] public TIER_PRICES_ANNUAL_USD_6 = [
        86_400_000, // Shield: $86.40/yr
        470_400_000, // Guardian: $470.40/yr
        1_920_000_000 // Watchtower: $1,920/yr
    ];

    uint256[4] public TIER_FEE_BPS = [
        20, // Shield: 0.20%
        10, // Guardian: 0.10%
        5, // Watchtower: 0.05%
        5 // Titan: 0.05%
    ];

    uint256[4] public TIER_MAX_COLLATERAL_USD_8 = [
        15_000e8, // Shield: up to $15k
        100_000e8, // Guardian: up to $100k
        300_000e8, // Watchtower: up to $300k
        type(uint256).max // Titan: unlimited
    ];

    // ─── State ───────────────────────────────────────────────────
    IERC20 public immutable usdc;
    address public pauseGuardian;
    address public timelock;
    /// @notice Timestamp until which the contract is paused. A11: represented as an absolute
    /// timestamp rather than a boolean so that every `pause()` has an auto-expiry, preventing
    /// indefinite lockout even if the owner/guardian disappears or is compromised.
    uint256 public pausedUntil;
    /// @notice Minimum collateral (USD-8) required to enable protection on any position.
    /// A7: timelock-gated gate against abusing cheap/free tiers with dust positions. Set to 0
    /// to disable the gate entirely.
    uint256 public minCollateralUsd;

    mapping(address => bool) public keepers;
    mapping(bytes32 => AdapterEntry) public adapters;
    mapping(address => bool) public allowedFlashProviders;
    mapping(address => bool) public allowedDexRouters;

    struct AdapterEntry {
        IProtocolAdapter adapter;
        bool enabled;
        uint256 addedAt;
    }

    mapping(address => Subscription) internal _subscriptions;
    mapping(address => mapping(bytes32 => PositionProtection)) internal _protections;
    mapping(address => uint256) public lastTriggerTime;

    /// @notice Accrued protocol-owner revenue per token address (debt asset of triggers, USDC for subscriptions).
    /// @dev Per-asset accounting is mandatory because trigger fees accrue in whatever debt asset the user
    /// was borrowing (DAI, WETH, USDT, …), while subscriptions always accrue in USDC. Collapsing these
    /// into a single accumulator would conflate denominations.
    mapping(address asset => uint256 amount) public ownerFeeBalances;

    /// @notice Accrued keeper revenue per keeper and per asset (debt asset of the trigger).
    mapping(address keeper => mapping(address asset => uint256 amount)) public keeperFeeBalances;

    mapping(address => uint256) public saveCredits;

    address private _activeFlashProvider;
    bytes32 private _activeSessionHash;

    // ─── Modifiers ───────────────────────────────────────────────
    modifier whenNotPaused() {
        if (block.timestamp < pausedUntil) revert SepehrErrors.ContractPaused();
        _;
    }

    modifier onlyKeeper() {
        if (!keepers[msg.sender]) revert SepehrErrors.NotKeeper();
        _;
    }

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert SepehrErrors.NotTimelock();
        _;
    }

    modifier onlyPauseGuardianOrOwner() {
        if (msg.sender != pauseGuardian && msg.sender != owner()) {
            revert SepehrErrors.NotPauseGuardian();
        }
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────
    /// @param _owner initial protocol owner (holds `onlyOwner` + fee-withdraw rights).
    /// @param _timelock 48h-delay governance contract; sole caller of every admin mutation.
    /// @param _pauseGuardian address able to pause alongside the owner for rapid incident response.
    /// @param _usdc subscription payment token.
    /// @param _minCollateralUsd minimum USD-8 collateral required at `enableProtection`; 0 disables.
    /// @dev A6: the legacy `_subscriptionOracle` constructor slot was removed because the oracle
    /// was never read. Per-position USD value comes from `adapter.getCollateralValueUsd()`, which
    /// already exists for the tier-cap path and is trust-minimized by timelock-registered adapters.
    constructor(
        address _owner,
        address _timelock,
        address _pauseGuardian,
        address _usdc,
        uint256 _minCollateralUsd
    ) Ownable(_owner) {
        if (_timelock == address(0)) revert SepehrErrors.ZeroAddress();
        if (_pauseGuardian == address(0)) revert SepehrErrors.ZeroAddress();
        if (_usdc == address(0)) revert SepehrErrors.ZeroAddress();

        timelock = _timelock;
        pauseGuardian = _pauseGuardian;
        usdc = IERC20(_usdc);
        minCollateralUsd = _minCollateralUsd;
    }

    // ─── User: Subscriptions ─────────────────────────────────────

    /// @inheritdoc ISepehrCore
    function subscribe(
        uint8 tier,
        bool annual
    ) external override nonReentrant whenNotPaused {
        if (tier == 0 || tier > 4) revert SepehrErrors.InvalidTier();
        if (tier == 4) revert SepehrErrors.TitanSelfSubscribeNotAllowed();
        if (_subscriptions[msg.sender].expiresAt > block.timestamp) {
            revert SepehrErrors.SubscriptionAlreadyActive();
        }

        uint256 price = annual ? TIER_PRICES_ANNUAL_USD_6[tier - 1] : TIER_PRICES_MONTHLY_USD_6[tier - 1];
        usdc.safeTransferFrom(msg.sender, address(this), price);
        ownerFeeBalances[address(usdc)] += price;

        uint256 duration = annual ? ANNUAL_PERIOD : MONTHLY_PERIOD;
        _subscriptions[msg.sender] = Subscription({
            tier: tier, annual: annual, expiresAt: block.timestamp + duration, collateralValueUsdSnapshot: 0
        });

        emit SepehrEvents.Subscribed(msg.sender, block.timestamp + duration, tier, annual, block.chainid);
    }

    /// @inheritdoc ISepehrCore
    function renew() external override nonReentrant whenNotPaused {
        Subscription storage sub = _subscriptions[msg.sender];
        if (sub.tier == 0) revert SepehrErrors.SubscriptionNotFound();
        if (sub.tier == 4) revert SepehrErrors.TitanSelfSubscribeNotAllowed();

        uint256 price = sub.annual ? TIER_PRICES_ANNUAL_USD_6[sub.tier - 1] : TIER_PRICES_MONTHLY_USD_6[sub.tier - 1];
        usdc.safeTransferFrom(msg.sender, address(this), price);
        ownerFeeBalances[address(usdc)] += price;

        uint256 duration = sub.annual ? ANNUAL_PERIOD : MONTHLY_PERIOD;
        uint256 baseTime = sub.expiresAt > block.timestamp ? sub.expiresAt : block.timestamp;
        sub.expiresAt = baseTime + duration;

        emit SepehrEvents.Renewed(msg.sender, sub.expiresAt, sub.tier, sub.annual);
    }

    /// @inheritdoc ISepehrCore
    /// @dev H25: on early cancellation we refund the pro-rata unused portion of the remaining
    /// subscription in USDC. Previously an `unsubscribe` simply deleted the record and the user
    /// forfeited all prepaid time — equivalent to a silent penalty for cancelling. Refunds are
    /// bounded by the outstanding `ownerFeeBalances[USDC]` so the protocol can never over-pay if
    /// the treasury has already been drained via `withdrawOwnerFees`. Titan grants (tier 4) are
    /// owner-gifted and therefore never refunded.
    function unsubscribe() external override nonReentrant {
        Subscription storage sub = _subscriptions[msg.sender];
        if (sub.tier == 0) revert SepehrErrors.SubscriptionNotFound();

        uint256 refund;
        if (sub.tier != 4 && sub.expiresAt > block.timestamp) {
            uint256 remaining = sub.expiresAt - block.timestamp;
            uint256 duration = sub.annual ? ANNUAL_PERIOD : MONTHLY_PERIOD;
            uint256 price =
                sub.annual ? TIER_PRICES_ANNUAL_USD_6[sub.tier - 1] : TIER_PRICES_MONTHLY_USD_6[sub.tier - 1];
            refund = (price * remaining) / duration;
            uint256 avail = ownerFeeBalances[address(usdc)];
            if (refund > avail) refund = avail;
            if (refund > 0) ownerFeeBalances[address(usdc)] -= refund;
        }

        delete _subscriptions[msg.sender];

        if (refund > 0) {
            usdc.safeTransfer(msg.sender, refund);
        }
        emit SepehrEvents.Unsubscribed(msg.sender);
    }

    // ─── User: Position Protection ──────────────────────────────

    /// @inheritdoc ISepehrCore
    function enableProtection(
        bytes32 protocolKey,
        uint256 thresholdHF,
        uint256 maxSlippageBps,
        uint256 repayPercentBps
    ) external override whenNotPaused {
        _requireActiveSubscription(msg.sender);
        _validateProtectionParams(thresholdHF, maxSlippageBps, repayPercentBps);

        AdapterEntry storage entry = adapters[protocolKey];
        if (address(entry.adapter) == address(0)) revert SepehrErrors.AdapterNotRegistered(protocolKey);
        if (!entry.enabled) revert SepehrErrors.AdapterDisabled(protocolKey);

        if (_protections[msg.sender][protocolKey].enabled) {
            revert SepehrErrors.ProtectionAlreadyEnabled(msg.sender, protocolKey);
        }

        if (!entry.adapter.checkDelegation(msg.sender)) {
            revert SepehrErrors.DelegationRevoked(msg.sender, protocolKey);
        }

        // A7: minimum-collateral gate. The gate was specified in the error library but never
        // thrown — so a user could subscribe to the free/cheap tiers with a dust position and
        // waste keeper gas on forever-unprofitable triggers. `minCollateralUsd == 0` is
        // treated as "disabled" so test fixtures and initial deploys can opt out.
        if (minCollateralUsd != 0) {
            uint256 collateralUsd = entry.adapter.getCollateralValueUsd(msg.sender);
            if (collateralUsd < minCollateralUsd) {
                revert SepehrErrors.BelowMinimumCollateral(collateralUsd, minCollateralUsd);
            }
        }

        _protections[msg.sender][protocolKey] = PositionProtection({
            enabled: true, thresholdHF: thresholdHF, maxSlippageBps: maxSlippageBps, repayPercentBps: repayPercentBps
        });

        emit SepehrEvents.ProtectionEnabled(msg.sender, protocolKey, thresholdHF, maxSlippageBps, repayPercentBps);
    }

    /// @inheritdoc ISepehrCore
    function disableProtection(
        bytes32 protocolKey
    ) external override {
        if (!_protections[msg.sender][protocolKey].enabled) {
            revert SepehrErrors.ProtectionNotEnabled(msg.sender, protocolKey);
        }
        delete _protections[msg.sender][protocolKey];
        emit SepehrEvents.ProtectionDisabled(msg.sender, protocolKey);
    }

    /// @inheritdoc ISepehrCore
    function updateProtection(
        bytes32 protocolKey,
        uint256 thresholdHF,
        uint256 maxSlippageBps,
        uint256 repayPercentBps
    ) external override whenNotPaused {
        if (!_protections[msg.sender][protocolKey].enabled) {
            revert SepehrErrors.ProtectionNotEnabled(msg.sender, protocolKey);
        }
        _validateProtectionParams(thresholdHF, maxSlippageBps, repayPercentBps);

        PositionProtection storage prot = _protections[msg.sender][protocolKey];
        prot.thresholdHF = thresholdHF;
        prot.maxSlippageBps = maxSlippageBps;
        prot.repayPercentBps = repayPercentBps;

        emit SepehrEvents.ProtectionUpdated(msg.sender, protocolKey, thresholdHF, maxSlippageBps, repayPercentBps);
    }

    // ─── Keeper: Trigger ─────────────────────────────────────────

    /// @inheritdoc ISepehrCore
    function execute(
        address user,
        bytes32 protocolKey,
        address debtAsset,
        address collateralAsset,
        uint256 repayAmount,
        uint256 repayValueUsd6,
        address[] calldata flashProviders,
        address dexRouter,
        bytes calldata dexRouteData
    ) external override nonReentrant whenNotPaused onlyKeeper {
        _requireActiveSubscription(user);

        PositionProtection storage prot = _protections[user][protocolKey];
        if (!prot.enabled) revert SepehrErrors.ProtectionNotEnabled(user, protocolKey);

        AdapterEntry storage entry = adapters[protocolKey];
        if (address(entry.adapter) == address(0)) revert SepehrErrors.AdapterNotRegistered(protocolKey);
        if (!entry.enabled) revert SepehrErrors.AdapterDisabled(protocolKey);

        if (!entry.adapter.checkDelegation(user)) {
            revert SepehrErrors.DelegationRevoked(user, protocolKey);
        }

        uint256 timeSinceLast = block.timestamp - lastTriggerTime[user];
        if (timeSinceLast < COOLDOWN_SECONDS) {
            revert SepehrErrors.CooldownActive(COOLDOWN_SECONDS - timeSinceLast);
        }

        uint256 hfBefore = entry.adapter.getHealthFactor(user);
        if (hfBefore >= prot.thresholdHF) {
            revert SepehrErrors.HealthFactorAboveThreshold(hfBefore, prot.thresholdHF);
        }

        // H01: enforce the tier's collateral-value cap at the moment of execution. Checking
        // only at subscription would let a user grow their position after subscribing and
        // receive protection beyond what their tier economically justifies. Titan (tier 4) has
        // an unbounded cap (type(uint256).max) and is skipped.
        {
            uint256 tierCap = TIER_MAX_COLLATERAL_USD_8[_subscriptions[user].tier - 1];
            if (tierCap != type(uint256).max) {
                uint256 collateralUsd = entry.adapter.getCollateralValueUsd(user);
                if (collateralUsd > tierCap) {
                    revert SepehrErrors.TierCollateralCapExceeded(collateralUsd, tierCap);
                }
            }
        }

        if (repayAmount == 0) revert SepehrErrors.ZeroAmount();

        // H02: enforce the user's `repayPercentBps` limit. The user constrains how much of their
        // outstanding debt Sepehr may close in a single trigger (e.g. "never touch more than
        // 25% at once"), which protects them from a keeper that over-repays and drains their
        // position. `getDebt` may return 0 for adapters that cannot read debt in a single call
        // (per-vault models where debt is partitioned across positions, etc.); in that case we short-circuit the percent check —
        // the flash loan + adapter.repay() would still fail on any amount exceeding true debt,
        // but the percent-of-debt guarantee is downgraded to "whatever the protocol permits".
        {
            uint256 userDebt = entry.adapter.getDebt(user, debtAsset);
            if (userDebt != 0) {
                uint256 allowed = (userDebt * prot.repayPercentBps) / 10_000;
                if (repayAmount > allowed) {
                    revert SepehrErrors.RepayExceedsUserLimit(repayAmount, allowed);
                }
            }
        }

        if (!allowedDexRouters[dexRouter]) revert SepehrErrors.NotAuthorized();

        lastTriggerTime[user] = block.timestamp;

        uint256 userFeeBps = TIER_FEE_BPS[_subscriptions[user].tier - 1];
        bytes memory callbackData = abi.encode(
            user,
            protocolKey,
            debtAsset,
            collateralAsset,
            repayAmount,
            dexRouter,
            dexRouteData,
            prot.maxSlippageBps,
            userFeeBps
        );

        // H28: bind the callback session not just to the payload hash but also to the asset and
        // amount the flash-loan provider is expected to deliver. A malicious whitelisted provider
        // that tried to invoke onFlashLoan with a different asset/amount than execute() requested
        // would fail the equality check below.
        _activeSessionHash = keccak256(abi.encode(keccak256(callbackData), debtAsset, repayAmount));
        _borrowFlashLoan(flashProviders, debtAsset, repayAmount, callbackData);
        _activeSessionHash = bytes32(0);

        uint256 hfAfter = entry.adapter.getHealthFactor(user);
        if (hfAfter < prot.thresholdHF) {
            revert SepehrErrors.PostExecutionHFBelowThreshold(hfAfter, prot.thresholdHF);
        }
        // H09: require strict HF improvement. A trigger that leaves HF unchanged (or regressed
        // due to a stale adapter price cache) is ineffective, and charging fees for a no-op would
        // constitute unjust enrichment of keeper + owner at the user's expense.
        if (hfAfter <= hfBefore) {
            revert SepehrErrors.HealthFactorNotImproved(hfBefore, hfAfter);
        }

        uint256 totalFee = Percentages.applyBps(repayAmount, userFeeBps);
        (uint256 ownerShare, uint256 keeperShare) = Percentages.splitFee(totalFee);

        // Fees accrue in the debt asset of this trigger. Per-asset accounting is required because
        // debt assets vary across protocols (DAI, WETH, USDT, crvUSD, …); a single uint counter
        // would mix denominations and corrupt withdrawal math.
        ownerFeeBalances[debtAsset] += ownerShare;
        keeperFeeBalances[msg.sender][debtAsset] += keeperShare;

        saveCredits[user] += repayValueUsd6;

        emit SepehrEvents.Triggered(user, protocolKey, msg.sender, repayAmount, 0, hfBefore, hfAfter, totalFee);
        emit SepehrEvents.FeeCollected(msg.sender, totalFee, ownerShare, keeperShare);
        emit SepehrEvents.SaveCreditAccrued(user, repayValueUsd6, saveCredits[user]);
    }

    // ─── Flash Loan Callback ─────────────────────────────────────

    /// @inheritdoc ISepehrCallback
    function onFlashLoan(
        address asset,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override {
        if (msg.sender != _activeFlashProvider) {
            revert SepehrErrors.InvalidFlashLoanCallback();
        }
        // H28: session hash binds the payload AND the (asset, amount) pair so a whitelisted but
        // misbehaving provider cannot substitute arguments mid-flight.
        bytes32 expectedHash = keccak256(abi.encode(keccak256(data), asset, amount));
        if (expectedHash != _activeSessionHash) {
            revert SepehrErrors.InvalidFlashLoanCallback();
        }
        // H06: consume the session immediately. A nested re-entry into onFlashLoan (via a
        // misbehaving adapter or DEX router that calls back into us) would see a zero session
        // hash and revert. execute() already re-zeroes these after `_borrowFlashLoan`, so
        // double-clearing is safe.
        _activeFlashProvider = address(0);
        _activeSessionHash = bytes32(0);

        (
            address user,
            bytes32 protocolKey,
            address debtAsset,
            address collateralAsset,
            uint256 repayAmount,
            address dexRouter,
            bytes memory dexRouteData,
            uint256 maxSlippageBps,
            uint256 triggerFeeBps
        ) = abi.decode(data, (address, bytes32, address, address, uint256, address, bytes, uint256, uint256));

        IProtocolAdapter adapter = adapters[protocolKey].adapter;

        IERC20(debtAsset).safeTransfer(address(adapter), repayAmount);
        adapter.repay(user, debtAsset, repayAmount);

        uint256 collateralNeeded = repayAmount + fee + Percentages.applyBpsRoundUp(repayAmount, triggerFeeBps);
        adapter.withdrawCollateral(user, collateralAsset, collateralNeeded, address(this));

        if (collateralAsset != debtAsset) {
            // H23: `minOut` is the exact amount needed to repay the flash loan. It is passed
            // directly to the router so the router's own min-out check enforces the floor. The
            // previous code computed `minOutWithSlippage = minOut - slippage`, passed that to
            // the router, then re-asserted on the un-slipped `minOut` — double-deducting the
            // slippage margin and making the user-supplied `maxSlippageBps` effectively
            // unreachable. `maxSlippageBps` is silenced intentionally here; it is still
            // validated in _validateProtectionParams (bounded by MAX_SLIPPAGE_BPS) so that an
            // upcoming off-chain price-oracle check can consume it. See H23 in the audit.
            maxSlippageBps;
            uint256 minOut = repayAmount + fee;
            IERC20(collateralAsset).safeIncreaseAllowance(dexRouter, collateralNeeded);
            uint256 received =
                IDexRouter(dexRouter).swap(collateralAsset, debtAsset, collateralNeeded, minOut, dexRouteData);
            // H07: zero the allowance after the swap so a residual approval cannot be drained
            // later if the router holds onto it. forceApprove handles tokens that require the
            // allowance to be reset to zero before being changed.
            IERC20(collateralAsset).forceApprove(dexRouter, 0);

            if (received < minOut) {
                revert SepehrErrors.SlippageExceeded(received, minOut);
            }
            // H10: if the swap returns more than needed to repay the flash loan, sweep the
            // surplus into owner fees so the protocol captures positive MEV instead of leaving
            // it idle in the contract (where it would be uncredited and unrecoverable via the
            // per-asset owner-fee withdraw path).
            uint256 surplus = received - minOut;
            if (surplus > 0) {
                ownerFeeBalances[debtAsset] += surplus;
            }
        }

        IERC20(asset).safeTransfer(msg.sender, amount + fee);
    }

    // ─── Fees ────────────────────────────────────────────────────

    /// @notice Withdraw the protocol owner's accrued revenue for a specific asset to the
    /// current owner address.
    /// @dev A10: the recipient is hardcoded to `owner()` so a compromised owner key cannot
    /// extract fees to an arbitrary wallet. Changing the destination requires `transferOwnership`
    /// + `acceptOwnership` (Ownable2Step), which gives the outgoing key at least one block of
    /// observability. Per-asset accounting is preserved (subscription USDC vs. per-debt-asset
    /// trigger revenue). Reverts if the per-asset balance is zero.
    /// @param asset The ERC-20 address to withdraw.
    function withdrawOwnerFees(
        address asset
    ) external nonReentrant {
        if (msg.sender != owner()) revert SepehrErrors.NotOwner();
        if (asset == address(0)) revert SepehrErrors.ZeroAddress();
        uint256 amount = ownerFeeBalances[asset];
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        ownerFeeBalances[asset] = 0;
        address to = owner();
        IERC20(asset).safeTransfer(to, amount);
        emit SepehrEvents.OwnerFeesWithdrawn(asset, to, amount);
    }

    /// @notice Withdraw the caller's accrued keeper-share revenue for a specific asset.
    /// @dev Restricted implicitly by per-keeper accounting: only the keeper that earned a fee can claim it.
    /// Asset must be provided because a keeper may have accrued fees across multiple debt assets.
    /// @param asset The ERC-20 address to withdraw (the debt asset of the trigger that paid the keeper).
    function withdrawKeeperFees(
        address asset
    ) external nonReentrant {
        if (asset == address(0)) revert SepehrErrors.ZeroAddress();
        uint256 amount = keeperFeeBalances[msg.sender][asset];
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        keeperFeeBalances[msg.sender][asset] = 0;
        IERC20(asset).safeTransfer(msg.sender, amount);
        emit SepehrEvents.KeeperFeesWithdrawn(msg.sender, asset, amount);
    }

    // ─── Pause ───────────────────────────────────────────────────

    /// @notice Emergency-pause all user-facing and keeper mutations for up to `MAX_PAUSE_DURATION`.
    /// @dev Callable by the owner or the pause guardian so the contract can be frozen quickly
    /// in response to an incident without waiting for the 48h timelock. A11: the pause is
    /// represented as an absolute `pausedUntil` timestamp that auto-expires after
    /// `MAX_PAUSE_DURATION`, preventing indefinite censorship if the owner/guardian keys are
    /// compromised or lost. To keep the pause in force longer, the operator must re-call
    /// `pause()` before `pausedUntil` elapses.
    function pause() external onlyPauseGuardianOrOwner {
        uint256 newPausedUntil = block.timestamp + MAX_PAUSE_DURATION;
        pausedUntil = newPausedUntil;
        emit SepehrEvents.EmergencyPaused(msg.sender, newPausedUntil);
    }

    /// @notice Resume the contract before the pause auto-expires.
    /// @dev Owner-only to ensure the pause guardian cannot unilaterally un-pause after the owner
    /// has investigated an incident. Setting `pausedUntil = 0` overrides an earlier future
    /// timestamp; the auto-expiry path (reaching `pausedUntil`) cannot be distinguished on
    /// chain from the manual-unpause path, which is intentional — both are "contract is now
    /// live".
    function unpause() external {
        if (msg.sender != owner()) revert SepehrErrors.NotOwner();
        pausedUntil = 0;
        emit SepehrEvents.Unpaused(msg.sender);
    }

    /// @notice Convenience view: returns true while the contract is currently paused.
    /// @dev Preserves the pre-A11 public `paused` getter shape for off-chain consumers.
    function paused() external view returns (bool) {
        return block.timestamp < pausedUntil;
    }

    // ─── Admin (Timelock-gated) ──────────────────────────────────

    /// @notice Register a new protocol adapter under the given key.
    /// @dev Timelock-gated (48h delay) because a malicious adapter could drain user collateral
    /// during trigger execution. Reverts if an adapter is already registered for the key.
    /// @param protocolKey Unique identifier for the protocol (e.g. keccak256("aave-v3-ethereum")).
    /// @param adapter Address of the contract implementing IProtocolAdapter.
    function addAdapter(
        bytes32 protocolKey,
        address adapter
    ) external onlyTimelock {
        if (adapter == address(0)) revert SepehrErrors.ZeroAddress();
        if (address(adapters[protocolKey].adapter) != address(0)) {
            revert SepehrErrors.AdapterAlreadyRegistered(protocolKey);
        }
        adapters[protocolKey] =
            AdapterEntry({adapter: IProtocolAdapter(adapter), enabled: true, addedAt: block.timestamp});
        emit SepehrEvents.AdapterAdded(protocolKey, adapter);
    }

    /// @notice Unregister a previously-added protocol adapter.
    /// @dev Timelock-gated because removing an adapter disables protection for every user
    /// relying on it. Users should be notified before removal.
    /// @param protocolKey Identifier of the adapter to remove.
    function removeAdapter(
        bytes32 protocolKey
    ) external onlyTimelock {
        if (address(adapters[protocolKey].adapter) == address(0)) {
            revert SepehrErrors.AdapterNotRegistered(protocolKey);
        }
        delete adapters[protocolKey];
        emit SepehrEvents.AdapterRemoved(protocolKey);
    }

    /// @notice Toggle the enabled flag on a registered adapter without removing it.
    /// @dev Timelock-gated. Disabling prevents new protections and new triggers on the adapter
    /// while preserving historical state (addedAt, registration).
    /// @param protocolKey Identifier of the adapter to toggle.
    /// @param enabled True to activate, false to pause the adapter.
    function setAdapterEnabled(
        bytes32 protocolKey,
        bool enabled
    ) external onlyTimelock {
        if (address(adapters[protocolKey].adapter) == address(0)) {
            revert SepehrErrors.AdapterNotRegistered(protocolKey);
        }
        adapters[protocolKey].enabled = enabled;
        if (enabled) {
            emit SepehrEvents.AdapterEnabled(protocolKey);
        } else {
            emit SepehrEvents.AdapterDisabled(protocolKey);
        }
    }

    /// @notice Authorize an address to call `execute` as a keeper.
    /// @dev Timelock-gated because keepers receive 15% of trigger fees and can invoke flash loans;
    /// adding an untrusted keeper would be a significant attack vector.
    /// @param keeper Address to grant keeper role.
    function addKeeper(
        address keeper
    ) external onlyTimelock {
        if (keeper == address(0)) revert SepehrErrors.ZeroAddress();
        keepers[keeper] = true;
        emit SepehrEvents.KeeperAdded(keeper);
    }

    /// @notice Revoke keeper privileges from an address.
    /// @dev Timelock-gated. Already-accrued fees remain claimable by the keeper via `withdrawKeeperFees`.
    /// @param keeper Address to revoke.
    function removeKeeper(
        address keeper
    ) external onlyTimelock {
        keepers[keeper] = false;
        emit SepehrEvents.KeeperRemoved(keeper);
    }

    /// @notice Update the trigger fee (in basis points) charged to subscribers of a given tier.
    /// @dev Timelock-gated because fees directly affect economics for all existing subscribers;
    /// changes should go through governance and announcement before taking effect. A8: bounded
    /// by `MAX_TIER_FEE_BPS` (1%) so even a rushed/malicious proposal cannot seize user
    /// collateral via a 99% fee — anything above that requires a contract migration.
    /// @param tier Tier index in [1, 4]; reverts otherwise.
    /// @param newBps Replacement fee in basis points applied to the repaid amount; must be
    /// ≤ `MAX_TIER_FEE_BPS`.
    function setTierFeeBps(
        uint8 tier,
        uint256 newBps
    ) external onlyTimelock {
        if (tier == 0 || tier > 4) revert SepehrErrors.InvalidTier();
        if (newBps > MAX_TIER_FEE_BPS) {
            revert SepehrErrors.TierFeeBpsTooHigh(newBps, MAX_TIER_FEE_BPS);
        }
        uint256 old = TIER_FEE_BPS[tier - 1];
        TIER_FEE_BPS[tier - 1] = newBps;
        emit SepehrEvents.TierFeeBpsUpdated(tier, old, newBps);
    }

    /// @notice Update the minimum USD-8 collateral required to enable protection.
    /// @dev Timelock-gated. Setting to 0 disables the gate entirely (useful for dev/test or
    /// emergency relief). A7: previously dead state; now enforced in `enableProtection`.
    /// @param newMin New minimum, in USD-8 units (e.g. 500e8 = $500).
    function setMinCollateralUsd(
        uint256 newMin
    ) external onlyTimelock {
        uint256 old = minCollateralUsd;
        minCollateralUsd = newMin;
        emit SepehrEvents.MinCollateralUsdUpdated(old, newMin);
    }

    /// @notice Grant a Titan (tier 4) subscription free of charge.
    /// @dev Owner-only (not timelock) so strategic partners, audits, or bounty recipients can be
    /// onboarded reactively. Cannot be self-subscribed through `subscribe`.
    /// @param user Recipient of the Titan subscription.
    /// @param durationSeconds Length of the subscription starting from now.
    function grantTitanSubscription(
        address user,
        uint256 durationSeconds
    ) external {
        if (msg.sender != owner()) revert SepehrErrors.NotOwner();
        if (user == address(0)) revert SepehrErrors.ZeroAddress();
        if (durationSeconds == 0) revert SepehrErrors.ZeroAmount();

        // Refuse to overwrite an active paid subscription. A Titan grant could otherwise wipe a
        // still-valid Shield/Guardian/Watchtower period without refund (owner griefing risk), or
        // even silently extend a compromised account's cap. The user must first `unsubscribe`
        // if they want to move off a paid plan onto a Titan grant.
        Subscription storage existing = _subscriptions[user];
        if (existing.tier != 0 && existing.tier != 4 && existing.expiresAt > block.timestamp) {
            revert SepehrErrors.SubscriptionAlreadyActive();
        }

        _subscriptions[user] = Subscription({
            tier: 4, annual: false, expiresAt: block.timestamp + durationSeconds, collateralValueUsdSnapshot: 0
        });

        emit SepehrEvents.TitanSubscriptionGranted(user, block.timestamp + durationSeconds);
    }

    /// @notice Whitelist a flash loan provider for use during trigger execution.
    /// @dev Timelock-gated because the callback `onFlashLoan` trusts `msg.sender` to be the active
    /// provider; whitelisting a malicious contract would let it forge callbacks.
    /// @param provider Address of an IFlashLoanProvider implementation.
    function addFlashLoanProvider(
        address provider
    ) external onlyTimelock {
        if (provider == address(0)) revert SepehrErrors.ZeroAddress();
        allowedFlashProviders[provider] = true;
        emit SepehrEvents.FlashLoanProviderAdded(provider);
    }

    /// @notice Remove a flash loan provider from the whitelist.
    /// @dev Timelock-gated. Pending executions continue using the provider until the next block.
    /// @param provider Address to delist.
    function removeFlashLoanProvider(
        address provider
    ) external onlyTimelock {
        allowedFlashProviders[provider] = false;
        emit SepehrEvents.FlashLoanProviderRemoved(provider);
    }

    /// @notice Whitelist a DEX router used for collateral→debt swaps during execution.
    /// @dev Timelock-gated because the router receives collateral approvals and is trusted to
    /// honor the `minOut` amount; a malicious router could drain positions.
    /// @param router Address of an IDexRouter implementation.
    function addDexRouter(
        address router
    ) external onlyTimelock {
        if (router == address(0)) revert SepehrErrors.ZeroAddress();
        allowedDexRouters[router] = true;
    }

    /// @notice Remove a DEX router from the whitelist.
    /// @dev Timelock-gated. Executions that specify a delisted router in `dexRouter` will revert.
    /// @param router Address to delist.
    function removeDexRouter(
        address router
    ) external onlyTimelock {
        allowedDexRouters[router] = false;
    }

    /// @notice Rotate the pause-guardian role to a new address.
    /// @dev Timelock-gated so the guardian cannot be swapped unilaterally by a compromised owner
    /// without the 48h delay announcing it on-chain.
    /// @param newGuardian Replacement guardian address.
    function setPauseGuardian(
        address newGuardian
    ) external onlyTimelock {
        if (newGuardian == address(0)) revert SepehrErrors.ZeroAddress();
        address old = pauseGuardian;
        pauseGuardian = newGuardian;
        emit SepehrEvents.PauseGuardianUpdated(old, newGuardian);
    }

    // ─── Views ───────────────────────────────────────────────────

    /// @inheritdoc ISepehrCore
    function getSubscription(
        address user
    ) external view override returns (Subscription memory) {
        return _subscriptions[user];
    }

    /// @inheritdoc ISepehrCore
    function getProtection(
        address user,
        bytes32 protocolKey
    ) external view override returns (PositionProtection memory) {
        return _protections[user][protocolKey];
    }

    /// @inheritdoc ISepehrCore
    function isKeeper(
        address addr
    ) external view override returns (bool) {
        return keepers[addr];
    }

    /// @inheritdoc ISepehrCore
    function getSaveCredits(
        address user
    ) external view override returns (uint256) {
        return saveCredits[user];
    }

    // ─── Internal ────────────────────────────────────────────────

    function _requireActiveSubscription(
        address user
    ) internal view {
        Subscription storage sub = _subscriptions[user];
        if (sub.tier == 0) revert SepehrErrors.SubscriptionNotFound();
        if (sub.expiresAt <= block.timestamp) revert SepehrErrors.SubscriptionExpired();
    }

    function _validateProtectionParams(
        uint256 thresholdHF,
        uint256 maxSlippageBps,
        uint256 repayPercentBps
    ) internal pure {
        if (thresholdHF < MIN_HF_THRESHOLD) {
            revert SepehrErrors.ThresholdTooLow(thresholdHF, MIN_HF_THRESHOLD);
        }
        if (repayPercentBps > MAX_REPAY_BPS) {
            revert SepehrErrors.RepayPercentTooHigh(repayPercentBps, MAX_REPAY_BPS);
        }
        if (maxSlippageBps > MAX_SLIPPAGE_BPS) {
            revert SepehrErrors.InvalidSlippage(maxSlippageBps);
        }
    }

    function _borrowFlashLoan(
        address[] calldata providers,
        address asset,
        uint256 amount,
        bytes memory data
    ) internal {
        for (uint256 i = 0; i < providers.length; i++) {
            if (!allowedFlashProviders[providers[i]]) continue;

            IFlashLoanProvider provider = IFlashLoanProvider(providers[i]);
            if (!provider.isAvailable(asset, amount)) continue;

            _activeFlashProvider = providers[i];
            try provider.flashBorrow(asset, amount, address(this), data) {
                _activeFlashProvider = address(0);
                return;
            } catch {
                _activeFlashProvider = address(0);
                continue;
            }
        }
        revert SepehrErrors.NoFlashLoanAvailable();
    }
}
