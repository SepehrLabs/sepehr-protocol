// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {AegisCore} from "../src/AegisCore.sol";
import {AegisTimelock} from "../src/AegisTimelock.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

contract DeployCore is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address owner = vm.envAddress("AEGIS_OWNER");
        address pauseGuardian = vm.envAddress("AEGIS_PAUSE_GUARDIAN");
        uint256 feeBps = vm.envUint("AEGIS_FEE_BPS");
        uint256 timelockDelay = vm.envOr("AEGIS_TIMELOCK_DELAY_SECONDS", uint256(172_800));
        uint256 minCollateralUsd = vm.envOr("AEGIS_MIN_COLLATERAL_USD", uint256(500e8));
        bool useMockOracle = vm.envOr("USE_MOCK_ORACLE", false);

        vm.startBroadcast(deployer);

        address[] memory proposers = new address[](1);
        proposers[0] = owner;
        address[] memory executors = new address[](1);
        executors[0] = owner;

        AegisTimelock timelock = new AegisTimelock(timelockDelay, proposers, executors, owner);
        console.log("AegisTimelock deployed at:", address(timelock));

        address oracleAddr;
        if (useMockOracle) {
            MockOracle oracle = new MockOracle();
            oracleAddr = address(oracle);
            console.log("MockOracle deployed at:", oracleAddr);
        } else {
            oracleAddr = vm.envAddress("SUBSCRIPTION_ORACLE");
        }

        AegisCore core = new AegisCore(owner, address(timelock), pauseGuardian, oracleAddr, minCollateralUsd, feeBps);
        console.log("AegisCore deployed at:", address(core));

        vm.stopBroadcast();
    }
}
