// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IEpochManager} from "../../../src/interfaces/IEpochManager.sol";

import "./LeaderboardBase.sol";

contract EpochManagerTest is LeaderboardBase {
    function testInitialState() public view {
        assertEq(epochManager.currentEpoch(), 0, "Should start at epoch 0");
        assertEq(epochManager.currentEpochStartTime(), 0, "Should have no start time");
        assertFalse(epochManager.hasStarted(), "Leaderboard should not have started");
    }

    function testStartFirstEpoch() public {
        uint256 startTime = block.timestamp;

        vm.prank(admin);
        epochManager.startNewEpoch(0);

        assertEq(epochManager.currentEpoch(), 1, "Should be epoch 1");
        assertEq(epochManager.currentEpochStartTime(), startTime, "Start time should match");
        assertTrue(epochManager.hasStarted(), "Leaderboard should have started");

        // New epoch should be active
        assertTrue(epochManager.isEpochActive(1), "Epoch 1 should be active");
    }

    function testStartFirstEpochOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        epochManager.startNewEpoch(0);
    }

    function testTransitionToSecondEpoch() public {
        // Start epoch 1
        vm.prank(admin);
        epochManager.startNewEpoch(0);

        uint256 epoch1StartTime = epochManager.currentEpochStartTime();

        // Advance time
        skip(30 days);

        uint256 epoch1EndTime = block.timestamp;

        // End epoch 1
        vm.prank(admin);
        epochManager.endCurrentEpoch(0);

        // Advance a bit more for epoch 2
        skip(1 days);

        // Start epoch 2
        uint256 epoch2StartTime = block.timestamp;

        vm.prank(admin);
        epochManager.startNewEpoch(0);

        assertEq(epochManager.currentEpoch(), 2, "Should be epoch 2");
        assertEq(epochManager.currentEpochStartTime(), epoch2StartTime, "Epoch 2 start time");

        // Check epoch 1 ended correctly
        (, uint256 e1StartTime, uint256 e1EndTime,) = epochManager.getEpoch(1);
        assertEq(e1StartTime, epoch1StartTime, "Epoch 1 start time should be preserved");
        assertEq(e1EndTime, epoch1EndTime, "Epoch 1 end time should match");
        assertFalse(epochManager.isEpochActive(1), "Epoch 1 should not be active");
        assertTrue(epochManager.isEpochActive(2), "Epoch 2 should be active");

        // Verify duration calculation
        uint256 actualDuration = e1EndTime - e1StartTime;
        assertEq(actualDuration, 30 days, "Duration should be 30 days");
    }

    function testMultipleEpochTransitions() public {
        uint256[] memory epochStartTimes = new uint256[](5);
        uint256[] memory epochEndTimes = new uint256[](5);

        // Start and transition through 5 epochs
        for (uint256 i = 1; i <= 5; i++) {
            vm.prank(admin);
            epochManager.startNewEpoch(0);

            epochStartTimes[i - 1] = epochManager.currentEpochStartTime();

            assertEq(epochManager.currentEpoch(), i, string(abi.encodePacked("Should be epoch ", vm.toString(i))));
            assertTrue(
                epochManager.isEpochActive(i), string(abi.encodePacked("Epoch ", vm.toString(i), " should be active"))
            );

            // Advance time
            skip(7 days);

            // End the epoch (except last one)
            if (i < 5) {
                vm.prank(admin);
                epochManager.endCurrentEpoch(0);

                epochEndTimes[i - 1] = block.timestamp;

                // Small gap before next epoch
                skip(1 days);
            }
        }

        // Verify all historical epochs have correct data
        for (uint256 i = 1; i < 5; i++) {
            (, uint256 sTime, uint256 eTime,) = epochManager.getEpoch(i);
            assertEq(sTime, epochStartTimes[i - 1], "Historical start time should be preserved");
            assertEq(eTime, epochEndTimes[i - 1], "Historical end time should match when ended");
            assertFalse(epochManager.isEpochActive(i), "Historical epoch should not be active");
        }

        // Current epoch should not have end data
        (, uint256 currentStartTime, uint256 currentEndTime,) = epochManager.getEpoch(5);
        assertEq(currentStartTime, epochStartTimes[4], "Current epoch start time should match");
        assertEq(currentEndTime, 0, "Current epoch should not have end time");
    }

    function testEpochDetailsForNonExistentEpoch() public {
        vm.prank(admin);
        epochManager.startNewEpoch(0);

        // Query non-existent epoch
        (, uint256 sTime, uint256 eTime,) = epochManager.getEpoch(999);
        assertEq(sTime, 0, "Non-existent epoch should have no data");
        assertEq(eTime, 0, "Non-existent epoch should have no data");
    }

    function testIsEpochActiveForNonExistentEpoch() public {
        vm.prank(admin);
        epochManager.startNewEpoch(0);

        assertFalse(epochManager.isEpochActive(0), "Epoch 0 should not be active");
        assertFalse(epochManager.isEpochActive(999), "Non-existent epoch should not be active");
    }

    function testDeterministicEpochTiming() public {
        // Epoch 1: 30 days
        vm.prank(admin);
        epochManager.startNewEpoch(0);
        uint256 epoch1Start = block.timestamp;

        skip(30 days);
        vm.roll(block.number + 1000);

        // End epoch 1
        vm.prank(admin);
        epochManager.endCurrentEpoch(0);

        skip(1 days); // Gap
        vm.roll(block.number + 10);

        // Epoch 2: 45 days
        vm.prank(admin);
        epochManager.startNewEpoch(0);
        uint256 epoch2Start = block.timestamp;

        skip(45 days);
        vm.roll(block.number + 1500);

        // End epoch 2
        vm.prank(admin);
        epochManager.endCurrentEpoch(0);

        skip(1 days); // Gap
        vm.roll(block.number + 10);

        // Epoch 3: 20 days
        vm.prank(admin);
        epochManager.startNewEpoch(0);

        // Verify epoch 1 duration
        (,, uint256 e1End,) = epochManager.getEpoch(1);
        assertEq(e1End - epoch1Start, 30 days, "Epoch 1 should be exactly 30 days");

        // Verify epoch 2 duration
        (,, uint256 e2End,) = epochManager.getEpoch(2);
        assertEq(e2End - epoch2Start, 45 days, "Epoch 2 should be exactly 45 days");

        // Epoch 3 still active
        (,, uint256 e3End,) = epochManager.getEpoch(3);
        assertEq(e3End, 0, "Epoch 3 should still be active");
    }

    function testScheduledEpochGapAndFuturePreviousEpoch() public {
        vm.warp(100);

        vm.prank(admin);
        epochManager.startNewEpoch(100);

        vm.prank(admin);
        epochManager.endCurrentEpoch(1000);

        vm.prank(admin);
        epochManager.startNewEpoch(2000);

        assertEq(epochManager.currentEpoch(), 1, "Previous epoch remains active until scheduled end");

        (uint256 activeEpoch, uint256 startTime, uint256 endTime, uint256 duration) = epochManager.getActiveEpoch();
        assertEq(activeEpoch, 1, "Active epoch");
        assertEq(startTime, 100, "Active start");
        assertEq(endTime, 1000, "Scheduled end");
        assertEq(duration, 900, "Scheduled duration");
        assertFalse(epochManager.isEpochActive(1), "Scheduled end means isEpochActive reports false");

        vm.warp(1500);
        assertEq(epochManager.currentEpoch(), 0, "Gap before future epoch");
        assertTrue(epochManager.isInGapPeriod(), "Gap period");

        (activeEpoch, startTime, endTime, duration) = epochManager.getActiveEpoch();
        assertEq(activeEpoch, 0, "No active epoch");
        assertEq(startTime, 0, "No active start");
        assertEq(endTime, 0, "No active end");
        assertEq(duration, 0, "No active duration");
    }

    function testEpochRevertsAndRenounceGuard() public {
        vm.prank(admin);
        vm.expectRevert(IEpochManager.NoEpochToEnd.selector);
        epochManager.endCurrentEpoch(0);

        vm.prank(admin);
        epochManager.startNewEpoch(0);

        vm.prank(admin);
        vm.expectRevert(IEpochManager.EpochStillActive.selector);
        epochManager.startNewEpoch(0);

        vm.prank(admin);
        vm.expectRevert(IEpochManager.ScheduledEndBeforeStart.selector);
        epochManager.endCurrentEpoch(block.timestamp);

        // renounceOwnership is disabled via a BARE `revert()` (no named error).
        vm.prank(admin);
        vm.expectRevert(bytes(""));
        epochManager.renounceOwnership();
    }
}
