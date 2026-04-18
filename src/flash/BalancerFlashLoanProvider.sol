// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IFlashLoanProvider} from "../interfaces/IFlashLoanProvider.sol";
import {ISepehrCallback} from "../interfaces/ISepehrCallback.sol";
import {IBalancerFeesCollector, IBalancerVault} from "../interfaces/external/IBalancerVault.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title BalancerFlashLoanProvider
/// @notice Wraps Balancer V2 Vault flash loans behind the IFlashLoanProvider interface.
contract BalancerFlashLoanProvider is IFlashLoanProvider {
    using SafeERC20 for IERC20;

    IBalancerVault public immutable VAULT;

    address private _activeCallback;
    bytes private _activeData;

    constructor(
        address vault
    ) {
        if (vault == address(0)) revert SepehrErrors.ZeroAddress();
        VAULT = IBalancerVault(vault);
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

        address[] memory tokens = new address[](1);
        tokens[0] = asset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        VAULT.flashLoan(address(this), tokens, amounts, "");

        _activeCallback = address(0);
        delete _activeData;
    }

    /// @notice Balancer V2 callback invoked by the Vault after transferring borrowed tokens.
    /// @param tokens The borrowed token addresses.
    /// @param amounts The borrowed amounts.
    /// @param feeAmounts The fees owed for each token.
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory
    ) external {
        if (msg.sender != address(VAULT)) revert SepehrErrors.InvalidFlashLoanCallback();
        if (_activeCallback == address(0)) revert SepehrErrors.InvalidFlashLoanCallback();

        address asset = tokens[0];
        uint256 amount = amounts[0];
        uint256 fee = feeAmounts[0];

        IERC20(asset).safeTransfer(_activeCallback, amount);
        ISepehrCallback(_activeCallback).onFlashLoan(asset, amount, fee, _activeData);

        IERC20(asset).safeTransfer(address(VAULT), amount + fee);
    }

    /// @inheritdoc IFlashLoanProvider
    function getFlashLoanFeeBps(
        address
    ) external view override returns (uint256) {
        address collector = VAULT.getProtocolFeesCollector();
        uint256 feePercentage = IBalancerFeesCollector(collector).getFlashLoanFeePercentage();
        // C3: feePercentage uses 18-decimal fixed point (1e18 = 100% = 10000 bps). Integer
        // division truncates and returns 0 for sub-1-bp fees (e.g. a 0.5-bp = 5e13 rate
        // would pre-fund nothing and make the flash repay fail). Use ceiling division so
        // callers always over-approve by ≤1 wei of the loan — the upstream Vault returns
        // any excess, so the user does not pay more than is actually owed.
        if (feePercentage == 0) return 0;
        return (feePercentage + 1e14 - 1) / 1e14;
    }

    /// @inheritdoc IFlashLoanProvider
    function isAvailable(
        address asset,
        uint256 amount
    ) external view override returns (bool) {
        return IERC20(asset).balanceOf(address(VAULT)) >= amount;
    }
}
