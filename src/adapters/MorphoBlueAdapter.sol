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

    /// @dev Morpho's fixed oracle price scale. `collateral * price / ORACLE_PRICE_SCALE`
    ///      yields loan-token base units, per Morpho's IOracle spec.
    uint256 private constant ORACLE_PRICE_SCALE = 1e36;
    /// @dev Morpho's WAD unit for lltv and HF scaling.
    uint256 private constant WAD = 1e18;

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
    /// @dev Reproduces Morpho's canonical liquidation check exactly, per
    ///      morpho-blue `_isHealthy`:
    ///        borrowed  = shares.toAssetsUp(totalBorrowAssets, totalBorrowShares)
    ///        maxBorrow = collateral * price / ORACLE_PRICE_SCALE * lltv / WAD
    ///        healthy   ⇔ borrowed ≤ maxBorrow
    ///      Returns `maxBorrow * WAD / borrowed`, i.e. HF scaled by WAD (1e18).
    ///      Rounds the borrow-side up to match Morpho's safety direction; our
    ///      trigger then fires marginally before Morpho liquidates.
    function getHealthFactor(
        address user
    ) external view returns (uint256) {
        IMorpho.Position memory pos = MORPHO.position(MARKET_ID, user);
        if (pos.borrowShares == 0) return type(uint256).max;

        IMorpho.Market memory mkt = MORPHO.market(MARKET_ID);
        IMorpho.MarketParams memory params = MORPHO.idToMarketParams(MARKET_ID);

        uint256 totalBorrowShares = uint256(mkt.totalBorrowShares);
        if (totalBorrowShares == 0) return type(uint256).max;

        // toAssetsUp: ceil(shares * totalAssets / totalShares)
        uint256 totalBorrowAssets = uint256(mkt.totalBorrowAssets);
        uint256 borrowed = (uint256(pos.borrowShares) * totalBorrowAssets + totalBorrowShares - 1) / totalBorrowShares;
        if (borrowed == 0) return type(uint256).max;

        uint256 oraclePrice = IMorphoOracle(params.oracle).price();
        uint256 collateralQuoted = uint256(pos.collateral) * oraclePrice / ORACLE_PRICE_SCALE;

        // HF_WAD = (collateralQuoted * lltv / WAD) * WAD / borrowed = collateralQuoted * lltv / borrowed
        return collateralQuoted * params.lltv / borrowed;
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

    /// @inheritdoc IProtocolAdapter
    /// @dev Converts the user's borrow shares to assets via the market's totals; 0 if the
    ///      market has no debt or `debtAsset` is not this market's loan token.
    function getDebt(
        address user,
        address debtAsset
    ) external view returns (uint256 debt) {
        IMorpho.MarketParams memory params = MORPHO.idToMarketParams(MARKET_ID);
        if (debtAsset != params.loanToken) return 0;
        IMorpho.Position memory pos = MORPHO.position(MARKET_ID, user);
        if (pos.borrowShares == 0) return 0;
        IMorpho.Market memory mkt = MORPHO.market(MARKET_ID);
        uint256 totalShares = uint256(mkt.totalBorrowShares);
        if (totalShares == 0) return 0;
        // Round up to match Morpho's internal accounting — this is the amount
        // the user owes, so under-reporting here would let an over-repay slip
        // past SepehrCore's repayPercentBps check.
        return (uint256(pos.borrowShares) * uint256(mkt.totalBorrowAssets) + totalShares - 1) / totalShares;
    }
}
