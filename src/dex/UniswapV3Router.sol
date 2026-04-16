// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IDexRouter} from "../interfaces/IDexRouter.sol";
import {ISwapRouter} from "../interfaces/external/ISwapRouter.sol";
import {IUniswapV3Factory} from "../interfaces/external/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "../interfaces/external/IUniswapV3Pool.sol";
import {AegisErrors} from "../libraries/AegisErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title UniswapV3Router
/// @notice Wraps Uniswap V3 SwapRouter behind the IDexRouter interface.
///         routeData: abi.encode(uint24 fee) to override the default pool fee.
contract UniswapV3Router is IDexRouter {
    using SafeERC20 for IERC20;

    ISwapRouter public immutable SWAP_ROUTER;
    IUniswapV3Factory public immutable FACTORY;
    uint24 public immutable DEFAULT_FEE;

    constructor(
        address swapRouter,
        address factory,
        uint24 defaultFee
    ) {
        if (swapRouter == address(0) || factory == address(0)) revert AegisErrors.ZeroAddress();
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
    ) external override returns (uint256 amountOut) {
        if (amountIn == 0) revert AegisErrors.ZeroAmount();

        uint24 fee = routeData.length > 0 ? abi.decode(routeData, (uint24)) : DEFAULT_FEE;

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(SWAP_ROUTER), amountIn);

        amountOut = SWAP_ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: msg.sender,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            })
        );
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
