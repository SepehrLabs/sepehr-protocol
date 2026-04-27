// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAavePool} from "../../src/interfaces/external/IAavePool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock Aave Pool that implements getUserAccountData, repay, and withdraw
///         for unit-testing AaveV3Adapter.
contract MockAavePoolAdapter is IAavePool {
    struct AccountData {
        uint256 totalCollateralBase;
        uint256 totalDebtBase;
        uint256 availableBorrowsBase;
        uint256 currentLiquidationThreshold;
        uint256 ltv;
        uint256 healthFactor;
    }

    struct RepayCall {
        address asset;
        uint256 amount;
        uint256 interestRateMode;
        address onBehalfOf;
    }

    struct WithdrawCall {
        address asset;
        uint256 amount;
        address to;
    }

    IERC20 public immutable UNDERLYING;

    mapping(address => AccountData) private _accountData;
    mapping(address => address) private _variableDebtToken;

    RepayCall[] public repayCalls;
    WithdrawCall[] public withdrawCalls;

    /// @dev When true, calls to `repay` with `interestRateMode = 2` revert so the adapter's
    ///      try/catch fallback to stable (mode 1) can be exercised.
    bool public revertOnVariableMode;

    /// @dev When non-zero, `repay` only pulls `min(amount, cap)` tokens from the caller, simulating
    ///      Aave's behaviour when `amount` exceeds the user's outstanding debt. Leaves a verifiable
    ///      surplus in the adapter so the B12 sweep can be asserted.
    uint256 public repayCapAmount;

    constructor(
        address underlying
    ) {
        UNDERLYING = IERC20(underlying);
    }

    // ── Setters ────────────────────────────────────────────────────────

    function setUserAccountData(
        address user,
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    ) external {
        _accountData[user] = AccountData({
            totalCollateralBase: totalCollateralBase,
            totalDebtBase: totalDebtBase,
            availableBorrowsBase: availableBorrowsBase,
            currentLiquidationThreshold: currentLiquidationThreshold,
            ltv: ltv,
            healthFactor: healthFactor
        });
    }

    function setRevertOnVariableMode(
        bool flag
    ) external {
        revertOnVariableMode = flag;
    }

    function setRepayCap(
        uint256 cap
    ) external {
        repayCapAmount = cap;
    }

    // ── Getters for recorded calls ─────────────────────────────────────

    function repayCallCount() external view returns (uint256) {
        return repayCalls.length;
    }

    function withdrawCallCount() external view returns (uint256) {
        return withdrawCalls.length;
    }

    // ── IAavePool implementation ───────────────────────────────────────

    function getUserAccountData(
        address user
    )
        external
        view
        override
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        AccountData memory d = _accountData[user];
        return (
            d.totalCollateralBase,
            d.totalDebtBase,
            d.availableBorrowsBase,
            d.currentLiquidationThreshold,
            d.ltv,
            d.healthFactor
        );
    }

    function repay(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        address onBehalfOf
    ) external override returns (uint256) {
        if (revertOnVariableMode && interestRateMode == 2) {
            revert("MockAavePoolAdapter: NO_DEBT_OF_SELECTED_TYPE");
        }
        uint256 take = amount;
        if (repayCapAmount != 0 && take > repayCapAmount) {
            take = repayCapAmount;
        }
        repayCalls.push(
            RepayCall({asset: asset, amount: amount, interestRateMode: interestRateMode, onBehalfOf: onBehalfOf})
        );
        if (take > 0) {
            IERC20(asset).transferFrom(msg.sender, address(this), take);
        }
        return take;
    }

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external override returns (uint256) {
        withdrawCalls.push(WithdrawCall({asset: asset, amount: amount, to: to}));
        // Send underlying tokens to the recipient
        IERC20(asset).transfer(to, amount);
        return amount;
    }

    // ── Stubs for unused IAavePool functions ────────────────────────────

    function flashLoanSimple(
        address,
        address,
        uint256,
        bytes calldata,
        uint16
    ) external pure override {
        revert("MockAavePoolAdapter: flashLoanSimple not implemented");
    }

    function FLASHLOAN_PREMIUM_TOTAL() external pure override returns (uint128) {
        return 0;
    }

    function setVariableDebtToken(
        address asset,
        address variableDebtToken
    ) external {
        _variableDebtToken[asset] = variableDebtToken;
    }

    function getReserveData(
        address asset
    )
        external
        view
        override
        returns (
            uint256,
            uint128,
            uint128,
            uint128,
            uint128,
            uint128,
            uint40,
            uint16,
            address,
            address,
            address variableDebtTokenAddress,
            address,
            uint128,
            uint128,
            uint128
        )
    {
        variableDebtTokenAddress = _variableDebtToken[asset];
        return (0, 0, 0, 0, 0, 0, 0, 0, address(0), address(0), variableDebtTokenAddress, address(0), 0, 0, 0);
    }
}
