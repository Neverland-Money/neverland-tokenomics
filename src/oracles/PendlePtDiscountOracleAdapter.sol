// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IPendlePrincipalToken} from "../interfaces/IPendlePrincipalToken.sol";
import {IPendlePtDiscountOracleAdapter} from "../interfaces/IPendlePtDiscountOracleAdapter.sol";

import {CommonChecksLibrary} from "../libraries/CommonChecksLibrary.sol";
import {OracleLib} from "../libraries/OracleLib.sol";

/**
 * @title PendlePtDiscountOracleAdapter
 * @author Neverland
 * @notice Deterministic USD price for a Pendle Principal Token (PT) used as money-market collateral.
 * @dev Prices the PT as its accounting asset's USD feed, linearly discounted to maturity:
 *
 *          discountWad = (discountRatePerYear * 1e14) * timeToMaturity / SECONDS_PER_YEAR   // 1e18 scale
 *          PT/USD      = baseAssetUSD * (WAD - discountWad) / WAD                           // then 8 decimals
 *
 *      The discount decays to zero at maturity, where the PT prices at par. The price is a pure function of
 *      `block.timestamp` and the base feed and never reads a Pendle AMM/TWAP, so it has no manipulation surface
 *      beyond the Chainlink feed it wraps. Independent implementation of the linear-discount model Pendle
 *      publicly documents for lending integrations; no third-party source code is reused.
 *
 *      The PT must be a non-borrowable, collateral-only reserve. `discountRatePerYear` is a risk parameter owned
 *      by the market's risk admin (Safe/timelock), hard-capped by the immutable `maxDiscountRatePerYear`.
 *      L1-only (e.g., Monad); on an L2 rollup add an external Sequencer Uptime Feed + grace-period guard.
 */
