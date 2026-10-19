// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AggregatorSelectors} from "../../../src/dex/AggregatorSelectors.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Each allowed selector is the one of the aggregator's exact-input swap function.
contract AggregatorSelectorsTest is Test {
    function test_kyberSwap_allowsSwapAndSwapSimpleMode() public pure {
        bytes4[] memory selectors = AggregatorSelectors.kyberSwap();
        assertEq(selectors.length, 2);
        assertEq(
            selectors[0],
            bytes4(
                keccak256(
                    "swap((address,address,bytes,(address,address,address[],uint256[],address[],uint256[],address,uint256,uint256,uint256,bytes),bytes))"
                )
            )
        );
        assertEq(
            selectors[1],
            bytes4(
                keccak256(
                    "swapSimpleMode(address,(address,address,address[],uint256[],address[],uint256[],address,uint256,uint256,uint256,bytes),bytes,bytes)"
                )
            )
        );
    }

    function test_velora_allowsTheExactAmountInSwaps() public pure {
        bytes4[] memory selectors = AggregatorSelectors.velora();
        assertEq(selectors.length, 5);
        assertEq(
            selectors[0],
            bytes4(
                keccak256(
                    "swapExactAmountIn(address,(address,address,uint256,uint256,uint256,bytes32,address),uint256,bytes,bytes)"
                )
            )
        );
        assertEq(
            selectors[1],
            bytes4(
                keccak256(
                    "swapExactAmountInOnUniswapV2((address,address,uint256,uint256,uint256,bytes32,address,bytes),uint256,bytes)"
                )
            )
        );
        assertEq(
            selectors[2],
            bytes4(
                keccak256(
                    "swapExactAmountInOnUniswapV3((address,address,uint256,uint256,uint256,bytes32,address,bytes),uint256,bytes)"
                )
            )
        );
        assertEq(
            selectors[3],
            bytes4(
                keccak256(
                    "swapExactAmountInOnBalancerV2((uint256,uint256,uint256,bytes32,uint256),uint256,bytes,bytes)"
                )
            )
        );
        assertEq(
            selectors[4],
            bytes4(
                keccak256(
                    "swapExactAmountInOnCurveV2((uint256,uint256,uint256,address,address,address,uint256,uint256,uint256,bytes32,address),uint256,bytes)"
                )
            )
        );
    }
}
