// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockAdapter is IProtocolAdapter {
    mapping(address => uint256) public healthFactors;
    mapping(address => bool) public delegations;
    mapping(address => uint256) public collateralValues;

    uint256 public repayCallCount;
    uint256 public withdrawCallCount;

    function setHealthFactor(
        address user,
        uint256 hf
    ) external {
        healthFactors[user] = hf;
    }

    function setDelegation(
        address user,
        bool delegated
    ) external {
        delegations[user] = delegated;
    }

    function setCollateralValueUsd(
        address user,
        uint256 value
    ) external {
        collateralValues[user] = value;
    }

    function getHealthFactor(
        address user
    ) external view override returns (uint256) {
        return healthFactors[user];
    }

    function checkDelegation(
        address user
    ) external view override returns (bool) {
        return delegations[user];
    }

    function repay(
        address,
        address debtAsset,
        uint256 amount
    ) external override {
        IERC20(debtAsset).transfer(address(0xdead), amount);
        repayCallCount++;
    }

    function withdrawCollateral(
        address,
        address collateralAsset,
        uint256 amount,
        address recipient
    ) external override {
        IERC20(collateralAsset).transfer(recipient, amount);
        withdrawCallCount++;
    }

    function getCollateralValueUsd(
        address user
    ) external view override returns (uint256) {
        return collateralValues[user];
    }
}
