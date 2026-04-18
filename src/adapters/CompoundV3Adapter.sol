// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {IComet} from "../interfaces/external/IComet.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CompoundV3Adapter
/// @notice Protocol adapter for Compound V3 (Comet) positions. Calculates health
///         factors from on-chain collateral data and handles repay/withdraw via Comet.
/// @dev Trust boundary: Comet's `allow` grants this adapter full manager rights on the
///      underlying market (supplyTo, withdrawFrom, transferFrom). Containment relies on
///      `onlyCore` gating every state-changing function and no escape hatch being added
///      outside IProtocolAdapter. Any new mutator must be `onlyCore` or a pure no-op.
contract CompoundV3Adapter is IProtocolAdapter {
    using SafeERC20 for IERC20;

    IComet public immutable COMET;
    address public immutable core;

    modifier onlyCore() {
        if (msg.sender != core) revert SepehrErrors.NotAuthorized();
        _;
    }

    constructor(
        address comet,
        address _core
    ) {
        if (comet == address(0)) revert SepehrErrors.ZeroAddress();
        if (_core == address(0)) revert SepehrErrors.ZeroAddress();
        COMET = IComet(comet);
        core = _core;
    }

    /// @inheritdoc IProtocolAdapter
    function getHealthFactor(
        address user
    ) external view returns (uint256) {
        uint256 borrowBalance = COMET.borrowBalanceOf(user);
        if (borrowBalance == 0) return type(uint256).max;

        uint256 totalCollateralValue;
        uint8 numAssets = COMET.numAssets();
        for (uint8 i; i < numAssets; i++) {
            (, address asset, address priceFeed, uint64 scale,, uint64 liquidateCollateralFactor,,) =
                COMET.getAssetInfo(i);
            uint128 balance = COMET.collateralBalanceOf(user, asset);
            if (balance == 0) continue;
            uint256 price = COMET.getPrice(priceFeed);
            totalCollateralValue += uint256(balance) * price * liquidateCollateralFactor / (uint256(scale) * 1e18);
        }

        uint256 basePrice = COMET.getPrice(COMET.baseTokenPriceFeed());
        uint256 borrowValueUsd = borrowBalance * basePrice / 1e6;

        if (borrowValueUsd == 0) return type(uint256).max;
        return totalCollateralValue * 1e18 / borrowValueUsd;
    }

    /// @inheritdoc IProtocolAdapter
    function checkDelegation(
        address user
    ) external view returns (bool delegated) {
        return COMET.isAllowed(user, address(this));
    }

    /// @inheritdoc IProtocolAdapter
    function repay(
        address user,
        address debtAsset,
        uint256 amount
    ) external onlyCore {
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        IERC20(debtAsset).forceApprove(address(COMET), amount);
        COMET.supplyTo(user, debtAsset, amount);
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
        COMET.withdrawFrom(user, recipient, collateralAsset, amount);
    }

    /// @inheritdoc IProtocolAdapter
    function getCollateralValueUsd(
        address user
    ) external view returns (uint256 usdValue) {
        uint8 numAssets = COMET.numAssets();
        for (uint8 i; i < numAssets; i++) {
            (, address asset, address priceFeed, uint64 scale,,,,) = COMET.getAssetInfo(i);
            uint128 balance = COMET.collateralBalanceOf(user, asset);
            if (balance == 0) continue;
            uint256 price = COMET.getPrice(priceFeed);
            usdValue += uint256(balance) * price / uint256(scale);
        }
    }
}
