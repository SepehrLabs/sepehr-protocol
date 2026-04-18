// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IFlashLoanProvider} from "../interfaces/IFlashLoanProvider.sol";
import {ISepehrCallback} from "../interfaces/ISepehrCallback.sol";
import {IBalancerFeesCollector, IBalancerVault} from "../interfaces/external/IBalancerVault.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BalancerFlashLoanProvider
/// @notice Wraps Balancer V2 Vault flash loans behind the IFlashLoanProvider interface.
/// @dev C7: callbacks use `nonReentrant` as defense-in-depth on top of the
///      msg.sender/initiator checks — a compromised Vault cannot cause re-entrant
///      dispatch into Sepehr callbacks via this provider.
///      C9: callback + userData travel through the Vault's `userData` bytes rather
///      than persistent storage. A transient `_active` flag (EIP-1153) enforces the
///      ConcurrentFlashLoan guard without touching a real storage slot.
///      C10: owner-only `sweep` recovers tokens accidentally donated to the provider;
///      blocked while a flash loan is in flight.
contract BalancerFlashLoanProvider is IFlashLoanProvider, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IBalancerVault public immutable VAULT;

    bool private transient _active;

    constructor(
        address vault,
        address owner_
    ) Ownable(owner_) {
        if (vault == address(0)) revert SepehrErrors.ZeroAddress();
        VAULT = IBalancerVault(vault);
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

        address[] memory tokens = new address[](1);
        tokens[0] = asset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        // C9: encode (callback, userData) into the Vault's userData bytes.
        bytes memory userData = abi.encode(callback, data);
        VAULT.flashLoan(address(this), tokens, amounts, userData);

        _active = false;
    }

    /// @notice Balancer V2 callback invoked by the Vault after transferring borrowed tokens.
    /// @param tokens The borrowed token addresses.
    /// @param amounts The borrowed amounts.
    /// @param feeAmounts The fees owed for each token.
    /// @param userData The abi-encoded `(address callback, bytes data)` tuple produced by `flashBorrow`.
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external nonReentrant {
        if (msg.sender != address(VAULT)) revert SepehrErrors.InvalidFlashLoanCallback();
        if (!_active) revert SepehrErrors.InvalidFlashLoanCallback();
        // C5: Bound to single-token flash loans so a future Vault upgrade pushing
        // 2+ tokens cannot silently advance past the first element and desynchronise
        // the amounts/fees the callback sees.
        if (tokens.length != 1 || amounts.length != 1 || feeAmounts.length != 1) {
            revert SepehrErrors.InvalidFlashLoanCallback();
        }

        address asset = tokens[0];
        uint256 amount = amounts[0];
        uint256 fee = feeAmounts[0];

        (address callback, bytes memory data) = abi.decode(userData, (address, bytes));

        IERC20(asset).safeTransfer(callback, amount);
        ISepehrCallback(callback).onFlashLoan(asset, amount, fee, data);

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
