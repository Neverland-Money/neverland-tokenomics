// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {CommonChecksLibrary} from "../libraries/CommonChecksLibrary.sol";
import {INeverlandDustHelper} from "../interfaces/INeverlandDustHelper.sol";
import {IChainlinkAggregator} from "../interfaces/IChainlinkAggregator.sol";
import {IReClammPool} from "../interfaces/IReClammPool.sol";

/**
 * @title NeverlandDustHelper
 * @author Neverland
 * @notice Production-ready oracle and helper contract for DUST token
 * @dev Provides market data, circulating supply, and price discovery via oracle integration
 *
 * ⚠️ IMPORTANT: This contract uses spot prices from Uniswap pools (slot0) without TWAP protection.
 * It can return prices from different sources (V4/V3/V2/Chainlink) and switch sources on the fly.
 * It is designed EXCLUSIVELY for off-chain UI/informational purposes (e.g., APR display in NeverlandUiProvider).
 * DO NOT use this as an on-chain oracle for financial logic such as:
 * - Liquidations
 * - Collateral valuations
 * - Automated trading decisions
 * - Any logic where price manipulation could cause financial loss
 *
 * The updatePriceCache() function is owner-gated and only snapshots spot prices.
 * It should be called when sources/config change or on a schedule controlled by the owner.
 *
 * Operational notes:
 * - Native currency pairs are NOT supported (ERC20-only).
 * - Token decimals are capped to MAX_TOKEN_DECIMALS; larger values are treated as invalid.
 * - If a price source is invalid or reverts, the helper returns 0 (no automatic fallback).
 * - If pairOracle is cleared while dustPair is a DUST/<PAIR> pool, the price will be 0.
 * - No explicit freshness/L2 sequencer checks are performed: Uniswap pools are spot reads with no timestamps,
 *   and Chainlink feeds enforce their own heartbeat/freshness off-chain; this helper is UI-only.
 */
