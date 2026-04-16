// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {CurveLlamalendAdapter} from "../../src/adapters/CurveLlamalendAdapter.sol";
import {ICurveController} from "../../src/interfaces/external/ICurveLlamma.sol";
import {ForkTestBase} from "./ForkTestBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CurveLlamalendAdapterForkTest is ForkTestBase {
    // --- Ethereum mainnet addresses ---
    // crvUSD Controller for WETH collateral
    address constant CRVUSD_WETH_CONTROLLER = 0x100dAa78fC509Db39Ef7D04DE0c1ABD299f4C6CE;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    CurveLlamalendAdapter internal adapter;
    bool internal _forked;
    address internal user;
    address internal mockController;

    function setUp() public {
        _forked = _tryCreateFork("RPC_ETHEREUM_PRIMARY_HTTP");
        if (!_forked) return;

        user = makeAddr("curveUser");

        // Deploy adapter with a mock controller to verify logic.
        // The real controller's create_loan/borrow functions require
        // specific conditions that are hard to replicate without
        // deep protocol setup.
        mockController = makeAddr("curveController");
        address mockOracle = makeAddr("curvePriceOracle");
        adapter = new CurveLlamalendAdapter(mockController, mockOracle);
    }

    // ─── getHealthFactor ──────────────────────────────────────────────

    function test_getHealthFactor_convertsPositiveHealthToHF() public {
        if (!_forked) return;

        // Curve health = 0.5e18 means 50% margin above liquidation.
        // Expected adapter output: 1e18 + 0.5e18 = 1.5e18
        int256 curveHealth = 0.5e18;
        vm.mockCall(
            mockController, abi.encodeWithSelector(ICurveController.health.selector, user), abi.encode(curveHealth)
        );

        uint256 hf = adapter.getHealthFactor(user);
        assertEq(hf, 1.5e18, "HF should be 1 + health margin");
    }

    function test_getHealthFactor_returnsZeroAtLiquidation() public {
        if (!_forked) return;

        // Curve health = 0 means at liquidation threshold.
        int256 curveHealth = int256(0);
        vm.mockCall(
            mockController, abi.encodeWithSelector(ICurveController.health.selector, user), abi.encode(curveHealth)
        );

        uint256 hf = adapter.getHealthFactor(user);
        assertEq(hf, 0, "HF should be 0 at liquidation boundary");
    }

    function test_getHealthFactor_returnsZeroWhenNegativeHealth() public {
        if (!_forked) return;

        // Curve health < 0 means past liquidation.
        int256 curveHealth = -0.1e18;
        vm.mockCall(
            mockController, abi.encodeWithSelector(ICurveController.health.selector, user), abi.encode(curveHealth)
        );

        uint256 hf = adapter.getHealthFactor(user);
        assertEq(hf, 0, "HF should be 0 when past liquidation");
    }

    // ─── checkDelegation ──────────────────────────────────────────────

    function test_checkDelegation_alwaysReturnsTrue() public {
        if (!_forked) return;

        // Curve Llamalend adapter always returns true since there is no
        // on-chain delegation mechanism.
        assertTrue(adapter.checkDelegation(user), "Curve adapter should always return true for delegation");
        assertTrue(adapter.checkDelegation(address(0xdead)), "Curve adapter should always return true for any address");
    }

    // ─── getCollateralValueUsd ────────────────────────────────────────

    function test_getCollateralValueUsd_computesFromUserState() public {
        if (!_forked) return;

        // user_state returns [collateral, stablecoin, debt, N]
        uint256[4] memory state = [uint256(5e18), uint256(2000e18), uint256(1000e18), uint256(4)];
        vm.mockCall(
            mockController, abi.encodeWithSelector(ICurveController.user_state.selector, user), abi.encode(state)
        );

        uint256 usdValue = adapter.getCollateralValueUsd(user);
        // Expected: (stablecoin + collateral) / 1e10 = (2000e18 + 5e18) / 1e10
        uint256 expected = (2000e18 + 5e18) / 1e10;
        assertEq(usdValue, expected, "Collateral value should combine stablecoin and collateral");
    }
}
