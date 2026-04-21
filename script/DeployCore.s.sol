// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {SepehrCore} from "../src/SepehrCore.sol";
import {SepehrTimelock} from "../src/SepehrTimelock.sol";

contract DeployCore is Script {
    /// @notice Arbitrum One.
    uint256 internal constant ARBITRUM_ONE_CHAIN_ID = 42_161;
    /// @notice Arbitrum Sepolia (public testnet).
    uint256 internal constant ARBITRUM_SEPOLIA_CHAIN_ID = 421_614;

    function run() external {
        // ADR-0011: V1 is a mono-Arbitrum deploy. The script refuses to broadcast on any
        // chain that isn't Arbitrum One or Arbitrum Sepolia so an operator cannot
        // accidentally spin up a half-configured Sepehr on the wrong network (which would
        // then accept `subscribe` calls the keeper on the real chain can never honour).
        // Local anvil / unit tests go through `E2ELocalDeploy.s.sol`, which is deliberately
        // unrestricted.
        require(
            block.chainid == ARBITRUM_ONE_CHAIN_ID || block.chainid == ARBITRUM_SEPOLIA_CHAIN_ID,
            "DeployCore: only Arbitrum One or Arbitrum Sepolia"
        );

        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address owner = vm.envAddress("SEPEHR_OWNER");
        address pauseGuardian = vm.envAddress("SEPEHR_PAUSE_GUARDIAN");
        address usdcAddress = vm.envAddress("USDC_ADDRESS");
        uint256 timelockDelay = vm.envOr("SEPEHR_TIMELOCK_DELAY_SECONDS", uint256(172_800));
        uint256 minCollateralUsd = vm.envOr("SEPEHR_MIN_COLLATERAL_USD", uint256(500e8));
        // G4: protocol-wide TVL cap (USD-8). V1 default is $75k = `7_500_000_000_000` to
        // bound exposure while keeper performance is empirically validated; governance
        // raises it via `setTvlCapUsd` once the runtime numbers justify it.
        uint256 tvlCapUsd = vm.envOr("SEPEHR_TVL_CAP_USD", uint256(7_500_000_000_000));

        vm.startBroadcast(deployer);

        address[] memory proposers = new address[](1);
        proposers[0] = owner;
        address[] memory executors = new address[](1);
        executors[0] = owner;

        // C3: pass address(0) as admin so the timelock is self-administered. Granting TIMELOCK_ADMIN_ROLE
        // to `owner` would let the owner bypass the delay via grantRole/revokeRole, defeating the 48h gate.
        SepehrTimelock timelock = new SepehrTimelock(timelockDelay, proposers, executors, address(0));
        console.log("SepehrTimelock deployed at:", address(timelock));

        SepehrCore core = new SepehrCore(
            owner, address(timelock), pauseGuardian, usdcAddress, minCollateralUsd, tvlCapUsd, block.chainid
        );
        console.log("SepehrCore deployed at:", address(core));

        // M3: freeze the strict-canonical-routes default post-deploy. A fresh deploy MUST
        // leave it off so trigger flow keeps working while governance seeds the route
        // registry; enabling strict mode at the same time as deploy would brick every
        // trigger until the canonical-route mapping is populated.
        require(!core.strictCanonicalRoutes(), "DeployCore: strictCanonicalRoutes must default to false");

        vm.stopBroadcast();
    }
}
