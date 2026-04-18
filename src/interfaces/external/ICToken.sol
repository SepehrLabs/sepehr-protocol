// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @notice Minimal Compound V2 cToken interface.
interface ICToken {
    function repayBorrowBehalf(
        address borrower,
        uint256 repayAmount
    ) external returns (uint256);

    function redeemUnderlying(
        uint256 redeemAmount
    ) external returns (uint256);

    function balanceOfUnderlying(
        address owner
    ) external returns (uint256);

    function borrowBalanceCurrent(
        address account
    ) external returns (uint256);

    function borrowBalanceStored(
        address account
    ) external view returns (uint256);

    function underlying() external view returns (address);

    function exchangeRateCurrent() external returns (uint256);

    function exchangeRateStored() external view returns (uint256);

    function balanceOf(
        address owner
    ) external view returns (uint256);
}

/// @notice Minimal Compound V2 Comptroller interface.
interface IComptroller {
    function getAccountLiquidity(
        address account
    ) external view returns (uint256 err, uint256 liquidity, uint256 shortfall);

    function oracle() external view returns (address);

    function getAssetsIn(
        address account
    ) external view returns (address[] memory);
}

/// @notice Minimal Compound V2 Oracle interface.
interface ICompoundOracle {
    function getUnderlyingPrice(
        address cToken
    ) external view returns (uint256);
}
