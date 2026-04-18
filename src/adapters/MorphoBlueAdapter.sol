// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {IMorpho, IMorphoOracle} from "../interfaces/external/IMorpho.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MorphoBlueAdapter
/// @notice Protocol adapter for Morpho Blue isolated-market positions. Computes
///         health factor from position shares, market state, oracle price, and LLTV.
/// @dev Trust boundary: Morpho's `setAuthorization` grants this adapter full manager
///      rights over the user's position across every Morpho market (repay, withdraw,
///      supplyCollateral, borrow). The surface is constrained to two operations because
///      (a) `repay`/`withdrawCollateral` are the only functions gated by `onlyCore`, and
///      (b) the adapter exposes no other public mutator. Any additional state-changing
///      function added here MUST also be gated by `onlyCore` or explicitly scoped to a
///      non-manager pathway; otherwise, manager rights become an unrestricted drain vector.
contract MorphoBlueAdapter is IProtocolAdapter {
    using SafeERC20 for IERC20;

    IMorpho public immutable MORPHO;
    bytes32 public immutable MARKET_ID;
    address public immutable core;

    modifier onlyCore() {
        if (msg.sender != core) revert SepehrErrors.NotAuthorized();
        _;
    }

    constructor(
        address morpho,
        bytes32 marketId,
        address _core
    ) {
        if (morpho == address(0)) revert SepehrErrors.ZeroAddress();
        if (marketId == bytes32(0)) revert SepehrErrors.ZeroAddress();
        if (_core == address(0)) revert SepehrErrors.ZeroAddress();
        MORPHO = IMorpho(morpho);
        MARKET_ID = marketId;
        core = _core;
    }

    /// @inheritdoc IProtocolAdapter
    function getHealthFactor(
        address user
    ) external view returns (uint256) {
        IMorpho.Position memory pos = MORPHO.position(MARKET_ID, user);
        if (pos.borrowShares == 0) return type(uint256).max;

        IMorpho.Market memory mkt = MORPHO.market(MARKET_ID);
        IMorpho.MarketParams memory params = MORPHO.idToMarketParams(MARKET_ID);

        uint256 borrowAmount =
            uint256(pos.borrowShares) * uint256(mkt.totalBorrowAssets) / uint256(mkt.totalBorrowShares);

        uint256 oraclePrice = IMorphoOracle(params.oracle).price();

        uint256 collateralValue = uint256(pos.collateral) * oraclePrice / 1e36;

        return collateralValue * params.lltv / borrowAmount;
    }

    /// @inheritdoc IProtocolAdapter
    function checkDelegation(
        address user
    ) external view returns (bool delegated) {
        return MORPHO.isAuthorized(user, address(this));
    }

    /// @inheritdoc IProtocolAdapter
    function repay(
        address user,
        address debtAsset,
        uint256 amount
    ) external onlyCore {
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        IMorpho.MarketParams memory params = MORPHO.idToMarketParams(MARKET_ID);
        IERC20(debtAsset).forceApprove(address(MORPHO), amount);
        MORPHO.repay(params, amount, 0, user, "");
    }

    /// @inheritdoc IProtocolAdapter
    function withdrawCollateral(
        address user,
        address,
        uint256 amount,
        address recipient
    ) external onlyCore {
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        if (recipient == address(0)) revert SepehrErrors.ZeroAddress();
        IMorpho.MarketParams memory params = MORPHO.idToMarketParams(MARKET_ID);
        MORPHO.withdrawCollateral(params, amount, user, recipient);
    }

    /// @inheritdoc IProtocolAdapter
    function getCollateralValueUsd(
        address user
    ) external view returns (uint256 usdValue) {
        IMorpho.Position memory pos = MORPHO.position(MARKET_ID, user);
        IMorpho.MarketParams memory params = MORPHO.idToMarketParams(MARKET_ID);
        uint256 oraclePrice = IMorphoOracle(params.oracle).price();
        usdValue = uint256(pos.collateral) * oraclePrice / 1e36;
    }
}
