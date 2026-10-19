// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SepehrErrors} from "../../../src/libraries/SepehrErrors.sol";
import {ChainlinkProductFeed} from "../../../src/oracles/ChainlinkProductFeed.sol";
import {MockChainlinkAggregator} from "../../helpers/MockChainlinkAggregator.sol";
import {Test} from "forge-std/Test.sol";

contract ChainlinkProductFeedTest is Test {
    MockChainlinkAggregator internal wstEthEth;
    MockChainlinkAggregator internal ethUsd;
    ChainlinkProductFeed internal feed;

    function setUp() public {
        vm.warp(1_800_000_000);
        wstEthEth = new MockChainlinkAggregator(18, 1.2e18);
        ethUsd = new MockChainlinkAggregator(8, 2500e8);
        feed = new ChainlinkProductFeed(address(wstEthEth), address(ethUsd), 8, "wstETH / USD");
    }

    function test_constructor_storesItsLegs() public view {
        assertEq(address(feed.BASE()), address(wstEthEth));
        assertEq(address(feed.QUOTE()), address(ethUsd));
        assertEq(feed.decimals(), 8);
        assertEq(feed.description(), "wstETH / USD");
    }

    function test_constructor_revertsOnZeroLeg() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new ChainlinkProductFeed(address(0), address(ethUsd), 8, "x");
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new ChainlinkProductFeed(address(wstEthEth), address(0), 8, "x");
    }

    function test_latestRoundData_multipliesTheLegs() public view {
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, 3000e8);
    }

    function test_latestRoundData_scalesUpWhenTheLegsHaveFewerDecimals() public {
        MockChainlinkAggregator a = new MockChainlinkAggregator(2, 150); // 1.50
        MockChainlinkAggregator b = new MockChainlinkAggregator(2, 200); // 2.00
        ChainlinkProductFeed product = new ChainlinkProductFeed(address(a), address(b), 8, "x");
        (, int256 answer,,,) = product.latestRoundData();
        assertEq(answer, 3e8);
    }

    function test_latestRoundData_isDatedByTheOlderLeg() public {
        wstEthEth.setUpdatedAt(1_799_990_000);
        ethUsd.setUpdatedAt(1_799_999_000);
        (,, uint256 startedAt, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, 1_799_990_000);
        assertEq(startedAt, updatedAt);

        wstEthEth.setUpdatedAt(1_799_999_500);
        (,,, updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, 1_799_999_000);
    }

    function test_latestRoundData_answersZeroWhenALegIsNotPositive() public {
        ethUsd.setAnswer(0);
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, 0);

        ethUsd.setAnswer(2500e8);
        wstEthEth.setAnswer(-1);
        (, answer,,,) = feed.latestRoundData();
        assertEq(answer, 0);
    }

    function test_latestRoundData_reportsTheQuoteRound() public {
        ethUsd.setAnswer(2600e8); // round 2
        (uint80 roundId,,,, uint80 answeredInRound) = feed.latestRoundData();
        assertEq(roundId, 2);
        assertEq(answeredInRound, 2);
    }

    function testFuzz_latestRoundData_matchesTheProduct(
        uint64 ratio,
        uint64 price
    ) public {
        vm.assume(ratio > 0 && price > 0);
        wstEthEth.setAnswer(int256(uint256(ratio)));
        ethUsd.setAnswer(int256(uint256(price)));
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(uint256(answer), uint256(ratio) * uint256(price) / 1e18);
    }
}
