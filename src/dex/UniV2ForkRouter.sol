// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IDexRouter} from "../interfaces/IDexRouter.sol";
import {IUniswapV2Router} from "../interfaces/external/IUniswapV2Router.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title UniV2ForkRouter
/// @notice Wraps any Uniswap V2 fork router (SushiSwap, PancakeSwap, etc.) behind IDexRouter.
/// @dev routeData encoding:
///      - empty → deadline defaults to block.timestamp (same-block tx, no validator-delay
///        protection — acceptable inside SepehrCore's atomic execute path but the caller
///        should prefer the explicit form below).
///      - `abi.encode(uint256 deadline)` (32 bytes) → D9: caller-supplied deadline.
///        The external router reverts if the tx is mined past this deadline, bounding a
///        mempool-delay attack.
///      D10: swap is `nonReentrant` as defense-in-depth; SepehrCore's own guard is the
///      primary protection but future aggregator integrations may re-enter.
contract UniV2ForkRouter is IDexRouter, ReentrancyGuard {
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
        bytes calldata routeData
    ) external override nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert SepehrErrors.ZeroAmount();
        // D12: fail fast on self-swaps instead of letting the external router revert
        // deep in the path-resolution logic with an opaque `PAIR_NOT_EXISTS`-style error.
        if (tokenIn == tokenOut) revert SepehrErrors.SameToken();

        uint256 deadline = _decodeDeadline(routeData);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(ROUTER), amountIn);

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        uint256[] memory amounts = ROUTER.swapExactTokensForTokens(amountIn, minAmountOut, path, msg.sender, deadline);
        amountOut = amounts[amounts.length - 1];

        // D5: zero the external-router allowance and sweep any residual `tokenIn` back
        // to the caller (fee-on-transfer / rebase tokens can leave dust if the external
        // router pulled less than `amountIn`).
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
