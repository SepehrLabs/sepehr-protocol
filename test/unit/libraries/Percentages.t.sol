// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Percentages} from "../../../src/libraries/Percentages.sol";
import {Test} from "forge-std/Test.sol";

contract PercentagesTest is Test {
    function test_applyBps_30bps() public pure {
        // 0.3% of 10000 = 30
        assertEq(Percentages.applyBps(10_000, 30), 30);
    }

    function test_applyBps_100percent() public pure {
        assertEq(Percentages.applyBps(1000, 10_000), 1000);
    }

    function test_applyBps_zero() public pure {
        assertEq(Percentages.applyBps(1000, 0), 0);
        assertEq(Percentages.applyBps(0, 5000), 0);
    }

    function test_applyBpsRoundUp_roundsUp() public pure {
        // 1 * 1 / 10000 = 0.0001 -> rounds up to 1
        assertEq(Percentages.applyBpsRoundUp(1, 1), 1);
    }

    function test_applyBpsRoundUp_exact() public pure {
        assertEq(Percentages.applyBpsRoundUp(10_000, 5000), 5000);
    }

    function test_toBps() public pure {
        assertEq(Percentages.toBps(30, 10_000), 30);
        assertEq(Percentages.toBps(5000, 10_000), 5000);
        assertEq(Percentages.toBps(10_000, 10_000), 10_000);
    }

    function test_toBps_zeroWhole() public pure {
        assertEq(Percentages.toBps(100, 0), 0);
    }

    function test_splitFee_85_15() public pure {
        (uint256 ownerShare, uint256 keeperShare) = Percentages.splitFee(10_000);
        assertEq(ownerShare, 8500);
        assertEq(keeperShare, 1500);
    }

    function test_splitFee_sumsToTotal() public pure {
        (uint256 ownerShare, uint256 keeperShare) = Percentages.splitFee(12_345);
        assertEq(ownerShare + keeperShare, 12_345);
    }

    function test_splitFee_zero() public pure {
        (uint256 ownerShare, uint256 keeperShare) = Percentages.splitFee(0);
        assertEq(ownerShare, 0);
        assertEq(keeperShare, 0);
    }

    function testFuzz_splitFee_sumsToTotal(uint128 total) public pure {
        (uint256 ownerShare, uint256 keeperShare) = Percentages.splitFee(uint256(total));
        assertEq(ownerShare + keeperShare, uint256(total));
    }

    function testFuzz_splitFee_ownerGetsMore(uint128 total) public pure {
        vm.assume(total > 10);
        (uint256 ownerShare, uint256 keeperShare) = Percentages.splitFee(uint256(total));
        assertGe(ownerShare, keeperShare);
    }

    function test_splitFee_smallAmountRounding() public pure {
        // For total=1, ownerShare = (1*8500)/10000 = 0, keeperShare = 1
        (uint256 ownerShare, uint256 keeperShare) = Percentages.splitFee(1);
        assertEq(ownerShare, 0);
        assertEq(keeperShare, 1);
    }

    /// @dev A21: the 85/15 split is expressed as named bps constants that sum to BPS_DENOMINATOR.
    function test_feeSplitConstants_sumToDenominator() public pure {
        assertEq(Percentages.OWNER_FEE_SPLIT_BPS, 8500);
        assertEq(Percentages.KEEPER_FEE_SPLIT_BPS, 1500);
        assertEq(Percentages.OWNER_FEE_SPLIT_BPS + Percentages.KEEPER_FEE_SPLIT_BPS, Percentages.BPS_DENOMINATOR);
    }
}
