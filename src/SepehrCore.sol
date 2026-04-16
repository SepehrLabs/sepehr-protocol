// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ISepehrCallback} from "./interfaces/ISepehrCallback.sol";
import {ISepehrCore} from "./interfaces/ISepehrCore.sol";
import {IDexRouter} from "./interfaces/IDexRouter.sol";
import {IFlashLoanProvider} from "./interfaces/IFlashLoanProvider.sol";
import {IProtocolAdapter} from "./interfaces/IProtocolAdapter.sol";
import {ISubscriptionOracle} from "./interfaces/ISubscriptionOracle.sol";
import {SepehrErrors} from "./libraries/SepehrErrors.sol";
import {SepehrEvents} from "./libraries/SepehrEvents.sol";
import {HealthFactorMath} from "./libraries/HealthFactorMath.sol";
import {Percentages} from "./libraries/Percentages.sol";

contract SepehrCore is ISepehrCore, ISepehrCallback, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Constants ───────────────────────────────────────────────
    uint256 public constant MIN_HF_THRESHOLD = 1.2e18;
    uint256 public constant MAX_REPAY_BPS = 5000;
    uint256 public constant MAX_SLIPPAGE_BPS = 2000;
    uint256 public constant COOLDOWN_SECONDS = 3600;
    uint256 public constant SUBSCRIPTION_PERIOD = 30 days;

    uint256[4] public TIER_PRICES_USD_6 = [
        9_990_000, // $9.99
        29_990_000, // $29.99
        79_990_000, // $79.99
        149_990_000 // $149.99
    ];

    uint256[4] public TIER_MAX_COLLATERAL_USD_8 = [
        10_000e8, // tier 1: up to $10k
        50_000e8, // tier 2: up to $50k
        200_000e8, // tier 3: up to $200k
        type(uint256).max // tier 4: unlimited
    ];

    // ─── State ───────────────────────────────────────────────────
    ISubscriptionOracle public subscriptionOracle;
    address public pauseGuardian;
    address public timelock;
    bool public paused;
    uint256 public feeBps = 30; // 0.3%
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

    uint256 public ownerFeeBalance;
    mapping(address => uint256) public keeperFeeBalances;

    address private _activeFlashProvider;

    // ─── Modifiers ───────────────────────────────────────────────
    modifier whenNotPaused() {
        if (paused) revert SepehrErrors.ContractPaused();
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
    constructor(
        address _owner,
        address _timelock,
        address _pauseGuardian,
        address _subscriptionOracle,
        uint256 _minCollateralUsd,
        uint256 _feeBps
    ) Ownable(_owner) {
        if (_timelock == address(0)) revert SepehrErrors.ZeroAddress();
        if (_pauseGuardian == address(0)) revert SepehrErrors.ZeroAddress();
        if (_subscriptionOracle == address(0)) revert SepehrErrors.ZeroAddress();

        timelock = _timelock;
        pauseGuardian = _pauseGuardian;
        subscriptionOracle = ISubscriptionOracle(_subscriptionOracle);
        minCollateralUsd = _minCollateralUsd;
        feeBps = _feeBps;
    }

    // ─── User: Subscriptions ─────────────────────────────────────

    /// @inheritdoc ISepehrCore
    function subscribe(
        uint8 tier,
        address paymentToken
    ) external override nonReentrant whenNotPaused {
        if (tier == 0 || tier > 4) revert SepehrErrors.InvalidTier();
        if (_subscriptions[msg.sender].expiresAt > block.timestamp) {
            revert SepehrErrors.SubscriptionAlreadyActive();
        }

        uint256 price = TIER_PRICES_USD_6[tier - 1];
        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), price);

        _subscriptions[msg.sender] =
            Subscription({tier: tier, expiresAt: block.timestamp + SUBSCRIPTION_PERIOD, collateralValueUsdSnapshot: 0});

        emit SepehrEvents.Subscribed(msg.sender, block.timestamp + SUBSCRIPTION_PERIOD, tier, block.chainid);
    }

    /// @inheritdoc ISepehrCore
    function renew(
        address paymentToken
    ) external override nonReentrant whenNotPaused {
        Subscription storage sub = _subscriptions[msg.sender];
        if (sub.tier == 0) revert SepehrErrors.SubscriptionNotFound();

        uint256 price = TIER_PRICES_USD_6[sub.tier - 1];
        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), price);

        uint256 baseTime = sub.expiresAt > block.timestamp ? sub.expiresAt : block.timestamp;
        sub.expiresAt = baseTime + SUBSCRIPTION_PERIOD;

        emit SepehrEvents.Renewed(msg.sender, sub.expiresAt, sub.tier);
    }

    /// @inheritdoc ISepehrCore
    function unsubscribe() external override nonReentrant {
        Subscription storage sub = _subscriptions[msg.sender];
        if (sub.tier == 0) revert SepehrErrors.SubscriptionNotFound();

        delete _subscriptions[msg.sender];
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

        if (repayAmount == 0) revert SepehrErrors.ZeroAmount();

        if (!allowedDexRouters[dexRouter]) revert SepehrErrors.NotAuthorized();

        lastTriggerTime[user] = block.timestamp;

        bytes memory callbackData = abi.encode(
            user, protocolKey, debtAsset, collateralAsset, repayAmount, dexRouter, dexRouteData, prot.maxSlippageBps
        );

        _borrowFlashLoan(flashProviders, debtAsset, repayAmount, callbackData);

        uint256 hfAfter = entry.adapter.getHealthFactor(user);
        if (hfAfter < prot.thresholdHF) {
            revert SepehrErrors.PostExecutionHFBelowThreshold(hfAfter, prot.thresholdHF);
        }

        uint256 totalFee = Percentages.applyBps(repayAmount, feeBps);
        (uint256 ownerShare, uint256 keeperShare) = Percentages.splitFee(totalFee);

        ownerFeeBalance += ownerShare;
        keeperFeeBalances[msg.sender] += keeperShare;

        emit SepehrEvents.Triggered(user, protocolKey, msg.sender, repayAmount, 0, hfBefore, hfAfter, totalFee);
        emit SepehrEvents.FeeCollected(msg.sender, totalFee, ownerShare, keeperShare);
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

        (
            address user,
            bytes32 protocolKey,
            address debtAsset,
            address collateralAsset,
            uint256 repayAmount,
            address dexRouter,
            bytes memory dexRouteData,
            uint256 maxSlippageBps
        ) = abi.decode(data, (address, bytes32, address, address, uint256, address, bytes, uint256));

        IProtocolAdapter adapter = adapters[protocolKey].adapter;

        IERC20(debtAsset).safeTransfer(address(adapter), repayAmount);
        adapter.repay(user, debtAsset, repayAmount);

        uint256 collateralNeeded = repayAmount + fee + Percentages.applyBpsRoundUp(repayAmount, feeBps);
        adapter.withdrawCollateral(user, collateralAsset, collateralNeeded, address(this));

        if (collateralAsset != debtAsset) {
            uint256 minOut = repayAmount + fee;
            uint256 minOutWithSlippage = minOut - Percentages.applyBps(minOut, maxSlippageBps);

            IERC20(collateralAsset).safeIncreaseAllowance(dexRouter, collateralNeeded);
            uint256 received = IDexRouter(dexRouter)
                .swap(collateralAsset, debtAsset, collateralNeeded, minOutWithSlippage, dexRouteData);

            if (received < minOut) {
                revert SepehrErrors.SlippageExceeded(received, minOut);
            }
        }

        IERC20(asset).safeTransfer(msg.sender, amount + fee);
    }

    // ─── Fees ────────────────────────────────────────────────────

    function withdrawOwnerFees(
        address token,
        address to
    ) external nonReentrant {
        if (msg.sender != owner()) revert SepehrErrors.NotOwner();
        uint256 amount = ownerFeeBalance;
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        ownerFeeBalance = 0;
        IERC20(token).safeTransfer(to, amount);
        emit SepehrEvents.OwnerFeesWithdrawn(to, amount);
    }

    function withdrawKeeperFees(
        address token
    ) external nonReentrant {
        uint256 amount = keeperFeeBalances[msg.sender];
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        keeperFeeBalances[msg.sender] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit SepehrEvents.KeeperFeesWithdrawn(msg.sender, amount);
    }

    // ─── Pause ───────────────────────────────────────────────────

    function pause() external onlyPauseGuardianOrOwner {
        paused = true;
        emit SepehrEvents.EmergencyPaused(msg.sender);
    }

    function unpause() external {
        if (msg.sender != owner()) revert SepehrErrors.NotOwner();
        paused = false;
        emit SepehrEvents.Unpaused(msg.sender);
    }

    // ─── Admin (Timelock-gated) ──────────────────────────────────

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

    function removeAdapter(
        bytes32 protocolKey
    ) external onlyTimelock {
        if (address(adapters[protocolKey].adapter) == address(0)) {
            revert SepehrErrors.AdapterNotRegistered(protocolKey);
        }
        delete adapters[protocolKey];
        emit SepehrEvents.AdapterRemoved(protocolKey);
    }

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

    function addKeeper(
        address keeper
    ) external onlyTimelock {
        if (keeper == address(0)) revert SepehrErrors.ZeroAddress();
        keepers[keeper] = true;
        emit SepehrEvents.KeeperAdded(keeper);
    }

    function removeKeeper(
        address keeper
    ) external onlyTimelock {
        keepers[keeper] = false;
        emit SepehrEvents.KeeperRemoved(keeper);
    }

    function setFeeBps(
        uint256 newFeeBps
    ) external onlyTimelock {
        uint256 old = feeBps;
        feeBps = newFeeBps;
        emit SepehrEvents.FeeBpsUpdated(old, newFeeBps);
    }

    function addFlashLoanProvider(
        address provider
    ) external onlyTimelock {
        if (provider == address(0)) revert SepehrErrors.ZeroAddress();
        allowedFlashProviders[provider] = true;
        emit SepehrEvents.FlashLoanProviderAdded(provider);
    }

    function removeFlashLoanProvider(
        address provider
    ) external onlyTimelock {
        allowedFlashProviders[provider] = false;
        emit SepehrEvents.FlashLoanProviderRemoved(provider);
    }

    function addDexRouter(
        address router
    ) external onlyTimelock {
        if (router == address(0)) revert SepehrErrors.ZeroAddress();
        allowedDexRouters[router] = true;
    }

    function removeDexRouter(
        address router
    ) external onlyTimelock {
        allowedDexRouters[router] = false;
    }

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
