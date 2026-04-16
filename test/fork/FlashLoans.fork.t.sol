// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AaveFlashLoanProvider} from "../../src/flash/AaveFlashLoanProvider.sol";
import {BalancerFlashLoanProvider} from "../../src/flash/BalancerFlashLoanProvider.sol";
import {UniswapV3FlashLoanProvider} from "../../src/flash/UniswapV3FlashLoanProvider.sol";
import {IAegisCallback} from "../../src/interfaces/IAegisCallback.sol";
import {IFlashLoanProvider} from "../../src/interfaces/IFlashLoanProvider.sol";
import {ForkTestBase} from "./ForkTestBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Simple flash-loan callback that repays principal + fee back to the provider.
contract FlashLoanRepayer is IAegisCallback {
    address public lastAsset;
    uint256 public lastAmount;
    uint256 public lastFee;

    function onFlashLoan(
        address asset,
        uint256 amount,
        uint256 fee,
        bytes calldata
    ) external override {
        lastAsset = asset;
        lastAmount = amount;
        lastFee = fee;

        // Repay: transfer principal + fee back to the caller (the provider).
        // The provider holds the funds after our callback returns and handles
        // the actual repayment to the underlying pool.
        IERC20(asset).transfer(msg.sender, amount + fee);
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Aave V3 Flash Loan Fork Tests
// ═══════════════════════════════════════════════════════════════════════

contract AaveFlashLoanForkTest is ForkTestBase {
    address constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    AaveFlashLoanProvider internal provider;
    FlashLoanRepayer internal repayer;
    bool internal _forked;

    function setUp() public {
        _forked = _tryCreateFork("RPC_ETHEREUM_PRIMARY_HTTP");
        if (!_forked) return;

        provider = new AaveFlashLoanProvider(AAVE_V3_POOL);
        repayer = new FlashLoanRepayer();
    }

    function test_flashBorrow_usdcAndRepay() public {
        if (!_forked) return;

        uint256 borrowAmount = 100_000e6; // 100k USDC

        // Compute expected fee so we can pre-fund the repayer
        uint256 feeBps = provider.getFlashLoanFeeBps(USDC);
        uint256 expectedFee = borrowAmount * feeBps / 10_000;
        deal(USDC, address(repayer), expectedFee);

        provider.flashBorrow(USDC, borrowAmount, address(repayer), "");

        assertEq(repayer.lastAsset(), USDC, "Callback should receive USDC");
        assertEq(repayer.lastAmount(), borrowAmount, "Callback should receive the requested amount");
        assertEq(repayer.lastFee(), expectedFee, "Fee should match FLASHLOAN_PREMIUM_TOTAL");
    }

    function test_getFlashLoanFeeBps_matchesPoolPremium() public {
        if (!_forked) return;

        uint256 feeBps = provider.getFlashLoanFeeBps(USDC);
        // Aave V3 mainnet premium is typically 5 bps (0.05%)
        assertGt(feeBps, 0, "Flash loan fee should be > 0");
        assertLe(feeBps, 100, "Flash loan fee should be reasonable (< 1%)");
    }

    function test_isAvailable_returnsTrueForLiquidAsset() public {
        if (!_forked) return;

        // Aave pool should have plenty of USDC
        bool available = provider.isAvailable(USDC, 1000e6);
        assertTrue(available, "1000 USDC should be available in Aave V3 pool");
    }

    function test_isAvailable_returnsFalseForExcessiveAmount() public {
        if (!_forked) return;

        // Request an absurdly large amount that exceeds pool liquidity
        bool available = provider.isAvailable(USDC, type(uint128).max);
        assertFalse(available, "Excessive amount should not be available");
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Balancer Flash Loan Fork Tests
// ═══════════════════════════════════════════════════════════════════════

contract BalancerFlashLoanForkTest is ForkTestBase {
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    BalancerFlashLoanProvider internal provider;
    FlashLoanRepayer internal repayer;
    bool internal _forked;

    function setUp() public {
        _forked = _tryCreateFork("RPC_ETHEREUM_PRIMARY_HTTP");
        if (!_forked) return;

        provider = new BalancerFlashLoanProvider(BALANCER_VAULT);
        repayer = new FlashLoanRepayer();
    }

    function test_flashBorrow_wethAndRepay() public {
        if (!_forked) return;

        uint256 borrowAmount = 100 ether;

        // Compute expected fee and pre-fund
        uint256 feeBps = provider.getFlashLoanFeeBps(WETH);
        uint256 expectedFee = borrowAmount * feeBps / 10_000;
        // Balancer typically has 0 flash loan fees, but handle any fee
        if (expectedFee > 0) {
            deal(WETH, address(repayer), expectedFee);
        }

        provider.flashBorrow(WETH, borrowAmount, address(repayer), "");

        assertEq(repayer.lastAsset(), WETH, "Callback should receive WETH");
        assertEq(repayer.lastAmount(), borrowAmount, "Callback should receive the requested amount");
    }

    function test_getFlashLoanFeeBps_returnsReasonableValue() public {
        if (!_forked) return;

        uint256 feeBps = provider.getFlashLoanFeeBps(WETH);
        // Balancer typically has 0% flash loan fees
        assertLe(feeBps, 100, "Flash loan fee should be reasonable (<=1%)");
    }

    function test_isAvailable_wethIsLiquid() public {
        if (!_forked) return;

        bool available = provider.isAvailable(WETH, 10 ether);
        assertTrue(available, "10 WETH should be available in Balancer Vault");
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Uniswap V3 Flash Loan Fork Tests
// ═══════════════════════════════════════════════════════════════════════

contract UniswapV3FlashLoanForkTest is ForkTestBase {
    // USDC/WETH 0.3% pool
    address constant USDC_WETH_POOL = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    UniswapV3FlashLoanProvider internal provider;
    FlashLoanRepayer internal repayer;
    bool internal _forked;

    function setUp() public {
        _forked = _tryCreateFork("RPC_ETHEREUM_PRIMARY_HTTP");
        if (!_forked) return;

        provider = new UniswapV3FlashLoanProvider(USDC_WETH_POOL);
        repayer = new FlashLoanRepayer();
    }

    function test_flashBorrow_usdcFromPool() public {
        if (!_forked) return;

        uint256 borrowAmount = 50_000e6; // 50k USDC

        // Compute expected fee and pre-fund
        uint256 feeBps = provider.getFlashLoanFeeBps(USDC);
        uint256 expectedFee = borrowAmount * feeBps / 10_000;
        // Pool fee for 0.3% pool = 30 bps, so flash fee = 30 bps
        deal(USDC, address(repayer), expectedFee + 1e6); // slight buffer for rounding

        provider.flashBorrow(USDC, borrowAmount, address(repayer), "");

        assertEq(repayer.lastAsset(), USDC, "Callback should receive USDC");
        assertEq(repayer.lastAmount(), borrowAmount, "Callback should receive the requested amount");
        assertGt(repayer.lastFee(), 0, "Pool should charge a flash loan fee");
    }

    function test_getFlashLoanFeeBps_matchesPoolFee() public {
        if (!_forked) return;

        uint256 feeBps = provider.getFlashLoanFeeBps(USDC);
        // 0.3% pool fee = 3000 hundredths of a bip / 100 = 30 bps
        assertEq(feeBps, 30, "Fee should be 30 bps for a 0.3% pool");
    }

    function test_isAvailable_returnsFalseForNonPoolToken() public {
        if (!_forked) return;

        address DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        bool available = provider.isAvailable(DAI, 1000e18);
        assertFalse(available, "DAI should not be available in USDC/WETH pool");
    }

    function test_isAvailable_wethIsInPool() public {
        if (!_forked) return;

        bool available = provider.isAvailable(WETH, 10 ether);
        assertTrue(available, "10 WETH should be available in the USDC/WETH pool");
    }
}
