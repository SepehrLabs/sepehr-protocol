// SPDX-License-Identifier: GPL-2.0-or-later
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

    /// @notice Get a spot-price quote for swapping `amountIn` of `tokenIn` to `tokenOut`.
    /// @dev ADVISORY ONLY. Returns the instantaneous spot price of the underlying pool, which is
    ///      trivially manipulable within the same block (flash-loan sandwich, JIT liquidity, etc.).
    ///      Do NOT use the return value as an on-chain `minAmountOut` floor or any other
    ///      trust-sensitive input. SepehrCore derives `minAmountOut` from the Chainlink oracle
    ///      registry (`_oracleMinOut`), not from `getQuote`. Callers wanting a price feed for
    ///      on-chain logic must read a TWAP or an independent oracle.
    /// @param tokenIn The input token.
    /// @param tokenOut The output token.
    /// @param amountIn The amount of input token.
    /// @return amountOut The expected output amount at current spot price (manipulable).
    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut);
}
