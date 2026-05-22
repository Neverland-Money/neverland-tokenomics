// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AggregatorInterface} from "@aave/core-v3/contracts/dependencies/chainlink/AggregatorInterface.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IYieldBearingOracleAdapter
 * @author Neverland
 * @notice Interface for yield-bearing asset oracle adapter with growth rate protection
 * @dev Adapts a single oracle feed for yield-bearing assets with rate-limiting on share ratio growth.
 *      Legacy AggregatorInterface functions return 0 on failure; V3 functions revert on invalid data.
 *      Historical rounds are not supported: getRoundData returns the latest round only and reverts
 *      for non-latest roundIds.
 */
interface IYieldBearingOracleAdapter is AggregatorInterface, AggregatorV3Interface {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the shares conversion is invalid
    error InvalidSharesConversion();

    /// @notice Emitted when the snapshot ratio is invalid
    error InvalidSnapshotRatio();

    /// @notice Emitted when the snapshot timestamp is invalid
    error InvalidSnapshotTimestamp();

    /// @notice Emitted when the growth rate is invalid
    error InvalidGrowthRate();

    /// @notice Emitted when rejection grace is invalid
    error InvalidRejectionGrace();

    /// @notice Emitted when the snapshot is too recent
    error SnapshotTooRecent();

    /// @notice Emitted when the snapshot is too old
    error SnapshotTooOld();

    /// @notice Emitted when the ownership is required
    error OwnershipRequired();

    /// @notice Emitted when the keeper address is invalid
    error InvalidKeeper();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Emitted when growth cap bounds are updated
     * @param maxAnnualGrowthBps Maximum allowed annual growth in basis points
     * @param growthRatePerSecond Calculated growth rate per second, scaled by 1e18
     */
    event GrowthCapBoundsUpdated(uint256 maxAnnualGrowthBps, uint256 growthRatePerSecond);

    /**
     * @notice Emitted when a snapshot update is queued (timelock)
     * @param snapshotRatio The queued snapshot ratio
     * @param effectiveAt Timestamp when the snapshot will become active
     */
    event SnapshotQueued(uint256 snapshotRatio, uint256 effectiveAt);

    /**
     * @notice Emitted when a queued snapshot becomes active
     * @param snapshotRatio The activated snapshot ratio
     * @param effectiveAt Timestamp when the snapshot became active
     */
    event SnapshotActivated(uint256 snapshotRatio, uint256 effectiveAt);

    /**
     * @notice Emitted when rejection grace is updated
     * @param previousRejectionGraceBps The previous rejection grace in basis points
     * @param newRejectionGraceBps The new rejection grace in basis points
     */
    event RejectionGraceUpdated(uint256 previousRejectionGraceBps, uint256 newRejectionGraceBps);

    /**
     * @notice Emitted when the keeper address is updated
     * @param previousKeeper The previous keeper address
     * @param newKeeper The new keeper address
     */
    event KeeperUpdated(address indexed previousKeeper, address indexed newKeeper);

    /*//////////////////////////////////////////////////////////////
                                FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Returns the base asset price oracle
     * @return The base aggregator interface
     */
    function baseAggregator() external view returns (AggregatorV3Interface);

    /**
     * @notice Returns the ERC4626 shares contract
     * @return The shares contract interface
     */
    function sharesContract() external view returns (IERC4626);

    /**
     * @notice Returns the maximum staleness delay in seconds
     * @return The maximum staleness delay in seconds
     */
    function maxDelay() external view returns (uint256);

    /**
     * @notice Returns the number of decimals for the base oracle
     * @return The number of decimals
     */
    function baseDecimals() external view returns (uint8);

    /**
     * @notice Returns the number of decimals for the shares token
     * @return The number of decimals
     */
    function sharesDecimals() external view returns (uint8);

    /**
     * @notice Returns the number of decimals for the underlying asset
     * @return The number of decimals
     */
    function assetDecimals() external view returns (uint8);

    /**
     * @notice Returns the minimum delay required between snapshot and current time
     * @dev A value of 0 disables the timelock; queued snapshots become effective immediately.
     * @return The minimum snapshot delay in seconds
     */
    function minimumSnapshotDelay() external view returns (uint48);

    /**
     * @notice Returns the snapshot staleness threshold in seconds
     * @dev This value is intended for monitoring; growth extrapolation does not hard-stop at this age.
     * @return The snapshot staleness threshold in seconds
     */
    function maximumSnapshotAge() external view returns (uint48);

    /*//////////////////////////////////////////////////////////////
                        LEGACY AGGREGATOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the latest price answer
     * @dev Returns 0 on failure
     * @return answer The latest price answer
     */
    function latestAnswer() external view override returns (int256 answer);

