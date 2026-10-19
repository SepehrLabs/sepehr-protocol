// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AaveV3Adapter} from "../../src/adapters/AaveV3Adapter.sol";
import {IAavePool} from "../../src/interfaces/external/IAavePool.sol";
import {ForkTestBase} from "./ForkTestBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Aave V3 Pool interface extension for supply/borrow used in test setup.
interface IAavePoolFork {
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;
    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external;
    function setUserUseReserveAsCollateral(
        address asset,
        bool useAsCollateral
    ) external;
}

/// @notice Aave V3 variable-debt token interface for credit delegation.
interface IVariableDebtToken {
    function approveDelegation(
        address delegatee,
        uint256 amount
    ) external;
}

contract AaveV3AdapterForkTest is ForkTestBase {
    // --- Ethereum mainnet addresses ---
    address constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant AWETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    AaveV3Adapter internal adapter;
    bool internal forked;
    address internal user;

    function setUp() public {
        forked = _tryCreateFork("RPC_ETHEREUM_PRIMARY_HTTP");
        if (!forked) return;

        adapter = new AaveV3Adapter(AAVE_V3_POOL, address(this));
        user = makeAddr("forkUser");

        _createAavePosition();
    }

    /// @dev Supply 10 WETH as collateral and borrow 5 000 USDC to create a leveraged position.
    function _createAavePosition() internal {
        uint256 supplyAmount = 10 ether;
        uint256 borrowAmount = 5000e6; // USDC has 6 decimals

        deal(WETH, user, supplyAmount);

        vm.startPrank(user);
        IERC20(WETH).approve(AAVE_V3_POOL, supplyAmount);
        IAavePoolFork(AAVE_V3_POOL).supply(WETH, supplyAmount, user, 0);
        IAavePoolFork(AAVE_V3_POOL).borrow(USDC, borrowAmount, 2, 0, user);
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
        // Non-borrowers have no debt; Aave returns type(uint256).max
        assertEq(hf, type(uint256).max, "No-debt user should have max health factor");
    }

    function test_getHealthFactor_decreasesAfterPriceDrop() public {
        if (!forked) return;

        uint256 hfBefore = adapter.getHealthFactor(user);

        // Borrow more to reduce health factor
        uint256 additionalBorrow = 5000e6;
        vm.prank(user);
        IAavePoolFork(AAVE_V3_POOL).borrow(USDC, additionalBorrow, 2, 0, user);

        uint256 hfAfter = adapter.getHealthFactor(user);
        assertLt(hfAfter, hfBefore, "Health factor should decrease after additional borrowing");
    }

    // ─── checkDelegation ───────────────────────────────────────────────

    function test_checkDelegation_returnsFalseWithoutApproval() public {
        if (!forked) return;

        assertFalse(adapter.checkDelegation(user), "Should not be delegated without approval");
    }

    function test_checkDelegation_returnsTrueAfterApproval() public {
        if (!forked) return;

        vm.prank(user);
        IERC20(AWETH).approve(address(adapter), type(uint256).max);

        assertTrue(adapter.checkDelegation(user), "Should be delegated after approval");
    }

    // ─── getCollateralValueUsd ──────────────────────────────────────────

    function test_getCollateralValueUsd_returnsNonZeroForCollateralizedUser() public {
        if (!forked) return;

        uint256 usdValue = adapter.getCollateralValueUsd(user);
        assertGt(usdValue, 0, "Collateral value should be > 0 for user with deposits");
    }

    function test_getCollateralValueUsd_returnsZeroForEmptyUser() public {
        if (!forked) return;

        address nobody = makeAddr("nobody");
        uint256 usdValue = adapter.getCollateralValueUsd(nobody);
        assertEq(usdValue, 0, "Collateral value should be 0 for user with no deposits");
    }

    // ─── repay ─────────────────────────────────────────────────────────

    function test_repay_reducesDebtAndImprovesHealthFactor() public {
        if (!forked) return;

        uint256 hfBefore = adapter.getHealthFactor(user);

        // Give USDC to the adapter so it can repay
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

        // User must approve the adapter to transfer aTokens
        vm.prank(user);
        IERC20(AWETH).approve(address(adapter), withdrawAmount);

        uint256 recipientBefore = IERC20(WETH).balanceOf(recipient);

        adapter.withdrawCollateral(user, WETH, withdrawAmount, recipient);

        uint256 recipientAfter = IERC20(WETH).balanceOf(recipient);
        assertEq(recipientAfter - recipientBefore, withdrawAmount, "Recipient should receive the withdrawn WETH");
    }

    function test_withdrawCollateral_reducesCollateralValue() public {
        if (!forked) return;

        uint256 valueBefore = adapter.getCollateralValueUsd(user);

        uint256 withdrawAmount = 1 ether;
        address recipient = makeAddr("recipient");

        vm.prank(user);
        IERC20(AWETH).approve(address(adapter), withdrawAmount);

        adapter.withdrawCollateral(user, WETH, withdrawAmount, recipient);

        uint256 valueAfter = adapter.getCollateralValueUsd(user);
        assertLt(valueAfter, valueBefore, "Collateral value should decrease after withdrawal");
    }
}

