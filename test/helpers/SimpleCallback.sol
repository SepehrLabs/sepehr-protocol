// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISepehrCallback} from "../../src/interfaces/ISepehrCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal ISepehrCallback for testing flash loan providers.
///         Repays principal + fee back to the caller (the flash loan provider).
contract SimpleCallback is ISepehrCallback {
    bool public shouldRepay = true;
    address public lastAsset;
    uint256 public lastAmount;
    uint256 public lastFee;
    bytes public lastData;

    function setShouldRepay(
        bool _repay
    ) external {
        shouldRepay = _repay;
    }

    function onFlashLoan(
        address asset,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override {
        lastAsset = asset;
        lastAmount = amount;
        lastFee = fee;
        lastData = data;

        if (shouldRepay) {
            IERC20(asset).transfer(msg.sender, amount + fee);
        }
    }
}
