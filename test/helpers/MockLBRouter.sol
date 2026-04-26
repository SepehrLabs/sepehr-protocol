// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock Trader Joe V2.2 LB Router for unit tests.
contract MockLBRouter {
    uint256 public exchangeRate = 1e18;

    function setExchangeRate(
        uint256 rate
    ) external {
        exchangeRate = rate;
    }

    enum Version {
        V1,
        V2,
        V2_1,
        V2_2
    }

    struct Path {
        uint256[] pairBinSteps;
        Version[] versions;
        address[] tokenPath;
    }

    Version public lastVersion;
    uint256 public lastBinStep;
    uint256 public lastDeadline;

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Path memory path,
        address to,
        uint256 deadline
    ) external returns (uint256 amountOut) {
        IERC20(path.tokenPath[0]).transferFrom(msg.sender, address(this), amountIn);
        amountOut = (amountIn * exchangeRate) / 1e18;
        require(amountOut >= amountOutMin, "MockLB: slippage");
        IERC20(path.tokenPath[path.tokenPath.length - 1]).transfer(to, amountOut);

        lastVersion = path.versions[0];
        lastBinStep = path.pairBinSteps[0];
        lastDeadline = deadline;
    }
}

/// @notice Mock LB Factory for unit tests.
contract MockLBFactory {
    struct LBPairInformation {
        uint16 binStep;
        address LBPair;
        bool createdByOwner;
        bool ignoredForRouting;
    }

    mapping(bytes32 => LBPairInformation) private _pairs;

    function setPair(
        address tokenX,
        address tokenY,
        uint256 binStep,
        address pair
    ) external {
        bytes32 key = keccak256(abi.encode(tokenX, tokenY, binStep));
        _pairs[key] = LBPairInformation(uint16(binStep), pair, false, false);
        bytes32 reverseKey = keccak256(abi.encode(tokenY, tokenX, binStep));
        _pairs[reverseKey] = LBPairInformation(uint16(binStep), pair, false, false);
    }

    function getLBPairInformation(
        address tokenX,
        address tokenY,
        uint256 binStep
    ) external view returns (LBPairInformation memory) {
        bytes32 key = keccak256(abi.encode(tokenX, tokenY, binStep));
        return _pairs[key];
    }
}

/// @notice Mock LB Pair for unit tests.
contract MockLBPair {
    address public tokenY;
    uint128 public mockAmountOut;

    constructor(
        address _tokenY,
        uint128 _amountOut
    ) {
        tokenY = _tokenY;
        mockAmountOut = _amountOut;
    }

    function getTokenY() external view returns (address) {
        return tokenY;
    }

    function getSwapOut(
        uint128,
        bool
    ) external view returns (uint128 amountInLeft, uint128 amountOut, uint128 fee) {
        return (0, mockAmountOut, 0);
    }

    function setMockAmountOut(
        uint128 _amountOut
    ) external {
        mockAmountOut = _amountOut;
    }
}
