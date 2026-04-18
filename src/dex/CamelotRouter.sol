// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IDexRouter} from "../interfaces/IDexRouter.sol";
import {ICamelotRouter} from "../interfaces/external/ICamelotRouter.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CamelotRouter
/// @notice Wraps Camelot DEX Router behind IDexRouter.
/// @dev routeData encoding:
///      - empty → deadline defaults to block.timestamp.
///      - `abi.encode(uint256 deadline)` (32 bytes) → D9: caller-supplied deadline.
///      D10: swap is `nonReentrant` as defense-in-depth on top of SepehrCore's guard.
contract CamelotRouter is IDexRouter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ICamelotRouter public immutable ROUTER;
    address public immutable REFERRER;

    constructor(
        address router,
        address referrer
    ) {
        if (router == address(0)) revert SepehrErrors.ZeroAddress();
        ROUTER = ICamelotRouter(router);
        REFERRER = referrer;
    }

    /// @inheritdoc IDexRouter
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata routeData
    ) external override nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert SepehrErrors.ZeroAmount();
        // D12: Camelot would bubble up a generic `INSUFFICIENT_INPUT_AMOUNT` / pair-missing
        // revert on a self-swap; short-circuit with a typed error here.
        if (tokenIn == tokenOut) revert SepehrErrors.SameToken();

        uint256 deadline = _decodeDeadline(routeData);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(ROUTER), amountIn);

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        uint256[] memory amounts =
            ROUTER.swapExactTokensForTokens(amountIn, minAmountOut, path, msg.sender, REFERRER, deadline);
        amountOut = amounts[amounts.length - 1];

        // D5: zero the external-router allowance and sweep any residual `tokenIn`.
        IERC20(tokenIn).forceApprove(address(ROUTER), 0);
        uint256 dust = IERC20(tokenIn).balanceOf(address(this));
        if (dust > 0) IERC20(tokenIn).safeTransfer(msg.sender, dust);
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

    function _decodeDeadline(
        bytes calldata routeData
    ) internal view returns (uint256) {
        if (routeData.length == 0) return block.timestamp;
        if (routeData.length != 32) revert SepehrErrors.InvalidRouteData();
        return abi.decode(routeData, (uint256));
    }
}
