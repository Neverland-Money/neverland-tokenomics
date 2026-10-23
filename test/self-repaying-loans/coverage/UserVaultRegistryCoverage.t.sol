// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {UserVaultRegistry} from "../../../src/self-repaying-loans/UserVaultRegistry.sol";

/**
 * @title UserVaultRegistryCoverage
 * @notice Coverage-focused unit tests for UserVaultRegistry.
 * @dev Deploys a fresh, standalone UserVaultRegistry so this test contract owns it
 *      (Ownable2Step sets msg.sender as the initial owner in the constructor). This lets
 *      the suite exercise every admin path, every view getter, and the access-control and
 *      renounceOwnership reverts against the ACTUAL current source — which uses a bare
 *      `revert()` for renounceOwnership, performs NO zero-address validation in
 *      setSupportedAggregators, and has NO upper bound on setMaxSwapSlippageBps.
 */
contract UserVaultRegistryCoverageTest is Test {
    UserVaultRegistry internal registry;

    address internal owner = address(this);
    address internal stranger = makeAddr("stranger");
    address internal executorA = makeAddr("executorA");
    address internal executorB = makeAddr("executorB");
    address internal aggregator = makeAddr("aggregator");

    /// @dev Mirror of the interface event layout so expectEmit can be asserted locally.
    event ExecutorUpdated(address indexed oldExecutor, address indexed newExecutor);
    event AggregatorSupportUpdated(address indexed aggregator, bool isActive);
    event MaxSwapSlippageUpdated(uint256 oldValue, uint256 newValue);

    function setUp() public {
        // Deploy fresh; constructor leaves msg.sender (this contract) as owner.
        registry = new UserVaultRegistry();
    }

    /*//////////////////////////////////////////////////////////////
                          DEPLOYMENT / DEFAULTS
    //////////////////////////////////////////////////////////////*/

    function testInitialOwnerIsDeployer() public view {
        assertEq(registry.owner(), owner, "deployer is owner");
    }

    function testDefaultStateIsZeroed() public view {
        assertEq(registry.executor(), address(0), "executor defaults to zero");
        assertEq(registry.maxSwapSlippageBps(), 0, "slippage defaults to zero");
        assertFalse(registry.isSupportedAggregator(aggregator), "aggregator unsupported by default");
    }

    /*//////////////////////////////////////////////////////////////
                              setExecutor
    //////////////////////////////////////////////////////////////*/

    function testSetExecutorUpdatesState() public {
        registry.setExecutor(executorA);

        assertEq(registry.executor(), executorA, "executor set");
    }

    function testSetExecutorEmitsEventWithOldAndNew() public {
        // First set establishes a non-zero "old" value for the second emission.
        registry.setExecutor(executorA);

        vm.expectEmit(true, true, false, false);
        emit ExecutorUpdated(executorA, executorB);

        registry.setExecutor(executorB);

        assertEq(registry.executor(), executorB, "executor updated");
    }

    function testSetExecutorFromZeroOldValueEmitsZeroOld() public {
        vm.expectEmit(true, true, false, false);
        emit ExecutorUpdated(address(0), executorA);

        registry.setExecutor(executorA);
    }

    function testSetExecutorRevertsOnZeroAddress() public {
        // CommonChecksLibrary.revertIfZeroAddress fires before any state write.
        vm.expectRevert();
        registry.setExecutor(address(0));

        assertEq(registry.executor(), address(0), "executor unchanged after revert");
    }

    function testSetExecutorOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        registry.setExecutor(executorA);
    }

    /*//////////////////////////////////////////////////////////////
                         setSupportedAggregators
    //////////////////////////////////////////////////////////////*/

    function testSetSupportedAggregatorActivate() public {
        registry.setSupportedAggregators(aggregator, true);

        assertTrue(registry.isSupportedAggregator(aggregator), "aggregator activated");
    }

    function testSetSupportedAggregatorDeactivate() public {
        registry.setSupportedAggregators(aggregator, true);
        assertTrue(registry.isSupportedAggregator(aggregator), "activated first");

        registry.setSupportedAggregators(aggregator, false);

        assertFalse(registry.isSupportedAggregator(aggregator), "aggregator deactivated");
    }

    function testSetSupportedAggregatorEmitsActivate() public {
        vm.expectEmit(true, false, false, true);
        emit AggregatorSupportUpdated(aggregator, true);

        registry.setSupportedAggregators(aggregator, true);
    }

    function testSetSupportedAggregatorEmitsDeactivate() public {
        vm.expectEmit(true, false, false, true);
        emit AggregatorSupportUpdated(aggregator, false);

        registry.setSupportedAggregators(aggregator, false);
    }

    /// @dev Current source does NOT validate the zero address here — confirm it is allowed.
    function testSetSupportedAggregatorAllowsZeroAddress() public {
        registry.setSupportedAggregators(address(0), true);

        assertTrue(registry.isSupportedAggregator(address(0)), "zero address can be marked supported");
    }

    function testSetSupportedAggregatorOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        registry.setSupportedAggregators(aggregator, true);
    }

    /*//////////////////////////////////////////////////////////////
                          setMaxSwapSlippageBps
    //////////////////////////////////////////////////////////////*/

    function testSetMaxSwapSlippageBpsUpdatesState() public {
        registry.setMaxSwapSlippageBps(250);

        assertEq(registry.maxSwapSlippageBps(), 250, "slippage set");
    }

    function testSetMaxSwapSlippageBpsEmitsEvent() public {
        registry.setMaxSwapSlippageBps(100);

        vm.expectEmit(false, false, false, true);
        emit MaxSwapSlippageUpdated(100, 300);

        registry.setMaxSwapSlippageBps(300);

        assertEq(registry.maxSwapSlippageBps(), 300, "slippage updated");
    }

    function testSetMaxSwapSlippageBpsEmitsZeroOldFirstTime() public {
        vm.expectEmit(false, false, false, true);
        emit MaxSwapSlippageUpdated(0, 500);

        registry.setMaxSwapSlippageBps(500);
    }

    /// @dev No MAX_SWAP_SLIPPAGE_BPS constant / no upper bound in current source — large values accepted.
    function testSetMaxSwapSlippageBpsAllowsArbitrarilyLargeValue() public {
        registry.setMaxSwapSlippageBps(type(uint256).max);

        assertEq(registry.maxSwapSlippageBps(), type(uint256).max, "no upper bound enforced");
    }

    function testSetMaxSwapSlippageBpsAllowsZero() public {
        registry.setMaxSwapSlippageBps(750);
        registry.setMaxSwapSlippageBps(0);

        assertEq(registry.maxSwapSlippageBps(), 0, "can reset to zero");
    }

    function testSetMaxSwapSlippageBpsOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        registry.setMaxSwapSlippageBps(100);
    }

    function testSetMaxSwapSlippageBpsFuzz(uint256 value) public {
        registry.setMaxSwapSlippageBps(value);

        assertEq(registry.maxSwapSlippageBps(), value, "fuzz slippage stored verbatim");
    }

    /*//////////////////////////////////////////////////////////////
                          renounceOwnership
    //////////////////////////////////////////////////////////////*/

    /// @dev Current source disables renounce with a BARE `revert()` (no named error).
    function testRenounceOwnershipRevertsForOwner() public {
        vm.expectRevert();
        registry.renounceOwnership();

        assertEq(registry.owner(), owner, "owner unchanged");
    }

    function testRenounceOwnershipRevertsForNonOwner() public {
        // onlyOwner gate fires for a non-owner caller before the bare revert.
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        registry.renounceOwnership();

        assertEq(registry.owner(), owner, "owner unchanged");
    }

    /*//////////////////////////////////////////////////////////////
                       OWNABLE2STEP TRANSFER FLOW
    //////////////////////////////////////////////////////////////*/

    function testTransferOwnershipIsTwoStep() public {
        registry.transferOwnership(stranger);

        // Ownership does not move until accepted.
        assertEq(registry.owner(), owner, "owner unchanged before acceptance");
        assertEq(registry.pendingOwner(), stranger, "pending owner recorded");

        vm.prank(stranger);
        registry.acceptOwnership();

        assertEq(registry.owner(), stranger, "ownership transferred after acceptance");
        assertEq(registry.pendingOwner(), address(0), "pending owner cleared");
    }

    function testTransferOwnershipOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        registry.transferOwnership(stranger);
    }

    function testAcceptOwnershipOnlyPendingOwner() public {
        registry.transferOwnership(stranger);

        vm.prank(executorA);
        vm.expectRevert("Ownable2Step: caller is not the new owner");
        registry.acceptOwnership();
    }

    function testNewOwnerCanAdministerAfterTransfer() public {
        registry.transferOwnership(stranger);
        vm.prank(stranger);
        registry.acceptOwnership();

        // New owner can set state.
        vm.prank(stranger);
        registry.setExecutor(executorA);
        assertEq(registry.executor(), executorA, "new owner can set executor");

        // Old owner can no longer.
        vm.expectRevert("Ownable: caller is not the owner");
        registry.setExecutor(executorB);
    }
}
