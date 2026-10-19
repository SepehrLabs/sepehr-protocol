// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IChainlinkAggregator} from "../interfaces/external/IChainlinkAggregator.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";

/// @title ChainlinkProductFeed
/// @notice One price that Chainlink only publishes in two legs, read like a Chainlink feed:
///         `BASE × QUOTE`. On Arbitrum, wstETH/USD is WSTETH/ETH (market price) × ETH/USD.
/// @dev The market leg, not the wstETH/stETH exchange rate: SepehrCore turns this price into
///      the floor its swaps must clear, and a floor held at the exchange rate during a depeg
///      would block the very rescues the depeg calls for. The result reports the older leg's
///      date, so SepehrCore's staleness bound covers both legs, and an answer of 0 when a leg is
///      not positive, which SepehrCore refuses (`InvalidOraclePrice`).
contract ChainlinkProductFeed is IChainlinkAggregator {
    /// @notice First leg, e.g. WSTETH/ETH.
    IChainlinkAggregator public immutable BASE;
    /// @notice Second leg, e.g. ETH/USD.
    IChainlinkAggregator public immutable QUOTE;
    /// @notice Decimals of the product.
    uint8 public immutable override decimals;
    /// @notice What the product prices, e.g. "wstETH / USD".
    string public description;

    /// @dev 10 ** (BASE decimals + QUOTE decimals - decimals) or its inverse, whichever is whole.
    uint256 private immutable _divisor;
    uint256 private immutable _multiplier;

    /// @param base First leg.
    /// @param quote Second leg.
    /// @param decimals_ Decimals of the product (8 for a USD price).
    /// @param description_ What the product prices.
    constructor(
        address base,
        address quote,
        uint8 decimals_,
        string memory description_
    ) {
        if (base == address(0) || quote == address(0)) revert SepehrErrors.ZeroAddress();
        BASE = IChainlinkAggregator(base);
        QUOTE = IChainlinkAggregator(quote);
        decimals = decimals_;
        description = description_;
        uint256 legs = uint256(BASE.decimals()) + QUOTE.decimals();
        if (legs >= decimals_) {
            _divisor = 10 ** (legs - decimals_);
            _multiplier = 1;
        } else {
            _divisor = 1;
            _multiplier = 10 ** (decimals_ - legs);
        }
    }

    /// @notice The product of both legs' latest answers, dated by the older leg.
    /// @return roundId QUOTE's round.
    /// @return answer `BASE × QUOTE` in `decimals`, 0 when a leg is not positive.
    /// @return startedAt Same as `updatedAt`.
    /// @return updatedAt The older leg's update time.
    /// @return answeredInRound QUOTE's round.
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (, int256 base,, uint256 baseUpdatedAt,) = BASE.latestRoundData();
        (uint80 quoteRound, int256 quote,, uint256 quoteUpdatedAt,) = QUOTE.latestRoundData();
        updatedAt = baseUpdatedAt < quoteUpdatedAt ? baseUpdatedAt : quoteUpdatedAt;
        if (base > 0 && quote > 0) {
            answer = int256(uint256(base) * uint256(quote) * _multiplier / _divisor);
        }
        return (quoteRound, answer, updatedAt, updatedAt, quoteRound);
    }
}
