// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AggregatorInterface} from "@aave/core-v3/contracts/dependencies/chainlink/AggregatorInterface.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {IPendlePrincipalToken} from "./IPendlePrincipalToken.sol";

/**
 * @title IPendlePtDiscountOracleAdapter
 * @author Neverland
 * @notice Interface for the deterministic Pendle Principal Token (PT) USD discount oracle adapter
 * @dev Prices a PT in USD as the discounted value of its accounting asset's USD feed, using a
 *      governed linear-discount-to-maturity model with no dependency on a Pendle AMM/TWAP.
 *      AaveOracle consumes the legacy AggregatorInterface path (`latestAnswer`), which returns 0 on
 *      invalid data so Aave can route to its fallback oracle. AggregatorV3Interface reads are strict
 *      diagnostic reads and revert on invalid data. Historical rounds are not supported: getRoundData
 *      returns the latest round only and reverts for non-latest roundIds.
 */
interface IPendlePtDiscountOracleAdapter is AggregatorInterface, AggregatorV3Interface {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Reverts when a configured rate would make the discount at the current time reach 100%
    error DiscountExceedsHundredPercent();

    /// @notice Reverts when a discount rate (or the immutable ceiling) is zero or out of range
    error InvalidDiscountRate();

    /// @notice Reverts when the base-feed staleness limit is zero
    error InvalidMaxDelay();

    /// @notice Reverts when the discounted PT price could not be computed
    error InvalidPtPrice();

    /// @notice Reverts when the principal token has already matured at deployment time
    error MaturityHasPassed();

    /// @notice Reverts when ownership renouncement is attempted (disabled to keep risk control)
    error OwnershipRequired();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when the annual discount rate is updated by the owner
     * @param previousRatePerYear The previous annual discount rate in basis points
     * @param newRatePerYear The new annual discount rate in basis points
     */
    event DiscountRatePerYearUpdated(uint16 previousRatePerYear, uint16 newRatePerYear);

    /*//////////////////////////////////////////////////////////////
                                FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates the annual discount rate (owner only)
     * @dev Must be greater than zero and at most maxDiscountRatePerYear; the immutable ceiling can
     *      never be exceeded. Intended to be held by the market's risk admin (Safe/timelock).
     * @param newRatePerYear The new annual discount rate in basis points
     */
    function setDiscountRatePerYear(uint16 newRatePerYear) external;

    /**
     * @notice Renouncing ownership is disabled to prevent accidental loss of risk control
     * @dev Reverts on every call so the discount-rate owner cannot be accidentally removed.
     */
    function renounceOwnership() external view;

    /**
     * @notice Returns the accounting-asset USD price aggregator (e.g., AUSD/USD)
     * @return The base aggregator interface
     */
    function baseAggregator() external view returns (AggregatorV3Interface);

    /**
     * @notice Returns the number of decimals reported by the base aggregator
     * @return The number of decimals
     */
    function baseDecimals() external view returns (uint8);

    /**
     * @notice Returns the current annual discount rate applied to the PT
     * @return The annual discount rate in basis points (e.g., 1500 = 15%)
     */
    function discountRatePerYear() external view returns (uint16);

    /**
     * @notice Returns the discount currently applied to the PT given time remaining to maturity
     * @dev Linearly decays to 0 at and after maturity. Expressed at 1e18 fixed-point scale, where
     *      1e18 == 100%. Configuration guarantees this stays below 1e18 while the PT is unmatured.
     * @return The current discount at 1e18 scale
     */
    function getCurrentDiscount() external view returns (uint256);

    /**
     * @notice Returns the maximum allowed staleness for the base feed in seconds
     * @dev Must be nonzero; the adapter is not deployable with disabled freshness checks.
     * @return The maximum staleness delay in seconds
     */
    function maxDelay() external view returns (uint256);

    /**
     * @notice Returns the immutable hard ceiling for the annual discount rate
     * @return The maximum annual discount rate in basis points
     */
    function maxDiscountRatePerYear() external view returns (uint16);

    /**
     * @notice Returns the PT maturity timestamp, cached from the principal token at deployment
     * @return The maturity (expiry) timestamp in seconds
     */
    function maturity() external view returns (uint256);

    /**
     * @notice Returns the priced Pendle principal token
     * @return The principal token interface
     */
    function principalToken() external view returns (IPendlePrincipalToken);

    /*//////////////////////////////////////////////////////////////
                          AGGREGATOR V3
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the fixed number of decimals for the PT/USD answer
     * @dev Always 8 (Chainlink USD convention); any base-feed price is normalized to this scale.
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
     * @notice Returns the latest discounted PT/USD round
     * @dev Reads the base feed's latest round, validates it, and returns the discounted PT price as `answer`
     *      alongside the base round's roundId/startedAt/updatedAt/answeredInRound. Unlike the legacy reads,
     *      this REVERTS (does not return 0) on invalid, stale, zero, future-dated, or metadata-inconsistent
     *      base data.
     * @return roundId The base feed round ID
     * @return answer The discounted PT/USD price in target (8) decimals
     * @return startedAt The base round start timestamp
     * @return updatedAt The base round update timestamp
     * @return answeredInRound The round in which the base answer was computed
     */
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /**
     * @notice Returns round data for the requested round
     * @dev Latest-round only: returns the latest round when `requestedRoundId` equals the current base round ID,
     *      and reverts with StaleRound otherwise. Historical rounds are not supported.
     * @param requestedRoundId The round ID to query; must equal the latest base round ID
     * @return roundId The base feed round ID
     * @return answer The discounted PT/USD price in target (8) decimals
     * @return startedAt The base round start timestamp
     * @return updatedAt The base round update timestamp
     * @return answeredInRound The round in which the base answer was computed
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
     * @notice Returns the latest discounted PT price answer
     * @dev Returns 0 on failure (e.g., stale or invalid base feed). This under-prices PT collateral,
     *      which is the conservative direction for a lending market.
     * @return answer The latest PT/USD answer in target decimals
     */
    function latestAnswer() external view override returns (int256 answer);

    /**
     * @notice Returns the timestamp of the latest base round
     * @dev Returns 0 on failure
     * @return timestamp The timestamp of the latest round
     */
    function latestTimestamp() external view override returns (uint256 timestamp);

    /**
     * @notice Returns the latest base round ID
     * @dev Returns 0 on failure
     * @return roundId The latest round ID
     */
    function latestRound() external view override returns (uint256 roundId);

    /**
     * @notice Returns the answer for a specific round
     * @dev Only the latest round is supported; non-latest rounds return 0
     * @param roundId The round ID to query
     * @return answer The answer for the requested round
     */
    function getAnswer(uint256 roundId) external view override returns (int256 answer);

    /**
     * @notice Returns the timestamp for a specific round
     * @dev Only the latest round is supported; non-latest rounds return 0
     * @param roundId The round ID to query
     * @return timestamp The timestamp for the requested round
     */
    function getTimestamp(uint256 roundId) external view override returns (uint256 timestamp);
}
