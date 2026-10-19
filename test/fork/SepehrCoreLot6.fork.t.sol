// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SepehrCore} from "../../src/SepehrCore.sol";
import {SepehrSubscriptions} from "../../src/SepehrSubscriptions.sol";
import {AaveV3Adapter} from "../../src/adapters/AaveV3Adapter.sol";
import {UniswapV3Router} from "../../src/dex/UniswapV3Router.sol";
import {MorphoBlueFlashLoanProvider} from "../../src/flash/MorphoBlueFlashLoanProvider.sol";
import {ISepehrCore} from "../../src/interfaces/ISepehrCore.sol";
import {IChainlinkAggregator} from "../../src/interfaces/external/IChainlinkAggregator.sol";
import {SepehrErrors} from "../../src/libraries/SepehrErrors.sol";
import {ForkTestBase} from "./ForkTestBase.sol";

interface IAavePoolLot6 {
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external;

    function getReserveData(
        address asset
    )
        external
        view
        returns (
            uint256,
            uint128,
            uint128,
            uint128,
            uint128,
            uint128,
            uint40,
            uint16,
            address aToken,
            address,
            address variableDebtToken,
            address,
            uint128,
            uint128,
            uint128
        );
}

/// @title Lot 6 on Arbitrum One: a stop-loss close and a rescue paid from the wallet, through
/// the real Aave V3 market, Morpho Blue flash loan, Uniswap V3 pool and Chainlink feeds.
/// @dev Skipped without `RPC_ARBITRUM_PRIMARY_HTTP`. Run with `--profile fork-arbitrum`.
contract SepehrCoreLot6ArbitrumForkTest is ForkTestBase {
    address constant POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant MORPHO = 0x6c247b1F6182318877311737BaC0844bAa518F5e;
    address constant SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address constant USDC_USD = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    bytes32 constant AAVE_KEY = keccak256("aave-v3-arbitrum");

    SepehrCore internal core;
    AaveV3Adapter internal adapter;
    MorphoBlueFlashLoanProvider internal morphoFlash;
    UniswapV3Router internal router;
    bool internal forked;
    address internal keeper = makeAddr("keeper");
    address internal user = makeAddr("lot6User");

    function setUp() public {
        forked = _tryCreateFork("RPC_ARBITRUM_PRIMARY_HTTP");
        if (!forked) return;

        address nextCore = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        SepehrSubscriptions subs = new SepehrSubscriptions(address(this), address(this), USDC, block.chainid, nextCore);
        core = new SepehrCore(
            address(this), address(this), address(this), address(subs), 0, type(uint256).max, block.chainid
        );
        adapter = new AaveV3Adapter(POOL, address(core));
        morphoFlash = new MorphoBlueFlashLoanProvider(MORPHO, address(this));
        router = new UniswapV3Router(SWAP_ROUTER, FACTORY, 500);
        core.addAdapter(AAVE_KEY, address(adapter));
        core.addFlashLoanProvider(address(morphoFlash));
        core.addDexRouter(address(router));
        core.addKeeper(keeper);
        core.setAssetOracle(WETH, ETH_USD, 1 days);
        core.setAssetOracle(USDC, USDC_USD, 1 days);
        subs.grantTitanSubscription(user, 30 days);
    }

    function _aToken() internal view returns (address aToken) {
        (,,,,,,,, aToken,,,,,,) = IAavePoolLot6(POOL).getReserveData(WETH);
    }

    function _debtToken() internal view returns (address debtToken) {
        (,,,,,,,,,, debtToken,,,,) = IAavePoolLot6(POOL).getReserveData(USDC);
    }

    /// @dev 3 WETH supplied and USDC borrowed to `healthFactor`, the aWETH approved to the
    /// adapter, protection on.
    function _openPosition(
        uint256 healthFactor,
        uint256 thresholdHF,
        uint256 targetHF
    ) internal {
        deal(WETH, user, 3 ether);
        vm.startPrank(user);
        IERC20(WETH).approve(POOL, 3 ether);
        IAavePoolLot6(POOL).supply(WETH, 3 ether, user, 0);
        // A first borrow tells the weighted collateral (`HF × debt`); the second brings the
        // debt to the one that gives `healthFactor`.
        IAavePoolLot6(POOL).borrow(USDC, 1000e6, 2, 0, user);
        uint256 debt = IERC20(_debtToken()).balanceOf(user);
        uint256 weighted = adapter.getHealthFactor(user) * debt;
        IAavePoolLot6(POOL).borrow(USDC, weighted / healthFactor - debt, 2, 0, user);
        IERC20(_aToken()).approve(address(adapter), type(uint256).max);
        core.enableProtection(AAVE_KEY, thresholdHF, 100, targetHF);
        vm.stopPrank();
    }

    function _providers() internal view returns (address[] memory providers) {
        providers = new address[](1);
        providers[0] = address(morphoFlash);
    }

    function test_close_atTheStopLoss_repaysAaveSellsTheWethAndPaysTheRest() public {
        if (!forked) return;
        _openPosition(1.6e18, 1.2e18, 1.5e18);
        (, int256 answer,,,) = IChainlinkAggregator(ETH_USD).latestRoundData();
        uint256 price = uint256(answer);
        // A stop-loss just above the price: the feed is at it already.
        vm.prank(user);
        core.setExitOrder(AAVE_KEY, WETH, price + 1, 0);

        uint256 debt = IERC20(_debtToken()).balanceOf(user);
        uint256 collateral = IERC20(_aToken()).balanceOf(user);
        uint256 usdcBefore = IERC20(USDC).balanceOf(user);
        vm.prank(keeper);
        core.close(user, AAVE_KEY, USDC, WETH, collateral, _providers(), address(router), "");

        assertEq(IERC20(_debtToken()).balanceOf(user), 0, "the whole debt repaid");
        assertEq(IERC20(_aToken()).balanceOf(user), 0, "all the WETH sold");
        // 3 WETH at the feed's price, less the debt, the 5 bps Titan fee and the pool's cut.
        uint256 sale = (3 * price) / 100; // USDC, 6 decimals
        uint256 received = IERC20(USDC).balanceOf(user) - usdcBefore;
        assertGt(received, (sale * 99) / 100 - debt - (debt * 5) / 10_000, "the rest of the sale");
        assertLt(received, sale - debt);
        assertEq(core.getExitOrder(user, AAVE_KEY).priceAsset, address(0), "the order is spent");
    }

    function test_close_revertsWhileThePriceIsAboveTheStopLoss() public {
        if (!forked) return;
        _openPosition(1.6e18, 1.2e18, 1.5e18);
        (, int256 answer,,,) = IChainlinkAggregator(ETH_USD).latestRoundData();
        vm.prank(user);
        core.setExitOrder(AAVE_KEY, WETH, uint256(answer) / 2, 0);
        uint256 collateral = IERC20(_aToken()).balanceOf(user);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SepehrErrors.ExitConditionNotMet.selector, uint256(answer)));
        core.close(user, AAVE_KEY, USDC, WETH, collateral, _providers(), address(router), "");
    }

    function test_execute_repaysFromTheWallet_withoutSellingWeth() public {
        if (!forked) return;
        _openPosition(1.3e18, 1.4e18, 1.6e18);
        deal(USDC, user, 100_000e6);
        vm.prank(user);
        IERC20(USDC).approve(address(core), type(uint256).max);

        // The repayment that brings the health factor to 1.62: `D (1 - HF / 1.62)`.
        uint256 hf = adapter.getHealthFactor(user);
        uint256 debt = IERC20(_debtToken()).balanceOf(user);
        uint256 repay = debt - (debt * hf) / 1.62e18;
        uint256 collateral = IERC20(_aToken()).balanceOf(user);

        vm.prank(keeper);
        uint256 hfAfter = core.execute(user, AAVE_KEY, USDC, WETH, repay, _providers(), address(router), "");

        assertGe(hfAfter, 1.6e18, "back to the target");
        assertLe(hfAfter, 1.65e18);
        assertGe(IERC20(_aToken()).balanceOf(user), collateral, "no WETH sold");
        assertEq(100_000e6 - IERC20(USDC).balanceOf(user), repay + (repay * 5) / 10_000, "repayment and fee");
    }

    function test_exitOrderAndOpenExecution_areOffUntilSet() public view {
        if (!forked) return;
        ISepehrCore.ExitOrder memory order = core.getExitOrder(user, AAVE_KEY);
        assertEq(order.priceAsset, address(0));
        assertEq(core.openExecutionHF(), 0);
    }
}
