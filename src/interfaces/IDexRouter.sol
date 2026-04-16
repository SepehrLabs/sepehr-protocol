// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title IDexRouter
/// @notice Uniform DEX swap interface. Each implementation wraps a specific DEX
///         (Uniswap V3, Velodrome, Camelot, etc.).
interface IDexRouter {
    /// @notice Swap `amountIn` of `tokenIn` for at least `minAmountOut` of `tokenOut`.
    /// @dev Caller must have approved this contract to spend `tokenIn`.
    /// @param tokenIn The input token.
    /// @param tokenOut The output token.
    /// @param amountIn The amount of input token.
    /// @param minAmountOut The minimum acceptable output amount (slippage protection).
    /// @param routeData Optional encoded route hints (pool fees, multi-hop paths, etc.).
    /// @return amountOut The actual amount of tokenOut received.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata routeData
    ) external returns (uint256 amountOut);

    /// @notice Get a quote for swapping `amountIn` of `tokenIn` to `tokenOut`.
    /// @param tokenIn The input token.
    /// @param tokenOut The output token.
    /// @param amountIn The amount of input token.
    /// @return amountOut The expected output amount.
    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut);
}
