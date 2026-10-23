// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {ISessionCalendar} from "../../src/interfaces/ISessionCalendar.sol";

/**
 * @title SessionWindowTestBase
 * @author Neverland
 * @notice Shared session-window builders for the calendar and market-hours adapter suites
 * @dev Holds the single copy of the builders both suites use, so neither carries its own duplicate.
 */
abstract contract SessionWindowTestBase is Test {
    /**
     * @notice Builds a window from full-width timestamps
     * @param start The window start
     * @param end The window end
     * @return The window
     */
    function _window(uint256 start, uint256 end) internal pure returns (ISessionCalendar.Window memory) {
        return ISessionCalendar.Window({start: uint64(start), end: uint64(end)});
    }

    /**
     * @notice Builds a one-window batch
     * @param start The window start
     * @param end The window end
     * @return windows The batch
     */
    function _single(uint256 start, uint256 end) internal pure returns (ISessionCalendar.Window[] memory windows) {
        windows = new ISessionCalendar.Window[](1);
        windows[0] = _window(start, end);
    }
}
