// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {RatioOracleAggregator} from "../../src/oracles/RatioOracleAggregator.sol";
import {CommonChecksLibrary} from "../../src/libraries/CommonChecksLibrary.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract MockAggregator is AggregatorV3Interface {
    int256 private _answer;
    uint8 private _decimals;
    uint256 private _timestamp;
    uint80 private _roundId;
    uint80 private _answeredInRoundOverride;
    bool private _useAnsweredInRoundOverride;
    uint256 private _startedAtOverride;
    bool private _useStartedAtOverride;

    constructor(int256 answer_, uint8 decimals_) {
        _answer = answer_;
        _decimals = decimals_;
        _timestamp = block.timestamp;
        _roundId = 1;
    }

    function setAnswer(int256 answer_) external {
        _answer = answer_;
        _roundId++;
        _timestamp = block.timestamp;
    }

    function setStale() external {
        _timestamp = block.timestamp - 1 hours;
    }

    function setIncompleteRound() external {
        uint80 currentRound = _roundId;
        _roundId = currentRound + 5;
    }

    function setTimestamp(uint256 timestamp_) external {
        _timestamp = timestamp_;
    }

    function setAnsweredInRound(uint80 answeredInRound_) external {
        _answeredInRoundOverride = answeredInRound_;
        _useAnsweredInRoundOverride = true;
    }

    function clearAnsweredInRoundOverride() external {
        _useAnsweredInRoundOverride = false;
    }

    function setStartedAt(uint256 startedAt_) external {
        _startedAtOverride = startedAt_;
        _useStartedAtOverride = true;
    }

    function clearStartedAtOverride() external {
        _useStartedAtOverride = false;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "Mock Aggregator";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 requestedRoundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint80 answeredIn = _useAnsweredInRoundOverride
            ? _answeredInRoundOverride
            : (requestedRoundId < _roundId ? requestedRoundId : _roundId);
        uint256 startedAtValue = _useStartedAtOverride ? _startedAtOverride : _timestamp;
        return (_roundId, _answer, startedAtValue, _timestamp, answeredIn);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint80 answeredIn = _useAnsweredInRoundOverride ? _answeredInRoundOverride : _roundId;
        uint256 startedAtValue = _useStartedAtOverride ? _startedAtOverride : _timestamp;
        return (_roundId, _answer, startedAtValue, _timestamp, answeredIn);
    }

    function latestAnswer() external view returns (int256) {
        return _answer;
    }

    function latestTimestamp() external view returns (uint256) {
        return _timestamp;
    }

    function latestRound() external view returns (uint256) {
        return _roundId;
    }

    function getAnswer(uint256) external view returns (int256) {
        return _answer;
    }

    function getTimestamp(uint256) external view returns (uint256) {
        return _timestamp;
    }
}

contract MockAggregatorRevertLatestRoundData is AggregatorV3Interface {
    uint8 private _decimals;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "Mock Revert LatestRoundData";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external pure returns (uint80, int256, uint256, uint256, uint80) {
        return (0, 0, 0, 0, 0);
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert("LATEST_ROUND_DATA_REVERT");
    }

    function latestAnswer() external pure returns (int256) {
        return 0;
    }

    function latestTimestamp() external pure returns (uint256) {
        return 0;
    }

    function latestRound() external pure returns (uint256) {
        return 0;
    }

    function getAnswer(uint256) external pure returns (int256) {
        return 0;
    }

    function getTimestamp(uint256) external pure returns (uint256) {
        return 0;
    }
}

contract MockAggregatorZeroRound is AggregatorV3Interface {
    int256 private _answer;
    uint8 private _decimals;
    uint256 private _timestamp;

    constructor(int256 answer_, uint8 decimals_) {
        _answer = answer_;
        _decimals = decimals_;
        _timestamp = block.timestamp;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "Mock Zero Round";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, _answer, _timestamp, _timestamp, 0);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, _answer, _timestamp, _timestamp, 0);
    }

    function latestAnswer() external view returns (int256) {
        return _answer;
    }

    function latestTimestamp() external view returns (uint256) {
        return _timestamp;
    }

    function latestRound() external pure returns (uint256) {
        return 0;
    }

    function getAnswer(uint256) external view returns (int256) {
        return _answer;
    }

    function getTimestamp(uint256) external view returns (uint256) {
        return _timestamp;
    }
}

