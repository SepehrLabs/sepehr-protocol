// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DeployCore} from "../../script/DeployCore.s.sol";
import {SepehrCore} from "../../src/SepehrCore.sol";
import {SepehrSubscriptions} from "../../src/SepehrSubscriptions.sol";
import {ISepehrSubscriptions} from "../../src/interfaces/ISepehrSubscriptions.sol";
import {ForkTestBase} from "./ForkTestBase.sol";

interface ISafeProxyFactory {
    function createProxyWithNonce(
        address singleton,
        bytes memory initializer,
        uint256 saltNonce
    ) external returns (address proxy);
}

interface ISafe {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;

    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);

    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce
    ) external view returns (bytes32);

    function nonce() external view returns (uint256);
}

/// @title Lot 8 rehearsal: the mainnet governance on Arbitrum One, run by a real Safe 2 of 3.
/// @notice DeployCore deploys the timelock, SepehrSubscriptions and SepehrCore with a Safe
///         1.4.1 as owner, proposer, executor and canceller; the Safe then governs them with two
///         signatures, and hands everything to a new Safe.
/// @dev Skipped without `RPC_ARBITRUM_PRIMARY_HTTP`. Run with `--profile fork-arbitrum`.
contract SafeGovernanceArbitrumForkTest is ForkTestBase {
    uint256 constant FORK_BLOCK = 512_922_786;
    address constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address constant SAFE_L2_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address constant SAFE_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    uint256 constant DELAY = 48 hours;

    bool internal forked;
    uint256[3] internal signerKeys = [uint256(0xA11CE), uint256(0xB0B), uint256(0xCA401)];
    address internal deployer = makeAddr("deployer");
    address internal guardian = makeAddr("guardian");
    address internal safe;
    uint256 internal saltNonce;

    TimelockController internal timelock;
    SepehrSubscriptions internal subs;
    SepehrCore internal core;

    function setUp() public {
        forked = _tryCreateForkAtBlock("RPC_ARBITRUM_PRIMARY_HTTP", FORK_BLOCK);
        if (!forked) return;
        assertGt(SAFE_PROXY_FACTORY.code.length, 0, "Safe 1.4.1 factory");
        assertGt(SAFE_L2_SINGLETON.code.length, 0, "Safe 1.4.1 L2 singleton");

        safe = _createSafe(_signers(), 2);
        _setDeployEnv(safe);
        uint256 nonce = vm.getNonce(deployer);
        new DeployCore().run();
        timelock = TimelockController(payable(vm.computeCreateAddress(deployer, nonce)));
        subs = SepehrSubscriptions(vm.computeCreateAddress(deployer, nonce + 1));
        core = SepehrCore(vm.computeCreateAddress(deployer, nonce + 2));
    }

    // ─── Helpers ─────────────────────────────────────────────────

    function _signers() internal view returns (address[] memory signers) {
        signers = new address[](3);
        for (uint256 i; i < 3; i++) {
            signers[i] = vm.addr(signerKeys[i]);
        }
    }

    function _createSafe(
        address[] memory signers,
        uint256 threshold
    ) internal returns (address) {
        bytes memory initializer = abi.encodeCall(
            ISafe.setup, (signers, threshold, address(0), "", SAFE_FALLBACK_HANDLER, address(0), 0, payable(address(0)))
        );
        return ISafeProxyFactory(SAFE_PROXY_FACTORY).createProxyWithNonce(SAFE_L2_SINGLETON, initializer, saltNonce++);
    }

    function _setDeployEnv(
        address owner
    ) internal {
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(deployer));
        vm.setEnv("SEPEHR_OWNER", vm.toString(owner));
        vm.setEnv("SEPEHR_PAUSE_GUARDIAN", vm.toString(guardian));
        vm.setEnv("USDC_ADDRESS", vm.toString(USDC));
        vm.setEnv("SEPEHR_TIMELOCK_DELAY_SECONDS", vm.toString(DELAY));
        vm.setEnv("SEPEHR_MIN_COLLATERAL_USD", vm.toString(uint256(500e8)));
        vm.setEnv("SEPEHR_TVL_CAP_USD", vm.toString(uint256(75_000e8)));
    }

    /// @dev The Safe's signatures by `keys`, ordered by signer address as the Safe requires.
    function _sign(
        address safe_,
        address to,
        bytes memory data,
        uint256[] memory keys
    ) internal view returns (bytes memory signatures) {
        bytes32 txHash =
            ISafe(safe_).getTransactionHash(to, 0, data, 0, 0, 0, 0, address(0), address(0), ISafe(safe_).nonce());
        for (uint256 i = 1; i < keys.length; i++) {
            for (uint256 j = i; j > 0 && vm.addr(keys[j - 1]) > vm.addr(keys[j]); j--) {
                (keys[j - 1], keys[j]) = (keys[j], keys[j - 1]);
            }
        }
        for (uint256 i; i < keys.length; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], txHash);
            signatures = abi.encodePacked(signatures, r, s, v);
        }
    }

    function _keys(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256[] memory keys) {
        keys = new uint256[](2);
        (keys[0], keys[1]) = (a, b);
    }

    /// @dev A transaction of `safe_` signed by its first two signers.
    function _exec(
        address safe_,
        address to,
        bytes memory data
    ) internal {
        _execSignedBy(safe_, to, data, _keys(signerKeys[0], signerKeys[2]));
    }

    function _execSignedBy(
        address safe_,
        address to,
        bytes memory data,
        uint256[] memory keys
    ) internal {
        _execWith(safe_, to, data, _sign(safe_, to, data, keys));
    }

    function _execWith(
        address safe_,
        address to,
        bytes memory data,
        bytes memory signatures
    ) internal {
        ISafe(safe_).execTransaction(to, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), signatures);
    }

    // ─── Deployment ──────────────────────────────────────────────

    function test_deployCore_givesTheSafeEveryGovernanceRole() public view {
        if (!forked) return;
        assertEq(core.owner(), safe);
        assertEq(subs.owner(), safe);
        assertEq(core.timelock(), address(timelock));
        assertEq(subs.timelock(), address(timelock));
        assertEq(core.pauseGuardian(), guardian);
        assertEq(timelock.getMinDelay(), DELAY);
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), safe));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), safe));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), safe));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), safe));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), deployer));
    }

    function test_deployCore_refusesAnOwnerThatIsNotASafe() public {
        if (!forked) return;
        _setDeployEnv(makeAddr("singleKey"));
        DeployCore deploy = new DeployCore();
        vm.expectRevert(bytes("DeployCore: on Arbitrum One the owner must be a Safe"));
        deploy.run();
    }

    function test_deployCore_refusesASafeUnderTwoOfThree() public {
        if (!forked) return;
        DeployCore deploy = new DeployCore();

        _setDeployEnv(_createSafe(_signers(), 1));
        vm.expectRevert(bytes("DeployCore: the owner Safe needs 2 signatures out of 3 signers or more"));
        deploy.run();

        address[] memory two = new address[](2);
        (two[0], two[1]) = (vm.addr(signerKeys[0]), vm.addr(signerKeys[1]));
        _setDeployEnv(_createSafe(two, 2));
        vm.expectRevert(bytes("DeployCore: the owner Safe needs 2 signatures out of 3 signers or more"));
        deploy.run();
    }

    // ─── Governance through the Safe ─────────────────────────────

    function test_aCoreChangeNeedsTwoSignaturesAndTheDelay() public {
        if (!forked) return;
        address keeper = makeAddr("keeper");
        bytes memory addKeeper = abi.encodeCall(SepehrCore.addKeeper, (keeper));
        bytes memory schedule = abi.encodeCall(TimelockController.schedule, (address(core), 0, addKeeper, 0, 0, DELAY));

        uint256[] memory one = new uint256[](1);
        one[0] = signerKeys[1];
        bytes memory oneSignature = _sign(safe, address(timelock), schedule, one);
        vm.expectRevert(bytes("GS020"));
        _execWith(safe, address(timelock), schedule, oneSignature);

        _exec(safe, address(timelock), schedule);
        bytes memory execute = abi.encodeCall(TimelockController.execute, (address(core), 0, addKeeper, 0, 0));
        skip(DELAY - 1);
        bytes memory signatures = _sign(safe, address(timelock), execute, _keys(signerKeys[0], signerKeys[2]));
        vm.expectRevert(bytes("GS013"));
        _execWith(safe, address(timelock), execute, signatures);

        skip(1);
        _exec(safe, address(timelock), execute);
        assertTrue(core.isKeeper(keeper));
    }

    function test_aSignerOutsideTheSafeCannotStandInForASecondSignature() public {
        if (!forked) return;
        bytes memory schedule = abi.encodeCall(
            TimelockController.schedule,
            (address(core), 0, abi.encodeCall(SepehrCore.addKeeper, (makeAddr("keeper"))), 0, 0, DELAY)
        );
        bytes memory signatures = _sign(safe, address(timelock), schedule, _keys(signerKeys[0], 0xBAD));
        vm.expectRevert(bytes("GS026"));
        _execWith(safe, address(timelock), schedule, signatures);
    }

    function test_theSafeUnpausesAfterTheGuardianAndGrantsTitan() public {
        if (!forked) return;
        vm.prank(guardian);
        core.pause();
        assertTrue(core.paused());

        _exec(safe, address(core), abi.encodeCall(SepehrCore.unpause, ()));
        assertFalse(core.paused());

        address tester = makeAddr("tester");
        _exec(safe, address(subs), abi.encodeCall(SepehrSubscriptions.grantTitanSubscription, (tester, 30 days)));
        ISepehrSubscriptions.Subscription memory sub = subs.getSubscription(tester);
        assertEq(sub.tier, 4);
    }

    function test_theSafeHandsEverythingToANewSafe() public {
        if (!forked) return;
        address next = _createSafe(_signers(), 2);

        _exec(safe, address(core), abi.encodeCall(core.transferOwnership, (next)));
        _exec(safe, address(subs), abi.encodeCall(subs.transferOwnership, (next)));
        _exec(next, address(core), abi.encodeCall(core.acceptOwnership, ()));
        _exec(next, address(subs), abi.encodeCall(subs.acceptOwnership, ()));
        assertEq(core.owner(), next);
        assertEq(subs.owner(), next);

        bytes32[3] memory roles = [timelock.PROPOSER_ROLE(), timelock.EXECUTOR_ROLE(), timelock.CANCELLER_ROLE()];
        address[] memory targets = new address[](6);
        uint256[] memory values = new uint256[](6);
        bytes[] memory calls = new bytes[](6);
        for (uint256 i; i < 3; i++) {
            (targets[i], targets[i + 3]) = (address(timelock), address(timelock));
            calls[i] = abi.encodeCall(timelock.grantRole, (roles[i], next));
            calls[i + 3] = abi.encodeCall(timelock.revokeRole, (roles[i], safe));
        }
        _exec(
            safe,
            address(timelock),
            abi.encodeCall(TimelockController.scheduleBatch, (targets, values, calls, 0, 0, DELAY))
        );
        skip(DELAY);
        _exec(safe, address(timelock), abi.encodeCall(TimelockController.executeBatch, (targets, values, calls, 0, 0)));

        for (uint256 i; i < 3; i++) {
            assertTrue(timelock.hasRole(roles[i], next));
            assertFalse(timelock.hasRole(roles[i], safe));
        }
        address keeper = makeAddr("keeper");
        bytes memory addKeeper = abi.encodeCall(SepehrCore.addKeeper, (keeper));
        _exec(
            next,
            address(timelock),
            abi.encodeCall(TimelockController.schedule, (address(core), 0, addKeeper, 0, 0, DELAY))
        );
        skip(DELAY);
        _exec(next, address(timelock), abi.encodeCall(TimelockController.execute, (address(core), 0, addKeeper, 0, 0)));
        assertTrue(core.isKeeper(keeper));
    }
}
