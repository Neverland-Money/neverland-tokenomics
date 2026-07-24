// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AggregatorInterface} from "@aave/core-v3/contracts/dependencies/chainlink/AggregatorInterface.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title IHardcodedPriceOracle
 * @author Neverland
 * @notice Interface for a fixed-price, non-upgradeable Chainlink/Aave-compatible price feed
 * @dev Reports a single immutable USD price (the deploy-set answer at the 8-decimal TARGET_DECIMALS
 *      scale Aave consumes — e.g. 100000000 for $1.00 or 104000000 for $1.04) on every read path.
 *      There is no owner, no setter, and no upgrade path: the answer is constant for all time and the
 *      feed never reverts at read time, so it can serve as a hardcoded Aave price source for an asset
 *      whose USD value is pinned by design (e.g. a $1 stablecoin). An invalid deploy price (zero, or
 *      one beyond the int256 answer range) reverts construction, so a live feed always reports a
 *      strictly positive, never-stale price. Round metadata is degenerate: every read returns the
 *      same answer, a single constant round ID, and `block.timestamp`, keeping any downstream
 *      staleness check perpetually fresh.
 */
interface IHardcodedPriceOracle is AggregatorInterface, AggregatorV3Interface {
    /// @notice Thrown when the deploy price is zero or beyond the int256 answer range
    error InvalidPrice();

    /**
     * @notice Returns the fixed price answer
     * @return answer The constant price in TARGET_DECIMALS (8-decimal) USD scale
     */
    function latestAnswer() external view override returns (int256 answer);

    /**
     * @notice Returns the latest round timestamp
     * @return timestamp The current block timestamp (the feed is always fresh)
     */
    function latestTimestamp() external view override returns (uint256 timestamp);

    /**
     * @notice Returns the constant round ID
     * @return roundId The single perpetual round ID
     */
    function latestRound() external view override returns (uint256 roundId);

    /**
     * @notice Returns the fixed price answer for any round
     * @dev The round ID is ignored; every round shares the one constant answer.
     * @return answer The constant price in TARGET_DECIMALS USD scale
     */
    function getAnswer(uint256) external view override returns (int256 answer);

    /**
     * @notice Returns the timestamp for any round
     * @dev The round ID is ignored; the feed is always fresh.
     * @return timestamp The current block timestamp
     */
    function getTimestamp(uint256) external view override returns (uint256 timestamp);
}
