// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {MorphoBlueAdapter} from "../../../src/adapters/MorphoBlueAdapter.sol";
import {SepehrErrors} from "../../../src/libraries/SepehrErrors.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {MockMorpho, MockMorphoOracle} from "../../helpers/MockMorpho.sol";
import {Test} from "forge-std/Test.sol";

contract MorphoBlueAdapterTest is Test {
    MorphoBlueAdapter adapter;
    MockMorpho morpho;
    MockMorphoOracle oracle;
    MockERC20 loanToken;
    MockERC20 collateralToken;

    bytes32 constant MARKET_ID = keccak256("test-market");
    address user = makeAddr("user");
    address recipient = makeAddr("recipient");
    address irm = makeAddr("irm");

    function setUp() public {
        morpho = new MockMorpho();
        oracle = new MockMorphoOracle();
        loanToken = new MockERC20("USDC", "USDC");
        collateralToken = new MockERC20("WETH", "WETH");

        morpho.setMarketParams(
            MARKET_ID,
            address(loanToken),
            address(collateralToken),
            address(oracle),
            irm,
            0.8e18 // 80% LLTV
        );

        adapter = new MorphoBlueAdapter(address(morpho), MARKET_ID);
    }

    // ── Constructor ──────────────────────────────────────────────────────

    function test_constructor_setsMorphoAndMarketId() public view {
        assertEq(address(adapter.MORPHO()), address(morpho));
        assertEq(adapter.MARKET_ID(), MARKET_ID);
    }

    function test_constructor_revertsOnZeroMorpho() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new MorphoBlueAdapter(address(0), MARKET_ID);
    }

    function test_constructor_revertsOnZeroMarketId() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new MorphoBlueAdapter(address(morpho), bytes32(0));
    }

    // ── getHealthFactor ──────────────────────────────────────────────────

    function test_getHealthFactor_returnsMaxWhenNoBorrow() public {
        morpho.setPosition(MARKET_ID, user, 0, 0, 10e18);
        assertEq(adapter.getHealthFactor(user), type(uint256).max);
    }

    function test_getHealthFactor_calculatesCorrectly() public {
        // Position: 10 ETH collateral, 100 borrow shares
        morpho.setPosition(MARKET_ID, user, 0, 100, 10e18);

        // Market: totalBorrowAssets=1000, totalBorrowShares=1000
        // So 100 shares = 100 assets
        morpho.setMarket(MARKET_ID, 5000, 5000, 1000, 1000, uint128(block.timestamp), 0);

        // Oracle price = 2000e36 (Morpho uses 1e36 scale for collateral/loan)
        oracle.setPrice(2000e36);

        uint256 hf = adapter.getHealthFactor(user);

        // borrowAmount = 100 * 1000 / 1000 = 100
        // collateralValue = 10e18 * 2000e36 / 1e36 = 20_000e18
        // hf = 20_000e18 * 0.8e18 / 100 = 16_000e36 / 100 = 1.6e38
        assertEq(hf, 1.6e38);
    }

    function test_getHealthFactor_lowHealthFactor() public {
        // Position: 1 ETH collateral, 2000 borrow shares
        morpho.setPosition(MARKET_ID, user, 0, 2000e6, 1e18);

        // Market: 1:1 share ratio (totalBorrowAssets == totalBorrowShares)
        morpho.setMarket(MARKET_ID, 5000e6, 5000e6, 5000e6, 5000e6, uint128(block.timestamp), 0);

        // Oracle: 1 collateral = 2000 loan tokens
        oracle.setPrice(2000e36);

        uint256 hf = adapter.getHealthFactor(user);

        // borrowAmount = 2000e6 * 5000e6 / 5000e6 = 2000e6
        // collateralValue = 1e18 * 2000e36 / 1e36 = 2000e18
        // hf = 2000e18 * 0.8e18 / 2000e6 = 1600e36 / 2000e6 = 8e29
        assertEq(hf, 8e29);
    }

    function test_getHealthFactor_withDifferentShareRatio() public {
        // Position: 5 ETH collateral, 500 borrow shares
        morpho.setPosition(MARKET_ID, user, 0, 500, 5e18);

        // Market: 2:1 ratio (totalBorrowAssets = 2000, totalBorrowShares = 1000)
        // So 500 shares = 500 * 2000 / 1000 = 1000 assets
        morpho.setMarket(MARKET_ID, 10_000, 10_000, 2000, 1000, uint128(block.timestamp), 0);

        oracle.setPrice(3000e36);

        uint256 hf = adapter.getHealthFactor(user);

        // borrowAmount = 500 * 2000 / 1000 = 1000
        // collateralValue = 5e18 * 3000e36 / 1e36 = 15_000e18
        // hf = 15_000e18 * 0.8e18 / 1000 = 12_000e36 / 1000 = 1.2e37
        assertEq(hf, 1.2e37);
    }

    // ── checkDelegation ──────────────────────────────────────────────────

    function test_checkDelegation_returnsTrueWhenAuthorized() public {
        morpho.setAuthorized(user, address(adapter), true);
        assertTrue(adapter.checkDelegation(user));
    }

    function test_checkDelegation_returnsFalseWhenNotAuthorized() public view {
        assertFalse(adapter.checkDelegation(user));
    }

    // ── repay ────────────────────────────────────────────────────────────

    function test_repay_revertsOnZeroAmount() public {
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        adapter.repay(user, address(loanToken), 0);
    }

    function test_repay_callsMorphoRepayCorrectly() public {
        uint256 amount = 500e18;
        loanToken.mint(address(adapter), amount);

        adapter.repay(user, address(loanToken), amount);

        assertEq(morpho.lastRepayLoanToken(), address(loanToken));
        assertEq(morpho.lastRepayAssets(), amount);
        assertEq(morpho.lastRepayShares(), 0);
        assertEq(morpho.lastRepayOnBehalf(), user);
        assertEq(morpho.lastRepayData(), "");
    }

    function test_repay_transfersTokensToMorpho() public {
        uint256 amount = 500e18;
        loanToken.mint(address(adapter), amount);

        adapter.repay(user, address(loanToken), amount);

        assertEq(loanToken.balanceOf(address(morpho)), amount);
        assertEq(loanToken.balanceOf(address(adapter)), 0);
    }

    // ── withdrawCollateral ───────────────────────────────────────────────

    function test_withdrawCollateral_revertsOnZeroAmount() public {
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        adapter.withdrawCollateral(user, address(collateralToken), 0, recipient);
    }

    function test_withdrawCollateral_revertsOnZeroRecipient() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        adapter.withdrawCollateral(user, address(collateralToken), 1e18, address(0));
    }

    function test_withdrawCollateral_callsMorphoCorrectly() public {
        uint256 amount = 2e18;

        adapter.withdrawCollateral(user, address(collateralToken), amount, recipient);

        assertEq(morpho.lastWithdrawCollateralToken(), address(collateralToken));
        assertEq(morpho.lastWithdrawAssets(), amount);
        assertEq(morpho.lastWithdrawOnBehalf(), user);
        assertEq(morpho.lastWithdrawReceiver(), recipient);
    }

    // ── getCollateralValueUsd ────────────────────────────────────────────

    function test_getCollateralValueUsd_calculatesCorrectly() public {
        morpho.setPosition(MARKET_ID, user, 0, 0, 10e18);
        oracle.setPrice(2000e36);

        uint256 value = adapter.getCollateralValueUsd(user);

        // 10e18 * 2000e36 / 1e36 = 20_000e18
        assertEq(value, 20_000e18);
    }

    function test_getCollateralValueUsd_zeroWhenNoCollateral() public {
        oracle.setPrice(2000e36);
        assertEq(adapter.getCollateralValueUsd(user), 0);
    }

    function test_getCollateralValueUsd_reflectsOraclePrice() public {
        morpho.setPosition(MARKET_ID, user, 0, 0, 5e18);

        oracle.setPrice(1000e36);
        assertEq(adapter.getCollateralValueUsd(user), 5000e18);

        oracle.setPrice(3000e36);
        assertEq(adapter.getCollateralValueUsd(user), 15_000e18);
    }

    // ── Fuzz tests ───────────────────────────────────────────────────────

    function testFuzz_getHealthFactor_maxWhenNoBorrowShares(
        uint128 collateral
    ) public {
        morpho.setPosition(MARKET_ID, user, 0, 0, collateral);
        assertEq(adapter.getHealthFactor(user), type(uint256).max);
    }

    function testFuzz_repay_anyAmount(
        uint128 amount
    ) public {
        vm.assume(amount > 0);
        loanToken.mint(address(adapter), amount);

        adapter.repay(user, address(loanToken), amount);

        assertEq(morpho.lastRepayAssets(), amount);
        assertEq(loanToken.balanceOf(address(morpho)), amount);
    }

    function testFuzz_getCollateralValueUsd_proportional(
        uint64 collateral,
        uint64 priceScaled
    ) public {
        uint256 oraclePrice = uint256(priceScaled) * 1e18; // Scale up to prevent zero
        morpho.setPosition(MARKET_ID, user, 0, 0, uint128(collateral));
        oracle.setPrice(oraclePrice);

        uint256 value = adapter.getCollateralValueUsd(user);
        assertEq(value, uint256(collateral) * oraclePrice / 1e36);
    }

    function testFuzz_withdrawCollateral_recordsCorrectArgs(
        uint128 amount,
        address rcpt
    ) public {
        vm.assume(amount > 0);
        vm.assume(rcpt != address(0));

        adapter.withdrawCollateral(user, address(collateralToken), amount, rcpt);

        assertEq(morpho.lastWithdrawAssets(), amount);
        assertEq(morpho.lastWithdrawReceiver(), rcpt);
    }
}
