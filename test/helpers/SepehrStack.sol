// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {SepehrCore} from "../../src/SepehrCore.sol";
import {SepehrSubscriptions} from "../../src/SepehrSubscriptions.sol";

/// @notice Deploys SepehrSubscriptions, then SepehrCore at the address it was given, as the
///         deploy scripts do.
abstract contract SepehrStack is Test {
    function _deployStack(
        address owner,
        address timelock,
        address guardian,
        address usdc,
        uint256 minCollateralUsd,
        uint256 tvlCapUsd
    ) internal returns (SepehrCore core, SepehrSubscriptions subs) {
        address nextCore = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        subs = new SepehrSubscriptions(owner, timelock, usdc, block.chainid, nextCore);
        core = new SepehrCore(owner, timelock, guardian, address(subs), minCollateralUsd, tvlCapUsd, block.chainid);
    }
}
