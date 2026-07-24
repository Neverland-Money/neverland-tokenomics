// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/**
 * @title MockChainlinkAggregator
 * @notice Minimal Chainlink-style AggregatorV3 mock used in Tenderly/ fork
 *         rehearsals to refresh stale feeds or simulate bad oracle states.
 *
 *         NOT FOR PRODUCTION USE.
 */
contract MockChainlinkAggregator {
    error NoDataPresent();

    int256 public answer;
    uint80 public roundId;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound;
    uint8 public override_decimals;
    string private _description;

    constructor(int256 answer_, uint8 decimals_, string memory description_) {
        configureMetadata(decimals_, description_);
        answer = answer_;
        roundId = 1;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        answeredInRound = 1;
    }

    function configureMetadata(uint8 decimals_, string memory description_) public {
        override_decimals = decimals_;
        _description = description_;
    }

    function set(int256 answer_, uint80 roundId_, uint256 startedAt_, uint256 updatedAt_, uint80 answeredInRound_)
        external
    {
        answer = answer_;
        roundId = roundId_;
        startedAt = startedAt_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }

    function setStale(uint256 secondsInPast) external {
        updatedAt = block.timestamp - secondsInPast;
        startedAt = updatedAt;
    }

    function setFuture(uint256 secondsInFuture) external {
        updatedAt = block.timestamp + secondsInFuture;
    }

    function setAnswer(int256 answer_) external {
        answer = answer_;
    }

    function decimals() external view returns (uint8) {
        return override_decimals;
    }

    function description() external view returns (string memory) {
        return _description;
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function latestRoundData()
        external
        view
        returns (uint80 _roundId, int256 _answer, uint256 _startedAt, uint256 _updatedAt, uint80 _answeredInRound)
    {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function getRoundData(uint80 requestedRoundId)
        external
        view
        returns (uint80 _roundId, int256 _answer, uint256 _startedAt, uint256 _updatedAt, uint80 _answeredInRound)
    {
        if (requestedRoundId != roundId) {
            revert NoDataPresent();
        }

        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function latestAnswer() external view returns (int256) {
        return answer;
    }

    function latestTimestamp() external view returns (uint256) {
        return updatedAt;
    }
}
