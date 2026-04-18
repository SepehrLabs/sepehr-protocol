// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IDexRouter} from "../interfaces/IDexRouter.sol";
import {IVelodromeRouter} from "../interfaces/external/IVelodromeRouter.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title VelodromeRouter
/// @notice Wraps Velodrome V2 Router behind IDexRouter.
/// @dev routeData encoding:
///      - empty → DEFAULT_POOL_FACTORY, DEFAULT_STABLE, deadline = block.timestamp
///      - 32 bytes (bool stable) → override pool type; factory = DEFAULT_POOL_FACTORY
///      - 96 bytes (uint256 deadline, bool stable, address factory) → D7 + D9:
///        caller-supplied deadline AND per-call factory (e.g., Aerodrome Slipstream)
///        that overrides the immutable default.
///      D10: swap is `nonReentrant` as defense-in-depth on top of SepehrCore's guard.
contract VelodromeRouter is IDexRouter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IVelodromeRouter public immutable ROUTER;
    address public immutable DEFAULT_POOL_FACTORY;
    bool public immutable DEFAULT_STABLE;

    constructor(
        address router,
        address poolFactory,
        bool defaultStable
    ) {
        if (router == address(0) || poolFactory == address(0)) revert SepehrErrors.ZeroAddress();
        ROUTER = IVelodromeRouter(router);
        DEFAULT_POOL_FACTORY = poolFactory;
        DEFAULT_STABLE = defaultStable;
    }

    /// @notice Backwards-compatible getter — original name pre-D7.
    function POOL_FACTORY() external view returns (address) {
        return DEFAULT_POOL_FACTORY;
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

        (uint256 deadline, bool stable, address factory) = _decodeRoute(routeData);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(ROUTER), amountIn);

        IVelodromeRouter.Route[] memory routes = new IVelodromeRouter.Route[](1);
        routes[0] = IVelodromeRouter.Route({from: tokenIn, to: tokenOut, stable: stable, factory: factory});

        uint256[] memory amounts = ROUTER.swapExactTokensForTokens(amountIn, minAmountOut, routes, msg.sender, deadline);
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
        routes[0] = IVelodromeRouter.Route({
            from: tokenIn, to: tokenOut, stable: DEFAULT_STABLE, factory: DEFAULT_POOL_FACTORY
        });

        uint256[] memory amounts = ROUTER.getAmountsOut(amountIn, routes);
        return amounts[amounts.length - 1];
    }

    function _decodeRoute(
        bytes calldata routeData
    ) internal view returns (uint256 deadline, bool stable, address factory) {
        if (routeData.length == 0) {
            return (block.timestamp, DEFAULT_STABLE, DEFAULT_POOL_FACTORY);
        }
        if (routeData.length == 32) {
            return (block.timestamp, abi.decode(routeData, (bool)), DEFAULT_POOL_FACTORY);
        }
        if (routeData.length == 96) {
            (deadline, stable, factory) = abi.decode(routeData, (uint256, bool, address));
            if (factory == address(0)) revert SepehrErrors.ZeroAddress();
            return (deadline, stable, factory);
        }
        revert SepehrErrors.InvalidRouteData();
    }
}
