// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {GearboxAdapter} from "../../../src/adapters/GearboxAdapter.sol";
import {AegisErrors} from "../../../src/libraries/AegisErrors.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {MockBotList, MockCreditFacade, MockCreditManager} from "../../helpers/MockGearbox.sol";
import {Test} from "forge-std/Test.sol";

contract GearboxAdapterTest is Test {
    uint256 internal constant HF_BP_TO_WAD = 1e14;

    GearboxAdapter internal adapter;
    MockCreditManager internal creditManager;
    MockCreditFacade internal facade;
    MockBotList internal botList;
    MockERC20 internal debtToken;
    MockERC20 internal collateralToken;

    address internal user = makeAddr("user");
    address internal recipient = makeAddr("recipient");
    address internal creditAccount = makeAddr("creditAccount");

    function setUp() public {
        debtToken = new MockERC20("Debt Token", "DEBT");
        collateralToken = new MockERC20("Collateral", "COL");
        facade = new MockCreditFacade();
        creditManager = new MockCreditManager(address(facade));
        botList = new MockBotList();

        adapter = new GearboxAdapter(address(creditManager), address(botList));
    }

    // ─── Constructor ───────────────────────────────────────────────────

    function test_constructor_revertsOnZeroCreditManager() public {
        vm.expectRevert(AegisErrors.ZeroAddress.selector);
        new GearboxAdapter(address(0), address(botList));
    }

    function test_constructor_revertsOnZeroBotList() public {
        vm.expectRevert(AegisErrors.ZeroAddress.selector);
        new GearboxAdapter(address(creditManager), address(0));
    }

    function test_constructor_storesImmutables() public view {
        assertEq(address(adapter.CREDIT_MANAGER()), address(creditManager));
        assertEq(address(adapter.BOT_LIST()), address(botList));
    }

    // ─── getHealthFactor ───────────────────────────────────────────────

    function test_getHealthFactor_returnsMaxWhenNoCreditAccount() public view {
        // creditAccounts(user) defaults to address(0)
        assertEq(adapter.getHealthFactor(user), type(uint256).max);
    }

    function test_getHealthFactor_convertsFromBasisPoints() public {
        creditManager.setCreditAccount(user, creditAccount);
        // hfBp = 10_000 (1.0 in BP) → 10_000 * 1e14 = 1e18
        creditManager.setDebtAndCollateral(creditAccount, 100e18, 0, 0, 0, 100e8, 200e8, 150e8, 10_000);

        assertEq(adapter.getHealthFactor(user), 1e18);
    }

    function test_getHealthFactor_belowOne() public {
        creditManager.setCreditAccount(user, creditAccount);
        // hfBp = 9_000 (0.9) → 9_000 * 1e14 = 0.9e18
        creditManager.setDebtAndCollateral(creditAccount, 100e18, 0, 0, 0, 100e8, 180e8, 135e8, 9000);

        assertEq(adapter.getHealthFactor(user), 9000 * HF_BP_TO_WAD);
    }

    function test_getHealthFactor_aboveOne() public {
        creditManager.setCreditAccount(user, creditAccount);
        // hfBp = 15_000 (1.5) → 15_000 * 1e14 = 1.5e18
        creditManager.setDebtAndCollateral(creditAccount, 100e18, 0, 0, 0, 100e8, 300e8, 225e8, 15_000);

        assertEq(adapter.getHealthFactor(user), 1.5e18);
    }

    function test_getHealthFactor_differentUsers() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address aliceAccount = makeAddr("aliceAccount");
        address bobAccount = makeAddr("bobAccount");

        creditManager.setCreditAccount(alice, aliceAccount);
        creditManager.setCreditAccount(bob, bobAccount);
        creditManager.setDebtAndCollateral(aliceAccount, 0, 0, 0, 0, 0, 0, 0, 20_000);
        creditManager.setDebtAndCollateral(bobAccount, 0, 0, 0, 0, 0, 0, 0, 5000);

        assertEq(adapter.getHealthFactor(alice), 2e18);
        assertEq(adapter.getHealthFactor(bob), 0.5e18);
    }

    // ─── checkDelegation ───────────────────────────────────────────────

    function test_checkDelegation_returnsFalseWhenNoCreditAccount() public view {
        assertFalse(adapter.checkDelegation(user));
    }

    function test_checkDelegation_returnsTrueWhenPermissionsAndNotForbidden() public {
        creditManager.setCreditAccount(user, creditAccount);
        botList.setBotStatus(address(creditManager), creditAccount, address(adapter), 1, false, false);

        assertTrue(adapter.checkDelegation(user));
    }

    function test_checkDelegation_returnsFalseWhenForbidden() public {
        creditManager.setCreditAccount(user, creditAccount);
        botList.setBotStatus(address(creditManager), creditAccount, address(adapter), 1, true, false);

        assertFalse(adapter.checkDelegation(user));
    }

    function test_checkDelegation_returnsFalseWhenZeroPermissions() public {
        creditManager.setCreditAccount(user, creditAccount);
        botList.setBotStatus(address(creditManager), creditAccount, address(adapter), 0, false, false);

        assertFalse(adapter.checkDelegation(user));
    }

    function test_checkDelegation_returnsFalseWhenBothZeroAndForbidden() public {
        creditManager.setCreditAccount(user, creditAccount);
        botList.setBotStatus(address(creditManager), creditAccount, address(adapter), 0, true, false);

        assertFalse(adapter.checkDelegation(user));
    }

    // ─── repay ─────────────────────────────────────────────────────────

    function test_repay_revertsOnZeroAmount() public {
        vm.expectRevert(AegisErrors.ZeroAmount.selector);
        adapter.repay(user, address(debtToken), 0);
    }

    function test_repay_revertsWhenNoCreditAccount() public {
        vm.expectRevert(AegisErrors.ZeroAddress.selector);
        adapter.repay(user, address(debtToken), 100e18);
    }

    function test_repay_transfersTokensAndCallsBotMulticall() public {
        uint256 amount = 100e18;
        creditManager.setCreditAccount(user, creditAccount);
        debtToken.mint(address(adapter), amount);

        adapter.repay(user, address(debtToken), amount);

        // Tokens transferred to creditAccount
        assertEq(debtToken.balanceOf(creditAccount), amount);
        assertEq(debtToken.balanceOf(address(adapter)), 0);

        // botMulticall was called
        assertEq(facade.botMulticallCount(), 1);
        (address account, bytes[] memory calls) = facade.getBotMulticall(0);
        assertEq(account, creditAccount);
        assertEq(calls.length, 1);

        // Verify the encoded call is decreaseDebt(uint256)
        bytes memory expectedCall = abi.encodeWithSignature("decreaseDebt(uint256)", amount);
        assertEq(calls[0], expectedCall);
    }

    // ─── withdrawCollateral ────────────────────────────────────────────

    function test_withdrawCollateral_revertsOnZeroAmount() public {
        vm.expectRevert(AegisErrors.ZeroAmount.selector);
        adapter.withdrawCollateral(user, address(collateralToken), 0, recipient);
    }

    function test_withdrawCollateral_revertsOnZeroRecipient() public {
        vm.expectRevert(AegisErrors.ZeroAddress.selector);
        adapter.withdrawCollateral(user, address(collateralToken), 1e18, address(0));
    }

    function test_withdrawCollateral_revertsWhenNoCreditAccount() public {
        vm.expectRevert(AegisErrors.ZeroAddress.selector);
        adapter.withdrawCollateral(user, address(collateralToken), 1e18, recipient);
    }

    function test_withdrawCollateral_callsBotMulticall() public {
        uint256 amount = 50e18;
        creditManager.setCreditAccount(user, creditAccount);

        adapter.withdrawCollateral(user, address(collateralToken), amount, recipient);

        assertEq(facade.botMulticallCount(), 1);
        (address account, bytes[] memory calls) = facade.getBotMulticall(0);
        assertEq(account, creditAccount);
        assertEq(calls.length, 1);

        bytes memory expectedCall = abi.encodeWithSignature(
            "withdrawCollateral(address,uint256,address)", address(collateralToken), amount, recipient
        );
        assertEq(calls[0], expectedCall);
    }

    // ─── getCollateralValueUsd ─────────────────────────────────────────

    function test_getCollateralValueUsd_returnsZeroWhenNoCreditAccount() public view {
        assertEq(adapter.getCollateralValueUsd(user), 0);
    }

    function test_getCollateralValueUsd_returnsTotalValueUSD() public {
        uint256 totalValueUSD = 500_000e8;
        creditManager.setCreditAccount(user, creditAccount);
        creditManager.setDebtAndCollateral(creditAccount, 100e18, 0, 0, 0, 100e8, totalValueUSD, 375_000e8, 15_000);

        assertEq(adapter.getCollateralValueUsd(user), totalValueUSD);
    }

    function test_getCollateralValueUsd_differentUsers() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address aliceAccount = makeAddr("aliceAccount");
        address bobAccount = makeAddr("bobAccount");

        creditManager.setCreditAccount(alice, aliceAccount);
        creditManager.setCreditAccount(bob, bobAccount);
        creditManager.setDebtAndCollateral(aliceAccount, 0, 0, 0, 0, 0, 100e8, 0, 0);
        creditManager.setDebtAndCollateral(bobAccount, 0, 0, 0, 0, 0, 200e8, 0, 0);

        assertEq(adapter.getCollateralValueUsd(alice), 100e8);
        assertEq(adapter.getCollateralValueUsd(bob), 200e8);
    }

    // ─── Fuzz tests ────────────────────────────────────────────────────

    function testFuzz_getHealthFactor_noCreditAccountReturnsMax(
        address randomUser
    ) public view {
        // No creditAccount set → always returns max
        assertEq(adapter.getHealthFactor(randomUser), type(uint256).max);
    }

    function testFuzz_getHealthFactor_conversion(
        uint256 hfBp
    ) public {
        hfBp = bound(hfBp, 0, type(uint64).max);
        creditManager.setCreditAccount(user, creditAccount);
        creditManager.setDebtAndCollateral(creditAccount, 0, 0, 0, 0, 0, 0, 0, hfBp);

        assertEq(adapter.getHealthFactor(user), hfBp * HF_BP_TO_WAD);
    }

    function testFuzz_repayAmount(
        uint256 amount
    ) public {
        amount = bound(amount, 1, type(uint128).max);
        creditManager.setCreditAccount(user, creditAccount);
        debtToken.mint(address(adapter), amount);

        adapter.repay(user, address(debtToken), amount);

        assertEq(debtToken.balanceOf(creditAccount), amount);
        assertEq(facade.botMulticallCount(), 1);
    }

    function testFuzz_getCollateralValueUsd(
        uint256 totalValueUSD
    ) public {
        creditManager.setCreditAccount(user, creditAccount);
        creditManager.setDebtAndCollateral(creditAccount, 0, 0, 0, 0, 0, totalValueUSD, 0, 0);

        assertEq(adapter.getCollateralValueUsd(user), totalValueUSD);
    }
}
