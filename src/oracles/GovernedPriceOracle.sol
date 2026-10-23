// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IGovernedPriceOracle} from "../interfaces/IGovernedPriceOracle.sol";

import {CommonChecksLibrary} from "../libraries/CommonChecksLibrary.sol";
import {OracleLib} from "../libraries/OracleLib.sol";

/**
 * @title GovernedPriceOracle
 * @author Neverland
 * @notice Owner-governed, non-upgradeable Chainlink/Aave-compatible feed reporting one posted USD price
 * @dev The price is a governance input, not market data: the owner (the Governance Safe in production) posts it
 *      at the 8-decimal TARGET_DECIMALS scale (e.g. `$1.00` is `100000000`). Latest/Aave-facing reads
 *      serve the last posted answer without a staleness gate; freshness is a governance duty, monitored
 *      off-chain. Each post, including a same-value re-attestation, increments the round ID, stamps
 *      `updatedAt`, and emits canonical Chainlink events plus `PriceUpdated`. Zero and beyond-int256
 *      prices are rejected at construction and on every update, so a live feed always reports a strictly
 *      positive answer. No upgrade path; replacing behavior means deploying a new oracle and re-pointing
 *      the consumer.
 */
contract GovernedPriceOracle is IGovernedPriceOracle, Ownable2Step {
    /**
     * @notice Sets the initial price and description reported by the feed
     * @dev Reverts with InvalidPrice when `answer` is zero or beyond the int256 range. The deployer
     *      becomes the initial owner; hand off to the Governance Safe via the two-step transfer.
     * @param answer The initial price at 8 decimals (e.g. 100000000 for $1.00)
     * @param _description Human-readable feed description (e.g. "USDe / USD")
     */
    constructor(uint256 answer, string memory _description) {
        if (answer == 0 || answer > uint256(type(int256).max)) revert InvalidPrice();

        _answer = int256(answer);
        _roundId = 1;
        _updatedAt = block.timestamp;

        description = _description;

        _emitPriceUpdate(0);
    }

    /*//////////////////////////////////////////////////////////////
                          MUTABLE STATE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGovernedPriceOracle
    string public description;

    /// @dev The last posted price answer in TARGET_DECIMALS (8-decimal) USD scale; always positive
    int256 private _answer;

    /// @dev Post counter reported as the round ID; starts at 1 and increments on every post
    uint80 private _roundId;

    /// @dev Timestamp of the latest post
    uint256 private _updatedAt;

    /*//////////////////////////////////////////////////////////////
                              ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGovernedPriceOracle
    function setPrice(uint256 newAnswer) external onlyOwner {
        // The posted price must stay strictly positive and within the int256 answer range.
        if (newAnswer == 0 || newAnswer > uint256(type(int256).max)) revert InvalidPrice();

        int256 previous = _answer;
        _answer = int256(newAnswer);
        ++_roundId;
        _updatedAt = block.timestamp;

        _emitPriceUpdate(previous);
    }

    /// @inheritdoc IGovernedPriceOracle
    function renounceOwnership() public view override(IGovernedPriceOracle, Ownable) onlyOwner {
        revert OwnershipRequired();
    }

    /*//////////////////////////////////////////////////////////////
                        LEGACY AGGREGATOR
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGovernedPriceOracle
    function latestAnswer() external view returns (int256) {
        return _answer;
    }

    /// @inheritdoc IGovernedPriceOracle
    function latestTimestamp() external view returns (uint256) {
        return _updatedAt;
    }

    /// @inheritdoc IGovernedPriceOracle
    function latestRound() external view returns (uint256) {
        return _roundId;
    }

    /// @inheritdoc IGovernedPriceOracle
    function getAnswer(uint256 roundId) external view returns (int256) {
        return roundId == _roundId ? _answer : int256(0);
    }

    /// @inheritdoc IGovernedPriceOracle
    function getTimestamp(uint256 roundId) external view returns (uint256) {
        return roundId == _roundId ? _updatedAt : 0;
    }

    /*//////////////////////////////////////////////////////////////
                       CHAINLINK V3 INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGovernedPriceOracle
    function decimals() external pure returns (uint8) {
        return uint8(OracleLib.TARGET_DECIMALS);
    }

    /// @inheritdoc IGovernedPriceOracle
    function version() external pure returns (uint256) {
        return 1;
    }

    /// @inheritdoc IGovernedPriceOracle
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return _roundData();
    }

    /// @inheritdoc IGovernedPriceOracle
    function getRoundData(uint80 requestedRoundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        // Historical rounds are not stored; only the latest round is returned.
        if (requestedRoundId != _roundId) revert CommonChecksLibrary.StaleRound();

        return _roundData();
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emits the complete monitoring event sequence for the current post
     * @param previousAnswer The answer from the preceding round, or zero during construction
     */
    function _emitPriceUpdate(int256 previousAnswer) private {
        emit NewRound(_roundId, msg.sender, _updatedAt);
        emit AnswerUpdated(_answer, _roundId, _updatedAt);
        emit PriceUpdated(previousAnswer, _answer);
    }

    /**
     * @notice Builds the latest round tuple
     * @dev Round metadata is honest: `roundId == answeredInRound` is the post counter and
     *      `startedAt == updatedAt` is the timestamp of the latest post.
     * @return roundId The current round ID
     * @return answer The posted price answer
     * @return startedAt The timestamp of the latest post
     * @return updatedAt The timestamp of the latest post
     * @return answeredInRound The current round ID
     */
    function _roundData()
        private
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }
}
