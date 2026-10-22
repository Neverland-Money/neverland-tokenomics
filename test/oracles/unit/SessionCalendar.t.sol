// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {ISessionCalendar} from "../../../src/interfaces/ISessionCalendar.sol";

import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";

import {SessionCalendar} from "../../../src/oracles/SessionCalendar.sol";

import {SessionWindowTestBase} from "../../_utils/SessionWindowTestBase.sol";

/**
 * @title SessionCalendarTest
 * @author Neverland
 * @notice Unit tests for the governed trading-session calendar
 * @dev Pins the append rules, the [start, end) boundary semantics, binary search against a linear scan,
 *      removal of unstarted windows only, shortening the current window, and two-step ownership.
 */
contract SessionCalendarTest is SessionWindowTestBase {
    /// @dev Deployment timestamp used by every test.
    uint256 internal constant T0 = 365 days;

    SessionCalendar internal calendar;

    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(T0);

        calendar = new SessionCalendar();
    }

    /*//////////////////////////////////////////////////////////////
                             APPEND WINDOWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Appended windows are stored in order and announced
    function test_appendWindows_storesAndEmits() public {
        ISessionCalendar.Window[] memory windows = _separatedWindows();

        vm.expectEmit(false, false, false, true);
        emit ISessionCalendar.WindowsAppended(0, 2);
        calendar.appendWindows(windows);

        assertEq(calendar.windowCount(), 2);
        assertEq(calendar.windowAt(1).start, T0 + 8 days);
        assertEq(calendar.windowAt(1).end, T0 + 13 days);
        assertEq(calendar.MAX_WINDOW_DURATION(), 7 days);
    }

    /// @notice A window may start exactly where the previous one ends
    function test_appendWindows_allowsAdjacentWindows() public {
        ISessionCalendar.Window[] memory windows = new ISessionCalendar.Window[](2);
        windows[0] = _window(T0 + 1 days, T0 + 2 days);
        windows[1] = _window(T0 + 2 days, T0 + 3 days);

        calendar.appendWindows(windows);

        assertEq(calendar.sessionStart(T0 + 2 days), T0 + 2 days);
    }

    /**
     * @notice A later batch may start exactly where the last stored window ends
     * @dev Records logs rather than expecting the emit, so a stricter bound against the stored window fails
     *      with WindowOverlap instead of a log mismatch.
     */
    function test_appendWindows_allowsAdjacentWindowsAcrossBatches() public {
        ISessionCalendar.Window[] memory stored = new ISessionCalendar.Window[](2);
        stored[0] = _window(T0 + 1 days, T0 + 2 days);
        stored[1] = _window(T0 + 3 days, T0 + 4 days);
        calendar.appendWindows(stored);

        ISessionCalendar.Window[] memory windows = new ISessionCalendar.Window[](2);
        windows[0] = _window(T0 + 4 days, T0 + 5 days);
        windows[1] = _window(T0 + 6 days, T0 + 7 days);

        vm.recordLogs();
        calendar.appendWindows(windows);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(calendar));
        assertEq(logs[0].topics[0], ISessionCalendar.WindowsAppended.selector);
        assertEq(logs[0].data, abi.encode(uint256(2), uint256(2)));
        assertEq(calendar.windowCount(), 4);
        assertEq(calendar.sessionStart(T0 + 4 days), T0 + 4 days);
        assertEq(calendar.windowAt(3).start, T0 + 6 days);
        assertEq(calendar.windowAt(3).end, T0 + 7 days);
    }

    /// @notice An empty batch is rejected
    function test_appendWindows_revertsOnEmptyBatch() public {
        vm.expectRevert(CommonChecksLibrary.ZeroAmount.selector);
        calendar.appendWindows(new ISessionCalendar.Window[](0));
    }

    /// @notice A window must start before it ends
    function test_appendWindows_revertsOnInvalidWindow() public {
        vm.expectRevert(ISessionCalendar.InvalidWindow.selector);
        calendar.appendWindows(_single(T0 + 1 days, T0 + 1 days));

        vm.expectRevert(ISessionCalendar.InvalidWindow.selector);
        calendar.appendWindows(_single(T0 + 2 days, T0 + 1 days));
    }

    /// @notice A window must start after the current block
    function test_appendWindows_revertsOnPastStart() public {
        vm.expectRevert(ISessionCalendar.WindowInPast.selector);
        calendar.appendWindows(_single(T0, T0 + 1 days));

        vm.expectRevert(ISessionCalendar.WindowInPast.selector);
        calendar.appendWindows(_single(T0 - 1, T0 + 1 days));
    }

    /// @notice A window may not overlap or precede the last stored window
    function test_appendWindows_revertsOnOverlapWithStoredWindow() public {
        ISessionCalendar.Window[] memory windows = new ISessionCalendar.Window[](2);
        windows[0] = _window(T0 + 1 days, T0 + 2 days);
        windows[1] = _window(T0 + 3 days, T0 + 6 days);
        calendar.appendWindows(windows);

        vm.expectRevert(ISessionCalendar.WindowOverlap.selector);
        calendar.appendWindows(_single(T0 + 5 days, T0 + 7 days));

        vm.expectRevert(ISessionCalendar.WindowOverlap.selector);
        calendar.appendWindows(_single(T0 + 2 days + 1 hours, T0 + 2 days + 2 hours));
    }

    /// @notice Windows inside one batch may not overlap each other
    function test_appendWindows_revertsOnOverlapWithinBatch() public {
        ISessionCalendar.Window[] memory windows = new ISessionCalendar.Window[](2);
        windows[0] = _window(T0 + 1 days, T0 + 6 days);
        windows[1] = _window(T0 + 5 days, T0 + 7 days);

        vm.expectRevert(ISessionCalendar.WindowOverlap.selector);
        calendar.appendWindows(windows);
    }

    /// @notice A window may last seven days but not longer
    function test_appendWindows_revertsOnTooLongWindow() public {
        vm.expectRevert(ISessionCalendar.WindowTooLong.selector);
        calendar.appendWindows(_single(T0 + 1 days, T0 + 8 days + 1));

        calendar.appendWindows(_single(T0 + 1 days, T0 + 8 days));

        assertEq(calendar.windowCount(), 1);
    }

    /// @notice Only the owner appends windows
    function test_appendWindows_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        calendar.appendWindows(_single(T0 + 1 days, T0 + 2 days));
    }

    /*//////////////////////////////////////////////////////////////
                                 LOOKUPS
    //////////////////////////////////////////////////////////////*/

    /// @notice `start` is inclusive, `end` exclusive, and gaps read closed
    function test_sessionStart_boundaries() public {
        ISessionCalendar.Window[] memory windows = _separatedWindows();
        calendar.appendWindows(windows);

        assertEq(calendar.sessionStart(T0 + 1 days - 1), 0);
        assertEq(calendar.sessionStart(T0 + 1 days), T0 + 1 days);
        assertEq(calendar.sessionStart(T0 + 6 days - 1), T0 + 1 days);
        assertEq(calendar.sessionStart(T0 + 6 days), 0);
        assertEq(calendar.sessionStart(T0 + 7 days), 0);
        assertEq(calendar.sessionStart(T0 + 8 days), T0 + 8 days);
        assertEq(calendar.sessionStart(T0 + 13 days), 0);
        assertTrue(calendar.isOpen(T0 + 1 days));
        assertFalse(calendar.isOpen(T0 + 7 days));
    }

    /// @notice An empty calendar reads closed everywhere
    function test_sessionStart_emptyCalendarReadsClosed() public view {
        assertEq(calendar.sessionStart(T0), 0);
        assertFalse(calendar.isOpen(T0 + 1 days));
        assertEq(calendar.lastEndedSession(T0 + 1 days), 0);
    }

    /// @notice The last ended session is the previous window's end in session and the closing end while closed
    function test_lastEndedSession_boundaries() public {
        _appendBoundaryWindows();

        assertEq(calendar.lastEndedSession(T0 + 1 days - 1), 0);
        assertEq(calendar.lastEndedSession(T0 + 1 days), 0);
        assertEq(calendar.lastEndedSession(T0 + 6 days - 1), 0);
        assertEq(calendar.lastEndedSession(T0 + 6 days), T0 + 6 days);
        assertEq(calendar.lastEndedSession(T0 + 7 days), T0 + 6 days);
        assertEq(calendar.lastEndedSession(T0 + 8 days), T0 + 6 days);
        assertEq(calendar.lastEndedSession(T0 + 13 days - 1), T0 + 6 days);
        assertEq(calendar.lastEndedSession(T0 + 13 days), T0 + 13 days);
        assertEq(calendar.lastEndedSession(T0 + 14 days), T0 + 14 days);
        assertEq(calendar.lastEndedSession(T0 + 400 days), T0 + 14 days);
    }

    /// @notice The last started window is the running window in session and the window that closed while closed
    function test_lastStartedWindow_boundaries() public {
        _appendBoundaryWindows();

        _assertWindow(calendar.lastStartedWindow(T0 + 1 days - 1), 0, 0);
        _assertWindow(calendar.lastStartedWindow(T0 + 1 days), T0 + 1 days, T0 + 6 days);
        _assertWindow(calendar.lastStartedWindow(T0 + 6 days), T0 + 1 days, T0 + 6 days);
        _assertWindow(calendar.lastStartedWindow(T0 + 8 days - 1), T0 + 1 days, T0 + 6 days);
        _assertWindow(calendar.lastStartedWindow(T0 + 8 days), T0 + 8 days, T0 + 13 days);
        _assertWindow(calendar.lastStartedWindow(T0 + 13 days), T0 + 13 days, T0 + 14 days);
        _assertWindow(calendar.lastStartedWindow(T0 + 400 days), T0 + 13 days, T0 + 14 days);
    }

    /// @notice Binary search agrees with a linear scan over a year of weekly windows
    function testFuzz_sessionStart_matchesLinearScan(uint256 seed, uint256 probe) public {
        ISessionCalendar.Window[] memory windows = _appendFuzzWindows(seed);
        probe = bound(probe, T0, T0 + 430 days);

        uint256 expected;
        ISessionCalendar.Window memory expectedStarted;
        for (uint256 i; i < windows.length; ++i) {
            if (windows[i].start <= probe && probe < windows[i].end) expected = windows[i].start;
            if (windows[i].start <= probe) expectedStarted = windows[i];
        }

        uint256 expectedEnd;
        for (uint256 i; i < windows.length; ++i) {
            if (windows[i].end <= probe) expectedEnd = windows[i].end;
        }

        assertEq(calendar.sessionStart(probe), expected);
        assertEq(calendar.isOpen(probe), expected != 0);
        assertEq(calendar.lastEndedSession(probe), expectedEnd);
        _assertWindow(calendar.lastStartedWindow(probe), expectedStarted.start, expectedStarted.end);
    }

    /*//////////////////////////////////////////////////////////////
                             REMOVE WINDOWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Unstarted windows are popped from the end and announced
    function test_removeFutureWindows_popsAndEmits() public {
        ISessionCalendar.Window[] memory windows = new ISessionCalendar.Window[](3);
        windows[0] = _window(T0 + 1 days, T0 + 2 days);
        windows[1] = _window(T0 + 3 days, T0 + 4 days);
        windows[2] = _window(T0 + 5 days, T0 + 6 days);
        calendar.appendWindows(windows);

        vm.expectEmit(false, false, false, true);
        emit ISessionCalendar.WindowsRemoved(1, 2);
        calendar.removeFutureWindows(2);

        assertEq(calendar.windowCount(), 1);
        assertEq(calendar.sessionStart(T0 + 3 days), 0);
    }

    /// @notice A corrected window can replace a removed one
    function test_removeFutureWindows_thenAppendCorrection() public {
        calendar.appendWindows(_single(T0 + 1 days, T0 + 6 days));
        calendar.removeFutureWindows(1);

        calendar.appendWindows(_single(T0 + 1 days, T0 + 5 days));

        assertEq(calendar.windowCount(), 1);
        assertEq(calendar.windowAt(0).end, T0 + 5 days);
    }

    /// @notice A started window can never be removed, alone or behind unstarted windows
    function test_removeFutureWindows_revertsWhenWindowStarted() public {
        ISessionCalendar.Window[] memory windows = _separatedWindows();
        calendar.appendWindows(windows);
        vm.warp(T0 + 1 days);

        vm.expectRevert(ISessionCalendar.WindowAlreadyStarted.selector);
        calendar.removeFutureWindows(2);

        calendar.removeFutureWindows(1);

        vm.expectRevert(ISessionCalendar.WindowAlreadyStarted.selector);
        calendar.removeFutureWindows(1);
    }

    /// @notice Zero and excessive removal counts are rejected
    function test_removeFutureWindows_revertsOnInvalidCount() public {
        calendar.appendWindows(_single(T0 + 1 days, T0 + 2 days));

        vm.expectRevert(CommonChecksLibrary.ZeroAmount.selector);
        calendar.removeFutureWindows(0);

        vm.expectRevert(ISessionCalendar.InvalidRemovalCount.selector);
        calendar.removeFutureWindows(2);
    }

    /// @notice Only the owner removes windows
    function test_removeFutureWindows_revertsForNonOwner() public {
        calendar.appendWindows(_single(T0 + 1 days, T0 + 2 days));

        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        calendar.removeFutureWindows(1);
    }

    /*//////////////////////////////////////////////////////////////
                                OWNERSHIP
    //////////////////////////////////////////////////////////////*/

    /// @notice Ownership moves only through the two-step handoff
    function test_ownership_twoStepHandoff() public {
        calendar.transferOwnership(stranger);
        assertEq(calendar.owner(), address(this));
        assertEq(calendar.pendingOwner(), stranger);

        vm.prank(stranger);
        calendar.acceptOwnership();

        assertEq(calendar.owner(), stranger);
    }

    /// @notice Renouncing ownership always reverts
    function test_renounceOwnership_reverts() public {
        vm.expectRevert(ISessionCalendar.OwnershipRequired.selector);
        calendar.renounceOwnership();
    }

    /*//////////////////////////////////////////////////////////////
                         DURATION AND LOOKAHEAD
    //////////////////////////////////////////////////////////////*/

    /// @notice A window shorter than MIN_WINDOW_DURATION is rejected, and one exactly that long is accepted
    function test_appendWindows_revertsOnTooShortWindow() public {
        vm.expectRevert(ISessionCalendar.WindowTooShort.selector);
        calendar.appendWindows(_single(T0 + 1 days, T0 + 1 days + 8 hours - 1));

        calendar.appendWindows(_single(T0 + 1 days, T0 + 1 days + 8 hours));
        assertEq(calendar.windowCount(), 1);
        assertEq(calendar.MIN_WINDOW_DURATION(), 8 hours);
    }

    /// @notice A window starting more than MAX_LOOKAHEAD ahead is rejected, and one exactly at the bound is accepted
    function test_appendWindows_revertsOnTooFarAheadWindow() public {
        vm.expectRevert(ISessionCalendar.WindowTooFarAhead.selector);
        calendar.appendWindows(_single(T0 + 400 days + 1, T0 + 401 days));

        calendar.appendWindows(_single(T0 + 400 days, T0 + 401 days));
        assertEq(calendar.windowCount(), 1);
        assertEq(calendar.MAX_LOOKAHEAD(), 400 days);
    }

    /*//////////////////////////////////////////////////////////////
                             TRUNCATE WINDOW
    //////////////////////////////////////////////////////////////*/

    /// @notice The owner shortens the running window, which reads closed from the new end and is announced
    function test_truncateCurrentWindow_shortensAndEmits() public {
        calendar.appendWindows(_single(T0 + 1 days, T0 + 6 days));
        vm.warp(T0 + 2 days);
        uint64 newEnd = uint64(T0 + 3 days);

        vm.expectEmit(false, false, false, true);
        emit ISessionCalendar.WindowTruncated(0, T0 + 6 days, newEnd);
        calendar.truncateCurrentWindow(newEnd);

        _assertWindow(calendar.windowAt(0), T0 + 1 days, newEnd);
        assertTrue(calendar.isOpen(newEnd - 1));
        assertFalse(calendar.isOpen(newEnd));
        assertEq(calendar.sessionStart(newEnd), 0);
    }

    /// @notice Ending the running window at the current block closes the market in the same block
    function test_truncateCurrentWindow_canEndAtTheCurrentBlock() public {
        calendar.appendWindows(_single(T0 + 1 days, T0 + 6 days));
        vm.warp(T0 + 2 days);

        calendar.truncateCurrentWindow(uint64(block.timestamp));

        assertFalse(calendar.isOpen(block.timestamp));
        assertEq(calendar.sessionStart(block.timestamp), 0);
    }

    /// @notice Truncation needs a running window and only moves its end earlier, never before its start or the block
    function test_truncateCurrentWindow_rules() public {
        vm.expectRevert(ISessionCalendar.NoOpenWindow.selector);
        calendar.truncateCurrentWindow(uint64(T0 + 1));

        calendar.appendWindows(_single(T0 + 1 days, T0 + 6 days));
        vm.expectRevert(ISessionCalendar.NoOpenWindow.selector);
        calendar.truncateCurrentWindow(uint64(T0 + 2 days));

        vm.warp(T0 + 6 days);
        vm.expectRevert(ISessionCalendar.NoOpenWindow.selector);
        calendar.truncateCurrentWindow(uint64(T0 + 6 days));

        vm.warp(T0 + 2 days);
        vm.expectRevert(ISessionCalendar.InvalidTruncation.selector);
        calendar.truncateCurrentWindow(uint64(T0 + 2 days - 1));
        vm.expectRevert(ISessionCalendar.InvalidTruncation.selector);
        calendar.truncateCurrentWindow(uint64(T0 + 6 days));
        vm.expectRevert(ISessionCalendar.InvalidTruncation.selector);
        calendar.truncateCurrentWindow(uint64(T0 + 7 days));

        vm.warp(T0 + 1 days);
        vm.expectRevert(ISessionCalendar.InvalidTruncation.selector);
        calendar.truncateCurrentWindow(uint64(T0 + 1 days));

        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        calendar.truncateCurrentWindow(uint64(T0 + 2 days));
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Appends fifty-five weekly windows whose offset and durations come from `seed`
     * @param seed The fuzz seed
     * @return windows The appended windows
     */
    function _appendFuzzWindows(uint256 seed) internal returns (ISessionCalendar.Window[] memory windows) {
        windows = new ISessionCalendar.Window[](55);
        uint256 offset = seed % 2 days;
        for (uint256 i; i < windows.length; ++i) {
            uint256 start = T0 + 1 days + i * 7 days + offset;
            uint256 duration = 8 hours + uint256(keccak256(abi.encode(seed, i))) % 5 days;
            windows[i] = _window(start, start + duration);
        }
        calendar.appendWindows(windows);
    }

    /**
     * @notice Returns the standard pair of separated windows used across boundary and removal tests
     * @return windows The two windows
     */
    function _separatedWindows() internal pure returns (ISessionCalendar.Window[] memory windows) {
        windows = new ISessionCalendar.Window[](2);
        windows[0] = _window(T0 + 1 days, T0 + 6 days);
        windows[1] = _window(T0 + 8 days, T0 + 13 days);
    }

    /// @notice Appends two separated windows and a third adjacent to the second
    function _appendBoundaryWindows() internal {
        ISessionCalendar.Window[] memory windows = new ISessionCalendar.Window[](3);
        windows[0] = _window(T0 + 1 days, T0 + 6 days);
        windows[1] = _window(T0 + 8 days, T0 + 13 days);
        windows[2] = _window(T0 + 13 days, T0 + 14 days);
        calendar.appendWindows(windows);
    }

    /**
     * @notice Asserts a window's bounds
     * @param window The window to check
     * @param start The expected start
     * @param end The expected end
     */
    function _assertWindow(ISessionCalendar.Window memory window, uint256 start, uint256 end) internal pure {
        assertEq(window.start, start);
        assertEq(window.end, end);
    }
}
