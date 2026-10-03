// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal `aggregate3` (Multicall3 ABI) so viem's multicall works on a
/// fresh, non-forked Anvil. The keeper acceptance test copies this runtime code to
/// the canonical Multicall3 address with `anvil_setCode`.
contract Multicall3Lite {
    struct Call3 {
        address target;
        bool allowFailure;
        bytes callData;
    }

    struct Result {
        bool success;
        bytes returnData;
    }

    function aggregate3(
        Call3[] calldata calls
    ) external payable returns (Result[] memory returnData) {
        returnData = new Result[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory ret) = calls[i].target.call(calls[i].callData);
            if (!success && !calls[i].allowFailure) revert("Multicall3Lite: call failed");
            returnData[i] = Result(success, ret);
        }
    }
}
