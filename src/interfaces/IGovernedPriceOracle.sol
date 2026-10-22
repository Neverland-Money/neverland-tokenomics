// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AggregatorInterface} from "@aave/core-v3/contracts/dependencies/chainlink/AggregatorInterface.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title IGovernedPriceOracle
 * @author Neverland
 * @notice Interface for an owner-governed, non-upgradeable Chainlink/Aave-compatible price feed
 * @dev Reports a single owner-posted USD price at the 8-decimal TARGET_DECIMALS scale Aave consumes
 *      (e.g. 100000000 for $1.00). The price is a governance input, not market data: the owner
 *      (the Governance Safe in production) is the only party that can move it, and freshness is a governance
 *      duty. There is no staleness gate, so latest/Aave-facing reads always serve the last posted answer.
 *      Round metadata is honest: each post, including a same-value re-attestation, increments the round
 *      ID and stamps `updatedAt`. Historical rounds are not stored: getRoundData returns the latest round
 *      only and reverts for non-latest roundIds; the legacy per-round reads return 0 for non-latest
 *      rounds. An invalid price (zero, or beyond the int256 answer range) is rejected at construction and
 *      on every update, so a live feed always reports a strictly positive answer.
 */
interface IGovernedPriceOracle is AggregatorInterface, AggregatorV3Interface {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Reverts when a posted price is zero or beyond the int256 answer range
    error InvalidPrice();

    /// @notice Reverts when ownership renouncement is attempted (disabled to keep price control)
    error OwnershipRequired();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when the owner posts a new price
     * @param previousAnswer The previous price in TARGET_DECIMALS (8-decimal) USD scale
     * @param newAnswer The new price in TARGET_DECIMALS (8-decimal) USD scale
     */
    event PriceUpdated(int256 previousAnswer, int256 newAnswer);

    /*//////////////////////////////////////////////////////////////
                                FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Posts a new price (owner only)
     * @dev Rejects zero and values beyond the int256 answer range. Increments the round ID and stamps
     *      `updatedAt` with the current block timestamp, including for a same-value re-attestation. Emits
     *      `NewRound`, `AnswerUpdated`, and `PriceUpdated`.
     * @param newAnswer The new price in TARGET_DECIMALS (8-decimal) USD scale (e.g. 100000000 = $1.00)
     */
    function setPrice(uint256 newAnswer) external;

    /**
     * @notice Renouncing ownership is disabled to prevent accidental loss of price control
     * @dev Reverts on every call so price control cannot be frozen by renouncing ownership.
     */
    function renounceOwnership() external view;

    /*//////////////////////////////////////////////////////////////
                          AGGREGATOR V3
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the fixed number of decimals for the answer
     * @dev Always 8 (Chainlink USD convention).
     * @return The number of decimals (8)
     */
    function decimals() external view override returns (uint8);

    /**
     * @notice Returns the human-readable description of the oracle
     * @return The oracle description
     */
    function description() external view override returns (string memory);

    /**
     * @notice Returns the oracle interface version
     * @return The version number (1)
     */
    function version() external view override returns (uint256);

    /**
     * @notice Returns the latest posted round
     * @dev The answer is the last owner-posted price; `startedAt` and `updatedAt` are the timestamp of
     *      that post, and `roundId == answeredInRound` is the post counter. Never reverts.
     * @return roundId The current round ID (increments on every post)
     * @return answer The posted price in TARGET_DECIMALS (8-decimal) USD scale
     * @return startedAt The timestamp of the latest post
     * @return updatedAt The timestamp of the latest post
     * @return answeredInRound The current round ID
     */
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /**
     * @notice Returns round data for the requested round
     * @dev Latest-round only: historical rounds are not stored, so any non-latest `requestedRoundId`
     *      reverts with StaleRound.
     * @param requestedRoundId The round ID to query; must equal the current round ID
     * @return roundId The current round ID
     * @return answer The posted price in TARGET_DECIMALS (8-decimal) USD scale
     * @return startedAt The timestamp of the latest post
     * @return updatedAt The timestamp of the latest post
     * @return answeredInRound The current round ID
     */
    function getRoundData(uint80 requestedRoundId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /*//////////////////////////////////////////////////////////////
                        LEGACY AGGREGATOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the latest posted price
     * @dev Never reverts; the invariant that every accepted price is positive means this is always a
     *      strictly positive answer.
     * @return answer The posted price in TARGET_DECIMALS (8-decimal) USD scale
     */
    function latestAnswer() external view override returns (int256 answer);

    /**
     * @notice Returns the timestamp of the latest post
     * @return timestamp The timestamp the price was last posted
     */
    function latestTimestamp() external view override returns (uint256 timestamp);

    /**
     * @notice Returns the current round ID
     * @return roundId The post counter
     */
    function latestRound() external view override returns (uint256 roundId);

    /**
     * @notice Returns the answer for a specific round
     * @dev Only the latest round is stored; non-latest rounds return 0
     * @param roundId The round ID to query
     * @return answer The answer for the requested round
     */
    function getAnswer(uint256 roundId) external view override returns (int256 answer);

    /**
     * @notice Returns the timestamp for a specific round
     * @dev Only the latest round is stored; non-latest rounds return 0
     * @param roundId The round ID to query
     * @return timestamp The timestamp for the requested round
     */
    function getTimestamp(uint256 roundId) external view override returns (uint256 timestamp);
}
