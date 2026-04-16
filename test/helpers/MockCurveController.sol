// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ICurveController} from "../../src/interfaces/external/ICurveLlamma.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock Curve Lending Controller for unit-testing CurveLlamalendAdapter.
contract MockCurveController is ICurveController {
    struct RepayCall {
        uint256 amount;
        address _for;
    }

    struct RemoveCollateralCall {
        uint256 amount;
    }

    mapping(address => int256) private _health;
    mapping(address => uint256[4]) private _userState;
    address private _collateralToken;
    address private _borrowedToken;

    RepayCall[] public repayCalls;
    RemoveCollateralCall[] public removeCollateralCalls;

    constructor(
        address collateralToken_,
        address borrowedToken_
    ) {
        _collateralToken = collateralToken_;
        _borrowedToken = borrowedToken_;
    }

    // ── Setters ────────────────────────────────────────────────────────

    function setHealth(
        address user,
        int256 value
    ) external {
        _health[user] = value;
    }

    function setUserState(
        address user,
        uint256 collateral,
        uint256 stablecoin,
        uint256 debt,
        uint256 N
    ) external {
        _userState[user] = [collateral, stablecoin, debt, N];
    }

    // ── Getters for recorded calls ─────────────────────────────────────

    function repayCallCount() external view returns (uint256) {
        return repayCalls.length;
    }

    function removeCollateralCallCount() external view returns (uint256) {
        return removeCollateralCalls.length;
    }

    // ── ICurveController implementation ────────────────────────────────

    function health(
        address user
    ) external view override returns (int256) {
        return _health[user];
    }

    function repay(
        uint256 amount,
        address _for
    ) external override {
        repayCalls.push(RepayCall({amount: amount, _for: _for}));
        IERC20(_borrowedToken).transferFrom(msg.sender, address(this), amount);
    }

    function remove_collateral(
        uint256 amount
    ) external override {
        removeCollateralCalls.push(RemoveCollateralCall({amount: amount}));
        // Send collateral tokens to the caller (the adapter)
        IERC20(_collateralToken).transfer(msg.sender, amount);
    }

    function user_state(
        address user
    ) external view override returns (uint256[4] memory) {
        return _userState[user];
    }

    function amm() external pure override returns (address) {
        return address(0);
    }

    function collateral_token() external view override returns (address) {
        return _collateralToken;
    }

    function borrowed_token() external view override returns (address) {
        return _borrowedToken;
    }
}
