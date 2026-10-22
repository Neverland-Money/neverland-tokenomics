// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {
    IPoolAddressesProviderRegistry
} from "@neverland-money/lending-core/contracts/interfaces/IPoolAddressesProviderRegistry.sol";

import {IDustLock} from "./IDustLock.sol";
import {IDustRewardsController} from "./IDustRewardsController.sol";
import {INeverlandDustHelper} from "./INeverlandDustHelper.sol";
import {INeverlandUiRevenueReward as IRevenueReward} from "./INeverlandUiRevenueReward.sol";

/**
 * @title INeverlandUiProvider
 * @author Neverland
 * @notice Interface for the Neverland UI data provider contract
 * @dev Aggregates data from multiple contracts for efficient frontend queries
 */
interface INeverlandUiProvider {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Thrown when an account's token balance cannot be read.
     * @param token Token whose balance read failed because it has no code, reverted, or returned short data.
     * @param account Account whose token balance could not be read.
     */
    error BalanceUnreadable(address token, address account);

    /*//////////////////////////////////////////////////////////////
                               STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice One registered lending pool market, as discovered from the pool address provider registry.
     * @param provider The market's pool address provider. Pass this into a market-scoped price or
     *        emission call to query that specific market.
     * @param marketId The market's human-readable label (its own getMarketId()), or "" if that read
     *        failed. Display-only; code should key on `provider`, never on this string or on list
     *        position, since neither is a stable identity.
     */
    struct PoolMarket {
        address provider;
        string marketId;
    }

    /**
     * @notice Dashboard data for a user over one raw DustLock enumeration page
     * @dev Arrays are compacted to valid veNFTs, so `tokenIds.length` is not a pagination cursor; advance `offset` to `nextRawOffset` and stop when `hasMore` is false.
     * @param user The user address
     * @param tokenIds Compacted array of valid veNFT token IDs from the page
     * @param locks Lock information for each returned token
     * @param rewardSummaries Reward summaries for each returned token
     * @param totalVotingPower Current voting power across returned tokens
     * @param totalLockedAmount Total DUST locked across returned tokens
     * @param rawTokenCount Raw `DustLock.balanceOf(user)` enumeration length at query time
     * @param nextRawOffset Raw offset to pass as the next call's `offset` after skipped entries are scanned
     * @param hasMore True when the page left expected live entries or sparse raw slots unscanned
     */
    struct UserDashboardData {
        address user;
        uint256[] tokenIds;
        LockInfo[] locks;
        RewardSummary[] rewardSummaries;
        uint256 totalVotingPower;
        uint256 totalLockedAmount;
        uint256 rawTokenCount;
        uint256 nextRawOffset;
        bool hasMore;
    }

    /**
     * @notice Detailed information about a specific lock
     * @param tokenId The veNFT token ID
     * @param amount Amount of DUST locked
     * @param end Unlock timestamp (0 for permanent locks)
     * @param effectiveStart Synthetic early-withdraw penalty anchor, not creation or served time
     * @param isPermanent Whether this is a permanent lock
     * @param votingPower Current voting power of this token
     * @param rewardReceiver Address that receives rewards (for auto modes)
     * @param owner Current owner of the token
     */
    struct LockInfo {
        uint256 tokenId;
        uint256 amount;
        uint256 end;
        uint256 effectiveStart;
        bool isPermanent;
        uint256 votingPower;
        address rewardReceiver;
        address owner;
    }

    /**
     * @notice Summary of rewards for a specific veNFT token
     * @param tokenId The veNFT token ID
     * @param revenueRewards Live token-accrued revenue rewards per reward token; excludes receiver-level deferred rewards
     * @param rewardTokens Array of reward token addresses
     * @dev Emission rewards are per-user (not per-token), use getUserEmissions() instead
     */
    struct RewardSummary {
        uint256 tokenId;
        uint256[] revenueRewards;
        address[] rewardTokens;
    }

    /**
     * @notice Protocol-wide statistics
     * @param totalSupply Total DUST locked in the protocol
     * @param totalVotingPower Total voting power across all tokens
     * @param permanentLockBalance Total DUST in permanent locks
     * @param rewardTokens Array of all reward tokens
     * @param totalRewardsPerToken Total rewards distributed per token
     * @param epoch Current global epoch
     * @param activeTokenCount Number of active veNFT tokens
     */
    struct GlobalStats {
        uint256 totalSupply;
        uint256 totalVotingPower;
        uint256 permanentLockBalance;
        address[] rewardTokens;
        uint256[] totalRewardsPerToken;
        uint256 epoch;
        uint256 activeTokenCount;
    }

