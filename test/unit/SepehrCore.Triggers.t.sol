// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {SepehrCore} from "../../src/SepehrCore.sol";
import {ISepehrCore} from "../../src/interfaces/ISepehrCore.sol";
import {Percentages} from "../../src/libraries/Percentages.sol";
import {SepehrErrors} from "../../src/libraries/SepehrErrors.sol";
import {SepehrEvents} from "../../src/libraries/SepehrEvents.sol";
import {MockAdapter} from "../../src/mocks/MockAdapter.sol";
import {MockDex} from "../../src/mocks/MockDex.sol";
import {MockFlashLoan} from "../../src/mocks/MockFlashLoan.sol";
import {MockOracle} from "../../src/mocks/MockOracle.sol";

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
    MockOracle public oracle;
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
    uint256 public constant REPAY_VALUE_USD6 = 1000e6;
    uint256 public constant HF_BELOW_THRESHOLD = 1.1e18;
    uint256 public constant HF_ABOVE_THRESHOLD = 1.5e18;
    uint256 public constant THRESHOLD_HF = 1.3e18;
    uint256 public constant MONTHLY_PERIOD = 30 days;

    // Shield tier fee: 20 bps (0.20%)
    uint256 public constant SHIELD_FEE_BPS = 20;

    function setUp() public {
        vm.warp(10_000);

        oracle = new MockOracle();
        adapter = new MockAdapter();
        flashLoan = new MockFlashLoan();
        dex = new MockDex();
        usdc = new MockERC20("USDC", "USDC");
        debtToken = new MockERC20("Debt Token", "DEBT");
        collateralToken = new MockERC20("Collateral Token", "COLL");

        core = new SepehrCore(address(this), timelock, guardian, address(oracle), address(usdc), 500e8);

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
        core.execute(
            alice,
            seqKey,
            address(debtToken),
            address(debtToken),
            REPAY_AMOUNT,
            REPAY_VALUE_USD6,
            providers,
            address(dex),
            ""
        );

        assertEq(core.lastTriggerTime(alice), block.timestamp);

        // Fee uses per-tier BPS (Shield = 20 bps). Per-asset accounting separates the Shield
        // monthly subscription ($9 USDC, 6 decimals) from the trigger fee in the debt asset.
        uint256 totalFee = Percentages.applyBps(REPAY_AMOUNT, SHIELD_FEE_BPS);
        (uint256 ownerShare, uint256 keeperShare) = Percentages.splitFee(totalFee);
        uint256 shieldMonthly = 9_000_000;
        assertEq(core.ownerFeeBalances(address(debtToken)), ownerShare);
        assertEq(core.ownerFeeBalances(address(usdc)), shieldMonthly);
        assertEq(core.keeperFeeBalances(keeper, address(debtToken)), keeperShare);
    }

    function test_execute_updatesSaveCredits() public {
        SequentialMockAdapter seqAdapter = new SequentialMockAdapter(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        seqAdapter.setDelegation(alice, true);
        debtToken.mint(address(seqAdapter), REPAY_AMOUNT * 10);

        bytes32 seqKey = keccak256("SAVE_CREDIT_PROTOCOL");
        vm.prank(timelock);
        core.addAdapter(seqKey, address(seqAdapter));

        vm.prank(alice);
        core.enableProtection(seqKey, THRESHOLD_HF, 250, 2500);

        address[] memory providers = _buildFlashProviders();

        vm.prank(keeper);
        core.execute(
            alice,
            seqKey,
            address(debtToken),
            address(debtToken),
            REPAY_AMOUNT,
            REPAY_VALUE_USD6,
            providers,
            address(dex),
            ""
        );

        assertEq(core.getSaveCredits(alice), REPAY_VALUE_USD6);
    }

    function test_execute_saveCreditsCumulative() public {
        SequentialMockAdapter seqAdapter = new SequentialMockAdapter(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        seqAdapter.setDelegation(alice, true);
        debtToken.mint(address(seqAdapter), REPAY_AMOUNT * 20);

        bytes32 seqKey = keccak256("CUMULATIVE_PROTOCOL");
        vm.prank(timelock);
        core.addAdapter(seqKey, address(seqAdapter));

        vm.prank(alice);
        core.enableProtection(seqKey, THRESHOLD_HF, 250, 2500);

        address[] memory providers = _buildFlashProviders();

        // First execution
        vm.prank(keeper);
        core.execute(
            alice,
            seqKey,
            address(debtToken),
            address(debtToken),
            REPAY_AMOUNT,
            REPAY_VALUE_USD6,
            providers,
            address(dex),
            ""
        );

        // Warp past cooldown, reset adapter
        vm.warp(block.timestamp + 3601);
        seqAdapter.reset(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        debtToken.mint(address(flashLoan), REPAY_AMOUNT * 10);

        // Second execution
        vm.prank(keeper);
        core.execute(
            alice,
            seqKey,
            address(debtToken),
            address(debtToken),
            REPAY_AMOUNT,
            REPAY_VALUE_USD6,
            providers,
            address(dex),
            ""
        );

        assertEq(core.getSaveCredits(alice), REPAY_VALUE_USD6 * 2);
    }

    function test_execute_emitsSaveCreditEvent() public {
        SequentialMockAdapter seqAdapter = new SequentialMockAdapter(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        seqAdapter.setDelegation(alice, true);
        debtToken.mint(address(seqAdapter), REPAY_AMOUNT * 10);

        bytes32 seqKey = keccak256("SAVE_EVENT_PROTOCOL");
        vm.prank(timelock);
        core.addAdapter(seqKey, address(seqAdapter));

        vm.prank(alice);
        core.enableProtection(seqKey, THRESHOLD_HF, 250, 2500);

        address[] memory providers = _buildFlashProviders();

        vm.expectEmit(true, false, false, true, address(core));
        emit SepehrEvents.SaveCreditAccrued(alice, REPAY_VALUE_USD6, REPAY_VALUE_USD6);

        vm.prank(keeper);
        core.execute(
            alice,
            seqKey,
            address(debtToken),
            address(debtToken),
            REPAY_AMOUNT,
            REPAY_VALUE_USD6,
            providers,
            address(dex),
            ""
        );
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
        core.execute(
            alice,
            seqKey,
            address(debtToken),
            address(debtToken),
            REPAY_AMOUNT,
            REPAY_VALUE_USD6,
            providers,
            address(dex),
            ""
        );
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

        vm.expectEmit(true, false, false, true, address(core));
        emit SepehrEvents.FeeCollected(keeper, totalFee, ownerShare, keeperShare);

        vm.prank(keeper);
        core.execute(
            alice,
            seqKey,
            address(debtToken),
            address(debtToken),
            REPAY_AMOUNT,
            REPAY_VALUE_USD6,
            providers,
            address(dex),
            ""
        );
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
        core.execute(
            bob,
            seqKey,
            address(debtToken),
            address(debtToken),
            REPAY_AMOUNT,
            REPAY_VALUE_USD6,
            providers,
            address(dex),
            ""
        );

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
            alice,
            PROTOCOL_KEY,
            address(debtToken),
            address(collateralToken),
            REPAY_AMOUNT,
            REPAY_VALUE_USD6,
            providers,
            address(dex),
            ""
        );
    }

    function test_execute_revertsWhenPaused() public {
        core.pause();
        address[] memory providers = _buildFlashProviders();

        vm.expectRevert(SepehrErrors.ContractPaused.selector);
        vm.prank(keeper);
        core.execute(
            alice,
            PROTOCOL_KEY,
            address(debtToken),
            address(collateralToken),
            REPAY_AMOUNT,
            REPAY_VALUE_USD6,
            providers,
            address(dex),
            ""
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
            alice,
            PROTOCOL_KEY,
            address(debtToken),
            address(collateralToken),
            REPAY_AMOUNT,
            REPAY_VALUE_USD6,
            providers,
            address(dex),
            ""
        );
    }

    function test_execute_revertsOnCooldown() public {
        SequentialMockAdapter seqAdapter = new SequentialMockAdapter(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        seqAdapter.setDelegation(alice, true);
        debtToken.mint(address(seqAdapter), REPAY_AMOUNT * 10);

        bytes32 seqKey = keccak256("COOLDOWN_PROTOCOL");
        vm.prank(timelock);
        core.addAdapter(seqKey, address(seqAdapter));
        vm.prank(alice);
        core.enableProtection(seqKey, THRESHOLD_HF, 250, 2500);

        address[] memory providers = _buildFlashProviders();

        vm.prank(keeper);
        core.execute(
            alice,
            seqKey,
            address(debtToken),
            address(debtToken),
            REPAY_AMOUNT,
            REPAY_VALUE_USD6,
            providers,
            address(dex),
            ""
        );

        seqAdapter.reset(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);

        uint256 remaining = 3600;
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.CooldownActive.selector, remaining));
        vm.prank(keeper);
        core.execute(
            alice,
            seqKey,
            address(debtToken),
            address(debtToken),
            REPAY_AMOUNT,
            REPAY_VALUE_USD6,
            providers,
            address(dex),
            ""
        );
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
        core.execute(
            alice,
            seqKey,
            address(debtToken),
            address(debtToken),
            REPAY_AMOUNT,
            REPAY_VALUE_USD6,
            providers,
            address(dex),
            ""
        );

        vm.warp(block.timestamp + 3601);
        seqAdapter.reset(HF_BELOW_THRESHOLD, HF_ABOVE_THRESHOLD);
        debtToken.mint(address(flashLoan), REPAY_AMOUNT * 10);

        vm.prank(keeper);
        core.execute(
            alice,
            seqKey,
            address(debtToken),
            address(debtToken),
            REPAY_AMOUNT,
            REPAY_VALUE_USD6,
            providers,
            address(dex),
            ""
        );
    }

    function test_execute_revertsWhenSubscriptionExpired() public {
        vm.warp(block.timestamp + MONTHLY_PERIOD + 1);

        address[] memory providers = _buildFlashProviders();

        vm.expectRevert(SepehrErrors.SubscriptionExpired.selector);
        vm.prank(keeper);
        core.execute(
            alice,
            PROTOCOL_KEY,
            address(debtToken),
            address(collateralToken),
            REPAY_AMOUNT,
            REPAY_VALUE_USD6,
            providers,
            address(dex),
            ""
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
            alice,
            unknownKey,
            address(debtToken),
            address(collateralToken),
            REPAY_AMOUNT,
            REPAY_VALUE_USD6,
            providers,
            address(dex),
            ""
        );
    }

    function test_execute_revertsWhenDelegationRevoked() public {
        adapter.setDelegation(alice, false);

        address[] memory providers = _buildFlashProviders();

        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.DelegationRevoked.selector, alice, PROTOCOL_KEY));
        vm.prank(keeper);
        core.execute(
            alice,
            PROTOCOL_KEY,
            address(debtToken),
            address(collateralToken),
            REPAY_AMOUNT,
            REPAY_VALUE_USD6,
            providers,
            address(dex),
            ""
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
            REPAY_VALUE_USD6,
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
            alice,
            PROTOCOL_KEY,
            address(debtToken),
            address(collateralToken),
            REPAY_AMOUNT,
            REPAY_VALUE_USD6,
            providers,
            address(dex),
            ""
        );
    }

    function test_execute_revertsOnZeroRepayAmount() public {
        adapter.setHealthFactor(alice, HF_BELOW_THRESHOLD);
        address[] memory providers = _buildFlashProviders();

        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        vm.prank(keeper);
        core.execute(
            alice, PROTOCOL_KEY, address(debtToken), address(collateralToken), 0, 0, providers, address(dex), ""
        );
    }

    function test_execute_revertsOnUnauthorizedDexRouter() public {
        adapter.setHealthFactor(alice, HF_BELOW_THRESHOLD);
        address[] memory providers = _buildFlashProviders();
        address fakeDex = makeAddr("fakeDex");

        vm.expectRevert(SepehrErrors.NotAuthorized.selector);
        vm.prank(keeper);
        core.execute(
            alice,
            PROTOCOL_KEY,
            address(debtToken),
            address(collateralToken),
            REPAY_AMOUNT,
            REPAY_VALUE_USD6,
            providers,
            fakeDex,
            ""
        );
    }

    function test_execute_revertsWhenNoSubscription() public {
        address bob = makeAddr("bob");
        address[] memory providers = _buildFlashProviders();

        vm.expectRevert(SepehrErrors.SubscriptionNotFound.selector);
        vm.prank(keeper);
        core.execute(
            bob,
            PROTOCOL_KEY,
            address(debtToken),
            address(collateralToken),
            REPAY_AMOUNT,
            REPAY_VALUE_USD6,
            providers,
            address(dex),
            ""
        );
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
    ) external {
        ERC20(debtAsset).transfer(address(0xdead), amount);
        currentHF = postRepayHF;
    }

    function withdrawCollateral(
        address,
        address collateralAsset,
        uint256 amount,
        address recipient
    ) external {
        ERC20(collateralAsset).transfer(recipient, amount);
    }

    function getCollateralValueUsd(
        address
    ) external pure returns (uint256) {
        return 100_000e8;
    }
}
