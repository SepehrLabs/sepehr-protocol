// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MorphoBlueAdapter} from "../../src/adapters/MorphoBlueAdapter.sol";
import {IMorpho} from "../../src/interfaces/external/IMorpho.sol";
import {ForkTestBase} from "./ForkTestBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Extended Morpho interface for supply-collateral and borrow used in test setup.
interface IMorphoFork {
    function supplyCollateral(
        IMorpho.MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        bytes memory data
    ) external;
    function borrow(
        IMorpho.MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);
    function setAuthorization(
        address authorized,
        bool newIsAuthorized
    ) external;
}

contract MorphoBlueAdapterForkTest is ForkTestBase {
    // --- Ethereum mainnet addresses ---
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Known WETH/USDC market on Morpho Blue (86% LLTV, AdaptiveCurveIrm)
    // This market ID corresponds to WETH collateral / USDC loan with Chainlink oracle
    bytes32 constant MARKET_ID = 0xb323495f7e4148be5643a4ea4a8221eef163e4bccfdedc2a6f4696baacbc86cc;

    MorphoBlueAdapter internal adapter;
    bool internal forked;
    address internal user;
    IMorpho.MarketParams internal params;

    function setUp() public {
        forked = _tryCreateFork("RPC_ETHEREUM_PRIMARY_HTTP");
        if (!forked) return;

        adapter = new MorphoBlueAdapter(MORPHO, MARKET_ID, address(this));
        user = makeAddr("morphoUser");

        // Fetch market params from the real Morpho contract
        params = IMorpho(MORPHO).idToMarketParams(MARKET_ID);

        // Skip if this market doesn't exist on-chain
        if (params.loanToken == address(0)) {
            forked = false;
            return;
        }

        _createMorphoPosition();
    }

    /// @dev Supply 10 WETH collateral and borrow 3 000 USDC on Morpho Blue.
    function _createMorphoPosition() internal {
        uint256 collateralAmount = 10 ether;
        uint256 borrowAmount = 3000e6;

        deal(params.collateralToken, user, collateralAmount);

        vm.startPrank(user);

        IERC20(params.collateralToken).approve(MORPHO, collateralAmount);
        IMorphoFork(MORPHO).supplyCollateral(params, collateralAmount, user, "");

        IMorphoFork(MORPHO).borrow(params, borrowAmount, 0, user, user);

        vm.stopPrank();
    }

    // ─── getHealthFactor ───────────────────────────────────────────────

    function test_getHealthFactor_returnsFiniteForBorrower() public {
        if (!forked) return;

        uint256 hf = adapter.getHealthFactor(user);
        assertGt(hf, 0, "Health factor should be > 0 for active borrower");
        assertLt(hf, type(uint256).max, "Health factor should be finite for active borrower");
    }

    function test_getHealthFactor_returnsMaxForNonBorrower() public {
        if (!forked) return;

        address nobody = makeAddr("nobody");
        uint256 hf = adapter.getHealthFactor(nobody);
        assertEq(hf, type(uint256).max, "Non-borrower should have max health factor");
    }

    function test_getHealthFactor_decreasesAfterMoreBorrowing() public {
        if (!forked) return;

        uint256 hfBefore = adapter.getHealthFactor(user);

        uint256 additionalBorrow = 1000e6;
        vm.prank(user);
        IMorphoFork(MORPHO).borrow(params, additionalBorrow, 0, user, user);

        uint256 hfAfter = adapter.getHealthFactor(user);
        assertLt(hfAfter, hfBefore, "Health factor should decrease after additional borrowing");
    }

    // ─── checkDelegation ───────────────────────────────────────────────

    function test_checkDelegation_returnsFalseWithoutAuthorization() public {
        if (!forked) return;

        assertFalse(adapter.checkDelegation(user), "Should not be delegated by default");
    }

    function test_checkDelegation_returnsTrueAfterAuthorization() public {
        if (!forked) return;

        vm.prank(user);
        IMorphoFork(MORPHO).setAuthorization(address(adapter), true);

        assertTrue(adapter.checkDelegation(user), "Should be delegated after setAuthorization");
    }

    // ─── getCollateralValueUsd ──────────────────────────────────────────

    function test_getCollateralValueUsd_returnsNonZero() public {
        if (!forked) return;

        uint256 usdValue = adapter.getCollateralValueUsd(user);
        assertGt(usdValue, 0, "Collateral value should be > 0 for user with collateral");
    }

    function test_getCollateralValueUsd_returnsZeroForEmptyUser() public {
        if (!forked) return;

        address nobody = makeAddr("nobody");
        uint256 usdValue = adapter.getCollateralValueUsd(nobody);
        assertEq(usdValue, 0, "Collateral value should be 0 for empty user");
    }

    // ─── repay ─────────────────────────────────────────────────────────

    function test_repay_reducesDebtAndImprovesHealthFactor() public {
        if (!forked) return;

        uint256 hfBefore = adapter.getHealthFactor(user);

        uint256 repayAmount = 500e6;
        deal(params.loanToken, address(adapter), repayAmount);

        adapter.repay(user, params.loanToken, repayAmount);

        uint256 hfAfter = adapter.getHealthFactor(user);
        assertGt(hfAfter, hfBefore, "Health factor should improve after repayment");
    }

    // ─── withdrawCollateral ────────────────────────────────────────────

    function test_withdrawCollateral_sendsToRecipient() public {
        if (!forked) return;

        address recipient = makeAddr("recipient");
        uint256 withdrawAmount = 0.5 ether;

        // User must authorize the adapter
        vm.prank(user);
        IMorphoFork(MORPHO).setAuthorization(address(adapter), true);

        uint256 recipientBefore = IERC20(params.collateralToken).balanceOf(recipient);

        adapter.withdrawCollateral(user, params.collateralToken, withdrawAmount, recipient);

        uint256 recipientAfter = IERC20(params.collateralToken).balanceOf(recipient);
        assertEq(recipientAfter - recipientBefore, withdrawAmount, "Recipient should receive withdrawn collateral");
    }
}
