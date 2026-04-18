// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal fee-on-transfer ERC20 used to drive the B19 balance-delta guard in
///         CompoundV2-family adapters. A flat `feeBps`-of-amount is burned on every transfer;
///         the recipient receives `amount - fee`. `mint` is fee-free so tests can pre-seed
///         exact balances.
contract MockFeeOnTransferERC20 is ERC20 {
    uint256 public feeBps;

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 feeBps_
    ) ERC20(name_, symbol_) {
        feeBps = feeBps_;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function setFeeBps(
        uint256 feeBps_
    ) external {
        feeBps = feeBps_;
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = value * feeBps / 10_000;
        if (fee > 0) {
            super._update(from, address(0), fee);
        }
        super._update(from, to, value - fee);
    }
}
