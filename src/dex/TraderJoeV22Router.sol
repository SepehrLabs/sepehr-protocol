// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IDexRouter} from "../interfaces/IDexRouter.sol";
import {ILBFactory, ILBPair, ILBRouter} from "../interfaces/external/ILBRouter.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TraderJoeV22Router
/// @notice Wraps Trader Joe V2.2 LB Router behind IDexRouter.
/// @dev routeData encoding:
///      - empty → DEFAULT_BIN_STEP, Version.V2_2, deadline = block.timestamp
///      - 32 bytes (uint256 binStep) → override bin step; Version.V2_2
///      - 96 bytes (uint256 deadline, uint256 binStep, uint8 version) → D8 + D9:
///        caller-supplied deadline AND per-call LB version (V1 / V2 / V2_1 / V2_2)
///        so pools with deeper liquidity in older versions remain routable.
///      D10: swap is `nonReentrant` as defense-in-depth on top of SepehrCore's guard.
contract TraderJoeV22Router is IDexRouter, ReentrancyGuard {
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
    ) external override nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert SepehrErrors.ZeroAmount();
        // D12: TraderJoe's LBRouter would revert inside route resolution with an opaque
        // error on a self-swap; short-circuit with a typed signal.
        if (tokenIn == tokenOut) revert SepehrErrors.SameToken();

        (uint256 deadline, uint256 binStep, ILBRouter.Version version) = _decodeRoute(routeData);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(ROUTER), amountIn);

        uint256[] memory pairBinSteps = new uint256[](1);
        pairBinSteps[0] = binStep;

        ILBRouter.Version[] memory versions = new ILBRouter.Version[](1);
        versions[0] = version;

        address[] memory tokenPath = new address[](2);
        tokenPath[0] = tokenIn;
        tokenPath[1] = tokenOut;

        ILBRouter.Path memory path =
            ILBRouter.Path({pairBinSteps: pairBinSteps, versions: versions, tokenPath: tokenPath});

        amountOut = ROUTER.swapExactTokensForTokens(amountIn, minAmountOut, path, msg.sender, deadline);

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
        ILBFactory.LBPairInformation memory info = LB_FACTORY.getLBPairInformation(tokenIn, tokenOut, DEFAULT_BIN_STEP);
        if (info.LBPair == address(0)) return 0;

        bool swapForY = tokenIn != ILBPair(info.LBPair).getTokenY();
        (, uint128 amountOut,) = ILBPair(info.LBPair).getSwapOut(uint128(amountIn), swapForY);
        return uint256(amountOut);
    }

    function _decodeRoute(
        bytes calldata routeData
    ) internal view returns (uint256 deadline, uint256 binStep, ILBRouter.Version version) {
        if (routeData.length == 0) {
            return (block.timestamp, DEFAULT_BIN_STEP, ILBRouter.Version.V2_2);
        }
        if (routeData.length == 32) {
            return (block.timestamp, abi.decode(routeData, (uint256)), ILBRouter.Version.V2_2);
        }
        if (routeData.length == 96) {
            uint8 versionRaw;
            (deadline, binStep, versionRaw) = abi.decode(routeData, (uint256, uint256, uint8));
            if (versionRaw > uint8(ILBRouter.Version.V2_2)) revert SepehrErrors.InvalidRouteData();
            return (deadline, binStep, ILBRouter.Version(versionRaw));
        }
        revert SepehrErrors.InvalidRouteData();
    }
}
