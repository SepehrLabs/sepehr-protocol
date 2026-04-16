// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {IBotList, ICreditFacade, ICreditManager} from "../interfaces/external/IGearbox.sol";
import {AegisErrors} from "../libraries/AegisErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title GearboxAdapter
/// @notice Protocol adapter for Gearbox V3 credit account positions. Uses the bot
///         multicall pattern for repayment and collateral withdrawal.
contract GearboxAdapter is IProtocolAdapter {
    using SafeERC20 for IERC20;

    /// @dev Gearbox V3 health factor is in basis points (10_000 = 1.0).
    uint256 internal constant HF_BP_TO_WAD = 1e14;

    /// @dev calcDebtAndCollateral task for full collateral check.
    uint8 internal constant TASK_FULL_COLLATERAL_CHECK = 1;

    ICreditManager public immutable CREDIT_MANAGER;
    IBotList public immutable BOT_LIST;

    constructor(
        address creditManager,
        address botList
    ) {
        if (creditManager == address(0)) revert AegisErrors.ZeroAddress();
        if (botList == address(0)) revert AegisErrors.ZeroAddress();
        CREDIT_MANAGER = ICreditManager(creditManager);
        BOT_LIST = IBotList(botList);
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
    function checkDelegation(
        address user
    ) external view returns (bool delegated) {
        address creditAccount = CREDIT_MANAGER.creditAccounts(user);
        if (creditAccount == address(0)) return false;
        (uint192 permissions, bool forbidden,) =
            BOT_LIST.getBotStatus(address(CREDIT_MANAGER), creditAccount, address(this));
        return permissions > 0 && !forbidden;
    }

    /// @inheritdoc IProtocolAdapter
    function repay(
        address user,
        address debtAsset,
        uint256 amount
    ) external {
        if (amount == 0) revert AegisErrors.ZeroAmount();
        address creditAccount = CREDIT_MANAGER.creditAccounts(user);
        if (creditAccount == address(0)) revert AegisErrors.ZeroAddress();
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
    ) external {
        if (amount == 0) revert AegisErrors.ZeroAmount();
        if (recipient == address(0)) revert AegisErrors.ZeroAddress();
        address creditAccount = CREDIT_MANAGER.creditAccounts(user);
        if (creditAccount == address(0)) revert AegisErrors.ZeroAddress();
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
