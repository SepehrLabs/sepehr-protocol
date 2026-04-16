// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {GearboxAdapter} from "../../src/adapters/GearboxAdapter.sol";
import {IBotList, ICreditFacade, ICreditManager} from "../../src/interfaces/external/IGearbox.sol";
import {ForkTestBase} from "./ForkTestBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract GearboxAdapterForkTest is ForkTestBase {
    // --- Ethereum mainnet addresses ---
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    GearboxAdapter internal adapter;
    bool internal _forked;
    address internal user;
    address internal mockCreditManager;
    address internal mockBotList;
    address internal mockCreditAccount;
    address internal mockFacade;

    function setUp() public {
        _forked = _tryCreateFork("RPC_ETHEREUM_PRIMARY_HTTP");
        if (!_forked) return;

        user = makeAddr("gearboxUser");
        mockCreditManager = makeAddr("gearboxCM");
        mockBotList = makeAddr("gearboxBotList");
        mockCreditAccount = makeAddr("gearboxCreditAccount");
        mockFacade = makeAddr("gearboxFacade");

        adapter = new GearboxAdapter(mockCreditManager, mockBotList);
    }

    // ─── getHealthFactor ──────────────────────────────────────────────

    function test_getHealthFactor_returnsMaxWhenNoCreditAccount() public {
        if (!_forked) return;

        vm.mockCall(
            mockCreditManager,
            abi.encodeWithSelector(ICreditManager.creditAccounts.selector, user),
            abi.encode(address(0))
        );

        uint256 hf = adapter.getHealthFactor(user);
        assertEq(hf, type(uint256).max, "No credit account should return max HF");
    }

    function test_getHealthFactor_convertsFromBasisPointsToWad() public {
        if (!_forked) return;

        // Mock creditAccounts to return a valid credit account
        vm.mockCall(
            mockCreditManager,
            abi.encodeWithSelector(ICreditManager.creditAccounts.selector, user),
            abi.encode(mockCreditAccount)
        );

        // Mock calcDebtAndCollateral: hf = 15_000 bps = 1.5x
        // Returns 8 values: debt, cumulIndexLast, cumulIndexNow, mask, totalDebtUSD, totalValueUSD, twvUSD, hf
        vm.mockCall(
            mockCreditManager,
            abi.encodeWithSelector(ICreditManager.calcDebtAndCollateral.selector, mockCreditAccount, uint8(1)),
            abi.encode(
                uint256(1000e18), // debt
                uint256(1e27), // cumulativeIndexLastUpdate
                uint256(1e27), // cumulativeIndexNow
                uint256(1), // enabledTokensMask
                uint256(1000e8), // totalDebtUSD
                uint256(1500e8), // totalValueUSD
                uint256(1200e8), // twvUSD
                uint256(15_000) // hf in bps (1.5x)
            )
        );

        uint256 hf = adapter.getHealthFactor(user);
        // 15_000 bps * 1e14 = 1.5e18
        assertEq(hf, 1.5e18, "Health factor should convert from bps to WAD");
    }

    function test_getHealthFactor_returnsOneAtLiquidation() public {
        if (!_forked) return;

        vm.mockCall(
            mockCreditManager,
            abi.encodeWithSelector(ICreditManager.creditAccounts.selector, user),
            abi.encode(mockCreditAccount)
        );

        // hf = 10_000 bps = 1.0x (liquidation boundary)
        vm.mockCall(
            mockCreditManager,
            abi.encodeWithSelector(ICreditManager.calcDebtAndCollateral.selector, mockCreditAccount, uint8(1)),
            abi.encode(
                uint256(1000e18),
                uint256(1e27),
                uint256(1e27),
                uint256(1),
                uint256(1000e8),
                uint256(1000e8),
                uint256(1000e8),
                uint256(10_000) // hf = exactly 1.0
            )
        );

        uint256 hf = adapter.getHealthFactor(user);
        assertEq(hf, 1e18, "Health factor should be 1e18 at liquidation boundary");
    }

    // ─── checkDelegation ──────────────────────────────────────────────

    function test_checkDelegation_returnsFalseWhenNoCreditAccount() public {
        if (!_forked) return;

        vm.mockCall(
            mockCreditManager,
            abi.encodeWithSelector(ICreditManager.creditAccounts.selector, user),
            abi.encode(address(0))
        );

        assertFalse(adapter.checkDelegation(user), "No credit account means no delegation");
    }

    function test_checkDelegation_returnsTrueWhenBotPermitted() public {
        if (!_forked) return;

        vm.mockCall(
            mockCreditManager,
            abi.encodeWithSelector(ICreditManager.creditAccounts.selector, user),
            abi.encode(mockCreditAccount)
        );

        // permissions > 0, not forbidden, no special permissions
        vm.mockCall(
            mockBotList,
            abi.encodeWithSelector(
                IBotList.getBotStatus.selector, address(mockCreditManager), mockCreditAccount, address(adapter)
            ),
            abi.encode(uint192(1), false, false)
        );

        assertTrue(adapter.checkDelegation(user), "Should be delegated when bot has permissions");
    }

    function test_checkDelegation_returnsFalseWhenForbidden() public {
        if (!_forked) return;

        vm.mockCall(
            mockCreditManager,
            abi.encodeWithSelector(ICreditManager.creditAccounts.selector, user),
            abi.encode(mockCreditAccount)
        );

        // permissions > 0 but forbidden = true
        vm.mockCall(
            mockBotList,
            abi.encodeWithSelector(
                IBotList.getBotStatus.selector, address(mockCreditManager), mockCreditAccount, address(adapter)
            ),
            abi.encode(uint192(1), true, false)
        );

        assertFalse(adapter.checkDelegation(user), "Should not be delegated when bot is forbidden");
    }

    // ─── getCollateralValueUsd ────────────────────────────────────────

    function test_getCollateralValueUsd_returnsZeroWithoutCreditAccount() public {
        if (!_forked) return;

        vm.mockCall(
            mockCreditManager,
            abi.encodeWithSelector(ICreditManager.creditAccounts.selector, user),
            abi.encode(address(0))
        );

        uint256 usdValue = adapter.getCollateralValueUsd(user);
        assertEq(usdValue, 0, "No credit account should have 0 collateral value");
    }
}
