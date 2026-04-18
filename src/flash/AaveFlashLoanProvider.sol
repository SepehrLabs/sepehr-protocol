// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IFlashLoanProvider} from "../interfaces/IFlashLoanProvider.sol";
import {ISepehrCallback} from "../interfaces/ISepehrCallback.sol";
import {IAavePool} from "../interfaces/external/IAavePool.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AaveFlashLoanProvider
/// @notice Wraps Aave V3 flash loans behind the IFlashLoanProvider interface.
/// @dev C7: `executeOperation` uses `nonReentrant` as defense-in-depth on top of
///      the msg.sender/initiator checks — a compromised Pool cannot cause re-entrant
///      dispatch into Sepehr callbacks via this provider.
///      C10: owner-only `sweep` recovers tokens accidentally donated to the provider;
///      blocked while a flash loan is in flight so the owner cannot siphon the
///      principal/fee mid-callback.
contract AaveFlashLoanProvider is IFlashLoanProvider, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IAavePool public immutable POOL;

    address private _activeCallback;
    bytes private _activeData;

    constructor(
        address pool,
        address owner_
    ) Ownable(owner_) {
        if (pool == address(0)) revert SepehrErrors.ZeroAddress();
        POOL = IAavePool(pool);
    }

    /// @notice Sweep a non-essential token balance to `to`.
    /// @dev C10: guards against accidentally-donated tokens being permanently locked.
    ///      Blocked while `_activeCallback != address(0)` so an (already trusted) owner
    ///      still cannot race a live flash loan and take the principal.
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

        _activeCallback = callback;
        _activeData = data;

        POOL.flashLoanSimple(address(this), asset, amount, "", 0);

        // C8: explicitly zero the Pool's allowance after repayment. On standard ERC20s Aave's
        // `transferFrom` already decrements allowance to 0, but non-standard tokens (USDT-like
        // quirks, custom ERC20s) may leave dust, which would persist across flash loans and
        // silently raise the next call's effective allowance.
        IERC20(asset).forceApprove(address(POOL), 0);

        _activeCallback = address(0);
        delete _activeData;
    }

    /// @notice Aave V3 callback invoked by the Pool after transferring borrowed tokens.
    /// @param asset The borrowed token.
    /// @param amount The borrowed amount.
    /// @param premium The fee owed on top of the principal.
    /// @param initiator The address that initiated the flash loan (must be this contract).
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata
    ) external nonReentrant returns (bool) {
        if (msg.sender != address(POOL)) revert SepehrErrors.InvalidFlashLoanCallback();
        if (initiator != address(this)) revert SepehrErrors.InvalidFlashLoanCallback();
        if (_activeCallback == address(0)) revert SepehrErrors.InvalidFlashLoanCallback();

        IERC20(asset).safeTransfer(_activeCallback, amount);
        ISepehrCallback(_activeCallback).onFlashLoan(asset, amount, premium, _activeData);

        IERC20(asset).forceApprove(address(POOL), amount + premium);
        return true;
    }

    /// @inheritdoc IFlashLoanProvider
    function getFlashLoanFeeBps(
        address
    ) external view override returns (uint256) {
        return uint256(POOL.FLASHLOAN_PREMIUM_TOTAL());
    }

    /// @inheritdoc IFlashLoanProvider
    function isAvailable(
        address asset,
        uint256 amount
    ) external view override returns (bool) {
        return IERC20(asset).balanceOf(address(POOL)) >= amount;
    }
}
