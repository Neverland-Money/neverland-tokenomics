// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AggregatorInterface} from "@aave/core-v3/contracts/dependencies/chainlink/AggregatorInterface.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title IRatioOracleAggregator
 * @author Neverland
 * @notice Interface for ratio-based oracle aggregator that multiplies two price feeds
 * @dev Aggregates ratio oracle (e.g., sMON/MON) with base USD oracle (e.g., MON/USD).
 *      Legacy AggregatorInterface functions return 0 on failure; V3 functions revert on invalid data.
 *      Historical rounds are not supported: getRoundData returns the latest round only and reverts
 *      for non-latest roundIds.
 */
interface IRatioOracleAggregator is AggregatorInterface, AggregatorV3Interface {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Used when the ratio value is invalid
    error InvalidRatio();

    /*//////////////////////////////////////////////////////////////
                                FUNCTIONS
    //////////////////////////////////////////////////////////////**/
    /**
     * @notice Returns the ratio aggregator address
     * @return The ratio aggregator interface
     */
    function ratioAggregator() external view returns (AggregatorV3Interface);

    /**
     * @notice Returns the base USD aggregator contract
     * @return The base aggregator interface
     */
    function baseAggregator() external view returns (AggregatorV3Interface);

    /**
     * @notice Returns the maximum staleness delay in seconds
     * @return The maximum staleness delay in seconds
     */
    function maxDelay() external view returns (uint256);

    /**
     * @notice Returns the number of decimals for the ratio oracle
     * @return The number of decimals
     */
    function ratioDecimals() external view returns (uint8);

    /**
     * @notice Returns the number of decimals for the base oracle
     * @return The number of decimals
     */
    function baseDecimals() external view returns (uint8);

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
}
