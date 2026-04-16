// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title IProtocolAdapter
/// @notice Interface for protocol-specific adapters that handle repaying debt
///         and withdrawing collateral on behalf of a user.
interface IProtocolAdapter {
    /// @notice Returns the current health factor of the user's position, in WAD (1e18 = 1.0).
    /// @param user The user whose position to query.
    /// @return healthFactor The health factor in 18-decimal fixed point.
    function getHealthFactor(
        address user
    ) external view returns (uint256 healthFactor);

    /// @notice Check whether the user has granted Sepehr the required authorization
    ///         for this protocol (aToken approval, Comet.allow, Morpho.setAuthorization, etc.).
    /// @param user The user to check.
    /// @return delegated True if Sepehr can act on the user's position.
    function checkDelegation(
        address user
    ) external view returns (bool delegated);

    /// @notice Repay `amount` of `debtAsset` on behalf of `user`.
    /// @dev Caller must have already transferred `amount` of `debtAsset` to this contract.
    /// @param user The borrower.
    /// @param debtAsset The debt token address.
    /// @param amount The amount to repay (in the debt token's native decimals).
    function repay(
        address user,
        address debtAsset,
        uint256 amount
    ) external;

    /// @notice Withdraw `amount` of `collateralAsset` from `user`'s position to `recipient`.
    /// @param user The position owner.
    /// @param collateralAsset The collateral token address.
    /// @param amount The amount to withdraw.
    /// @param recipient Where to send the withdrawn collateral.
    function withdrawCollateral(
        address user,
        address collateralAsset,
        uint256 amount,
        address recipient
    ) external;

    /// @notice Get the total collateral value in USD (8 decimals) for the user.
    /// @param user The user to query.
    /// @return usdValue The total collateral value in 8-decimal USD.
    function getCollateralValueUsd(
        address user
    ) external view returns (uint256 usdValue);
}