contract RatioOracleAggregatorTest is Test {
    RatioOracleAggregator public oracle;
    MockAggregator public ratioAgg;
    MockAggregator public baseAgg;

    address user = address(0x1);

    function setUp() public {
        ratioAgg = new MockAggregator(1.05e18, 18);
        baseAgg = new MockAggregator(2000e8, 8);
        oracle = new RatioOracleAggregator(address(ratioAgg), address(baseAgg), 1 hours);
    }

    function testConstructorSuccess() public view {
        assertEq(address(oracle.ratioAggregator()), address(ratioAgg));
        assertEq(address(oracle.baseAggregator()), address(baseAgg));
        assertEq(oracle.maxDelay(), 1 hours);
        assertEq(oracle.ratioDecimals(), 18);
        assertEq(oracle.baseDecimals(), 8);
        assertEq(oracle.decimals(), 8);
    }

    function testConstructorZeroAddresses() public {
        vm.expectRevert();
        new RatioOracleAggregator(address(0), address(baseAgg), 1 hours);

        vm.expectRevert();
        new RatioOracleAggregator(address(ratioAgg), address(0), 1 hours);
    }

    function testConstructorInvalidDecimals() public {
        MockAggregator invalidDecimals = new MockAggregator(1e18, 19);
        vm.expectRevert();
        new RatioOracleAggregator(address(invalidDecimals), address(baseAgg), 1 hours);

        vm.expectRevert();
        new RatioOracleAggregator(address(ratioAgg), address(invalidDecimals), 1 hours);

        MockAggregator lowDecimals = new MockAggregator(1e6, 5);
        vm.expectRevert();
        new RatioOracleAggregator(address(lowDecimals), address(baseAgg), 1 hours);

        vm.expectRevert();
        new RatioOracleAggregator(address(ratioAgg), address(lowDecimals), 1 hours);
    }

    function testLatestRoundData() public view {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();

        assertEq(roundId, 1);
        assertEq(answer, 2100e8);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, 1);
    }

    function testLatestRoundDataWithNegativeRatio() public {
        ratioAgg.setAnswer(-1e18);
        vm.expectRevert();
        oracle.latestRoundData();
    }

    function testLatestRoundDataWithNegativeBasePrice() public {
        baseAgg.setAnswer(-1000e8);
        vm.expectRevert();
        oracle.latestRoundData();
    }

    function testLatestRoundDataRevertsOnMulDivOverflow() public {
        MockAggregator ratioAggLarge = new MockAggregator(int256(1) << 200, 18);
        MockAggregator baseAggLarge = new MockAggregator(int256(1) << 200, 8);
        RatioOracleAggregator oracleLarge =
            new RatioOracleAggregator(address(ratioAggLarge), address(baseAggLarge), 1 hours);

        vm.expectRevert(CommonChecksLibrary.InvalidBasePrice.selector);
        oracleLarge.latestRoundData();
    }

    function testLatestRoundDataRevertsOnInt256Overflow() public {
        MockAggregator ratioAggLarge = new MockAggregator(int256(1) << 200, 18);
        MockAggregator baseAggLarge = new MockAggregator(int256(1) << 115, 8);
        RatioOracleAggregator oracleLarge =
            new RatioOracleAggregator(address(ratioAggLarge), address(baseAggLarge), 1 hours);

        vm.expectRevert(CommonChecksLibrary.InvalidBasePrice.selector);
        oracleLarge.latestRoundData();
    }

    function testLatestRoundDataStaleRatioRound() public {
        vm.expectRevert();
        oracle.getRoundData(999);
    }

    function testGetRoundDataWithOldRound() public {
        ratioAgg.setAnswer(1.1e18);
        vm.expectRevert();
        oracle.getRoundData(1);
    }

    function testLatestRoundDataPriceTooOld() public {
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert();
        oracle.latestRoundData();
    }

    function testGetRoundDataSuccess() public view {
        (uint80 roundId, int256 answer,,,) = oracle.getRoundData(1);
        assertEq(roundId, 1);
        assertEq(answer, 2100e8);
    }

    function testGetRoundDataStaleRound() public {
        ratioAgg.setAnswer(1.1e18);
        vm.expectRevert();
        oracle.getRoundData(1);
    }

    function testLatestAnswer() public view {
        int256 answer = oracle.latestAnswer();
        assertEq(answer, 2100e8);
    }

    function testLatestAnswerWithNegativeRatio() public {
        ratioAgg.setAnswer(-1e18);
        int256 answer = oracle.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestAnswerIgnoresRatioAnsweredInRound() public {
        ratioAgg.setAnsweredInRound(0);
        int256 answer = oracle.latestAnswer();
        assertEq(answer, 2100e8);
    }

    function testLatestAnswerWithZeroTimestamp() public {
        ratioAgg.setTimestamp(0);
        int256 answer = oracle.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestAnswerWithStaleTimestamp() public {
        vm.warp(3 hours);
        ratioAgg.setTimestamp(block.timestamp - 2 hours);
        int256 answer = oracle.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestAnswerIgnoresBaseAnsweredInRound() public {
        baseAgg.setAnsweredInRound(0);
        int256 answer = oracle.latestAnswer();
        assertEq(answer, 2100e8);
    }

    function testLatestAnswerReturnsZeroOnRatioAnsweredInRoundLessThanRoundId() public {
        ratioAgg.setAnswer(1.05e18);
        ratioAgg.setAnsweredInRound(1);
        int256 answer = oracle.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestAnswerReturnsZeroOnBaseAnsweredInRoundLessThanRoundId() public {
        baseAgg.setAnswer(2000e8);
        baseAgg.setAnsweredInRound(1);
        int256 answer = oracle.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestAnswerReturnsZeroOnRatioStartedAtAfterUpdatedAt() public {
        ratioAgg.setStartedAt(block.timestamp + 1);
        int256 answer = oracle.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestAnswerReturnsZeroOnBaseStartedAtAfterUpdatedAt() public {
        baseAgg.setStartedAt(block.timestamp + 1);
        int256 answer = oracle.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestAnswerReturnsZeroOnZeroRoundId() public {
        MockAggregatorZeroRound zeroRatio = new MockAggregatorZeroRound(1.05e18, 18);
        RatioOracleAggregator oracleZero = new RatioOracleAggregator(address(zeroRatio), address(baseAgg), 1 hours);

        int256 answer = oracleZero.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestAnswerWithRevertingRatioAggregator() public {
        MockAggregatorRevertLatestRoundData revertRatio = new MockAggregatorRevertLatestRoundData(18);
        RatioOracleAggregator oracleRevert = new RatioOracleAggregator(address(revertRatio), address(baseAgg), 1 hours);
        int256 answer = oracleRevert.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestAnswerWithRevertingBaseAggregator() public {
        MockAggregatorRevertLatestRoundData revertBase = new MockAggregatorRevertLatestRoundData(8);
        RatioOracleAggregator oracleRevert = new RatioOracleAggregator(address(ratioAgg), address(revertBase), 1 hours);
        int256 answer = oracleRevert.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestAnswerReturnsZeroOnMulDivOverflow() public {
        MockAggregator ratioAggLarge = new MockAggregator(int256(1) << 200, 18);
        MockAggregator baseAggLarge = new MockAggregator(int256(1) << 200, 8);
        RatioOracleAggregator oracleLarge =
            new RatioOracleAggregator(address(ratioAggLarge), address(baseAggLarge), 1 hours);

        int256 answer = oracleLarge.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestAnswerReturnsZeroOnInt256Overflow() public {
        MockAggregator ratioAggLarge = new MockAggregator(int256(1) << 200, 18);
        MockAggregator baseAggLarge = new MockAggregator(int256(1) << 115, 8);
        RatioOracleAggregator oracleLarge =
            new RatioOracleAggregator(address(ratioAggLarge), address(baseAggLarge), 1 hours);

        int256 answer = oracleLarge.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestTimestamp() public view {
        uint256 timestamp = oracle.latestTimestamp();
        assertEq(timestamp, block.timestamp);
    }

    function testLatestRound() public view {
        uint256 round = oracle.latestRound();
        assertEq(round, 1);
    }

    function testGetAnswer() public view {
        int256 answer = oracle.getAnswer(1);
        assertEq(answer, 2100e8);
    }

    function testGetAnswerStaleRound() public {
        ratioAgg.setAnswer(1.1e18);
        int256 answer = oracle.getAnswer(1);
        assertEq(answer, 0);
    }

    function testGetAnswerReverts() public {
        baseAgg.setAnswer(-1000e8);
        int256 answer = oracle.getAnswer(1);
        assertEq(answer, 0);
    }

    function testGetAnswerWithRevertingRatioAggregator() public {
        MockAggregatorRevertLatestRoundData revertRatio = new MockAggregatorRevertLatestRoundData(18);
        RatioOracleAggregator oracleRevert = new RatioOracleAggregator(address(revertRatio), address(baseAgg), 1 hours);
        int256 answer = oracleRevert.getAnswer(1);
        assertEq(answer, 0);
    }

    function testGetTimestamp() public view {
        uint256 timestamp = oracle.getTimestamp(1);
        assertEq(timestamp, block.timestamp);
    }

    function testGetTimestampStaleRound() public {
        ratioAgg.setAnswer(1.1e18);
        uint256 timestamp = oracle.getTimestamp(1);
        assertEq(timestamp, 0);
    }

    function testGetTimestampReverts() public {
        ratioAgg.setTimestamp(0);
        uint256 timestamp = oracle.getTimestamp(1);
        assertEq(timestamp, 0);
    }

    function testGetTimestampWithRevertingRatioAggregator() public {
        MockAggregatorRevertLatestRoundData revertRatio = new MockAggregatorRevertLatestRoundData(18);
        RatioOracleAggregator oracleRevert = new RatioOracleAggregator(address(revertRatio), address(baseAgg), 1 hours);
        uint256 timestamp = oracleRevert.getTimestamp(1);
        assertEq(timestamp, 0);
    }

    function testGetTimestampWithIncompleteRound() public view {
        uint256 timestamp = oracle.getTimestamp(999);
        assertEq(timestamp, 0);
    }

    function testDescription() public view {
        string memory desc = oracle.description();
        assertEq(desc, "Mock Aggregator * Mock Aggregator");
    }

    function testVersion() public view {
        assertEq(oracle.version(), 1);
    }

    function testDecimalScaling() public {
        MockAggregator ratio6 = new MockAggregator(1.05e6, 6);
        MockAggregator base18 = new MockAggregator(2000e18, 18);
        RatioOracleAggregator oracle6_18 = new RatioOracleAggregator(address(ratio6), address(base18), 1 hours);

        (, int256 answer,,,) = oracle6_18.latestRoundData();
        assertEq(answer, 2100e8);
    }

    function testNoMaxDelay() public {
        RatioOracleAggregator oracleNoDelay = new RatioOracleAggregator(address(ratioAgg), address(baseAgg), 0);

        vm.warp(block.timestamp + 365 days);
        (, int256 answer,,,) = oracleNoDelay.latestRoundData();
        assertEq(answer, 2100e8);
    }

    function testMinimumTimestampUpdated() public {
        baseAgg.setAnswer(1500e8);
        vm.warp(block.timestamp + 10);
        ratioAgg.setAnswer(1.1e18);

        (,,, uint256 updatedAt,) = oracle.latestRoundData();
        assertEq(updatedAt, block.timestamp - 10);
    }

    function testLatestTimestampReturnsRatioTimestampWhenOlder() public {
        uint256 baseTimestamp = block.timestamp + 200;
        ratioAgg.setTimestamp(baseTimestamp - 100);
        baseAgg.setTimestamp(baseTimestamp - 10);
        vm.warp(baseTimestamp);

        uint256 timestamp = oracle.latestTimestamp();
        assertEq(timestamp, baseTimestamp - 100);
    }

    function testLatestRoundDataIgnoresRatioAnsweredInRound() public {
        ratioAgg.setAnsweredInRound(0);
        (, int256 answer,,,) = oracle.latestRoundData();
        assertEq(answer, 2100e8);
    }

    function testLatestRoundDataIgnoresBaseAnsweredInRound() public {
        baseAgg.setAnsweredInRound(0);
        (, int256 answer,,,) = oracle.latestRoundData();
        assertEq(answer, 2100e8);
    }

    function testLatestRoundDataRevertsOnZeroRoundId() public {
        MockAggregatorZeroRound zeroRatio = new MockAggregatorZeroRound(1.05e18, 18);
        RatioOracleAggregator oracleZero = new RatioOracleAggregator(address(zeroRatio), address(baseAgg), 1 hours);

        vm.expectRevert();
        oracleZero.latestRoundData();
    }

    function testLatestRoundDataZeroTimestampRatio() public {
        ratioAgg.setTimestamp(0);
        vm.expectRevert();
        oracle.latestRoundData();
    }

    function testLatestRoundDataZeroTimestampBase() public {
        baseAgg.setTimestamp(0);
        vm.expectRevert();
        oracle.latestRoundData();
    }

    function testLatestAnswerReturnsZeroOnFutureTimestamp() public {
        ratioAgg.setTimestamp(block.timestamp + 1);
        int256 answer = oracle.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestRoundDataRevertsOnFutureTimestampRatio() public {
        ratioAgg.setTimestamp(block.timestamp + 1);
        vm.expectRevert();
        oracle.latestRoundData();
    }

    function testLatestRoundDataRevertsOnFutureTimestampBase() public {
        baseAgg.setTimestamp(block.timestamp + 1);
        vm.expectRevert();
        oracle.latestRoundData();
    }
}