    /**
     * @notice User reward summary data structure
     * @param totalRevenue Total pending revenue rewards per reward token
     * @param totalEmissions Total pending emission rewards per reward token
     * @param revenueResolvedMask Bit j set means `totalRevenue[j]` is fully trustworthy: every earned-
     *        reward preview chunk covering reward token j succeeded AND both pendingRewards reads
     *        (user and, if present, vault) for reward token j succeeded. Bit j is positionally aligned
     *        with the `rewardTokens` array passed into `getUserRewardsSummary`; only the first 256
     *        positions are representable.
     * @param emissionsResolvedMask Bit j set means `totalEmissions[j]` is trustworthy. Same positional
     *        alignment and 256-bit limit as `revenueResolvedMask`.
     * @param asOfBlock Block number this read executed against.
     * @param asOfTimestamp Block timestamp this read executed against.
     */
    struct UserRewardsSummary {
        uint256[] totalRevenue;
        uint256[] totalEmissions;
        uint256 revenueResolvedMask;
        uint256 emissionsResolvedMask;
        uint256 asOfBlock;
        uint256 asOfTimestamp;
    }

    /**
     * @notice Per-asset emission reward row for a specific reward token
     * @param asset Emission asset address, usually an aToken or variable debt token
     * @param amount Accrued reward amount for the asset and queried reward token
     * @param symbol Asset ERC20 symbol returned by the asset contract
     * @param isDebt True when the asset is a variable debt token
     * @param resolved False means `amount` defaulted to 0 because this asset's emission read failed,
     *        not because the user genuinely has no accrued reward there.
     */
    struct UserEmissionAsset {
        address asset;
        uint256 amount;
        string symbol;
        bool isDebt;
        bool resolved;
    }

    /*//////////////////////////////////////////////////////////////
                         CORE DEPENDENCIES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the DustLock contract used for veNFT and voting-power data.
     * @return dustLock The configured DustLock contract.
     */
    function DUST_LOCK() external view returns (IDustLock dustLock);

    /**
     * @notice Returns the revenue reward contract used for distribution data.
     * @return revenueReward The configured RevenueReward contract.
     */
    function REVENUE_REWARD() external view returns (IRevenueReward revenueReward);

    /**
     * @notice Returns the rewards controller used for emission data.
     * @return rewardsController The configured DustRewardsController contract.
     */
    function DUST_REWARDS_CONTROLLER() external view returns (IDustRewardsController rewardsController);

    /**
     * @notice Returns the helper used for DUST price data.
     * @return dustHelper The configured NeverlandDustHelper contract.
     */
    function DUST_HELPER() external view returns (INeverlandDustHelper dustHelper);

    /**
     * @notice Returns the registry used to discover every lending pool market at read time.
     * @dev No market is pinned in the provider. Canonical and isolated markets are discovered from
     *      this registry, so registering a new market does not require redeploying the UI provider.
     * @return registry The configured pool address provider registry.
     */
    function NEVERLAND_POOL_REGISTRY() external view returns (IPoolAddressesProviderRegistry registry);

    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get one raw DustLock enumeration page of user veNFT positions and rewards
     * @dev Scans DustLock's raw owner-token enumeration from `offset`, skipping stale/zero/reverting slots, until `limit` valid veNFTs or the per-call scan budget is hit. Paginate off `nextRawOffset`/`hasMore`, never off `tokenIds.length`.
     * @param user The user address to get data for
     * @param offset Start index for paginated token list
     * @param limit Maximum number of tokens to include
     * @return Compacted dashboard information for the requested raw page, including
     *         `rawTokenCount`, `nextRawOffset`, and `hasMore` pagination metadata
     */
    function getUserDashboard(address user, uint256 offset, uint256 limit)
        external
        view
        returns (UserDashboardData memory);

    /**
     * @notice Returns the total number of veDUST tokens owned by a user
     * @param user The user address
     * @return count Number of owned veDUST tokens
     */
    function getUserTokenCount(address user) external view returns (uint256 count);

    /**
     * @notice Get protocol-wide statistics
     * @return GlobalStats Protocol statistics
     */
    function getGlobalStats() external view returns (GlobalStats memory);

