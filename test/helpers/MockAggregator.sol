// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDexRouter} from "../../src/interfaces/IDexRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice A swap aggregator as AggregatorRouter sees one: `sell` pulls `pullAmount` of
/// `tokenIn` through `spender` (itself, or an allowance holder) and sends `outAmount` of
/// `tokenOut` to `recipient`. `reenter` makes it call the router back during the sale.
contract MockAggregator {
    MockAllowanceHolder public immutable holder;
    bool public reenter;

    constructor() {
        holder = new MockAllowanceHolder();
    }

    function setReenter(
        bool value
    ) external {
        reenter = value;
    }

    function sell(
        address tokenIn,
        address tokenOut,
        uint256 pullAmount,
        uint256 outAmount,
        address recipient,
        bool viaHolder
    ) external {
        if (reenter) IDexRouter(msg.sender).swap(tokenIn, tokenOut, 1, 0, msg.data);
        if (viaHolder) holder.pull(tokenIn, msg.sender, pullAmount);
        else IERC20(tokenIn).transferFrom(msg.sender, address(this), pullAmount);
        IERC20(tokenOut).transfer(recipient, outAmount);
    }

    function fail() external pure {
        revert("MockAggregator: no route");
    }
}

/// @notice The allowance holder pattern (0x): the seller approves it, not the aggregator.
contract MockAllowanceHolder {
    function pull(
        address token,
        address from,
        uint256 amount
    ) external {
        IERC20(token).transferFrom(from, msg.sender, amount);
    }
}
