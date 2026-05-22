// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {CommonChecksLibrary} from "../libraries/CommonChecksLibrary.sol";
import {OracleLib} from "../libraries/OracleLib.sol";

import {IRatioOracleAggregator} from "../interfaces/IRatioOracleAggregator.sol";

/**
 * @title RatioOracleAggregator
 * @author Neverland
 * @notice Aggregates ratio and base price feeds for yield-bearing assets
 * @dev Intended for L1 deployments (e.g., Monad). If used on an L2 rollup, integrate an
 *      L2 Sequencer Uptime Feed + grace period guard externally or via a sequencer-aware adapter.
 */
contract RatioOracleAggregator is IRatioOracleAggregator {
    /*//////////////////////////////////////////////////////////////
                          IMMUTABLE STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The ratio oracle (e.g., sMON/MON)
    AggregatorV3Interface public immutable ratioAggregator;

    /// @notice The base USD oracle (e.g., MON/USD)
    AggregatorV3Interface public immutable baseAggregator;

    /// @notice Maximum allowed staleness for price data in seconds
    uint256 public immutable maxDelay;

    /// @notice Number of decimals used by the ratio oracle
    uint8 public immutable ratioDecimals;

    /// @notice Number of decimals used by the base oracle
    uint8 public immutable baseDecimals;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the ratio oracle aggregator
     * @param _ratioAggregator Address of the ratio oracle (e.g., sMON/MON)
     * @param _baseAggregator Address of the base USD oracle (e.g., MON/USD)
     * @param _maxDelay Maximum staleness delay for price data in seconds (0 = no check)
     */
    constructor(address _ratioAggregator, address _baseAggregator, uint256 _maxDelay) {
        if (_ratioAggregator == address(0) || _baseAggregator == address(0)) revert CommonChecksLibrary.AddressZero();

        ratioAggregator = AggregatorV3Interface(_ratioAggregator);
        baseAggregator = AggregatorV3Interface(_baseAggregator);
        maxDelay = _maxDelay;
        ratioDecimals = ratioAggregator.decimals();
        baseDecimals = baseAggregator.decimals();

        if (
            ratioDecimals < OracleLib.MIN_DECIMALS || ratioDecimals > OracleLib.MAX_DECIMALS
                || baseDecimals < OracleLib.MIN_DECIMALS || baseDecimals > OracleLib.MAX_DECIMALS
        ) {
            revert CommonChecksLibrary.InvalidDecimals();
        }
    }

    /*//////////////////////////////////////////////////////////////
                      CHAINLINK V3 INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc AggregatorV3Interface
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) = ratioAggregator.latestRoundData();

        if (answer <= 0) revert InvalidRatio();

        _ensureComplete(roundId, updatedAt);
        (
            uint80 baseRoundId,
            int256 basePrice,
            uint256 baseStartedAt,
            uint256 baseUpdatedAt,
            uint80 _baseAnsweredInRound
        ) = baseAggregator.latestRoundData();
        // answeredInRound is informational only (Chainlink interface); report the minimum across feeds.
        if (_baseAnsweredInRound < answeredInRound) {
            answeredInRound = _baseAnsweredInRound;
        }

        if (basePrice <= 0) revert CommonChecksLibrary.InvalidBasePrice();

        _ensureComplete(baseRoundId, baseUpdatedAt);
        if (baseUpdatedAt < updatedAt) {
            updatedAt = baseUpdatedAt;
        }
        if (baseStartedAt < startedAt) {
            startedAt = baseStartedAt;
        }

        answer = _computePrice(answer, basePrice);
    }

    /// @inheritdoc AggregatorV3Interface
    function getRoundData(uint80 requestedRoundId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        // Historical rounds are not supported; only the latest round is returned.
        (roundId, answer, startedAt, updatedAt, answeredInRound) = this.latestRoundData();
        if (requestedRoundId != roundId) revert CommonChecksLibrary.StaleRound();
    }

    /// @inheritdoc AggregatorV3Interface
    function decimals() external pure override returns (uint8) {
        return uint8(OracleLib.TARGET_DECIMALS);
    }

    /// @inheritdoc AggregatorV3Interface
    function description() external view override returns (string memory) {
        return string.concat(ratioAggregator.description(), " * ", baseAggregator.description());
    }

    /// @inheritdoc AggregatorV3Interface
    function version() external pure override returns (uint256) {
        return 1;
    }

    /*//////////////////////////////////////////////////////////////
                      LEGACY INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRatioOracleAggregator
    function latestAnswer() external view override returns (int256) {
        (bool ok, int256 answer,,) = _tryLatestData();
        return ok ? answer : int256(0);
    }

    /// @inheritdoc IRatioOracleAggregator
    function latestTimestamp() external view override returns (uint256) {
        (bool ok,,, uint256 timestamp) = _tryLatestData();
        return ok ? timestamp : 0;
    }

    /// @inheritdoc IRatioOracleAggregator
    function latestRound() external view override returns (uint256) {
        (bool ok,, uint80 roundId,) = _tryLatestData();
        return ok ? uint256(roundId) : 0;
    }

    /// @inheritdoc IRatioOracleAggregator
    function getAnswer(uint256 roundId) external view override returns (int256) {
        (bool ok, int256 answer, uint80 latestRoundId,) = _tryLatestData();
        if (!ok || roundId != uint256(latestRoundId)) return 0;
        return answer;
    }

    /// @inheritdoc IRatioOracleAggregator
    function getTimestamp(uint256 roundId) external view override returns (uint256) {
        (bool ok,, uint80 latestRoundId, uint256 timestamp) = _tryLatestData();
        if (!ok || roundId != uint256(latestRoundId)) return 0;
        return timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Attempts to fetch the latest combined price without reverting
     * @dev Returns (false, 0, 0, 0) on any failure or invalid/stale data
     * @return ok True if the latest data was fetched and validated
     * @return answer The computed price scaled to target decimals
     * @return roundId The ratio round ID used for the answer
     * @return updatedAt The minimum updatedAt between ratio and base oracles
     */
    function _tryLatestData() internal view returns (bool ok, int256 answer, uint80 roundId, uint256 updatedAt) {
        try ratioAggregator.latestRoundData() returns (
            uint80 ratioRoundId,
            int256 ratio,
            uint256 ratioStartedAt,
            uint256 ratioUpdatedAt,
            uint80 ratioAnsweredInRound
        ) {
            if (ratio <= 0) return (false, 0, 0, 0);
            if (!_isComplete(ratioRoundId, ratioUpdatedAt)) return (false, 0, 0, 0);

            if (ratioStartedAt > ratioUpdatedAt) return (false, 0, 0, 0);
            if (ratioAnsweredInRound != 0 && ratioAnsweredInRound < ratioRoundId) return (false, 0, 0, 0);

            try baseAggregator.latestRoundData() returns (
                uint80 baseRoundId,
                int256 basePrice,
                uint256 baseStartedAt,
                uint256 baseUpdatedAt,
                uint80 baseAnsweredInRound
            ) {
                if (basePrice <= 0) return (false, 0, 0, 0);
                if (!_isComplete(baseRoundId, baseUpdatedAt)) return (false, 0, 0, 0);

                if (baseStartedAt > baseUpdatedAt) return (false, 0, 0, 0);
                if (baseAnsweredInRound != 0 && baseAnsweredInRound < baseRoundId) return (false, 0, 0, 0);

                int256 price = _computePriceSafe(ratio, basePrice);
                if (price == 0) return (false, 0, 0, 0);

                uint256 minUpdatedAt = ratioUpdatedAt < baseUpdatedAt ? ratioUpdatedAt : baseUpdatedAt;
                return (true, price, ratioRoundId, minUpdatedAt);
            } catch {
                return (false, 0, 0, 0);
            }
        } catch {
            return (false, 0, 0, 0);
        }
    }

    /**
     * @notice Validates that an oracle round is complete and not stale
     * @dev Reverts if the round is incomplete or data is too old based on maxDelay
     * @param roundId The round ID
     * @param updatedAt Timestamp when the round was last updated
     */
    function _ensureComplete(uint80 roundId, uint256 updatedAt) internal view {
        if (roundId == 0) revert CommonChecksLibrary.StaleRound();
        if (updatedAt == 0 || updatedAt > block.timestamp) revert CommonChecksLibrary.StaleRound();
        if (maxDelay > 0 && block.timestamp - updatedAt > maxDelay) {
            revert CommonChecksLibrary.PriceTooOld(block.timestamp, updatedAt, updatedAt + maxDelay);
        }
    }

    /**
     * @notice Checks if an oracle round is complete and not stale
     * @dev Returns false instead of reverting, used for lenient validation in latestAnswer()
     * @param roundId The round ID
     * @param updatedAt Timestamp when the round was last updated
     * @return isComplete True if the round is complete and fresh, false otherwise
     */
    function _isComplete(uint80 roundId, uint256 updatedAt) internal view returns (bool isComplete) {
        if (roundId == 0) return false;
        if (updatedAt == 0 || updatedAt > block.timestamp) return false;
        if (maxDelay > 0 && block.timestamp - updatedAt > maxDelay) return false;

        return true;
    }

    /**
     * @notice Computes the final price by multiplying ratio and base price with strict validation
     * @dev Uses safe math and reverts if computation fails (overflow or invalid result)
     * @param ratio The ratio value from the ratio aggregator
     * @param basePrice The base price from the base aggregator
     * @return price The computed price scaled to target decimals
     */
    function _computePrice(int256 ratio, int256 basePrice) internal view returns (int256 price) {
        price = _computePriceSafe(ratio, basePrice);
        if (price == 0) revert CommonChecksLibrary.InvalidBasePrice();
    }

    /**
     * @notice Safely computes price by multiplying ratio and base price without reverting
     * @dev Returns 0 on overflow or scaling errors instead of reverting, used for fallback compatibility
     * @param ratio The ratio value from the ratio aggregator
     * @param basePrice The base price from the base aggregator
     * @return price The computed price scaled to target decimals, or 0 if computation fails
     */
    function _computePriceSafe(int256 ratio, int256 basePrice) internal view returns (int256 price) {
        (uint256 scaled, bool ok) =
            OracleLib.tryMulDiv(uint256(ratio), uint256(basePrice), OracleLib.DECIMAL_BASE ** uint256(ratioDecimals));
        if (!ok) return 0;

        (uint256 normalized, bool scaleOk) = OracleLib.tryScaleToTargetDecimals(scaled, baseDecimals);
        if (!scaleOk || normalized > uint256(type(int256).max)) return 0;

        return int256(normalized);
    }
}
