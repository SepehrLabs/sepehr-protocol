// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {RadiantAdapter} from "../../src/adapters/RadiantAdapter.sol";
import {ForkTestBase} from "./ForkTestBase.sol";

/// @notice Radiant Capital is an Aave-fork cross-chain money market. These fork
///         tests target the Arbitrum LendingPool and validate the adapter's
///         on-chain interface surface. Tests are skipped if
///         RPC_ARBITRUM_PRIMARY_HTTP is not set.
contract RadiantAdapterForkTest is ForkTestBase {
    // Radiant v2 LendingPool on Arbitrum (docs.radiant.capital)
    address constant RADIANT_POOL = 0xF4B1486DD74D07706052A33d31d7c0AAFD0659E1;
    address constant RUSDC = 0x805ba50001779CeD4f59CfF63aea527D12B94829;

    RadiantAdapter internal adapter;
    bool internal forked;

    function setUp() public {
        forked = _tryCreateFork("RPC_ARBITRUM_PRIMARY_HTTP");
        if (!forked) return;
        adapter = new RadiantAdapter(RADIANT_POOL, RUSDC, address(this));
    }

    function test_getHealthFactor_onInactiveUserReturnsMax() public {
        if (!forked) return;
        uint256 hf = adapter.getHealthFactor(makeAddr("freshUser"));
        assertEq(hf, type(uint256).max, "Inactive user should have max HF on Radiant");
    }

    function test_checkDelegation_defaultsToFalse() public {
        if (!forked) return;
        assertFalse(adapter.checkDelegation(makeAddr("noDelegation")));
    }

    function test_getCollateralValueUsd_zeroForFreshUser() public {
        if (!forked) return;
        assertEq(adapter.getCollateralValueUsd(makeAddr("noCollateral")), 0);
    }

    function test_immutables_pointToRadiantContracts() public view {
        if (!forked) return;
        assertEq(address(adapter.POOL()), RADIANT_POOL);
        assertEq(adapter.RTOKEN(), RUSDC);
    }
}
