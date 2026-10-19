// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IDexRouter} from "../interfaces/IDexRouter.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AggregatorRouter
/// @notice Lot 7: sells through one swap aggregator (KyberSwap, Velora…) behind the IDexRouter
///         interface. `routeData` is the aggregator's own calldata, built off-chain by the keeper
///         from the aggregator's API with this router as sender and recipient.
/// @dev One router per aggregator, fixed at deployment: the contract it calls (`TARGET`), the
///      one it approves (`SPENDER`) and the functions of `TARGET` it may call. Nothing can be
///      changed afterwards; the closed list of aggregators is SepehrCore's router whitelist,
///      under the timelock. What the router hands back is measured, never trusted: the output
///      it received must reach `minAmountOut` (SepehrCore's oracle floor), and the input the
///      aggregator did not take goes back to the caller with the output. The router holds no
///      token between calls and accepts no native ETH.
contract AggregatorRouter is IDexRouter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The aggregator contract the calldata is sent to.
    address public immutable TARGET;
    /// @notice The contract that pulls `tokenIn` (the aggregator itself, or its allowance holder).
    address public immutable SPENDER;
    /// @notice Functions of `TARGET` the calldata may call: its exact-input swaps.
    mapping(bytes4 selector => bool) public allowedSelectors;

    /// @param target The aggregator contract.
    /// @param spender The contract `target` uses to pull the input.
    /// @param selectors The exact-input swap functions of `target`.
    constructor(
        address target,
        address spender,
        bytes4[] memory selectors
    ) {
        if (target == address(0) || spender == address(0)) revert SepehrErrors.ZeroAddress();
        if (selectors.length == 0) revert SepehrErrors.InvalidRouteData();
        TARGET = target;
        SPENDER = spender;
        for (uint256 i = 0; i < selectors.length; i++) {
            allowedSelectors[selectors[i]] = true;
        }
    }

    /// @inheritdoc IDexRouter
    /// @dev `routeData` is sent to `TARGET` as is, after its selector is checked. The calldata may
    ///      sell less than `amountIn` (the keeper quotes a little under the amount SepehrCore will
    ///      sell): what is left goes back to the caller.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata routeData
    ) external override nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert SepehrErrors.ZeroAmount();
        if (tokenIn == tokenOut) revert SepehrErrors.SameToken();
        if (routeData.length < 4) revert SepehrErrors.InvalidRouteData();
        bytes4 selector = bytes4(routeData[:4]);
        if (!allowedSelectors[selector]) revert SepehrErrors.SelectorNotAllowed(selector);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenIn).forceApprove(SPENDER, amountIn);
        Address.functionCall(TARGET, routeData);
        IERC20(tokenIn).forceApprove(SPENDER, 0);

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        if (amountOut < minAmountOut) revert SepehrErrors.SlippageExceeded(amountOut, minAmountOut);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        uint256 unsold = IERC20(tokenIn).balanceOf(address(this));
        if (unsold > 0) IERC20(tokenIn).safeTransfer(msg.sender, unsold);
    }

    /// @inheritdoc IDexRouter
    /// @dev An aggregator quotes through its API only: always 0. SepehrCore never reads it.
    function getQuote(
        address,
        address,
        uint256
    ) external pure override returns (uint256) {
        return 0;
    }
}
