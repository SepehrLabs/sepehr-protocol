// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFlashLoanProvider} from "../interfaces/IFlashLoanProvider.sol";
import {ISepehrCallback} from "../interfaces/ISepehrCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockFlashLoan is IFlashLoanProvider {
    uint256 public feeBps = 9; // 0.09%
    bool public shouldRevert;
    /// @notice When true, `flashBorrow` reverts but `isAvailable` still returns true — simulates
    /// a provider that advertises availability yet fails the actual call (wrong-asset approval,
    /// transient balance glitch, callback-hash mismatch, …). Used by A17 tests to drive the
    /// `catch (bytes memory reason)` path in `SepehrCore._borrowFlashLoan`.
    bool public revertOnFlashBorrow;
    bytes public revertReason;

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

    function setRevertOnFlashBorrow(
        bool _revert,
        bytes calldata reason
    ) external {
        revertOnFlashBorrow = _revert;
        revertReason = reason;
    }

    function flashBorrow(
        address asset,
        uint256 amount,
        address callback,
        bytes calldata data
    ) external override {
        if (shouldRevert) revert("MockFlashLoan: unavailable");
        if (revertOnFlashBorrow) {
            bytes memory reason = revertReason;
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }

        IERC20(asset).transfer(callback, amount);

        uint256 fee = (amount * feeBps) / 10_000;
        ISepehrCallback(callback).onFlashLoan(asset, amount, fee, data);

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
