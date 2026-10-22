// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {RatioOracleAggregator} from "../../../src/oracles/RatioOracleAggregator.sol";

/**
 * @title MockFeed
 * @notice Configurable Chainlink-style feed used to drive the lenient `_tryLatestData` path.
 * @dev Exposes independent setters for answer / roundId / updatedAt so a feed can report a
 *      POSITIVE price while still being "incomplete" (e.g. updatedAt == 0) — the exact shape
 *      required to reach the base-feed `_isComplete` guard inside `_tryLatestData`.
 */
contract MockFeed is AggregatorV3Interface {
    int256 private _answer;
    uint8 private _decimals;
    uint80 private _roundId;
    uint256 private _startedAt;
    uint256 private _updatedAt;
    uint80 private _answeredInRound;

    constructor(int256 answer_, uint8 decimals_) {
        _answer = answer_;
        _decimals = decimals_;
        _roundId = 1;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
        _answeredInRound = 1;
    }

    function setAnswer(int256 answer_) external {
        _answer = answer_;
    }

    function setRoundId(uint80 roundId_) external {
        _roundId = roundId_;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }

    function setStartedAt(uint256 startedAt_) external {
        _startedAt = startedAt_;
    }

    function setAnsweredInRound(uint80 answeredInRound_) external {
        _answeredInRound = answeredInRound_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "Mock Feed";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }
}

/**
 * @title RatioOracleLenientCoverageTest
 * @notice Targets RatioOracleAggregator.sol:203 — the TRUE arm of the base-feed completeness
 *         guard inside the lenient `_tryLatestData` path (reached via `latestAnswer()`).
 */
contract RatioOracleLenientCoverageTest is Test {
    MockFeed internal ratioFeed;
    MockFeed internal baseFeed;
    RatioOracleAggregator internal oracle;

    function setUp() public {
        // Move off genesis so updatedAt == block.timestamp is a fresh, complete round by default.
        vm.warp(1_000_000);

        ratioFeed = new MockFeed(1.05e18, 18);
        baseFeed = new MockFeed(2000e8, 8);
        oracle = new RatioOracleAggregator(address(ratioFeed), address(baseFeed), 1 hours);
    }

    /// @notice Sanity: with both feeds fresh and complete, the lenient path returns the computed price.
    function test_baseline_latestAnswerComputesPrice() public view {
        int256 answer = oracle.latestAnswer();
        assertEq(answer, 2100e8);
    }

    /**
     * @notice Drives line 203 TRUE arm: base feed reports a POSITIVE price (passes line 202) but an
     *         INCOMPLETE round via updatedAt == 0, so `_isComplete(baseRoundId, 0)` is false →
     *         lenient path returns the (false, 0, 0, 0) fallback → `latestAnswer()` yields 0.
     * @dev Ratio feed stays fully valid so execution clears the ratio-side guards and reaches the
     *      base-feed branch. basePrice remains 2000e8 (> 0) to ensure line 202 is NOT the early-out.
     */
    function test_latestAnswerReturnsZeroWhenBaseRoundIncompleteZeroUpdatedAt() public {
        baseFeed.setUpdatedAt(0);

        int256 answer = oracle.latestAnswer();

        assertEq(answer, 0);
    }

    /**
     * @notice Second incarnation of line 203 TRUE arm via a future updatedAt (updatedAt > block.timestamp),
     *         which `_isComplete` also treats as incomplete. basePrice stays positive so line 202 passes.
     */
    function test_latestAnswerReturnsZeroWhenBaseRoundIncompleteFutureUpdatedAt() public {
        baseFeed.setUpdatedAt(block.timestamp + 1);

        int256 answer = oracle.latestAnswer();

        assertEq(answer, 0);
    }

    /**
     * @notice Third incarnation of line 203 TRUE arm via a zero base roundId, which `_isComplete`
     *         rejects (`roundId == 0`). basePrice stays positive and updatedAt fresh so the only
     *         failing condition inside `_isComplete` is the round id.
     */
    function test_latestAnswerReturnsZeroWhenBaseRoundIdZero() public {
        baseFeed.setRoundId(0);

        int256 answer = oracle.latestAnswer();

        assertEq(answer, 0);
    }
}
