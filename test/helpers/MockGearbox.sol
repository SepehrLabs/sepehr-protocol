// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IBotList, ICreditFacade, ICreditManager} from "../../src/interfaces/external/IGearbox.sol";

/// @notice Mock Gearbox V3 Credit Manager for unit-testing GearboxAdapter.
contract MockCreditManager is ICreditManager {
    struct DebtAndCollateral {
        uint256 debt;
        uint256 cumulativeIndexLastUpdate;
        uint256 cumulativeIndexNow;
        uint256 enabledTokensMask;
        uint256 totalDebtUSD;
        uint256 totalValueUSD;
        uint256 twvUSD;
        uint256 hf;
    }

    address private _creditFacade;
    mapping(address => address) private _creditAccounts;
    mapping(address => DebtAndCollateral) private _debtAndCollateral;

    constructor(
        address facade
    ) {
        _creditFacade = facade;
    }

    // ── Setters ────────────────────────────────────────────────────────

    function setCreditAccount(
        address borrower,
        address creditAccount
    ) external {
        _creditAccounts[borrower] = creditAccount;
    }

    function setDebtAndCollateral(
        address creditAccount,
        uint256 debt,
        uint256 cumulativeIndexLastUpdate,
        uint256 cumulativeIndexNow,
        uint256 enabledTokensMask,
        uint256 totalDebtUSD,
        uint256 totalValueUSD,
        uint256 twvUSD,
        uint256 hf
    ) external {
        _debtAndCollateral[creditAccount] = DebtAndCollateral({
            debt: debt,
            cumulativeIndexLastUpdate: cumulativeIndexLastUpdate,
            cumulativeIndexNow: cumulativeIndexNow,
            enabledTokensMask: enabledTokensMask,
            totalDebtUSD: totalDebtUSD,
            totalValueUSD: totalValueUSD,
            twvUSD: twvUSD,
            hf: hf
        });
    }

    // ── ICreditManager implementation ──────────────────────────────────

    function creditFacade() external view override returns (address) {
        return _creditFacade;
    }

    function creditAccounts(
        address borrower
    ) external view override returns (address) {
        return _creditAccounts[borrower];
    }

    function calcDebtAndCollateral(
        address creditAccount,
        uint8
    )
        external
        view
        override
        returns (
            uint256 debt,
            uint256 cumulativeIndexLastUpdate,
            uint256 cumulativeIndexNow,
            uint256 enabledTokensMask,
            uint256 totalDebtUSD,
            uint256 totalValueUSD,
            uint256 twvUSD,
            uint256 hf
        )
    {
        DebtAndCollateral memory d = _debtAndCollateral[creditAccount];
        return (
            d.debt,
            d.cumulativeIndexLastUpdate,
            d.cumulativeIndexNow,
            d.enabledTokensMask,
            d.totalDebtUSD,
            d.totalValueUSD,
            d.twvUSD,
            d.hf
        );
    }
}

/// @notice Mock Gearbox V3 Credit Facade for unit-testing GearboxAdapter.
contract MockCreditFacade is ICreditFacade {
    struct MulticallRecord {
        address creditAccount;
        bytes[] calls;
    }

    struct BotMulticallRecord {
        address creditAccount;
        bytes[] calls;
    }

    MulticallRecord[] private _multicalls;
    BotMulticallRecord[] private _botMulticalls;

    function multicallCount() external view returns (uint256) {
        return _multicalls.length;
    }

    function botMulticallCount() external view returns (uint256) {
        return _botMulticalls.length;
    }

    function getBotMulticall(
        uint256 index
    ) external view returns (address creditAccount, bytes[] memory calls) {
        BotMulticallRecord storage r = _botMulticalls[index];
        return (r.creditAccount, r.calls);
    }

    function multicall(
        address creditAccount,
        bytes[] calldata calls
    ) external override {
        MulticallRecord storage r = _multicalls.push();
        r.creditAccount = creditAccount;
        for (uint256 i = 0; i < calls.length; i++) {
            r.calls.push(calls[i]);
        }
    }

    function botMulticall(
        address creditAccount,
        bytes[] calldata calls
    ) external override {
        BotMulticallRecord storage r = _botMulticalls.push();
        r.creditAccount = creditAccount;
        for (uint256 i = 0; i < calls.length; i++) {
            r.calls.push(calls[i]);
        }
    }
}

/// @notice Mock Gearbox V3 Bot List for unit-testing GearboxAdapter.
contract MockBotList is IBotList {
    struct BotStatus {
        uint192 permissions;
        bool forbidden;
        bool hasSpecialPermissions;
    }

    // creditManager => creditAccount => bot => status
    mapping(address => mapping(address => mapping(address => BotStatus))) private _botStatuses;

    function setBotStatus(
        address creditManager,
        address creditAccount,
        address bot,
        uint192 permissions,
        bool forbidden,
        bool hasSpecialPermissions
    ) external {
        _botStatuses[creditManager][creditAccount][bot] =
            BotStatus({permissions: permissions, forbidden: forbidden, hasSpecialPermissions: hasSpecialPermissions});
    }

    function getBotStatus(
        address creditManager,
        address creditAccount,
        address bot
    ) external view override returns (uint192 permissions, bool forbidden, bool hasSpecialPermissions) {
        BotStatus memory s = _botStatuses[creditManager][creditAccount][bot];
        return (s.permissions, s.forbidden, s.hasSpecialPermissions);
    }
}
