// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IProtocolAdapter} from "../interfaces/IProtocolAdapter.sol";
import {IChainlinkAggregator} from "../interfaces/external/IChainlinkAggregator.sol";
import {IMorpho, IMorphoIrm, IMorphoOracle} from "../interfaces/external/IMorpho.sol";
import {SepehrErrors} from "../libraries/SepehrErrors.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
/// @dev Audit B15 — Morpho oracle trust model: Morpho markets are immutable; the oracle
///      contract is fixed in the market's `params.oracle` at market creation, and is the
///      only price source feeding `getHealthFactor`. A Sepehr deployment therefore implicitly
///      whitelists a Morpho oracle by registering an adapter for that specific `MARKET_ID`.
///      Because `addAdapter` is timelock-gated, every Morpho oracle entering Sepehr gets a
///      ≥48h review window — operators MUST audit `idToMarketParams(MARKET_ID).oracle` for
///      manipulation resistance (push vs. pull, Chainlink-backed vs. custom, admin-mutability)
///      before registering the adapter. Belt-and-braces: SepehrCore.execute rejects HFs below
///      `MIN_PLAUSIBLE_HF_WAD`, so an oracle that reports "0" can't be used to extract fees
///      even if the adapter-level review misses a pathological source.
contract MorphoBlueAdapter is IProtocolAdapter {
    using SafeERC20 for IERC20;

    /// @dev Morpho's fixed oracle price scale. `collateral * price / ORACLE_PRICE_SCALE`
    ///      yields loan-token base units, per Morpho's IOracle spec.
    uint256 private constant ORACLE_PRICE_SCALE = 1e36;
    /// @dev Morpho's WAD unit for lltv and HF scaling.
    uint256 private constant WAD = 1e18;
    /// @dev Decimals of the Chainlink USD feeds SepehrCore works with (USD-8).
    uint8 private constant USD_FEED_DECIMALS = 8;

    IMorpho public immutable MORPHO;
    bytes32 public immutable MARKET_ID;
    address public immutable core;
    /// @notice M-4: Chainlink USD feed (8 decimals) of the market's loan token. Collateral is
    ///         quoted in loan-token units by Morpho's oracle; this feed turns it into USD-8,
    ///         the unit SepehrCore's tier caps, TVL cap and minimum collateral use.
    IChainlinkAggregator public immutable LOAN_TOKEN_USD_FEED;
    /// @dev 10 ** loanToken.decimals().
    uint256 private immutable LOAN_TOKEN_UNIT;

    modifier onlyCore() {
        if (msg.sender != core) revert SepehrErrors.NotAuthorized();
        _;
    }

    constructor(
        address morpho,
        bytes32 marketId,
        address loanTokenUsdFeed,
        address _core
    ) {
        if (morpho == address(0)) revert SepehrErrors.ZeroAddress();
        if (marketId == bytes32(0)) revert SepehrErrors.ZeroAddress();
        if (loanTokenUsdFeed == address(0)) revert SepehrErrors.ZeroAddress();
        if (_core == address(0)) revert SepehrErrors.ZeroAddress();
        uint8 feedDecimals = IChainlinkAggregator(loanTokenUsdFeed).decimals();
        if (feedDecimals != USD_FEED_DECIMALS) {
            revert SepehrErrors.InvalidOracleDecimals(feedDecimals, USD_FEED_DECIMALS);
        }
        MORPHO = IMorpho(morpho);
        MARKET_ID = marketId;
        LOAN_TOKEN_USD_FEED = IChainlinkAggregator(loanTokenUsdFeed);
        LOAN_TOKEN_UNIT = 10 ** IERC20Metadata(IMorpho(morpho).idToMarketParams(marketId).loanToken).decimals();
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

        // toAssetsUp: ceil(shares * totalAssets / totalShares), on the borrow total with the
        // interest accrued since the market's last update (I-5).
        uint256 totalBorrowAssets = _expectedTotalBorrowAssets(params, mkt);
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
    /// @dev Audit B12: Morpho `repay` caps at the user's outstanding debt shares; excess
    ///      `debtAsset` stays in the adapter and is swept back to Core.
    ///      Audit B17: the adapter previously approved `debtAsset` to Morpho but let Morpho pull
    ///      the market's `loanToken`. A mis-specified `debtAsset` left a stale approval on the
    ///      wrong token and reverted deep inside Morpho's transferFrom path. Fail fast instead.
    function repay(
        address user,
        address debtAsset,
        uint256 amount
    ) external onlyCore {
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        IMorpho.MarketParams memory params = MORPHO.idToMarketParams(MARKET_ID);
        if (debtAsset != params.loanToken) {
            revert SepehrErrors.DebtAssetMismatch(params.loanToken, debtAsset);
        }
        IERC20(debtAsset).forceApprove(address(MORPHO), amount);
        // Lot 6: a repayment that covers the whole debt (a close) repays every borrow share.
        // Repaid as assets, Morpho's rounding into shares would leave dust of debt behind, which
        // blocks withdrawing all the collateral, or round past the position's shares and revert.
        uint256 debt = _debt(params, user);
        if (debt != 0 && amount >= debt) {
            MORPHO.repay(params, 0, MORPHO.position(MARKET_ID, user).borrowShares, user, "");
        } else {
            MORPHO.repay(params, amount, 0, user, "");
        }
        IERC20(debtAsset).forceApprove(address(MORPHO), 0);
        uint256 surplus = IERC20(debtAsset).balanceOf(address(this));
        if (surplus > 0) {
            IERC20(debtAsset).safeTransfer(core, surplus);
        }
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev Audit B22: validate `collateralAsset` against the market's `collateralToken`.
    ///      The adapter is bound to a single `MARKET_ID`, so any other token is a keeper bug
    ///      or malicious input; reject before touching Morpho so the revert surfaces the mismatch.
    function withdrawCollateral(
        address user,
        address collateralAsset,
        uint256 amount,
        address recipient
    ) external onlyCore {
        if (amount == 0) revert SepehrErrors.ZeroAmount();
        if (recipient == address(0)) revert SepehrErrors.ZeroAddress();
        IMorpho.MarketParams memory params = MORPHO.idToMarketParams(MARKET_ID);
        if (collateralAsset != params.collateralToken) {
            revert SepehrErrors.CollateralAssetMismatch(params.collateralToken, collateralAsset);
        }
        MORPHO.withdrawCollateral(params, amount, user, recipient);
    }

    /// @inheritdoc IProtocolAdapter
    /// @dev M-4: Morpho's oracle quotes collateral in loan-token units; the loan token's USD
    ///      feed converts that to USD-8. Returning loan-token units (USDC: 6 decimals) put the
    ///      value 100x below every USD-8 threshold SepehrCore compares it with.
    function getCollateralValueUsd(
        address user
    ) external view returns (uint256 usdValue) {
        IMorpho.Position memory pos = MORPHO.position(MARKET_ID, user);
        IMorpho.MarketParams memory params = MORPHO.idToMarketParams(MARKET_ID);
        uint256 oraclePrice = IMorphoOracle(params.oracle).price();
        uint256 loanUnits = uint256(pos.collateral) * oraclePrice / ORACLE_PRICE_SCALE;
        (, int256 answer,,,) = LOAN_TOKEN_USD_FEED.latestRoundData();
        if (answer <= 0) revert SepehrErrors.InvalidOraclePrice(params.loanToken, answer);
        usdValue = Math.mulDiv(loanUnits, uint256(answer), LOAN_TOKEN_UNIT);
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
        return _debt(params, user);
    }

    /// @dev What `user` owes in the market, interest accrued, rounded up as Morpho rounds it.
    function _debt(
        IMorpho.MarketParams memory params,
        address user
    ) internal view returns (uint256) {
        IMorpho.Position memory pos = MORPHO.position(MARKET_ID, user);
        if (pos.borrowShares == 0) return 0;
        IMorpho.Market memory mkt = MORPHO.market(MARKET_ID);
        uint256 totalShares = uint256(mkt.totalBorrowShares);
        if (totalShares == 0) return 0;
        // Round up to match Morpho's internal accounting — this is the amount
        // the user owes, so under-reporting here would let an over-repay slip
        // past SepehrCore's MAX_REPAY_BPS check. I-5: includes accrued interest.
        return (uint256(pos.borrowShares) * _expectedTotalBorrowAssets(params, mkt) + totalShares - 1) / totalShares;
    }

    /// @notice I-5: the market's borrow total with the interest accrued since its last update,
    ///         the way Morpho's `_accrueInterest` will book it (MorphoBalancesLib).
    /// @dev Without it the HF and the debt were read on a stale total, so the HF was slightly
    ///      overstated and a trigger fired late. A market without an IRM accrues nothing.
    function _expectedTotalBorrowAssets(
        IMorpho.MarketParams memory params,
        IMorpho.Market memory mkt
    ) internal view returns (uint256) {
        uint256 totalBorrowAssets = uint256(mkt.totalBorrowAssets);
        uint256 elapsed = block.timestamp - uint256(mkt.lastUpdate);
        if (elapsed == 0 || totalBorrowAssets == 0 || params.irm == address(0)) return totalBorrowAssets;
        uint256 borrowRate = IMorphoIrm(params.irm).borrowRateView(params, mkt);
        // wTaylorCompounded(rate, elapsed): e^(rate*elapsed) - 1 to the third order, in WAD.
        uint256 firstTerm = borrowRate * elapsed;
        uint256 secondTerm = Math.mulDiv(firstTerm, firstTerm, 2 * WAD);
        uint256 thirdTerm = Math.mulDiv(secondTerm, firstTerm, 3 * WAD);
        return totalBorrowAssets + Math.mulDiv(totalBorrowAssets, firstTerm + secondTerm + thirdTerm, WAD);
    }
}