    /**
     * @notice Returns comprehensive reward summary for a user across specified reward tokens, with
     *         per-row resolution signals.
     * @dev Unpaginated aggregate over owned veNFTs plus the auto-mode token set; prefer `getUserDashboard`/`getUiFullBundle` for large collections. Totals are RevenueReward-side accruals only (UserVault-realized and RevenueLending lender tabs are excluded by design). A single unreadable reward token degrades that row (see `revenueResolvedMask`/`emissionsResolvedMask`) instead of reverting the whole call.
     * @param user The address to query rewards for
     * @param rewardTokens Array of reward token addresses to check
     * @return summary User rewards summary containing all reward arrays plus resolution masks; see `UserRewardsSummary`.
     */
    function getUserRewardsSummary(address user, address[] calldata rewardTokens)
        external
        view
        returns (UserRewardsSummary memory summary);

    /**
     * @notice Returns per-asset emission rewards and labels for a specific reward token
     * @dev Lists every contributing asset, with its symbol and side, across every lending pool market
     *      currently registered on the pool address provider registry: a user's position can live in
     *      any registered market (canonical or isolated), so this is not limited to one market. Rows
     *      from different markets are concatenated, never merged or averaged into one another. Each
     *      row does not currently say which market it came from; if you need that, correlate the
     *      asset address against `getRegisteredPoolMarkets()` off-chain, or ask for a dedicated
     *      per-market surface if row-level attribution becomes a hard requirement.
     * @param user The address to query rewards for
     * @param rewardToken The reward token address to break down
     * @return breakdown Array of per-asset emission rows; a row's `resolved` field is false when that
     *         specific asset's read failed, not when the user genuinely has no accrued reward there.
     * @return enumerationResolved Aggregate signal, distinct from any row's own `resolved`: false
     *         means at least one registered pool's asset list itself could not be enumerated, so
     *         `breakdown` is missing that pool's rows entirely rather than reporting them as zero.
     */
    function getUserEmissionBreakdown(address user, address rewardToken)
        external
        view
        returns (UserEmissionAsset[] memory breakdown, bool enumerationResolved);

    /**
     * @notice Get unlock schedule for user's tokens
     * @dev Unpaginated over all currently owned veNFTs. Prefer
     *      `getUserDashboard` for bounded UI reads, especially for accounts
     *      with many veNFTs.
     * @param user The user address
     * @return unlockTimes Array of unlock timestamps
     * @return amounts Array of amounts unlocking at each timestamp
     * @return tokenIds Array of token IDs for each unlock
     */
    function getUnlockSchedule(address user)
        external
        view
        returns (uint256[] memory unlockTimes, uint256[] memory amounts, uint256[] memory tokenIds);

    /*//////////////////////////////////////////////////////////////
                         COMPREHENSIVE DATA STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Market and economic data
     * @param rewardTokens Array of reward token addresses
     * @param rewardTokenBalances Raw reward token balances held by RevenueReward
     * @param distributionRates Rewards distributed per epoch (current epoch)
     * @param nextEpochTimestamp When next reward epoch starts
     * @param currentEpoch Current epoch number
     * @param epochRewards Total rewards for current epoch per token
     * @param nextEpochRewards Total rewards already scheduled for the next epoch per token
     * @param totalValueLockedUSD Total protocol TVL in USD (8 decimals)
     * @param followingEpochRewards Total rewards already scheduled for the epoch after next per token
     * @param totalValueLockedUSDResolved False means `totalValueLockedUSD` defaulted to 0 because the
     *        DUST price was unavailable or the DUST value read failed; every other field here is a
     *        first-party, non-fail-soft read and is not separately flagged.
     * @param asOfBlock Block number this read executed against.
     * @param asOfTimestamp Block timestamp this read executed against.
     */
    struct MarketData {
        address[] rewardTokens;
        uint256[] rewardTokenBalances;
        uint256[] distributionRates;
        uint256 nextEpochTimestamp;
        uint256 currentEpoch;
        uint256[] epochRewards;
        uint256[] nextEpochRewards;
        uint256 totalValueLockedUSD;
        uint256[] followingEpochRewards;
        bool totalValueLockedUSDResolved;
        uint256 asOfBlock;
        uint256 asOfTimestamp;
    }

    /**
     * @notice Static and semi-static protocol metadata for bootstrapping the UI
     * @param dustLock Address of DustLock contract
     * @param revenueReward Address of RevenueReward contract
     * @param dustRewardsController Address of DustRewardsController
     * @param dustOracle Address of NeverlandDustHelper
     * @param earlyWithdrawPenalty Early withdraw penalty in basis points
     * @param minLockAmount Minimum DUST required to create a lock
     * @param rewardDistributor Current revenue reward distributor address
     * @param revenueRewardTokens List of revenue reward tokens
     * @param emissionRewardTokens List of emission reward tokens
     * @param emissionStrategies List of transfer strategies (parallel to emissionRewardTokens)
     */
    struct ProtocolMeta {
        address dustLock;
        address revenueReward;
        address dustRewardsController;
        address dustOracle;
        uint256 earlyWithdrawPenalty;
        uint256 minLockAmount;
        address rewardDistributor;
        address[] revenueRewardTokens;
        address[] emissionRewardTokens;
        address[] emissionStrategies;
    }

