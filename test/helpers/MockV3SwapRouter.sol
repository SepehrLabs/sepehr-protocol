// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock Uniswap V3 SwapRouter for unit tests.
contract MockV3SwapRouter {
    uint256 public exchangeRate = 1e18;

    uint160 public lastSqrtPriceLimitX96;
    uint24 public lastFee;

    function setExchangeRate(
        uint256 rate
    ) external {
        exchangeRate = rate;
    }

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable returns (uint256 amountOut) {
        lastSqrtPriceLimitX96 = params.sqrtPriceLimitX96;
        lastFee = params.fee;
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        amountOut = (params.amountIn * exchangeRate) / 1e18;
        require(amountOut >= params.amountOutMinimum, "MockV3: slippage");
        IERC20(params.tokenOut).transfer(params.recipient, amountOut);
    }
}
