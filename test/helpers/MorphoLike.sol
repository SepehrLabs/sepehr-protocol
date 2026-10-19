// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMorpho, IMorphoOracle} from "../../src/interfaces/external/IMorpho.sol";

/// @notice Morpho-style oracle: price of one collateral unit in loan-token units, scaled by
/// 1e36 * 10^(loanDecimals - collateralDecimals). For WETH(18)/USDC(6): price = USD * 1e24.
contract MorphoLikeOracle is IMorphoOracle {
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

/// @notice Simplified Morpho Blue market WITH real accounting (unlike `MockMorpho`, which only
/// records calls), so the real MorphoBlueAdapter and SepehrCore run end to end:
///   - one borrow share = one unit of the loan asset (no interest);
///   - `repay` reduces the debt and reverts on over-repayment, like Morpho;
///   - `withdrawCollateral` moves the collateral and requires a healthy position afterwards
///     (same rule as Morpho's `_isHealthy`).
contract MorphoLike is IMorpho {
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;
    uint256 internal constant WAD = 1e18;

    mapping(bytes32 => MarketParams) internal _params;
    mapping(bytes32 => Market) internal _market;
    mapping(bytes32 => mapping(address => Position)) internal _pos;
    mapping(address => mapping(address => bool)) internal _auth;

    function marketId(
        MarketParams memory p
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(p));
    }

    function createMarket(
        MarketParams memory p
    ) external returns (bytes32 id) {
        id = marketId(p);
        _params[id] = p;
        _market[id].lastUpdate = uint128(block.timestamp);
    }

    function setAuthorization(
        address authorized,
        bool value
    ) external {
        _auth[msg.sender][authorized] = value;
    }

    function supplyCollateral(
        MarketParams memory p,
        uint256 assets,
        address onBehalf
    ) external {
        bytes32 id = marketId(p);
        IERC20(p.collateralToken).transferFrom(msg.sender, address(this), assets);
        _pos[id][onBehalf].collateral += uint128(assets);
    }

    function borrow(
        MarketParams memory p,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external {
        bytes32 id = marketId(p);
        require(msg.sender == onBehalf || _auth[onBehalf][msg.sender], "MorphoLike: unauthorized");
        _pos[id][onBehalf].borrowShares += uint128(assets);
        _market[id].totalBorrowAssets += uint128(assets);
        _market[id].totalBorrowShares += uint128(assets);
        require(isHealthy(id, onBehalf), "MorphoLike: insufficient collateral");
        IERC20(p.loanToken).transfer(receiver, assets);
    }

    function repay(
        MarketParams memory p,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory
    ) external returns (uint256, uint256) {
        bytes32 id = marketId(p);
        // One share per asset here: repaying by shares repays as many assets.
        if (shares != 0) assets = shares;
        // Like Morpho: repaying more than the debt underflows and reverts.
        _pos[id][onBehalf].borrowShares -= uint128(assets);
        _market[id].totalBorrowAssets -= uint128(assets);
        _market[id].totalBorrowShares -= uint128(assets);
        IERC20(p.loanToken).transferFrom(msg.sender, address(this), assets);
        return (assets, assets);
    }

    function withdrawCollateral(
        MarketParams memory p,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external {
        bytes32 id = marketId(p);
        require(msg.sender == onBehalf || _auth[onBehalf][msg.sender], "MorphoLike: unauthorized");
        _pos[id][onBehalf].collateral -= uint128(assets);
        require(isHealthy(id, onBehalf), "MorphoLike: insufficient collateral");
        IERC20(p.collateralToken).transfer(receiver, assets);
    }

    /// @notice Same rule as Morpho `_isHealthy`: borrowed <= collateral * price / 1e36 * lltv / 1e18.
    function isHealthy(
        bytes32 id,
        address user
    ) public view returns (bool) {
        Position memory ps = _pos[id][user];
        if (ps.borrowShares == 0) return true;
        uint256 px = IMorphoOracle(_params[id].oracle).price();
        uint256 maxBorrow = uint256(ps.collateral) * px / ORACLE_PRICE_SCALE * _params[id].lltv / WAD;
        return maxBorrow >= ps.borrowShares;
    }

    function isAuthorized(
        address authorizer,
        address authorized
    ) external view returns (bool) {
        return _auth[authorizer][authorized];
    }

    function position(
        bytes32 id,
        address user
    ) external view returns (Position memory) {
        return _pos[id][user];
    }

    function market(
        bytes32 id
    ) external view returns (Market memory) {
        return _market[id];
    }

    function idToMarketParams(
        bytes32 id
    ) external view returns (MarketParams memory) {
        return _params[id];
    }
}
