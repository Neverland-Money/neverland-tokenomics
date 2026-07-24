// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IDustLock} from "../../../src/interfaces/IDustLock.sol";
import {IRevenueReward} from "../../../src/interfaces/IRevenueReward.sol";
import {IUserVaultFactory} from "../../../src/interfaces/IUserVaultFactory.sol";
import {DustLockTransferStrategy} from "../../../src/emissions/DustLockTransferStrategy.sol";
import {NeverlandTimelockController} from "../../../src/governance/NeverlandTimelockController.sol";
import {RevenueReward} from "../../../src/rewards/RevenueReward.sol";
import {DustLock} from "../../../src/tokens/DustLock.sol";
import {MockERC20} from "../../_utils/MockERC20.sol";
import {BaseTest} from "../../BaseTest.sol";

contract Ngv05DustLockPredecessor {
    function token() external view returns (address tokenAddress) {
        assembly ("memory-safe") {
            tokenAddress := sload(152)
        }
    }

    function earlyWithdrawTreasury() external view returns (address treasury) {
        assembly ("memory-safe") {
            treasury := sload(175)
        }
    }
}

contract Ngv05RevenueRewardPredecessor {}

contract Ngv05RewardsControllerHarness {
    mapping(address => address) internal transferStrategies;

    function setTransferStrategy(address reward, address strategy) external {
        transferStrategies[reward] = strategy;
    }

    function getTransferStrategy(address reward) external view returns (address) {
        return transferStrategies[reward];
    }
}

/**
 * @title ClaimReformAtomicGovernanceUpgradeTest
 * @notice Executes the exact paired NGV-05 proxy sequence through NeverlandTimelockController
 */
