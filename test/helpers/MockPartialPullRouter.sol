// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal Uniswap V2-style router mock that deliberately pulls less than
///         `amountIn` from its caller, simulating a fee-on-transfer `tokenIn` or a
///         buggy external router. Used by the D5 tests to verify that the Sepehr
///         router wrappers zero their allowance and sweep residual `tokenIn` back
///         to the caller.
contract MockPartialPullRouter {
    uint256 public exchangeRate = 1e18;
    /// @notice Fraction of `amountIn` actually pulled from msg.sender, in WAD (1e18 = full).
    uint256 public pullRatio = 1e18;

    function setExchangeRate(
        uint256 rate
    ) external {
        exchangeRate = rate;
    }

    function setPullRatio(
        uint256 ratio
    ) external {
        pullRatio = ratio;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        uint256 pulled = (amountIn * pullRatio) / 1e18;
        IERC20(path[0]).transferFrom(msg.sender, address(this), pulled);
        uint256 amountOut = (pulled * exchangeRate) / 1e18;
        require(amountOut >= amountOutMin, "MockPartial: slippage");
        IERC20(path[path.length - 1]).transfer(to, amountOut);

        amounts = new uint256[](path.length);
        amounts[0] = pulled;
        amounts[path.length - 1] = amountOut;
    }

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = (amountIn * exchangeRate) / 1e18;
    }
}
