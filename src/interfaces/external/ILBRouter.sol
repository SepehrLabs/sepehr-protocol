// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @notice Minimal Trader Joe V2.2 Liquidity Book Router interface.
interface ILBRouter {
    enum Version {
        V1,
        V2,
        V2_1,
        V2_2
    }

    struct Path {
        uint256[] pairBinSteps;
        Version[] versions;
        address[] tokenPath;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Path memory path,
        address to,
        uint256 deadline
    ) external returns (uint256 amountOut);
}

/// @notice Minimal Trader Joe V2.2 LB Factory interface.
interface ILBFactory {
    struct LBPairInformation {
        uint16 binStep;
        address LBPair;
        bool createdByOwner;
        bool ignoredForRouting;
    }

    function getLBPairInformation(
        address tokenX,
        address tokenY,
        uint256 binStep
    ) external view returns (LBPairInformation memory);
}

/// @notice Minimal Trader Joe V2.2 LB Pair interface for quotes.
interface ILBPair {
    function getTokenY() external view returns (address);

    function getSwapOut(
        uint128 amountIn,
        bool swapForY
    ) external view returns (uint128 amountInLeft, uint128 amountOut, uint128 fee);
}
