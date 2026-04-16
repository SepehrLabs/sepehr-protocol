// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @notice Minimal Curve Lending Controller (crvUSD) interface.
interface ICurveController {
    function health(
        address user
    ) external view returns (int256);

    function repay(
        uint256 amount,
        address _for
    ) external;

    function remove_collateral(
        uint256 amount
    ) external;

    function user_state(
        address user
    ) external view returns (uint256[4] memory);

    function amm() external view returns (address);

    function collateral_token() external view returns (address);

    function borrowed_token() external view returns (address);
}

/// @notice Minimal Curve LLAMMA AMM interface.
interface ICurveLlamma {
    function get_sum_xy(
        address user
    ) external view returns (uint256 x, uint256 y);
}
