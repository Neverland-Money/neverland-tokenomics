// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {IMarketHoursPriceAdapter} from "../interfaces/IMarketHoursPriceAdapter.sol";
import {ISessionCalendar} from "../interfaces/ISessionCalendar.sol";

import {CommonChecksLibrary} from "../libraries/CommonChecksLibrary.sol";
import {OracleLib} from "../libraries/OracleLib.sol";

/**
 * @title MarketHoursPriceAdapter
 * @author Neverland
 * @notice Session-aware Aave price source for one tokenized stock
 * @dev Direct deployment, no upgrade path, no owner. Serves the feed's latest round through market closures.
 *      A round posted since the current session opened may be MAX_SESSION_AGE old; any other round, which is
 *      the last print before a closure, may be MAX_CLOSURE_AGE old provided it was within MAX_SESSION_AGE at
 *      the close. That print keeps pricing the stock after the reopen until the feed prints again. Launch
 *      values are 2 days and 5 days: the feeds post nothing while the market is closed, print within 90
 *      seconds of every open, and carry a 24-hour heartbeat in session. The feed and the calendar are the
 *      only sources read.
 */
contract MarketHoursPriceAdapter is IMarketHoursPriceAdapter {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMarketHoursPriceAdapter
    uint256 public constant MAX_CLOSURE_AGE_CEILING = 7 days;

    /// @inheritdoc IMarketHoursPriceAdapter
    uint256 public constant MAX_SESSION_AGE_CEILING = 7 days;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMarketHoursPriceAdapter
    AggregatorV3Interface public immutable FEED;

    /// @inheritdoc IMarketHoursPriceAdapter
    ISessionCalendar public immutable CALENDAR;

    /// @inheritdoc IMarketHoursPriceAdapter
    uint256 public immutable MAX_SESSION_AGE;

    /// @inheritdoc IMarketHoursPriceAdapter
    uint256 public immutable MAX_CLOSURE_AGE;

    /*//////////////////////////////////////////////////////////////
                            STORAGE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMarketHoursPriceAdapter
    string public description;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys the adapter for one stock feed
     * @dev Reverts on zero addresses, a zero session age or one above MAX_SESSION_AGE_CEILING, a closure age
     *      below the session age or above MAX_CLOSURE_AGE_CEILING, a feed whose decimals are not 8, a feed
     *      that cannot answer latestRoundData, and a calendar that cannot answer sessionStart or
     *      lastEndedSession, the two reads every price read makes. Both sources are fixed for life.
     * @param feed The Chainlink tokenized-equity feed
     * @param calendar The session calendar
     * @param maxSessionAge The oldest age a round posted since the session opened may reach, in seconds
     * @param maxClosureAge The oldest age a round from before the session opened may reach, in seconds
     * @param _description Human-readable adapter description
     */
    constructor(
        AggregatorV3Interface feed,
        ISessionCalendar calendar,
        uint256 maxSessionAge,
        uint256 maxClosureAge,
        string memory _description
    ) {
        CommonChecksLibrary.revertIfZeroAddress(address(feed));
        CommonChecksLibrary.revertIfZeroAddress(address(calendar));
        CommonChecksLibrary.revertIfZeroAmount(maxSessionAge);
        if (maxSessionAge > MAX_SESSION_AGE_CEILING) revert InvalidSessionAge();
        if (maxClosureAge < maxSessionAge || maxClosureAge > MAX_CLOSURE_AGE_CEILING) revert InvalidClosureAge();
        _revertIfInvalidFeed(feed);
        _revertIfInvalidCalendar(calendar);

        FEED = feed;
        CALENDAR = calendar;
        MAX_SESSION_AGE = maxSessionAge;
        MAX_CLOSURE_AGE = maxClosureAge;
        description = _description;
    }

    /*//////////////////////////////////////////////////////////////
                            AAVE PRICE SOURCE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMarketHoursPriceAdapter
    function latestAnswer() external view returns (int256) {
        (bool ok, int256 answer, uint256 updatedAt) = _tryLatestRound(FEED);
        if (!ok) return 0;

        return _servedAnswer(answer, updatedAt);
    }

    /// @inheritdoc IMarketHoursPriceAdapter
    function latestTimestamp() external view returns (uint256) {
        (bool ok,, uint256 updatedAt) = _tryLatestRound(FEED);

        return ok ? updatedAt : 0;
    }

    /*//////////////////////////////////////////////////////////////
                           CHAINLINK V3 READS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMarketHoursPriceAdapter
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) = FEED.latestRoundData();

        return (roundId, _servedAnswer(answer, updatedAt), startedAt, updatedAt, answeredInRound);
    }

    /// @inheritdoc IMarketHoursPriceAdapter
    function decimals() external pure returns (uint8) {
        return uint8(OracleLib.TARGET_DECIMALS);
    }

    /// @inheritdoc IMarketHoursPriceAdapter
    function version() external pure returns (uint256) {
        return 1;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Applies the age rules to a feed answer
     * @dev The calendar decides only which bound applies. A round posted since the current session opened is
     *      held to MAX_SESSION_AGE. Every other round, the last print before a closure included, is held to
     *      MAX_CLOSURE_AGE and must have been within MAX_SESSION_AGE when the market last closed, so a round
     *      that went stale in session stays rejected through the closure instead of reviving at the close.
     * @param answer The feed's latest answer
     * @param updatedAt The feed's latest update timestamp
     * @return The answer to serve, or 0 when it must not be used
     */
    function _servedAnswer(int256 answer, uint256 updatedAt) private view returns (int256) {
        if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) return 0;

        uint256 start = CALENDAR.sessionStart(block.timestamp);
        if (start != 0 && updatedAt >= start) {
            if (block.timestamp - updatedAt > MAX_SESSION_AGE) return 0;
        } else {
            uint256 closedAt = CALENDAR.lastEndedSession(block.timestamp);
            if (closedAt > updatedAt + MAX_SESSION_AGE || block.timestamp - updatedAt > MAX_CLOSURE_AGE) return 0;
        }

        return answer;
    }

    /**
     * @notice Reads the feed's latest round without letting a reverting feed revert the Aave price path
     * @dev The legacy reads answer 0 on a feed that reverts, the rule every adapter in this repository applies
     *      on the path AaveOracle reads; the Chainlink V3 read bubbles the fault. A feed whose answer no
     *      longer decodes, one with its code removed or one answering in another shape, reverts here instead,
     *      since a try statement cannot catch a decoding failure. The deployment probe reads through this
     *      function and rejects a feed that reverts.
     * @param feed The feed to read
     * @return ok True when the feed answered latestRoundData
     * @return answer The feed's latest answer
     * @return updatedAt The feed's latest update timestamp
     */
    function _tryLatestRound(AggregatorV3Interface feed)
        private
        view
        returns (bool ok, int256 answer, uint256 updatedAt)
    {
        try feed.latestRoundData() returns (uint80, int256 feedAnswer, uint256, uint256 feedUpdatedAt, uint80) {
            return (true, feedAnswer, feedUpdatedAt);
        } catch {
            return (false, 0, 0);
        }
    }

    /**
     * @notice Reverts when a feed has no code, reports decimals other than 8, or cannot answer latestRoundData
     * @param feed The feed to validate
     */
    function _revertIfInvalidFeed(AggregatorV3Interface feed) private view {
        if (address(feed).code.length == 0) revert InvalidFeed();
        if (feed.decimals() != OracleLib.TARGET_DECIMALS) revert CommonChecksLibrary.InvalidDecimals();
        (bool ok,,) = _tryLatestRound(feed);
        if (!ok) revert InvalidFeed();
    }

    /**
     * @notice Reverts when a calendar has no code or cannot answer the two reads the served path makes
     * @dev Probes sessionStart and lastEndedSession at the deployment timestamp, the calls _servedAnswer makes
     *      on every price read. The calendar is fixed at deployment, so a target that cannot answer either
     *      read is rejected here rather than reverting every price read for the life of the adapter.
     * @param calendar The calendar to validate
     */
    function _revertIfInvalidCalendar(ISessionCalendar calendar) private view {
        if (address(calendar).code.length == 0) revert InvalidCalendar();

        _revertIfCalendarReadFails(calendar.sessionStart);
        _revertIfCalendarReadFails(calendar.lastEndedSession);
    }

    /**
     * @notice Reverts when a calendar read fails at the deployment timestamp or answers a moment after it
     * @dev No window containing the timestamp starts after it and no session that had ended by it ends after
     *      it, so an answer past the timestamp means the target is not a calendar, whatever its code answers.
     * @param read The calendar view to probe, sessionStart or lastEndedSession
     */
    function _revertIfCalendarReadFails(function(uint256) external view returns (uint256) read) private view {
        try read(block.timestamp) returns (uint256 answer) {
            if (answer > block.timestamp) revert InvalidCalendar();
        } catch {
            revert InvalidCalendar();
        }
    }
}
