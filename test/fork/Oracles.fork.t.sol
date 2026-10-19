// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ChainlinkProductFeed} from "../../src/oracles/ChainlinkProductFeed.sol";
import {ForkTestBase} from "./ForkTestBase.sol";

interface IAaveOracleFork {
    function getAssetPrice(
        address asset
    ) external view returns (uint256);
}

/// @notice wstETH/USD on Arbitrum One from Chainlink's WSTETH/ETH market feed and ETH/USD,
///         compared with the price Aave uses for the same asset.
contract ChainlinkProductFeedArbitrumForkTest is ForkTestBase {
    address constant WSTETH_ETH = 0xb523AE262D20A936BC152e6023996e46FDC2A95D;
    address constant ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address constant AAVE_ORACLE = 0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7;
    address constant WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;

    ChainlinkProductFeed internal feed;
    bool internal forked;

    function setUp() public {
        forked = _tryCreateFork("RPC_ARBITRUM_PRIMARY_HTTP");
        if (!forked) return;
        feed = new ChainlinkProductFeed(WSTETH_ETH, ETH_USD, 8, "wstETH / USD");
    }

    function test_wstEthUsd_isWithinOnePercentOfAavesPrice() public {
        if (!forked) return;

        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        uint256 aave = IAaveOracleFork(AAVE_ORACLE).getAssetPrice(WSTETH);
        assertGt(answer, 0);
        assertApproxEqRel(uint256(answer), aave, 0.01e18);
        assertGt(updatedAt, block.timestamp - 1 days, "both legs fresh");
    }
}
