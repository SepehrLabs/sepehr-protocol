// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {SepehrCore} from "../../src/SepehrCore.sol";
import {IProtocolAdapter} from "../../src/interfaces/IProtocolAdapter.sol";
import {MockAdapter} from "../../src/mocks/MockAdapter.sol";
import {MockChainlinkAggregator} from "../helpers/MockChainlinkAggregator.sol";

contract MockERC20 is ERC20 {
    constructor(
        string memory n,
        string memory s
    ) ERC20(n, s) {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

/// @notice Integration test for the Bloc 5.1 testnet V2 deploy flow:
///         OZ TimelockController with minDelay = 300s (5 min) gates the
///         post-deploy admin ops (`addAdapter`, `addKeeper`,
///         `addFlashLoanProvider`, `setAssetOracle`). Freezes the
///         contract-level invariants that the Phase 2 split-deploy
///         scripts rely on:
///           1. the timelock's minDelay is exactly 300s,
///           2. a scheduled op is pending before the delay elapses,
///           3. executing before the delay reverts,
///           4. executing after the delay populates the core's admin
///              registries (adapter, keeper, flash, asset oracle).
contract TestnetV2DeployTest is Test {
    uint256 internal constant TESTNET_TIMELOCK_DELAY = 300; // 5 min
    bytes32 internal constant AAVE_KEY = keccak256("aave-v3-arbitrum-sepolia");

    address internal deployer = makeAddr("deployer");
    address internal keeper = makeAddr("keeper");
    address internal pauseGuardian = makeAddr("guardian");

    TimelockController internal timelock;
    SepehrCore internal core;
    MockAdapter internal adapter;
    MockERC20 internal usdc;
    MockChainlinkAggregator internal usdcOracle;
    address internal flashProvider = makeAddr("flash");

    function setUp() public {
        // Mirror Phase 2 DeployAndSchedule: deployer is the sole proposer
        // and executor, admin=address(0) so the timelock is
        // self-administered (same pattern as Bloc 5, only delay changes).
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = deployer;
        vm.prank(deployer);
        timelock = new TimelockController(TESTNET_TIMELOCK_DELAY, proposers, executors, address(0));

        usdc = new MockERC20("USD Coin", "USDC");
        core = new SepehrCore(
            deployer, address(timelock), pauseGuardian, address(usdc), 0, type(uint256).max, block.chainid
        );
        adapter = new MockAdapter();
        usdcOracle = new MockChainlinkAggregator(8, int256(100_000_000)); // $1
    }

    // ─── 1. Timelock delay invariant ──────────────────────────────

    function test_timelockMinDelayIs300Seconds() public view {
        assertEq(timelock.getMinDelay(), TESTNET_TIMELOCK_DELAY);
    }

    // ─── 2. Schedule places op in pending state ───────────────────

    function test_scheduleAdminOpIsPendingBeforeDelay() public {
        bytes memory data = abi.encodeWithSignature("addAdapter(bytes32,address)", AAVE_KEY, address(adapter));

        vm.prank(deployer);
        timelock.schedule(address(core), 0, data, bytes32(0), bytes32(0), TESTNET_TIMELOCK_DELAY);

        bytes32 id = timelock.hashOperation(address(core), 0, data, bytes32(0), bytes32(0));
        assertTrue(timelock.isOperationPending(id), "op should be pending");
        assertFalse(timelock.isOperationReady(id), "op should not be ready yet");
        assertFalse(timelock.isOperationDone(id), "op should not be done");
    }

    // ─── 3. Execute before delay reverts ──────────────────────────

    function test_executeAdminOpRevertsBeforeDelay() public {
        bytes memory data = abi.encodeWithSignature("addAdapter(bytes32,address)", AAVE_KEY, address(adapter));

        vm.prank(deployer);
        timelock.schedule(address(core), 0, data, bytes32(0), bytes32(0), TESTNET_TIMELOCK_DELAY);

        // Only warp halfway through the delay: the op must still be pending,
        // not ready.
        vm.warp(block.timestamp + TESTNET_TIMELOCK_DELAY / 2);

        vm.prank(deployer);
        vm.expectRevert(); // OZ: TimelockUnexpectedOperationState
        timelock.execute(address(core), 0, data, bytes32(0), bytes32(0));
    }

    // ─── 4. Execute after delay completes admin ops ───────────────

    function test_executeAddAdapterAfterDelay() public {
        bytes memory data = abi.encodeWithSignature("addAdapter(bytes32,address)", AAVE_KEY, address(adapter));

        vm.prank(deployer);
        timelock.schedule(address(core), 0, data, bytes32(0), bytes32(0), TESTNET_TIMELOCK_DELAY);

        vm.warp(block.timestamp + TESTNET_TIMELOCK_DELAY + 1);

        vm.prank(deployer);
        timelock.execute(address(core), 0, data, bytes32(0), bytes32(0));

        (IProtocolAdapter registered, bool enabled,) = core.adapters(AAVE_KEY);
        assertEq(address(registered), address(adapter), "adapter not registered");
        assertTrue(enabled, "adapter should be enabled");

        bytes32 id = timelock.hashOperation(address(core), 0, data, bytes32(0), bytes32(0));
        assertTrue(timelock.isOperationDone(id), "op should be done");
    }

    function test_executeAddKeeperAfterDelay() public {
        bytes memory data = abi.encodeWithSignature("addKeeper(address)", keeper);

        vm.prank(deployer);
        timelock.schedule(address(core), 0, data, bytes32(0), bytes32(0), TESTNET_TIMELOCK_DELAY);

        vm.warp(block.timestamp + TESTNET_TIMELOCK_DELAY + 1);

        vm.prank(deployer);
        timelock.execute(address(core), 0, data, bytes32(0), bytes32(0));

        assertTrue(core.keepers(keeper), "keeper not registered");
    }

    function test_executeAddFlashLoanProviderAfterDelay() public {
        bytes memory data = abi.encodeWithSignature("addFlashLoanProvider(address)", flashProvider);

        vm.prank(deployer);
        timelock.schedule(address(core), 0, data, bytes32(0), bytes32(0), TESTNET_TIMELOCK_DELAY);

        vm.warp(block.timestamp + TESTNET_TIMELOCK_DELAY + 1);

        vm.prank(deployer);
        timelock.execute(address(core), 0, data, bytes32(0), bytes32(0));

        assertTrue(core.allowedFlashProviders(flashProvider), "flash provider not whitelisted");
    }

    function test_executeSetAssetOracleAfterDelay() public {
        bytes memory data = abi.encodeWithSignature(
            "setAssetOracle(address,address,uint256)", address(usdc), address(usdcOracle), uint256(86_400)
        );

        vm.prank(deployer);
        timelock.schedule(address(core), 0, data, bytes32(0), bytes32(0), TESTNET_TIMELOCK_DELAY);

        vm.warp(block.timestamp + TESTNET_TIMELOCK_DELAY + 1);

        vm.prank(deployer);
        timelock.execute(address(core), 0, data, bytes32(0), bytes32(0));

        (address agg, uint256 staleness) = _readAssetOracle(address(usdc));
        assertEq(agg, address(usdcOracle), "oracle not registered");
        assertEq(staleness, 86_400, "staleness mismatch");
    }

    // ─── 5. Single-adapter invariant (ADR-0011 SKIP Compound + Morpho) ─

    /// @notice Freezes the Bloc 5.1 decision: only the Aave V3 adapter is
    /// registered on Sepolia. Compound V3 and Morpho Blue are SKIPped
    /// because neither protocol has an Arbitrum Sepolia deployment, so a
    /// mock registration would give testers unit-test-grade signal
    /// dressed up as integration parity. If this test ever fails because
    /// someone registered an extra adapter, either the SKIP decision was
    /// reverted (update the plan) or a protocol shipped a Sepolia
    /// deployment (update chains.json + protocols.json first).
    function test_onlyAaveAdapterRegisteredAfterFullDeploy() public {
        bytes memory data = abi.encodeWithSignature("addAdapter(bytes32,address)", AAVE_KEY, address(adapter));

        vm.prank(deployer);
        timelock.schedule(address(core), 0, data, bytes32(0), bytes32(0), TESTNET_TIMELOCK_DELAY);

        vm.warp(block.timestamp + TESTNET_TIMELOCK_DELAY + 1);

        vm.prank(deployer);
        timelock.execute(address(core), 0, data, bytes32(0), bytes32(0));

        (IProtocolAdapter aaveAdapter,,) = core.adapters(AAVE_KEY);
        (IProtocolAdapter compAdapter,,) = core.adapters(keccak256("compound-v3-arbitrum-sepolia"));
        (IProtocolAdapter morphoAdapter,,) = core.adapters(keccak256("morpho-blue-arbitrum-sepolia"));

        assertTrue(address(aaveAdapter) != address(0), "aave adapter must be registered");
        assertEq(address(compAdapter), address(0), "compound adapter must not be registered on sepolia");
        assertEq(address(morphoAdapter), address(0), "morpho adapter must not be registered on sepolia");
    }

    // ─── helpers ──────────────────────────────────────────────────

    /// @dev Reads the public `assetOracles(address)` getter, which returns
    ///      the struct as a (aggregator, maxStaleness) tuple.
    function _readAssetOracle(
        address asset
    ) internal view returns (address aggregator, uint256 maxStaleness) {
        (aggregator, maxStaleness) = _readAssetOracleRaw(asset);
    }

    function _readAssetOracleRaw(
        address asset
    ) internal view returns (address, uint256) {
        // Solidity generates the public mapping getter with struct fields
        // returned as a tuple. We read via staticcall to dodge any compiler
        // version drift in the tuple layout.
        (bool ok, bytes memory ret) = address(core).staticcall(abi.encodeWithSignature("assetOracles(address)", asset));
        require(ok, "assetOracles getter failed");
        (address aggregator, uint256 maxStaleness) = abi.decode(ret, (address, uint256));
        return (aggregator, maxStaleness);
    }
}
