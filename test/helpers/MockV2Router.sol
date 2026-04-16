// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock Uniswap V2 Router for unit tests. Also used for V2 forks.
contract MockV2Router {
    uint256 public exchangeRate = 1e18;

    function setExchangeRate(
        uint256 rate
    ) external {
        exchangeRate = rate;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        uint256 amountOut = (amountIn * exchangeRate) / 1e18;
        require(amountOut >= amountOutMin, "MockV2: slippage");
        IERC20(path[path.length - 1]).transfer(to, amountOut);

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
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
