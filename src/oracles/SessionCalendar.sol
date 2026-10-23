// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {ISessionCalendar} from "../interfaces/ISessionCalendar.sol";

import {CommonChecksLibrary} from "../libraries/CommonChecksLibrary.sol";

/**
 * @title SessionCalendar
 * @author Neverland
 * @notice Governed schedule of stock-market trading sessions for the market-hours sentinel and adapters
 * @dev Direct deployment, no upgrade path. Owned by the RiskTimelock in production, which posts explicit
 *      UTC windows at least a quarter ahead because New York time shifts with daylight saving, and shortens the
 *      running window when the exchange closes without notice. Lookups use binary search over the sorted windows.
 */
contract SessionCalendar is ISessionCalendar, Ownable2Step {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISessionCalendar
    uint64 public constant MAX_LOOKAHEAD = 400 days;

    /// @inheritdoc ISessionCalendar
    uint64 public constant MAX_WINDOW_DURATION = 7 days;

    /// @inheritdoc ISessionCalendar
    uint64 public constant MIN_WINDOW_DURATION = 8 hours;

    /*//////////////////////////////////////////////////////////////
                            STORAGE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev Session windows in ascending, non-overlapping order
    Window[] private _windows;

    /*//////////////////////////////////////////////////////////////
                                  ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISessionCalendar
    function appendWindows(Window[] calldata windows) external onlyOwner {
        CommonChecksLibrary.revertIfZeroAmount(windows.length);

        uint256 firstIndex = _windows.length;
        uint64 previousEnd = firstIndex == 0 ? 0 : _windows[firstIndex - 1].end;
        for (uint256 i; i < windows.length; ++i) {
            _revertIfInvalidWindow(windows[i], previousEnd);

            _windows.push(windows[i]);
            previousEnd = windows[i].end;
        }

        emit WindowsAppended(firstIndex, windows.length);
    }

    /// @inheritdoc ISessionCalendar
    function removeFutureWindows(uint256 count) external onlyOwner {
        CommonChecksLibrary.revertIfZeroAmount(count);
        if (count > _windows.length) revert InvalidRemovalCount();
        uint256 fromIndex = _windows.length - count;
        if (_windows[fromIndex].start <= block.timestamp) revert WindowAlreadyStarted();

        for (uint256 i; i < count; ++i) {
            _windows.pop();
        }

        emit WindowsRemoved(fromIndex, count);
    }

    /// @inheritdoc ISessionCalendar
    function truncateCurrentWindow(uint64 newEnd) external onlyOwner {
        uint256 count = _countStartedBy(block.timestamp);
        if (count == 0 || block.timestamp >= _windows[count - 1].end) revert NoOpenWindow();
        Window storage window = _windows[count - 1];
        if (newEnd <= window.start || newEnd < block.timestamp || newEnd >= window.end) revert InvalidTruncation();

        uint64 previousEnd = window.end;
        window.end = newEnd;

        emit WindowTruncated(count - 1, previousEnd, newEnd);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISessionCalendar
    function sessionStart(uint256 timestamp) external view returns (uint256) {
        return _sessionStart(timestamp);
    }

    /// @inheritdoc ISessionCalendar
    function lastEndedSession(uint256 timestamp) external view returns (uint256) {
        uint256 count = _countStartedBy(timestamp);
        if (count == 0) return 0;
        if (_windows[count - 1].end <= timestamp) return _windows[count - 1].end;

        return count > 1 ? _windows[count - 2].end : 0;
    }

    /// @inheritdoc ISessionCalendar
    function lastStartedWindow(uint256 timestamp) external view returns (Window memory window) {
        uint256 count = _countStartedBy(timestamp);

        if (count != 0) window = _windows[count - 1];
    }

    /// @inheritdoc ISessionCalendar
    function isOpen(uint256 timestamp) external view returns (bool) {
        return _sessionStart(timestamp) != 0;
    }

    /// @inheritdoc ISessionCalendar
    function windowCount() external view returns (uint256) {
        return _windows.length;
    }

    /// @inheritdoc ISessionCalendar
    function windowAt(uint256 index) external view returns (Window memory) {
        return _windows[index];
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISessionCalendar
    function renounceOwnership() public view override(ISessionCalendar, Ownable) onlyOwner {
        revert OwnershipRequired();
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Finds the start of the window containing `timestamp`
     * @dev Takes the last window whose start is at or before `timestamp`, then checks that `timestamp` falls
     *      before that window's end.
     * @param timestamp The UTC timestamp to look up
     * @return start The containing window's start, or 0 when no window contains `timestamp`
     */
    function _sessionStart(uint256 timestamp) private view returns (uint256 start) {
        uint256 count = _countStartedBy(timestamp);

        if (count != 0 && timestamp < _windows[count - 1].end) start = _windows[count - 1].start;
    }

    /**
     * @notice Counts the windows whose start is at or before `timestamp`
     * @dev Binary search over the sorted windows. When `count` is non-zero, the window at `count - 1` is the
     *      last one that has started by `timestamp`.
     * @param timestamp The UTC timestamp to look up
     * @return count The number of windows whose start is at or before `timestamp`
     */
    function _countStartedBy(uint256 timestamp) private view returns (uint256 count) {
        uint256 high = _windows.length;
        while (count < high) {
            uint256 mid = (count + high) / 2;
            if (_windows[mid].start <= timestamp) count = mid + 1;
            else high = mid;
        }
    }

    /**
     * @notice Reverts when a window breaks the calendar's ordering, duration, or lookahead rules
     * @param window The window to validate
     * @param previousEnd The end of the window immediately before it, or 0 when it is the first
     */
    function _revertIfInvalidWindow(Window calldata window, uint64 previousEnd) private view {
        if (window.start >= window.end) revert InvalidWindow();
        if (window.start <= block.timestamp) revert WindowInPast();
        if (window.start > block.timestamp + MAX_LOOKAHEAD) revert WindowTooFarAhead();
        if (window.start < previousEnd) revert WindowOverlap();
        if (window.end - window.start > MAX_WINDOW_DURATION) revert WindowTooLong();
        if (window.end - window.start < MIN_WINDOW_DURATION) revert WindowTooShort();
    }
}
