// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {MockChainlinkAggregator} from "./MockChainlinkAggregator.sol";

contract MockChainlinkAggregatorTest is Test {
    function testGetRoundDataReturnsStoredRoundOnly() public {
        MockChainlinkAggregator aggregator = new MockChainlinkAggregator(2_000e8, 8, "MON / USD");
        aggregator.set(2_100e8, 7, 100, 120, 7);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            aggregator.getRoundData(7);

        assertEq(roundId, 7);
        assertEq(answer, 2_100e8);
        assertEq(startedAt, 100);
        assertEq(updatedAt, 120);
        assertEq(answeredInRound, 7);
    }

    function testGetRoundDataRevertsForMissingRound() public {
        MockChainlinkAggregator aggregator = new MockChainlinkAggregator(2_000e8, 8, "MON / USD");

        vm.expectRevert(MockChainlinkAggregator.NoDataPresent.selector);
        aggregator.getRoundData(2);
    }
}
