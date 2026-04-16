// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFlashLoanSimpleReceiver {
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}

/// @notice Simulates Aave V3 Pool flash loan behavior for unit tests.
contract MockAavePool {
    uint128 public premiumTotal = 5;

    function setPremiumTotal(
        uint128 _premium
    ) external {
        premiumTotal = _premium;
    }

    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128) {
        return premiumTotal;
    }

    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16
    ) external {
        IERC20(asset).transfer(receiverAddress, amount);

        uint256 premium = (amount * premiumTotal) / 10_000;

        bool success =
            IFlashLoanSimpleReceiver(receiverAddress).executeOperation(asset, amount, premium, msg.sender, params);
        require(success, "MockAavePool: executeOperation failed");

        IERC20(asset).transferFrom(receiverAddress, address(this), amount + premium);
    }
}
