// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AccessControl} from "@openzeppelin-v5/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin-v5/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin-v5/contracts/governance/TimelockController.sol";

import {NeverlandTimelockController} from "../../src/governance/NeverlandTimelockController.sol";
import {MockGovernedValue} from "./mocks/MockGovernedValue.sol";
import {MockGovernedValueV2} from "./mocks/MockGovernedValueV2.sol";

contract MockRunbookLendingSurface is AccessControl {
    bytes32 public constant POOL_ADMIN_ROLE = keccak256("POOL_ADMIN");
    bytes32 public constant RISK_ADMIN_ROLE = keccak256("RISK_ADMIN");

    mapping(address => uint256) public supplyCaps;
    mapping(address => address) public assetSources;

    constructor(
        address initialAdmin,
        address initialPoolAdmin,
        address initialRiskAdmin,
        address usdcAsset,
        uint256 initialSupplyCap,
        address initialOracle
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(POOL_ADMIN_ROLE, initialPoolAdmin);
        _grantRole(RISK_ADMIN_ROLE, initialRiskAdmin);

        supplyCaps[usdcAsset] = initialSupplyCap;
        assetSources[usdcAsset] = initialOracle;
    }

    function setSupplyCap(address asset, uint256 newSupplyCap) external onlyRole(RISK_ADMIN_ROLE) {
        supplyCaps[asset] = newSupplyCap;
    }

    function setAssetSources(address[] calldata assets, address[] calldata sources) external onlyRole(POOL_ADMIN_ROLE) {
        require(assets.length == sources.length, "length mismatch");
        for (uint256 i = 0; i < assets.length; i++) {
            assetSources[assets[i]] = sources[i];
        }
    }
}

