// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

/// @notice Minimal Morpho Blue interface.
interface IMorpho {
    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }

    struct Position {
        uint256 supplyShares;
        uint128 borrowShares;
        uint128 collateral;
    }

    struct Market {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint128 lastUpdate;
        uint128 fee;
    }

    function isAuthorized(
        address authorizer,
        address authorized
    ) external view returns (bool);

    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 assetsRepaid, uint256 sharesRepaid);

    function withdrawCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external;

    function position(
        bytes32 id,
        address user
    ) external view returns (Position memory);

    function market(
        bytes32 id
    ) external view returns (Market memory);

    function idToMarketParams(
        bytes32 id
    ) external view returns (MarketParams memory);
}

/// @notice Minimal Morpho oracle interface (IOracle pattern).
interface IMorphoOracle {
    function price() external view returns (uint256);
}
