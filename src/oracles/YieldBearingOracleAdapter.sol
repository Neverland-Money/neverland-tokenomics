// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {CommonChecksLibrary} from "../libraries/CommonChecksLibrary.sol";
import {OracleLib} from "../libraries/OracleLib.sol";

import {IYieldBearingOracleAdapter} from "../interfaces/IYieldBearingOracleAdapter.sol";

/**
 * @title YieldBearingOracleAdapter
 * @author Neverland
 * @notice Oracle adapter for yield-bearing assets with growth rate limiting
 * @dev Intended for L1 deployments (e.g., Monad). If used on an L2 rollup, integrate an
 *      L2 Sequencer Uptime Feed + grace period guard externally or via a sequencer-aware adapter.
 */
contract YieldBearingOracleAdapter is IYieldBearingOracleAdapter, Ownable2Step {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 private constant BPS_DENOMINATOR = 10000;
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant PRECISION_SCALE = 1e18;

    /*//////////////////////////////////////////////////////////////
                          IMMUTABLE STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The base price aggregator (e.g., MON/USD for sMON)
    AggregatorV3Interface public immutable baseAggregator;

    /// @notice The ERC4626 shares contract for the yield-bearing asset
    IERC4626 public immutable sharesContract;

    /// @notice Maximum allowed staleness for price data in seconds
    uint256 public immutable maxDelay;

    /// @notice Number of decimals used by the base aggregator
    uint8 public immutable baseDecimals;

    /// @notice Number of decimals used by the shares contract
    uint8 public immutable sharesDecimals;

    /// @notice Number of decimals used by the underlying asset
    uint8 public immutable assetDecimals;

    /// @notice Unit value for shares based on sharesDecimals (10^sharesDecimals)
    uint256 private immutable shareUnit;

    /// @notice Unit value for assets based on assetDecimals (10^assetDecimals)
    uint256 private immutable assetUnit;

    /// @notice Minimum delay required between snapshot updates
    uint48 public immutable minimumSnapshotDelay;

    /// @notice Snapshot age threshold used for monitoring staleness
    uint48 public immutable maximumSnapshotAge;

    /*//////////////////////////////////////////////////////////////
                          MUTABLE STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Human-readable description of the oracle
    string public description;

    /// @notice Address authorized to update snapshots (in addition to owner)
    address public keeper;

    // @notice Current snapshot ratio (assets per shareUnit, in asset decimals)
    uint104 private _snapshotRatio;
    // @notice Timestamp when the snapshot became effective
    uint48 private _snapshotTimestamp;
    // @notice Growth rate per second (scaled by PRECISION_SCALE)
    uint104 private _growthRatePerSecond;
    // @notice Maximum annual growth rate in basis points
    uint16 private _maxAnnualGrowthBps;

    /// @notice Pending snapshot waiting for timelock
    uint104 private _pendingSnapshotRatio;
    /// @notice Timestamp when the pending snapshot will become effective
    uint48 private _pendingSnapshotEffectiveAt;
    /// @notice Rejection grace in bps beyond hard cap; accepted values are clamped to hard cap for pricing
    uint16 private _rejectionGraceBps;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the yield-bearing oracle adapter
     * @param _baseAggregator The base price aggregator address
     * @param _sharesContract The ERC4626 shares contract address
     * @param _maxDelay Maximum staleness delay for price data in seconds
     * @param _minimumSnapshotDelay Minimum delay between snapshot updates
     * @param _maximumSnapshotAge Snapshot staleness threshold used for monitoring
     * @param _initialRejectionGraceBps Initial rejection grace in basis points
     * @param _description Human-readable description of the oracle
     */
    constructor(
        address _baseAggregator,
        address _sharesContract,
        uint256 _maxDelay,
        uint48 _minimumSnapshotDelay,
        uint48 _maximumSnapshotAge,
        uint16 _initialRejectionGraceBps,
        string memory _description
    ) {
        if (_baseAggregator == address(0) || _sharesContract == address(0)) {
            revert CommonChecksLibrary.AddressZero();
        }

        baseAggregator = AggregatorV3Interface(_baseAggregator);
        sharesContract = IERC4626(_sharesContract);
        maxDelay = _maxDelay;
        minimumSnapshotDelay = _minimumSnapshotDelay;
        maximumSnapshotAge = _maximumSnapshotAge;

        if (_maximumSnapshotAge == 0) revert InvalidGrowthRate();
        if (_minimumSnapshotDelay >= _maximumSnapshotAge) revert InvalidGrowthRate();

        baseDecimals = baseAggregator.decimals();
        if (baseDecimals < OracleLib.MIN_DECIMALS || baseDecimals > OracleLib.MAX_DECIMALS) {
            revert CommonChecksLibrary.InvalidDecimals();
        }

        sharesDecimals = sharesContract.decimals();
        if (sharesDecimals < OracleLib.MIN_DECIMALS || sharesDecimals > OracleLib.MAX_DECIMALS) {
            revert CommonChecksLibrary.InvalidDecimals();
        }

        shareUnit = OracleLib.DECIMAL_BASE ** uint256(sharesDecimals);

        address asset = sharesContract.asset();
        if (asset == address(0)) revert CommonChecksLibrary.AddressZero();

        assetDecimals = IERC20Metadata(asset).decimals();
        if (assetDecimals < OracleLib.MIN_DECIMALS || assetDecimals > OracleLib.MAX_DECIMALS) {
            revert CommonChecksLibrary.InvalidDecimals();
        }

        assetUnit = OracleLib.DECIMAL_BASE ** uint256(assetDecimals);

        if (_initialRejectionGraceBps > BPS_DENOMINATOR) revert InvalidRejectionGrace();
        _rejectionGraceBps = _initialRejectionGraceBps;

        description = _description;
    }

    /*//////////////////////////////////////////////////////////////
                      CHAINLINK INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYieldBearingOracleAdapter
    function latestAnswer() external view returns (int256) {
        (bool ok,, int256 answer,) = _tryLatestData();
        return ok ? answer : int256(0);
    }

    /// @inheritdoc IYieldBearingOracleAdapter
    function latestTimestamp() external view returns (uint256) {
        (bool ok,,, uint256 timestamp) = _tryLatestData();
        return ok ? timestamp : 0;
    }

    /// @inheritdoc IYieldBearingOracleAdapter
    function latestRound() external view returns (uint256) {
        (bool ok, uint80 roundId,,) = _tryLatestData();
        return ok ? uint256(roundId) : 0;
    }

    /// @inheritdoc IYieldBearingOracleAdapter
    function getAnswer(uint256 roundId) external view returns (int256) {
        if (roundId > type(uint80).max) return 0;
        (bool ok, uint80 latestRoundId, int256 answer,) = _tryLatestData();
        if (!ok || roundId != uint256(latestRoundId)) return 0;
        return answer;
    }

    /// @inheritdoc IYieldBearingOracleAdapter
    function getTimestamp(uint256 roundId) external view returns (uint256) {
        if (roundId > type(uint80).max) return 0;
        (bool ok, uint80 latestRoundId,, uint256 timestamp) = _tryLatestData();
        if (!ok || roundId != uint256(latestRoundId)) return 0;
        return timestamp;
    }

    /// @inheritdoc AggregatorV3Interface
    function decimals() external pure returns (uint8) {
        return uint8(OracleLib.TARGET_DECIMALS);
    }

    /// @inheritdoc AggregatorV3Interface
    function version() external pure returns (uint256) {
        return 1;
    }

    /// @inheritdoc AggregatorV3Interface
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) = baseAggregator.latestRoundData();
        _validateRound(answer, updatedAt);
        _validateRoundMetadata(roundId, startedAt, updatedAt, answeredInRound);
        answer = _computeSharesPrice(answer);
    }

    /// @inheritdoc AggregatorV3Interface
    function getRoundData(uint80 requestedRoundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        // Historical rounds are not supported; only the latest round is returned.
        (roundId, answer, startedAt, updatedAt, answeredInRound) = this.latestRoundData();
        if (requestedRoundId != roundId) revert CommonChecksLibrary.StaleRound();
    }

    /*//////////////////////////////////////////////////////////////
                      GROWTH CAP MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYieldBearingOracleAdapter
    function setGrowthCapBounds(uint16 maxAnnualGrowthBps) external onlyOwner {
        if (maxAnnualGrowthBps == 0 || maxAnnualGrowthBps > BPS_DENOMINATOR) revert InvalidGrowthRate();

        _rolloverEffectiveSnapshot();
        _maxAnnualGrowthBps = maxAnnualGrowthBps;

        if (_snapshotRatio > 0) {
            (uint104 growthRate, bool ok) = _tryComputeGrowthRate(_snapshotRatio, maxAnnualGrowthBps);
            if (!ok) revert InvalidGrowthRate();
            _growthRatePerSecond = growthRate;

            emit GrowthCapBoundsUpdated(maxAnnualGrowthBps, growthRate);
        } else {
            emit GrowthCapBoundsUpdated(maxAnnualGrowthBps, 0);
        }

        if (_pendingSnapshotEffectiveAt != 0) {
            // Validate queued snapshot fits new bounds to avoid overflow at activation.
            (, bool ok) = _tryComputeGrowthRate(_pendingSnapshotRatio, maxAnnualGrowthBps);
            if (!ok) revert InvalidGrowthRate();
        }
    }

    /// @inheritdoc IYieldBearingOracleAdapter
    function setRejectionGraceBps(uint16 rejectionGraceBps) external onlyOwner {
        if (rejectionGraceBps > BPS_DENOMINATOR) revert InvalidRejectionGrace();

        uint16 previous = _rejectionGraceBps;
        _rejectionGraceBps = rejectionGraceBps;

        emit RejectionGraceUpdated(previous, rejectionGraceBps);
    }

    /// @inheritdoc IYieldBearingOracleAdapter
    function updateSnapshot() external {
        if (msg.sender != owner() && msg.sender != keeper) revert CommonChecksLibrary.UnauthorizedAccess();
        if (_maxAnnualGrowthBps == 0) revert InvalidGrowthRate();

        // Reconcile any time-effective pending snapshot before queuing a new one.
        _rolloverEffectiveSnapshot();

        uint256 currentRatio = sharesContract.convertToAssets(shareUnit);
        if (currentRatio == 0) revert InvalidSnapshotRatio();
        if (currentRatio > type(uint104).max) revert InvalidSnapshotRatio();

        (, bool ok) = _tryComputeGrowthRate(currentRatio, _maxAnnualGrowthBps);
        if (!ok) revert InvalidGrowthRate();

        // First snapshot is effective immediately; later snapshots honor the delay (or none if set to zero).
        bool immediate = _snapshotRatio == 0 && _pendingSnapshotEffectiveAt == 0;
        uint256 effectiveAtTimestamp = immediate ? block.timestamp : block.timestamp + minimumSnapshotDelay;
        // Guarded narrowing conversion: revert instead of truncating far-future timestamps.
        uint48 effectiveAt = _toUint48Timestamp(effectiveAtTimestamp);

        _pendingSnapshotRatio = uint104(currentRatio);
        _pendingSnapshotEffectiveAt = effectiveAt;

        emit SnapshotQueued(uint104(currentRatio), effectiveAt);

        if (immediate) _rolloverEffectiveSnapshot();
    }

    /// @inheritdoc IYieldBearingOracleAdapter
    function updateSnapshotImmediate() external onlyOwner {
        if (_maxAnnualGrowthBps == 0) revert InvalidGrowthRate();

        _rolloverEffectiveSnapshot();

        uint256 currentRatio = sharesContract.convertToAssets(shareUnit);
        if (currentRatio == 0) revert InvalidSnapshotRatio();
        if (currentRatio > type(uint104).max) revert InvalidSnapshotRatio();

        (, bool ok) = _tryComputeGrowthRate(currentRatio, _maxAnnualGrowthBps);
        if (!ok) revert InvalidGrowthRate();

        _pendingSnapshotRatio = uint104(currentRatio);
        // Guarded narrowing conversion: revert instead of truncating far-future timestamps.
        _pendingSnapshotEffectiveAt = _toUint48Timestamp(block.timestamp);

        emit SnapshotQueued(uint104(currentRatio), _pendingSnapshotEffectiveAt);
        _rolloverEffectiveSnapshot();
    }

    /// @inheritdoc IYieldBearingOracleAdapter
    function isCapped() external view returns (bool) {
        if (!_hasEffectiveSnapshot()) return false;

        try sharesContract.convertToAssets(shareUnit) returns (uint256 currentRatio) {
            uint256 maxAllowedRatio = _calculateMaxRatio();
            if (maxAllowedRatio == 0) return false;

            return currentRatio > maxAllowedRatio;
        } catch {
            return false;
        }
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYieldBearingOracleAdapter
    function getSnapshotRatio() external view returns (uint256) {
        // Time-effective pending snapshots are treated as active for reads.
        if (_isPendingEffective()) {
            return _pendingSnapshotRatio;
        }
        return _snapshotRatio;
    }

    /// @inheritdoc IYieldBearingOracleAdapter
    function getSnapshotTimestamp() external view returns (uint256) {
        if (_isPendingEffective()) {
            return _pendingSnapshotEffectiveAt;
        }
        return _snapshotTimestamp;
    }

    /// @inheritdoc IYieldBearingOracleAdapter
    function getMaxAnnualGrowthBps() external view returns (uint256) {
        return _maxAnnualGrowthBps;
    }

    /// @inheritdoc IYieldBearingOracleAdapter
    function getGrowthRatePerSecond() external view returns (uint256) {
        if (_isPendingEffective()) {
            (uint104 pendingRate, bool ok) = _tryComputeGrowthRate(_pendingSnapshotRatio, _maxAnnualGrowthBps);
            if (ok) return pendingRate;
        }
        return _growthRatePerSecond;
    }

    /// @inheritdoc IYieldBearingOracleAdapter
    function getRejectionGraceBps() external view returns (uint256) {
        return _rejectionGraceBps;
    }

    /// @inheritdoc IYieldBearingOracleAdapter
    function getCurrentSlackBps() external view returns (uint256 slackBps, bool ok) {
        if (!_hasEffectiveSnapshot()) return (0, false);

        uint256 maxAllowedRatio = _calculateMaxRatio();
        if (maxAllowedRatio == 0) return (0, false);

        try sharesContract.convertToAssets(shareUnit) returns (uint256 currentRatio) {
            if (currentRatio == 0) return (0, false);
            if (currentRatio >= maxAllowedRatio) return (0, true);

            // denominator=maxAllowedRatio>0 (checked above), x=(maxAllowedRatio-currentRatio)<denominator,
            // y=BPS_DENOMINATOR (10_000). `ok` should always be true, but keep a defensive check.
            (uint256 slack, bool okSlack) =
                OracleLib.tryMulDiv(maxAllowedRatio - currentRatio, BPS_DENOMINATOR, maxAllowedRatio);
            if (!okSlack) return (0, false);
            return (slack, true);
        } catch {
            return (0, false);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Attempts to fetch the latest base round and compute a shares price without reverting
     * @dev Returns (false, 0, 0, 0) on any failure or invalid/stale data
     * @return ok True if the latest data was fetched and validated
     * @return roundId The base round ID used for the answer
     * @return answer The computed shares price scaled to target decimals
     * @return updatedAt The base round updatedAt timestamp
     */
    function _tryLatestData() internal view returns (bool ok, uint80 roundId, int256 answer, uint256 updatedAt) {
        try baseAggregator.latestRoundData() returns (
            uint80 baseRoundId,
            int256 basePrice,
            uint256 baseStartedAt,
            uint256 baseUpdatedAt,
            uint80 baseAnsweredInRound
        ) {
            if (!_isValidRound(basePrice, baseUpdatedAt)) return (false, 0, 0, 0);

            if (!_isValidRoundMetadata(baseRoundId, baseStartedAt, baseUpdatedAt, baseAnsweredInRound)) {
                return (false, 0, 0, 0);
            }

            int256 price = _computeSharesPriceSafe(basePrice);
            if (price == 0) return (false, 0, 0, 0);

            return (true, baseRoundId, price, baseUpdatedAt);
        } catch {
            return (false, 0, 0, 0);
        }
    }

    /**
     * @notice Computes the shares price with strict validation
     * @dev Reverts if safe computation returns 0, including when convertToAssets fails,
     *      returns 0, or when scaling/overflow bounds checks fail.
     * @param basePrice The base price from the base aggregator
     * @return sharesPrice The computed shares price scaled to target decimals
     */
    function _computeSharesPrice(int256 basePrice) internal view returns (int256 sharesPrice) {
        sharesPrice = _computeSharesPriceSafe(basePrice);
        if (sharesPrice == 0) revert InvalidSharesConversion();
    }

    /**
     * @notice Safely computes shares price with growth cap protection
     * @dev Returns 0 on failure instead of reverting. Applies growth cap if snapshot is set.
     * @param basePrice The base price from the base aggregator
     * @return sharesPrice The computed shares price scaled to target decimals, or 0 if computation fails
     */
    function _computeSharesPriceSafe(int256 basePrice) internal view returns (int256 sharesPrice) {
        try sharesContract.convertToAssets(shareUnit) returns (uint256 currentRatio) {
            if (currentRatio == 0) return 0;

            uint256 effectiveRatio = currentRatio;
            if (_hasEffectiveSnapshot()) {
                uint256 maxAllowedRatio = _calculateMaxRatio();
                if (maxAllowedRatio == 0) return 0;

                if (currentRatio > maxAllowedRatio) {
                    uint256 graceCapRatio = _calculateGraceCapRatio(maxAllowedRatio);
                    if (graceCapRatio == 0 || currentRatio > graceCapRatio) return 0;

                    // Keep liveness under short-lived drift while preventing any overpricing.
                    effectiveRatio = maxAllowedRatio;
                }
            }

            (uint256 rawSharesPrice, bool ok) = OracleLib.tryMulDiv(uint256(basePrice), effectiveRatio, assetUnit);
            if (!ok) return 0;

            (uint256 normalized, bool scaleOk) = OracleLib.tryScaleToTargetDecimals(rawSharesPrice, baseDecimals);
            if (!scaleOk || normalized > uint256(type(int256).max)) return 0;

            return int256(normalized);
        } catch {
            return 0;
        }
    }

    /**
     * @notice Calculates ratio rejection threshold including grace above hard cap
     * @dev Returns 0 on overflow.
     * @param maxAllowedRatio Hard cap ratio derived from snapshot and growth bounds
     * @return graceCapRatio Hard cap ratio expanded by rejection grace bps
     */
    function _calculateGraceCapRatio(uint256 maxAllowedRatio) internal view returns (uint256 graceCapRatio) {
        uint256 rejectionGraceBps = _rejectionGraceBps;
        if (rejectionGraceBps == 0) return maxAllowedRatio;

        (uint256 expanded, bool ok) =
            OracleLib.tryMulDiv(maxAllowedRatio, BPS_DENOMINATOR + rejectionGraceBps, BPS_DENOMINATOR);
        // `0` from this branch indicates overflow-safe failure, not a valid grace cap.
        if (!ok) return 0;

        return expanded;
    }

    /**
     * @notice Rolls any time-effective pending snapshot into active storage
     * @dev Called on write paths to ensure pending snapshots are activated when their time arrives
     */
    function _rolloverEffectiveSnapshot() internal {
        // Roll any time-effective pending snapshot into active storage on write paths.
        if (_pendingSnapshotEffectiveAt == 0) return;
        if (block.timestamp < _pendingSnapshotEffectiveAt) return;

        uint104 snapshotRatio = _pendingSnapshotRatio;
        uint48 snapshotTimestamp = _pendingSnapshotEffectiveAt;

        _snapshotRatio = snapshotRatio;
        _snapshotTimestamp = snapshotTimestamp;
        _growthRatePerSecond = _computeGrowthRate(snapshotRatio, _maxAnnualGrowthBps);
        _pendingSnapshotRatio = 0;
        _pendingSnapshotEffectiveAt = 0;

        emit SnapshotActivated(snapshotRatio, snapshotTimestamp);
    }

    /**
     * @notice Calculates the maximum allowed share ratio without mutating state
     * @dev Returns 0 if computation fails or no effective snapshot is available
     * @return maxRatio The maximum allowed share ratio considering growth rate limits
     */
    function _calculateMaxRatio() internal view returns (uint256 maxRatio) {
        if (!_hasEffectiveSnapshot()) return 0;

        uint256 snapshotRatio = _snapshotRatio;
        uint256 snapshotTimestamp = _snapshotTimestamp;
        uint256 growthRate = _growthRatePerSecond;

        if (_isPendingEffective()) {
            snapshotRatio = _pendingSnapshotRatio;
            snapshotTimestamp = _pendingSnapshotEffectiveAt;
            (uint104 pendingRate, bool ok) = _tryComputeGrowthRate(snapshotRatio, _maxAnnualGrowthBps);
            if (!ok) return 0;

            growthRate = pendingRate;
        }

        if (snapshotTimestamp > block.timestamp) return 0;
        uint256 timeElapsed = block.timestamp - snapshotTimestamp;
        (uint256 allowedGrowth, bool okGrowth) = OracleLib.tryMulDiv(growthRate, timeElapsed, PRECISION_SCALE);
        if (!okGrowth) return 0;

        if (snapshotRatio > type(uint256).max - allowedGrowth) return 0;
        return snapshotRatio + allowedGrowth;
    }

    /**
     * @notice Checks if there is an effective snapshot (active or pending)
     * @return hasSnapshot True if there is an effective snapshot, false otherwise
     */
    function _hasEffectiveSnapshot() internal view returns (bool hasSnapshot) {
        // Effective if active snapshot exists or a pending snapshot has passed effectiveAt.
        if (_maxAnnualGrowthBps == 0) return false;
        if (_snapshotRatio > 0) return true;
        return _isPendingEffective();
    }

    /**
     * @notice Checks whether a pending snapshot is time-effective
     * @return pendingEffective True if a pending snapshot exists and its effective time has passed
     */
    function _isPendingEffective() internal view returns (bool pendingEffective) {
        return _pendingSnapshotEffectiveAt != 0 && block.timestamp >= _pendingSnapshotEffectiveAt;
    }

    /**
     * @notice Computes the per-second growth rate without reverting
     * @dev Returns (0, false) if the growth rate would overflow uint104
     * @param snapshotRatio The snapshot ratio used for growth calculations
     * @param maxAnnualGrowthBps The maximum annual growth in basis points
     * @return growthRate The computed growth rate per second
     * @return ok True if the growth rate fits in uint104
     */
    function _tryComputeGrowthRate(uint256 snapshotRatio, uint16 maxAnnualGrowthBps)
        internal
        pure
        returns (uint104 growthRate, bool ok)
    {
        uint256 growthRateDenominator = BPS_DENOMINATOR * SECONDS_PER_YEAR;
        uint256 growthRateCalculation = (snapshotRatio * maxAnnualGrowthBps * PRECISION_SCALE) / growthRateDenominator;
        if (growthRateCalculation > type(uint104).max) return (0, false);
        return (uint104(growthRateCalculation), true);
    }

    /**
     * @notice Computes the per-second growth rate with strict validation
     * @dev Reverts if the computed growth rate would overflow uint104
     * @param snapshotRatio The snapshot ratio used for growth calculations
     * @param maxAnnualGrowthBps The maximum annual growth in basis points
     * @return growthRate The computed growth rate per second
     */
    function _computeGrowthRate(uint256 snapshotRatio, uint16 maxAnnualGrowthBps)
        internal
        pure
        returns (uint104 growthRate)
    {
        uint256 growthRateDenominator = BPS_DENOMINATOR * SECONDS_PER_YEAR;
        uint256 growthRateCalculation = (snapshotRatio * maxAnnualGrowthBps * PRECISION_SCALE) / growthRateDenominator;
        if (growthRateCalculation > type(uint104).max) revert InvalidGrowthRate();
        return uint104(growthRateCalculation);
    }

    /**
     * @notice Safely converts a timestamp to uint48 storage width
     * @dev Reverts instead of silently truncating if timestamp does not fit in uint48.
     *      uint48 max timestamp is 2^48-1 seconds from Unix epoch (~8.9 million years).
     * @param timestamp The timestamp to cast
     * @return value The timestamp as uint48
     */
    function _toUint48Timestamp(uint256 timestamp) internal pure returns (uint48 value) {
        if (timestamp > type(uint48).max) revert InvalidSnapshotTimestamp();
        return uint48(timestamp);
    }

    /**
     * @notice Validates oracle round data with strict checks
     * @dev Reverts if answer is invalid or data is too old
     * @param answer The price answer from the oracle
     * @param updatedAt Timestamp when the round was last updated
     */
    function _validateRound(int256 answer, uint256 updatedAt) internal view {
        if (answer <= 0) revert CommonChecksLibrary.InvalidBasePrice();

        _validateFreshness(updatedAt);
    }

    /**
     * @notice Validates additional round metadata checks with strict behavior
     * @dev Reverts on inconsistent round metadata.
     * @param roundId The round ID returned by the aggregator
     * @param startedAt Timestamp when the round started
     * @param updatedAt Timestamp when the round was last updated
     * @param answeredInRound Round ID in which the answer was computed
     */
    function _validateRoundMetadata(uint80 roundId, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
        internal
        pure
    {
        if (roundId == 0) revert CommonChecksLibrary.StaleRound();
        if (startedAt > updatedAt) revert CommonChecksLibrary.StaleRound();
        if (answeredInRound != 0 && answeredInRound < roundId) revert CommonChecksLibrary.StaleRound();
    }

    /**
     * @notice Checks if oracle round data is valid without reverting
     * @dev Returns false instead of reverting, used for lenient validation in latestAnswer()
     * @param answer The price answer from the oracle
     * @param updatedAt Timestamp when the round was last updated
     * @return isValid True if the round is valid and fresh, false otherwise
     */
    function _isValidRound(int256 answer, uint256 updatedAt) internal view returns (bool isValid) {
        if (answer <= 0) return false;

        return _isFresh(updatedAt);
    }

    /**
     * @notice Checks if additional round metadata is valid without reverting
     * @dev Mirrors strict metadata checks but returns false on invalid data.
     * @param roundId The round ID returned by the aggregator
     * @param startedAt Timestamp when the round started
     * @param updatedAt Timestamp when the round was last updated
     * @param answeredInRound Round ID in which the answer was computed
     * @return isValid True if metadata is consistent
     */
    function _isValidRoundMetadata(uint80 roundId, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
        internal
        pure
        returns (bool isValid)
    {
        if (roundId == 0) return false;
        if (startedAt > updatedAt) return false;
        if (answeredInRound != 0 && answeredInRound < roundId) return false;

        return true;
    }

    /**
     * @notice Validates that oracle data is fresh based on maxDelay
     * @dev Reverts if data is too old according to configured maxDelay
     * @param updatedAt Timestamp when the data was last updated
     */
    function _validateFreshness(uint256 updatedAt) internal view {
        if (updatedAt == 0 || updatedAt > block.timestamp) revert CommonChecksLibrary.StaleRound();
        if (maxDelay > 0 && block.timestamp - updatedAt > maxDelay) {
            revert CommonChecksLibrary.PriceTooOld(block.timestamp, updatedAt, updatedAt + maxDelay);
        }
    }

    /**
     * @notice Checks if oracle data is fresh based on maxDelay
     * @dev Returns true if maxDelay is 0 (no staleness check) or data is within maxDelay
     * @param updatedAt Timestamp when the data was last updated
     * @return isFresh True if data is fresh, false otherwise
     */
    function _isFresh(uint256 updatedAt) internal view returns (bool isFresh) {
        if (updatedAt == 0 || updatedAt > block.timestamp) return false;
        if (maxDelay == 0) return true;

        return block.timestamp - updatedAt <= maxDelay;
    }

    /*//////////////////////////////////////////////////////////////
                            OWNERSHIP
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IYieldBearingOracleAdapter
    function setKeeper(address newKeeper) external onlyOwner {
        if (newKeeper == address(this)) revert InvalidKeeper();
        if (newKeeper == owner()) revert CommonChecksLibrary.SameAddress();

        // address(0) disables keeper updates.
        address previousKeeper = keeper;
        keeper = newKeeper;

        emit KeeperUpdated(previousKeeper, newKeeper);
    }

    /**
     * @notice Renouncing ownership is disabled to prevent accidental loss of control
     * @dev This override prevents the contract from being renounced
     */
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRequired();
    }
}
