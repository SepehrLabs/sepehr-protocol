// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice 18-decimal fixed-point helpers for health-factor arithmetic.
/// @dev Both `wadMul` and `wadDiv` floor (round toward zero). An earlier revision rounded
///      half-up, which silently overstated computed solvency by up to HALF_WAD. Solvency
///      math must never overestimate — flooring matches OZ MathUpgradeable.mulDiv and
///      DSMath conventions, and keeps downstream HF checks conservative.
library HealthFactorMath {
    uint256 internal constant WAD = 1e18;

    /// @notice Multiply two WAD values, rounding down (toward zero).
    function wadMul(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return (a * b) / WAD;
    }

    /// @notice Divide two WAD values, rounding down (toward zero).
    function wadDiv(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return (a * WAD) / b;
    }

    /// @notice Convert a raw number to WAD representation.
    function toWad(
        uint256 a
    ) internal pure returns (uint256) {
        return a * WAD;
    }

    /// @notice Calculate (a * b) / c with full precision, rounding up.
    function mulDivRoundUp(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal pure returns (uint256) {
        uint256 result = a * b;
        return (result + c - 1) / c;
    }

    /// @notice Calculate (a * b) / c with full precision, rounding down.
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal pure returns (uint256) {
        return (a * b) / c;
    }
}
