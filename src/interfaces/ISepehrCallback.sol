// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title ISepehrCallback
/// @notice Callback interface invoked by flash-loan providers during the flash-loan execution.
///         SepehrCore implements this to perform the repay/withdraw/swap/refund sequence.
interface ISepehrCallback {
    /// @notice Called by the flash-loan provider after transferring `amount` of `asset`.
    ///         The implementer must repay the flash loan (principal + fee) before returning.
    /// @param asset The borrowed asset.
    /// @param amount The borrowed amount.
    /// @param fee The flash-loan fee to repay on top of `amount`.
    /// @param data The calldata forwarded from `flashBorrow`.
    function onFlashLoan(
        address asset,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external;
}
