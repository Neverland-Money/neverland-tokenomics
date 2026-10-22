// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {ISessionCalendar} from "./ISessionCalendar.sol";

/**
 * @title IMarketHoursPriceAdapter
 * @author Neverland
 * @notice Interface for the per-stock Aave price source that follows trading sessions
 * @dev The feed's latest positive round is served under one of two age bounds: a round posted since the
 *      current session opened may be MAX_SESSION_AGE old, any other round MAX_CLOSURE_AGE old if it was
 *      within MAX_SESSION_AGE when the market last closed. The market's last print therefore prices the
 *      stock through every closure and after the reopen until the feed prints again, and gap risk at the
 *      reopen is carried by collateral parameters and the sentinel's opening grace. A rejected round returns
 *      0; AaveOracle then invokes its fallback, which the stock pool leaves unset so price-dependent actions
 *      revert. Ordinary repayment remains available. Nothing but the feed and the calendar is read.
 */
interface IMarketHoursPriceAdapter {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Reverts when the calendar has no code or cannot answer sessionStart or lastEndedSession
    error InvalidCalendar();

    /// @notice Reverts when the closure age is below the session age or exceeds MAX_CLOSURE_AGE_CEILING
    error InvalidClosureAge();

    /// @notice Reverts when the feed has no code or cannot answer latestRoundData
    error InvalidFeed();

    /// @notice Reverts when the session age exceeds MAX_SESSION_AGE_CEILING
    error InvalidSessionAge();

    /*//////////////////////////////////////////////////////////////
                                FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the largest closure age the adapter accepts at construction
     * @return The ceiling in seconds (7 days)
     */
    function MAX_CLOSURE_AGE_CEILING() external view returns (uint256);

    /**
     * @notice Returns the largest session age the adapter accepts at construction
     * @return The ceiling in seconds (7 days)
     */
    function MAX_SESSION_AGE_CEILING() external view returns (uint256);

    /**
     * @notice Returns the wrapped Chainlink feed
     * @return The 8-decimal tokenized-equity feed
     */
    function FEED() external view returns (AggregatorV3Interface);

    /**
     * @notice Returns the session calendar
     * @return The calendar that decides open and closed
     */
    function CALENDAR() external view returns (ISessionCalendar);

    /**
     * @notice Returns the oldest age a round posted since the current session opened may reach
     * @dev Size it above the feed's heartbeat with operational margin; launch value 2 days.
     * @return The limit in seconds
     */
    function MAX_SESSION_AGE() external view returns (uint256);

    /**
     * @notice Returns the oldest age a round from before the current session opened may reach
     * @dev Bounds the last print's life through a closure. The feeds post nothing while the market is closed,
     *      so size it to the longest closure plus the heartbeat; launch value 5 days.
     * @return The limit in seconds
     */
    function MAX_CLOSURE_AGE() external view returns (uint256);

    /**
     * @notice Returns the price Aave should use
     * @dev Returns 0 when the answer is rejected by the age rules, is a fault answer, or when the feed reverts.
     *      A feed whose answer no longer decodes reverts the read instead, as it does in the repository's
     *      other adapters.
     * @return The price at 8 decimals, or 0
     */
    function latestAnswer() external view returns (int256);

    /**
     * @notice Returns the wrapped feed's latest update timestamp
     * @dev Feed diagnostics only: the age rules are not applied, so a fresh timestamp does not mean the
     *      answer is being served. Returns 0 when the feed reverts.
     * @return The feed's `updatedAt`
     */
    function latestTimestamp() external view returns (uint256);

    /**
     * @notice Returns the wrapped feed's latest round with the served answer
     * @dev Round metadata comes from the feed unchanged; `answer` follows the same rules as latestAnswer. A
     *      fresh timestamp alone does not establish validity: the calendar can reject the price. A feed fault
     *      bubbles up.
     * @return roundId The feed's round ID
     * @return answer The served price at 8 decimals, or 0
     * @return startedAt The feed's round start timestamp
     * @return updatedAt The feed's round update timestamp
     * @return answeredInRound The feed's answered-in round
     */
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /**
     * @notice Returns the answer's decimals
     * @return Always 8
     */
    function decimals() external pure returns (uint8);

    /**
     * @notice Returns the human-readable description of the adapter
     * @return The adapter description
     */
    function description() external view returns (string memory);

    /**
     * @notice Returns the adapter interface version
     * @return The version number (1)
     */
    function version() external pure returns (uint256);
}
