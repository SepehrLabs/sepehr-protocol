// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @notice Minimal Fluid (Instadapp) vault interface.
interface IFluidVault {
    function repay(
        address onBehalfOf,
        uint256 amount
    ) external returns (uint256);

    function withdraw(
        uint256 amount,
        address to
    ) external returns (uint256);

    function getHealthFactor(
        address user
    ) external view returns (uint256);

    function isAuth(
        address user,
        address auth
    ) external view returns (bool);

    function getCollateralValueUsd(
        address user
    ) external view returns (uint256);
}
