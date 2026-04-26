// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CompoundV3Adapter} from "../../../src/adapters/CompoundV3Adapter.sol";
import {SepehrErrors} from "../../../src/libraries/SepehrErrors.sol";
import {MockComet} from "../../helpers/MockComet.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {Test} from "forge-std/Test.sol";

contract CompoundV3AdapterTest is Test {
    CompoundV3Adapter adapter;
    MockComet comet;
    MockERC20 debtToken;
    MockERC20 collateralA;
    MockERC20 collateralB;

    address user = makeAddr("user");
    address recipient = makeAddr("recipient");
    address priceFeedA = makeAddr("priceFeedA");
    address priceFeedB = makeAddr("priceFeedB");
    address basePriceFeed = makeAddr("basePriceFeed");
    address internal core = makeAddr("core");

    function setUp() public {
        comet = new MockComet();
        debtToken = new MockERC20("USDC", "USDC");
        collateralA = new MockERC20("WETH", "WETH");
        collateralB = new MockERC20("WBTC", "WBTC");

        comet.setBaseTokenPriceFeed(basePriceFeed);

        adapter = new CompoundV3Adapter(address(comet), core);
    }

    // ── Constructor ──────────────────────────────────────────────────────

    function test_constructor_setsComet() public view {
        assertEq(address(adapter.COMET()), address(comet));
        assertEq(adapter.core(), core);
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new CompoundV3Adapter(address(0), core);
    }

    function test_constructor_revertsOnZeroCore() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new CompoundV3Adapter(address(comet), address(0));
    }

    // ── getHealthFactor ──────────────────────────────────────────────────

    function test_getHealthFactor_returnsMaxWhenNoBorrow() public view {
        assertEq(adapter.getHealthFactor(user), type(uint256).max);
    }

    function test_getHealthFactor_calculatesWithOneAsset() public {
        // Setup: 1 ETH collateral at $2000, borrow $1000 USDC
        // scale = 1e18, liquidateCollateralFactor = 0.85e18
        comet.addAsset(0, address(collateralA), priceFeedA, 1e18, 0.8e18, 0.85e18, 0.9e18, type(uint128).max);
        comet.setCollateralBalance(user, address(collateralA), 1e18);
        comet.setPrice(priceFeedA, 2000e6); // $2000 in 6 decimals
        comet.setBorrowBalance(user, 1000e6); // 1000 USDC (6 decimals)
        comet.setPrice(basePriceFeed, 1e6); // $1 base price

        uint256 hf = adapter.getHealthFactor(user);

        // collateralValue = 1e18 * 2000e6 * 0.85e18 / (1e18 * 1e18) = 1700e6
        // borrowValueUsd = 1000e6 * 1e6 / 1e6 = 1000e6
        // hf = 1700e6 * 1e18 / 1000e6 = 1.7e18
        assertEq(hf, 1.7e18);
    }

    function test_getHealthFactor_calculatesWithMultipleAssets() public {
        // Asset A: 2 ETH at $2000 each, lcf=0.85e18, scale=1e18
        comet.addAsset(0, address(collateralA), priceFeedA, 1e18, 0.8e18, 0.85e18, 0.9e18, type(uint128).max);
        // Asset B: 0.1 BTC at $30000, lcf=0.80e18, scale=1e8
        comet.addAsset(1, address(collateralB), priceFeedB, 1e8, 0.75e18, 0.8e18, 0.85e18, type(uint128).max);

        comet.setCollateralBalance(user, address(collateralA), 2e18);
        comet.setCollateralBalance(user, address(collateralB), 0.1e8);
        comet.setPrice(priceFeedA, 2000e6);
        comet.setPrice(priceFeedB, 30_000e6);
        comet.setBorrowBalance(user, 2000e6);
        comet.setPrice(basePriceFeed, 1e6);

        uint256 hf = adapter.getHealthFactor(user);

        // collValueA = 2e18 * 2000e6 * 0.85e18 / (1e18 * 1e18) = 3400e6
        // collValueB = 0.1e8 * 30000e6 * 0.80e18 / (1e8 * 1e18) = 2400e6
        // total = 5800e6
        // borrowUsd = 2000e6 * 1e6 / 1e6 = 2000e6
        // hf = 5800e6 * 1e18 / 2000e6 = 2.9e18
        assertEq(hf, 2.9e18);
    }

    function test_getHealthFactor_returnsMaxWhenBorrowValueUsdIsZero() public {
        // Borrow balance > 0 but base price = 0 => borrowValueUsd = 0 => max
        comet.addAsset(0, address(collateralA), priceFeedA, 1e18, 0.8e18, 0.85e18, 0.9e18, type(uint128).max);
        comet.setCollateralBalance(user, address(collateralA), 1e18);
        comet.setPrice(priceFeedA, 2000e6);
        comet.setBorrowBalance(user, 1000e6);
        comet.setPrice(basePriceFeed, 0);

        assertEq(adapter.getHealthFactor(user), type(uint256).max);
    }

    function test_getHealthFactor_skipsAssetsWithZeroBalance() public {
        comet.addAsset(0, address(collateralA), priceFeedA, 1e18, 0.8e18, 0.85e18, 0.9e18, type(uint128).max);
        comet.addAsset(1, address(collateralB), priceFeedB, 1e8, 0.75e18, 0.8e18, 0.85e18, type(uint128).max);

        // Only asset A has balance
        comet.setCollateralBalance(user, address(collateralA), 1e18);
        // collateralB balance is 0 by default
        comet.setPrice(priceFeedA, 2000e6);
        comet.setPrice(priceFeedB, 30_000e6);
        comet.setBorrowBalance(user, 1000e6);
        comet.setPrice(basePriceFeed, 1e6);

        uint256 hf = adapter.getHealthFactor(user);

        // Only collateralA contributes: 1e18 * 2000e6 * 0.85e18 / (1e18 * 1e18) = 1700e6
        // borrowUsd = 1000e6
        // hf = 1700e6 * 1e18 / 1000e6 = 1.7e18
        assertEq(hf, 1.7e18);
    }

    // ── checkDelegation ──────────────────────────────────────────────────

    function test_checkDelegation_returnsTrueWhenAllowed() public {
        comet.setAllowed(user, address(adapter), true);
        assertTrue(adapter.checkDelegation(user));
    }

    function test_checkDelegation_returnsFalseWhenNotAllowed() public view {
        assertFalse(adapter.checkDelegation(user));
    }

    // ── repay ────────────────────────────────────────────────────────────

    function test_repay_revertsWhenNotCore() public {
        vm.expectRevert(SepehrErrors.NotAuthorized.selector);
        adapter.repay(user, address(debtToken), 1e18);
    }

    function test_repay_revertsOnZeroAmount() public {
        vm.prank(core);
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        adapter.repay(user, address(debtToken), 0);
    }

    function test_repay_callsSupplyToWithCorrectArgs() public {
        uint256 repayAmount = 500e6;
        debtToken.mint(address(adapter), repayAmount);

        vm.prank(core);
        adapter.repay(user, address(debtToken), repayAmount);

        assertEq(comet.lastSupplyToDst(), user);
        assertEq(comet.lastSupplyToAsset(), address(debtToken));
        assertEq(comet.lastSupplyToAmount(), repayAmount);
    }

    function test_repay_transfersTokensToComet() public {
        uint256 repayAmount = 500e6;
        debtToken.mint(address(adapter), repayAmount);

        vm.prank(core);
        adapter.repay(user, address(debtToken), repayAmount);

        assertEq(debtToken.balanceOf(address(comet)), repayAmount);
        assertEq(debtToken.balanceOf(address(adapter)), 0);
    }

    // ── withdrawCollateral ───────────────────────────────────────────────

    function test_withdrawCollateral_revertsWhenNotCore() public {
        vm.expectRevert(SepehrErrors.NotAuthorized.selector);
        adapter.withdrawCollateral(user, address(collateralA), 1e18, recipient);
    }

    function test_withdrawCollateral_revertsOnZeroAmount() public {
        vm.prank(core);
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        adapter.withdrawCollateral(user, address(collateralA), 0, recipient);
    }

    function test_withdrawCollateral_revertsOnZeroRecipient() public {
        vm.prank(core);
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        adapter.withdrawCollateral(user, address(collateralA), 1e18, address(0));
    }

    function test_withdrawCollateral_callsWithdrawFromCorrectly() public {
        uint256 amount = 1e18;

        vm.prank(core);
        adapter.withdrawCollateral(user, address(collateralA), amount, recipient);

        assertEq(comet.lastWithdrawFromSrc(), user);
        assertEq(comet.lastWithdrawFromTo(), recipient);
        assertEq(comet.lastWithdrawFromAsset(), address(collateralA));
        assertEq(comet.lastWithdrawFromAmount(), amount);
    }

    // ── getCollateralValueUsd ────────────────────────────────────────────

    function test_getCollateralValueUsd_singleAsset() public {
        comet.addAsset(0, address(collateralA), priceFeedA, 1e18, 0.8e18, 0.85e18, 0.9e18, type(uint128).max);
        comet.setCollateralBalance(user, address(collateralA), 5e18);
        comet.setPrice(priceFeedA, 2000e6);

        uint256 value = adapter.getCollateralValueUsd(user);
        // 5e18 * 2000e6 / 1e18 = 10_000e6
        assertEq(value, 10_000e6);
    }

    function test_getCollateralValueUsd_multipleAssets() public {
        comet.addAsset(0, address(collateralA), priceFeedA, 1e18, 0.8e18, 0.85e18, 0.9e18, type(uint128).max);
        comet.addAsset(1, address(collateralB), priceFeedB, 1e8, 0.75e18, 0.8e18, 0.85e18, type(uint128).max);

        comet.setCollateralBalance(user, address(collateralA), 2e18);
        comet.setCollateralBalance(user, address(collateralB), 1e8);
        comet.setPrice(priceFeedA, 2000e6);
        comet.setPrice(priceFeedB, 30_000e6);

        uint256 value = adapter.getCollateralValueUsd(user);
        // A: 2e18 * 2000e6 / 1e18 = 4000e6
        // B: 1e8 * 30_000e6 / 1e8 = 30_000e6
        // total = 34_000e6
        assertEq(value, 34_000e6);
    }

    function test_getCollateralValueUsd_zeroWhenNoCollateral() public {
        comet.addAsset(0, address(collateralA), priceFeedA, 1e18, 0.8e18, 0.85e18, 0.9e18, type(uint128).max);
        comet.setPrice(priceFeedA, 2000e6);

        assertEq(adapter.getCollateralValueUsd(user), 0);
    }

    // ── Fuzz tests ───────────────────────────────────────────────────────

    function testFuzz_getHealthFactor_neverRevertsOnValidInputs(
        uint128 borrowBal,
        uint128 collBal,
        uint64 price
    ) public {
        vm.assume(price > 0);
        comet.addAsset(0, address(collateralA), priceFeedA, 1e18, 0.8e18, 0.85e18, 0.9e18, type(uint128).max);
        comet.setCollateralBalance(user, address(collateralA), collBal);
        comet.setPrice(priceFeedA, uint256(price));
        comet.setBorrowBalance(user, borrowBal);
        comet.setPrice(basePriceFeed, 1e6);

        // Should not revert
        adapter.getHealthFactor(user);
    }

    function testFuzz_repay_anyAmount(
        uint128 amount
    ) public {
        vm.assume(amount > 0);
        debtToken.mint(address(adapter), amount);

        vm.prank(core);
        adapter.repay(user, address(debtToken), amount);

        assertEq(comet.lastSupplyToAmount(), amount);
        assertEq(debtToken.balanceOf(address(comet)), amount);
    }

    function testFuzz_getCollateralValueUsd_proportionalToBalance(
        uint64 balance
    ) public {
        uint256 pricePerUnit = 2000e6;
        uint64 scale = 1e18;

        comet.addAsset(0, address(collateralA), priceFeedA, scale, 0.8e18, 0.85e18, 0.9e18, type(uint128).max);
        comet.setCollateralBalance(user, address(collateralA), uint128(balance));
        comet.setPrice(priceFeedA, pricePerUnit);

        uint256 value = adapter.getCollateralValueUsd(user);
        assertEq(value, uint256(balance) * pricePerUnit / uint256(scale));
    }

    function testFuzz_withdrawCollateral_recordsCorrectArgs(
        uint128 amount,
        address rcpt
    ) public {
        vm.assume(amount > 0);
        vm.assume(rcpt != address(0));

        vm.prank(core);
        adapter.withdrawCollateral(user, address(collateralA), amount, rcpt);

        assertEq(comet.lastWithdrawFromAmount(), amount);
        assertEq(comet.lastWithdrawFromTo(), rcpt);
    }
}
