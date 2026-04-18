// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {VenusAdapter} from "../../src/adapters/VenusAdapter.sol";
import {ForkTestBase} from "./ForkTestBase.sol";

/// @notice Venus Protocol is a Compound V2 fork on BSC. These fork tests bind
///         the adapter against the real Venus Comptroller and vToken contracts
///         and validate the on-chain interface surface. Tests are skipped if
///         RPC_BSC_PRIMARY_HTTP is not set.
contract VenusAdapterForkTest is ForkTestBase {
    // Venus Protocol mainnet addresses on BSC (docs.venus.io)
    address constant VENUS_UNITROLLER = 0xfD36E2c2a6789Db23113685031d7F16329158384;
    address constant VUSDC = 0xecA88125a5ADbe82614ffC12D0DB554E2e2867C8;

    VenusAdapter internal adapter;
    bool internal forked;

    function setUp() public {
        forked = _tryCreateFork("RPC_BSC_PRIMARY_HTTP");
        if (!forked) return;
        adapter = new VenusAdapter(VENUS_UNITROLLER, VUSDC, address(this));
    }

    function test_getHealthFactor_onInactiveUserReturnsOneWad() public {
        if (!forked) return;
        // Compound-style comptroller returns (0, 0) for users with no borrows
        // which our adapter maps to WAD (1e18).
        uint256 hf = adapter.getHealthFactor(makeAddr("freshUser"));
        assertEq(hf, 1e18, "Zero-balance user should map to 1.0 on Venus");
    }

    function test_checkDelegation_defaultsToFalse() public {
        if (!forked) return;
        assertFalse(adapter.checkDelegation(makeAddr("noDelegation")));
    }

    function test_getCollateralValueUsd_zeroForFreshUser() public {
        if (!forked) return;
        assertEq(adapter.getCollateralValueUsd(makeAddr("noCollateral")), 0);
    }

    function test_immutables_pointToVenusContracts() public view {
        if (!forked) return;
        assertEq(address(adapter.COMPTROLLER()), VENUS_UNITROLLER);
        assertEq(address(adapter.VTOKEN()), VUSDC);
    }
}