/// @notice M-3 on Arbitrum One: a position with WETH and wstETH against USDC, where the adapter
///         withdraws whichever collateral the user approved.
contract AaveV3AdapterMultiCollateralArbitrumForkTest is ForkTestBase {
    address constant POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;
    address constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    AaveV3Adapter internal adapter;
    bool internal forked;
    address internal user;

    function setUp() public {
        forked = _tryCreateFork("RPC_ARBITRUM_PRIMARY_HTTP");
        if (!forked) return;

        adapter = new AaveV3Adapter(POOL, address(this));
        user = makeAddr("multiCollateralUser");
        deal(WETH, user, 3 ether);
        deal(WSTETH, user, 3 ether);

        vm.startPrank(user);
        IERC20(WETH).approve(POOL, 3 ether);
        IERC20(WSTETH).approve(POOL, 3 ether);
        IAavePoolFork(POOL).supply(WETH, 3 ether, user, 0);
        IAavePoolFork(POOL).supply(WSTETH, 3 ether, user, 0);
        IAavePoolFork(POOL).borrow(USDC, 5000e6, 2, 0, user);
        vm.stopPrank();
    }

    function _aToken(
        address asset
    ) internal view returns (address aToken) {
        (,,,,,,,, aToken,,,,,,) = IAavePool(POOL).getReserveData(asset);
    }

    function _approve(
        address asset
    ) internal {
        address aToken = _aToken(asset);
        vm.prank(user);
        IERC20(aToken).approve(address(adapter), type(uint256).max);
    }

    function test_checkDelegation_followsTheApprovedCollaterals() public {
        if (!forked) return;

        assertFalse(adapter.checkDelegation(user), "nothing approved yet");
        _approve(WSTETH);
        assertTrue(adapter.checkDelegation(user));
        assertTrue(adapter.isDelegated(user, WSTETH));
        assertFalse(adapter.isDelegated(user, WETH));

        AaveV3Adapter.Collateral[] memory list = adapter.collateralsOf(user);
        assertEq(list.length, 2);
        for (uint256 i = 0; i < list.length; i++) {
            assertGt(list[i].balance, 0);
            assertEq(list[i].allowance, list[i].asset == WSTETH ? type(uint256).max : 0);
        }
    }

    function test_checkDelegation_ignoresAnApprovedAssetNotSupplied() public {
        if (!forked) return;

        _approve(WBTC);
        assertFalse(adapter.checkDelegation(user));
    }

    function test_withdrawCollateral_takesTheNamedCollateral() public {
        if (!forked) return;

        _approve(WSTETH);
        address recipient = makeAddr("recipient");
        uint256 wethCollateralBefore = IERC20(_aToken(WETH)).balanceOf(user);

        adapter.withdrawCollateral(user, WSTETH, 1 ether, recipient);

        assertEq(IERC20(WSTETH).balanceOf(recipient), 1 ether);
        assertEq(IERC20(_aToken(WETH)).balanceOf(user), wethCollateralBefore, "WETH untouched");
        assertLt(adapter.getHealthFactor(user), type(uint256).max);
    }
}
