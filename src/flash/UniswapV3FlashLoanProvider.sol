// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IFlashLoanProvider} from "../interfaces/IFlashLoanProvider.sol";
import {ISepehrCallback} from "../interfaces/ISepehrCallback.sol";
import {IUniswapV3Pool} from "../interfaces/external/IUniswapV3Pool.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title UniswapV3FlashLoanProvider
/// @notice Wraps a single Uniswap V3 pool's flash capability behind IFlashLoanProvider.
///         Deploy one instance per pool. The asset must be one of the pool's two tokens.
contract UniswapV3FlashLoanProvider is IFlashLoanProvider {
    using SafeERC20 for IERC20;

    IUniswapV3Pool public immutable POOL;

    address private _activeCallback;
    address private _activeAsset;
    uint256 private _activeAmount;
    bytes private _activeData;

    constructor(
        address pool
    ) {
        if (pool == address(0)) revert SepehrErrors.ZeroAddress();
        POOL = IUniswapV3Pool(pool);
    }

    /// @inheritdoc IFlashLoanProvider
    function flashBorrow(
        address asset,
        uint256 amount,
        address callback,
        bytes calldata data
    ) external override {
        if (callback == address(0)) revert SepehrErrors.ZeroAddress();
        if (amount == 0) revert SepehrErrors.ZeroAmount();

        address t0 = POOL.token0();
        address t1 = POOL.token1();
        bool isToken0 = asset == t0;
        bool isToken1 = asset == t1;
        if (!isToken0 && !isToken1) revert SepehrErrors.NoFlashLoanAvailable();

        _activeCallback = callback;
        _activeAsset = asset;
        _activeAmount = amount;
        _activeData = data;

        uint256 amount0 = isToken0 ? amount : 0;
        uint256 amount1 = isToken1 ? amount : 0;
        POOL.flash(address(this), amount0, amount1, "");

        _activeCallback = address(0);
        _activeAsset = address(0);
        _activeAmount = 0;
        delete _activeData;
    }

    /// @notice Uniswap V3 flash callback invoked by the pool after transferring tokens.
    /// @param fee0 The fee owed for token0.
    /// @param fee1 The fee owed for token1.
    function uniswapV3FlashCallback(
        uint256 fee0,
        uint256 fee1,
        bytes calldata
    ) external {
        if (msg.sender != address(POOL)) revert SepehrErrors.InvalidFlashLoanCallback();
        if (_activeCallback == address(0)) revert SepehrErrors.InvalidFlashLoanCallback();

        address asset = _activeAsset;
        uint256 amount = _activeAmount;
        uint256 fee = asset == POOL.token0() ? fee0 : fee1;

        IERC20(asset).safeTransfer(_activeCallback, amount);
        ISepehrCallback(_activeCallback).onFlashLoan(asset, amount, fee, _activeData);

        IERC20(asset).safeTransfer(address(POOL), amount + fee);
    }

    /// @inheritdoc IFlashLoanProvider
    function getFlashLoanFeeBps(
        address
    ) external view override returns (uint256) {
        // pool.fee() is in hundredths of a bip (1e6 = 100%), convert to bps (1e4 = 100%)
        return uint256(POOL.fee()) / 100;
    }

    /// @inheritdoc IFlashLoanProvider
    function isAvailable(
        address asset,
        uint256 amount
    ) external view override returns (bool) {
        if (asset != POOL.token0() && asset != POOL.token1()) return false;
        return IERC20(asset).balanceOf(address(POOL)) >= amount;
    }
}
