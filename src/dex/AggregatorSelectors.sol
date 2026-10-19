// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title AggregatorSelectors
/// @notice Lot 7: the exact-input swap functions each AggregatorRouter may call, fixed at its
///         deployment. Exact-output, RFQ and administrative functions are left out.
library AggregatorSelectors {
    /// @notice KyberSwap MetaAggregationRouterV2: `swap` and `swapSimpleMode`.
    function kyberSwap() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = 0xe21fd0e9; // swap((address,address,bytes,(…)),bytes)
        selectors[1] = 0x8af033fb; // swapSimpleMode(address,(…),bytes,bytes)
    }

    /// @notice Velora (ParaSwap) AugustusV6.2: `swapExactAmountIn` and its direct-pool variants.
    function velora() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = 0xe3ead59e; // swapExactAmountIn
        selectors[1] = 0xe8bb3b6c; // swapExactAmountInOnUniswapV2
        selectors[2] = 0x876a02f6; // swapExactAmountInOnUniswapV3
        selectors[3] = 0xd85ca173; // swapExactAmountInOnBalancerV2
        selectors[4] = 0xe37ed256; // swapExactAmountInOnCurveV2
    }
}
