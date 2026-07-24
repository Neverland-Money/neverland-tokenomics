// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/**
 * @title INeverlandUiProvider
 * @author Neverland
 * @notice Interface for the Neverland UI data provider contract
 * @dev Aggregates data from multiple contracts for efficient frontend queries
 */
interface INeverlandUiProvider {
    /// @notice Thrown when a non-DUST asset price cannot be retrieved or is zero
    error AssetPriceUnavailable(address token);

    /// @notice Thrown when an account's token balance cannot be read (no code, revert, or short return)
    error BalanceUnreadable(address token, address account);

    /// @notice Thrown when the price oracle for non-DUST assets is not configured or inaccessible
    error PriceOracleUnavailable();

    /*//////////////////////////////////////////////////////////////
                               STRUCTS
    //////////////////////////////////////////////////////////////*/

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
     * @notice User reward summary data structure
     * @param totalRevenue Total pending revenue rewards per reward token
     * @param totalEmissions Total pending emission rewards per reward token
     */
    struct UserRewardsSummary {
        uint256[] totalRevenue;
        uint256[] totalEmissions;
    }

    /**
     * @notice Per-asset emission reward row for a specific reward token
     * @param asset Emission asset address, usually an aToken or variable debt token
     * @param amount Accrued reward amount for the asset and queried reward token
     * @param symbol Asset ERC20 symbol returned by the asset contract
     * @param isDebt True when the asset is a variable debt token
     */
    struct UserEmissionAsset {
        address asset;
        uint256 amount;
        string symbol;
        bool isDebt;
    }

    /**
     * @notice Returns comprehensive reward summary for a user across specified reward tokens
     * @dev Unpaginated aggregate over owned veNFTs plus the auto-mode token set; prefer `getUserDashboard`/`getUiFullBundle` for large collections. Totals are RevenueReward-side accruals only (UserVault-realized and RevenueLending lender tabs are excluded by design).
     * @param user The address to query rewards for
     * @param rewardTokens Array of reward token addresses to check
     * @return summary User rewards summary containing all reward arrays
     */
    function getUserRewardsSummary(address user, address[] calldata rewardTokens)
        external
        view
        returns (UserRewardsSummary memory summary);

    /**
     * @notice Returns per-asset emission rewards and labels for a specific reward token
     * @dev Lists Aave assets that contribute to the user's emissions with the asset token symbol and side.
     * @param user The address to query rewards for
     * @param rewardToken The reward token address to break down
     * @return breakdown Array of per-asset emission rows
     */
    function getUserEmissionBreakdown(address user, address rewardToken)
        external
        view
        returns (UserEmissionAsset[] memory breakdown);

    /**
     * @notice Get unlock schedule for user's tokens
     * @dev Unpaginated over all currently owned veNFTs. Prefer
     *      `getUserDashboard` or `getExtendedUserView` for bounded UI reads,
     *      especially for accounts with many veNFTs.
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
     * @notice Price information for all tokens
     * @param tokens Token addresses
     * @param prices Token prices in USD (8 decimals)
     * @param lastUpdated Price timestamps. DUST uses DustHelper's latest timestamp; non-DUST uses read time when price is available and zero when unavailable.
     */
    struct PriceData {
        address[] tokens;
        uint256[] prices;
        uint256[] lastUpdated;
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
     */
    struct EmissionData {
        address[] rewardTokens;
        uint256[] totalRewards;
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
     * @notice Get extended user view with detailed analysis data
     * @param user The user address
     * @param offset Start index for paginated token list
     * @param limit Maximum number of tokens to include
     * @return Extended user data bundle
     */
    function getExtendedUserView(address user, uint256 offset, uint256 limit)
        external
        view
        returns (ExtendedUserView memory);

    /**
     * @notice Get user emission rewards data
     * @param user The user address
     * @return rewardTokens Array of emission reward token addresses
     * @return totalRewards Array of total rewards per token
     */
    function getUserEmissions(address user)
        external
        view
        returns (address[] memory rewardTokens, uint256[] memory totalRewards);

    /**
     * @notice Get market and economic data
     * @return MarketData Market data including prices and TVL
     */
    function getMarketData() external view returns (MarketData memory);

    /**
     * @notice Get all token prices
     * @return PriceData Price information for all tokens
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
     * @notice Get protocol bootstrap data in one call
     * @return boot UiBootstrap containing protocol + market + prices + network
     */
    function getUiBootstrap() external view returns (UiBootstrap memory boot);

    /**
     * @notice Get complete user bundle in one call (protocol + user views)
     * @param user The user address
     * @param offset Start index for paginated token list
     * @param limit Maximum number of tokens to include
     * @return bundle UiFullBundle containing meta, essential, extended, and network
     */
    function getUiFullBundle(address user, uint256 offset, uint256 limit)
        external
        view
        returns (UiFullBundle memory bundle);
}
