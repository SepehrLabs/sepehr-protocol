// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IComet} from "../../src/interfaces/external/IComet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock Compound V3 Comet for unit testing CompoundV3Adapter.
contract MockComet is IComet {
    struct AssetInfo {
        uint8 offset;
        address asset;
        address priceFeed;
        uint64 scale;
        uint64 borrowCollateralFactor;
        uint64 liquidateCollateralFactor;
        uint64 liquidationFactor;
        uint128 supplyCap;
    }

    // ── State ────────────────────────────────────────────────────────────

    mapping(address => uint256) private _borrowBalances;
    mapping(address => mapping(address => uint128)) private _collateralBalances;
    mapping(address => uint256) private _prices;
    mapping(address => mapping(address => bool)) private _allowed;

    AssetInfo[] private _assets;
    address private _baseTokenPriceFeed;
    address private _baseToken;
    uint256 private _baseScale = 1e6;

    // ── Call recording ───────────────────────────────────────────────────

    address public lastSupplyToDst;
    address public lastSupplyToAsset;
    uint256 public lastSupplyToAmount;

    address public lastWithdrawFromSrc;
    address public lastWithdrawFromTo;
    address public lastWithdrawFromAsset;
    uint256 public lastWithdrawFromAmount;

    // ── Setup helpers ────────────────────────────────────────────────────

    function setBorrowBalance(
        address user,
        uint256 balance
    ) external {
        _borrowBalances[user] = balance;
    }

    function setCollateralBalance(
        address user,
        address asset,
        uint128 balance
    ) external {
        _collateralBalances[user][asset] = balance;
    }

    function setPrice(
        address priceFeed,
        uint256 price
    ) external {
        _prices[priceFeed] = price;
    }

    function setAllowed(
        address owner,
        address manager,
        bool value
    ) external {
        _allowed[owner][manager] = value;
    }

    function setBaseTokenPriceFeed(
        address feed
    ) external {
        _baseTokenPriceFeed = feed;
    }

    function setBaseToken(
        address token
    ) external {
        _baseToken = token;
    }

    function setBaseScale(
        uint256 scale
    ) external {
        _baseScale = scale;
    }

    function addAsset(
        uint8 offset,
        address asset,
        address priceFeed,
        uint64 scale,
        uint64 borrowCollateralFactor,
        uint64 liquidateCollateralFactor,
        uint64 liquidationFactor,
        uint128 supplyCap
    ) external {
        _assets.push(
            AssetInfo(
                offset,
                asset,
                priceFeed,
                scale,
                borrowCollateralFactor,
                liquidateCollateralFactor,
                liquidationFactor,
                supplyCap
            )
        );
    }

    // ── IComet implementation ────────────────────────────────────────────

    function borrowBalanceOf(
        address account
    ) external view returns (uint256) {
        return _borrowBalances[account];
    }

    function collateralBalanceOf(
        address account,
        address asset
    ) external view returns (uint128) {
        return _collateralBalances[account][asset];
    }

    function numAssets() external view returns (uint8) {
        return uint8(_assets.length);
    }

    function getAssetInfo(
        uint8 i
    )
        external
        view
        returns (
            uint8 offset,
            address asset,
            address priceFeed,
            uint64 scale,
            uint64 borrowCollateralFactor,
            uint64 liquidateCollateralFactor,
            uint64 liquidationFactor,
            uint128 supplyCap
        )
    {
        AssetInfo storage info = _assets[i];
        return (
            info.offset,
            info.asset,
            info.priceFeed,
            info.scale,
            info.borrowCollateralFactor,
            info.liquidateCollateralFactor,
            info.liquidationFactor,
            info.supplyCap
        );
    }

    function getPrice(
        address priceFeed
    ) external view returns (uint256) {
        return _prices[priceFeed];
    }

    function baseTokenPriceFeed() external view returns (address) {
        return _baseTokenPriceFeed;
    }

    function baseToken() external view returns (address) {
        return _baseToken;
    }

    function baseScale() external view returns (uint256) {
        return _baseScale;
    }

    function isAllowed(
        address owner,
        address manager
    ) external view returns (bool) {
        return _allowed[owner][manager];
    }

    function supply(
        address,
        uint256
    ) external pure {}

    function supplyTo(
        address dst,
        address asset,
        uint256 amount
    ) external {
        lastSupplyToDst = dst;
        lastSupplyToAsset = asset;
        lastSupplyToAmount = amount;
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
    }

    function withdrawFrom(
        address src,
        address to,
        address asset,
        uint256 amount
    ) external {
        lastWithdrawFromSrc = src;
        lastWithdrawFromTo = to;
        lastWithdrawFromAsset = asset;
        lastWithdrawFromAmount = amount;
    }
}
