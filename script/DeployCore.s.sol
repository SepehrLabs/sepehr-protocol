// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {SepehrCore} from "../src/SepehrCore.sol";
import {SepehrTimelock} from "../src/SepehrTimelock.sol";

contract DeployCore is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address owner = vm.envAddress("SEPEHR_OWNER");
        address pauseGuardian = vm.envAddress("SEPEHR_PAUSE_GUARDIAN");
        address usdcAddress = vm.envAddress("USDC_ADDRESS");
        uint256 timelockDelay = vm.envOr("SEPEHR_TIMELOCK_DELAY_SECONDS", uint256(172_800));
        uint256 minCollateralUsd = vm.envOr("SEPEHR_MIN_COLLATERAL_USD", uint256(500e8));

        vm.startBroadcast(deployer);

        address[] memory proposers = new address[](1);
        proposers[0] = owner;
        address[] memory executors = new address[](1);
        executors[0] = owner;

        SepehrTimelock timelock = new SepehrTimelock(timelockDelay, proposers, executors, owner);
        console.log("SepehrTimelock deployed at:", address(timelock));

        SepehrCore core = new SepehrCore(owner, address(timelock), pauseGuardian, usdcAddress, minCollateralUsd);
        console.log("SepehrCore deployed at:", address(core));

        vm.stopBroadcast();
    }
}
