// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFlashLoanProvider} from "../../src/interfaces/IFlashLoanProvider.sol";
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

    // Reentrancy-test scaffolding for C2 coverage.
    bool public reentrantTrigger;
    address public reentrantProvider;
    address public reentrantAsset;
    uint256 public reentrantAmount;

    function setShouldRepay(
        bool _repay
    ) external {
        shouldRepay = _repay;
    }

    function setReentrantTrigger(
        bool v
    ) external {
        reentrantTrigger = v;
    }

    function setReentrantProvider(
        address p
    ) external {
        reentrantProvider = p;
    }

    function setReentrantAsset(
        address a
    ) external {
        reentrantAsset = a;
    }

    function setReentrantAmount(
        uint256 a
    ) external {
        reentrantAmount = a;
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

        if (reentrantTrigger) {
            // Attempt a second flashBorrow on the same provider while we're still
            // inside the first — the C2 guard must revert this with ConcurrentFlashLoan.
            IFlashLoanProvider(reentrantProvider).flashBorrow(reentrantAsset, reentrantAmount, address(this), "");
        }

        if (shouldRepay) {
            IERC20(asset).transfer(msg.sender, amount + fee);
        }
    }
}
