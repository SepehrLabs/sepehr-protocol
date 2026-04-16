// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @notice Minimal Compound V3 (Comet) interface.
interface IComet {
    function supply(
        address asset,
        uint256 amount
    ) external;

    function supplyTo(
        address dst,
        address asset,
        uint256 amount
    ) external;

    function withdrawFrom(
        address src,
        address to,
        address asset,
        uint256 amount
    ) external;

    function isAllowed(
        address owner,
        address manager
    ) external view returns (bool);

    function borrowBalanceOf(
        address account
    ) external view returns (uint256);

    function collateralBalanceOf(
        address account,
        address asset
    ) external view returns (uint128);

    function baseToken() external view returns (address);

    function numAssets() external view returns (uint8);

    function getAssetInfo(
        uint8 i
    )
        external
        view
        returns (
            uint8 offset,
            address asset,
            address priceFeed,
            uint64 scale,
            uint64 borrowCollateralFactor,
            uint64 liquidateCollateralFactor,
            uint64 liquidationFactor,
            uint128 supplyCap
        );

    function getPrice(
        address priceFeed
    ) external view returns (uint256);

    function baseTokenPriceFeed() external view returns (address);
}
