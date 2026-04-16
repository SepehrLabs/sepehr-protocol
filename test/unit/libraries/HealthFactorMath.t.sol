// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {HealthFactorMath} from "../../../src/libraries/HealthFactorMath.sol";
import {Test} from "forge-std/Test.sol";

contract HealthFactorMathTest is Test {
    using HealthFactorMath for uint256;

    function test_wadMul_oneTimesOne() public pure {
        assertEq(HealthFactorMath.wadMul(1e18, 1e18), 1e18);
    }

    function test_wadMul_twoTimesThree() public pure {
        assertEq(HealthFactorMath.wadMul(2e18, 3e18), 6e18);
    }

    function test_wadMul_roundsCorrectly() public pure {
        // 1.5 * 1.5 = 2.25
        assertEq(HealthFactorMath.wadMul(1.5e18, 1.5e18), 2.25e18);
    }

    function test_wadMul_zeroReturnsZero() public pure {
        assertEq(HealthFactorMath.wadMul(0, 1e18), 0);
        assertEq(HealthFactorMath.wadMul(1e18, 0), 0);
    }

    function test_wadDiv_sixByTwo() public pure {
        assertEq(HealthFactorMath.wadDiv(6e18, 2e18), 3e18);
    }

    function test_wadDiv_oneByThree() public pure {
        // 1/3 = 0.333...
        uint256 result = HealthFactorMath.wadDiv(1e18, 3e18);
        assertApproxEqAbs(result, 0.333333333333333333e18, 1);
    }

    function test_toWad() public pure {
        assertEq(HealthFactorMath.toWad(5), 5e18);
    }

    function test_mulDiv_basic() public pure {
        assertEq(HealthFactorMath.mulDiv(10, 20, 5), 40);
    }

    function test_mulDivRoundUp_roundsUp() public pure {
        // 10 * 3 / 7 = 4.2857... -> rounds up to 5
        assertEq(HealthFactorMath.mulDivRoundUp(10, 3, 7), 5);
    }

    function test_mulDivRoundUp_exactNoRounding() public pure {
        // 10 * 2 / 5 = 4.0 -> no rounding needed
        assertEq(HealthFactorMath.mulDivRoundUp(10, 2, 5), 4);
    }

    function testFuzz_wadMulCommutative(
        uint128 a,
        uint128 b
    ) public pure {
        uint256 ab = HealthFactorMath.wadMul(uint256(a), uint256(b));
        uint256 ba = HealthFactorMath.wadMul(uint256(b), uint256(a));
        assertEq(ab, ba);
    }

    function testFuzz_wadDivMulIdentity(
        uint128 a
    ) public pure {
        vm.assume(a > 0);
        uint256 wad = uint256(a);
        uint256 result = HealthFactorMath.wadDiv(HealthFactorMath.wadMul(wad, 1e18), 1e18);
        assertApproxEqAbs(result, wad, 1);
    }
}
