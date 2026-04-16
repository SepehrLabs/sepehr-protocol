// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IDexRouter} from "../interfaces/IDexRouter.sol";
import {IUniswapV2Router} from "../interfaces/external/IUniswapV2Router.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title UniV2ForkRouter
/// @notice Wraps any Uniswap V2 fork router (SushiSwap, PancakeSwap, etc.) behind IDexRouter.
///         routeData: unused (always direct tokenIn → tokenOut path).
contract UniV2ForkRouter is IDexRouter {
    using SafeERC20 for IERC20;

    IUniswapV2Router public immutable ROUTER;

    constructor(
        address router
    ) {
        if (router == address(0)) revert SepehrErrors.ZeroAddress();
        ROUTER = IUniswapV2Router(router);
    }

    /// @inheritdoc IDexRouter
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata
    ) external override returns (uint256 amountOut) {
        if (amountIn == 0) revert SepehrErrors.ZeroAmount();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(ROUTER), amountIn);

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        uint256[] memory amounts =
            ROUTER.swapExactTokensForTokens(amountIn, minAmountOut, path, msg.sender, block.timestamp);
        amountOut = amounts[amounts.length - 1];
    }

    /// @inheritdoc IDexRouter
    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view override returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        uint256[] memory amounts = ROUTER.getAmountsOut(amountIn, path);
        return amounts[amounts.length - 1];
    }
}
