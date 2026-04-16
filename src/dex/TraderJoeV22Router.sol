// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IDexRouter} from "../interfaces/IDexRouter.sol";
import {ILBFactory, ILBPair, ILBRouter} from "../interfaces/external/ILBRouter.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title TraderJoeV22Router
/// @notice Wraps Trader Joe V2.2 LB Router behind IDexRouter.
///         routeData: abi.encode(uint256 binStep) to override the default bin step.
contract TraderJoeV22Router is IDexRouter {
    using SafeERC20 for IERC20;

    ILBRouter public immutable ROUTER;
    ILBFactory public immutable LB_FACTORY;
    uint256 public immutable DEFAULT_BIN_STEP;

    constructor(
        address router,
        address factory,
        uint256 defaultBinStep
    ) {
        if (router == address(0) || factory == address(0)) revert SepehrErrors.ZeroAddress();
        ROUTER = ILBRouter(router);
        LB_FACTORY = ILBFactory(factory);
        DEFAULT_BIN_STEP = defaultBinStep;
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

        uint256 binStep = routeData.length > 0 ? abi.decode(routeData, (uint256)) : DEFAULT_BIN_STEP;

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(ROUTER), amountIn);

        uint256[] memory pairBinSteps = new uint256[](1);
        pairBinSteps[0] = binStep;

        ILBRouter.Version[] memory versions = new ILBRouter.Version[](1);
        versions[0] = ILBRouter.Version.V2_2;

        address[] memory tokenPath = new address[](2);
        tokenPath[0] = tokenIn;
        tokenPath[1] = tokenOut;

        ILBRouter.Path memory path =
            ILBRouter.Path({pairBinSteps: pairBinSteps, versions: versions, tokenPath: tokenPath});

        amountOut = ROUTER.swapExactTokensForTokens(amountIn, minAmountOut, path, msg.sender, block.timestamp);
    }

    /// @inheritdoc IDexRouter
    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view override returns (uint256) {
        ILBFactory.LBPairInformation memory info = LB_FACTORY.getLBPairInformation(tokenIn, tokenOut, DEFAULT_BIN_STEP);
        if (info.LBPair == address(0)) return 0;

        bool swapForY = tokenIn != ILBPair(info.LBPair).getTokenY();
        (, uint128 amountOut,) = ILBPair(info.LBPair).getSwapOut(uint128(amountIn), swapForY);
        return uint256(amountOut);
    }
}
