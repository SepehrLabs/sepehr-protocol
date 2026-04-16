// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISubscriptionOracle} from "../interfaces/ISubscriptionOracle.sol";

contract MockOracle is ISubscriptionOracle {
    mapping(address => uint256) public prices;

    function setPrice(
        address asset,
        uint256 priceUsd8
    ) external {
        prices[asset] = priceUsd8;
    }

    function getAssetPriceUsd(
        address asset
    ) external view override returns (uint256) {
        return prices[asset];
    }
}
