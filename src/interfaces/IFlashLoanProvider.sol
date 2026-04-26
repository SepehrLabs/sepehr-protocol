// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

/// @title IFlashLoanProvider
/// @notice Interface for flash-loan providers. Each implementation wraps a specific
///         flash-loan source (Aave, Balancer, Uniswap V3) behind a uniform API.
interface IFlashLoanProvider {
    /// @notice Borrow `amount` of `asset` via flash loan, then call back `callback`
    ///         with `data`. The callback must repay the flash loan (principal + fee)
    ///         before the transaction ends.
    /// @param asset The ERC20 token to borrow.
    /// @param amount The amount to borrow.
    /// @param callback The address to call back (must implement ISepehrCallback).
    /// @param data Arbitrary data forwarded to the callback.
    function flashBorrow(
        address asset,
        uint256 amount,
        address callback,
        bytes calldata data
    ) external;

    /// @notice Returns the fee in basis points charged by this flash-loan source.
    /// @param asset The token to check the fee for.
    /// @return feeBps The fee in basis points (e.g. 9 = 0.09%).
    function getFlashLoanFeeBps(
        address asset
    ) external view returns (uint256 feeBps);

    /// @notice Check whether this provider can supply `amount` of `asset`.
    /// @param asset The token.
    /// @param amount The amount needed.
    /// @return available True if the pool has sufficient liquidity.
    function isAvailable(
        address asset,
        uint256 amount
    ) external view returns (bool available);
}
