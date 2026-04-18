// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock Velodrome V2 Router for unit tests.
contract MockVeloRouter {
    uint256 public exchangeRate = 1e18;

    function setExchangeRate(
        uint256 rate
    ) external {
        exchangeRate = rate;
    }

    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    address public lastFactory;
    bool public lastStable;
    uint256 public lastDeadline;

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        IERC20(routes[0].from).transferFrom(msg.sender, address(this), amountIn);
        uint256 amountOut = (amountIn * exchangeRate) / 1e18;
        require(amountOut >= amountOutMin, "MockVelo: slippage");
        IERC20(routes[routes.length - 1].to).transfer(to, amountOut);

        lastFactory = routes[0].factory;
        lastStable = routes[0].stable;
        lastDeadline = deadline;

        amounts = new uint256[](routes.length + 1);
        amounts[0] = amountIn;
        amounts[routes.length] = amountOut;
    }

    function getAmountsOut(
        uint256 amountIn,
        Route[] calldata routes
    ) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](routes.length + 1);
        amounts[0] = amountIn;
        amounts[routes.length] = (amountIn * exchangeRate) / 1e18;
    }
}
