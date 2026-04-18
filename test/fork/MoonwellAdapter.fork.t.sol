// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {MoonwellAdapter} from "../../src/adapters/MoonwellAdapter.sol";
import {ForkTestBase} from "./ForkTestBase.sol";

/// @notice Moonwell is a Compound V2 fork deployed on Base and Optimism. These
///         fork tests bind the adapter against the real Moonwell Comptroller
///         and mToken contracts on Base and validate the on-chain interface
///         surface. Tests are skipped if RPC_BASE_PRIMARY_HTTP is not set.
contract MoonwellAdapterForkTest is ForkTestBase {
    // Moonwell mainnet addresses on Base (docs.moonwell.fi)
    address constant MOONWELL_UNITROLLER = 0xfBb21d0380beE3312B33c4353c8936a0F13EF26C;
    address constant MUSDC = 0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22;

    MoonwellAdapter internal adapter;
    bool internal forked;

    function setUp() public {
        forked = _tryCreateFork("RPC_BASE_PRIMARY_HTTP");
        if (!forked) return;
        adapter = new MoonwellAdapter(MOONWELL_UNITROLLER, MUSDC, address(this));
    }

    function test_getHealthFactor_onInactiveUserReturnsOneWad() public {
        if (!forked) return;
        uint256 hf = adapter.getHealthFactor(makeAddr("freshUser"));
        assertEq(hf, 1e18, "Zero-balance user should map to 1.0 on Moonwell");
    }

    function test_checkDelegation_defaultsToFalse() public {
        if (!forked) return;
        assertFalse(adapter.checkDelegation(makeAddr("noDelegation")));
    }

    function test_getCollateralValueUsd_zeroForFreshUser() public {
        if (!forked) return;
        assertEq(adapter.getCollateralValueUsd(makeAddr("noCollateral")), 0);
    }

    function test_immutables_pointToMoonwellContracts() public view {
        if (!forked) return;
        assertEq(address(adapter.COMPTROLLER()), MOONWELL_UNITROLLER);
        assertEq(address(adapter.MTOKEN()), MUSDC);
    }
}
