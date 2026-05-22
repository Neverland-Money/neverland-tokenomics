// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/**
 * @title IEpochManager
 * @author Neverland
 * @notice Interface for managing leaderboard epochs
 */
interface IEpochManager {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when trying to start epoch while previous is still active
    error EpochStillActive();

    /// @notice Thrown when trying to end epoch but none is active
    error NoEpochToEnd();

    /// @notice Thrown when trying to schedule end before start
    error ScheduledEndBeforeStart();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when a new epoch is created (immediate or scheduled)
     * @param epochNumber The new epoch number
     * @param startTime Timestamp when epoch starts (current, past, or future)
     */
    event EpochStart(uint256 indexed epochNumber, uint256 startTime);

    /**
     * @notice Emitted when an epoch end is set (immediate or scheduled)
     * @param epochNumber The epoch number that ended
     * @param endTime Timestamp when epoch ends (current, past, or future)
     */
    event EpochEnd(uint256 indexed epochNumber, uint256 endTime);

    /*//////////////////////////////////////////////////////////////
                               ACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Starts a new epoch immediately or schedules it for a specific timestamp
     * @dev If currentEpoch is 0 (leaderboard not started), this starts epoch 1
     * @dev Otherwise, starts the next epoch (previous must be ended first; overlap reverts)
     * @param scheduledTime 0 = start immediately, >0 = schedule for this timestamp (past or future allowed)
     */
    function startNewEpoch(uint256 scheduledTime) external;

    /**
     * @notice Ends the current epoch immediately or schedules it for a specific timestamp
     * @dev Allows for gap periods between epochs
     * @dev Reverts if no epoch is active. Can reschedule end if epoch hasn't ended yet
     * @param scheduledTime 0 = end immediately, >0 = schedule for this timestamp (past or future allowed)
     */
    function endCurrentEpoch(uint256 scheduledTime) external;

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the current epoch number
     * @return Current epoch number
     */
    function currentEpoch() external view returns (uint256);

    /**
     * @notice Get the current epoch start timestamp
     * @return Timestamp when current epoch started
     */
    function currentEpochStartTime() external view returns (uint256);

    /**
     * @notice Get active epoch data
     * @return epochNumber Active epoch number (0 if none)
     * @return startTime Timestamp when epoch started
     * @return endTime Timestamp when epoch ends (0 if not scheduled)
     * @return duration Duration in seconds (0 if end not scheduled)
     */
    function getActiveEpoch()
        external
        view
        returns (uint256 epochNumber, uint256 startTime, uint256 endTime, uint256 duration);

    /**
     * @notice Get specific epoch data
     * @param epochNumber The epoch number to query
     * @return id The epoch number
     * @return startTime Timestamp when epoch started
     * @return endTime Timestamp when epoch ended (0 if not ended)
     * @return duration Duration in seconds (0 if not ended)
     */
    function getEpoch(uint256 epochNumber)
        external
        view
        returns (uint256 id, uint256 startTime, uint256 endTime, uint256 duration);

    /**
     * @notice Check if an epoch is active
     * @param epochNumber The epoch number to check
     * @return True if epoch is current and active
     */
    function isEpochActive(uint256 epochNumber) external view returns (bool);

    /**
     * @notice Check if the leaderboard has started
     * @return True if at least one epoch has been started (currentEpoch > 0)
     */
    function hasStarted() external view returns (bool);

    /**
     * @notice Check if currently in a gap period (between epochs)
     * @return True if leaderboard has started but no epoch is currently active
     */
    function isInGapPeriod() external view returns (bool);

    /**
     * @notice Get latest epoch number created (may not be active yet)
     * @return Latest epoch number
     */
    function latestEpoch() external view returns (uint256);
}
