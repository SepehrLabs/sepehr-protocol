// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MorphoBlueAdapter} from "../../../src/adapters/MorphoBlueAdapter.sol";
import {IMorpho} from "../../../src/interfaces/external/IMorpho.sol";
import {SepehrErrors} from "../../../src/libraries/SepehrErrors.sol";
import {MockChainlinkAggregator} from "../../helpers/MockChainlinkAggregator.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {MockMorpho, MockMorphoOracle} from "../../helpers/MockMorpho.sol";
import {MockTokenDecimals} from "../../helpers/MockTokenDecimals.sol";
import {Test} from "forge-std/Test.sol";

contract MorphoBlueAdapterTest is Test {
    MorphoBlueAdapter adapter;
    MockMorpho morpho;
    MockMorphoOracle oracle;
    MockERC20 loanToken;
    MockERC20 collateralToken;
    /// @dev Loan-token USD feed: $1, 8 decimals.
    MockChainlinkAggregator loanFeed;

    bytes32 constant MARKET_ID = keccak256("test-market");
    address user = makeAddr("user");
    address recipient = makeAddr("recipient");
    address irm = makeAddr("irm");
    address internal core = makeAddr("core");

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

        loanFeed = new MockChainlinkAggregator(8, 1e8);
        adapter = new MorphoBlueAdapter(address(morpho), MARKET_ID, address(loanFeed), core);
    }

    // ── Constructor ──────────────────────────────────────────────────────

    function test_constructor_setsMorphoAndMarketId() public view {
        assertEq(address(adapter.MORPHO()), address(morpho));
        assertEq(adapter.MARKET_ID(), MARKET_ID);
        assertEq(adapter.core(), core);
    }

    function test_constructor_revertsOnZeroMorpho() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new MorphoBlueAdapter(address(0), MARKET_ID, address(loanFeed), core);
    }

    function test_constructor_revertsOnZeroMarketId() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new MorphoBlueAdapter(address(morpho), bytes32(0), address(loanFeed), core);
    }

    function test_constructor_revertsOnZeroCore() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new MorphoBlueAdapter(address(morpho), MARKET_ID, address(loanFeed), address(0));
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

    function test_repay_revertsWhenNotCore() public {
        vm.expectRevert(SepehrErrors.NotAuthorized.selector);
        adapter.repay(user, address(loanToken), 1e18);
    }

    function test_repay_revertsOnZeroAmount() public {
        vm.prank(core);
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        adapter.repay(user, address(loanToken), 0);
    }

    function test_repay_callsMorphoRepayCorrectly() public {
        uint256 amount = 500e18;
        loanToken.mint(address(adapter), amount);

        vm.prank(core);
        adapter.repay(user, address(loanToken), amount);

        assertEq(morpho.lastRepayLoanToken(), address(loanToken));
        assertEq(morpho.lastRepayAssets(), amount);
        assertEq(morpho.lastRepayShares(), 0);
        assertEq(morpho.lastRepayOnBehalf(), user);
        assertEq(morpho.lastRepayData(), "");
    }

    function test_repay_revertsForAnotherAssetThanTheLoanToken() public {
        vm.prank(core);
        vm.expectRevert(
            abi.encodeWithSelector(
                SepehrErrors.DebtAssetMismatch.selector, address(loanToken), address(collateralToken)
            )
        );
        adapter.repay(user, address(collateralToken), 1e18);
    }

    /// @dev Lot 6: a close repays the whole debt; Morpho takes it by shares, so no dust is
    /// left, and the unused part of the amount goes back to the core.
    function test_repay_coveringTheWholeDebt_repaysEveryShare() public {
        morpho.setPosition(MARKET_ID, user, 0, 300e6, 10e18);
        morpho.setMarket(MARKET_ID, 0, 0, 1000e18, 1000e6, uint128(block.timestamp), 0);
        uint256 debt = adapter.getDebt(user, address(loanToken));
        assertEq(debt, 300e18);
        loanToken.mint(address(adapter), debt + 1e18);

        vm.prank(core);
        adapter.repay(user, address(loanToken), debt + 1e18);

        assertEq(morpho.lastRepayAssets(), 0, "repaid by shares");
        assertEq(morpho.lastRepayShares(), 300e6, "every share");
        assertEq(loanToken.balanceOf(address(morpho)), debt);
        assertEq(loanToken.balanceOf(core), 1e18, "the rest goes back to the core");
    }

    function test_repay_underTheDebt_repaysAssets() public {
        morpho.setPosition(MARKET_ID, user, 0, 300e6, 10e18);
        morpho.setMarket(MARKET_ID, 0, 0, 1000e18, 1000e6, uint128(block.timestamp), 0);
        loanToken.mint(address(adapter), 100e18);

        vm.prank(core);
        adapter.repay(user, address(loanToken), 100e18);

        assertEq(morpho.lastRepayAssets(), 100e18);
        assertEq(morpho.lastRepayShares(), 0);
    }

    function test_repay_transfersTokensToMorpho() public {
        uint256 amount = 500e18;
        loanToken.mint(address(adapter), amount);

        vm.prank(core);
        adapter.repay(user, address(loanToken), amount);

        assertEq(loanToken.balanceOf(address(morpho)), amount);
        assertEq(loanToken.balanceOf(address(adapter)), 0);
    }

    // ── withdrawCollateral ───────────────────────────────────────────────

    function test_withdrawCollateral_revertsWhenNotCore() public {
        vm.expectRevert(SepehrErrors.NotAuthorized.selector);
        adapter.withdrawCollateral(user, address(collateralToken), 1e18, recipient);
    }

    function test_withdrawCollateral_revertsOnZeroAmount() public {
        vm.prank(core);
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        adapter.withdrawCollateral(user, address(collateralToken), 0, recipient);
    }

    function test_withdrawCollateral_revertsOnZeroRecipient() public {
        vm.prank(core);
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        adapter.withdrawCollateral(user, address(collateralToken), 1e18, address(0));
    }

    function test_withdrawCollateral_callsMorphoCorrectly() public {
        uint256 amount = 2e18;

        vm.prank(core);
        adapter.withdrawCollateral(user, address(collateralToken), amount, recipient);

        assertEq(morpho.lastWithdrawCollateralToken(), address(collateralToken));
        assertEq(morpho.lastWithdrawAssets(), amount);
        assertEq(morpho.lastWithdrawOnBehalf(), user);
        assertEq(morpho.lastWithdrawReceiver(), recipient);
    }

    function test_withdrawCollateral_revertsOnCollateralAssetMismatch() public {
        // Audit B22: an asset that is not the market's collateralToken must revert
        // before Morpho is called, so a buggy keeper doesn't silently pull nothing
        // (or a future interface change doesn't stranded approvals on the wrong token).
        MockERC20 wrong = new MockERC20("WRONG", "WRONG");
        vm.prank(core);
        vm.expectRevert(
            abi.encodeWithSelector(
                SepehrErrors.CollateralAssetMismatch.selector, address(collateralToken), address(wrong)
            )
        );
        adapter.withdrawCollateral(user, address(wrong), 1e18, recipient);
    }

    // ── getCollateralValueUsd ────────────────────────────────────────────

    function test_getCollateralValueUsd_calculatesCorrectly() public {
        morpho.setPosition(MARKET_ID, user, 0, 0, 10e18);
        oracle.setPrice(2000e36);

        uint256 value = adapter.getCollateralValueUsd(user);

        // 10e18 * 2000e36 / 1e36 = 20_000e18 loan units at $1 = $20,000 in USD-8
        assertEq(value, 20_000e8);
    }

    function test_getCollateralValueUsd_zeroWhenNoCollateral() public {
        oracle.setPrice(2000e36);
        assertEq(adapter.getCollateralValueUsd(user), 0);
    }

    function test_getCollateralValueUsd_reflectsOraclePrice() public {
        morpho.setPosition(MARKET_ID, user, 0, 0, 5e18);

        oracle.setPrice(1000e36);
        assertEq(adapter.getCollateralValueUsd(user), 5000e8);

        oracle.setPrice(3000e36);
        assertEq(adapter.getCollateralValueUsd(user), 15_000e8);
    }

    // ── M-4: collateral in USD-8 ─────────────────────────────────────────

    function test_constructor_revertsOnZeroLoanFeed() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new MorphoBlueAdapter(address(morpho), MARKET_ID, address(0), core);
    }

    function test_constructor_revertsOnAFeedWithOtherDecimals() public {
        MockChainlinkAggregator eighteen = new MockChainlinkAggregator(18, 1e18);
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.InvalidOracleDecimals.selector, 18, 8));
        new MorphoBlueAdapter(address(morpho), MARKET_ID, address(eighteen), core);
    }

    /// @dev M-4 (audit PoC): with a 6-decimal USDC loan token, a $30,000 position read as $300.
    function test_getCollateralValueUsd_quotesA6DecimalLoanTokenInUsd8() public {
        MockTokenDecimals usdc6 = new MockTokenDecimals("USDC", "USDC", 6);
        bytes32 marketId = keccak256("usdc6-market");
        morpho.setMarketParams(marketId, address(usdc6), address(collateralToken), address(oracle), irm, 0.86e18);
        MorphoBlueAdapter usdcAdapter = new MorphoBlueAdapter(address(morpho), marketId, address(loanFeed), core);

        // 10 WETH at 3,000 USDC: Morpho prices 1e18 collateral units as 3000e6 loan units.
        morpho.setPosition(marketId, user, 0, 0, 10e18);
        oracle.setPrice(3000e6 * 1e36 / 1e18);

        assertEq(usdcAdapter.getCollateralValueUsd(user), 30_000e8);
    }

    function test_getCollateralValueUsd_followsTheLoanTokenPrice() public {
        morpho.setPosition(MARKET_ID, user, 0, 0, 10e18);
        oracle.setPrice(2000e36);
        loanFeed.setAnswer(0.99e8);

        assertEq(adapter.getCollateralValueUsd(user), 19_800e8);
    }

    function test_getCollateralValueUsd_revertsOnANonPositiveFeedAnswer() public {
        morpho.setPosition(MARKET_ID, user, 0, 0, 10e18);
        oracle.setPrice(2000e36);
        loanFeed.setAnswer(0);

        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.InvalidOraclePrice.selector, address(loanToken), int256(0)));
        adapter.getCollateralValueUsd(user);
    }

    // ── I-5: interest accrued since the market's last update ─────────────

    /// @dev Borrow total after `elapsed` seconds at `rate` per second, as Morpho books it.
    function _accrued(
        uint256 totalBorrowAssets,
        uint256 rate,
        uint256 elapsed
    ) internal pure returns (uint256) {
        uint256 first = rate * elapsed;
        uint256 second = first * first / 2e18;
        uint256 third = second * first / 3e18;
        return totalBorrowAssets + totalBorrowAssets * (first + second + third) / 1e18;
    }

    function test_getDebt_includesInterestAccruedSinceTheLastUpdate() public {
        MockIrm rateModel = new MockIrm(1e18 / uint256(365 days) / 10); // ~10% a year
        morpho.setMarketParams(
            MARKET_ID, address(loanToken), address(collateralToken), address(oracle), address(rateModel), 0.8e18
        );
        morpho.setPosition(MARKET_ID, user, 0, 1000, 10e18);
        vm.warp(400 days);
        morpho.setMarket(MARKET_ID, 10_000e18, 10_000e18, 5000e18, 1000, uint128(block.timestamp - 30 days), 0);

        uint256 expected = _accrued(5000e18, rateModel.rate(), 30 days);
        assertGt(expected, 5000e18);
        assertEq(adapter.getDebt(user, address(loanToken)), expected);
    }

    function test_getHealthFactor_accountsForAccruedInterest() public {
        MockIrm rateModel = new MockIrm(1e18 / uint256(365 days) / 10);
        morpho.setMarketParams(
            MARKET_ID, address(loanToken), address(collateralToken), address(oracle), address(rateModel), 0.8e18
        );
        morpho.setPosition(MARKET_ID, user, 0, 1000, 10e18);
        oracle.setPrice(1000e36);
        vm.warp(400 days);
        morpho.setMarket(MARKET_ID, 10_000e18, 10_000e18, 5000e18, 1000, uint128(block.timestamp - 30 days), 0);

        uint256 borrowed = _accrued(5000e18, rateModel.rate(), 30 days);
        // collateralQuoted = 10e18 * 1000e36 / 1e36 = 10_000e18; HF = 10_000e18 * 0.8e18 / borrowed
        assertEq(adapter.getHealthFactor(user), 10_000e18 * 0.8e18 / borrowed);
    }

    function test_getDebt_withoutAnIrmAccruesNothing() public {
        morpho.setMarketParams(
            MARKET_ID, address(loanToken), address(collateralToken), address(oracle), address(0), 0.8e18
        );
        morpho.setPosition(MARKET_ID, user, 0, 1000, 10e18);
        vm.warp(400 days);
        morpho.setMarket(MARKET_ID, 10_000e18, 10_000e18, 5000e18, 1000, uint128(block.timestamp - 30 days), 0);

        assertEq(adapter.getDebt(user, address(loanToken)), 5000e18);
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

        vm.prank(core);
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
        assertEq(value, (uint256(collateral) * oraclePrice / 1e36) * 1e8 / 1e18);
    }

    function testFuzz_withdrawCollateral_recordsCorrectArgs(
        uint128 amount,
        address rcpt
    ) public {
        vm.assume(amount > 0);
        vm.assume(rcpt != address(0));

        vm.prank(core);
        adapter.withdrawCollateral(user, address(collateralToken), amount, rcpt);

        assertEq(morpho.lastWithdrawAssets(), amount);
        assertEq(morpho.lastWithdrawReceiver(), rcpt);
    }
}

/// @notice Constant-rate Morpho interest rate model.
contract MockIrm {
    uint256 public immutable rate;

    constructor(
        uint256 rate_
    ) {
        rate = rate_;
    }

    function borrowRateView(
        IMorpho.MarketParams memory,
        IMorpho.Market memory
    ) external view returns (uint256) {
        return rate;
    }
}
