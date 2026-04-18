// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {CompoundV2Adapter} from "../../../src/adapters/CompoundV2Adapter.sol";
import {SepehrErrors} from "../../../src/libraries/SepehrErrors.sol";
import {MockCToken, MockCompoundOracle, MockComptroller} from "../../helpers/MockCompoundV2.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {Test} from "forge-std/Test.sol";

contract CompoundV2AdapterTest is Test {
    CompoundV2Adapter adapter;
    MockComptroller comptroller;
    MockCToken cToken;
    MockCompoundOracle oracle;
    MockERC20 underlying;

    address user = makeAddr("user");
    address recipient = makeAddr("recipient");
    address internal core = makeAddr("core");

    function setUp() public {
        underlying = new MockERC20("DAI", "DAI");
        comptroller = new MockComptroller();
        oracle = new MockCompoundOracle();
        comptroller.setOracle(address(oracle));
        cToken = new MockCToken("cDAI", "cDAI", address(underlying));

        adapter = new CompoundV2Adapter(address(comptroller), address(cToken), core);
    }

    // ── Constructor ──────────────────────────────────────────────────────

    function test_constructor_setsComptrollerAndCToken() public view {
        assertEq(address(adapter.COMPTROLLER()), address(comptroller));
        assertEq(address(adapter.CTOKEN()), address(cToken));
        assertEq(adapter.core(), core);
    }

    function test_constructor_revertsOnZeroComptroller() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new CompoundV2Adapter(address(0), address(cToken), core);
    }

    function test_constructor_revertsOnZeroCToken() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new CompoundV2Adapter(address(comptroller), address(0), core);
    }

    function test_constructor_revertsOnZeroCore() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new CompoundV2Adapter(address(comptroller), address(cToken), address(0));
    }

    // ── getHealthFactor ──────────────────────────────────────────────────

    function test_getHealthFactor_returnsZeroWhenShortfall() public {
        comptroller.setAccountLiquidity(user, 0, 0, 100e18);
        assertEq(adapter.getHealthFactor(user), 0);
    }

    function test_getHealthFactor_returnsMaxWhenLiquidity() public {
        comptroller.setAccountLiquidity(user, 0, 500e18, 0);
        assertEq(adapter.getHealthFactor(user), type(uint256).max);
    }

    function test_getHealthFactor_returns1e18WhenNoLiquidityNoShortfall() public {
        comptroller.setAccountLiquidity(user, 0, 0, 0);
        assertEq(adapter.getHealthFactor(user), 1e18);
    }

    function test_getHealthFactor_shortfallTakesPrecedence() public {
        // Both liquidity and shortfall set; shortfall > 0 dominates
        comptroller.setAccountLiquidity(user, 0, 100e18, 1);
        assertEq(adapter.getHealthFactor(user), 0);
    }

    // ── checkDelegation ──────────────────────────────────────────────────

    function test_checkDelegation_returnsTrueWhenAllowanceGiven() public {
        vm.prank(user);
        cToken.approve(address(adapter), 1);
        assertTrue(adapter.checkDelegation(user));
    }

    function test_checkDelegation_returnsFalseWhenNoAllowance() public view {
        assertFalse(adapter.checkDelegation(user));
    }

    function test_checkDelegation_returnsTrueWithMaxAllowance() public {
        vm.prank(user);
        cToken.approve(address(adapter), type(uint256).max);
        assertTrue(adapter.checkDelegation(user));
    }

    // ── repay ────────────────────────────────────────────────────────────

    function test_repay_revertsWhenNotCore() public {
        vm.expectRevert(SepehrErrors.NotAuthorized.selector);
        adapter.repay(user, address(underlying), 1e18);
    }

    function test_repay_revertsOnZeroAmount() public {
        vm.prank(core);
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        adapter.repay(user, address(underlying), 0);
    }

    function test_repay_callsRepayBorrowBehalf() public {
        uint256 amount = 100e18;
        underlying.mint(address(adapter), amount);

        vm.prank(core);
        adapter.repay(user, address(underlying), amount);

        assertEq(cToken.lastRepayBorrower(), user);
        assertEq(cToken.lastRepayAmount(), amount);
    }

    function test_repay_transfersTokensToCToken() public {
        uint256 amount = 100e18;
        underlying.mint(address(adapter), amount);

        vm.prank(core);
        adapter.repay(user, address(underlying), amount);

        assertEq(underlying.balanceOf(address(cToken)), amount);
        assertEq(underlying.balanceOf(address(adapter)), 0);
    }

    // ── withdrawCollateral ───────────────────────────────────────────────

    function test_withdrawCollateral_revertsWhenNotCore() public {
        vm.expectRevert(SepehrErrors.NotAuthorized.selector);
        adapter.withdrawCollateral(user, address(underlying), 1e18, recipient);
    }

    function test_withdrawCollateral_revertsOnZeroAmount() public {
        vm.prank(core);
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        adapter.withdrawCollateral(user, address(underlying), 0, recipient);
    }

    function test_withdrawCollateral_revertsOnZeroRecipient() public {
        vm.prank(core);
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        adapter.withdrawCollateral(user, address(underlying), 1e18, address(0));
    }

    function test_withdrawCollateral_fullFlow() public {
        uint256 exchangeRate = 2e17; // 1 cToken = 0.2 underlying
        cToken.setExchangeRate(exchangeRate);

        uint256 withdrawAmount = 10e18;
        // cTokenAmount = (10e18 * 1e18 + 2e17 - 1) / 2e17 = 50e18 (rounds up)
        uint256 expectedCTokenAmount = (withdrawAmount * 1e18 + exchangeRate - 1) / exchangeRate;

        // Give user cTokens and approve adapter
        cToken.mint(user, expectedCTokenAmount);
        vm.prank(user);
        cToken.approve(address(adapter), expectedCTokenAmount);

        // Give cToken contract underlying to redeem
        underlying.mint(address(cToken), withdrawAmount);

        vm.prank(core);
        adapter.withdrawCollateral(user, address(underlying), withdrawAmount, recipient);

        assertEq(cToken.lastRedeemAmount(), withdrawAmount);
        assertEq(underlying.balanceOf(recipient), withdrawAmount);
        assertEq(cToken.balanceOf(user), 0);
    }

    function test_withdrawCollateral_roundsUpCTokenAmount() public {
        // Choose exchange rate that doesn't divide evenly
        uint256 exchangeRate = 3e17; // 1 cToken = 0.3 underlying
        cToken.setExchangeRate(exchangeRate);

        uint256 withdrawAmount = 1e18;
        // cTokenAmount = (1e18 * 1e18 + 3e17 - 1) / 3e17
        uint256 expectedCTokenAmount = (withdrawAmount * 1e18 + exchangeRate - 1) / exchangeRate;

        // Verify rounding up actually happened
        assertTrue(expectedCTokenAmount * exchangeRate / 1e18 >= withdrawAmount);

        cToken.mint(user, expectedCTokenAmount);
        vm.prank(user);
        cToken.approve(address(adapter), expectedCTokenAmount);
        underlying.mint(address(cToken), withdrawAmount);

        vm.prank(core);
        adapter.withdrawCollateral(user, address(underlying), withdrawAmount, recipient);

        assertEq(underlying.balanceOf(recipient), withdrawAmount);
    }

    // ── getCollateralValueUsd ────────────────────────────────────────────

    function test_getCollateralValueUsd_calculatesCorrectly() public {
        uint256 exchangeRate = 2e17; // 0.2
        cToken.setExchangeRate(exchangeRate);
        oracle.setUnderlyingPrice(address(cToken), 1e18); // $1

        uint256 cTokenBalance = 100e18;
        cToken.mint(user, cTokenBalance);

        uint256 value = adapter.getCollateralValueUsd(user);

        // underlyingBalance = 100e18 * 2e17 / 1e18 = 20e18
        // usdValue = 20e18 * 1e18 / 1e18 = 20e18
        assertEq(value, 20e18);
    }

    function test_getCollateralValueUsd_zeroWhenNoCTokens() public {
        oracle.setUnderlyingPrice(address(cToken), 1e18);
        assertEq(adapter.getCollateralValueUsd(user), 0);
    }

    function test_getCollateralValueUsd_reflectsPrice() public {
        uint256 exchangeRate = 1e18; // 1:1
        cToken.setExchangeRate(exchangeRate);
        oracle.setUnderlyingPrice(address(cToken), 2500e18); // $2500

        cToken.mint(user, 10e18);

        uint256 value = adapter.getCollateralValueUsd(user);
        // underlyingBalance = 10e18 * 1e18 / 1e18 = 10e18
        // usdValue = 10e18 * 2500e18 / 1e18 = 25_000e18
        assertEq(value, 25_000e18);
    }

    // ── Fuzz tests ───────────────────────────────────────────────────────

    function testFuzz_getHealthFactor_classifiesCorrectly(
        uint128 liquidity,
        uint128 shortfall
    ) public {
        comptroller.setAccountLiquidity(user, 0, liquidity, shortfall);

        uint256 hf = adapter.getHealthFactor(user);
        if (shortfall > 0) {
            assertEq(hf, 0);
        } else if (liquidity > 0) {
            assertEq(hf, type(uint256).max);
        } else {
            assertEq(hf, 1e18);
        }
    }

    function testFuzz_repay_anyAmount(
        uint128 amount
    ) public {
        vm.assume(amount > 0);
        underlying.mint(address(adapter), amount);

        vm.prank(core);
        adapter.repay(user, address(underlying), amount);

        assertEq(cToken.lastRepayAmount(), amount);
        assertEq(underlying.balanceOf(address(cToken)), amount);
    }

    function testFuzz_getCollateralValueUsd_proportional(
        uint64 cBal,
        uint64 rate,
        uint64 price
    ) public {
        vm.assume(rate > 0);
        vm.assume(price > 0);

        cToken.setExchangeRate(uint256(rate));
        oracle.setUnderlyingPrice(address(cToken), uint256(price));
        cToken.mint(user, uint256(cBal));

        uint256 value = adapter.getCollateralValueUsd(user);
        uint256 expected = uint256(cBal) * uint256(rate) / 1e18 * uint256(price) / 1e18;
        assertEq(value, expected);
    }
}
