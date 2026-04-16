// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFlashLoanRecipient {
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external;
}

/// @notice Simulates Balancer V2 Vault flash loan behavior for unit tests.
contract MockBalancerVault {
    address public feesCollector;

    constructor(
        address _feesCollector
    ) {
        feesCollector = _feesCollector;
    }

    function getProtocolFeesCollector() external view returns (address) {
        return feesCollector;
    }

    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external {
        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20(tokens[i]).transfer(recipient, amounts[i]);
        }

        uint256[] memory feeAmounts = new uint256[](tokens.length);

        IFlashLoanRecipient(recipient).receiveFlashLoan(tokens, amounts, feeAmounts, userData);

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = IERC20(tokens[i]).balanceOf(address(this));
            require(balance >= amounts[i], "MockBalancerVault: not repaid");
        }
    }
}

/// @notice Mock ProtocolFeesCollector returning 0 fee by default.
contract MockBalancerFeesCollector {
    uint256 public flashLoanFeePercentage;

    function setFlashLoanFeePercentage(
        uint256 _fee
    ) external {
        flashLoanFeePercentage = _fee;
    }

    function getFlashLoanFeePercentage() external view returns (uint256) {
        return flashLoanFeePercentage;
    }
}
