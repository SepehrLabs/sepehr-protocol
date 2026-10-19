// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IFlashLoanProvider} from "../interfaces/IFlashLoanProvider.sol";
import {ISepehrCallback} from "../interfaces/ISepehrCallback.sol";
import {IMorphoFlashLoan} from "../interfaces/external/IMorpho.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title MorphoBlueFlashLoanProvider
/// @notice Flash loans from Morpho Blue, which charges no fee and lends any token it holds
///         (on Arbitrum One, several hundred thousand idle USDC).
/// @dev Morpho sends the loan, calls `onMorphoFlashLoan` on this contract, then pulls the same
///      amount back with `transferFrom`: the provider approves exactly that amount before it
///      returns, so no allowance outlives the loan.
contract MorphoBlueFlashLoanProvider is IFlashLoanProvider, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The Morpho Blue singleton.
    IMorphoFlashLoan public immutable MORPHO;

    /// @dev Set for the duration of `flashBorrow`: Morpho's callback is only accepted inside it.
    bool private transient _active;

    /// @param morpho The Morpho Blue singleton.
    /// @param owner_ The owner, who may sweep tokens sent here by mistake.
    constructor(
        address morpho,
        address owner_
    ) Ownable(owner_) {
        if (morpho == address(0)) revert SepehrErrors.ZeroAddress();
        MORPHO = IMorphoFlashLoan(morpho);
    }

    /// @notice Sends this contract's whole balance of `token` to `to`. It holds nothing between
    ///         loans; anything here was sent by mistake.
    /// @param token The token to sweep.
    /// @param to The recipient.
    function sweep(
        address token,
        address to
    ) external onlyOwner {
        if (to == address(0)) revert SepehrErrors.ZeroAddress();
        if (_active) revert SepehrErrors.ConcurrentFlashLoan();
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
        if (_active) revert SepehrErrors.ConcurrentFlashLoan();

        _active = true;
        MORPHO.flashLoan(asset, amount, abi.encode(asset, callback, data));
        _active = false;
    }

    /// @notice Morpho's flash loan callback: hands the loan to `callback`, which must send it
    ///         back, then lets Morpho pull it.
    /// @param assets The amount lent.
    /// @param payload The asset, callback and data `flashBorrow` encoded.
    function onMorphoFlashLoan(
        uint256 assets,
        bytes calldata payload
    ) external nonReentrant {
        if (msg.sender != address(MORPHO)) revert SepehrErrors.InvalidFlashLoanCallback();
        if (!_active) revert SepehrErrors.InvalidFlashLoanCallback();

        (address asset, address callback, bytes memory data) = abi.decode(payload, (address, address, bytes));

        IERC20(asset).safeTransfer(callback, assets);
        ISepehrCallback(callback).onFlashLoan(asset, assets, 0, data);

        IERC20(asset).forceApprove(address(MORPHO), assets);
    }

    /// @inheritdoc IFlashLoanProvider
    /// @dev Morpho Blue charges no flash loan fee.
    function getFlashLoanFeeBps(
        address
    ) external pure override returns (uint256) {
        return 0;
    }

    /// @inheritdoc IFlashLoanProvider
    function isAvailable(
        address asset,
        uint256 amount
    ) external view override returns (bool) {
        return IERC20(asset).balanceOf(address(MORPHO)) >= amount;
    }
}
