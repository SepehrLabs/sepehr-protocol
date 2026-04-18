// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IUniswapV3FlashCallback {
    function uniswapV3FlashCallback(
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external;
}

/// @notice Simulates a Uniswap V3 Pool flash for unit tests.
contract MockUniswapV3Pool {
    address public token0;
    address public token1;
    uint24 public fee;

    constructor(
        address _token0,
        address _token1,
        uint24 _fee
    ) {
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
    }

    function flash(
        address recipient,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external {
        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        uint256 fee0 = _mulDivRoundUp(amount0, fee, 1_000_000);
        uint256 fee1 = _mulDivRoundUp(amount1, fee, 1_000_000);

        if (amount0 > 0) IERC20(token0).transfer(recipient, amount0);
        if (amount1 > 0) IERC20(token1).transfer(recipient, amount1);

        IUniswapV3FlashCallback(recipient).uniswapV3FlashCallback(fee0, fee1, data);

        require(IERC20(token0).balanceOf(address(this)) >= balance0Before + fee0, "MockV3Pool: token0 not repaid");
        require(IERC20(token1).balanceOf(address(this)) >= balance1Before + fee1, "MockV3Pool: token1 not repaid");
    }

    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool) {
        return (_sqrtPriceX96, _tick, 0, 0, 0, 0, _unlocked);
    }

    uint160 private _sqrtPriceX96;
    int24 private _tick;
    bool private _unlocked = true;

    function setSlot0(
        uint160 sqrtPriceX96_,
        int24 tick_
    ) external {
        _sqrtPriceX96 = sqrtPriceX96_;
        _tick = tick_;
    }

    function setUnlocked(
        bool unlocked_
    ) external {
        _unlocked = unlocked_;
    }

    function _mulDivRoundUp(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        result = (a * b) / denominator;
        if ((a * b) % denominator > 0) result++;
    }
}
