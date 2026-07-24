// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LeaderboardBase} from "./LeaderboardBase.sol";

contract EpochManagerScheduledActiveProbe is LeaderboardBase {
    function testScheduledEndLeavesCurrentEpochActiveButIsEpochActiveFalse() public {
        vm.warp(100);

        vm.prank(admin);
        epochManager.startNewEpoch(100);

        vm.prank(admin);
        epochManager.endCurrentEpoch(1000);

        assertEq(epochManager.currentEpoch(), 1, "scheduled-end epoch is current");

        (uint256 activeEpoch, uint256 startTime, uint256 endTime, uint256 duration) = epochManager.getActiveEpoch();
        assertEq(activeEpoch, 1, "getActiveEpoch reports active epoch");
        assertEq(startTime, 100, "start");
        assertEq(endTime, 1000, "future scheduled end");
        assertEq(duration, 900, "duration");

        assertFalse(epochManager.isEpochActive(1), "isEpochActive rejects future scheduled end");
    }
}