contract NeverlandDustHelper is INeverlandDustHelper, Ownable {
    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Price decimals (8 decimals to match standard oracles)
    uint8 public constant PRICE_DECIMALS = 8;

    /// @notice Default DUST price in USD (8 decimals) - $0.25
    uint256 public constant DEFAULT_DUST_PRICE = 25_000_000;

    /// @notice Maximum number of team addresses to prevent unbounded iteration DoS
    uint256 public constant MAX_TEAM_ADDRESSES = 50;

    /// @notice 18-decimals unit
    uint256 private constant WAD = 1e18;

    /// @notice One USD in 8-decimal scale
    uint256 private constant USD_SCALE = 1e8;

    /// @notice 2^192 used for Uniswap V3/V4 price math
    uint256 private constant Q192 = 2 ** 192;

    /// @notice Maximum supported ERC20 decimals (native currency not supported)
    uint8 private constant MAX_TOKEN_DECIMALS = 24;

    /*//////////////////////////////////////////////////////////////
                          STORAGE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice DUST token contract
    IERC20 public immutable dustToken;

    /**
     * @notice Current hardcoded DUST price in USD (8 decimals)
     * @dev Used only when no oracle sources are configured (manual UI fallback).
     */
    uint256 public hardcodedPrice;

    /**
     * @notice DUST/<PAIR> pool/oracle or direct DUST/USD oracle
     * @dev Can be: Uniswap V2/V3 pool, UniV3 TWAP oracle, or direct DUST/USD Chainlink oracle
     */
    address public dustPair;

    /**
     * @notice <PAIR>/USD oracle for two-step conversion (optional if dustPair is DUST/USD)
     * @dev If not set (address(0)), dustPair is assumed to return DUST/USD directly
     */
    address public pairOracle;

    /// @notice Last price update timestamp
    uint256 public lastPriceUpdate;

    /// @notice Price update interval (1 hour for production readiness)
    uint256 public priceUpdateInterval = 1 hours;

    /// @notice Cached price for gas optimization
    uint256 private cachedPrice;

    /// @notice Cache timestamp
    uint256 private cacheTimestamp;

    /// @notice Whether the cached price came from oracle (true) or hardcoded (false)
    bool private cachedPriceFromOracle;

    /// @notice Team addresses mapping
    mapping(address => bool) public isTeamAddress;

    /// @notice Array of team addresses for iteration
    address[] public teamAddresses;

    /// @notice Configurable maximum reasonable price (safety check)
    uint256 public maxReasonablePrice = 1e11;

    /// @notice Configurable minimum reasonable price (safety check)
    uint256 public minReasonablePrice = 1e5;

    /// @notice Round ID for Chainlink compatibility
    uint256 private currentRoundId;

    /// @notice Round data for Chainlink compatibility
    mapping(uint256 => RoundData) private rounds;

    /// @notice Uniswap V4 PoolManager address
    address public v4PoolManager;

    /// @notice Uniswap V4 Pool ID
    PoolId public v4PoolId;

    /// @notice True if DUST is currency0 in the V4 pool, false if currency1
    bool public v4IsDustToken0;

    /// @notice Paired currency address in V4 pool (ERC20 only; native currency not supported)
    address public v4PairedCurrency;

    /// @notice Balancer V3 reCLAMM pool address for price reading
    address public reclammPool;

    /// @notice True if DUST is token0 in the reCLAMM pool, false if token1
    bool public reclammIsDustToken0;

    /*//////////////////////////////////////////////////////////////
                               STRUCTS
    //////////////////////////////////////////////////////////////*/

    // MarketData struct is declared in the interface

    /**
     * @notice Chainlink round data structure
     * @param answer The answer of the round
     * @param timestamp The timestamp of the round
     * @param startedAt The start timestamp of the round
     * @param answeredInRound The round in which the answer was computed
     */
    struct RoundData {
        uint256 answer;
        uint256 timestamp;
        uint256 startedAt;
        uint256 answeredInRound;
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the helper with token and owner
     * @param _dustToken DUST token address (IERC20)
     * @param _initialOwner Initial owner for Ownable
     */
    constructor(address _dustToken, address _initialOwner) {
        _transferOwnership(_initialOwner);
        CommonChecksLibrary.revertIfZeroAddress(_dustToken);
        CommonChecksLibrary.revertIfZeroAddress(_initialOwner);

        dustToken = IERC20(_dustToken);
        hardcodedPrice = DEFAULT_DUST_PRICE;
        lastPriceUpdate = block.timestamp;
        cachedPrice = DEFAULT_DUST_PRICE;
        cacheTimestamp = block.timestamp;
        cachedPriceFromOracle = false;

        // Initialize round data with hardcoded price so Chainlink interface works immediately
        currentRoundId = 1;
        rounds[currentRoundId] = RoundData({
            answer: DEFAULT_DUST_PRICE, timestamp: block.timestamp, startedAt: block.timestamp, answeredInRound: 1
        });
    }

    /*//////////////////////////////////////////////////////////////
                           TEAM MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandDustHelper
    function addTeamAddress(address teamAddress) external override onlyOwner {
        CommonChecksLibrary.revertIfZeroAddress(teamAddress);

        if (teamAddresses.length >= MAX_TEAM_ADDRESSES) revert TooManyTeamAddresses();
        if (isTeamAddress[teamAddress]) revert TeamAddressAlreadyExists(teamAddress);

        isTeamAddress[teamAddress] = true;
        teamAddresses.push(teamAddress);

        emit TeamAddressAdded(teamAddress);
    }

    /// @inheritdoc INeverlandDustHelper
    function removeTeamAddress(address teamAddress) external override onlyOwner {
        if (!isTeamAddress[teamAddress]) revert TeamAddressNotFound(teamAddress);

        isTeamAddress[teamAddress] = false;

        // Remove from array by finding and swapping with last element
        uint256 len = teamAddresses.length;
        for (uint256 i = 0; i < len; ++i) {
            if (teamAddresses[i] == teamAddress) {
                teamAddresses[i] = teamAddresses[teamAddresses.length - 1];
                teamAddresses.pop();
                break;
            }
        }

        emit TeamAddressRemoved(teamAddress);
    }

    /// @inheritdoc INeverlandDustHelper
    function getTeamAddresses() external view override returns (address[] memory addresses) {
        return teamAddresses;
    }

    /// @inheritdoc INeverlandDustHelper
    function getTeamAddressCount() external view override returns (uint256 count) {
        return teamAddresses.length;
    }

    /// @inheritdoc INeverlandDustHelper
    function addTeamAddresses(address[] calldata teamAddressesBatch) external override onlyOwner {
        if (teamAddressesBatch.length == 0) {
            revert EmptyArray();
        }

        if (teamAddresses.length + teamAddressesBatch.length > MAX_TEAM_ADDRESSES) {
            revert TooManyTeamAddresses();
        }

        for (uint256 i = 0; i < teamAddressesBatch.length; ++i) {
            address teamAddress = teamAddressesBatch[i];
            CommonChecksLibrary.revertIfZeroAddress(teamAddress);

            if (isTeamAddress[teamAddress]) revert TeamAddressAlreadyExists(teamAddress);

            isTeamAddress[teamAddress] = true;
            teamAddresses.push(teamAddress);
        }

        emit TeamAddressesBatchAdded(teamAddressesBatch);
    }

    /// @inheritdoc INeverlandDustHelper
    function removeTeamAddresses(address[] calldata teamAddressesBatch) external override onlyOwner {
        if (teamAddressesBatch.length == 0) {
            revert EmptyArray();
        }

        for (uint256 i = 0; i < teamAddressesBatch.length; ++i) {
            address teamAddress = teamAddressesBatch[i];

            if (!isTeamAddress[teamAddress]) revert TeamAddressNotFound(teamAddress);

            isTeamAddress[teamAddress] = false;

            // Remove from array by finding and swapping with last element
            uint256 lenInner = teamAddresses.length;
            for (uint256 j = 0; j < lenInner; ++j) {
                if (teamAddresses[j] == teamAddress) {
                    teamAddresses[j] = teamAddresses[teamAddresses.length - 1];
                    teamAddresses.pop();
                    break;
                }
            }
        }

        emit TeamAddressesBatchRemoved(teamAddressesBatch);
    }

    /*//////////////////////////////////////////////////////////////
                         ORACLE INTEGRATION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandDustHelper
    function pair() external view override returns (address) {
        return dustPair;
    }

    /**
     * @notice Set the price source for DUST
     * @param pairAddress Can be:
     *        - Uniswap V2/V3 pool (DUST/<PAIR> or <PAIR>/DUST)
     *        - UniV3 TWAP oracle (Chainlink-compatible with token0/token1)
     *        - Direct DUST/USD Chainlink oracle (if pairOracle not needed)
     *        - DUST/<PAIR> Chainlink oracle (used with pairOracle for two-step conversion)
     */
    function setPair(address pairAddress) external override onlyOwner {
        CommonChecksLibrary.revertIfZeroAddress(pairAddress);

        address oldPair = dustPair;
        dustPair = pairAddress;

        // Clear cache when switching pairs
        cacheTimestamp = 0;

        emit PairUpdated(oldPair, pairAddress);
    }

    /**
     * @notice Remove the DUST/<PAIR> pool/oracle
     */
    function removePair() external override onlyOwner {
        address oldPair = dustPair;
        dustPair = address(0);
        cacheTimestamp = 0;

        emit PairUpdated(oldPair, address(0));
    }

    /**
     * @notice Set the <PAIR>/USD Chainlink oracle for USD conversion
     * @param pairOracleAddress <PAIR>/USD Chainlink oracle address (e.g., MON/USD, USDC/USD)
     */
    function setPairOracle(address pairOracleAddress) external override onlyOwner {
        CommonChecksLibrary.revertIfZeroAddress(pairOracleAddress);

        address oldPairOracle = pairOracle;
        pairOracle = pairOracleAddress;
        cacheTimestamp = 0;

        emit PairOracleUpdated(oldPairOracle, pairOracleAddress);
    }

    /**
     * @notice Set Uniswap V4 pool configuration for price reading
     * @param poolManager The V4 PoolManager address
     * @param poolId The pool ID (bytes32)
     * @param isDustToken0 True if DUST is currency0, false if currency1
     * @param pairedCurrency The paired currency address (ERC20 only; native currency not supported)
     */
    function setV4Pool(address poolManager, bytes32 poolId, bool isDustToken0, address pairedCurrency)
        external
        override
        onlyOwner
    {
        CommonChecksLibrary.revertIfZeroAddress(poolManager);
        CommonChecksLibrary.revertIfZeroAddress(pairedCurrency);
        if (pairedCurrency == address(dustToken)) revert InvalidV4PoolConfig();
        if (poolId == bytes32(0)) revert InvalidV4PoolConfig();

        v4PoolManager = poolManager;
        v4PoolId = PoolId.wrap(poolId);
        v4IsDustToken0 = isDustToken0;
        v4PairedCurrency = pairedCurrency;

        // Clear cache when switching pools
        cacheTimestamp = 0;

        emit V4PoolUpdated(poolManager, poolId, isDustToken0, pairedCurrency);
    }

    /**
     * @notice Remove Uniswap V4 pool configuration
     */
    function removeV4Pool() external override onlyOwner {
        v4PoolManager = address(0);
        v4PoolId = PoolId.wrap(bytes32(0));
        v4IsDustToken0 = false;
        v4PairedCurrency = address(0);
        cacheTimestamp = 0;

        emit V4PoolRemoved();
    }

    /**
     * @notice Set reCLAMM pool configuration for price reading
     * @param pool The reCLAMM pool address (Balancer V3)
     * @param isDustToken0 True if DUST is token0, false if token1
     */
    function setReclammPool(address pool, bool isDustToken0) external override onlyOwner {
        CommonChecksLibrary.revertIfZeroAddress(pool);

        reclammPool = pool;
        reclammIsDustToken0 = isDustToken0;

        // Clear cache when switching pools
        cacheTimestamp = 0;

        emit ReclammPoolUpdated(pool, isDustToken0);
    }

    /**
     * @notice Remove reCLAMM pool configuration
     */
    function removeReclammPool() external override onlyOwner {
        reclammPool = address(0);
        reclammIsDustToken0 = false;
        cacheTimestamp = 0;

        emit ReclammPoolRemoved();
    }

    /**
     * @notice Remove the <PAIR>/USD Chainlink oracle
     * @dev If dustPair is a DUST/<PAIR> pool, price reads will return 0 until pairOracle is set again.
     */
    function removePairOracle() external override onlyOwner {
        address oldPairOracle = pairOracle;
        pairOracle = address(0);
        cacheTimestamp = 0;
        emit PairOracleUpdated(oldPairOracle, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                               PRICE MANAGEMENT
        //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandDustHelper
    function updateHardcodedPrice(uint256 newPrice) external override onlyOwner {
        if (newPrice < minReasonablePrice || newPrice > maxReasonablePrice) revert InvalidPrice(newPrice);

        uint256 oldPrice = hardcodedPrice;
        hardcodedPrice = newPrice;
        lastPriceUpdate = block.timestamp;

        // Manual fallback mode: only used when no oracle sources are configured.
        if (dustPair == address(0) && v4PoolManager == address(0)) {
            cachedPrice = newPrice;
            cacheTimestamp = block.timestamp;
            cachedPriceFromOracle = false;
        }

        emit PriceUpdated(oldPrice, newPrice, block.timestamp, false);
    }

    /// @inheritdoc INeverlandDustHelper
    function setPriceUpdateInterval(uint256 interval) external override onlyOwner {
        if (interval < 60 || interval > 24 hours) revert InvalidPriceUpdateInterval(interval);

        uint256 oldInterval = priceUpdateInterval;
        priceUpdateInterval = interval;

        emit PriceUpdateIntervalChanged(oldInterval, interval);
    }

    /// @inheritdoc INeverlandDustHelper
    function setPriceLimits(uint256 minPrice, uint256 maxPrice) external override onlyOwner {
        if (minPrice == 0 || maxPrice <= minPrice) revert InvalidPriceLimits(minPrice, maxPrice);

        minReasonablePrice = minPrice;
        maxReasonablePrice = maxPrice;

        emit PriceLimitsUpdated(minPrice, maxPrice);
    }

    /*//////////////////////////////////////////////////////////////
                         SUPPLY CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandDustHelper
    function getTotalSupply() public view override returns (uint256 supply) {
        return dustToken.totalSupply();
    }

    /// @inheritdoc INeverlandDustHelper
    function getCirculatingSupply() public view override returns (uint256 supply) {
        uint256 totalSupply = dustToken.totalSupply();
        uint256 teamBalance = 0;

        // Sum all team address balances
        uint256 len = teamAddresses.length;
        for (uint256 i = 0; i < len; ++i) {
            teamBalance += dustToken.balanceOf(teamAddresses[i]);
        }

        return totalSupply > teamBalance ? totalSupply - teamBalance : 0;
    }

    /// @inheritdoc INeverlandDustHelper
    function getTeamTotalBalance() external view override returns (uint256 balance) {
        uint256 len = teamAddresses.length;
        for (uint256 i = 0; i < len; ++i) {
            balance += dustToken.balanceOf(teamAddresses[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                         PRICE DISCOVERY
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandDustHelper
    function getPrice() public view override returns (uint256 price, bool fromOracle) {
        // Use cache if valid
        if (cacheTimestamp > 0 && block.timestamp <= cacheTimestamp + priceUpdateInterval) {
            return (cachedPrice, cachedPriceFromOracle);
        }

        // Check if we have any price source configured (V4, reCLAMM, V3/V2, or Chainlink)
        if (dustPair != address(0) || v4PoolManager != address(0) || reclammPool != address(0)) {
            (uint256 oraclePrice, bool oracleSuccess) = _getOraclePrice();
            return (oraclePrice, oracleSuccess);
        }
        return (hardcodedPrice, false);
    }

    /// @inheritdoc INeverlandDustHelper
    function updatePriceCache() external override onlyOwner {
        (uint256 newPrice, bool fromOracle) = _getPriceWithoutCache();

        // Validate price reasonableness (allow 0 as an explicit invalid/unknown price)
        if (newPrice != 0 && (newPrice < minReasonablePrice || newPrice > maxReasonablePrice)) {
            revert InvalidPrice(newPrice);
        }

        // Avoid round/log growth if nothing changed (UI helper only).
        if (newPrice == cachedPrice && fromOracle == cachedPriceFromOracle) {
            cacheTimestamp = block.timestamp;
            lastPriceUpdate = block.timestamp;
            return;
        }

        uint256 oldPrice = cachedPrice;
        cachedPrice = newPrice;
        cacheTimestamp = block.timestamp;
        cachedPriceFromOracle = fromOracle;

        // Update lastPriceUpdate when cache is refreshed
        lastPriceUpdate = block.timestamp;

        // Always update Chainlink round data (even for hardcoded prices)
        _updateRoundData(newPrice, fromOracle);

        emit PriceUpdated(oldPrice, newPrice, block.timestamp, fromOracle);
    }

    /**
     * @notice Internal function to update Chainlink round data
     * @param price New price to record
     * @param fromOracle Whether price came from oracle or is hardcoded
     */
    function _updateRoundData(uint256 price, bool fromOracle) internal {
        RoundData memory prev = rounds[currentRoundId];
        // Always keep a local sequential round ID to avoid gaps/overwrites.
        currentRoundId += 1;

        uint256 startedAt = block.timestamp;
        uint256 updatedAt = block.timestamp;

        // If we have a <PAIR>/USD oracle and price is from oracle, use its timestamps.
        if (pairOracle != address(0) && fromOracle) {
            try IChainlinkAggregator(pairOracle).latestRoundData() returns (
                uint80, int256, uint256 oracleStartedAt, uint256 oracleUpdatedAt, uint80
            ) {
                if (oracleStartedAt != 0) startedAt = oracleStartedAt;
                if (oracleUpdatedAt != 0) updatedAt = oracleUpdatedAt;
            } catch {}
        }

        // Enforce monotonic timestamps for Chainlink-style consumers.
        if (prev.timestamp != 0 && updatedAt < prev.timestamp) updatedAt = prev.timestamp;
        if (prev.startedAt != 0 && startedAt < prev.startedAt) startedAt = prev.startedAt;

        rounds[currentRoundId] =
            RoundData({answer: price, timestamp: updatedAt, startedAt: startedAt, answeredInRound: currentRoundId});

        emit AnswerUpdated(int256(price), currentRoundId, updatedAt);
    }

    /**
     * @notice Get price without using cache
     * @return price Current price (8 decimals)
     * @return fromOracle Whether price is from oracle
     */
    function _getPriceWithoutCache() internal view returns (uint256 price, bool fromOracle) {
        // Check if we have any price source configured (V4, reCLAMM, V3/V2, or Chainlink)
        if (dustPair != address(0) || v4PoolManager != address(0) || reclammPool != address(0)) {
            (uint256 oraclePrice, bool oracleSuccess) = _getOraclePrice();
            return (oraclePrice, oracleSuccess);
        }
        return (hardcodedPrice, false);
    }

    /**
     * @notice Get price from oracle
     * @dev Uses Uniswap slot0 spot prices WITHOUT TWAP protection - manipulable via flash loans
     * @return price Price from oracle (8 decimals). Returns 0 on invalid/unavailable sources.
     * @return success True if price came from successful oracle read, false otherwise
     */
    function _getOraclePrice() internal view returns (uint256 price, bool success) {
        // Need at least one price source configured: V4, reCLAMM, V3/V2 (dustPair), or Chainlink
        if (dustPair == address(0) && v4PoolManager == address(0) && reclammPool == address(0)) {
            return (hardcodedPrice, false);
        }

        uint256 usdPerDustPrice18; // USD per DUST in 18 decimals

        // Case 1: Direct DUST/USD mode (no pairOracle needed)
        if (pairOracle == address(0)) {
            // Try reCLAMM first: paired token is USD-equivalent (e.g., USDC ≈ $1)
            if (reclammPool != address(0)) {
                (uint256 dustPerUsd, bool reclammSuccess) = _getReclammPrice();
                if (reclammSuccess && dustPerUsd > 0) {
                    // Invert: USD/DUST = 1 / (DUST/USD)
                    usdPerDustPrice18 = Math.mulDiv(WAD, WAD, dustPerUsd);
                }
            }
            // Fall back to direct Chainlink DUST/USD oracle on dustPair
            if (usdPerDustPrice18 == 0) {
                bool dustUsdSuccess;
                (usdPerDustPrice18, dustUsdSuccess) = _getDustUsdPrice();
                if (!dustUsdSuccess) return (0, false);
            }
        } else {
            // Case 2: Two-step conversion via DUST/<PAIR> and <PAIR>/USD
            // Get DUST per <PAIR> price from pool or oracle
            (uint256 dustPerPairPrice, bool dustPairSuccess) = _getDustPairPrice();
            if (!dustPairSuccess) return (0, false);

            // Get USD per <PAIR> price from oracle
            (uint256 usdPerPairPrice, bool pairUsdSuccess) = _getPairUsdPrice();
            if (!pairUsdSuccess) return (0, false);

            // Calculate USD/DUST = (USD/<PAIR>) / (DUST/<PAIR>)
            // Both prices are in 18 decimals: (USD/PAIR * 1e18) / (DUST/PAIR) = USD/DUST in 18 decimals
            if (dustPerPairPrice == 0) return (0, false);
            usdPerDustPrice18 = Math.mulDiv(usdPerPairPrice, 1e18, dustPerPairPrice);
        }

        // Convert to 8 decimals
        uint256 finalPrice = usdPerDustPrice18 / 1e10;

        // Final bounds check
        if (finalPrice >= minReasonablePrice && finalPrice <= maxReasonablePrice) {
            return (finalPrice, true);
        }
        return (0, false);
    }

    /**
     * @notice Get DUST per <PAIR> price from Uniswap pool, reCLAMM pool, or oracle
     * @dev Tries Uniswap V4 pool first, then reCLAMM, falls back to V3, V2, then Chainlink oracle
     * @return price Price in 18 decimals (DUST tokens per 1 PAIR)
     * @return success Whether price was successfully retrieved
     */
    function _getDustPairPrice() internal view returns (uint256 price, bool success) {
        // Try Uniswap V4 pool first
        if (v4PoolManager != address(0)) {
            try this.getV4PriceExternal() returns (uint256 v4Price, bool v4Success) {
                if (v4Success) return (v4Price, true);
            } catch {}
        }

        // Try reCLAMM pool (Balancer V3)
        if (reclammPool != address(0)) {
            (uint256 reclammPrice, bool reclammSuccess) = _getReclammPrice();
            if (reclammSuccess) return (reclammPrice, true);
        }

        // V3/V2/Chainlink all operate on dustPair; skip when not set
        if (dustPair != address(0)) {
            // Try Uniswap V3 pool
            (uint256 v3Price, bool v3Success) = _getUniswapV3Price();
            if (v3Success) return (v3Price, true);

            // Try Uniswap V2 pool
            (uint256 v2Price, bool v2Success) = _getUniswapV2Price();
            if (v2Success) return (v2Price, true);

            // Try Chainlink oracle as fallback
            (uint256 oraclePrice, bool oracleSuccess) = _getChainlinkPrice();
            if (oracleSuccess) return (oraclePrice, true);
        }

        return (0, false);
    }

    /**
     * @notice Get price from Balancer V3 reCLAMM pool using live + virtual balances
     * @dev Spot price = (liveDust + virtualDust) / (livePaired + virtualPaired)
     *      per Balancer reCLAMM spec (real balances + virtual offsets)
     * @return price Price in 18 decimals (DUST tokens per 1 PAIR)
     * @return success Whether price was successfully retrieved
     */
    function _getReclammPrice() internal view returns (uint256 price, bool success) {
        if (reclammPool == address(0)) return (0, false);

        try IReClammPool(reclammPool).getReClammPoolDynamicData() returns (
            IReClammPool.ReClammPoolDynamicData memory data
        ) {
            if (data.balancesLiveScaled18.length < 2 || data.lastVirtualBalances.length < 2) return (0, false);
            if (!data.isPoolInitialized) return (0, false);
            // Note: We allow reading prices from paused pools for UI/informational purposes
            // This helper is for off-chain display, so showing paused pool prices is useful

            uint256 totalDust;
            uint256 totalPaired;

            if (reclammIsDustToken0) {
                totalDust = data.balancesLiveScaled18[0] + data.lastVirtualBalances[0];
                totalPaired = data.balancesLiveScaled18[1] + data.lastVirtualBalances[1];
            } else {
                totalDust = data.balancesLiveScaled18[1] + data.lastVirtualBalances[1];
                totalPaired = data.balancesLiveScaled18[0] + data.lastVirtualBalances[0];
            }

            if (totalDust == 0 || totalPaired == 0) return (0, false);

            // DUST per PAIRED = totalDust / totalPaired (18-decimal scale)
            price = Math.mulDiv(totalDust, WAD, totalPaired);

            return (price, true);
        } catch {
            return (0, false);
        }
    }

    /**
     * @notice Reads ERC20 decimals defensively
     * @param tokenAddress Token address to query
     * @return tokenDecimals ERC20 decimals value
     * @return success True when decimals were read and within configured limits
     */
    function _tryDecimals(address tokenAddress) internal view returns (uint8 tokenDecimals, bool success) {
        try IERC20Metadata(tokenAddress).decimals() returns (uint8 decimalsValue) {
            if (decimalsValue > MAX_TOKEN_DECIMALS) return (0, false);
            return (decimalsValue, true);
        } catch {
            return (0, false);
        }
    }

    /**
     * @notice Reads oracle decimals defensively
     * @param oracleAddress Oracle address to query
     * @return oracleDecimals Oracle decimals value
     * @return success True when decimals were read and within configured limits
     */
    function _tryOracleDecimals(address oracleAddress) internal view returns (uint8 oracleDecimals, bool success) {
        try IChainlinkAggregator(oracleAddress).decimals() returns (uint8 decimalsValue) {
            if (decimalsValue > MAX_TOKEN_DECIMALS) return (0, false);
            return (decimalsValue, true);
        } catch {
            return (0, false);
        }
    }

    /**
     * @notice Reads token0 from a pair address via staticcall
     * @param pairAddress Pair contract address
     * @return pairToken0 token0 address when available
     * @return success True when token0 decoding succeeded
     */
    function _tryPairToken0(address pairAddress) internal view returns (address pairToken0, bool success) {
        (bool ok, bytes memory data) = pairAddress.staticcall(abi.encodeWithSelector(IUniswapV2Pair.token0.selector));
        if (!ok || data.length < 32) return (address(0), false);
        return (abi.decode(data, (address)), true);
    }

    /**
     * @notice Reads token1 from a pair address via staticcall
     * @param pairAddress Pair contract address
     * @return pairToken1 token1 address when available
     * @return success True when token1 decoding succeeded
     */
    function _tryPairToken1(address pairAddress) internal view returns (address pairToken1, bool success) {
        (bool ok, bytes memory data) = pairAddress.staticcall(abi.encodeWithSelector(IUniswapV2Pair.token1.selector));
        if (!ok || data.length < 32) return (address(0), false);
        return (abi.decode(data, (address)), true);
    }

    /**
     * @notice Scales a raw oracle price to 18 decimals
     * @param rawPrice Raw price value from source oracle
     * @param decimalsValue Decimals used by `rawPrice`
     * @return scaledPrice Price normalized to 18 decimals
     * @return success True when scaling completed without overflow/invalid input
     */
    function _scalePriceTo18(uint256 rawPrice, uint8 decimalsValue)
        internal
        pure
        returns (uint256 scaledPrice, bool success)
    {
        if (decimalsValue > MAX_TOKEN_DECIMALS) return (0, false);
        if (decimalsValue == 18) return (rawPrice, true);

        if (decimalsValue < 18) {
            uint256 scale = 10 ** (18 - decimalsValue);
            if (rawPrice > type(uint256).max / scale) return (0, false);
            return (rawPrice * scale, true);
        }

        uint256 scaleDown = 10 ** (decimalsValue - 18);
        return (rawPrice / scaleDown, true);
    }

    /**
     * @notice Computes an 18-decimal price from Uniswap-style sqrt price
     * @param sqrtPriceX96 Square-root price in Q96.96 format
     * @param decimals0 Decimals of token0
     * @param decimals1 Decimals of token1
     * @return price18 Price scaled to 18 decimals (token1 per token0 before orientation adjustment)
     */
    function _getPriceFromSqrtPriceX96(uint160 sqrtPriceX96, uint8 decimals0, uint8 decimals1)
        internal
        pure
        returns (uint256 price18)
    {
        if (sqrtPriceX96 == 0) return 0;

        // price18 = (sqrtPriceX96^2 * 1e18 / 2^192) * 10^decimals0 / 10^decimals1
        uint256 ratioX18 = Math.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96) * WAD, Q192);

        if (decimals0 >= decimals1) {
            uint256 scale = 10 ** (decimals0 - decimals1);
            if (ratioX18 > type(uint256).max / scale) return 0;
            price18 = ratioX18 * scale;
        } else {
            price18 = ratioX18 / (10 ** (decimals1 - decimals0));
        }
    }

    /**
     * @notice Get price from Uniswap V4 pool using StateLibrary
     * @return price Price in 18 decimals (DUST tokens per 1 PAIR)
     * @return success Whether price was successfully retrieved
     */
    function _getUniswapV4Price() internal view returns (uint256 price, bool success) {
        if (v4PoolManager == address(0) || v4PairedCurrency == address(0)) return (0, false);

        bytes memory callData = abi.encodeWithSelector(this.getV4Slot0.selector, v4PoolManager, v4PoolId);

        (bool callSuccess, bytes memory returnData) = address(this).staticcall(callData);

        if (!callSuccess || returnData.length == 0) return (0, false);

        uint160 sqrtPriceX96;
        (sqrtPriceX96,,,) = abi.decode(returnData, (uint160, int24, uint24, uint24));

        if (sqrtPriceX96 == 0) return (0, false);

        // Get token decimals for proper scaling
        uint8 decimals0;
        uint8 decimals1;
        bool decimals0Ok;
        bool decimals1Ok;

        if (v4IsDustToken0) {
            (decimals0, decimals0Ok) = _tryDecimals(address(dustToken));
            (decimals1, decimals1Ok) = _tryDecimals(v4PairedCurrency);
        } else {
            (decimals0, decimals0Ok) = _tryDecimals(v4PairedCurrency);
            (decimals1, decimals1Ok) = _tryDecimals(address(dustToken));
        }

        if (!decimals0Ok || !decimals1Ok) return (0, false);

        // Calculate price from sqrtPriceX96 with full precision
        // sqrtPriceX96 = sqrt(currency1/currency0) * 2^96 (in raw token amounts)
        uint256 price18 = _getPriceFromSqrtPriceX96(sqrtPriceX96, decimals0, decimals1);
        if (price18 == 0) return (0, false);

        // Invert if DUST is token0 to get DUST per PAIR
        if (v4IsDustToken0) {
            price = (WAD * WAD) / price18;
        } else {
            price = price18;
        }

        if (price == 0) return (0, false);

        return (price, true);
    }

    /**
     * @notice External helper to call StateLibrary.getSlot0
     * @dev Must be external to allow staticcall from internal functions
     * @param poolManager Address of Uniswap v4 pool manager
     * @param poolId Pool identifier
     * @return sqrtPriceX96 Current sqrt price in Q96.96 format
     * @return tick Current pool tick
     * @return protocolFee Protocol fee field from slot0
     * @return lpFee LP fee field from slot0
     */
    function getV4Slot0(address poolManager, PoolId poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        return StateLibrary.getSlot0(IPoolManager(poolManager), poolId);
    }

    /**
     * @notice External wrapper for _getUniswapV4Price
     * @return price DUST-per-paired-asset price in 18 decimals
     * @return success True when price could be computed safely
     */
    function getV4PriceExternal() external view returns (uint256 price, bool success) {
        return _getUniswapV4Price();
    }

    /**
     * @notice Reads Uniswap v3 slot0 sqrt price defensively
     * @return sqrtPriceX96 Current sqrt price in Q96.96 format
     * @return success True when slot0 was read successfully
     */
    function _getV3SqrtPriceX96() internal view returns (uint160 sqrtPriceX96, bool success) {
        try IUniswapV3Pool(dustPair).slot0() returns (
            uint160 slot0SqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool
        ) {
            return (slot0SqrtPriceX96, true);
        } catch {
            return (0, false);
        }
    }

    /**
     * @notice Converts a Uniswap v3 sqrt price into DUST-per-paired-asset price
     * @param sqrtPriceX96 Square-root price from v3 slot0
     * @return price DUST-per-paired-asset price in 18 decimals
     * @return success True when conversion and orientation checks succeed
     */
    function _getUniswapV3PriceFromSqrtPriceX96(uint160 sqrtPriceX96)
        internal
        view
        returns (uint256 price, bool success)
    {
        if (sqrtPriceX96 == 0) return (0, false);

        // Get token addresses and decimals to determine ordering
        (address token0, bool token0Ok) = _tryPairToken0(dustPair);
        (address token1, bool token1Ok) = _tryPairToken1(dustPair);
        if (!token0Ok || !token1Ok) return (0, false);

        // Get token decimals for proper scaling
        (uint8 decimals0, bool decimals0Ok) = _tryDecimals(token0);
        (uint8 decimals1, bool decimals1Ok) = _tryDecimals(token1);
        if (!decimals0Ok || !decimals1Ok) return (0, false);

        // Calculate price from sqrtPriceX96 with full precision
        uint256 price18 = _getPriceFromSqrtPriceX96(sqrtPriceX96, decimals0, decimals1);
        if (price18 == 0) return (0, false);

        // Handle token ordering - always return DUST per PAIR
        address dustAddr = address(dustToken);
        if (token0 == dustAddr) {
            // Pool is DUST/<PAIR>, price18 = <PAIR> per DUST
            // Invert to get DUST per <PAIR>
            price = (WAD * WAD) / price18;
        } else if (token1 == dustAddr) {
            // Pool is <PAIR>/DUST, price18 = DUST per <PAIR>
            price = price18;
        } else {
            // DUST not in pool
            return (0, false);
        }

        return (price, true);
    }

    /**
     * @notice Get price from Uniswap V3 pool using slot0
     * @return price DUST-per-paired-asset price in 18 decimals
     * @return success True when slot0 and conversion steps succeed
     */
    function _getUniswapV3Price() internal view returns (uint256 price, bool success) {
        (uint160 sqrtPriceX96, bool slot0Success) = _getV3SqrtPriceX96();
        if (!slot0Success) return (0, false);
        return _getUniswapV3PriceFromSqrtPriceX96(sqrtPriceX96);
    }

    /**
     * @notice Get price from Uniswap V2 pool using reserves
     * @return price DUST-per-paired-asset price in 18 decimals
     * @return success True when reserves, orientation, and scaling are valid
     */
    function _getUniswapV2Price() internal view returns (uint256 price, bool success) {
        try IUniswapV2Pair(dustPair).getReserves() returns (uint112 reserve0, uint112 reserve1, uint32) {
            if (reserve0 == 0 || reserve1 == 0) return (0, false);

            // Get token addresses to determine ordering
            (address token0, bool token0Ok) = _tryPairToken0(dustPair);
            (address token1, bool token1Ok) = _tryPairToken1(dustPair);
            if (!token0Ok || !token1Ok) return (0, false);
            address dustAddr = address(dustToken);

            // Get token decimals for proper scaling
            (uint8 decimals0, bool decimals0Ok) = _tryDecimals(token0);
            (uint8 decimals1, bool decimals1Ok) = _tryDecimals(token1);
            if (!decimals0Ok || !decimals1Ok) return (0, false);

            // Calculate price based on reserves - always return DUST per PAIR in 18 decimals
            uint256 rawPrice;
            if (token0 == dustAddr) {
                // Pool is DUST/<PAIR>: price = reserve0 / reserve1 (DUST per PAIR)
                rawPrice = (uint256(reserve0) * 1e18) / uint256(reserve1);
                // Adjust for decimals: multiply by (10^decimals1 / 10^decimals0)
                if (decimals0 > decimals1) {
                    price = rawPrice / (10 ** (decimals0 - decimals1));
                } else if (decimals1 > decimals0) {
                    price = rawPrice * (10 ** (decimals1 - decimals0));
                } else {
                    price = rawPrice;
                }
            } else if (token1 == dustAddr) {
                // Pool is <PAIR>/DUST: price = reserve1 / reserve0 (DUST per PAIR)
                rawPrice = (uint256(reserve1) * 1e18) / uint256(reserve0);
                // Adjust for decimals: multiply by (10^decimals0 / 10^decimals1)
                if (decimals1 > decimals0) {
                    price = rawPrice / (10 ** (decimals1 - decimals0));
                } else if (decimals0 > decimals1) {
                    price = rawPrice * (10 ** (decimals0 - decimals1));
                } else {
                    price = rawPrice;
                }
            } else {
                // DUST not in pool
                return (0, false);
            }

            return (price, true);
        } catch {
            return (0, false);
        }
    }

    /**
     * @notice Get price from Chainlink-compatible oracle (may include token ordering)
     * @dev Supports both standard Chainlink oracles and custom oracles with token0/token1
     * @return price DUST-per-paired-asset price in 18 decimals
     * @return success True when oracle read and orientation handling succeed
     */
    function _getChainlinkPrice() internal view returns (uint256 price, bool success) {
        try IChainlinkAggregator(dustPair).latestRoundData() returns (uint80, int256 answer, uint256, uint256, uint80) {
            if (answer <= 0) return (0, false);

            uint256 rawPrice = uint256(answer);
            (uint8 decimalsOracle, bool decimalsOk) = _tryOracleDecimals(dustPair);
            if (!decimalsOk) return (0, false);

            (uint256 price18, bool ok) = _scalePriceTo18(rawPrice, decimalsOracle);
            if (!ok) return (0, false);

            // Try to detect token ordering if oracle exposes token0/token1 (UniV3 oracle)
            try IChainlinkAggregator(dustPair).token0() returns (address token0) {
                try IChainlinkAggregator(dustPair).token1() returns (address token1) {
                    address dustAddr = address(dustToken);

                    // Handle token ordering
                    // Oracle returns price based on token pair
                    if (token0 == dustAddr) {
                        // token0=DUST, token1=<PAIR>: oracle returns DUST/<PAIR>
                        // Already correct
                        price = price18;
                    } else if (token1 == dustAddr) {
                        // token0=<PAIR>, token1=DUST: oracle returns <PAIR>/DUST
                        // We want DUST/<PAIR>, so invert
                        if (price18 == 0) return (0, false);
                        price = (1e18 * 1e18) / price18;
                    } else {
                        // DUST not in oracle pair, assume oracle returns DUST/<PAIR>
                        price = price18;
                    }
                    return (price, true);
                } catch {
                    // token1() failed, assume oracle returns DUST/<PAIR>
                    price = price18;
                    return (price, true);
                }
            } catch {
                // token0() not available (standard Chainlink oracle)
                // Assume oracle returns DUST/<PAIR>
                price = price18;
                return (price, true);
            }
        } catch {
            return (0, false);
        }
    }

    /**
     * @notice Get USD per DUST price from direct DUST/USD oracle
     * @dev Used when no pairOracle is set (direct DUST/USD feed)
     * @return price Price in 18 decimals (USD per DUST)
     * @return success Whether price was successfully retrieved
     */
    function _getDustUsdPrice() internal view returns (uint256 price, bool success) {
        try IChainlinkAggregator(dustPair).latestRoundData() returns (uint80, int256 answer, uint256, uint256, uint80) {
            if (answer <= 0) return (0, false);

            uint256 rawPrice = uint256(answer);
            (uint8 decimalsOracle, bool decimalsOk) = _tryOracleDecimals(dustPair);
            if (!decimalsOk) return (0, false);

            (uint256 price18, bool ok) = _scalePriceTo18(rawPrice, decimalsOracle);
            if (!ok) return (0, false);

            // Try to detect token ordering if oracle exposes token0/token1
            try IChainlinkAggregator(dustPair).token0() returns (address token0) {
                try IChainlinkAggregator(dustPair).token1() returns (address token1) {
                    address dustAddr = address(dustToken);

                    // For direct DUST/USD, interpret as USD per DUST
                    if (token0 == dustAddr) {
                        // token0=DUST, token1=USD: oracle returns USD/DUST
                        // Already correct
                        price = price18;
                    } else if (token1 == dustAddr) {
                        // token0=USD, token1=DUST: oracle returns DUST/USD
                        // We want USD/DUST, so invert
                        if (price18 == 0) return (0, false);
                        price = (1e18 * 1e18) / price18;
                    } else {
                        // DUST not in oracle pair, assume oracle returns USD/DUST
                        price = price18;
                    }
                    return (price, true);
                } catch {
                    // token1() failed, assume oracle returns USD/DUST
                    price = price18;
                    return (price, true);
                }
            } catch {
                // token0() not available (standard Chainlink oracle)
                // Assume oracle returns USD/DUST
                price = price18;
                return (price, true);
            }
        } catch {
            return (0, false);
        }
    }

    /**
     * @notice Get <PAIR>/USD price from Chainlink oracle
     * @return price Price in 18 decimals (USD per PAIR token)
     * @return success Whether price was successfully retrieved
     */
    function _getPairUsdPrice() internal view returns (uint256 price, bool success) {
        try IChainlinkAggregator(pairOracle).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256, uint80
        ) {
            if (answer <= 0) return (0, false);

            uint256 rawPrice = uint256(answer);
            (uint8 pairOracleDecimals, bool decimalsOk) = _tryOracleDecimals(pairOracle);
            if (!decimalsOk) return (0, false);

            (uint256 price18, bool ok) = _scalePriceTo18(rawPrice, pairOracleDecimals);
            if (!ok) return (0, false);

            return (price18, true);
        } catch {
            return (0, false);
        }
    }

    /*//////////////////////////////////////////////////////////////
                         MARKET DATA (MAIN FUNCTION)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandDustHelper
    function getMarketData() external view override returns (INeverlandDustHelper.MarketData memory data) {
        uint256 totalSupply = getTotalSupply();
        uint256 circulatingSupply = getCirculatingSupply();
        (uint256 usdPrice, bool fromOracle) = getPrice();

        // Calculate market caps (convert to 8 decimals for consistency)
        // circulatingSupply is 18 decimals, price is 8 decimals
        // Result should be 8 decimals: (supply * price) / WAD
        uint256 marketCap = (circulatingSupply * usdPrice) / WAD;
        uint256 fullyDilutedMarketCap = (totalSupply * usdPrice) / WAD;

        return INeverlandDustHelper.MarketData({
            circulatingSupply: circulatingSupply,
            totalSupply: totalSupply,
            usdPrice: usdPrice,
            marketCap: marketCap,
            fullyDilutedMarketCap: fullyDilutedMarketCap,
            timestamp: block.timestamp,
            isPriceFromOracle: fromOracle
        });
    }

    /// @inheritdoc INeverlandDustHelper
    function getMarketMetrics()
        external
        view
        override
        returns (uint256 circulatingSupply, uint256 totalSupply, uint256 usdPrice, uint256 marketCap)
    {
        totalSupply = getTotalSupply();
        circulatingSupply = getCirculatingSupply();
        (usdPrice,) = getPrice();
        marketCap = (circulatingSupply * usdPrice) / WAD;
    }

    /*//////////////////////////////////////////////////////////////
                           UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandDustHelper
    function getDustValueInUSD(uint256 dustAmount) external view override returns (uint256 usdValue) {
        (uint256 price,) = getPrice();
        return (dustAmount * price) / WAD;
    }

    /// @inheritdoc INeverlandDustHelper
    function getUSDValueInDust(uint256 usdValue) external view override returns (uint256 dustAmount) {
        (uint256 price,) = getPrice();
        if (price == 0) return 0;
        return (usdValue * WAD) / price;
    }

    /// @inheritdoc INeverlandDustHelper
    function isPriceCacheStale() external view override returns (bool isStale) {
        return cacheTimestamp < 1 || block.timestamp > cacheTimestamp + priceUpdateInterval;
    }

    /// @inheritdoc INeverlandDustHelper
    function getPriceInfo()
        external
        view
        override
        returns (uint256 price, bool isFromOracle, uint256 lastUpdate, bool isStale)
    {
        (price, isFromOracle) = getPrice();
        lastUpdate = cacheTimestamp;
        isStale = cacheTimestamp < 1 || block.timestamp > cacheTimestamp + priceUpdateInterval;
    }

    /*//////////////////////////////////////////////////////////////
                         CHAINLINK COMPATIBILITY
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandDustHelper
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (currentRoundId == 0 || rounds[currentRoundId].timestamp == 0) revert NoRoundsRecorded();

        RoundData memory round = rounds[currentRoundId];
        return
            (
                uint80(currentRoundId),
                int256(round.answer),
                round.startedAt,
                round.timestamp,
                uint80(round.answeredInRound)
            );
    }

    /// @inheritdoc INeverlandDustHelper
    function getRoundData(uint80 requestRoundId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        RoundData memory round = rounds[uint256(requestRoundId)];
        if (round.timestamp == 0) revert NoDataPresent();

        return (requestRoundId, int256(round.answer), round.startedAt, round.timestamp, uint80(round.answeredInRound));
    }

    /// @inheritdoc INeverlandDustHelper
    function latestAnswer() external view override returns (int256 price) {
        if (currentRoundId == 0 || rounds[currentRoundId].timestamp == 0) revert NoRoundsRecorded();
        return int256(rounds[currentRoundId].answer);
    }

    /// @inheritdoc INeverlandDustHelper
    function latestTimestamp() external view override returns (uint256 timestamp) {
        if (currentRoundId == 0 || rounds[currentRoundId].timestamp == 0) revert NoRoundsRecorded();
        return rounds[currentRoundId].timestamp;
    }

    /// @inheritdoc INeverlandDustHelper
    function latestRound() external view override returns (uint256 roundId) {
        if (currentRoundId == 0 || rounds[currentRoundId].timestamp == 0) revert NoRoundsRecorded();
        return currentRoundId;
    }

    /// @inheritdoc INeverlandDustHelper
    function getAnswer(uint256 roundId) external view override returns (int256 answer) {
        RoundData memory round = rounds[roundId];
        if (round.timestamp == 0) revert NoDataPresent();

        return int256(round.answer);
    }

    /// @inheritdoc INeverlandDustHelper
    function getTimestamp(uint256 roundId) external view override returns (uint256 timestamp) {
        RoundData memory round = rounds[roundId];
        if (round.timestamp == 0) revert NoDataPresent();

        return round.timestamp;
    }

    /// @inheritdoc INeverlandDustHelper
    function decimals() external pure override returns (uint8) {
        return PRICE_DECIMALS;
    }

    /// @inheritdoc INeverlandDustHelper
    function description() external pure override returns (string memory) {
        return "DUST / USD";
    }

    /// @inheritdoc INeverlandDustHelper
    function version() external pure override returns (uint256) {
        return 13;
    }

    /// @notice Disabled to prevent accidental renouncement of ownership
    function renounceOwnership() public view override onlyOwner {
        revert();
    }
}
