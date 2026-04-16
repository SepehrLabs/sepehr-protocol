// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @notice Mock Uniswap V3 Factory for unit tests.
contract MockV3Factory {
    mapping(address => mapping(address => mapping(uint24 => address))) private _pools;

    function setPool(
        address tokenA,
        address tokenB,
        uint24 fee,
        address pool
    ) external {
        _pools[tokenA][tokenB][fee] = pool;
        _pools[tokenB][tokenA][fee] = pool;
    }

    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external view returns (address) {
        return _pools[tokenA][tokenB][fee];
    }
}
