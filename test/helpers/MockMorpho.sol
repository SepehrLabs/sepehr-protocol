// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IMorpho, IMorphoOracle} from "../../src/interfaces/external/IMorpho.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock Morpho Blue oracle for unit testing MorphoBlueAdapter.
contract MockMorphoOracle is IMorphoOracle {
    uint256 private _price;

    function setPrice(
        uint256 price_
    ) external {
        _price = price_;
    }

    function price() external view returns (uint256) {
        return _price;
    }
}

/// @notice Mock Morpho Blue protocol for unit testing MorphoBlueAdapter.
contract MockMorpho is IMorpho {
    // ── State ────────────────────────────────────────────────────────────

    mapping(bytes32 => mapping(address => Position)) private _positions;
    mapping(bytes32 => Market) private _markets;
    mapping(bytes32 => MarketParams) private _marketParams;
    mapping(address => mapping(address => bool)) private _authorized;

    // ── Call recording ───────────────────────────────────────────────────

    address public lastRepayLoanToken;
    uint256 public lastRepayAssets;
    uint256 public lastRepayShares;
    address public lastRepayOnBehalf;
    bytes public lastRepayData;

    address public lastWithdrawCollateralToken;
    uint256 public lastWithdrawAssets;
    address public lastWithdrawOnBehalf;
    address public lastWithdrawReceiver;

    // ── Setup helpers ────────────────────────────────────────────────────

    function setPosition(
        bytes32 id,
        address user,
        uint256 supplyShares,
        uint128 borrowShares,
        uint128 collateral
    ) external {
        _positions[id][user] = Position(supplyShares, borrowShares, collateral);
    }

    function setMarket(
        bytes32 id,
        uint128 totalSupplyAssets,
        uint128 totalSupplyShares,
        uint128 totalBorrowAssets,
        uint128 totalBorrowShares,
        uint128 lastUpdate,
        uint128 fee
    ) external {
        _markets[id] =
            Market(totalSupplyAssets, totalSupplyShares, totalBorrowAssets, totalBorrowShares, lastUpdate, fee);
    }

    function setMarketParams(
        bytes32 id,
        address loanToken,
        address collateralToken,
        address oracle,
        address irm,
        uint256 lltv
    ) external {
        _marketParams[id] = MarketParams(loanToken, collateralToken, oracle, irm, lltv);
    }

    function setAuthorized(
        address authorizer,
        address authorized_,
        bool value
    ) external {
        _authorized[authorizer][authorized_] = value;
    }

    // ── IMorpho implementation ───────────────────────────────────────────

    function position(
        bytes32 id,
        address user
    ) external view returns (Position memory) {
        return _positions[id][user];
    }

    function market(
        bytes32 id
    ) external view returns (Market memory) {
        return _markets[id];
    }

    function idToMarketParams(
        bytes32 id
    ) external view returns (MarketParams memory) {
        return _marketParams[id];
    }

    function isAuthorized(
        address authorizer,
        address authorized_
    ) external view returns (bool) {
        return _authorized[authorizer][authorized_];
    }

    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 assetsRepaid, uint256 sharesRepaid) {
        lastRepayLoanToken = marketParams.loanToken;
        lastRepayAssets = assets;
        lastRepayShares = shares;
        lastRepayOnBehalf = onBehalf;
        lastRepayData = data;
        IERC20(marketParams.loanToken).transferFrom(msg.sender, address(this), assets);
        return (assets, shares);
    }

    function withdrawCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external {
        lastWithdrawCollateralToken = marketParams.collateralToken;
        lastWithdrawAssets = assets;
        lastWithdrawOnBehalf = onBehalf;
        lastWithdrawReceiver = receiver;
    }
}
