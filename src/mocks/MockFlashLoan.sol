// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAegisCallback} from "../interfaces/IAegisCallback.sol";
import {IFlashLoanProvider} from "../interfaces/IFlashLoanProvider.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockFlashLoan is IFlashLoanProvider {
    uint256 public feeBps = 9; // 0.09%
    bool public shouldRevert;

    function setFeeBps(
        uint256 _feeBps
    ) external {
        feeBps = _feeBps;
    }

    function setShouldRevert(
        bool _revert
    ) external {
        shouldRevert = _revert;
    }

    function flashBorrow(
        address asset,
        uint256 amount,
        address callback,
        bytes calldata data
    ) external override {
        if (shouldRevert) revert("MockFlashLoan: unavailable");

        IERC20(asset).transfer(callback, amount);

        uint256 fee = (amount * feeBps) / 10_000;
        IAegisCallback(callback).onFlashLoan(asset, amount, fee, data);

        uint256 repayment = amount + fee;
        uint256 balance = IERC20(asset).balanceOf(address(this));
        require(balance >= repayment, "MockFlashLoan: not repaid");
    }

    function getFlashLoanFeeBps(
        address
    ) external view override returns (uint256) {
        return feeBps;
    }

    function isAvailable(
        address asset,
        uint256 amount
    ) external view override returns (bool) {
        if (shouldRevert) return false;
        return IERC20(asset).balanceOf(address(this)) >= amount;
    }
}
