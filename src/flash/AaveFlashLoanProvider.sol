// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IFlashLoanProvider} from "../interfaces/IFlashLoanProvider.sol";
import {ISepehrCallback} from "../interfaces/ISepehrCallback.sol";
import {IAavePool} from "../interfaces/external/IAavePool.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title AaveFlashLoanProvider
/// @notice Wraps Aave V3 flash loans behind the IFlashLoanProvider interface.
contract AaveFlashLoanProvider is IFlashLoanProvider {
    using SafeERC20 for IERC20;

    IAavePool public immutable POOL;

    address private _activeCallback;
    bytes private _activeData;

    constructor(
        address pool
    ) {
        if (pool == address(0)) revert SepehrErrors.ZeroAddress();
        POOL = IAavePool(pool);
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
    ) external returns (bool) {
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
