// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMorphoFlashLoanCallback {
    function onMorphoFlashLoan(
        uint256 assets,
        bytes calldata data
    ) external;
}

/// @notice Morpho Blue's flash loan as the singleton runs it: send, call back, pull back the
///         same amount with `transferFrom` (no fee).
contract MockMorphoFlashLoan {
    function flashLoan(
        address token,
        uint256 assets,
        bytes calldata data
    ) external {
        IERC20(token).transfer(msg.sender, assets);
        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);
        IERC20(token).transferFrom(msg.sender, address(this), assets);
    }
}