contract RunbookProofFlowTimelockTest is Test {
    uint256 internal constant GOVERNANCE_DELAY = 24 hours;
    uint256 internal constant RISK_DELAY = 1 hours;
    uint256 internal constant INITIAL_SUPPLY_CAP = 80_000_000;
    uint256 internal constant UPDATED_SUPPLY_CAP = 81_000_000;

    address internal governanceSafe = makeAddr("governanceSafe");
    address internal deployer = makeAddr("deployer");
    address internal outsider = makeAddr("outsider");
    address internal usdc = makeAddr("USDC");
    address internal currentOracle = makeAddr("currentOracle");
    address internal replacementOracle = makeAddr("replacementOracle");

    NeverlandTimelockController internal governanceTimelock;
    NeverlandTimelockController internal riskTimelock;
    MockRunbookLendingSurface internal lendingSurface;
    MockGovernedValue internal proxiedDust;
    MockGovernedValueV2 internal dustImplV2;
    ProxyAdmin internal proxyAdmin;
    TransparentUpgradeableProxy internal dustProxy;

    function setUp() public {
        governanceTimelock = new NeverlandTimelockController(
            GOVERNANCE_DELAY, GOVERNANCE_DELAY, _singleOperatorArray(), _singleOperatorArray(), address(this)
        );
        riskTimelock = new NeverlandTimelockController(
            RISK_DELAY, RISK_DELAY, _singleOperatorArray(), _singleOperatorArray(), address(this)
        );

        lendingSurface = new MockRunbookLendingSurface(
            governanceSafe, governanceSafe, governanceSafe, usdc, INITIAL_SUPPLY_CAP, currentOracle
        );

        vm.startPrank(governanceSafe);
        lendingSurface.grantRole(lendingSurface.DEFAULT_ADMIN_ROLE(), address(governanceTimelock));
        lendingSurface.grantRole(lendingSurface.POOL_ADMIN_ROLE(), address(governanceTimelock));
        lendingSurface.grantRole(lendingSurface.RISK_ADMIN_ROLE(), address(riskTimelock));
        lendingSurface.revokeRole(lendingSurface.POOL_ADMIN_ROLE(), governanceSafe);
        lendingSurface.revokeRole(lendingSurface.RISK_ADMIN_ROLE(), governanceSafe);
        lendingSurface.revokeRole(lendingSurface.DEFAULT_ADMIN_ROLE(), governanceSafe);
        vm.stopPrank();

        MockGovernedValue dustImplV1 = new MockGovernedValue();
        dustImplV2 = new MockGovernedValueV2();

        vm.startPrank(deployer);
        proxyAdmin = new ProxyAdmin();
        dustProxy = new TransparentUpgradeableProxy(
            address(dustImplV1), address(proxyAdmin), abi.encodeCall(MockGovernedValue.initialize, (1))
        );
        proxyAdmin.transferOwnership(address(governanceTimelock));
        vm.stopPrank();

        proxiedDust = MockGovernedValue(address(dustProxy));
    }

    function test_onlyFoundationSafeCanScheduleAndExecuteRunbookOperations() public {
        bytes memory supplyCapData = abi.encodeCall(MockRunbookLendingSurface.setSupplyCap, (usdc, UPDATED_SUPPLY_CAP));
        bytes32 salt = keccak256("risk-operator-check");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, riskTimelock.PROPOSER_ROLE()
            )
        );
        vm.prank(outsider);
        riskTimelock.schedule(address(lendingSurface), 0, supplyCapData, bytes32(0), salt, RISK_DELAY);

        vm.prank(governanceSafe);
        riskTimelock.schedule(address(lendingSurface), 0, supplyCapData, bytes32(0), salt, RISK_DELAY);

        vm.warp(block.timestamp + RISK_DELAY + 1);
        vm.roll(block.number + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, riskTimelock.EXECUTOR_ROLE()
            )
        );
        vm.prank(outsider);
        riskTimelock.execute(address(lendingSurface), 0, supplyCapData, bytes32(0), salt);

        vm.prank(governanceSafe);
        riskTimelock.execute(address(lendingSurface), 0, supplyCapData, bytes32(0), salt);

        assertEq(lendingSurface.supplyCaps(usdc), UPDATED_SUPPLY_CAP);
    }

    function test_runbookRiskLaneSupplyCapRequiresDelayAndBlocksDirectCallersAndWrongLane() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                governanceSafe,
                lendingSurface.RISK_ADMIN_ROLE()
            )
        );
        vm.prank(governanceSafe);
        lendingSurface.setSupplyCap(usdc, UPDATED_SUPPLY_CAP);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, lendingSurface.RISK_ADMIN_ROLE()
            )
        );
        vm.prank(deployer);
        lendingSurface.setSupplyCap(usdc, UPDATED_SUPPLY_CAP);

        bytes memory supplyCapData = abi.encodeCall(MockRunbookLendingSurface.setSupplyCap, (usdc, UPDATED_SUPPLY_CAP));
        bytes32 correctSalt = keccak256("risk-supply-cap");
        bytes32 operationId =
            riskTimelock.hashOperation(address(lendingSurface), 0, supplyCapData, bytes32(0), correctSalt);

        vm.prank(governanceSafe);
        riskTimelock.schedule(address(lendingSurface), 0, supplyCapData, bytes32(0), correctSalt, RISK_DELAY);

        assertEq(
            uint256(riskTimelock.getOperationState(operationId)), uint256(TimelockController.OperationState.Waiting)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, operationId, _readyBitmap()
            )
        );
        vm.prank(governanceSafe);
        riskTimelock.execute(address(lendingSurface), 0, supplyCapData, bytes32(0), correctSalt);

        vm.warp(block.timestamp + RISK_DELAY + 1);
        vm.roll(block.number + 1);

        assertEq(uint256(riskTimelock.getOperationState(operationId)), uint256(TimelockController.OperationState.Ready));

        vm.prank(governanceSafe);
        riskTimelock.execute(address(lendingSurface), 0, supplyCapData, bytes32(0), correctSalt);

        assertEq(lendingSurface.supplyCaps(usdc), UPDATED_SUPPLY_CAP);
        assertEq(uint256(riskTimelock.getOperationState(operationId)), uint256(TimelockController.OperationState.Done));

        bytes memory wrongLaneData =
            abi.encodeCall(MockRunbookLendingSurface.setSupplyCap, (usdc, UPDATED_SUPPLY_CAP + 1_000_000));
        bytes32 wrongLaneSalt = keccak256("governance-wrong-supply-cap");

        vm.prank(governanceSafe);
        governanceTimelock.schedule(
            address(lendingSurface), 0, wrongLaneData, bytes32(0), wrongLaneSalt, GOVERNANCE_DELAY
        );

        vm.warp(block.timestamp + GOVERNANCE_DELAY + 1);
        vm.roll(block.number + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(governanceTimelock),
                lendingSurface.RISK_ADMIN_ROLE()
            )
        );
        vm.prank(governanceSafe);
        governanceTimelock.execute(address(lendingSurface), 0, wrongLaneData, bytes32(0), wrongLaneSalt);
    }

    function test_runbookGovernanceLaneOracleRequiresDelayAndBlocksDirectCallersAndWrongLane() public {
        address[] memory assets = new address[](1);
        assets[0] = usdc;
        address[] memory replacementSources = new address[](1);
        replacementSources[0] = replacementOracle;

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                governanceSafe,
                lendingSurface.POOL_ADMIN_ROLE()
            )
        );
        vm.prank(governanceSafe);
        lendingSurface.setAssetSources(assets, replacementSources);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, lendingSurface.POOL_ADMIN_ROLE()
            )
        );
        vm.prank(deployer);
        lendingSurface.setAssetSources(assets, replacementSources);

        bytes memory oracleData =
            abi.encodeCall(MockRunbookLendingSurface.setAssetSources, (assets, replacementSources));
        bytes32 correctSalt = keccak256("governance-oracle-update");
        bytes32 operationId =
            governanceTimelock.hashOperation(address(lendingSurface), 0, oracleData, bytes32(0), correctSalt);

        vm.prank(governanceSafe);
        governanceTimelock.schedule(address(lendingSurface), 0, oracleData, bytes32(0), correctSalt, GOVERNANCE_DELAY);

        assertEq(
            uint256(governanceTimelock.getOperationState(operationId)),
            uint256(TimelockController.OperationState.Waiting)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, operationId, _readyBitmap()
            )
        );
        vm.prank(governanceSafe);
        governanceTimelock.execute(address(lendingSurface), 0, oracleData, bytes32(0), correctSalt);

        vm.warp(block.timestamp + GOVERNANCE_DELAY + 1);
        vm.roll(block.number + 1);

        assertEq(
            uint256(governanceTimelock.getOperationState(operationId)), uint256(TimelockController.OperationState.Ready)
        );

        vm.prank(governanceSafe);
        governanceTimelock.execute(address(lendingSurface), 0, oracleData, bytes32(0), correctSalt);

        assertEq(lendingSurface.assetSources(usdc), replacementOracle);
        assertEq(
            uint256(governanceTimelock.getOperationState(operationId)), uint256(TimelockController.OperationState.Done)
        );

        address[] memory wrongSources = new address[](1);
        wrongSources[0] = makeAddr("wrongLaneOracle");
        bytes memory wrongLaneData = abi.encodeCall(MockRunbookLendingSurface.setAssetSources, (assets, wrongSources));
        bytes32 wrongLaneSalt = keccak256("risk-wrong-oracle-update");

        vm.prank(governanceSafe);
        riskTimelock.schedule(address(lendingSurface), 0, wrongLaneData, bytes32(0), wrongLaneSalt, RISK_DELAY);

        vm.warp(block.timestamp + RISK_DELAY + 1);
        vm.roll(block.number + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(riskTimelock),
                lendingSurface.POOL_ADMIN_ROLE()
            )
        );
        vm.prank(governanceSafe);
        riskTimelock.execute(address(lendingSurface), 0, wrongLaneData, bytes32(0), wrongLaneSalt);
    }

    function test_runbookGovernanceLaneDustUpgradeRequiresDelayAndBlocksDirectCallersAndWrongLane() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(governanceSafe);
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(payable(address(dustProxy))), address(dustImplV2));

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(deployer);
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(payable(address(dustProxy))), address(dustImplV2));

        bytes memory upgradeData = abi.encodeWithSelector(
            ProxyAdmin.upgrade.selector, ITransparentUpgradeableProxy(payable(address(dustProxy))), address(dustImplV2)
        );
        bytes32 correctSalt = keccak256("governance-dust-upgrade");
        bytes32 operationId =
            governanceTimelock.hashOperation(address(proxyAdmin), 0, upgradeData, bytes32(0), correctSalt);

        vm.prank(governanceSafe);
        governanceTimelock.schedule(address(proxyAdmin), 0, upgradeData, bytes32(0), correctSalt, GOVERNANCE_DELAY);

        assertEq(
            uint256(governanceTimelock.getOperationState(operationId)),
            uint256(TimelockController.OperationState.Waiting)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, operationId, _readyBitmap()
            )
        );
        vm.prank(governanceSafe);
        governanceTimelock.execute(address(proxyAdmin), 0, upgradeData, bytes32(0), correctSalt);

        vm.warp(block.timestamp + GOVERNANCE_DELAY + 1);
        vm.roll(block.number + 1);

        vm.prank(governanceSafe);
        governanceTimelock.execute(address(proxyAdmin), 0, upgradeData, bytes32(0), correctSalt);

        assertEq(proxiedDust.version(), 2);
        assertEq(
            uint256(governanceTimelock.getOperationState(operationId)), uint256(TimelockController.OperationState.Done)
        );

        bytes32 wrongLaneSalt = keccak256("risk-dust-upgrade");
        vm.prank(governanceSafe);
        riskTimelock.schedule(address(proxyAdmin), 0, upgradeData, bytes32(0), wrongLaneSalt, RISK_DELAY);

        vm.warp(block.timestamp + RISK_DELAY + 1);
        vm.roll(block.number + 1);

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(governanceSafe);
        riskTimelock.execute(address(proxyAdmin), 0, upgradeData, bytes32(0), wrongLaneSalt);
    }

    function _singleOperatorArray() internal view returns (address[] memory operators) {
        operators = new address[](1);
        operators[0] = governanceSafe;
    }

    function _readyBitmap() internal pure returns (bytes32) {
        return bytes32(uint256(1) << uint8(TimelockController.OperationState.Ready));
    }
}
