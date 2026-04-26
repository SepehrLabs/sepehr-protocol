// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

/// @notice Minimal Uniswap V3 Pool interface for flash loans.
interface IUniswapV3Pool {
    function flash(
        address recipient,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;

    function fee() external view returns (uint24);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}
