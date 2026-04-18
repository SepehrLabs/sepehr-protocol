// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {UniswapV3FlashLoanProvider} from "../../../src/flash/UniswapV3FlashLoanProvider.sol";
import {SepehrErrors} from "../../../src/libraries/SepehrErrors.sol";
import {MockERC20} from "../../helpers/MockERC20.sol";
import {MockUniswapV3Pool} from "../../helpers/MockUniswapV3Pool.sol";
import {SimpleCallback} from "../../helpers/SimpleCallback.sol";
import {Test} from "forge-std/Test.sol";

contract UniswapV3FlashLoanProviderTest is Test {
    UniswapV3FlashLoanProvider provider;
    MockUniswapV3Pool pool;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 tokenC;
    SimpleCallback callback;

    uint24 constant POOL_FEE = 3000; // 0.3% = 30 bps
    uint256 constant POOL_LIQUIDITY = 1_000_000e18;
    uint256 constant BORROW_AMOUNT = 100e18;

    function setUp() public {
        tokenA = new MockERC20("WETH", "WETH");
        tokenB = new MockERC20("USDC", "USDC");
        tokenC = new MockERC20("DAI", "DAI");
        callback = new SimpleCallback();

        pool = new MockUniswapV3Pool(address(tokenA), address(tokenB), POOL_FEE);
        provider = new UniswapV3FlashLoanProvider(address(pool));

        tokenA.mint(address(pool), POOL_LIQUIDITY);
        tokenB.mint(address(pool), POOL_LIQUIDITY);
    }

    // ── Constructor ──────────────────────────────────────────────────────

    function test_constructor_setsPool() public view {
        assertEq(address(provider.POOL()), address(pool));
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        new UniswapV3FlashLoanProvider(address(0));
    }

    // ── flashBorrow token0 ───────────────────────────────────────────────

    function test_flashBorrow_token0_successfulBorrowAndRepay() public {
        // fee = 100e18 * 3000 / 1_000_000 = 0.3e18
        uint256 expectedFee = (BORROW_AMOUNT * POOL_FEE) / 1_000_000;
        tokenA.mint(address(callback), expectedFee);

        provider.flashBorrow(address(tokenA), BORROW_AMOUNT, address(callback), "t0_data");

        assertEq(callback.lastAsset(), address(tokenA));
        assertEq(callback.lastAmount(), BORROW_AMOUNT);
        assertEq(callback.lastFee(), expectedFee);
        assertEq(callback.lastData(), "t0_data");
    }

    // ── flashBorrow token1 ───────────────────────────────────────────────

    function test_flashBorrow_token1_successfulBorrowAndRepay() public {
        uint256 expectedFee = (BORROW_AMOUNT * POOL_FEE) / 1_000_000;
        tokenB.mint(address(callback), expectedFee);

        provider.flashBorrow(address(tokenB), BORROW_AMOUNT, address(callback), "t1_data");

        assertEq(callback.lastAsset(), address(tokenB));
        assertEq(callback.lastAmount(), BORROW_AMOUNT);
        assertEq(callback.lastFee(), expectedFee);
        assertEq(callback.lastData(), "t1_data");
    }

    // ── flashBorrow unsupported ──────────────────────────────────────────

    function test_flashBorrow_revertsOnUnsupportedAsset() public {
        vm.expectRevert(SepehrErrors.NoFlashLoanAvailable.selector);
        provider.flashBorrow(address(tokenC), BORROW_AMOUNT, address(callback), "");
    }

    function test_flashBorrow_revertsOnZeroCallback() public {
        vm.expectRevert(SepehrErrors.ZeroAddress.selector);
        provider.flashBorrow(address(tokenA), BORROW_AMOUNT, address(0), "");
    }

    function test_flashBorrow_revertsOnZeroAmount() public {
        vm.expectRevert(SepehrErrors.ZeroAmount.selector);
        provider.flashBorrow(address(tokenA), 0, address(callback), "");
    }

    function test_flashBorrow_revertsWhenCallbackDoesNotRepay() public {
        callback.setShouldRepay(false);
        vm.expectRevert();
        provider.flashBorrow(address(tokenA), BORROW_AMOUNT, address(callback), "");
    }

    function test_flashBorrow_clearsActiveStateAfterSuccess() public {
        uint256 fee = (BORROW_AMOUNT * POOL_FEE) / 1_000_000;
        tokenA.mint(address(callback), fee * 2);

        provider.flashBorrow(address(tokenA), BORROW_AMOUNT, address(callback), "first");
        provider.flashBorrow(address(tokenA), BORROW_AMOUNT, address(callback), "second");
        assertEq(callback.lastData(), "second");
    }

    // ── uniswapV3FlashCallback ───────────────────────────────────────────

    function test_uniswapV3FlashCallback_revertsIfCallerNotPool() public {
        vm.expectRevert(SepehrErrors.InvalidFlashLoanCallback.selector);
        provider.uniswapV3FlashCallback(0, 0, "");
    }

    function test_uniswapV3FlashCallback_revertsIfNoActiveLoan() public {
        vm.prank(address(pool));
        vm.expectRevert(SepehrErrors.InvalidFlashLoanCallback.selector);
        provider.uniswapV3FlashCallback(0, 0, "");
    }

    // ── getFlashLoanFeeBps ───────────────────────────────────────────────

    function test_getFlashLoanFeeBps_convertsCorrectly() public view {
        // pool fee 3000 (hundredths of a bip) / 100 = 30 bps
        assertEq(provider.getFlashLoanFeeBps(address(tokenA)), 30);
    }

    function test_getFlashLoanFeeBps_500feeTier() public {
        MockUniswapV3Pool pool500 = new MockUniswapV3Pool(address(tokenA), address(tokenB), 500);
        UniswapV3FlashLoanProvider provider500 = new UniswapV3FlashLoanProvider(address(pool500));
        assertEq(provider500.getFlashLoanFeeBps(address(tokenA)), 5);
    }

    function test_getFlashLoanFeeBps_10000feeTier() public {
        MockUniswapV3Pool pool10k = new MockUniswapV3Pool(address(tokenA), address(tokenB), 10_000);
        UniswapV3FlashLoanProvider provider10k = new UniswapV3FlashLoanProvider(address(pool10k));
        assertEq(provider10k.getFlashLoanFeeBps(address(tokenA)), 100);
    }

    function test_getFlashLoanFeeBps_100feeTier() public {
        MockUniswapV3Pool pool100 = new MockUniswapV3Pool(address(tokenA), address(tokenB), 100);
        UniswapV3FlashLoanProvider provider100 = new UniswapV3FlashLoanProvider(address(pool100));
        assertEq(provider100.getFlashLoanFeeBps(address(tokenA)), 1);
    }

    // C4: non-canonical fee tiers must revert rather than silently rounding.
    function test_getFlashLoanFeeBps_revertsOnNonCanonicalFee() public {
        MockUniswapV3Pool oddPool = new MockUniswapV3Pool(address(tokenA), address(tokenB), 450);
        UniswapV3FlashLoanProvider oddProvider = new UniswapV3FlashLoanProvider(address(oddPool));
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.UnsupportedPoolFee.selector, uint24(450)));
        oddProvider.getFlashLoanFeeBps(address(tokenA));
    }

    function test_getFlashLoanFeeBps_revertsOnZeroDynamicFee() public {
        MockUniswapV3Pool zeroPool = new MockUniswapV3Pool(address(tokenA), address(tokenB), 0);
        UniswapV3FlashLoanProvider zeroProvider = new UniswapV3FlashLoanProvider(address(zeroPool));
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.UnsupportedPoolFee.selector, uint24(0)));
        zeroProvider.getFlashLoanFeeBps(address(tokenA));
    }

    // C2: a re-entrant flashBorrow must revert rather than overwrite the callback slot.
    function test_flashBorrow_revertsOnConcurrentInvocation() public {
        uint256 fee = (BORROW_AMOUNT * POOL_FEE) / 1_000_000;
        tokenA.mint(address(callback), fee);
        callback.setReentrantProvider(address(provider));
        callback.setReentrantAsset(address(tokenA));
        callback.setReentrantAmount(BORROW_AMOUNT);
        callback.setReentrantTrigger(true);

        vm.expectRevert();
        provider.flashBorrow(address(tokenA), BORROW_AMOUNT, address(callback), "");
    }

    // ── isAvailable ──────────────────────────────────────────────────────

    function test_isAvailable_trueForToken0WithEnoughBalance() public view {
        assertTrue(provider.isAvailable(address(tokenA), BORROW_AMOUNT));
    }

    function test_isAvailable_trueForToken1WithEnoughBalance() public view {
        assertTrue(provider.isAvailable(address(tokenB), BORROW_AMOUNT));
    }

    function test_isAvailable_falseForUnsupportedAsset() public view {
        assertFalse(provider.isAvailable(address(tokenC), BORROW_AMOUNT));
    }

    function test_isAvailable_falseWhenInsufficientLiquidity() public view {
        assertFalse(provider.isAvailable(address(tokenA), POOL_LIQUIDITY + 1));
    }

    function test_isAvailable_falseWhenPoolLocked() public {
        // C6: isAvailable must return false while slot0.unlocked == false,
        // so the selector doesn't pick this provider mid-swap and waste a
        // top-level flashBorrow on a pool that would revert with `LOK`.
        pool.setUnlocked(false);
        assertFalse(provider.isAvailable(address(tokenA), BORROW_AMOUNT));
        pool.setUnlocked(true);
        assertTrue(provider.isAvailable(address(tokenA), BORROW_AMOUNT));
    }

    // ── Fuzz ─────────────────────────────────────────────────────────────

    function testFuzz_flashBorrow_correctFeeForToken0(
        uint128 amount
    ) public {
        vm.assume(amount > 0 && amount <= POOL_LIQUIDITY);
        uint256 expectedFee = _mulDivRoundUp(uint256(amount), POOL_FEE, 1_000_000);
        tokenA.mint(address(callback), expectedFee);

        provider.flashBorrow(address(tokenA), uint256(amount), address(callback), "fuzz");
        assertEq(callback.lastFee(), expectedFee);
    }

    function _mulDivRoundUp(
        uint256 a,
        uint256 b,
        uint256 d
    ) internal pure returns (uint256) {
        uint256 result = (a * b) / d;
        if ((a * b) % d > 0) result++;
        return result;
    }
}
