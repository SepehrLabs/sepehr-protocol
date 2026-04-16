// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @notice 18-decimal fixed-point helpers for health-factor arithmetic.
library HealthFactorMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant HALF_WAD = 0.5e18;

    /// @notice Multiply two WAD values, rounding down.
    function wadMul(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return (a * b + HALF_WAD) / WAD;
    }

    /// @notice Divide two WAD values, rounding down.
    function wadDiv(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return (a * WAD + b / 2) / b;
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
