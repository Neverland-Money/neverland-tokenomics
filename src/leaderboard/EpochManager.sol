// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {CommonChecksLibrary} from "../libraries/CommonChecksLibrary.sol";
import {IEpochManager} from "../interfaces/IEpochManager.sol";

/**
 * @title EpochManager
 * @author Neverland
 * @notice Manages leaderboard epochs for the Neverland points system
 * @dev Emits events that the subgraph listens to for epoch transitions
 * @custom:oz-upgrades-unsafe-allow constructor
 */
contract EpochManager is IEpochManager, OwnableUpgradeable {
    /*//////////////////////////////////////////////////////////////
                          STORAGE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Latest epoch number created (may not be active yet if scheduled)
    uint256 public latestEpoch;

    /// @notice Mapping of epoch number to start timestamp
    mapping(uint256 => uint256) public epochStartTimes;

    /// @notice Mapping of epoch number to end timestamp
    mapping(uint256 => uint256) public epochEndTimes;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Disables initializers on the implementation contract
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the manager (leaderboard not started yet)
     * @param _initialOwner Initial owner for Ownable
     */
    function initialize(address _initialOwner) external initializer {
        __Ownable_init();
        _transferOwnership(_initialOwner);
        CommonChecksLibrary.revertIfZeroAddress(_initialOwner);
    }

    /*//////////////////////////////////////////////////////////////
                               ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IEpochManager
    function startNewEpoch(uint256 scheduledTime) external onlyOwner {
        uint256 currentActive = currentEpoch();
        if (currentActive != 0 && epochEndTimes[currentActive] == 0) revert EpochStillActive();

        uint256 epochNumber = latestEpoch + 1;
        latestEpoch = epochNumber;

        // Allows retrospective epoch start
        uint256 startTime = scheduledTime > 0 ? scheduledTime : block.timestamp;

        epochStartTimes[epochNumber] = startTime;

        emit EpochStart(epochNumber, startTime);
    }

    /// @inheritdoc IEpochManager
    function endCurrentEpoch(uint256 scheduledTime) external onlyOwner {
        uint256 currentActive = currentEpoch();
        if (currentActive == 0) revert NoEpochToEnd();

        uint256 startTime = epochStartTimes[currentActive];

        // Allows retrospective epoch end
        uint256 endTime = scheduledTime > 0 ? scheduledTime : block.timestamp;
        if (endTime <= startTime) revert ScheduledEndBeforeStart();

        epochEndTimes[currentActive] = endTime;

        emit EpochEnd(currentActive, endTime);
    }

    /// @notice Disabled to prevent accidental renouncement of ownership
    function renounceOwnership() public view override onlyOwner {
        revert();
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IEpochManager
    function currentEpoch() public view returns (uint256) {
        if (latestEpoch == 0) return 0;

        // Check if latest epoch has started
        uint256 startTime = epochStartTimes[latestEpoch];
        if (block.timestamp < startTime) {
            // Latest epoch hasn't started yet, return previous epoch if it exists and hasn't ended
            if (latestEpoch > 1 && epochEndTimes[latestEpoch - 1] > block.timestamp) {
                return latestEpoch - 1;
            }
            return 0; // In gap or before first epoch
        }

        // Latest epoch has started - check if it has ended
        uint256 endTime = epochEndTimes[latestEpoch];
        if (endTime > 0 && block.timestamp >= endTime) {
            return 0; // Epoch ended, in gap
        }

        return latestEpoch;
    }

    /// @inheritdoc IEpochManager
    function getActiveEpoch()
        external
        view
        returns (uint256 epochNumber, uint256 startTime, uint256 endTime, uint256 duration)
    {
        epochNumber = currentEpoch();
        if (epochNumber == 0) {
            return (0, 0, 0, 0);
        }
        startTime = epochStartTimes[epochNumber];
        endTime = epochEndTimes[epochNumber];
        duration = endTime > 0 ? endTime - startTime : 0;
    }

    /// @inheritdoc IEpochManager
    function getEpoch(uint256 epochNumber)
        external
        view
        returns (uint256 id, uint256 startTime, uint256 endTime, uint256 duration)
    {
        id = epochNumber;
        startTime = epochStartTimes[epochNumber];
        endTime = epochEndTimes[epochNumber];
        duration = endTime > 0 ? endTime - startTime : 0;
    }

    /// @inheritdoc IEpochManager
    function isEpochActive(uint256 epochNumber) external view returns (bool) {
        if (epochNumber == 0) return false;
        return epochNumber == currentEpoch() && epochEndTimes[epochNumber] == 0;
    }

    /// @inheritdoc IEpochManager
    function hasStarted() external view returns (bool) {
        return latestEpoch > 0;
    }

    /// @inheritdoc IEpochManager
    function isInGapPeriod() external view returns (bool) {
        return latestEpoch > 0 && currentEpoch() == 0;
    }

    /// @inheritdoc IEpochManager
    function currentEpochStartTime() external view returns (uint256) {
        uint256 current = currentEpoch();
        return current == 0 ? 0 : epochStartTimes[current];
    }

    /*//////////////////////////////////////////////////////////////
                              STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    /// @dev Reserved storage gap for future upgrades
    uint256[50] private __gap;
}
