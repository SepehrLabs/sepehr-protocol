// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IDexRouter} from "./interfaces/IDexRouter.sol";
import {IFlashLoanProvider} from "./interfaces/IFlashLoanProvider.sol";
import {IProtocolAdapter} from "./interfaces/IProtocolAdapter.sol";
import {ISepehrCallback} from "./interfaces/ISepehrCallback.sol";
import {ISepehrCore} from "./interfaces/ISepehrCore.sol";
import {ISepehrSubscriptions} from "./interfaces/ISepehrSubscriptions.sol";
import {IChainlinkAggregator} from "./interfaces/external/IChainlinkAggregator.sol";
import {Percentages} from "./libraries/Percentages.sol";
import {SepehrErrors} from "./libraries/SepehrErrors.sol";
import {SepehrEvents} from "./libraries/SepehrEvents.sol";

contract SepehrCore is ISepehrCore, ISepehrCallback, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Constants ───────────────────────────────────────────────
    uint256 public constant MIN_HF_THRESHOLD = 1.2e18;
    /// @notice Largest share of the debt one rescue may repay. A position the cap stops short of
    /// its target stays under its threshold and is rescued again at once.
    uint256 public constant MAX_REPAY_BPS = 5000;
    /// @notice Smallest gap between a protection's threshold and its target. The gap is what
    /// stops rescues from repeating: a rescue lands at the target, and the next one needs the
    /// health factor to fall back under the threshold.
    uint256 public constant MIN_TARGET_GAP = 0.05e18;
    /// @notice Highest target a protection accepts.
    uint256 public constant MAX_TARGET_HF = 2.5e18;
    /// @notice How far above its target a rescue may leave a position. A rescue past it repaid,
    /// and charged fees on, more than the target needed; one that stops below the target is
    /// accepted, so a price moving between the keeper's sizing and the block never voids a rescue.
    uint256 public constant TARGET_TOLERANCE = 0.05e18;
    /// @notice Maximum slippage a user may configure for collateral→debt swaps during triggers.
    /// @dev Capped at 3% because the swap route and router are keeper-controlled: wider caps
    /// permit a keeper to sandwich their own trigger and capture the difference as MEV. 3% is
    /// the industry-typical upper bound for distressed-position swaps; above this, the keeper
    /// should simulate with a tighter bound off-chain.
    uint256 public constant MAX_SLIPPAGE_BPS = 300;

    /// @notice B15: plausibility floor for `hfBefore` at execute time. Liquidations on every
    /// supported lending market happen at HF = 1.0 (WAD = 1e18); any adapter reporting an HF
    /// meaningfully below that has either missed a protocol liquidation or is being fed a
    /// manipulated oracle. Rejecting sub-floor reads prevents a colluding-keeper + manipulated-
    /// oracle pair from extracting trigger fees on positions whose on-chain HF is actually safe.
    /// 0.5e18 is well below the minimum user-configurable threshold (1.2e18) so the floor never
    /// interferes with legitimate protection; it kicks in only on pathological / attacker reads.
    uint256 public constant MIN_PLAUSIBLE_HF_WAD = 0.5e18;

    /// @notice Maximum duration a single `pause()` call may freeze the contract. A11: without an
    /// auto-expiry a compromised owner/guardian key can permanently censor protections; the
    /// contract must eventually un-freeze itself so users can at least unsubscribe and call
    /// `disableProtection` without waiting on a human. 7 days is long enough for a legitimate
    /// incident response (timelock + review) and short enough to avoid indefinite lockout.
    uint256 public constant MAX_PAUSE_DURATION = 7 days;

    /// @notice D2: upper bound on the per-asset oracle staleness threshold. A timelock proposal
    /// that registered a feed with a multi-week `maxStaleness` would effectively disable the
    /// oracle-floor check (a long-dead feed would still be "fresh"). One day is the longest
    /// heartbeat among Chainlink's mainstream USD feeds (stablecoin pairs), so capping at
    /// 1 day rejects obviously-insecure configurations without breaking legitimate ones.
    ///
    /// Deploy policy (H4): the contract exposes a *ceiling* — individual per-asset values are
    /// expected to be **much tighter** in production. Volatile majors (ETH/USD, BTC/USD,
    /// WBTC/USD) must be configured with `maxStaleness <= 1 hours` because their Chainlink
    /// heartbeats are 3600s; only stablecoin feeds (USDC/USD, USDT/USD, DAI/USD) with
    /// legitimately-slow 86400s heartbeats should be registered anywhere near the ceiling.
    /// The `setAssetOracle` ingress is timelock-gated, so the 48h delay is the second defence.
    uint256 public constant MAX_ORACLE_STALENESS = 1 days;
    /// @notice D2: required decimals for every registered Chainlink aggregator. Chainlink's
    /// USD-denominated feeds are 8-decimal; enforcing this at registration time lets the
    /// min-out math assume both sides of a swap price pair share the same scaling and skip
    /// a `min`/`max`-decimal normalization step that would otherwise have to run inside the
    /// flash-loan callback.
    uint8 public constant ORACLE_PRICE_DECIMALS = 8;
    /// @notice L-5: after the L2 sequencer comes back up, prices are not trusted for this long,
    /// so feeds can catch up before triggers size withdrawals and swaps on them.
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;

    // ─── State ───────────────────────────────────────────────────
    /// @notice The plans users subscribe to: what `enableProtection` and `execute` check of a
    /// user (tier, expiry, collateral cap, trigger fee), read through `planOf`.
    ISepehrSubscriptions public immutable subscriptions;
    /// @notice Chain ID this SepehrCore instance is authorized to operate on. Captured at
    /// construction and enforced by `onlyExpectedChain` on every mutative entry-point plus the
    /// user-state view getters. V1 pivots mono-Arbitrum: the deploy script restricts this
    /// constructor argument to Arbitrum One (42161) or Arbitrum Sepolia (421614). Keeping the
    /// binding in immutable storage (rather than a hardcoded constant) lets the same bytecode
    /// target mainnet and testnet without a recompile, at the cost of one constructor check.
    /// See ADR-0011.
    uint256 public immutable expectedChainId;
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

    /// @notice G4: protocol-wide upper bound (USD-8) on the sum of snapshotted collateral
    /// values across every active position. Set to `type(uint256).max` to disable the cap.
    /// V1 deploys are expected to launch with a conservative cap (e.g. $75k = `7_500_000_000_000`)
    /// and let governance raise it as keeper performance is empirically validated. The cap
    /// is a forward-looking gate only: lowering it never disables already-enabled positions,
    /// so a tightening proposal cannot retroactively brick users.
    uint256 public tvlCapUsd;
    /// @notice G4: running sum of `protectionCollateralSnapshot` over all active positions.
    /// Maintained by `enableProtection` (add) and `disableProtection` / `unsubscribe` (sub).
    /// The snapshot is taken once at enable time and is not re-read; this means the running
    /// total drifts as collateral USD prices move, but for the cap's purpose (a sanity
    /// guardrail against unbounded protocol exposure) a stale-but-deterministic accounting
    /// beats a live-but-walk-all-positions accounting.
    uint256 public protectedCollateralUsd;
    /// @notice G4: per-(user, protocolKey) snapshot of `getCollateralValueUsd` taken at
    /// `enableProtection`. Read by `disableProtection` / `unsubscribe` to decrement the
    /// running total by the same amount that was added on enable, even if prices have moved.
    mapping(address user => mapping(bytes32 protocolKey => uint256)) public protectionCollateralSnapshot;

    mapping(address => bool) public keepers;
    mapping(bytes32 => AdapterEntry) public adapters;
    mapping(address => bool) public allowedFlashProviders;
    mapping(address => bool) public allowedDexRouters;

    /// @notice D1/D4: canonical-pool registry. Keyed by
    /// `keccak256(router, tokenIn, tokenOut)`; when an entry is registered
    /// the keeper-supplied `dexRouteData` is overridden with the timelock-
    /// registered bytes at swap time. This neutralizes keeper-controlled
    /// pool-steering vectors (UniswapV3 fee tier, Velodrome stable flag,
    /// TraderJoe binStep, Camelot/V2 path selection) and pins the swap to
    /// a pool that governance has explicitly blessed for that pair.
    mapping(bytes32 => bytes) private _canonicalRouteData;
    mapping(bytes32 => bool) public canonicalRouteSet;
    /// @notice When `true`, triggers revert if no canonical route is registered for
    /// the `(router, collateralAsset, debtAsset)` triple. Defaults to `false` so the
    /// registry can be rolled out pair-by-pair without breaking triggers on already-
    /// live pairs; governance can flip the flag once the registry is populated.
    ///
    /// Deploy policy (M3): new deployments MUST leave this as `false` at construction so
    /// the initial trigger path keeps working while the canonical-route registry is
    /// seeded. The deploy script asserts this default post-deploy, and
    /// `test_strictCanonicalRoutes_defaultIsOff` freezes the invariant in unit tests.
    /// Governance is expected to flip it to `true` via `setStrictCanonicalRoutes` only
    /// after the registry is fully populated.
    /// Governance is expected to flip it to `true` via `setStrictCanonicalRoutes` only
    /// after the registry is fully populated.
    bool public strictCanonicalRoutes;

    /// @notice D2: per-asset Chainlink-compatible price oracle registry. Drives the
    /// oracle-derived `minOut` floor inside `onFlashLoan`: given an expected swap pair
    /// (collateralAsset → debtAsset), the contract computes the USD-equivalent output
    /// from registered feeds and requires the swap to return at least
    /// `expected * (10_000 - maxSlippageBps) / 10_000`. Without this floor, a keeper
    /// with mempool control could sandwich their own trigger up to the user's
    /// `maxSlippageBps` because the `repayAmount + fee` floor only guards flash-loan
    /// solvency, not fair pricing.
    struct AssetOracle {
        IChainlinkAggregator aggregator;
        uint256 maxStaleness;
    }

    mapping(address asset => AssetOracle) public assetOracles;
    /// @notice L-5: Chainlink L2 sequencer uptime feed. While the sequencer is down, or within
    /// `SEQUENCER_GRACE_PERIOD` of its restart, every oracle read reverts. address(0) disables
    /// the check, for chains without such a feed (Arbitrum Sepolia).
    IChainlinkAggregator public sequencerUptimeFeed;
    /// @notice When `true`, swaps in `onFlashLoan` revert if either side of the pair
    /// has no registered oracle. Defaults to `false` so the registry can be populated
    /// pair-by-pair; governance flips the flag once every live pair is covered.
    bool public strictOraclePricing;

    struct AdapterEntry {
        IProtocolAdapter adapter;
        bool enabled;
        uint256 addedAt;
    }

    mapping(address => mapping(bytes32 => PositionProtection)) internal _protections;
    /// @notice A18: ordered list of protocol keys for which `user` has protection enabled.
    /// Maintained by `enableProtection` (push) and `disableProtection` (swap-pop). `unsubscribe`
    /// iterates this list to wipe `_protections` entries on cancellation, so a later
    /// re-subscribe starts from a clean slate instead of silently re-activating stale params.
    mapping(address user => bytes32[]) internal _userProtocols;
    /// @notice Lot 6: each protected position's stop-loss and take-profit, on an oracle price.
    mapping(address user => mapping(bytes32 protocolKey => ExitOrder)) internal _exitOrders;
    /// @notice Lot 6 (D4): under this health factor anyone may rescue a position, not only a
    /// keeper; 0, the default, keeps rescues to the keepers. Set by the timelock.
    uint256 public openExecutionHF;

    /// @notice Accrued protocol-owner trigger fees per token address (the debt asset of each trigger).
    /// @dev Per-asset accounting is mandatory because trigger fees accrue in whatever debt asset the user
    /// was borrowing (DAI, WETH, USDT, …). Subscription revenue lives in SepehrSubscriptions (M-1).
    mapping(address asset => uint256 amount) public ownerFeeBalances;

    /// @notice Accrued keeper revenue per keeper and per asset (debt asset of the trigger).
    mapping(address keeper => mapping(address asset => uint256 amount)) public keeperFeeBalances;

    address private _activeFlashProvider;
    bytes32 private _activeSessionHash;
    /// @dev I-1: collateral the flash-loan callback withdrew from the position, read back by
    /// `execute` for the `Triggered` event.
    uint256 private transient _collateralWithdrawn;

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

    /// @notice Reject every call whose `block.chainid` differs from the `expectedChainId`
    /// captured at construction. Applied to every mutative entry-point and to user-state view
    /// getters so a wrong-chain deployment is fully inert instead of half-alive (a half-alive
    /// contract would accept `subscribe` calls that the keeper on the real chain can never
    /// honour). See ADR-0011 for the V1 mono-Arbitrum rationale.
    modifier onlyExpectedChain() {
        if (block.chainid != expectedChainId) {
            revert SepehrErrors.WrongChain(expectedChainId, block.chainid);
        }
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────
    /// @param _owner initial protocol owner (holds `onlyOwner` + fee-withdraw rights).
    /// @param _timelock 48h-delay governance contract; sole caller of every admin mutation.
    /// @param _pauseGuardian address able to pause alongside the owner for rapid incident response.
    /// @param _subscriptions SepehrSubscriptions, deployed just before with this core's address.
    /// @param _minCollateralUsd minimum USD-8 collateral required at `enableProtection`; 0 disables.
    /// @param _tvlCapUsd G4: protocol-wide cap on the sum of snapshotted collateral USD
    /// across all active positions. Pass `type(uint256).max` to disable the cap (test fixtures
    /// and forks do this); production deploys are expected to start with a conservative ceiling
    /// (V1 default: $75k = `7_500_000_000_000`) and let governance raise it via `setTvlCapUsd`.
    /// @param _expectedChainId ADR-0011: the chain ID this instance is authorized to operate
    /// on. Stored as immutable and enforced by `onlyExpectedChain` on every mutative entry-point
    /// plus user-state view getters. Must equal `block.chainid` at deploy time; callers in
    /// `DeployCore.s.sol` restrict this to `42_161` (Arbitrum One) or `421_614` (Arbitrum Sepolia)
    /// — the contract itself only checks `block.chainid == _expectedChainId` so unit tests and
    /// local-anvil deploys can still pass their own chain ID.
    /// @dev A6: the legacy `_subscriptionOracle` constructor slot was removed because the oracle
    /// was never read. Per-position USD value comes from `adapter.getCollateralValueUsd()`, which
    /// already exists for the tier-cap path and is trust-minimized by timelock-registered adapters.
    constructor(
        address _owner,
        address _timelock,
        address _pauseGuardian,
        address _subscriptions,
        uint256 _minCollateralUsd,
        uint256 _tvlCapUsd,
        uint256 _expectedChainId
    ) Ownable(_owner) {
        if (_timelock == address(0)) revert SepehrErrors.ZeroAddress();
        if (_pauseGuardian == address(0)) revert SepehrErrors.ZeroAddress();
        if (_subscriptions == address(0)) revert SepehrErrors.ZeroAddress();
        if (_expectedChainId == 0) revert SepehrErrors.ZeroAmount();
        if (block.chainid != _expectedChainId) {
            revert SepehrErrors.WrongChain(_expectedChainId, block.chainid);
        }
        // The two contracts name each other: SepehrSubscriptions was deployed with this address.
        if (address(ISepehrSubscriptions(_subscriptions).core()) != address(this)) revert SepehrErrors.CoreMismatch();

        timelock = _timelock;
        pauseGuardian = _pauseGuardian;
        subscriptions = ISepehrSubscriptions(_subscriptions);
        minCollateralUsd = _minCollateralUsd;
        tvlCapUsd = _tvlCapUsd;
        expectedChainId = _expectedChainId;
    }

    // ─── Subscriptions ───────────────────────────────────────────

    /// @inheritdoc ISepehrCore
    /// @dev A18: a cancelled plan's protections are wiped so a later subscription starts from a
    /// clean slate, and their snapshots return to the TVL budget.
    function clearProtections(
        address user
    ) external override onlyExpectedChain {
        if (msg.sender != address(subscriptions)) revert SepehrErrors.NotSubscriptions();
        _clearProtections(user);
    }

    // ─── User: Position Protection ──────────────────────────────

    /// @inheritdoc ISepehrCore
    function enableProtection(
        bytes32 protocolKey,
        uint256 thresholdHF,
        uint256 maxSlippageBps,
        uint256 targetHF
    ) external override onlyExpectedChain whenNotPaused {
        ISepehrSubscriptions.Plan memory plan = _requireActiveSubscription(msg.sender);
        _validateProtectionParams(thresholdHF, maxSlippageBps, targetHF);

        AdapterEntry storage entry = adapters[protocolKey];
        if (address(entry.adapter) == address(0)) revert SepehrErrors.AdapterNotRegistered(protocolKey);
        if (!entry.enabled) revert SepehrErrors.AdapterDisabled(protocolKey);

        if (_protections[msg.sender][protocolKey].enabled) {
            revert SepehrErrors.ProtectionAlreadyEnabled(msg.sender, protocolKey);
        }

        if (!entry.adapter.checkDelegation(msg.sender)) {
            revert SepehrErrors.DelegationRevoked(msg.sender, protocolKey);
        }

        // A7 + G4: read the user's collateral value once and use it for two checks:
        //   1. minimum-collateral gate (A7): rejects dust positions that would waste keeper
        //      gas on triggers whose fee will never recoup gas costs. `minCollateralUsd == 0`
        //      disables the floor for test fixtures and initial deploys.
        //   2. protocol-wide TVL cap (G4): snapshots the value into
        //      `protectionCollateralSnapshot` and bumps `protectedCollateralUsd`. The cap is
        //      a forward-looking guardrail; lowering it via governance never disables already-
        //      enabled positions. `tvlCapUsd == type(uint256).max` disables the cap.
        uint256 collateralUsd = entry.adapter.getCollateralValueUsd(msg.sender);
        if (minCollateralUsd != 0 && collateralUsd < minCollateralUsd) {
            revert SepehrErrors.BelowMinimumCollateral(collateralUsd, minCollateralUsd);
        }
        // L-8 / M-2: the tier cap was only checked at trigger time, so a position above it was
        // accepted, counted against the TVL cap, and then never rescued.
        _requireWithinTierCap(collateralUsd, plan.maxCollateralUsd);
        uint256 newProtectedTotal = protectedCollateralUsd + collateralUsd;
        if (newProtectedTotal > tvlCapUsd) {
            revert SepehrErrors.TvlCapExceeded(newProtectedTotal, tvlCapUsd);
        }
        protectedCollateralUsd = newProtectedTotal;
        protectionCollateralSnapshot[msg.sender][protocolKey] = collateralUsd;

        _protections[msg.sender][protocolKey] = PositionProtection({
            enabled: true, thresholdHF: thresholdHF, maxSlippageBps: maxSlippageBps, targetHF: targetHF
        });
        _userProtocols[msg.sender].push(protocolKey);

        emit SepehrEvents.ProtectionEnabled(msg.sender, protocolKey, thresholdHF, maxSlippageBps, targetHF);
    }

    /// @inheritdoc ISepehrCore
    function disableProtection(
        bytes32 protocolKey
    ) external override onlyExpectedChain {
        if (!_protections[msg.sender][protocolKey].enabled) {
            revert SepehrErrors.ProtectionNotEnabled(msg.sender, protocolKey);
        }
        // G4: refund the cap budget by exactly the snapshot taken at enable time, even if
        // the live collateral value has since drifted. Reading the live value here would
        // let a user front-run a price drop to enable a position cheaply (low snapshot)
        // and disable it after a price rally (high refund), draining the running total
        // below zero (or, with checked arithmetic, reverting on disable and bricking exit).
        uint256 snapshot = protectionCollateralSnapshot[msg.sender][protocolKey];
        if (snapshot != 0) {
            protectedCollateralUsd -= snapshot;
            delete protectionCollateralSnapshot[msg.sender][protocolKey];
        }
        delete _protections[msg.sender][protocolKey];
        delete _exitOrders[msg.sender][protocolKey];
        _removeUserProtocol(msg.sender, protocolKey);
        emit SepehrEvents.ProtectionDisabled(msg.sender, protocolKey);
    }

    /// @inheritdoc ISepehrCore
    function updateProtection(
        bytes32 protocolKey,
        uint256 thresholdHF,
        uint256 maxSlippageBps,
        uint256 targetHF
    ) external override onlyExpectedChain whenNotPaused {
        if (!_protections[msg.sender][protocolKey].enabled) {
            revert SepehrErrors.ProtectionNotEnabled(msg.sender, protocolKey);
        }
        _validateProtectionParams(thresholdHF, maxSlippageBps, targetHF);

        PositionProtection storage prot = _protections[msg.sender][protocolKey];
        prot.thresholdHF = thresholdHF;
        prot.maxSlippageBps = maxSlippageBps;
        prot.targetHF = targetHF;

        emit SepehrEvents.ProtectionUpdated(msg.sender, protocolKey, thresholdHF, maxSlippageBps, targetHF);
    }

    /// @notice M-2: release the protections of a subscription that has expired or was
    /// cancelled, returning their snapshots to the protocol-wide TVL budget.
    /// @dev Callable by anyone: an expired position can no longer be triggered, and without
    /// this it kept its share of the cap until its owner acted.
    /// @param user Owner of the expired subscription.
    function releaseExpiredProtections(
        address user
    ) external onlyExpectedChain {
        if (subscriptions.planOf(user).expiresAt > block.timestamp) revert SepehrErrors.SubscriptionAlreadyActive();
        _clearProtections(user);
    }

    /// @notice M-2: lower a protected position's TVL snapshot to its current collateral value,
    /// returning the difference to the TVL running total.
    /// @dev Callable by anyone. The snapshot taken at `enableProtection` never moved, so
    /// collateral borrowed for the enable call and withdrawn right after kept the cap filled.
    /// A refresh never raises a snapshot: it would let anyone push the running total past
    /// `tvlCapUsd` and the plan's cap with a deposit borrowed for one transaction, and block
    /// every new protection (KupiaSec, 2026-10-20). A position that grew keeps the value it was
    /// enabled with; nothing happens when the live value is not lower.
    /// @param user Owner of the position.
    /// @param protocolKey Protocol of the position.
    function refreshCollateralSnapshot(
        address user,
        bytes32 protocolKey
    ) external onlyExpectedChain {
        if (!_protections[user][protocolKey].enabled) revert SepehrErrors.ProtectionNotEnabled(user, protocolKey);
        IProtocolAdapter adapter = adapters[protocolKey].adapter;
        if (address(adapter) == address(0)) revert SepehrErrors.AdapterNotRegistered(protocolKey);

        uint256 oldValue = protectionCollateralSnapshot[user][protocolKey];
        uint256 newValue = adapter.getCollateralValueUsd(user);
        if (newValue >= oldValue) return;
        protectedCollateralUsd -= oldValue - newValue;
        protectionCollateralSnapshot[user][protocolKey] = newValue;
        emit SepehrEvents.CollateralSnapshotRefreshed(user, protocolKey, oldValue, newValue);
    }

    // ─── Keeper: Trigger ─────────────────────────────────────────

    /// @inheritdoc ISepehrCore
    function execute(
        address user,
        bytes32 protocolKey,
        address debtAsset,
        address collateralAsset,
        uint256 repayAmount,
        address[] calldata flashProviders,
        address dexRouter,
        bytes calldata dexRouteData
    ) external override onlyExpectedChain nonReentrant whenNotPaused returns (uint256 hfAfter) {
        (ISepehrSubscriptions.Plan memory plan, PositionProtection storage prot, IProtocolAdapter adapter) =
            _requireProtectedPosition(user, protocolKey, dexRouter);

        uint256 hfBefore = adapter.getHealthFactor(user);
        if (hfBefore >= prot.thresholdHF) {
            revert SepehrErrors.HealthFactorAboveThreshold(hfBefore, prot.thresholdHF);
        }
        // Lot 6 (D4): with open execution on, anyone may rescue a position under
        // `openExecutionHF`, the last resort when the keepers are down; it earns the keeper share.
        if (!keepers[msg.sender] && hfBefore >= openExecutionHF) revert SepehrErrors.NotKeeper();
        // B15: reject implausibly-low pre-trigger HFs. An adapter returning an HF well below
        // the protocol's own liquidation threshold (1.0) is either stale or oracle-manipulated;
        // either way, the trigger fee extraction is illegitimate and must revert.
        if (hfBefore < MIN_PLAUSIBLE_HF_WAD) {
            revert SepehrErrors.ImplausibleHealthFactor(hfBefore, MIN_PLAUSIBLE_HF_WAD);
        }

        // No cooldown between rescues: a rescue lands at most `TARGET_TOLERANCE` above the target,
        // itself at least `MIN_TARGET_GAP` above the threshold, so another one needs the health
        // factor to fall back under the threshold, which is when the position needs it. A rescue
        // the repay cap stopped short of the target leaves the position under its threshold, and
        // the next one may follow at once.

        if (repayAmount == 0) revert SepehrErrors.ZeroAmount();

        // H02: one rescue repays at most `MAX_REPAY_BPS` of the debt, whatever the target asks
        // for: a deep fall is recovered over several rescues, each checked again. M-6: every
        // adapter's `getDebt` returns 0 only when the user owes nothing in `debtAsset`, so 0
        // reverts; it used to skip the limit, which let a keeper "repay" Compound in a collateral
        // asset with no bound.
        {
            uint256 userDebt = adapter.getDebt(user, debtAsset);
            if (userDebt == 0) revert SepehrErrors.NoDebtToRepay(user, debtAsset);
            uint256 allowed = (userDebt * MAX_REPAY_BPS) / Percentages.BPS_DENOMINATOR;
            if (repayAmount > allowed) {
                revert SepehrErrors.MaxRepayExceeded(repayAmount, allowed);
            }
        }

        uint256 totalFee = Percentages.applyBps(repayAmount, plan.feeBps);
        // Lot 6: the debt asset the user lets the core take (allowance, within their balance)
        // repays first, each unit with its fee at the plan's rate; a flash loan backed by the
        // collateral covers the rest, and none is needed when the wallet covers it all.
        uint256 walletRepay = _walletRepay(user, debtAsset, repayAmount, plan.feeBps);
        uint256 walletFee = Percentages.applyBps(walletRepay, plan.feeBps);
        if (walletRepay != 0) {
            IERC20(debtAsset).safeTransferFrom(user, address(this), walletRepay + walletFee);
            emit SepehrEvents.RepaidFromWallet(user, protocolKey, debtAsset, walletRepay, walletFee);
        }
        uint256 collateralWithdrawn;
        if (walletRepay == repayAmount) {
            _repayFromWallet(adapter, user, debtAsset, repayAmount, totalFee);
        } else {
            bytes memory callbackData = abi.encode(
                user,
                protocolKey,
                debtAsset,
                collateralAsset,
                repayAmount,
                walletFee,
                dexRouter,
                dexRouteData,
                prot.maxSlippageBps,
                totalFee - walletFee,
                uint256(0)
            );
            uint256 flashAmount = repayAmount - walletRepay;
            // H28: bind the callback session not just to the payload hash but also to the asset
            // and amount the flash-loan provider is expected to deliver. A malicious whitelisted
            // provider that tried to invoke onFlashLoan with a different asset/amount than
            // execute() requested would fail the equality check below.
            _activeSessionHash = keccak256(abi.encode(keccak256(callbackData), debtAsset, flashAmount));
            _borrowFlashLoan(flashProviders, debtAsset, flashAmount, callbackData);
            _activeSessionHash = bytes32(0);
            collateralWithdrawn = _collateralWithdrawn;
            _collateralWithdrawn = 0;
        }

        // H-2: a trigger only has to improve the health factor. Requiring it to clear the
        // threshold, or the target, blocked every rescue once a fast drop pushed the position
        // further than one rescue could recover, which is when protection matters most.
        // H09: require strict HF improvement. A trigger that leaves HF unchanged (or regressed
        // due to a stale adapter price cache) is ineffective, and charging fees for a no-op would
        // constitute unjust enrichment of keeper + owner at the user's expense.
        hfAfter = adapter.getHealthFactor(user);
        if (hfAfter <= hfBefore) {
            revert SepehrErrors.HealthFactorNotImproved(hfBefore, hfAfter);
        }
        // The upper bound is the user's: the keeper earns a share of a fee proportional to the
        // amount repaid, and must not unwind more of the position than the target asks for.
        if (hfAfter > prot.targetHF + TARGET_TOLERANCE) {
            revert SepehrErrors.RescueOvershootsTarget(hfAfter, prot.targetHF + TARGET_TOLERANCE);
        }

        (uint256 ownerShare, uint256 keeperShare) = Percentages.splitFee(totalFee);

        // Fees accrue in the debt asset of this trigger. Per-asset accounting is required because
        // debt assets vary across protocols (DAI, WETH, USDT, crvUSD, …); a single uint counter
        // would mix denominations and corrupt withdrawal math.
        ownerFeeBalances[debtAsset] += ownerShare;
        keeperFeeBalances[msg.sender][debtAsset] += keeperShare;

        emit SepehrEvents.Triggered(
            user, protocolKey, msg.sender, repayAmount, collateralWithdrawn, hfBefore, hfAfter, totalFee
        );
        emit SepehrEvents.FeeCollected(msg.sender, debtAsset, totalFee, ownerShare, keeperShare);
    }

    // ─── Stop-loss and take-profit (lot 6) ───────────────────────

    /// @inheritdoc ISepehrCore
    function setExitOrder(
        bytes32 protocolKey,
        address priceAsset,
        uint256 stopLossUsd,
        uint256 takeProfitUsd
    ) external override onlyExpectedChain whenNotPaused {
        if (!_protections[msg.sender][protocolKey].enabled) {
            revert SepehrErrors.ProtectionNotEnabled(msg.sender, protocolKey);
        }
        if (stopLossUsd == 0 && takeProfitUsd == 0) {
            priceAsset = address(0);
        } else {
            if (address(assetOracles[priceAsset].aggregator) == address(0)) {
                revert SepehrErrors.MissingAssetOracle(priceAsset);
            }
            if (stopLossUsd != 0 && takeProfitUsd != 0 && stopLossUsd >= takeProfitUsd) {
                revert SepehrErrors.InvalidExitOrder(stopLossUsd, takeProfitUsd);
            }
        }
        _exitOrders[msg.sender][protocolKey] = ExitOrder(priceAsset, stopLossUsd, takeProfitUsd);
        emit SepehrEvents.ExitOrderSet(msg.sender, protocolKey, priceAsset, stopLossUsd, takeProfitUsd);
    }

    /// @inheritdoc ISepehrCore
    /// @dev The whole debt in `debtAsset` is repaid with a flash loan; `collateralAmount` of
    /// `collateralAsset` is withdrawn and sold, under the oracle floor a rescue uses, and what
    /// the sale leaves after the flash loan and the fee goes to the user. The order is spent.
    function close(
        address user,
        bytes32 protocolKey,
        address debtAsset,
        address collateralAsset,
        uint256 collateralAmount,
        address[] calldata flashProviders,
        address dexRouter,
        bytes calldata dexRouteData
    ) external override onlyExpectedChain nonReentrant whenNotPaused onlyKeeper {
        (ISepehrSubscriptions.Plan memory plan, PositionProtection storage prot, IProtocolAdapter adapter) =
            _requireProtectedPosition(user, protocolKey, dexRouter);
        if (collateralAmount == 0) revert SepehrErrors.ZeroAmount();

        ExitOrder memory order = _exitOrders[user][protocolKey];
        if (order.priceAsset == address(0)) revert SepehrErrors.NoExitOrder(user, protocolKey);
        uint256 price = _readOraclePrice(order.priceAsset, assetOracles[order.priceAsset]);
        bool stopped = order.stopLossUsd != 0 && price <= order.stopLossUsd;
        if (!stopped && (order.takeProfitUsd == 0 || price < order.takeProfitUsd)) {
            revert SepehrErrors.ExitConditionNotMet(price);
        }

        uint256 debt = adapter.getDebt(user, debtAsset);
        if (debt == 0) revert SepehrErrors.NoDebtToRepay(user, debtAsset);
        uint256 fee = Percentages.applyBps(debt, plan.feeBps);
        delete _exitOrders[user][protocolKey];

        bytes memory callbackData = abi.encode(
            user,
            protocolKey,
            debtAsset,
            collateralAsset,
            debt,
            uint256(0),
            dexRouter,
            dexRouteData,
            prot.maxSlippageBps,
            fee,
            collateralAmount
        );
        _activeSessionHash = keccak256(abi.encode(keccak256(callbackData), debtAsset, debt));
        _borrowFlashLoan(flashProviders, debtAsset, debt, callbackData);
        _activeSessionHash = bytes32(0);
        _collateralWithdrawn = 0;

        (uint256 ownerShare, uint256 keeperShare) = Percentages.splitFee(fee);
        ownerFeeBalances[debtAsset] += ownerShare;
        keeperFeeBalances[msg.sender][debtAsset] += keeperShare;
        emit SepehrEvents.PositionClosed(user, protocolKey, msg.sender, debt, collateralAmount, price, fee);
        emit SepehrEvents.FeeCollected(msg.sender, debtAsset, fee, ownerShare, keeperShare);
    }

    // ─── Flash Loan Callback ─────────────────────────────────────

    /// @inheritdoc ISepehrCallback
    function onFlashLoan(
        address asset,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override onlyExpectedChain {
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
            uint256 walletFee,
            address dexRouter,
            bytes memory dexRouteData,
            uint256 maxSlippageBps,
            uint256 collateralFee,
            uint256 collateralNeeded
        ) = abi.decode(
            data, (address, bytes32, address, address, uint256, uint256, address, bytes, uint256, uint256, uint256)
        );

        IProtocolAdapter adapter = adapters[protocolKey].adapter;

        // H-3 / L-2: balances the core held before this trigger (the provider sent `amount`, the
        // wallet the rest of `repayAmount` and its fee). The trigger keeps the flash-loan
        // repayment and the fee `execute` credits; everything else goes back to the user.
        uint256 debtHeld = IERC20(debtAsset).balanceOf(address(this)) - repayAmount - walletFee;
        uint256 collateralHeld = collateralAsset == debtAsset ? 0 : IERC20(collateralAsset).balanceOf(address(this));

        IERC20(debtAsset).safeTransfer(address(adapter), repayAmount);
        adapter.repay(user, debtAsset, repayAmount);

        // C1: `requiredDebtOut` is the amount of debt-asset the collateral must raise — enough to
        // repay the flash loan (`amount + fee`) and the part of the trigger fee the wallet did
        // not pay (`collateralFee`), with the same rounding as execute().
        uint256 requiredDebtOut = amount + fee + collateralFee;

        // A close names the collateral to sell, all of it (lot 6); a rescue sells what it needs.
        if (collateralNeeded == 0) {
            if (collateralAsset == debtAsset) {
                // Homogeneous case: collateral == debt, no swap needed. Withdraw exactly the
                // required output; the part over (amount+fee) funds trigger-fee accrual.
                collateralNeeded = requiredDebtOut;
            } else {
                // C1: cross-asset — reverse-project `requiredDebtOut` through the Chainlink oracle
                // pair, adding a `maxSlippageBps` buffer, so that even a worst-case swap still
                // produces at least `requiredDebtOut` of debt asset. The prior implementation used
                // `repayAmount + fee + triggerFee` in debt-asset units as the collateral amount,
                // which conflated denominations and either stole user collateral or under-withdrew.
                collateralNeeded = _collateralToCover(collateralAsset, debtAsset, requiredDebtOut, maxSlippageBps);
            }
        }

        adapter.withdrawCollateral(user, collateralAsset, collateralNeeded, address(this));
        _collateralWithdrawn = collateralNeeded;

        if (collateralAsset != debtAsset) {
            // D1/D4: if governance has registered a canonical route for this
            // (router, collateralAsset, debtAsset) triple, substitute the keeper's
            // `dexRouteData` with the registered bytes. In strict mode, triggers
            // must have a registered canonical route or they revert outright.
            {
                bytes32 routeKey = _canonicalRouteKey(dexRouter, collateralAsset, debtAsset);
                if (canonicalRouteSet[routeKey]) {
                    dexRouteData = _canonicalRouteData[routeKey];
                } else if (strictCanonicalRoutes) {
                    revert SepehrErrors.NoCanonicalRoute(dexRouter, collateralAsset, debtAsset);
                }
            }

            // minOut is the greater of `requiredDebtOut` (solvency + fee floor) and the
            // oracle-derived floor re-projected on the actual `collateralNeeded`. The oracle
            // floor defends against a keeper-sandwiched swap; `requiredDebtOut` defends the
            // flash loan + fee accrual. Reverting below either is correct.
            uint256 minOut = requiredDebtOut;
            uint256 oracleFloor = _oracleMinOut(collateralAsset, debtAsset, collateralNeeded, maxSlippageBps);
            if (oracleFloor > minOut) minOut = oracleFloor;

            uint256 debtBeforeSwap = IERC20(debtAsset).balanceOf(address(this));
            IERC20(collateralAsset).safeIncreaseAllowance(dexRouter, collateralNeeded);
            IDexRouter(dexRouter).swap(collateralAsset, debtAsset, collateralNeeded, minOut, dexRouteData);
            // H07: zero the allowance after the swap so a residual approval cannot be drained
            // later if the router holds onto it. forceApprove handles tokens that require the
            // allowance to be reset to zero before being changed.
            IERC20(collateralAsset).forceApprove(dexRouter, 0);

            // L-2: measure what the core actually received rather than trusting the router.
            uint256 received = IERC20(debtAsset).balanceOf(address(this)) - debtBeforeSwap;
            if (received < minOut) {
                revert SepehrErrors.SlippageExceeded(received, minOut);
            }
            // L-2: collateral the router handed back unspent belongs to the user.
            _returnSurplus(user, collateralAsset, IERC20(collateralAsset).balanceOf(address(this)) - collateralHeld);
        }

        // H-3: unused slippage headroom (and any repay surplus an adapter swept back) used to be
        // credited to the owner. It goes back to the user; the core keeps exactly what it owes.
        uint256 owed = amount + fee + collateralFee + walletFee;
        uint256 available = IERC20(debtAsset).balanceOf(address(this)) - debtHeld;
        if (available < owed) revert SepehrErrors.InsufficientRescueProceeds(available, owed);
        _returnSurplus(user, debtAsset, available - owed);

        IERC20(asset).safeTransfer(msg.sender, amount + fee);
    }

    // ─── Ownership ──────────────────────────────────────────────

    /// @notice Disabled. Ownership is permanent until transferred via `transferOwnership` +
    /// `acceptOwnership` (Ownable2Step). C2: allowing `renounceOwnership` would permanently
    /// disable fee withdrawal, adapter registration, pause/unpause, and every timelock-gated
    /// mutation — effectively bricking the protocol in a single call.
    function renounceOwnership() public pure override {
        revert SepehrErrors.OwnershipCannotBeRenounced();
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
    ) external onlyExpectedChain nonReentrant {
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
    ) external onlyExpectedChain nonReentrant {
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
    function pause() external onlyExpectedChain onlyPauseGuardianOrOwner {
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
    function unpause() external onlyExpectedChain {
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
    ) external onlyExpectedChain onlyTimelock {
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
    ) external onlyExpectedChain onlyTimelock {
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
    ) external onlyExpectedChain onlyTimelock {
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
    ) external onlyExpectedChain onlyTimelock {
        if (keeper == address(0)) revert SepehrErrors.ZeroAddress();
        keepers[keeper] = true;
        emit SepehrEvents.KeeperAdded(keeper);
    }

    /// @notice Revoke keeper privileges from an address.
    /// @dev Timelock-gated. Already-accrued fees remain claimable by the keeper via `withdrawKeeperFees`.
    /// @param keeper Address to revoke.
    function removeKeeper(
        address keeper
    ) external onlyExpectedChain onlyTimelock {
        keepers[keeper] = false;
        emit SepehrEvents.KeeperRemoved(keeper);
    }

    /// @notice Update the minimum USD-8 collateral required to enable protection.
    /// @dev Timelock-gated. Setting to 0 disables the gate entirely (useful for dev/test or
    /// emergency relief). A7: previously dead state; now enforced in `enableProtection`.
    /// @param newMin New minimum, in USD-8 units (e.g. 500e8 = $500).
    function setMinCollateralUsd(
        uint256 newMin
    ) external onlyExpectedChain onlyTimelock {
        uint256 old = minCollateralUsd;
        minCollateralUsd = newMin;
        emit SepehrEvents.MinCollateralUsdUpdated(old, newMin);
    }

    /// @notice G4: update the protocol-wide TVL cap (sum of snapshotted collateral USD-8 across
    /// every active position). Pass `type(uint256).max` to remove the cap entirely. Lowering the
    /// cap below `protectedCollateralUsd` does NOT disable existing positions — only future
    /// `enableProtection` calls are gated, so a tightening proposal cannot retroactively brick
    /// users. Raising the cap is the standard governance path as keeper performance is validated.
    /// @dev Timelock-gated. No cooldown: the cap is a forward-looking guardrail, not a price.
    /// @param newCap New cap in USD-8 units (e.g. `7_500_000_000_000` = $75k).
    function setTvlCapUsd(
        uint256 newCap
    ) external onlyExpectedChain onlyTimelock {
        uint256 old = tvlCapUsd;
        tvlCapUsd = newCap;
        emit SepehrEvents.TvlCapUpdated(old, newCap);
    }

    /// @notice Whitelist a flash loan provider for use during trigger execution.
    /// @dev Timelock-gated because the callback `onFlashLoan` trusts `msg.sender` to be the active
    /// provider; whitelisting a malicious contract would let it forge callbacks.
    /// @param provider Address of an IFlashLoanProvider implementation.
    function addFlashLoanProvider(
        address provider
    ) external onlyExpectedChain onlyTimelock {
        if (provider == address(0)) revert SepehrErrors.ZeroAddress();
        allowedFlashProviders[provider] = true;
        emit SepehrEvents.FlashLoanProviderAdded(provider);
    }

    /// @notice Remove a flash loan provider from the whitelist.
    /// @dev Timelock-gated. Pending executions continue using the provider until the next block.
    /// @param provider Address to delist.
    function removeFlashLoanProvider(
        address provider
    ) external onlyExpectedChain onlyTimelock {
        allowedFlashProviders[provider] = false;
        emit SepehrEvents.FlashLoanProviderRemoved(provider);
    }

    /// @notice Whitelist a DEX router used for collateral→debt swaps during execution.
    /// @dev Timelock-gated because the router receives collateral approvals and is trusted to
    /// honor the `minOut` amount; a malicious router could drain positions.
    /// @param router Address of an IDexRouter implementation.
    function addDexRouter(
        address router
    ) external onlyExpectedChain onlyTimelock {
        if (router == address(0)) revert SepehrErrors.ZeroAddress();
        allowedDexRouters[router] = true;
        emit SepehrEvents.DexRouterAdded(router);
    }

    /// @notice Remove a DEX router from the whitelist.
    /// @dev Timelock-gated. Executions that specify a delisted router in `dexRouter` will revert.
    /// A14: emits `DexRouterRemoved` so off-chain monitors can detect the delisting — earlier
    /// versions silently updated the mapping, which diverged from every other admin function.
    /// @param router Address to delist.
    function removeDexRouter(
        address router
    ) external onlyExpectedChain onlyTimelock {
        allowedDexRouters[router] = false;
        emit SepehrEvents.DexRouterRemoved(router);
    }

    /// @notice D1/D4: register a canonical `routeData` blob for a `(router, tokenIn, tokenOut)`
    /// triple. When set, the keeper's `dexRouteData` is ignored at swap time and the registered
    /// bytes are used instead, pinning the swap to a governance-approved pool configuration.
    /// @dev Timelock-gated. `data` is opaque to SepehrCore — it is passed verbatim to the
    /// router's `swap` and must match whatever schema the router expects
    /// (UniswapV3: `abi.encode(uint24 fee[, uint160 sqrtPriceLimitX96])`; Velodrome:
    /// `abi.encode(bool stable)`; TraderJoe: `abi.encode(uint256 binStep, uint8 version)`, etc.).
    function setCanonicalRoute(
        address router,
        address tokenIn,
        address tokenOut,
        bytes calldata data
    ) external onlyExpectedChain onlyTimelock {
        if (router == address(0) || tokenIn == address(0) || tokenOut == address(0)) {
            revert SepehrErrors.ZeroAddress();
        }
        if (tokenIn == tokenOut) revert SepehrErrors.SameToken();
        bytes32 key = _canonicalRouteKey(router, tokenIn, tokenOut);
        _canonicalRouteData[key] = data;
        canonicalRouteSet[key] = true;
        emit SepehrEvents.CanonicalRouteSet(router, tokenIn, tokenOut, data);
    }

    /// @notice Clear a previously registered canonical route.
    /// @dev Timelock-gated. After clearing, the pair falls back to keeper-supplied routeData
    /// (unless `strictCanonicalRoutes` is enabled, in which case the trigger will revert).
    function clearCanonicalRoute(
        address router,
        address tokenIn,
        address tokenOut
    ) external onlyExpectedChain onlyTimelock {
        bytes32 key = _canonicalRouteKey(router, tokenIn, tokenOut);
        delete _canonicalRouteData[key];
        canonicalRouteSet[key] = false;
        emit SepehrEvents.CanonicalRouteCleared(router, tokenIn, tokenOut);
    }

    /// @notice Toggle strict mode for the canonical route registry.
    /// @dev Timelock-gated. When enabled, triggers revert if no canonical route is registered
    /// for the `(router, collateralAsset, debtAsset)` triple — eliminating the keeper-supplied
    /// `dexRouteData` trust surface entirely. Disable while the registry is being populated.
    function setStrictCanonicalRoutes(
        bool enabled
    ) external onlyExpectedChain onlyTimelock {
        strictCanonicalRoutes = enabled;
        emit SepehrEvents.StrictCanonicalRoutesUpdated(enabled);
    }

    /// @notice View the canonical `routeData` registered for a `(router, tokenIn, tokenOut)` triple.
    /// @return set Whether a canonical entry is registered for the triple.
    /// @return data The registered routeData bytes (empty if `set` is false).
    function getCanonicalRoute(
        address router,
        address tokenIn,
        address tokenOut
    ) external view returns (bool set, bytes memory data) {
        bytes32 key = _canonicalRouteKey(router, tokenIn, tokenOut);
        set = canonicalRouteSet[key];
        data = _canonicalRouteData[key];
    }

    function _canonicalRouteKey(
        address router,
        address tokenIn,
        address tokenOut
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(router, tokenIn, tokenOut));
    }

    /// @notice D2: register a Chainlink-compatible price oracle for `asset`. Once both the
    /// collateral and debt assets of a swap have an oracle registered, the trigger callback
    /// requires the swap to return at least `expected * (1 - maxSlippageBps)` where
    /// `expected` is projected through the two registered feeds.
    /// @dev Timelock-gated. `maxStaleness` bounds `block.timestamp - updatedAt` at read time
    /// and must be in `(0, MAX_ORACLE_STALENESS]` so a multi-month threshold cannot silently
    /// disable the floor. Chainlink's mainstream USD feeds are 8-decimal; the call reverts if
    /// the aggregator reports any other decimal count so the in-callback math does not need
    /// to normalize.
    function setAssetOracle(
        address asset,
        address aggregator,
        uint256 maxStaleness
    ) external onlyExpectedChain onlyTimelock {
        if (asset == address(0) || aggregator == address(0)) revert SepehrErrors.ZeroAddress();
        if (maxStaleness == 0 || maxStaleness > MAX_ORACLE_STALENESS) {
            revert SepehrErrors.InvalidOracleStaleness(maxStaleness);
        }
        uint8 dec = IChainlinkAggregator(aggregator).decimals();
        if (dec != ORACLE_PRICE_DECIMALS) {
            revert SepehrErrors.InvalidOracleDecimals(dec, ORACLE_PRICE_DECIMALS);
        }
        assetOracles[asset] = AssetOracle({aggregator: IChainlinkAggregator(aggregator), maxStaleness: maxStaleness});
        emit SepehrEvents.AssetOracleSet(asset, aggregator, maxStaleness);
    }

    /// @notice Clear a previously registered asset oracle.
    /// @dev Timelock-gated. After clearing, swaps involving `asset` fall back to the
    /// flash-loan solvency floor only — unless `strictOraclePricing` is enabled, in which
    /// case those swaps will revert with `MissingAssetOracle`.
    function clearAssetOracle(
        address asset
    ) external onlyExpectedChain onlyTimelock {
        delete assetOracles[asset];
        emit SepehrEvents.AssetOracleCleared(asset);
    }

    /// @notice Toggle strict mode for the oracle-floor check.
    /// @dev Timelock-gated. When enabled, any swap whose collateral or debt asset lacks a
    /// registered oracle reverts — eliminating the implicit "no oracle → no floor" relaxation
    /// and forcing every live pair through the oracle check.
    function setStrictOraclePricing(
        bool enabled
    ) external onlyExpectedChain onlyTimelock {
        strictOraclePricing = enabled;
        emit SepehrEvents.StrictOraclePricingUpdated(enabled);
    }

    /// @notice L-5: set the L2 sequencer uptime feed checked before every oracle read.
    /// @dev Timelock-gated. address(0) disables the check.
    /// @param feed Chainlink sequencer uptime feed (Arbitrum One:
    /// 0xFdB631F5EE196F0ed6FAa767959853A9F217697D).
    function setSequencerUptimeFeed(
        address feed
    ) external onlyExpectedChain onlyTimelock {
        sequencerUptimeFeed = IChainlinkAggregator(feed);
        emit SepehrEvents.SequencerUptimeFeedSet(feed);
    }

    /// @notice D2: compute the oracle-derived minimum output for a `collateralAsset → debtAsset`
    /// swap of `amountIn` collateral units, accounting for the user-supplied `maxSlippageBps`.
    /// @dev Returns 0 when either side lacks a registered oracle and `strictOraclePricing`
    /// is disabled — the caller then falls back to the flash-loan solvency floor only.
    /// Reverts with `MissingAssetOracle` when strict mode is enabled and any side is missing,
    /// with `StaleOraclePrice` when a feed's `updatedAt` is older than its configured
    /// `maxStaleness`, and with `InvalidOraclePrice` on a zero or negative round answer.
    ///
    /// Math:
    ///   expectedOut = amountIn * collPrice * 10^debtDecimals
    ///                 / (10^collDecimals * debtPrice)
    ///   minOut      = expectedOut * (10_000 - maxSlippageBps) / 10_000
    ///
    /// Price decimals cancel because `setAssetOracle` enforces `ORACLE_PRICE_DECIMALS` on
    /// every registered feed. `Math.mulDiv` is used to avoid intermediate overflow at the
    /// outer edges of the input space (large amountIn × large price).
    function _oracleMinOut(
        address collateralAsset,
        address debtAsset,
        uint256 amountIn,
        uint256 maxSlippageBps
    ) internal view returns (uint256) {
        AssetOracle memory collOracle = assetOracles[collateralAsset];
        AssetOracle memory debtOracle = assetOracles[debtAsset];
        if (address(collOracle.aggregator) == address(0) || address(debtOracle.aggregator) == address(0)) {
            if (strictOraclePricing) {
                revert SepehrErrors.MissingAssetOracle(address(collOracle.aggregator) == address(0)
                        ? collateralAsset
                        : debtAsset);
            }
            return 0;
        }

        uint256 collPrice = _readOraclePrice(collateralAsset, collOracle);
        uint256 debtPrice = _readOraclePrice(debtAsset, debtOracle);

        uint256 collDec = IERC20Metadata(collateralAsset).decimals();
        uint256 debtDec = IERC20Metadata(debtAsset).decimals();

        // expectedOut = amountIn * collPrice / 10^collDec * 10^debtDec / debtPrice
        uint256 expectedOut = Math.mulDiv(Math.mulDiv(amountIn, collPrice, 10 ** collDec), 10 ** debtDec, debtPrice);
        if (maxSlippageBps == 0) return expectedOut;
        return (expectedOut * (10_000 - maxSlippageBps)) / 10_000;
    }

    /// @notice C1: inverse of `_oracleMinOut` — compute how much `collateralAsset` must be sold
    /// to produce at least `debtAmountRequired` of `debtAsset`, accounting for up to
    /// `maxSlippageBps` of swap slippage.
    /// @dev Forward: `expectedOut = amountIn * collPrice / 10^collDec * 10^debtDec / debtPrice`.
    /// Inverse (for amountIn): `amountIn = debtOut * debtPrice * 10^collDec / (collPrice * 10^debtDec)`.
    /// Slippage buffer: divide by `(10_000 - maxSlippageBps) / 10_000` so post-slippage output still
    /// meets the required amount. Uses `Math.mulDiv` ceil on both steps so rounding can only
    /// over-withdraw by at most 1 unit of collateral (never under-withdraw).
    /// Reverts via `_readOraclePrice` if either side lacks a registered feed or the feed is stale.
    function _collateralToCover(
        address collateralAsset,
        address debtAsset,
        uint256 debtAmountRequired,
        uint256 maxSlippageBps
    ) internal view returns (uint256) {
        AssetOracle memory collOracle = assetOracles[collateralAsset];
        AssetOracle memory debtOracle = assetOracles[debtAsset];
        if (address(collOracle.aggregator) == address(0)) {
            revert SepehrErrors.MissingAssetOracle(collateralAsset);
        }
        if (address(debtOracle.aggregator) == address(0)) {
            revert SepehrErrors.MissingAssetOracle(debtAsset);
        }

        uint256 collPrice = _readOraclePrice(collateralAsset, collOracle);
        uint256 debtPrice = _readOraclePrice(debtAsset, debtOracle);

        uint256 collDec = IERC20Metadata(collateralAsset).decimals();
        uint256 debtDec = IERC20Metadata(debtAsset).decimals();

        // amountIn = ceil( debtAmountRequired * debtPrice * 10^collDec / (collPrice * 10^debtDec) )
        // The first multiplication fits: realistic max is ~1e19 (WETH repay) * ~1e12 (ETH/USD 8dp) = 1e31 < 2^256.
        uint256 numer = debtAmountRequired * debtPrice;
        uint256 amountIn = Math.mulDiv(numer, 10 ** collDec, collPrice * (10 ** debtDec), Math.Rounding.Ceil);

        if (maxSlippageBps == 0) return amountIn;
        // buffer = ceil( amountIn * 10_000 / (10_000 - maxSlippageBps) )
        return Math.mulDiv(amountIn, 10_000, 10_000 - maxSlippageBps, Math.Rounding.Ceil);
    }

    function _readOraclePrice(
        address asset,
        AssetOracle memory oracle
    ) private view returns (uint256) {
        _requireSequencerUp();
        (, int256 answer,, uint256 updatedAt,) = oracle.aggregator.latestRoundData();
        if (answer <= 0) revert SepehrErrors.InvalidOraclePrice(asset, answer);
        if (block.timestamp > updatedAt && block.timestamp - updatedAt > oracle.maxStaleness) {
            revert SepehrErrors.StaleOraclePrice(asset, updatedAt, block.timestamp);
        }
        return uint256(answer);
    }

    /// @notice H-3 / L-2: send tokens a trigger did not consume back to the protected user.
    function _returnSurplus(
        address user,
        address asset,
        uint256 amount
    ) private {
        if (amount == 0) return;
        IERC20(asset).safeTransfer(user, amount);
        emit SepehrEvents.SurplusReturned(user, asset, amount);
    }

    /// @notice L-5: Chainlink's L2 sequencer check. `answer` 0 means up, 1 down; `startedAt` is
    /// when that status began, and 0 marks an invalid round.
    function _requireSequencerUp() private view {
        IChainlinkAggregator feed = sequencerUptimeFeed;
        if (address(feed) == address(0)) return;
        (, int256 answer, uint256 startedAt,,) = feed.latestRoundData();
        if (answer != 0 || startedAt == 0) revert SepehrErrors.SequencerDown();
        if (block.timestamp - startedAt <= SEQUENCER_GRACE_PERIOD) {
            revert SepehrErrors.SequencerGracePeriodNotOver(startedAt);
        }
    }

    /// @notice A18: swap-and-pop `protocolKey` out of `_userProtocols[user]`. Preserves O(1) per
    /// removal; ordering is not contractually stable (callers consume the list as an unordered
    /// set). No-op if the key is missing, since `disableProtection` already verifies
    /// `_protections[user][protocolKey].enabled` before calling.
    function _removeUserProtocol(
        address user,
        bytes32 protocolKey
    ) private {
        bytes32[] storage keys = _userProtocols[user];
        uint256 n = keys.length;
        for (uint256 i = 0; i < n; i++) {
            if (keys[i] == protocolKey) {
                if (i != n - 1) keys[i] = keys[n - 1];
                keys.pop();
                return;
            }
        }
    }

    /// @notice Rotate the pause-guardian role to a new address.
    /// @dev Timelock-gated so the guardian cannot be swapped unilaterally by a compromised owner
    /// without the 48h delay announcing it on-chain.
    /// @param newGuardian Replacement guardian address.
    function setPauseGuardian(
        address newGuardian
    ) external onlyExpectedChain onlyTimelock {
        if (newGuardian == address(0)) revert SepehrErrors.ZeroAddress();
        address old = pauseGuardian;
        pauseGuardian = newGuardian;
        emit SepehrEvents.PauseGuardianUpdated(old, newGuardian);
    }

    /// @notice Turn open execution on (a health factor under `MIN_HF_THRESHOLD`) or off (0).
    /// @dev The last resort when every keeper is down: the rescue keeps all its on-chain checks,
    /// and its caller earns the keeper share. Below the lowest threshold, so the keepers act first.
    /// @param hf The health factor under which anyone may rescue, WAD.
    function setOpenExecutionHF(
        uint256 hf
    ) external onlyExpectedChain onlyTimelock {
        if (hf >= MIN_HF_THRESHOLD) revert SepehrErrors.OpenExecutionHFTooHigh(hf, MIN_HF_THRESHOLD);
        emit SepehrEvents.OpenExecutionHFUpdated(openExecutionHF, hf);
        openExecutionHF = hf;
    }

    /// @notice Hand governance to another timelock (a multisig-driven one, for instance).
    /// @dev Called by the current timelock, so the change waits out its delay in public.
    /// @param newTimelock The new sole caller of the timelock-gated setters.
    function setTimelock(
        address newTimelock
    ) external onlyExpectedChain onlyTimelock {
        if (newTimelock == address(0)) revert SepehrErrors.ZeroAddress();
        emit SepehrEvents.TimelockUpdated(timelock, newTimelock);
        timelock = newTimelock;
    }

    // ─── Views ───────────────────────────────────────────────────

    /// @inheritdoc ISepehrCore
    function getProtection(
        address user,
        bytes32 protocolKey
    ) external view override onlyExpectedChain returns (PositionProtection memory) {
        return _protections[user][protocolKey];
    }

    /// @inheritdoc ISepehrCore
    function getExitOrder(
        address user,
        bytes32 protocolKey
    ) external view override onlyExpectedChain returns (ExitOrder memory) {
        return _exitOrders[user][protocolKey];
    }

    /// @inheritdoc ISepehrCore
    function isKeeper(
        address addr
    ) external view override onlyExpectedChain returns (bool) {
        return keepers[addr];
    }

    /// @notice A18: return the ordered list of protocol keys for which `user` has protection
    /// currently enabled. Populated by `enableProtection` / `disableProtection` and cleared by
    /// `unsubscribe`. Ordering is not stable across `disableProtection` calls (swap-and-pop).
    function getUserProtocols(
        address user
    ) external view onlyExpectedChain returns (bytes32[] memory) {
        return _userProtocols[user];
    }

    // ─── Internal ────────────────────────────────────────────────

    /// @dev The user's plan, read from SepehrSubscriptions; reverts without an active one.
    function _requireActiveSubscription(
        address user
    ) internal view returns (ISepehrSubscriptions.Plan memory plan) {
        plan = subscriptions.planOf(user);
        if (plan.tier == 0) revert SepehrErrors.SubscriptionNotFound();
        if (plan.expiresAt <= block.timestamp) revert SepehrErrors.SubscriptionExpired();
    }

    /// @dev What a rescue and a close both require: an active plan, the protection on, the adapter
    /// registered and enabled, the delegation in place, a whitelisted DEX router, and (H01) the
    /// collateral within the plan's cap at execution time, so a position grown after subscribing
    /// gets no protection beyond what its tier pays for. Titan's cap is unbounded.
    function _requireProtectedPosition(
        address user,
        bytes32 protocolKey,
        address dexRouter
    )
        private
        view
        returns (ISepehrSubscriptions.Plan memory plan, PositionProtection storage prot, IProtocolAdapter adapter)
    {
        plan = _requireActiveSubscription(user);
        prot = _protections[user][protocolKey];
        if (!prot.enabled) revert SepehrErrors.ProtectionNotEnabled(user, protocolKey);
        AdapterEntry storage entry = adapters[protocolKey];
        adapter = entry.adapter;
        if (address(adapter) == address(0)) revert SepehrErrors.AdapterNotRegistered(protocolKey);
        if (!entry.enabled) revert SepehrErrors.AdapterDisabled(protocolKey);
        if (!adapter.checkDelegation(user)) revert SepehrErrors.DelegationRevoked(user, protocolKey);
        if (!allowedDexRouters[dexRouter]) revert SepehrErrors.NotAuthorized();
        if (plan.maxCollateralUsd != type(uint256).max) {
            _requireWithinTierCap(adapter.getCollateralValueUsd(user), plan.maxCollateralUsd);
        }
    }

    /// @notice A18: wipe every protection of `user` so a later re-subscribe does not silently
    /// reactivate stale params, and return their snapshots to the TVL running total (G4) in one
    /// write. Gas is O(N) in the user's protected protocols, bounded by the registered adapters.
    function _clearProtections(
        address user
    ) private {
        bytes32[] storage keys = _userProtocols[user];
        uint256 n = keys.length;
        uint256 capRefund;
        for (uint256 i = 0; i < n; i++) {
            bytes32 key = keys[i];
            capRefund += protectionCollateralSnapshot[user][key];
            delete protectionCollateralSnapshot[user][key];
            delete _protections[user][key];
            delete _exitOrders[user][key];
        }
        if (capRefund != 0) {
            protectedCollateralUsd -= capRefund;
        }
        if (n > 0) {
            delete _userProtocols[user];
            emit SepehrEvents.UserProtectionsCleared(user, n);
        }
    }

    /// @notice H01 / L-8: `collateralUsd` must fit the user's tier cap (Titan is unlimited).
    function _requireWithinTierCap(
        uint256 collateralUsd,
        uint256 tierCap
    ) internal pure {
        if (collateralUsd > tierCap) revert SepehrErrors.TierCollateralCapExceeded(collateralUsd, tierCap);
    }

    function _validateProtectionParams(
        uint256 thresholdHF,
        uint256 maxSlippageBps,
        uint256 targetHF
    ) internal pure {
        if (thresholdHF < MIN_HF_THRESHOLD) {
            revert SepehrErrors.ThresholdTooLow(thresholdHF, MIN_HF_THRESHOLD);
        }
        if (targetHF < thresholdHF + MIN_TARGET_GAP) {
            revert SepehrErrors.TargetTooLow(targetHF, thresholdHF + MIN_TARGET_GAP);
        }
        if (targetHF > MAX_TARGET_HF) {
            revert SepehrErrors.TargetTooHigh(targetHF, MAX_TARGET_HF);
        }
        if (maxSlippageBps > MAX_SLIPPAGE_BPS) {
            revert SepehrErrors.InvalidSlippage(maxSlippageBps);
        }
    }

    /// @dev Lot 6: the part of `repayAmount` the user's wallet covers, each unit with its fee at
    /// `feeBps`, within what they let the core take (allowance) and what they hold.
    function _walletRepay(
        address user,
        address asset,
        uint256 repayAmount,
        uint256 feeBps
    ) private view returns (uint256 walletRepay) {
        uint256 available = IERC20(asset).allowance(user, address(this));
        if (available == 0) return 0;
        uint256 balance = IERC20(asset).balanceOf(user);
        if (balance < available) available = balance;
        walletRepay = Math.mulDiv(available, Percentages.BPS_DENOMINATOR, Percentages.BPS_DENOMINATOR + feeBps);
        if (walletRepay > repayAmount) walletRepay = repayAmount;
    }

    /// @dev Lot 6: a rescue the wallet covers in full, `repayAmount` and `totalFee` already
    /// pulled: the debt is repaid without a flash loan or a sale, and what the adapter did not
    /// use goes back to the user.
    function _repayFromWallet(
        IProtocolAdapter adapter,
        address user,
        address debtAsset,
        uint256 repayAmount,
        uint256 totalFee
    ) private {
        uint256 debtHeld = IERC20(debtAsset).balanceOf(address(this)) - repayAmount - totalFee;
        IERC20(debtAsset).safeTransfer(address(adapter), repayAmount);
        adapter.repay(user, debtAsset, repayAmount);
        _returnSurplus(user, debtAsset, IERC20(debtAsset).balanceOf(address(this)) - debtHeld - totalFee);
    }

    /// @dev L-1: when every attempted provider reverts, the last provider's revert data is
    /// re-raised as is, so a slippage, oracle or adapter failure inside the callback reaches the
    /// keeper instead of a generic `NoFlashLoanAvailable` (the `FlashAttemptFailed` events are
    /// rolled back with the transaction). `NoFlashLoanAvailable` is left for the case where no
    /// whitelisted provider could even be attempted, or the last one reverted without data.
    function _borrowFlashLoan(
        address[] calldata providers,
        address asset,
        uint256 amount,
        bytes memory data
    ) internal {
        bytes memory lastFailure;
        for (uint256 i = 0; i < providers.length; i++) {
            if (!allowedFlashProviders[providers[i]]) continue;

            IFlashLoanProvider provider = IFlashLoanProvider(providers[i]);
            if (!provider.isAvailable(asset, amount)) continue;

            _activeFlashProvider = providers[i];
            try provider.flashBorrow(asset, amount, address(this), data) {
                _activeFlashProvider = address(0);
                return;
            } catch (bytes memory reason) {
                // A17: surface the raw revert data so a failing provider (wrong asset, oracle
                // stale, callback hash mismatch, …) is diagnosable from logs. The legacy
                // behavior silently discarded `reason` and fell through to the next provider,
                // making multi-provider fallbacks impossible to debug without replaying each
                // call manually. Indexers can decode selectors from `reason` to classify root
                // causes (e.g. `SepehrErrors.InvalidFlashLoanCallback` indicates session-hash
                // drift rather than upstream-liquidity shortage).
                emit SepehrEvents.FlashAttemptFailed(providers[i], reason);
                _activeFlashProvider = address(0);
                lastFailure = reason;
                continue;
            }
        }
        if (lastFailure.length != 0) {
            assembly ("memory-safe") {
                revert(add(lastFailure, 32), mload(lastFailure))
            }
        }
        revert SepehrErrors.NoFlashLoanAvailable();
    }
}
