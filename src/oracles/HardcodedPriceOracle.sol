// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {IHardcodedPriceOracle} from "../interfaces/IHardcodedPriceOracle.sol";

import {OracleLib} from "../libraries/OracleLib.sol";

/**
 * @title HardcodedPriceOracle
 * @author Neverland
 * @notice Non-upgradeable, ungoverned Chainlink/Aave-compatible feed that reports one fixed USD price
 * @dev The price is supplied once at deployment as `answer`, already scaled to 8 decimals
 *      (OracleLib.TARGET_DECIMALS — the USD convention Aave consumes), and stored immutably. For
 *      example `$1.00` is `100000000` (1e8) and `$1.04` is `104000000`. Every read path returns that
 *      same answer plus `block.timestamp` and never reverts, so the feed is perpetually fresh and
 *      constant. A zero answer, or one beyond the int256 range, reverts construction, so a live feed
 *      always reports a strictly positive price. The human-readable `description` is likewise set
 *      once at deployment. There is no owner, no setter, and no upgrade path: behavior is fixed at
 *      construction.
 *
 *      Intended as a hardcoded Aave price source for an asset whose USD value is pinned by design
 *      (e.g. a $1 stablecoin). It performs no market reads and carries no manipulation surface.
 */
contract HardcodedPriceOracle is IHardcodedPriceOracle {
    /**
     * @notice Sets the fixed price and description reported by the feed
     * @dev Reverts with InvalidPrice when `answer` is zero or beyond the int256 range, so a deployed
     *      feed always reports a strictly positive price.
     * @param answer The fixed price at 8 decimals (e.g. 100000000 for $1.00, 104000000 for $1.04)
     * @param _description Human-readable feed description (e.g. "AUSD / USD")
     */
    constructor(uint256 answer, string memory _description) {
        if (answer == 0 || answer > uint256(type(int256).max)) revert InvalidPrice();

        _answer = int256(answer);
        description = _description;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Fixed round ID reported for the single perpetual round
    uint80 private constant ROUND_ID = 1;

    /*//////////////////////////////////////////////////////////////
                          IMMUTABLE STATE
    //////////////////////////////////////////////////////////////*/

    /// @dev The fixed price answer in TARGET_DECIMALS (8-decimal) USD scale
    int256 private immutable _answer;

    /*//////////////////////////////////////////////////////////////
                          MUTABLE STATE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc AggregatorV3Interface
    string public description;

    /*//////////////////////////////////////////////////////////////
                          LEGACY AGGREGATOR
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHardcodedPriceOracle
    function latestAnswer() external view returns (int256) {
        return _answer;
    }

    /// @inheritdoc IHardcodedPriceOracle
    function latestTimestamp() external view returns (uint256) {
        return block.timestamp;
    }

    /// @inheritdoc IHardcodedPriceOracle
    function latestRound() external pure returns (uint256) {
        return ROUND_ID;
    }

    /// @inheritdoc IHardcodedPriceOracle
    function getAnswer(uint256) external view returns (int256) {
        return _answer;
    }

    /// @inheritdoc IHardcodedPriceOracle
    function getTimestamp(uint256) external view returns (uint256) {
        return block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                       CHAINLINK V3 INTERFACE
    //////////////////////////////////////////////////////////////*/

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
        return _roundData();
    }

    /// @inheritdoc AggregatorV3Interface
    function getRoundData(uint80)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return _roundData();
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Builds the single perpetual round tuple
     * @dev Metadata is degenerate and constant: roundId == answeredInRound == ROUND_ID and
     *      startedAt == updatedAt == block.timestamp, so any downstream staleness check stays fresh.
     * @return roundId The constant round ID
     * @return answer The fixed price answer
     * @return startedAt The current block timestamp
     * @return updatedAt The current block timestamp
     * @return answeredInRound The constant round ID
     */
    function _roundData()
        private
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (ROUND_ID, _answer, block.timestamp, block.timestamp, ROUND_ID);
    }
}
