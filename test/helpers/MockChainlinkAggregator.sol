// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IChainlinkAggregator} from "../../src/interfaces/external/IChainlinkAggregator.sol";

contract MockChainlinkAggregator is IChainlinkAggregator {
    uint8 public override decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId;

    constructor(
        uint8 _decimals,
        int256 _answer
    ) {
        decimals = _decimals;
        answer = _answer;
        updatedAt = block.timestamp;
        roundId = 1;
    }

    function setAnswer(
        int256 _answer
    ) external {
        answer = _answer;
        updatedAt = block.timestamp;
        roundId++;
    }

    function setUpdatedAt(
        uint256 _updatedAt
    ) external {
        updatedAt = _updatedAt;
    }

    function setDecimals(
        uint8 _decimals
    ) external {
        decimals = _decimals;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }

    /// @notice Chainlink V2 `AggregatorInterface.latestAnswer`. Aave V3's `AaveOracle`
    ///         reads prices via this legacy entrypoint, so the mock must expose it for
    ///         fork-mode E2E where we hijack `assetsSources` to point at this contract.
    function latestAnswer() external view returns (int256) {
        return answer;
    }
}
