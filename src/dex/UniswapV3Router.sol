// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IDexRouter} from "../interfaces/IDexRouter.sol";
import {ISwapRouter} from "../interfaces/external/ISwapRouter.sol";
import {IUniswapV3Factory} from "../interfaces/external/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "../interfaces/external/IUniswapV3Pool.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title UniswapV3Router
/// @notice Wraps Uniswap V3 SwapRouter behind the IDexRouter interface.
/// @dev routeData encoding (all accepted):
///      - empty → DEFAULT_FEE, no sqrtPrice bound, deadline = block.timestamp
///      - 32 bytes (uint24 fee) → custom fee, no sqrtPrice bound, deadline = block.timestamp
///      - 64 bytes (uint24 fee, uint160 sqrtPriceLimitX96) → D3: bound pool-side price
///        movement; deadline = block.timestamp
///      - 96 bytes (uint256 deadline, uint24 fee, uint160 sqrtPriceLimitX96) → D9:
///        caller-supplied deadline. When wired through SepehrCore's canonical-route
///        registry this becomes the only reachable code path (the keeper loses its
///        ability to disable pool-side price protection with a 0).
///      D10: swap is `nonReentrant` as defense-in-depth on top of SepehrCore's guard.
contract UniswapV3Router is IDexRouter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ISwapRouter public immutable SWAP_ROUTER;
    IUniswapV3Factory public immutable FACTORY;
    uint24 public immutable DEFAULT_FEE;

    constructor(
        address swapRouter,
        address factory,
        uint24 defaultFee
    ) {
        if (swapRouter == address(0) || factory == address(0)) revert SepehrErrors.ZeroAddress();
        SWAP_ROUTER = ISwapRouter(swapRouter);
        FACTORY = IUniswapV3Factory(factory);
        DEFAULT_FEE = defaultFee;
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

        uint24 fee = DEFAULT_FEE;
        uint160 sqrtPriceLimitX96 = 0;
        uint256 deadline = block.timestamp;
        if (routeData.length == 32) {
            fee = abi.decode(routeData, (uint24));
        } else if (routeData.length == 64) {
            (fee, sqrtPriceLimitX96) = abi.decode(routeData, (uint24, uint160));
        } else if (routeData.length == 96) {
            (deadline, fee, sqrtPriceLimitX96) = abi.decode(routeData, (uint256, uint24, uint160));
        } else if (routeData.length != 0) {
            revert SepehrErrors.InvalidRouteData();
        }

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(SWAP_ROUTER), amountIn);

        amountOut = SWAP_ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: msg.sender,
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            })
        );

        // D5: zero the external-router allowance and sweep any residual `tokenIn` back to
        // the caller. Required because (a) a buggy/malicious SwapRouter could leave a
        // non-zero allowance in place, letting it pull more on a future call, and (b)
        // fee-on-transfer or rebase tokens can leave dust here when the external router
        // pulls less than `amountIn`.
        IERC20(tokenIn).forceApprove(address(SWAP_ROUTER), 0);
        uint256 dust = IERC20(tokenIn).balanceOf(address(this));
        if (dust > 0) IERC20(tokenIn).safeTransfer(msg.sender, dust);
    }

    /// @inheritdoc IDexRouter
    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view override returns (uint256) {
        address pool = FACTORY.getPool(tokenIn, tokenOut, DEFAULT_FEE);
        if (pool == address(0)) return 0;

        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        if (sqrtPriceX96 == 0) return 0;

        bool zeroForOne = tokenIn < tokenOut;
        uint256 amountOut;

        if (zeroForOne) {
            amountOut = Math.mulDiv(amountIn, uint256(sqrtPriceX96), 1 << 96);
            amountOut = Math.mulDiv(amountOut, uint256(sqrtPriceX96), 1 << 96);
        } else {
            amountOut = Math.mulDiv(amountIn, 1 << 96, uint256(sqrtPriceX96));
            amountOut = Math.mulDiv(amountOut, 1 << 96, uint256(sqrtPriceX96));
        }

        return amountOut * (1_000_000 - DEFAULT_FEE) / 1_000_000;
    }
}