    /**
     * @notice Returns the timestamp of the latest round
     * @dev Returns 0 on failure
     * @return timestamp The timestamp of the latest round
     */
    function latestTimestamp() external view override returns (uint256 timestamp);

    /**
     * @notice Returns the latest round ID
     * @dev Returns 0 on failure
     * @return roundId The latest round ID
     */
    function latestRound() external view override returns (uint256 roundId);

    /**
     * @notice Returns the answer for a specific round
     * @dev Only the latest round is supported; non-latest rounds return 0
     * @param roundId The round ID to query
     * @return answer The answer for the requested round
     */
    function getAnswer(uint256 roundId) external view override returns (int256 answer);

    /**
     * @notice Returns the timestamp for a specific round
     * @dev Only the latest round is supported; non-latest rounds return 0
     * @param roundId The round ID to query
     * @return timestamp The timestamp for the requested round
     */
    function getTimestamp(uint256 roundId) external view override returns (uint256 timestamp);

    /**
     * @notice Sets growth cap bounds (owner only)
     * @dev Updates the maximum allowed annual growth rate
     * @param maxAnnualGrowthBps Maximum allowed annual growth in basis points (e.g., 500 = 5%)
     */
    function setGrowthCapBounds(uint16 maxAnnualGrowthBps) external;

    /**
     * @notice Queues a snapshot update with timelock delay (owner or keeper)
     * @dev Reads current ratio on-chain and queues it to become active after minimumSnapshotDelay,
     *      with activation determined by time (no activation transaction). If no snapshot exists yet,
     *      the first snapshot is effective immediately. A minimumSnapshotDelay of 0 makes
     *      subsequent snapshots effective immediately as well. This relies on trusted owner/keeper
     *      access and does not implement TWAP or slippage protections.
     */
    function updateSnapshot() external;

    /**
     * @notice Immediately updates and activates a snapshot (owner only)
     * @dev Bypasses the timelock to restore pricing when capped.
     */
    function updateSnapshotImmediate() external;

    /**
     * @notice Check if current ratio exceeds growth cap
     * @dev Returns false if the ratio cannot be determined or no effective snapshot is set.
     *      With rejection grace configured, `true` means the live ratio is above the hard cap,
     *      but pricing may still be available (clamped at hard cap) until grace is exceeded.
     * @return isCapped True if ratio would be capped
     */
    function isCapped() external view returns (bool);

    /**
     * @notice Returns the snapshot ratio used for growth cap calculations
     * @dev If a pending snapshot is time-effective, this returns the pending ratio.
     * @return The snapshot ratio
     */
    function getSnapshotRatio() external view returns (uint256);

    /**
     * @notice Returns the snapshot timestamp
     * @dev If a pending snapshot is time-effective, this returns its effectiveAt timestamp.
     * @return The snapshot timestamp
     */
    function getSnapshotTimestamp() external view returns (uint256);

    /**
     * @notice Returns the maximum annual growth rate in basis points
     * @return The maximum annual growth in basis points
     */
    function getMaxAnnualGrowthBps() external view returns (uint256);

    /**
     * @notice Returns the growth rate per second
     * @return The growth rate per second, scaled by 1e18
     */
    function getGrowthRatePerSecond() external view returns (uint256);

    /**
     * @notice Returns the rejection grace in basis points
     * @dev Ratio values above hard cap but within hard cap + rejection grace are accepted
     *      and clamped to the hard cap for pricing.
     * @return rejectionGraceBps The rejection grace in basis points
     */
    function getRejectionGraceBps() external view returns (uint256 rejectionGraceBps);

    /**
     * @notice Returns the current slack between the live ratio and the cap
     * @dev Returns (0, false) if the slack cannot be determined.
     * @return slackBps Remaining headroom in basis points relative to the cap
     * @return ok True if slack was computed successfully, false if undetermined
     */
    function getCurrentSlackBps() external view returns (uint256 slackBps, bool ok);

    /**
     * @notice Sets the rejection grace in basis points (owner only)
     * @dev Must be <= 10000 bps. Grace affects rejection threshold only; pricing remains clamped at hard cap.
     * @param rejectionGraceBps The new rejection grace in basis points
     */
    function setRejectionGraceBps(uint16 rejectionGraceBps) external;

    /**
     * @notice Returns the keeper address
     * @return The keeper address
     */
    function keeper() external view returns (address);

    /**
     * @notice Sets the keeper address that can update growth cap parameters
     * @dev Use address(0) to disable keeper updates
     * @param newKeeper The address of the new keeper
     */
    function setKeeper(address newKeeper) external;
}
