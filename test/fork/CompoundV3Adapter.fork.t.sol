// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CompoundV3Adapter} from "../../src/adapters/CompoundV3Adapter.sol";
import {IComet} from "../../src/interfaces/external/IComet.sol";
import {ForkTestBase} from "./ForkTestBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Extended Comet interface for supply-collateral and withdraw used in test setup.
interface ICometFork {
    function supply(
        address asset,
        uint256 amount
    ) external;
    function withdraw(
        address asset,
        uint256 amount
    ) external;
    function allow(
        address manager,
        bool isAllowed
    ) external;
}

/// @notice WETH deposit interface.
interface IWETH {
    function deposit() external payable;
}

contract CompoundV3AdapterForkTest is ForkTestBase {
    // --- Ethereum mainnet addresses ---
    address constant COMET_USDC = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    CompoundV3Adapter internal adapter;
    bool internal forked;
    address internal user;

    function setUp() public {
        forked = _tryCreateFork("RPC_ETHEREUM_PRIMARY_HTTP");
        if (!forked) return;

        adapter = new CompoundV3Adapter(COMET_USDC, address(this));
        user = makeAddr("compV3User");

        _createCompoundPosition();
    }

    /// @dev Supply 10 WETH collateral and borrow 3 000 USDC from Compound V3.
    function _createCompoundPosition() internal {
        uint256 collateralAmount = 10 ether;
        uint256 borrowAmount = 3000e6;

        deal(WETH, user, collateralAmount);

        vm.startPrank(user);

        // Supply WETH as collateral
        IERC20(WETH).approve(COMET_USDC, collateralAmount);
        ICometFork(COMET_USDC).supply(WETH, collateralAmount);

        // Borrow USDC (withdraw base token)
        ICometFork(COMET_USDC).withdraw(USDC, borrowAmount);

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

        // Borrow more
        vm.prank(user);
        ICometFork(COMET_USDC).withdraw(USDC, 2000e6);

        uint256 hfAfter = adapter.getHealthFactor(user);
        assertLt(hfAfter, hfBefore, "Health factor should decrease after additional borrowing");
    }

    // ─── checkDelegation ───────────────────────────────────────────────

    function test_checkDelegation_returnsFalseWithoutAllow() public {
        if (!forked) return;

        assertFalse(adapter.checkDelegation(user), "Should not be delegated by default");
    }

    function test_checkDelegation_returnsTrueAfterAllow() public {
        if (!forked) return;

        vm.prank(user);
        ICometFork(COMET_USDC).allow(address(adapter), true);

        assertTrue(adapter.checkDelegation(user), "Should be delegated after allow(true)");
    }

    // ─── getCollateralValueUsd ──────────────────────────────────────────

    function test_getCollateralValueUsd_returnsNonZero() public {
        if (!forked) return;

        uint256 usdValue = adapter.getCollateralValueUsd(user);
        assertGt(usdValue, 0, "Collateral value should be > 0 for user with WETH collateral");
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

        uint256 repayAmount = 1000e6;
        deal(USDC, address(adapter), repayAmount);

        adapter.repay(user, USDC, repayAmount);

        uint256 hfAfter = adapter.getHealthFactor(user);
        assertGt(hfAfter, hfBefore, "Health factor should improve after repayment");
    }

    // ─── withdrawCollateral ────────────────────────────────────────────

    function test_withdrawCollateral_sendsToRecipient() public {
        if (!forked) return;

        address recipient = makeAddr("recipient");
        uint256 withdrawAmount = 0.5 ether;

        // User must allow the adapter to act on their behalf
        vm.prank(user);
        ICometFork(COMET_USDC).allow(address(adapter), true);

        uint256 recipientBefore = IERC20(WETH).balanceOf(recipient);

        adapter.withdrawCollateral(user, WETH, withdrawAmount, recipient);

        uint256 recipientAfter = IERC20(WETH).balanceOf(recipient);
        assertEq(recipientAfter - recipientBefore, withdrawAmount, "Recipient should receive withdrawn WETH");
    }

    function test_withdrawCollateral_reducesCollateralValue() public {
        if (!forked) return;

        uint256 valueBefore = adapter.getCollateralValueUsd(user);

        uint256 withdrawAmount = 1 ether;
        address recipient = makeAddr("recipient");

        vm.prank(user);
        ICometFork(COMET_USDC).allow(address(adapter), true);

        adapter.withdrawCollateral(user, WETH, withdrawAmount, recipient);

        uint256 valueAfter = adapter.getCollateralValueUsd(user);
        assertLt(valueAfter, valueBefore, "Collateral value should decrease after withdrawal");
    }
}