contract PendlePtDiscountOracleAdapter is IPendlePtDiscountOracleAdapter, Ownable2Step {
    /**
     * @notice Initializes the Pendle PT discount oracle adapter
     * @param _baseAggregator The accounting-asset USD price aggregator address
     * @param _principalToken The Pendle principal token address
     * @param _maxDelay Maximum staleness delay for base feed data in seconds
     * @param _maxDiscountRatePerYear Immutable hard ceiling for the annual discount rate, in basis points
     * @param _discountRatePerYear Initial annual discount rate, in basis points
     * @param _description Human-readable description of the oracle
     */
    constructor(
        address _baseAggregator,
        address _principalToken,
        uint256 _maxDelay,
        uint16 _maxDiscountRatePerYear,
        uint16 _discountRatePerYear,
        string memory _description
    ) {
        if (_baseAggregator == address(0) || _principalToken == address(0)) {
            revert CommonChecksLibrary.AddressZero();
        }
        if (_maxDelay == 0) revert InvalidMaxDelay();

        // The ceiling must be a real, sub-100% rate; the active rate must be positive and within it.
        if (_maxDiscountRatePerYear == 0 || _maxDiscountRatePerYear >= BPS_DENOMINATOR) {
            revert InvalidDiscountRate();
        }
        if (_discountRatePerYear == 0 || _discountRatePerYear > _maxDiscountRatePerYear) {
            revert InvalidDiscountRate();
        }

        baseAggregator = AggregatorV3Interface(_baseAggregator);
        principalToken = IPendlePrincipalToken(_principalToken);
        maxDelay = _maxDelay;
        maxDiscountRatePerYear = _maxDiscountRatePerYear;
        discountRatePerYear = _discountRatePerYear;

        baseDecimals = baseAggregator.decimals();
        if (baseDecimals < OracleLib.MIN_DECIMALS || baseDecimals > OracleLib.MAX_DECIMALS) {
            revert CommonChecksLibrary.InvalidDecimals();
        }

        // Refuse to deploy against an already-matured PT; post-deployment maturity prices at par.
        uint256 ptMaturity = principalToken.expiry();
        if (ptMaturity <= block.timestamp) revert MaturityHasPassed();

        maturity = ptMaturity;

        // A fresh listing must price strictly above zero: reject a rate that already implies a full discount.
        if (_discountWadFor(_discountRatePerYear) >= WAD) revert DiscountExceedsHundredPercent();

        description = _description;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Basis-points denominator (100%), used to bound the governed annual rate
    uint256 private constant BPS_DENOMINATOR = 10000;

    /// @dev 1e18 fixed-point scale (100%) used for the discount factor
    uint256 private constant WAD = 1e18;

    /// @dev Multiplier converting a basis-point rate to WAD (1e18 / 1e4)
    uint256 private constant BPS_TO_WAD = 1e14;

    /// @dev Seconds in a year, used to pro-rate the annual discount rate
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    /*//////////////////////////////////////////////////////////////
                          IMMUTABLE STATE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPendlePtDiscountOracleAdapter
    AggregatorV3Interface public immutable baseAggregator;

    /// @inheritdoc IPendlePtDiscountOracleAdapter
    IPendlePrincipalToken public immutable principalToken;

    /// @inheritdoc IPendlePtDiscountOracleAdapter
    uint256 public immutable maturity;

    /// @inheritdoc IPendlePtDiscountOracleAdapter
    uint256 public immutable maxDelay;

    /// @inheritdoc IPendlePtDiscountOracleAdapter
    uint8 public immutable baseDecimals;

    /// @inheritdoc IPendlePtDiscountOracleAdapter
    uint16 public immutable maxDiscountRatePerYear;

    /*//////////////////////////////////////////////////////////////
                          MUTABLE STATE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPendlePtDiscountOracleAdapter
    string public description;

    /// @inheritdoc IPendlePtDiscountOracleAdapter
    uint16 public discountRatePerYear;

    /*//////////////////////////////////////////////////////////////
                              ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPendlePtDiscountOracleAdapter
    function setDiscountRatePerYear(uint16 newRatePerYear) external onlyOwner {
        // The immutable ceiling can never be exceeded; the rate must remain strictly positive.
        if (newRatePerYear == 0 || newRatePerYear > maxDiscountRatePerYear) revert InvalidDiscountRate();
        // The new rate must not imply a full discount at the current time (PT must price above zero).
        if (_discountWadFor(newRatePerYear) >= WAD) revert DiscountExceedsHundredPercent();

        uint16 previous = discountRatePerYear;
        discountRatePerYear = newRatePerYear;

        emit DiscountRatePerYearUpdated(previous, newRatePerYear);
    }

    /// @inheritdoc IPendlePtDiscountOracleAdapter
    function renounceOwnership() public view override(IPendlePtDiscountOracleAdapter, Ownable) onlyOwner {
        revert OwnershipRequired();
    }

    /*//////////////////////////////////////////////////////////////
                      CHAINLINK INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPendlePtDiscountOracleAdapter
    function latestAnswer() external view returns (int256) {
        (bool ok,, int256 answer,) = _tryLatestData();

        return ok ? answer : int256(0);
    }

    /// @inheritdoc IPendlePtDiscountOracleAdapter
    function latestTimestamp() external view returns (uint256) {
        (bool ok,,, uint256 timestamp) = _tryLatestData();

        return ok ? timestamp : 0;
    }

    /// @inheritdoc IPendlePtDiscountOracleAdapter
    function latestRound() external view returns (uint256) {
        (bool ok, uint80 roundId,,) = _tryLatestData();

        return ok ? uint256(roundId) : 0;
    }

    /// @inheritdoc IPendlePtDiscountOracleAdapter
    function getAnswer(uint256 roundId) external view returns (int256) {
        if (roundId > type(uint80).max) return 0;

        (bool ok, uint80 latestRoundId, int256 answer,) = _tryLatestData();

        if (!ok || roundId != uint256(latestRoundId)) return 0;

        return answer;
    }

    /// @inheritdoc IPendlePtDiscountOracleAdapter
    function getTimestamp(uint256 roundId) external view returns (uint256) {
        if (roundId > type(uint80).max) return 0;

        (bool ok, uint80 latestRoundId,, uint256 timestamp) = _tryLatestData();

        if (!ok || roundId != uint256(latestRoundId)) return 0;

        return timestamp;
    }

    /// @inheritdoc IPendlePtDiscountOracleAdapter
    function decimals() external pure returns (uint8) {
        return uint8(OracleLib.TARGET_DECIMALS);
    }

    /// @inheritdoc IPendlePtDiscountOracleAdapter
    function version() external pure returns (uint256) {
        return 1;
    }

    /// @inheritdoc IPendlePtDiscountOracleAdapter
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) = baseAggregator.latestRoundData();
        _validateRound(answer, updatedAt);
        _validateRoundMetadata(roundId, startedAt, updatedAt, answeredInRound);
        answer = _computePtPrice(answer);
    }

    /// @inheritdoc IPendlePtDiscountOracleAdapter
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
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPendlePtDiscountOracleAdapter
    function getCurrentDiscount() external view returns (uint256) {
        return _currentDiscountWad();
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Attempts to fetch the latest base round and compute a discounted PT price without reverting
     * @dev Returns (false, 0, 0, 0) on any failure or invalid/stale data
     * @return ok True if the latest data was fetched and validated
     * @return roundId The base round ID used for the answer
     * @return answer The computed PT price scaled to target decimals
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

            int256 price = _computePtPriceSafe(basePrice);

            if (price == 0) return (false, 0, 0, 0);

            return (true, baseRoundId, price, baseUpdatedAt);
        } catch {
            return (false, 0, 0, 0);
        }
    }

    /**
     * @notice Computes the discounted PT price with strict validation
     * @dev Reverts if safe computation returns 0 (overflow, scaling failure, or full discount).
     * @param basePrice The accounting-asset USD price from the base aggregator
     * @return ptPrice The computed PT price scaled to target decimals
     */
    function _computePtPrice(int256 basePrice) internal view returns (int256 ptPrice) {
        ptPrice = _computePtPriceSafe(basePrice);

        if (ptPrice == 0) revert InvalidPtPrice();
    }

    /**
     * @notice Safely computes the discounted PT price
     * @dev Returns 0 on failure instead of reverting. Applies the linear discount-to-maturity factor.
     *      Caller must ensure basePrice is positive.
     * @param basePrice The accounting-asset USD price from the base aggregator
     * @return ptPrice The computed PT price scaled to target decimals, or 0 if computation fails
     */
    function _computePtPriceSafe(int256 basePrice) internal view returns (int256 ptPrice) {
        uint256 discountWad = _currentDiscountWad();

        // A full (>=100%) discount means the PT is valued at zero; surface as a failed read.
        if (discountWad >= WAD) return 0;

        uint256 factorWad = WAD - discountWad;
        uint256 numerator = factorWad;
        uint256 denominator = WAD;

        if (baseDecimals > OracleLib.TARGET_DECIMALS) {
            denominator *= OracleLib.DECIMAL_BASE ** (uint256(baseDecimals) - OracleLib.TARGET_DECIMALS);
        } else if (baseDecimals < OracleLib.TARGET_DECIMALS) {
            numerator *= OracleLib.DECIMAL_BASE ** (OracleLib.TARGET_DECIMALS - uint256(baseDecimals));
        }

        (uint256 normalized, bool ok) = OracleLib.tryMulDiv(uint256(basePrice), numerator, denominator);
        if (!ok || normalized > uint256(type(int256).max)) return 0;

        return int256(normalized);
    }

    /**
     * @notice Computes the discount currently applied to the PT from time remaining to maturity
     * @dev Convenience wrapper over `_discountWadFor` for the active `discountRatePerYear`.
     * @return discountWad The current discount at 1e18 scale
     */
    function _currentDiscountWad() internal view returns (uint256 discountWad) {
        return _discountWadFor(discountRatePerYear);
    }

    /**
     * @notice Computes the discount a given annual rate would currently apply to the PT
     * @dev Linear decay at WAD precision: discountWad = (rate * 1e14) * timeToMaturity / SECONDS_PER_YEAR.
     *      Returns 0 at and after maturity. An overflow is surfaced as a full discount (price floor of 0),
     *      which under-prices the collateral and therefore fails safe for a lending market.
     * @param rate The annual discount rate to evaluate, in basis points
     * @return discountWad The implied discount at 1e18 scale
     */
    function _discountWadFor(uint16 rate) internal view returns (uint256 discountWad) {
        if (block.timestamp >= maturity) return 0;

        uint256 timeToMaturity = maturity - block.timestamp;

        (uint256 discount, bool ok) = OracleLib.tryMulDiv(timeToMaturity, uint256(rate) * BPS_TO_WAD, SECONDS_PER_YEAR);

        if (!ok) return WAD;

        return discount;
    }

    /**
     * @notice Validates base oracle round data with strict checks
     * @dev Reverts if answer is invalid or data is too old
     * @param answer The price answer from the base aggregator
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
        if (answeredInRound == 0 || answeredInRound < roundId) revert CommonChecksLibrary.StaleRound();
    }

    /**
     * @notice Checks if base oracle round data is valid without reverting
     * @dev Returns false instead of reverting, used for lenient validation in latestAnswer()
     * @param answer The price answer from the base aggregator
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
        if (answeredInRound == 0 || answeredInRound < roundId) return false;

        return true;
    }

    /**
     * @notice Validates that base oracle data is fresh based on maxDelay
     * @dev Reverts if data is too old according to configured maxDelay
     * @param updatedAt Timestamp when the data was last updated
     */
    function _validateFreshness(uint256 updatedAt) internal view {
        if (updatedAt == 0 || updatedAt > block.timestamp) revert CommonChecksLibrary.StaleRound();
        if (block.timestamp - updatedAt > maxDelay) {
            revert CommonChecksLibrary.PriceTooOld(block.timestamp, updatedAt, updatedAt + maxDelay);
        }
    }

    /**
     * @notice Checks if base oracle data is fresh based on maxDelay
     * @dev Returns true when data is within maxDelay
     * @param updatedAt Timestamp when the data was last updated
     * @return isFresh True if data is fresh, false otherwise
     */
    function _isFresh(uint256 updatedAt) internal view returns (bool isFresh) {
        if (updatedAt == 0 || updatedAt > block.timestamp) return false;

        return block.timestamp - updatedAt <= maxDelay;
    }
}
