// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {IBotList, ICreditFacade, ICreditManager} from "../interfaces/external/IGearbox.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title GearboxAdapter
/// @notice Protocol adapter for Gearbox V3 credit account positions. Uses the bot
///         multicall pattern for repayment and collateral withdrawal.
/// @dev Trust boundary: Gearbox's bot-permission model is bit-masked. The adapter only
///      needs `DECREASE_DEBT` and `WITHDRAW_COLLATERAL` and `checkDelegation` enforces
///      that both bits are set (not merely "any permission"). This prevents a user from
///      accidentally granting the adapter `EXTERNAL_CALLS_PERMISSION` or other over-broad
///      permissions that could be abused if the adapter or Core were later compromised.
contract GearboxAdapter is IProtocolAdapter {
    using SafeERC20 for IERC20;

    /// @dev Gearbox V3 health factor is in basis points (10_000 = 1.0).
    uint256 internal constant HF_BP_TO_WAD = 1e14;

    /// @dev calcDebtAndCollateral task for full collateral check.
    uint8 internal constant TASK_FULL_COLLATERAL_CHECK = 1;

    /// @dev Gearbox V3 BotListV3 permission bits needed by this adapter. Matches the bit
    ///      layout used by Gearbox (DECREASE_DEBT = 1 << 2, WITHDRAW_COLLATERAL = 1 << 5).
    ///      If Gearbox revises the bit layout, update here and audit existing delegations.
    uint192 internal constant DECREASE_DEBT_PERMISSION = 1 << 2;
    uint192 internal constant WITHDRAW_COLLATERAL_PERMISSION = 1 << 5;
    uint192 internal constant REQUIRED_PERMISSIONS = DECREASE_DEBT_PERMISSION | WITHDRAW_COLLATERAL_PERMISSION;

    ICreditManager public immutable CREDIT_MANAGER;
    IBotList public immutable BOT_LIST;
    address public immutable core;

    modifier onlyCore() {
        if (msg.sender != core) revert SepehrErrors.NotAuthorized();
        _;
    }

    constructor(
        address creditManager,
        address botList,
        address _core
    ) {
        if (creditManager == address(0)) revert SepehrErrors.ZeroAddress();
        if (botList == address(0)) revert SepehrErrors.ZeroAddress();
        if (_core == address(0)) revert SepehrErrors.ZeroAddress();
        CREDIT_MANAGER = ICreditManager(creditManager);
        BOT_LIST = IBotList(botList);
        core = _core;
    }

    /// @inheritdoc IProtocolAdapter
    function getHealthFactor(
        address user
    ) external view returns (uint256 healthFactor) {
        address creditAccount = CREDIT_MANAGER.creditAccounts(user);
        if (creditAccount == address(0)) return type(uint256).max;
        (,,,,,,, uint256 hfBp) = CREDIT_MANAGER.calcDebtAndCollateral(creditAccount, TASK_FULL_COLLATERAL_CHECK);
        // Convert from basis points (10_000 = 1.0) to WAD (1e18 = 1.0).
        return hfBp * HF_BP_TO_WAD;
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Requires the user to have granted BOTH `DECREASE_DEBT` and `WITHDRAW_COLLATERAL`
    ///      bit permissions. Granting more is allowed (user's choice) but the adapter never
    ///      uses them. This narrow check prevents the adapter from being "enabled" when the
    ///      user granted an unrelated permission bit only.
    function checkDelegation(
        address user
    ) external view returns (bool delegated) {
        address creditAccount = CREDIT_MANAGER.creditAccounts(user);
        if (creditAccount == address(0)) return false;
        (uint192 permissions, bool forbidden,) =
            BOT_LIST.getBotStatus(address(CREDIT_MANAGER), creditAccount, address(this));
        if (forbidden) return false;
        return (permissions & REQUIRED_PERMISSIONS) == REQUIRED_PERMISSIONS;
    }

    /// @inheritdoc IProtocolAdapter
    function repay(
        address user,
        address debtAsset,
        uint256 amount
    ) external onlyCore {
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        address creditAccount = CREDIT_MANAGER.creditAccounts(user);
        if (creditAccount == address(0)) revert SepehrErrors.ZeroAddress();
        // Transfer debt tokens to the credit account, then call botMulticall to decrease debt.
        IERC20(debtAsset).safeTransfer(creditAccount, amount);
        address facade = CREDIT_MANAGER.creditFacade();
        bytes[] memory calls = new bytes[](1);
        // Encode decreaseDebt(uint256) selector with amount.
        calls[0] = abi.encodeWithSignature("decreaseDebt(uint256)", amount);
        ICreditFacade(facade).botMulticall(creditAccount, calls);
    }

    /// @inheritdoc IProtocolAdapter
    function withdrawCollateral(
        address user,
        address collateralAsset,
        uint256 amount,
        address recipient
    ) external onlyCore {
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        if (recipient == address(0)) revert SepehrErrors.ZeroAddress();
        address creditAccount = CREDIT_MANAGER.creditAccounts(user);
        if (creditAccount == address(0)) revert SepehrErrors.ZeroAddress();
        address facade = CREDIT_MANAGER.creditFacade();
        bytes[] memory calls = new bytes[](1);
        // Encode withdrawCollateral(address,uint256,address) selector.
        calls[0] =
            abi.encodeWithSignature("withdrawCollateral(address,uint256,address)", collateralAsset, amount, recipient);
        ICreditFacade(facade).botMulticall(creditAccount, calls);
    }

    /// @inheritdoc IProtocolAdapter
    function getCollateralValueUsd(
        address user
    ) external view returns (uint256 usdValue) {
        address creditAccount = CREDIT_MANAGER.creditAccounts(user);
        if (creditAccount == address(0)) return 0;
        (,,,,, uint256 totalValueUSD,,) =
            CREDIT_MANAGER.calcDebtAndCollateral(creditAccount, TASK_FULL_COLLATERAL_CHECK);
        return totalValueUSD;
    }
}
