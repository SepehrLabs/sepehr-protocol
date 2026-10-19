// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

/// @notice Minimal Camelot DEX Router interface. Camelot's V2 router only swaps exact inputs
///         through the fee-on-transfer variant, which returns nothing: the output is measured.
interface ICamelotRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        address referrer,
        uint256 deadline
    ) external;

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);
}
