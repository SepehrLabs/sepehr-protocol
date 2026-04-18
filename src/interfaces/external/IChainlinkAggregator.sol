// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title IChainlinkAggregator
/// @notice Minimal Chainlink AggregatorV3 interface used by SepehrCore's D2 oracle-floor
///         check. Every field we consume maps 1:1 onto the canonical Chainlink
///         AggregatorV3Interface, so the same feed addresses work unmodified.
interface IChainlinkAggregator {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
