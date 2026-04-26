// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

abstract contract ForkTestBase is Test {
    modifier onlyForked() {
        if (block.chainid == 31_337) {
            return; // skip on local anvil
        }
        _;
    }

    function _tryCreateFork(
        string memory envKey
    ) internal returns (bool success) {
        string memory rpcUrl = vm.envOr(envKey, string(""));
        if (bytes(rpcUrl).length == 0) return false;
        vm.createSelectFork(rpcUrl);
        return true;
    }

    function _tryCreateForkAtBlock(
        string memory envKey,
        uint256 blockNumber
    ) internal returns (bool success) {
        string memory rpcUrl = vm.envOr(envKey, string(""));
        if (bytes(rpcUrl).length == 0) return false;
        vm.createSelectFork(rpcUrl, blockNumber);
        return true;
    }
}
