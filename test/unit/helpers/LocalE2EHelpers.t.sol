// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {IMorpho} from "../../../src/interfaces/external/IMorpho.sol";
import {MockTokenDecimals} from "../../helpers/MockTokenDecimals.sol";
import {MorphoLike, MorphoLikeOracle} from "../../helpers/MorphoLike.sol";
import {Multicall3Lite} from "../../helpers/Multicall3Lite.sol";

contract Multicall3LiteTest is Test {
    Multicall3Lite internal multicall;
    MockTokenDecimals internal token;

    function setUp() public {
        multicall = new Multicall3Lite();
        token = new MockTokenDecimals("Token", "TKN", 6);
        token.mint(address(this), 5);
    }

    function _call(
        bytes memory data,
        bool allowFailure
    ) internal view returns (Multicall3Lite.Call3[] memory calls) {
        calls = new Multicall3Lite.Call3[](1);
        calls[0] = Multicall3Lite.Call3({target: address(token), allowFailure: allowFailure, callData: data});
    }

    function test_aggregate3_returnsResults() public {
        Multicall3Lite.Result[] memory results =
            multicall.aggregate3(_call(abi.encodeCall(token.balanceOf, (address(this))), false));
        assertTrue(results[0].success);
        assertEq(abi.decode(results[0].returnData, (uint256)), 5);
    }

    function test_aggregate3_recordsAllowedFailure() public {
        Multicall3Lite.Result[] memory results =
            multicall.aggregate3(_call(abi.encodeCall(token.transfer, (address(1), 1)), true));
        assertFalse(results[0].success);
    }

    function test_aggregate3_revertsOnDisallowedFailure() public {
        vm.expectRevert(bytes("Multicall3Lite: call failed"));
        multicall.aggregate3(_call(abi.encodeCall(token.transfer, (address(1), 1)), false));
    }
}

contract MorphoLikeTest is Test {
    MorphoLike internal morpho;
    MorphoLikeOracle internal oracle;
    MockTokenDecimals internal usdc;
    MockTokenDecimals internal weth;
    IMorpho.MarketParams internal params;
    bytes32 internal id;

    function setUp() public {
        morpho = new MorphoLike();
        oracle = new MorphoLikeOracle();
        oracle.setPrice(3000e24); // 3 000 USDC per WETH
        usdc = new MockTokenDecimals("USD Coin", "USDC", 6);
        weth = new MockTokenDecimals("Wrapped Ether", "WETH", 18);
        params = IMorpho.MarketParams(address(usdc), address(weth), address(oracle), address(0xBEEF), 0.86e18);
        id = morpho.createMarket(params);
        usdc.mint(address(morpho), 1_000_000e6);
        weth.mint(address(this), 10e18);
        weth.approve(address(morpho), 10e18);
        morpho.supplyCollateral(params, 10e18, address(this));
    }

    function test_borrow_revertsBeyondLltv() public {
        vm.expectRevert(bytes("MorphoLike: insufficient collateral"));
        morpho.borrow(params, 25_801e6, address(this), address(this));
    }

    function test_repay_reducesDebt() public {
        morpho.borrow(params, 20_000e6, address(this), address(this));
        usdc.approve(address(morpho), 5000e6);
        morpho.repay(params, 5000e6, 0, address(this), "");
        assertEq(morpho.position(id, address(this)).borrowShares, 15_000e6);
    }

    function test_withdrawCollateral_requiresHealth() public {
        morpho.borrow(params, 20_000e6, address(this), address(this));
        vm.expectRevert(bytes("MorphoLike: insufficient collateral"));
        morpho.withdrawCollateral(params, 3e18, address(this), address(this));
        morpho.withdrawCollateral(params, 1e18, address(this), address(this));
        assertEq(weth.balanceOf(address(this)), 1e18);
    }
}