    /**
     * @notice Price information for tokens priced against the canonical lending pool market's oracle,
     *         with a per-row resolution signal and an as-of block/timestamp.
     * @dev Scope note: prices come from the canonical market only (see `_resolveCanonicalPoolProvider`
     *      in the implementation), not from every registered market. This prices DUST and RevenueReward's
     *      curated reward-token list, none of which are market-scoped assets with genuinely different
     *      prices per market, so this is not a completeness gap the way emissions summing was.
     * @param tokens Token addresses
     * @param prices Token prices in USD (8 decimals)
     * @param lastUpdated Price timestamps. DUST uses DustHelper's latest timestamp; non-DUST uses read time when price is available and zero when unavailable.
     * @param resolvedMask Per-row resolution bits, positionally aligned with `tokens`/`prices`. Bit i
     *        unset means that row defaulted to 0 because the underlying read failed, was unavailable,
     *        or failed a sanity guard. Only the first 256 rows are representable; a bit for a row
     *        beyond that always reads unset regardless of the row's actual outcome.
     * @param dustPriceFromOracle True when the DUST price (index 0) came from DustHelper's live oracle
     *        path rather than its fallback path. Meaningless when bit 0 of resolvedMask is unset.
     * @param asOfBlock Block number this read executed against.
     * @param asOfTimestamp Block timestamp this read executed against.
     */
    struct PriceData {
        address[] tokens;
        uint256[] prices;
        uint256[] lastUpdated;
        uint256 resolvedMask;
        bool dustPriceFromOracle;
        uint256 asOfBlock;
        uint256 asOfTimestamp;
    }

    /**
     * @notice Network and system status information
     * @param currentBlock Current block number
     * @param currentTimestamp Current timestamp
     * @param gasPrice Current gas price estimate
     */
    struct NetworkData {
        uint256 currentBlock;
        uint256 currentTimestamp;
        uint256 gasPrice;
    }

    /*//////////////////////////////////////////////////////////////
                         BUNDLED VIEW STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice User emission rewards data
     * @param rewardTokens Array of emission reward token addresses
     * @param totalRewards Array of total rewards per token
     * @param resolved False only when the aggregate emissions read failed; an account with no
     *        contributing lending-pool assets is a legitimate resolved zero, not a failure.
     * @param asOfBlock Block number this read executed against.
     * @param asOfTimestamp Block timestamp this read executed against.
     */
    struct EmissionData {
        address[] rewardTokens;
        uint256[] totalRewards;
        bool resolved;
        uint256 asOfBlock;
        uint256 asOfTimestamp;
    }

    /**
     * @notice Unlock schedule for a user
     * @param unlockTimes Array of unlock timestamps
     * @param amounts Array of amounts unlocking
     * @param tokenIds Array of token IDs unlocking
     */
    struct UnlockSchedule {
        uint256[] unlockTimes;
        uint256[] amounts;
        uint256[] tokenIds;
    }

    /**
     * @notice Essential user data combining core dashboard elements
     * @param user Core user dashboard data
     * @param globalStats Global protocol statistics
     * @param emissions User emission rewards data
     * @param marketData Market and economic data
     */
    struct EssentialUserView {
        UserDashboardData user;
        GlobalStats globalStats;
        EmissionData emissions;
        MarketData marketData;
    }

    /**
     * @notice Extended user data for detailed dashboards
     * @param unlockSchedule Future unlock schedule for user's tokens
     * @param allPrices Token price information
     */
    struct ExtendedUserView {
        UnlockSchedule unlockSchedule;
        PriceData allPrices;
    }

    /**
     * @notice Complete protocol bootstrap data for UI in a single call
     * @param meta Protocol metadata and core addresses
     * @param globalStats Protocol-wide statistics
     * @param marketData Market and economic data
     * @param allPrices Price information for relevant tokens
     * @param network Network status and system information
     */
    struct UiBootstrap {
        ProtocolMeta meta;
        GlobalStats globalStats;
        MarketData marketData;
        PriceData allPrices;
        NetworkData network;
    }

