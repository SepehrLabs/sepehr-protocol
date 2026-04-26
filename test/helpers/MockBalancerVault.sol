// SPDX-License-Identifier: MIT
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

/// @notice Simulates a Vault that (after an upgrade) pushes 2-token flash loans.
/// @dev Used to exercise BalancerFlashLoanProvider's C5 bound (tokens.length == 1).
contract MaliciousBalancerVault {
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
        address[] memory, /*tokens*/
        uint256[] memory, /*amounts*/
        bytes memory userData
    ) external {
        address[] memory twoTokens = new address[](2);
        twoTokens[0] = address(1);
        twoTokens[1] = address(2);
        uint256[] memory twoAmounts = new uint256[](2);
        uint256[] memory twoFees = new uint256[](2);

        IFlashLoanRecipient(recipient).receiveFlashLoan(twoTokens, twoAmounts, twoFees, userData);
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
