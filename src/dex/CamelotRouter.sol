// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IDexRouter} from "../interfaces/IDexRouter.sol";
import {ICamelotRouter} from "../interfaces/external/ICamelotRouter.sol";
import {AegisErrors} from "../libraries/AegisErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CamelotRouter
/// @notice Wraps Camelot DEX Router behind IDexRouter.
///         routeData: unused.
contract CamelotRouter is IDexRouter {
    using SafeERC20 for IERC20;

    ICamelotRouter public immutable ROUTER;
    address public immutable REFERRER;

    constructor(
        address router,
        address referrer
    ) {
        if (router == address(0)) revert AegisErrors.ZeroAddress();
        ROUTER = ICamelotRouter(router);
        REFERRER = referrer;
    }

    /// @inheritdoc IDexRouter
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata
    ) external override returns (uint256 amountOut) {
        if (amountIn == 0) revert AegisErrors.ZeroAmount();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(ROUTER), amountIn);

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        uint256[] memory amounts =
            ROUTER.swapExactTokensForTokens(amountIn, minAmountOut, path, msg.sender, REFERRER, block.timestamp);
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