    /**
     * @notice Complete user-focused UI data in a single call
     * @param meta Protocol metadata and core addresses
     * @param essential Essential user view (dashboard + emissions + global + market)
     * @param extended Extended user view (unlock schedule + prices)
     * @param network Network status and system information
     */
    struct UiFullBundle {
        ProtocolMeta meta;
        EssentialUserView essential;
        ExtendedUserView extended;
        NetworkData network;
    }

    /**
     * @notice Per-asset emission breakdown for a given reward token
     * @param rewardToken Emission reward token address
     * @param assets List of contributing asset rows
     */
    struct EmissionAssetBreakdown {
        address rewardToken;
        UserEmissionAsset[] assets;
    }

    /*//////////////////////////////////////////////////////////////
                         BUNDLED VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get essential user view with core data
     * @param user The user address
     * @param offset Start index for paginated token list
     * @param limit Maximum number of tokens to include
     * @return Essential user data bundle
     */
    function getEssentialUserView(address user, uint256 offset, uint256 limit)
        external
        view
        returns (EssentialUserView memory);

    /**
     * @notice Get user emission rewards data, with a resolution signal and an as-of block/timestamp.
     * @dev Each total is summed across every lending pool market currently registered on the pool
     *      address provider registry, not just the canonical market: a user's contributing position
     *      can live in any registered market. `resolved` reflects whether every market's contribution
     *      was actually read, not just the canonical one; false only when the aggregate read itself
     *      failed, not when the user simply has no contributing assets (a legitimate resolved zero).
     * @param user The user address
     * @return rewardTokens Array of emission reward token addresses
     * @return totalRewards Array of total rewards per token
     * @return resolved False only when the aggregate emissions read failed.
     * @return asOfBlock Block number this read executed against.
     * @return asOfTimestamp Block timestamp this read executed against.
     */
    function getUserEmissions(address user)
        external
        view
        returns (
            address[] memory rewardTokens,
            uint256[] memory totalRewards,
            bool resolved,
            uint256 asOfBlock,
            uint256 asOfTimestamp
        );

    /**
     * @notice Get market and economic data, with a resolution signal for its one fail-soft field.
     * @return MarketData Market data including prices, TVL, and `totalValueLockedUSDResolved`.
     */
    function getMarketData() external view returns (MarketData memory);

    /**
     * @notice Get all token prices, with a per-row resolution signal and an as-of block/timestamp.
     * @dev Scope note: prices come from the canonical lending pool market's oracle only, not from
     *      every registered market (see `PriceData`'s NatSpec for why that is not a completeness gap
     *      for these specific tokens).
     * @return PriceData Price information for all tokens; see `PriceData` for the resolution fields.
     */
    function getAllPrices() external view returns (PriceData memory);

    /**
     * @notice Get protocol metadata for UI bootstrapping in one call
     * @return meta ProtocolMeta containing core addresses, settings, and token lists
     */
    function getProtocolMeta() external view returns (ProtocolMeta memory meta);

    /**
     * @notice Get network and system data
     * @return NetworkData Network status and system information
     */
    function getNetworkData() external view returns (NetworkData memory);

    /**
     * @notice Get protocol bootstrap data in one call, with resolution signals on its fail-soft legs.
     * @return boot UiBootstrap containing protocol + market + prices + network; nested `marketData`/`allPrices` carry their own resolution fields.
     */
    function getUiBootstrap() external view returns (UiBootstrap memory boot);

    /**
     * @notice Get complete user bundle in one call (protocol + user views), with resolution signals on its fail-soft legs.
     * @param user The user address
     * @param offset Start index for paginated token list
     * @param limit Maximum number of tokens to include
     * @return bundle UiFullBundle containing meta, essential, extended, and network; nested `marketData`/`allPrices` carry their own resolution fields.
     */
    function getUiFullBundle(address user, uint256 offset, uint256 limit)
        external
        view
        returns (UiFullBundle memory bundle);

    /*//////////////////////////////////////////////////////////////
                    LENDING POOL MARKET DISCOVERY
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Lists every lending pool market currently registered on the pool address provider
     *         registry, for use with market-scoped price/emission calls.
     * @dev Gap-safe: reads the registry's own address list directly rather than probing sequential
     *      ids, so an unregistered market never truncates the result. Cheap by design: each row is
     *      just an address plus a best-effort label, no per-market pricing or asset enumeration is
     *      done here.
     * @return markets Every registered market's provider address and human-readable label.
     */
    function getRegisteredPoolMarkets() external view returns (PoolMarket[] memory markets);
}
