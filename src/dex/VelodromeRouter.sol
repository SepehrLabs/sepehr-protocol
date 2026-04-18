// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IDexRouter} from "../interfaces/IDexRouter.sol";
import {IVelodromeRouter} from "../interfaces/external/IVelodromeRouter.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title VelodromeRouter
/// @notice Wraps Velodrome V2 Router behind IDexRouter.
///         routeData: abi.encode(bool stable) to override the default pool type.
contract VelodromeRouter is IDexRouter {
    using SafeERC20 for IERC20;

    IVelodromeRouter public immutable ROUTER;
    address public immutable POOL_FACTORY;
    bool public immutable DEFAULT_STABLE;

    constructor(
        address router,
        address poolFactory,
        bool defaultStable
    ) {
        if (router == address(0) || poolFactory == address(0)) revert SepehrErrors.ZeroAddress();
        ROUTER = IVelodromeRouter(router);
        POOL_FACTORY = poolFactory;
        DEFAULT_STABLE = defaultStable;
    }

    /// @inheritdoc IDexRouter
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata routeData
    ) external override returns (uint256 amountOut) {
        if (amountIn == 0) revert SepehrErrors.ZeroAmount();

        bool stable = routeData.length > 0 ? abi.decode(routeData, (bool)) : DEFAULT_STABLE;

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(ROUTER), amountIn);

        IVelodromeRouter.Route[] memory routes = new IVelodromeRouter.Route[](1);
        routes[0] = IVelodromeRouter.Route({from: tokenIn, to: tokenOut, stable: stable, factory: POOL_FACTORY});

        uint256[] memory amounts =
            ROUTER.swapExactTokensForTokens(amountIn, minAmountOut, routes, msg.sender, block.timestamp);
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
        IVelodromeRouter.Route[] memory routes = new IVelodromeRouter.Route[](1);
        routes[0] = IVelodromeRouter.Route({from: tokenIn, to: tokenOut, stable: DEFAULT_STABLE, factory: POOL_FACTORY});

        uint256[] memory amounts = ROUTER.getAmountsOut(amountIn, routes);
        return amounts[amounts.length - 1];
    }
}
