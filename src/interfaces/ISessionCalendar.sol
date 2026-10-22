// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/**
 * @title ISessionCalendar
 * @author Neverland
 * @notice Interface for the governed schedule of stock-market trading sessions
 * @dev Stores explicit UTC session windows, sorted and non-overlapping, posted ahead of time by the owner
 *      (the RiskTimelock in production). A window covers [start, end): `start` is inclusive and `end` is
 *      exclusive. Appended windows last between MIN_WINDOW_DURATION and MAX_WINDOW_DURATION and start at most
 *      MAX_LOOKAHEAD ahead; emergency truncation can shorten them below that minimum. Only unstarted windows
 *      can be removed, and the current window can only be shortened, preserving recorded history. Once the
 *      calendar runs out of windows, every later timestamp reads closed.
 */
interface ISessionCalendar {
    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice A trading session window in UTC seconds
     * @param start The first second of the session (inclusive)
     * @param end The first second after the session (exclusive)
     */
    struct Window {
        uint64 start;
        uint64 end;
    }

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Reverts when a removal count exceeds the number of stored windows
    error InvalidRemovalCount();

    /// @notice Reverts when a new end is at or before the start, before the current block, or at or after the stored end
    error InvalidTruncation();

    /// @notice Reverts when a window's start is not before its end
    error InvalidWindow();

    /// @notice Reverts when no window contains the current block
    error NoOpenWindow();

    /// @notice Reverts when ownership renouncement is attempted (disabled to keep schedule control)
    error OwnershipRequired();

    /// @notice Reverts when a removal would delete a window that has already started
    error WindowAlreadyStarted();

    /// @notice Reverts when a new window starts at or before the current block timestamp
    error WindowInPast();

    /// @notice Reverts when a new window starts before the previous window ends
    error WindowOverlap();

    /// @notice Reverts when a new window starts more than MAX_LOOKAHEAD after the current block
    error WindowTooFarAhead();

    /// @notice Reverts when a window lasts longer than MAX_WINDOW_DURATION
    error WindowTooLong();

    /// @notice Reverts when a window lasts less than MIN_WINDOW_DURATION
    error WindowTooShort();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when the owner shortens the window containing the current block
     * @param index The index of the shortened window
     * @param previousEnd The window's end before the change
     * @param newEnd The window's end after the change
     */
    event WindowTruncated(uint256 index, uint256 previousEnd, uint256 newEnd);

    /**
     * @notice Emitted when the owner appends windows
     * @param firstIndex The index of the first appended window
     * @param count The number of appended windows
     */
    event WindowsAppended(uint256 firstIndex, uint256 count);

    /**
     * @notice Emitted when the owner removes future windows
     * @param fromIndex The index of the first removed window
     * @param count The number of removed windows
     */
    event WindowsRemoved(uint256 fromIndex, uint256 count);

    /*//////////////////////////////////////////////////////////////
                                FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Appends future session windows (owner only)
     * @dev Rejects an empty batch. Each window must satisfy start < end, start after the current block timestamp
     *      and at most MAX_LOOKAHEAD ahead of it, start at or after the previous window's end, and last between
     *      MIN_WINDOW_DURATION and MAX_WINDOW_DURATION.
     * @param windows The windows to append, in ascending order
     */
    function appendWindows(Window[] calldata windows) external;

    /**
     * @notice Removes the last `count` windows (owner only)
     * @dev Rejects a zero count, a count above the stored total, and any removal that would delete a
     *      window whose start is at or before the current block timestamp.
     * @param count The number of windows to remove from the end
     */
    function removeFutureWindows(uint256 count) external;

    /**
     * @notice Shortens the window containing the current block (owner only)
     * @dev The emergency lever for an unscheduled closure announced after the session has started. It only
     *      moves the end earlier: `newEnd` must be after the window's start, at or after the current block, and
     *      before the stored end. Ending the window at the current block makes the calendar read closed from
     *      this block on. Windows that have not started are edited with removeFutureWindows and appendWindows.
     * @param newEnd The new end of the current window
     */
    function truncateCurrentWindow(uint64 newEnd) external;

    /**
     * @notice Renouncing ownership is disabled to prevent accidental loss of schedule control
     * @dev Reverts on every call.
     */
    function renounceOwnership() external view;

    /**
     * @notice Returns how far ahead of the current block a window may start
     * @return The maximum lookahead in seconds (400 days)
     */
    function MAX_LOOKAHEAD() external view returns (uint64);

    /**
     * @notice Returns the longest window the owner can post
     * @return The maximum window duration in seconds (7 days)
     */
    function MAX_WINDOW_DURATION() external view returns (uint64);

    /**
     * @notice Returns the shortest window the owner can post
     * @dev Prevents accidental tiny sessions. The sentinel independently accepts opening grace up to 12 hours
     *      and clamps any running grace to the current window's end.
     * @return The minimum window duration in seconds (8 hours)
     */
    function MIN_WINDOW_DURATION() external view returns (uint64);

    /**
     * @notice Returns the start of the session containing `timestamp`
     * @param timestamp The UTC timestamp to look up
     * @return The containing window's start, or 0 when no window contains `timestamp`
     */
    function sessionStart(uint256 timestamp) external view returns (uint256);

    /**
     * @notice Returns the end of the last session that had ended by `timestamp`
     * @dev While a session is open this is the previous session's end; while closed it is the close that began
     *      the closure. Adapters use it to check that a pre-session round was fresh when the market closed.
     * @param timestamp The UTC timestamp to look up
     * @return The end of the last window with `end <= timestamp`, or 0 when no window has ended
     */
    function lastEndedSession(uint256 timestamp) external view returns (uint256);

    /**
     * @notice Returns the last window that had started by `timestamp`, whether it is still open or has ended
     * @dev The sentinel reads it to calculate opening grace from the latest stored session start, including
     *      after that session has ended.
     * @param timestamp The UTC timestamp to look up
     * @return The last window with `start <= timestamp`, or a zero window when none has started
     */
    function lastStartedWindow(uint256 timestamp) external view returns (Window memory);

    /**
     * @notice Returns whether a session is open at `timestamp`
     * @param timestamp The UTC timestamp to look up
     * @return True when a window contains `timestamp`
     */
    function isOpen(uint256 timestamp) external view returns (bool);

    /**
     * @notice Returns the number of stored windows
     * @return The window count
     */
    function windowCount() external view returns (uint256);

    /**
     * @notice Returns a stored window
     * @param index The window index
     * @return The window at `index`
     */
    function windowAt(uint256 index) external view returns (Window memory);
}
