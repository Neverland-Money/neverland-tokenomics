// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IAccessControl} from "@openzeppelin-v5/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin-v5/contracts/governance/TimelockController.sol";

import {NeverlandTimelockController} from "../../src/governance/NeverlandTimelockController.sol";
import {MockGovernedValue} from "./mocks/MockGovernedValue.sol";
import {MockGovernedValueV2} from "./mocks/MockGovernedValueV2.sol";
import {MockOwnableBeacon} from "./mocks/MockOwnableBeacon.sol";

contract TokenomicsUpgradeTimelockTest is Test {
    // This test intentionally mixes OZ v4 proxy admin surfaces with the v5
    // governance timelock because that matches the repo's production boundary:
    // legacy upgradeability stays on the existing v4 lineage, while new
    // governance-only code imports from the separate v5 namespace.
    uint256 internal constant GOVERNANCE_DELAY = 24 hours;
    uint256 internal constant RISK_DELAY = 1 hours;

    address internal operator = makeAddr("operator");
    address internal outsider = makeAddr("outsider");

    NeverlandTimelockController internal governanceTimelock;
    NeverlandTimelockController internal riskTimelock;
    MockGovernedValue internal proxiedValue;
    MockGovernedValueV2 internal proxyImplV2;
    MockGovernedValueV2 internal mutableTarget;
    MockOwnableBeacon internal beacon;
    MockGovernedValueV2 internal beaconImplV2;
    ProxyAdmin internal proxyAdmin;
    TransparentUpgradeableProxy internal proxy;

    function setUp() public {
        governanceTimelock = new NeverlandTimelockController(
            GOVERNANCE_DELAY, GOVERNANCE_DELAY, _singleOperatorArray(), _singleOperatorArray(), address(this)
        );
        riskTimelock = new NeverlandTimelockController(
            RISK_DELAY, RISK_DELAY, _singleOperatorArray(), _singleOperatorArray(), address(this)
        );

        MockGovernedValue proxyImplV1 = new MockGovernedValue();
        proxyImplV2 = new MockGovernedValueV2();

        MockGovernedValue beaconImplV1 = new MockGovernedValue();
        beaconImplV2 = new MockGovernedValueV2();
        mutableTarget = new MockGovernedValueV2();

        proxyAdmin = new ProxyAdmin();
        proxy = new TransparentUpgradeableProxy(
            address(proxyImplV1), address(proxyAdmin), abi.encodeCall(MockGovernedValue.initialize, (1))
        );
        proxiedValue = MockGovernedValue(address(proxy));

        beacon = new MockOwnableBeacon(address(this), address(beaconImplV1));

        proxyAdmin.transferOwnership(address(governanceTimelock));
        beacon.transferOwnership(address(governanceTimelock));
    }

    function test_blocksDirectProxyUpgradesOnceProxyAdminOwnershipMovesToGovernanceTimelock() public {
        vm.prank(outsider);
        vm.expectRevert("Ownable: caller is not the owner");
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(payable(address(proxy))), address(proxyImplV2));
    }

    function test_requiresGovernanceDelayBeforeUpgradingATransparentProxy() public {
        assertEq(proxiedValue.version(), 1);

        bytes memory upgradeData = abi.encodeWithSelector(
            ProxyAdmin.upgrade.selector, ITransparentUpgradeableProxy(payable(address(proxy))), address(proxyImplV2)
        );
        bytes32 salt = keccak256("proxy-upgrade");
        bytes32 operationId = governanceTimelock.hashOperation(address(proxyAdmin), 0, upgradeData, bytes32(0), salt);

        vm.prank(operator);
        governanceTimelock.schedule(address(proxyAdmin), 0, upgradeData, bytes32(0), salt, GOVERNANCE_DELAY);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                operationId,
                bytes32(uint256(1) << uint8(TimelockController.OperationState.Ready))
            )
        );
        governanceTimelock.execute(address(proxyAdmin), 0, upgradeData, bytes32(0), salt);

        vm.warp(block.timestamp + GOVERNANCE_DELAY + 1);
        vm.roll(block.number + 1);

        vm.prank(operator);
        governanceTimelock.execute(address(proxyAdmin), 0, upgradeData, bytes32(0), salt);

        assertEq(proxiedValue.version(), 2);
    }

    function test_cancelledOperationsReturnToUnsetAndCanBeRescheduledWithANewSalt() public {
        bytes memory upgradeData = abi.encodeWithSelector(
            ProxyAdmin.upgrade.selector, ITransparentUpgradeableProxy(payable(address(proxy))), address(proxyImplV2)
        );
        bytes32 cancelledSalt = keccak256("cancelled-proxy-upgrade");
        bytes32 cancelledOperationId =
            governanceTimelock.hashOperation(address(proxyAdmin), 0, upgradeData, bytes32(0), cancelledSalt);

        vm.prank(operator);
        governanceTimelock.schedule(address(proxyAdmin), 0, upgradeData, bytes32(0), cancelledSalt, GOVERNANCE_DELAY);

        vm.prank(operator);
        governanceTimelock.cancel(cancelledOperationId);

        assertEq(
            uint256(governanceTimelock.getOperationState(cancelledOperationId)),
            uint256(TimelockController.OperationState.Unset)
        );

        vm.warp(block.timestamp + GOVERNANCE_DELAY + 1);
        vm.roll(block.number + 1);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, cancelledOperationId, _readyBitmap()
            )
        );
        governanceTimelock.execute(address(proxyAdmin), 0, upgradeData, bytes32(0), cancelledSalt);

        bytes32 replacementSalt = keccak256("replacement-proxy-upgrade");
        _scheduleAndExecute(governanceTimelock, address(proxyAdmin), upgradeData, replacementSalt, GOVERNANCE_DELAY);

        assertEq(proxiedValue.version(), 2);
    }

    function test_letsGovernanceTimelockUpgradeABeaconButBlocksRiskTimelockFromThatOwnerSurface() public {
        bytes memory beaconUpgradeData = abi.encodeCall(MockOwnableBeacon.upgradeTo, (address(beaconImplV2)));

        _scheduleAndExecute(
            governanceTimelock, address(beacon), beaconUpgradeData, keccak256("beacon-upgrade"), GOVERNANCE_DELAY
        );

        assertEq(beacon.implementation(), address(beaconImplV2));

        bytes32 riskSalt = keccak256("risk-beacon-upgrade");
        vm.prank(operator);
        riskTimelock.schedule(address(beacon), 0, beaconUpgradeData, bytes32(0), riskSalt, RISK_DELAY);

        vm.warp(block.timestamp + RISK_DELAY + 1);
        vm.roll(block.number + 1);

        vm.prank(operator);
        vm.expectRevert("Ownable: caller is not the owner");
        riskTimelock.execute(address(beacon), 0, beaconUpgradeData, bytes32(0), riskSalt);
    }

    function test_beaconRejectsZeroImplementationUpgrade() public {
        vm.prank(address(governanceTimelock));
        vm.expectRevert("OwnableBeacon: new implementation is the zero address");
        beacon.upgradeTo(address(0));
    }

    function test_predecessorLinkedOperationsCannotExecuteOutOfOrder() public {
        bytes memory firstData = abi.encodeCall(MockGovernedValueV2.setValue, (11));
        bytes memory secondData = abi.encodeCall(MockGovernedValueV2.setValue, (22));
        bytes32 firstSalt = keccak256("predecessor-first");
        bytes32 secondSalt = keccak256("predecessor-second");
        bytes32 firstOperationId =
            governanceTimelock.hashOperation(address(mutableTarget), 0, firstData, bytes32(0), firstSalt);

        vm.prank(operator);
        governanceTimelock.schedule(address(mutableTarget), 0, firstData, bytes32(0), firstSalt, GOVERNANCE_DELAY);

        vm.prank(operator);
        governanceTimelock.schedule(
            address(mutableTarget), 0, secondData, firstOperationId, secondSalt, GOVERNANCE_DELAY
        );

        vm.warp(block.timestamp + GOVERNANCE_DELAY + 1);
        vm.roll(block.number + 1);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockUnexecutedPredecessor.selector, firstOperationId)
        );
        governanceTimelock.execute(address(mutableTarget), 0, secondData, firstOperationId, secondSalt);

        vm.prank(operator);
        governanceTimelock.execute(address(mutableTarget), 0, firstData, bytes32(0), firstSalt);

        vm.prank(operator);
        governanceTimelock.execute(address(mutableTarget), 0, secondData, firstOperationId, secondSalt);

        assertEq(mutableTarget.value(), 22);
    }

    function test_valueBearingExecutionForwardsEthWhenTheOuterExecuteCallFundsTheTimelock() public {
        address payable recipient = payable(makeAddr("recipient"));
        uint256 transferValue = 1 ether;
        bytes32 salt = keccak256("value-transfer");

        vm.deal(operator, transferValue);

        vm.prank(operator);
        governanceTimelock.schedule(recipient, transferValue, "", bytes32(0), salt, GOVERNANCE_DELAY);

        vm.warp(block.timestamp + GOVERNANCE_DELAY + 1);
        vm.roll(block.number + 1);

        uint256 recipientBalanceBefore = recipient.balance;

        vm.prank(operator);
        governanceTimelock.execute{value: transferValue}(recipient, transferValue, "", bytes32(0), salt);

        assertEq(recipient.balance, recipientBalanceBefore + transferValue);
        assertEq(address(governanceTimelock).balance, 0);
    }

    function test_timelockSelfAdminRemainsAfterDeployerRenounceAndRoleChangesMustGoThroughScheduledOperations() public {
        bytes32 defaultAdminRole = governanceTimelock.DEFAULT_ADMIN_ROLE();
        bytes32 proposerRole = governanceTimelock.PROPOSER_ROLE();

        assertTrue(governanceTimelock.hasRole(defaultAdminRole, address(governanceTimelock)));
        assertTrue(governanceTimelock.hasRole(defaultAdminRole, address(this)));

        governanceTimelock.renounceRole(defaultAdminRole, address(this));

        assertTrue(governanceTimelock.hasRole(defaultAdminRole, address(governanceTimelock)));
        assertFalse(governanceTimelock.hasRole(defaultAdminRole, address(this)));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), defaultAdminRole
            )
        );
        governanceTimelock.grantRole(proposerRole, outsider);

        bytes memory grantRoleData =
            abi.encodeWithSelector(governanceTimelock.grantRole.selector, proposerRole, outsider);
        _scheduleAndExecute(
            governanceTimelock,
            address(governanceTimelock),
            grantRoleData,
            keccak256("grant-proposer"),
            GOVERNANCE_DELAY
        );

        assertTrue(governanceTimelock.hasRole(proposerRole, outsider));
    }

    function test_updateDelayRevertsWhenBelowFloor() public {
        bytes memory updateData = abi.encodeCall(governanceTimelock.updateDelay, (0));
        bytes32 salt = keccak256("lower-delay-below-floor");

        vm.prank(operator);
        governanceTimelock.schedule(address(governanceTimelock), 0, updateData, bytes32(0), salt, GOVERNANCE_DELAY);

        vm.warp(block.timestamp + GOVERNANCE_DELAY + 1);
        vm.roll(block.number + 1);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(NeverlandTimelockController.DelayBelowMinimumFloor.selector, 0, GOVERNANCE_DELAY)
        );
        governanceTimelock.execute(address(governanceTimelock), 0, updateData, bytes32(0), salt);
    }

    function test_updateDelayRevertsForDirectUnauthorizedCaller() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, outsider));
        governanceTimelock.updateDelay(0);
    }

    function test_batchExecutionRevertsWhenUpdateDelayFallsBelowFloor() public {
        address[] memory targets = new address[](2);
        targets[0] = address(mutableTarget);
        targets[1] = address(governanceTimelock);

        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeCall(MockGovernedValueV2.setValue, (11));
        payloads[1] = abi.encodeCall(governanceTimelock.updateDelay, (0));
        bytes32 salt = keccak256("batch-lower-delay-below-floor");

        vm.prank(operator);
        governanceTimelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, GOVERNANCE_DELAY);

        vm.warp(block.timestamp + GOVERNANCE_DELAY + 1);
        vm.roll(block.number + 1);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(NeverlandTimelockController.DelayBelowMinimumFloor.selector, 0, GOVERNANCE_DELAY)
        );
        governanceTimelock.executeBatch(targets, values, payloads, bytes32(0), salt);

        assertEq(mutableTarget.value(), 0);
        assertEq(governanceTimelock.getMinDelay(), GOVERNANCE_DELAY);
    }

    function test_updateDelaySucceedsAboveFloor() public {
        uint256 newDelay = 48 hours;
        bytes memory updateData = abi.encodeCall(governanceTimelock.updateDelay, (newDelay));
        bytes32 salt = keccak256("raise-delay-above-floor");

        _scheduleAndExecute(governanceTimelock, address(governanceTimelock), updateData, salt, GOVERNANCE_DELAY);

        assertEq(governanceTimelock.getMinDelay(), newDelay);
    }

    function test_updateDelaySucceedsAtExactFloor() public {
        uint256 raised = 48 hours;
        bytes memory raiseData = abi.encodeCall(governanceTimelock.updateDelay, (raised));
        _scheduleAndExecute(
            governanceTimelock, address(governanceTimelock), raiseData, keccak256("raise-first"), GOVERNANCE_DELAY
        );
        assertEq(governanceTimelock.getMinDelay(), raised);

        bytes memory lowerData = abi.encodeCall(governanceTimelock.updateDelay, (GOVERNANCE_DELAY));
        _scheduleAndExecute(
            governanceTimelock, address(governanceTimelock), lowerData, keccak256("lower-to-floor"), raised
        );
        assertEq(governanceTimelock.getMinDelay(), GOVERNANCE_DELAY);
    }

    function test_constructorRevertsWhenDelayBelowFloor() public {
        vm.expectRevert(
            abi.encodeWithSelector(NeverlandTimelockController.DelayBelowMinimumFloor.selector, 1 hours, 24 hours)
        );
        new NeverlandTimelockController(
            1 hours, 24 hours, _singleOperatorArray(), _singleOperatorArray(), address(this)
        );
    }

    function test_riskTimelockUpdateDelayRevertsWhenBelowFloor() public {
        bytes memory updateData = abi.encodeCall(riskTimelock.updateDelay, (30 minutes));
        bytes32 salt = keccak256("risk-lower-delay-below-floor");

        vm.prank(operator);
        riskTimelock.schedule(address(riskTimelock), 0, updateData, bytes32(0), salt, RISK_DELAY);

        vm.warp(block.timestamp + RISK_DELAY + 1);
        vm.roll(block.number + 1);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(NeverlandTimelockController.DelayBelowMinimumFloor.selector, 30 minutes, RISK_DELAY)
        );
        riskTimelock.execute(address(riskTimelock), 0, updateData, bytes32(0), salt);
    }

    function test_minDelayFloorIsReadable() public view {
        assertEq(governanceTimelock.MIN_DELAY_FLOOR(), GOVERNANCE_DELAY);
        assertEq(riskTimelock.MIN_DELAY_FLOOR(), RISK_DELAY);
    }

    function _scheduleAndExecute(
        NeverlandTimelockController timelock,
        address target,
        bytes memory data,
        bytes32 salt,
        uint256 delay
    ) internal {
        vm.prank(operator);
        timelock.schedule(target, 0, data, bytes32(0), salt, delay);

        vm.warp(block.timestamp + delay + 1);
        vm.roll(block.number + 1);

        vm.prank(operator);
        timelock.execute(target, 0, data, bytes32(0), salt);
    }

    function _singleOperatorArray() internal view returns (address[] memory operators) {
        operators = new address[](1);
        operators[0] = operator;
    }

    function _readyBitmap() internal pure returns (bytes32) {
        return bytes32(uint256(1) << uint8(TimelockController.OperationState.Ready));
    }
}
