// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {FluidAdapter} from "../../src/adapters/FluidAdapter.sol";
import {IFluidVault} from "../../src/interfaces/external/IFluidVault.sol";
import {ForkTestBase} from "./ForkTestBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract FluidAdapterForkTest is ForkTestBase {
    // --- Ethereum mainnet addresses ---
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    FluidAdapter internal adapter;
    bool internal _forked;
    address internal user;
    address internal mockVault;

    function setUp() public {
        _forked = _tryCreateFork("RPC_ETHEREUM_PRIMARY_HTTP");
        if (!_forked) return;

        user = makeAddr("fluidUser");

        // Fluid vault addresses are deployment-specific and can change.
        // Use a mock vault address and mock calls to verify adapter logic.
        mockVault = makeAddr("fluidVault");
        adapter = new FluidAdapter(mockVault, address(this));
    }

    // ─── getHealthFactor ──────────────────────────────────────────────

    function test_getHealthFactor_delegatesToVault() public {
        if (!_forked) return;

        uint256 expectedHf = 1.5e18;
        vm.mockCall(
            mockVault, abi.encodeWithSelector(IFluidVault.getHealthFactor.selector, user), abi.encode(expectedHf)
        );

        uint256 hf = adapter.getHealthFactor(user);
        assertEq(hf, expectedHf, "Health factor should match vault return value");
    }

    function test_getHealthFactor_returnsVaultValueForHealthyPosition() public {
        if (!_forked) return;

        uint256 healthyHf = 3e18;
        vm.mockCall(
            mockVault, abi.encodeWithSelector(IFluidVault.getHealthFactor.selector, user), abi.encode(healthyHf)
        );

        uint256 hf = adapter.getHealthFactor(user);
        assertGt(hf, 1e18, "Healthy position should have HF > 1.0");
    }

    // ─── checkDelegation ──────────────────────────────────────────────

    function test_checkDelegation_returnsFalseWithoutAuth() public {
        if (!_forked) return;

        vm.mockCall(
            mockVault, abi.encodeWithSelector(IFluidVault.isAuth.selector, user, address(adapter)), abi.encode(false)
        );

        assertFalse(adapter.checkDelegation(user), "Should not be delegated without auth");
    }

    function test_checkDelegation_returnsTrueWithAuth() public {
        if (!_forked) return;

        vm.mockCall(
            mockVault, abi.encodeWithSelector(IFluidVault.isAuth.selector, user, address(adapter)), abi.encode(true)
        );

        assertTrue(adapter.checkDelegation(user), "Should be delegated with auth");
    }

    // ─── getCollateralValueUsd ────────────────────────────────────────

    function test_getCollateralValueUsd_delegatesToVault() public {
        if (!_forked) return;

        uint256 expectedValue = 25_000e8;
        vm.mockCall(
            mockVault,
            abi.encodeWithSelector(IFluidVault.getCollateralValueUsd.selector, user),
            abi.encode(expectedValue)
        );

        uint256 usdValue = adapter.getCollateralValueUsd(user);
        assertEq(usdValue, expectedValue, "Collateral value should match vault return value");
    }
}
