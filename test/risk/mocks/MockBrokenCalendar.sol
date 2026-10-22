// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ISessionCalendar} from "../../../src/interfaces/ISessionCalendar.sol";

/**
 * @title MockBrokenCalendar
 * @author Neverland
 * @notice Session calendar whose shape views can each be made to revert
 * @dev NOT FOR PRODUCTION USE. Answers every view the sentinel probes at deployment, with one switch per shape
 *      view, so a calendar that carries code and still cannot report its schedule can be stood up. The
 *      sentinel fixes its calendar at deployment, so each of those failures has to be caught in its
 *      constructor. It implements neither sessionStart nor lastEndedSession, so it also stands in for a
 *      calendar the price adapter must reject: one that reports a schedule but cannot serve a price read.
 */
contract MockBrokenCalendar {
    /// @dev Raised by a shape view standing in for one the calendar can no longer answer
    error CalendarViewUnavailable();

    /// @dev The stored schedule, holding the single window the constructor posts
    ISessionCalendar.Window[] private _windows;

    /// @dev Whether `windowAt()` reverts
    bool private _revertOnWindowAt;

    /// @dev Whether `windowCount()` reverts
    bool private _revertOnWindowCount;

    /**
     * @notice Posts the single window the calendar reports
     * @param start The window start
     * @param end The window end
     */
    constructor(uint64 start, uint64 end) {
        _windows.push(ISessionCalendar.Window({start: start, end: end}));
    }

    /**
     * @notice Makes `windowAt()` revert or answer
     * @param value Whether the view reverts
     */
    function setRevertOnWindowAt(bool value) external {
        _revertOnWindowAt = value;
    }

    /**
     * @notice Makes `windowCount()` revert or answer
     * @param value Whether the view reverts
     */
    function setRevertOnWindowCount(bool value) external {
        _revertOnWindowCount = value;
    }

    /**
     * @notice Returns the number of stored windows
     * @return The stored window count while the view answers
     */
    function windowCount() external view returns (uint256) {
        if (_revertOnWindowCount) revert CalendarViewUnavailable();

        return _windows.length;
    }

    /**
     * @notice Returns a stored window
     * @param index The window index
     * @return The window at `index`
     */
    function windowAt(uint256 index) external view returns (ISessionCalendar.Window memory) {
        if (_revertOnWindowAt) revert CalendarViewUnavailable();

        return _windows[index];
    }

    /**
     * @notice Returns the stored window once it has started
     * @param timestamp The UTC timestamp to look up
     * @return The stored window, or a zero window before it starts
     */
    function lastStartedWindow(uint256 timestamp) external view returns (ISessionCalendar.Window memory) {
        ISessionCalendar.Window memory stored = _windows[0];
        if (timestamp < stored.start) return ISessionCalendar.Window({start: 0, end: 0});

        return stored;
    }
}
