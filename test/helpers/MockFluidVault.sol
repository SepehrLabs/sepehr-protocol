// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IFluidVault} from "../../src/interfaces/external/IFluidVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock Fluid vault for unit-testing FluidAdapter.
contract MockFluidVault is IFluidVault {
    struct RepayCall {
        address onBehalfOf;
        uint256 amount;
    }

    struct WithdrawCall {
        uint256 amount;
        address recipient;
    }

    IERC20 public immutable UNDERLYING;

    mapping(address => uint256) private _healthFactors;
    mapping(address => uint256) private _collateralValuesUsd;
    mapping(address => mapping(address => bool)) private _authMap;

    RepayCall[] public repayCalls;
    WithdrawCall[] public withdrawCalls;

    constructor(
        address underlying
    ) {
        UNDERLYING = IERC20(underlying);
    }

    // ── Setters ────────────────────────────────────────────────────────

    function setHealthFactor(
        address user,
        uint256 hf
    ) external {
        _healthFactors[user] = hf;
    }

    function setCollateralValueUsd(
        address user,
        uint256 usdValue
    ) external {
        _collateralValuesUsd[user] = usdValue;
    }

    function setAuth(
        address user,
        address auth,
        bool authorized
    ) external {
        _authMap[user][auth] = authorized;
    }

    // ── Getters for recorded calls ─────────────────────────────────────

    function repayCallCount() external view returns (uint256) {
        return repayCalls.length;
    }

    function withdrawCallCount() external view returns (uint256) {
        return withdrawCalls.length;
    }

    // ── IFluidVault implementation ─────────────────────────────────────

    function getHealthFactor(
        address user
    ) external view override returns (uint256) {
        return _healthFactors[user];
    }

    function isAuth(
        address user,
        address auth
    ) external view override returns (bool) {
        return _authMap[user][auth];
    }

    function repay(
        address onBehalfOf,
        uint256 amount
    ) external override returns (uint256) {
        repayCalls.push(RepayCall({onBehalfOf: onBehalfOf, amount: amount}));
        UNDERLYING.transferFrom(msg.sender, address(this), amount);
        return amount;
    }

    function withdraw(
        uint256 amount,
        address recipient
    ) external override returns (uint256) {
        withdrawCalls.push(WithdrawCall({amount: amount, recipient: recipient}));
        UNDERLYING.transfer(recipient, amount);
        return amount;
    }

    function getCollateralValueUsd(
        address user
    ) external view override returns (uint256) {
        return _collateralValuesUsd[user];
    }
}
