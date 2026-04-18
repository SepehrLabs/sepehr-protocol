// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {VenusAdapter} from "../../../src/adapters/VenusAdapter.sol";
import {SepehrErrors} from "../../../src/libraries/SepehrErrors.sol";
import {MockCToken, MockCompoundOracle, MockComptroller} from "../../helpers/MockCompoundV2.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {Test} from "forge-std/Test.sol";

contract VenusAdapterTest is Test {
    VenusAdapter adapter;
    MockComptroller comptroller;
    MockCToken vToken;
    MockCompoundOracle oracle;
    MockERC20 underlying;

    address user = makeAddr("user");
    address recipient = makeAddr("recipient");
    address internal core = makeAddr("core");

    function setUp() public {
        underlying = new MockERC20("BUSD", "BUSD");
        comptroller = new MockComptroller();
        oracle = new MockCompoundOracle();
        comptroller.setOracle(address(oracle));
        vToken = new MockCToken("vBUSD", "vBUSD", address(underlying));
        adapter = new VenusAdapter(address(comptroller), address(vToken), core);
    }

    function test_constructor_storesComptrollerAndVToken() public view {
        assertEq(address(adapter.COMPTROLLER()), address(comptroller));
        assertEq(address(adapter.VTOKEN()), address(vToken));
        assertEq(adapter.core(), core);
    }

    function test_constructor_revertsOnZeroComptroller() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new VenusAdapter(address(0), address(vToken), core);
    }

    function test_constructor_revertsOnZeroVToken() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new VenusAdapter(address(comptroller), address(0), core);
    }

    function test_constructor_revertsOnZeroCore() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new VenusAdapter(address(comptroller), address(vToken), address(0));
    }

    function test_getHealthFactor_shortfallReturnsZero() public {
        comptroller.setAccountLiquidity(user, 0, 0, 1e18);
        assertEq(adapter.getHealthFactor(user), 0);
    }

    function test_getHealthFactor_liquidityReturnsMax() public {
        comptroller.setAccountLiquidity(user, 0, 500e18, 0);
        assertEq(adapter.getHealthFactor(user), type(uint256).max);
    }

    function test_getHealthFactor_balancedReturnsOne() public {
        comptroller.setAccountLiquidity(user, 0, 0, 0);
        assertEq(adapter.getHealthFactor(user), 1e18);
    }

    function test_checkDelegation_reflectsAllowance() public {
        assertFalse(adapter.checkDelegation(user));
        vm.prank(user);
        vToken.approve(address(adapter), 1);
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
        assertEq(vToken.lastRepayBorrower(), user);
        assertEq(vToken.lastRepayAmount(), 100e18);
        assertEq(underlying.balanceOf(address(vToken)), 100e18);
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
        uint256 exchangeRate = 2e17;
        vToken.setExchangeRate(exchangeRate);

        uint256 withdrawAmount = 10e18;
        uint256 expectedVAmount = (withdrawAmount * 1e18 + exchangeRate - 1) / exchangeRate;

        vToken.mint(user, expectedVAmount);
        vm.prank(user);
        vToken.approve(address(adapter), expectedVAmount);
        underlying.mint(address(vToken), withdrawAmount);

        vm.prank(core);
        adapter.withdrawCollateral(user, address(underlying), withdrawAmount, recipient);

        assertEq(vToken.lastRedeemAmount(), withdrawAmount);
        assertEq(underlying.balanceOf(recipient), withdrawAmount);
    }

    function test_getCollateralValueUsd_calculatesCorrectly() public {
        vToken.setExchangeRate(2e17);
        oracle.setUnderlyingPrice(address(vToken), 1e18);
        vToken.mint(user, 100e18);
        assertEq(adapter.getCollateralValueUsd(user), 20e18);
    }

    function test_getCollateralValueUsd_zeroWhenNoBalance() public {
        oracle.setUnderlyingPrice(address(vToken), 1e18);
        assertEq(adapter.getCollateralValueUsd(user), 0);
    }

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
}
