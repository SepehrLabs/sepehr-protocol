// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title ISubscriptionOracle
/// @notice Oracle for determining the USD value of the user's total collateral at
///         subscription time. Used to enforce the minimum-collateral gate and assign tiers.
interface ISubscriptionOracle {
    /// @notice Get the price of `asset` in USD with 8 decimals.
    /// @param asset The ERC20 token address.
    /// @return price USD price with 8 decimals (1e8 = $1.00).
    function getAssetPriceUsd(
        address asset
    ) external view returns (uint256 price);
}
