// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @notice Basis-point (bps) arithmetic. 1 bps = 0.01%, 10_000 bps = 100%.
library Percentages {
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant MAX_BPS = 10_000;

    /// @notice Owner share of every trigger fee, in bps. Owner keeps 85 %, keeper earns 15 %.
    /// @dev A21: named so the 85/15 split is not encoded as a bare literal inside `splitFee`.
    uint256 internal constant OWNER_FEE_SPLIT_BPS = 8500;
    uint256 internal constant KEEPER_FEE_SPLIT_BPS = BPS_DENOMINATOR - OWNER_FEE_SPLIT_BPS;

    /// @notice Apply a bps percentage to an amount, rounding down.
    function applyBps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return (amount * bps) / BPS_DENOMINATOR;
    }

    /// @notice Apply a bps percentage to an amount, rounding up.
    function applyBpsRoundUp(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return (amount * bps + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
    }

    /// @notice Compute how many bps `part` is of `whole`.
    function toBps(uint256 part, uint256 whole) internal pure returns (uint256) {
        if (whole == 0) return 0;
        return (part * BPS_DENOMINATOR) / whole;
    }

    /// @notice Compute the owner share (85%) and keeper share (15%) of a fee.
    function splitFee(uint256 totalFee) internal pure returns (uint256 ownerShare, uint256 keeperShare) {
        ownerShare = (totalFee * OWNER_FEE_SPLIT_BPS) / BPS_DENOMINATOR;
        keeperShare = totalFee - ownerShare;
    }
}
