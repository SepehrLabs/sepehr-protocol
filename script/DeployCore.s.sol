// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {SepehrCore} from "../src/SepehrCore.sol";
import {SepehrTimelock} from "../src/SepehrTimelock.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

contract DeployCore is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address owner = vm.envAddress("SEPEHR_OWNER");
        address pauseGuardian = vm.envAddress("SEPEHR_PAUSE_GUARDIAN");
        uint256 feeBps = vm.envUint("SEPEHR_FEE_BPS");
        uint256 timelockDelay = vm.envOr("SEPEHR_TIMELOCK_DELAY_SECONDS", uint256(172_800));
        uint256 minCollateralUsd = vm.envOr("SEPEHR_MIN_COLLATERAL_USD", uint256(500e8));
        bool useMockOracle = vm.envOr("USE_MOCK_ORACLE", false);

        vm.startBroadcast(deployer);

        address[] memory proposers = new address[](1);
        proposers[0] = owner;
        address[] memory executors = new address[](1);
        executors[0] = owner;

        SepehrTimelock timelock = new SepehrTimelock(timelockDelay, proposers, executors, owner);
        console.log("SepehrTimelock deployed at:", address(timelock));

        address oracleAddr;
        if (useMockOracle) {
            MockOracle oracle = new MockOracle();
            oracleAddr = address(oracle);
            console.log("MockOracle deployed at:", oracleAddr);
        } else {
            oracleAddr = vm.envAddress("SUBSCRIPTION_ORACLE");
        }

        SepehrCore core = new SepehrCore(owner, address(timelock), pauseGuardian, oracleAddr, minCollateralUsd, feeBps);
        console.log("SepehrCore deployed at:", address(core));

        vm.stopBroadcast();
    }
}
