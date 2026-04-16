// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IDexRouter} from "../interfaces/IDexRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockDex is IDexRouter {
    uint256 public exchangeRate = 1e18; // 1:1 by default (in WAD)

    function setExchangeRate(
        uint256 rate
    ) external {
        exchangeRate = rate;
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata
    ) external override returns (uint256 amountOut) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        amountOut = (amountIn * exchangeRate) / 1e18;
        require(amountOut >= minAmountOut, "MockDex: slippage");

        IERC20(tokenOut).transfer(msg.sender, amountOut);
    }

    function getQuote(
        address,
        address,
        uint256 amountIn
    ) external view override returns (uint256) {
        return (amountIn * exchangeRate) / 1e18;
    }
}
