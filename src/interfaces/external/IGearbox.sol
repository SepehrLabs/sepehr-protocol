// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @notice Minimal Gearbox V3 Credit Facade interface.
interface ICreditFacade {
    function multicall(
        address creditAccount,
        bytes[] calldata calls
    ) external;

    function botMulticall(
        address creditAccount,
        bytes[] calldata calls
    ) external;
}

/// @notice Minimal Gearbox V3 Credit Manager interface.
interface ICreditManager {
    function creditFacade() external view returns (address);

    function creditAccounts(
        address borrower
    ) external view returns (address);

    function calcDebtAndCollateral(
        address creditAccount,
        uint8 task
    )
        external
        view
        returns (
            uint256 debt,
            uint256 cumulativeIndexLastUpdate,
            uint256 cumulativeIndexNow,
            uint256 enabledTokensMask,
            uint256 totalDebtUSD,
            uint256 totalValueUSD,
            uint256 twvUSD,
            uint256 hf
        );
}

/// @notice Minimal Gearbox V3 Bot List interface.
interface IBotList {
    function getBotStatus(
        address creditManager,
        address creditAccount,
        address bot
    ) external view returns (uint192 permissions, bool forbidden, bool hasSpecialPermissions);
}