contract ClaimReformAtomicGovernanceUpgradeTest is BaseTest {
    uint256 internal constant GOVERNANCE_DELAY = 1 days;
    uint256 internal constant DUST_LOCK_STORAGE_SLOTS = 228;
    uint256 internal constant REVENUE_REWARD_STORAGE_SLOTS = 215;

    address internal operator = address(0x0b0b);
    address internal dustVault = address(0xd057);
    address internal rewardDistributor = address(0xd157);

    ProxyAdmin internal proxyAdmin;
    NeverlandTimelockController internal timelock;
    TransparentUpgradeableProxy internal dustLockProxy;
    TransparentUpgradeableProxy internal revenueRewardProxy;
    DustLock internal dustLockCandidate;
    RevenueReward internal revenueRewardCandidate;
    Ngv05DustLockPredecessor internal dustLockPredecessor;
    Ngv05RevenueRewardPredecessor internal revenueRewardPredecessor;
    DustLockTransferStrategy internal strategy;
    Ngv05RewardsControllerHarness internal rewardsController;
    MockERC20 internal dust;

    function testSecondUpgradeFailureRollsBackRevenueRewardAndLeavesOperationRetryable() public {
        bytes32[] memory dustLockState = _snapshotStorage(address(dustLockProxy), DUST_LOCK_STORAGE_SLOTS);
        bytes32[] memory revenueRewardState =
            _snapshotStorage(address(revenueRewardProxy), REVENUE_REWARD_STORAGE_SLOTS);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _forwardActions(address(0xbad));
        bytes32 salt = keccak256("NGV-05 failing atomic forward");

        _schedule(targets, values, payloads, salt);
        vm.warp(block.timestamp + GOVERNANCE_DELAY + 1);
        vm.roll(block.number + 1);

        vm.prank(operator);
        vm.expectRevert();
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);

        _assertImplementations(address(revenueRewardPredecessor), address(dustLockPredecessor));
        _assertStorageEquals(address(dustLockProxy), dustLockState);
        _assertStorageEquals(address(revenueRewardProxy), revenueRewardState);
        strategy.assertActivationState(false);
    }

    function testForwardAndReverseBatchesUpgradeBothProxiesAtomicallyWithoutStorageDrift() public {
        bytes32[] memory dustLockState = _snapshotStorage(address(dustLockProxy), DUST_LOCK_STORAGE_SLOTS);
        bytes32[] memory revenueRewardState =
            _snapshotStorage(address(revenueRewardProxy), REVENUE_REWARD_STORAGE_SLOTS);

        (address[] memory forwardTargets, uint256[] memory forwardValues, bytes[] memory forwardPayloads) =
            _forwardActions(address(dustLockCandidate));
        _scheduleAndExecute(forwardTargets, forwardValues, forwardPayloads, keccak256("NGV-05 atomic forward"));

        _assertImplementations(address(revenueRewardCandidate), address(dustLockCandidate));
        _assertStorageEquals(address(dustLockProxy), dustLockState);
        _assertStorageEquals(address(revenueRewardProxy), revenueRewardState);
        strategy.assertActivationState(true);

        (address[] memory rollbackTargets, uint256[] memory rollbackValues, bytes[] memory rollbackPayloads) =
            _rollbackActions();
        _scheduleAndExecute(rollbackTargets, rollbackValues, rollbackPayloads, keccak256("NGV-05 atomic rollback"));

        _assertImplementations(address(revenueRewardPredecessor), address(dustLockPredecessor));
        _assertStorageEquals(address(dustLockProxy), dustLockState);
        _assertStorageEquals(address(revenueRewardProxy), revenueRewardState);
        strategy.assertActivationState(false);
    }

    function _testSetup() internal override {
        proxyAdmin = new ProxyAdmin();
        dust = new MockERC20("DUST", "DUST", 18);

        dustLockCandidate = new DustLock(FORWARDER);
        dustLockProxy = new TransparentUpgradeableProxy(
            address(dustLockCandidate),
            address(proxyAdmin),
            abi.encodeCall(DustLock.initialize, (FORWARDER, address(dust), "https://neverland.money/ngv05/"))
        );

        revenueRewardCandidate = new RevenueReward(FORWARDER);
        revenueRewardProxy = new TransparentUpgradeableProxy(
            address(revenueRewardCandidate),
            address(proxyAdmin),
            abi.encodeCall(
                RevenueReward.initialize,
                (FORWARDER, IDustLock(address(dustLockProxy)), rewardDistributor, IUserVaultFactory(address(0xfaca)))
            )
        );
        DustLock(address(dustLockProxy)).setRevenueReward(IRevenueReward(address(revenueRewardProxy)));
        DustLock(address(dustLockProxy)).setEarlyWithdrawTreasury(address(0xbea7));

        dustLockPredecessor = new Ngv05DustLockPredecessor();
        revenueRewardPredecessor = new Ngv05RevenueRewardPredecessor();
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(address(revenueRewardProxy)), address(revenueRewardPredecessor));
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(address(dustLockProxy)), address(dustLockPredecessor));

        rewardsController = new Ngv05RewardsControllerHarness();
        strategy = new DustLockTransferStrategy(address(rewardsController), admin, dustVault, address(dustLockProxy));
        rewardsController.setTransferStrategy(address(dust), address(strategy));
        vm.prank(dustVault);
        dust.approve(address(strategy), type(uint256).max);
        strategy.assertActivationState(false);

        address[] memory operators = new address[](1);
        operators[0] = operator;
        timelock =
            new NeverlandTimelockController(GOVERNANCE_DELAY, GOVERNANCE_DELAY, operators, operators, address(this));
        proxyAdmin.transferOwnership(address(timelock));
    }

    function _forwardActions(address selectedDustLockImplementation)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](4);
        values = new uint256[](4);
        payloads = new bytes[](4);

        targets[0] = address(strategy);
        targets[1] = address(proxyAdmin);
        targets[2] = address(proxyAdmin);
        targets[3] = address(strategy);
        payloads[0] = abi.encodeCall(DustLockTransferStrategy.assertActivationState, (false));
        payloads[1] = abi.encodeCall(
            ProxyAdmin.upgrade,
            (ITransparentUpgradeableProxy(address(revenueRewardProxy)), address(revenueRewardCandidate))
        );
        payloads[2] = abi.encodeCall(
            ProxyAdmin.upgrade, (ITransparentUpgradeableProxy(address(dustLockProxy)), selectedDustLockImplementation)
        );
        payloads[3] = abi.encodeCall(DustLockTransferStrategy.assertActivationState, (true));
    }

    function _rollbackActions()
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](4);
        values = new uint256[](4);
        payloads = new bytes[](4);

        targets[0] = address(strategy);
        targets[1] = address(proxyAdmin);
        targets[2] = address(proxyAdmin);
        targets[3] = address(strategy);
        payloads[0] = abi.encodeCall(DustLockTransferStrategy.assertActivationState, (true));
        payloads[1] = abi.encodeCall(
            ProxyAdmin.upgrade, (ITransparentUpgradeableProxy(address(dustLockProxy)), address(dustLockPredecessor))
        );
        payloads[2] = abi.encodeCall(
            ProxyAdmin.upgrade,
            (ITransparentUpgradeableProxy(address(revenueRewardProxy)), address(revenueRewardPredecessor))
        );
        payloads[3] = abi.encodeCall(DustLockTransferStrategy.assertActivationState, (false));
    }

    function _schedule(address[] memory targets, uint256[] memory values, bytes[] memory payloads, bytes32 salt)
        internal
    {
        vm.prank(operator);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, GOVERNANCE_DELAY);
    }

    function _scheduleAndExecute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory payloads,
        bytes32 salt
    ) internal {
        _schedule(targets, values, payloads, salt);
        vm.warp(block.timestamp + GOVERNANCE_DELAY + 1);
        vm.roll(block.number + 1);
        vm.prank(operator);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
    }

    function _assertImplementations(address expectedRevenueReward, address expectedDustLock) internal view {
        assertEq(
            proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(revenueRewardProxy))),
            expectedRevenueReward
        );
        assertEq(
            proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(dustLockProxy))), expectedDustLock
        );
    }

    function _snapshotStorage(address target, uint256 slotCount) internal view returns (bytes32[] memory snapshot) {
        snapshot = new bytes32[](slotCount);
        for (uint256 slot; slot < slotCount; ++slot) {
            snapshot[slot] = vm.load(target, bytes32(slot));
        }
    }

    function _assertStorageEquals(address target, bytes32[] memory expected) internal view {
        for (uint256 slot; slot < expected.length; ++slot) {
            assertEq(vm.load(target, bytes32(slot)), expected[slot]);
        }
    }
}
