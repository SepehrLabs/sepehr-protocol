// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {MoonwellAdapter} from "../../../src/adapters/MoonwellAdapter.sol";
import {SepehrErrors} from "../../../src/libraries/SepehrErrors.sol";
import {MockCToken, MockCompoundOracle, MockComptroller} from "../../helpers/MockCompoundV2.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MoonwellAdapterTest is Test {
    MoonwellAdapter adapter;
    MockComptroller comptroller;
    MockCToken mToken;
    MockCompoundOracle oracle;
    MockERC20 underlying;

    address user = makeAddr("user");
    address recipient = makeAddr("recipient");
    address internal core = makeAddr("core");

    function setUp() public {
        underlying = new MockERC20("USDC", "USDC");
        comptroller = new MockComptroller();
        oracle = new MockCompoundOracle();
        comptroller.setOracle(address(oracle));
        mToken = new MockCToken("mUSDC", "mUSDC", address(underlying));
        adapter = new MoonwellAdapter(address(comptroller), address(mToken), core);

        address[] memory assets = new address[](1);
        assets[0] = address(mToken);
        comptroller.setAssetsIn(user, assets);
    }

    function test_constructor_storesComptrollerAndMToken() public view {
        assertEq(address(adapter.COMPTROLLER()), address(comptroller));
        assertEq(address(adapter.MTOKEN()), address(mToken));
        assertEq(adapter.core(), core);
    }

    function test_constructor_revertsOnZeroComptroller() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new MoonwellAdapter(address(0), address(mToken), core);
    }

    function test_constructor_revertsOnZeroMToken() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new MoonwellAdapter(address(comptroller), address(0), core);
    }

    function test_constructor_revertsOnZeroCore() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new MoonwellAdapter(address(comptroller), address(mToken), address(0));
    }

    function test_getHealthFactor_shortfallReturnsZero() public {
        comptroller.setAccountLiquidity(user, 0, 0, 1);
        assertEq(adapter.getHealthFactor(user), 0);
    }

    function test_getHealthFactor_liquidityReturnsMax() public {
        comptroller.setAccountLiquidity(user, 0, 1, 0);
        assertEq(adapter.getHealthFactor(user), type(uint256).max);
    }

    function test_getHealthFactor_balancedReturnsOne() public {
        // Fix for B8: distinguish zero-debt (returns max) from balanced-debt.
        comptroller.setAccountLiquidity(user, 0, 0, 0);
        mToken.setBorrowBalance(user, 1);
        assertEq(adapter.getHealthFactor(user), 1e18);
    }

    function test_getHealthFactor_zeroDebtReturnsMax() public {
        comptroller.setAccountLiquidity(user, 0, 0, 0);
        assertEq(adapter.getHealthFactor(user), type(uint256).max);
    }

    function test_checkDelegation_reflectsAllowance() public {
        assertFalse(adapter.checkDelegation(user));
        vm.prank(user);
        mToken.approve(address(adapter), 1);
        assertTrue(adapter.checkDelegation(user));
    }

    function test_repay_revertsWhenNotCore() public {
        vm.expectRevert(SepehrErrors.NotAuthorized.selector);
        adapter.repay(user, address(underlying), 1e18);
    }

    function test_repay_revertsOnZero() public {
        vm.prank(core);
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        adapter.repay(user, address(underlying), 0);
    }

    function test_repay_callsRepayBorrowBehalf() public {
        underlying.mint(address(adapter), 100e18);
        vm.prank(core);
        adapter.repay(user, address(underlying), 100e18);
        assertEq(mToken.lastRepayBorrower(), user);
        assertEq(mToken.lastRepayAmount(), 100e18);
    }

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
        uint256 exchangeRate = 1e18;
        mToken.setExchangeRate(exchangeRate);

        uint256 withdrawAmount = 7e18;
        uint256 expectedMAmount = (withdrawAmount * 1e18 + exchangeRate - 1) / exchangeRate;

        mToken.mint(user, expectedMAmount);
        vm.prank(user);
        mToken.approve(address(adapter), expectedMAmount);
        underlying.mint(address(mToken), withdrawAmount);

        vm.prank(core);
        adapter.withdrawCollateral(user, address(underlying), withdrawAmount, recipient);

        assertEq(underlying.balanceOf(recipient), withdrawAmount);
    }

    function test_getCollateralValueUsd_calculatesCorrectly() public {
        mToken.setExchangeRate(1e18);
        oracle.setUnderlyingPrice(address(mToken), 2500e18);
        mToken.mint(user, 10e18);
        assertEq(adapter.getCollateralValueUsd(user), 25_000e18);
    }

    function testFuzz_getCollateralValueUsd_proportional(
        uint64 bal,
        uint64 rate,
        uint64 price
    ) public {
        vm.assume(rate > 0);
        vm.assume(price > 0);
        mToken.setExchangeRate(uint256(rate));
        oracle.setUnderlyingPrice(address(mToken), uint256(price));
        mToken.mint(user, uint256(bal));

        uint256 expected = uint256(bal) * uint256(rate) / 1e18 * uint256(price) / 1e18;
        assertEq(adapter.getCollateralValueUsd(user), expected);
    }
}
