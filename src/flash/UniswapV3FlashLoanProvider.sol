// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IFlashLoanProvider} from "../interfaces/IFlashLoanProvider.sol";
import {ISepehrCallback} from "../interfaces/ISepehrCallback.sol";
import {IUniswapV3Pool} from "../interfaces/external/IUniswapV3Pool.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title UniswapV3FlashLoanProvider
/// @notice Wraps a single Uniswap V3 pool's flash capability behind IFlashLoanProvider.
///         Deploy one instance per pool. The asset must be one of the pool's two tokens.
/// @dev C7: `uniswapV3FlashCallback` uses `nonReentrant` as defense-in-depth on top
///      of the msg.sender check — a compromised Pool cannot cause re-entrant dispatch
///      into Sepehr callbacks via this provider.
///      C10: owner-only `sweep` recovers tokens accidentally donated to the provider;
///      blocked while a flash loan is in flight.
contract UniswapV3FlashLoanProvider is IFlashLoanProvider, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IUniswapV3Pool public immutable POOL;

    address private _activeCallback;
    address private _activeAsset;
    uint256 private _activeAmount;
    bytes private _activeData;

    constructor(
        address pool,
        address owner_
    ) Ownable(owner_) {
        if (pool == address(0)) revert SepehrErrors.ZeroAddress();
        POOL = IUniswapV3Pool(pool);
    }

    /// @notice Sweep a non-essential token balance to `to`.
    /// @dev C10: recovers tokens accidentally donated to the provider. Blocked while
    ///      a flash loan is live so the owner cannot siphon principal/fee mid-callback.
    /// @param token The ERC20 to sweep.
    /// @param to The recipient.
    function sweep(
        address token,
        address to
    ) external onlyOwner {
        if (to == address(0)) revert SepehrErrors.ZeroAddress();
        if (_activeCallback != address(0)) revert SepehrErrors.ConcurrentFlashLoan();
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) return;
        IERC20(token).safeTransfer(to, bal);
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
        if (_activeCallback != address(0)) revert SepehrErrors.ConcurrentFlashLoan();

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
    ) external nonReentrant {
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
    /// @dev C4: `pool.fee()` is the Uniswap V3 pool's hundredths-of-bip fee constant. On
    /// canonical Uniswap V3 pools it can only be 100, 500, 3000, or 10000 — all exact
    /// multiples of 100, so integer division is lossless. Algebra forks, dynamic-fee
    /// pools, and custom factory deployments can return any uint24; silently rounding
    /// those values would under-report the true fee and make the flash repay revert
    /// (or, worse, let a malicious pool claim 0 bps and trick sizing logic into
    /// under-funding the callback). We whitelist the four canonical tiers explicitly
    /// and revert for anything else — this provider must be redeployed (or a different
    /// provider used) to flash-borrow from a non-canonical pool.
    function getFlashLoanFeeBps(
        address
    ) external view override returns (uint256) {
        uint24 fee = POOL.fee();
        if (fee == 100) return 1;
        if (fee == 500) return 5;
        if (fee == 3000) return 30;
        if (fee == 10_000) return 100;
        revert SepehrErrors.UnsupportedPoolFee(fee);
    }

    /// @inheritdoc IFlashLoanProvider
    /// @dev C6: check `slot0.unlocked` so the selector does not pick this provider
    ///      mid-swap — `pool.flash` reverts with `LOK` when the pool is locked, which
    ///      would waste a top-level `flashBorrow` attempt and force the fallback chain
    ///      to retry a second provider.
    function isAvailable(
        address asset,
        uint256 amount
    ) external view override returns (bool) {
        if (asset != POOL.token0() && asset != POOL.token1()) return false;
        if (IERC20(asset).balanceOf(address(POOL)) < amount) return false;
        (,,,,,, bool unlocked) = POOL.slot0();
        return unlocked;
    }
}
