// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPoolAddressesProvider} from "@neverland-money/lending-core/contracts/interfaces/IPoolAddressesProvider.sol";
import {
    IPoolAddressesProviderRegistry
} from "@neverland-money/lending-core/contracts/interfaces/IPoolAddressesProviderRegistry.sol";

import {IDustLock} from "../interfaces/IDustLock.sol";
import {IDustRewardsController} from "../interfaces/IDustRewardsController.sol";
import {INeverlandDustHelper} from "../interfaces/INeverlandDustHelper.sol";
import {INeverlandUiProvider} from "../interfaces/INeverlandUiProvider.sol";
import {INeverlandUiRevenueReward as IRevenueReward} from "../interfaces/INeverlandUiRevenueReward.sol";

import {CommonChecksLibrary} from "../libraries/CommonChecksLibrary.sol";
import {NeverlandUiArrayLibrary} from "./libraries/NeverlandUiArrayLibrary.sol";
import {NeverlandUiEmissionLibrary} from "./libraries/NeverlandUiEmissionLibrary.sol";
import {NeverlandUiEnumerationLibrary} from "./libraries/NeverlandUiEnumerationLibrary.sol";
import {NeverlandUiPriceMarketLibrary} from "./libraries/NeverlandUiPriceMarketLibrary.sol";
import {NeverlandUiRewardsSummaryLibrary} from "./libraries/NeverlandUiRewardsSummaryLibrary.sol";

/**
 * @title NeverlandUiProvider
 * @author Neverland
 * @notice Aggregates data from DustLock, RevenueReward, and DustRewardsController for efficient UI queries
 * @dev This contract is purely for data aggregation and contains no state-changing functions
 */
contract NeverlandUiProvider is INeverlandUiProvider {
    /**
     * @notice Initialize the NeverlandUiProvider with core contract addresses
     * @param _dustLock Address of the DustLock contract
     * @param _revenueReward Address of the RevenueReward contract
     * @param _dustRewardsController Address of the DustRewardsController contract
     * @param _dustOracle Address of the DUST price oracle
     * @param _neverlandPoolRegistry Address of the lending pool address provider registry
     */
    constructor(
        address _dustLock,
        address _revenueReward,
        address _dustRewardsController,
        address _dustOracle,
        address _neverlandPoolRegistry
    ) {
        CommonChecksLibrary.revertIfZeroAddress(_dustLock);
        CommonChecksLibrary.revertIfZeroAddress(_revenueReward);
        CommonChecksLibrary.revertIfZeroAddress(_dustRewardsController);
        CommonChecksLibrary.revertIfZeroAddress(_dustOracle);
        CommonChecksLibrary.revertIfZeroAddress(_neverlandPoolRegistry);

        DUST_LOCK = IDustLock(_dustLock);
        REVENUE_REWARD = IRevenueReward(_revenueReward);
        DUST_REWARDS_CONTROLLER = IDustRewardsController(_dustRewardsController);
        DUST_HELPER = INeverlandDustHelper(_dustOracle);
        NEVERLAND_POOL_REGISTRY = IPoolAddressesProviderRegistry(_neverlandPoolRegistry);
    }

    /*//////////////////////////////////////////////////////////////
                          IMMUTABLE CONTRACTS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandUiProvider
    IDustLock public immutable override DUST_LOCK;

    /// @inheritdoc INeverlandUiProvider
    IRevenueReward public immutable override REVENUE_REWARD;

    /// @inheritdoc INeverlandUiProvider
    IDustRewardsController public immutable override DUST_REWARDS_CONTROLLER;

    /// @inheritdoc INeverlandUiProvider
    INeverlandDustHelper public immutable override DUST_HELPER;

    /// @inheritdoc INeverlandUiProvider
    IPoolAddressesProviderRegistry public immutable override NEVERLAND_POOL_REGISTRY;

    /*//////////////////////////////////////////////////////////////
                    LENDING POOL MARKET DISCOVERY
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandUiProvider
    function getRegisteredPoolMarkets() external view override returns (PoolMarket[] memory markets) {
        address[] memory providers = NEVERLAND_POOL_REGISTRY.getAddressesProvidersList();
        uint256 n = providers.length;
        markets = new PoolMarket[](n);
        for (uint256 i; i < n;) {
            markets[i] = PoolMarket({provider: providers[i], marketId: _tryMarketId(providers[i])});
            unchecked {
                ++i;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                           MAIN UI FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandUiProvider
    function getUserTokenCount(address user) external view override returns (uint256 count) {
        CommonChecksLibrary.revertIfZeroAddress(user);

        return DUST_LOCK.balanceOf(user);
    }

    /// @inheritdoc INeverlandUiProvider
    function getUserDashboard(address user, uint256 offset, uint256 limit)
        public
        view
        override
        returns (UserDashboardData memory)
    {
        CommonChecksLibrary.revertIfZeroAddress(user);

        return _getUserDashboardInternal(user, offset, limit, REVENUE_REWARD.getRewardTokens());
    }

    /// @inheritdoc INeverlandUiProvider
    function getGlobalStats() public view override returns (GlobalStats memory) {
        return _getGlobalStats(REVENUE_REWARD.getRewardTokens());
    }

    /// @inheritdoc INeverlandUiProvider
    function getUserRewardsSummary(address user, address[] calldata rewardTokens)
        public
        view
        override
        returns (UserRewardsSummary memory summary)
    {
        CommonChecksLibrary.revertIfZeroAddress(user);

        uint256[] memory tokenIds =
            NeverlandUiEnumerationLibrary.getUserRelatedTokenIds(DUST_LOCK, REVENUE_REWARD, user);
        uint256 revenueResolvedMask;
        uint256 emissionsResolvedMask;
        (summary, revenueResolvedMask, emissionsResolvedMask) =
            NeverlandUiRewardsSummaryLibrary.getUserRewardsSummaryResolved(
                REVENUE_REWARD, DUST_REWARDS_CONTROLLER, _getAllRegisteredProviders(), user, rewardTokens, tokenIds
            );
        summary.revenueResolvedMask = revenueResolvedMask;
        summary.emissionsResolvedMask = emissionsResolvedMask;
        summary.asOfBlock = block.number;
        summary.asOfTimestamp = block.timestamp;
    }

    /// @inheritdoc INeverlandUiProvider
    function getUserEmissionBreakdown(address user, address rewardToken)
        public
        view
        override
        returns (UserEmissionAsset[] memory breakdown, bool enumerationResolved)
    {
        CommonChecksLibrary.revertIfZeroAddress(user);

        return NeverlandUiEmissionLibrary.getUserEmissionBreakdown(
            DUST_REWARDS_CONTROLLER, _getAllRegisteredProviders(), user, rewardToken
        );
    }

    /// @inheritdoc INeverlandUiProvider
    function getUserEmissions(address user)
        public
        view
        override
        returns (
            address[] memory rewardTokens,
            uint256[] memory totalRewards,
            bool resolved,
            uint256 asOfBlock,
            uint256 asOfTimestamp
        )
    {
        CommonChecksLibrary.revertIfZeroAddress(user);

        (rewardTokens, totalRewards, resolved) = NeverlandUiEmissionLibrary.getUserEmissionsResolved(
            DUST_REWARDS_CONTROLLER, _getAllRegisteredProviders(), user, DUST_REWARDS_CONTROLLER.getRewardsList()
        );
        asOfBlock = block.number;
        asOfTimestamp = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                           UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandUiProvider
    function getUnlockSchedule(address user)
        public
        view
        override
        returns (uint256[] memory unlockTimes, uint256[] memory amounts, uint256[] memory tokenIds)
    {
        CommonChecksLibrary.revertIfZeroAddress(user);

        uint256[] memory ownedTokenIds = NeverlandUiEnumerationLibrary.getValidatedOwnedTokenIds(DUST_LOCK, user);
        uint256 tokenCount = ownedTokenIds.length;
        IDustLock.LockedBalance[] memory lockedBalances = new IDustLock.LockedBalance[](tokenCount);
        uint256 unlockCount = 0;
        for (uint256 i; i < tokenCount;) {
            IDustLock.LockedBalance memory locked = DUST_LOCK.locked(ownedTokenIds[i]);
            lockedBalances[i] = locked;
            if (!locked.isPermanent && locked.end > block.timestamp) {
                ++unlockCount;
            }
            unchecked {
                ++i;
            }
        }

        unlockTimes = new uint256[](unlockCount);
        amounts = new uint256[](unlockCount);
        tokenIds = new uint256[](unlockCount);

        uint256 index = 0;
        for (uint256 i; i < tokenCount;) {
            uint256 tokenId = ownedTokenIds[i];
            IDustLock.LockedBalance memory locked = lockedBalances[i];

            if (!locked.isPermanent && locked.end > block.timestamp) {
                unlockTimes[index] = locked.end;
                amounts[index] = uint256(locked.amount);
                tokenIds[index] = tokenId;
                ++index;
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc INeverlandUiProvider
    function getEssentialUserView(address user, uint256 offset, uint256 limit)
        public
        view
        override
        returns (EssentialUserView memory)
    {
        (address[] memory rewardTokens, address[] memory emissionRewardTokens, UserDashboardData memory dash) =
            _getUserViewInputs(user, offset, limit);

        return _essentialFromDashboard(user, dash, rewardTokens, emissionRewardTokens, _getAllRegisteredProviders());
    }

    /*//////////////////////////////////////////////////////////////
                         COMPREHENSIVE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandUiProvider
    function getMarketData() public view override returns (MarketData memory m) {
        return _getMarketData(REVENUE_REWARD.getRewardTokens());
    }

    /// @inheritdoc INeverlandUiProvider
    function getAllPrices() public view override returns (PriceData memory p) {
        IPoolAddressesProvider canonicalPoolProvider = _resolveCanonicalPoolProvider();
        address[] memory rewardTokens = REVENUE_REWARD.getRewardTokens();

        return _getAllPrices(canonicalPoolProvider, rewardTokens);
    }

    /// @inheritdoc INeverlandUiProvider
    function getNetworkData() public view override returns (NetworkData memory) {
        NetworkData memory n;
        n.currentBlock = block.number;
        n.currentTimestamp = block.timestamp;
        n.gasPrice = tx.gasprice;

        return n;
    }

    /// @inheritdoc INeverlandUiProvider
    function getProtocolMeta() public view override returns (ProtocolMeta memory meta) {
        return _getProtocolMeta(REVENUE_REWARD.getRewardTokens(), DUST_REWARDS_CONTROLLER.getRewardsList());
    }

    /*//////////////////////////////////////////////////////////////
                         ONE-CALL UI AGGREGATES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandUiProvider
    function getUiBootstrap() public view override returns (UiBootstrap memory boot) {
        address[] memory rewardTokens = REVENUE_REWARD.getRewardTokens();
        address[] memory emissionRewardTokens = DUST_REWARDS_CONTROLLER.getRewardsList();

        boot.meta = _getProtocolMeta(rewardTokens, emissionRewardTokens);
        boot.globalStats = _getGlobalStats(rewardTokens);

        boot.marketData = _getMarketData(rewardTokens);
        boot.allPrices = _getAllPrices(_resolveCanonicalPoolProvider(), rewardTokens);

        boot.network = getNetworkData();
    }

    /// @inheritdoc INeverlandUiProvider
    function getUiFullBundle(address user, uint256 offset, uint256 limit)
        public
        view
        override
        returns (UiFullBundle memory bundle)
    {
        (address[] memory rewardTokens, address[] memory emissionRewardTokens, UserDashboardData memory dash) =
            _getUserViewInputs(user, offset, limit);
        bundle.meta = _getProtocolMeta(rewardTokens, emissionRewardTokens);
        bundle.essential =
            _essentialFromDashboard(user, dash, rewardTokens, emissionRewardTokens, _getAllRegisteredProviders());
        bundle.extended.unlockSchedule = _unlockScheduleFromLocks(dash.locks, dash.tokenIds);

        bundle.extended.allPrices = _getAllPrices(_resolveCanonicalPoolProvider(), rewardTokens);

        bundle.network = getNetworkData();
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Reads a pool address provider's human-readable market label without letting a
     *         misbehaving provider break discovery for every other registered market.
     * @param provider Pool address provider whose label is read.
     * @return label The provider's getMarketId() string, or "" if the read failed.
     */
    function _tryMarketId(address provider) internal view returns (string memory label) {
        try IPoolAddressesProvider(provider).getMarketId() returns (string memory marketId) {
            return marketId;
        } catch {
            return "";
        }
    }

    /**
     * @notice Resolves the price oracle source used by `getAllPrices`, `getUiBootstrap`, and
     *         `getUiFullBundle`'s `allPrices` leg. Price-scoped only: every emissions/rewards read in
     *         this contract sums across `_getAllRegisteredProviders()` instead, not this single
     *         canonical provider. Protocol-level tokens (DUST, RevenueReward's curated reward-token
     *         list) are not market-scoped assets, so pricing them via one deliberately-chosen source
     *         is not "picking a winner" among disagreeing markets; there is only one relevant source
     *         to ask.
     * @dev ASSUMPTION, stated explicitly because pricing depends on it: registry id 1 is the canonical
     *      market ("Neverland Market V3" at the time this was written). This is a single targeted
     *      lookup for one deliberately-chosen id, not an enumeration, so the gap-safety concern that
     *      rules out iterating ids for discovery does not apply here. If id 1 is ever unregistered,
     *      this returns address(0); every caller of this helper already degrades gracefully on a
     *      zero/no-code provider (try/catch in NeverlandUiPriceMarketLibrary, the code-length guard in
     *      NeverlandUiEmissionLibrary), so no additional handling is needed here.
     * @return provider The canonical market's pool address provider, or address(0) if id 1 is
     *         unregistered.
     */
    function _resolveCanonicalPoolProvider() internal view returns (IPoolAddressesProvider provider) {
        return IPoolAddressesProvider(NEVERLAND_POOL_REGISTRY.getAddressesProviderAddressById(1));
    }

    /**
     * @notice Returns every registered pool address provider, for market-scoped emission reads that
     *         must not privilege one market: a user's lending-pool position can live in any registered
     *         market, so DUST-emission completeness requires checking all of them, not just canonical.
     * @return providers Every provider currently on `NEVERLAND_POOL_REGISTRY.getAddressesProvidersList()`.
     */
    function _getAllRegisteredProviders() internal view returns (address[] memory providers) {
        return NEVERLAND_POOL_REGISTRY.getAddressesProvidersList();
    }

    /**
     * @notice Loads the shared inputs for the essential and full user-view aggregates.
     * @param user Token owner being viewed.
     * @param offset Raw owned-token offset for the dashboard page.
     * @param limit Maximum number of owned tokens to return.
     * @return rewardTokens RevenueReward reward-token list.
     * @return emissionRewardTokens DustRewardsController reward-token list.
     * @return dash Compacted dashboard page for `user`.
     */
    function _getUserViewInputs(address user, uint256 offset, uint256 limit)
        internal
        view
        returns (address[] memory, address[] memory, UserDashboardData memory)
    {
        CommonChecksLibrary.revertIfZeroAddress(user);

        address[] memory rewardTokens = REVENUE_REWARD.getRewardTokens();
        address[] memory emissionRewardTokens = DUST_REWARDS_CONTROLLER.getRewardsList();
        UserDashboardData memory dash = _getUserDashboardInternal(user, offset, limit, rewardTokens);

        return (rewardTokens, emissionRewardTokens, dash);
    }

    /**
     * @notice Builds market data and stamps its resolution snapshot metadata.
     * @param rewardTokens Pre-fetched RevenueReward reward-token list.
     * @return m Market data with TVL resolution and as-of metadata populated.
     */
    function _getMarketData(address[] memory rewardTokens) internal view returns (MarketData memory m) {
        bool tvlResolved;
        (m, tvlResolved) =
            NeverlandUiPriceMarketLibrary.getMarketData(DUST_LOCK, DUST_HELPER, REVENUE_REWARD, rewardTokens);
        m.totalValueLockedUSDResolved = tvlResolved;
        m.asOfBlock = block.number;
        m.asOfTimestamp = block.timestamp;
    }

    /**
     * @notice Builds price data and stamps its resolution snapshot metadata.
     * @param canonicalPoolProvider Already-resolved canonical pool address provider.
     * @param rewardTokens Pre-fetched RevenueReward reward-token list.
     * @return p Price data with resolution, provenance, and as-of metadata populated.
     */
    function _getAllPrices(IPoolAddressesProvider canonicalPoolProvider, address[] memory rewardTokens)
        internal
        view
        returns (PriceData memory p)
    {
        uint256 resolvedMask;
        bool dustPriceFromOracle;
        (p, resolvedMask, dustPriceFromOracle) =
            NeverlandUiPriceMarketLibrary.getAllPrices(DUST_LOCK, DUST_HELPER, canonicalPoolProvider, rewardTokens);
        p.resolvedMask = resolvedMask;
        p.dustPriceFromOracle = dustPriceFromOracle;
        p.asOfBlock = block.number;
        p.asOfTimestamp = block.timestamp;
    }

    /**
     * @notice Builds one dashboard page using a caller-supplied reward-token list.
     * @dev Lets aggregate callers (getUiFullBundle, getEssentialUserView) fetch
     *      REVENUE_REWARD.getRewardTokens() once per top-level call and reuse it here instead of a
     *      second independent STATICCALL inside _getBatchTokenDetailsInternal.
     * @param user The user address
     * @param offset Start index for paginated token list
     * @param limit Maximum number of tokens to include
     * @param rewardTokens Pre-fetched REVENUE_REWARD.getRewardTokens() result
     * @return dash Compacted dashboard information for the requested raw page
     */
    function _getUserDashboardInternal(address user, uint256 offset, uint256 limit, address[] memory rewardTokens)
        internal
        view
        returns (UserDashboardData memory)
    {
        (uint256[] memory tokenIds, uint256 tokenCount, uint256 nextRawOffset, bool hasMore) =
            NeverlandUiEnumerationLibrary.getValidatedOwnedTokenPage(DUST_LOCK, user, offset, limit);

        (LockInfo[] memory locks, RewardSummary[] memory rewardSummaries) =
            _getBatchTokenDetailsInternal(tokenIds, rewardTokens);

        uint256 totalVotingPower;
        uint256 totalLockedAmount;
        for (uint256 i; i < tokenIds.length;) {
            totalVotingPower += locks[i].votingPower;
            totalLockedAmount += locks[i].amount;
            unchecked {
                ++i;
            }
        }

        UserDashboardData memory dash;
        dash.user = user;
        dash.tokenIds = tokenIds;
        dash.locks = locks;
        dash.rewardSummaries = rewardSummaries;
        dash.totalVotingPower = totalVotingPower;
        dash.totalLockedAmount = totalLockedAmount;
        dash.rawTokenCount = tokenCount;
        dash.nextRawOffset = nextRawOffset;
        dash.hasMore = hasMore;

        return dash;
    }

    /**
     * @notice Builds GlobalStats using a caller-supplied reward-token list.
     * @param rewardTokens Pre-fetched REVENUE_REWARD.getRewardTokens() result
     * @return stats Protocol-wide statistics
     */
    function _getGlobalStats(address[] memory rewardTokens) internal view returns (GlobalStats memory stats) {
        uint256[] memory totalRewardsPerToken = new uint256[](rewardTokens.length);

        for (uint256 i; i < rewardTokens.length;) {
            totalRewardsPerToken[i] = REVENUE_REWARD.totalRewardsPerToken(rewardTokens[i]);
            unchecked {
                ++i;
            }
        }

        stats.totalSupply = DUST_LOCK.supply();
        stats.totalVotingPower = DUST_LOCK.totalSupplyAt(block.timestamp);
        stats.permanentLockBalance = DUST_LOCK.permanentLockBalance();
        stats.rewardTokens = rewardTokens;
        stats.totalRewardsPerToken = totalRewardsPerToken;
        stats.epoch = DUST_LOCK.epoch();
        stats.activeTokenCount = DUST_LOCK.tokenId();
    }

    /**
     * @notice Builds the essential user view from an already-computed dashboard page.
     * @dev Lets callers (getEssentialUserView, the full bundle) page a user's tokens once and reuse
     *      the result, and thread a single fetch of each reward-token list (and the registered
     *      provider list) through globalStats, marketData, and emissions instead of each one
     *      re-fetching/re-resolving independently.
     * @param user Token owner being viewed
     * @param dash Pre-computed dashboard page for `user`
     * @param rewardTokens Pre-fetched REVENUE_REWARD.getRewardTokens() result
     * @param emissionRewardTokens Pre-fetched DUST_REWARDS_CONTROLLER.getRewardsList() result
     * @param poolAddressesProviders Every registered pool address provider (see _getAllRegisteredProviders);
     *        emissions are summed across every one, so a position in any market is counted.
     * @return v Essential user view (dashboard + global stats + emissions + market)
     */
    function _essentialFromDashboard(
        address user,
        UserDashboardData memory dash,
        address[] memory rewardTokens,
        address[] memory emissionRewardTokens,
        address[] memory poolAddressesProviders
    ) internal view returns (EssentialUserView memory v) {
        v.user = dash;
        v.globalStats = _getGlobalStats(rewardTokens);
        bool emissionsResolved;
        (v.emissions.rewardTokens, v.emissions.totalRewards, emissionsResolved) =
            NeverlandUiEmissionLibrary.getUserEmissionsResolved(
                DUST_REWARDS_CONTROLLER, poolAddressesProviders, user, emissionRewardTokens
            );
        v.emissions.resolved = emissionsResolved;
        v.emissions.asOfBlock = block.number;
        v.emissions.asOfTimestamp = block.timestamp;
        v.marketData = _getMarketData(rewardTokens);
    }

    /**
     * @notice Derives the future unlock schedule from an already-fetched dashboard page.
     * @dev Filters to unexpired non-permanent locks; reuses the dashboard `locks` to avoid re-reading DustLock.
     * @param locks Per-token lock info (parallel to `tokenIds`)
     * @param tokenIds Token ids parallel to `locks`
     * @return schedule Unlock times, amounts, and token ids for unexpired non-permanent locks
     */
    function _unlockScheduleFromLocks(LockInfo[] memory locks, uint256[] memory tokenIds)
        internal
        view
        returns (UnlockSchedule memory schedule)
    {
        uint256 n = locks.length;
        uint256 count;
        for (uint256 i; i < n;) {
            if (!locks[i].isPermanent && locks[i].end > block.timestamp) {
                unchecked {
                    ++count;
                }
            }
            unchecked {
                ++i;
            }
        }

        schedule.unlockTimes = new uint256[](count);
        schedule.amounts = new uint256[](count);
        schedule.tokenIds = new uint256[](count);
        uint256 idx;
        for (uint256 i; i < n;) {
            if (!locks[i].isPermanent && locks[i].end > block.timestamp) {
                schedule.unlockTimes[idx] = locks[i].end;
                schedule.amounts[idx] = locks[i].amount;
                schedule.tokenIds[idx] = tokenIds[i];
                unchecked {
                    ++idx;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Internal function to get batch token details
     * @param tokenIds Array of veNFT token IDs
     * @param rewardTokens Pre-fetched REVENUE_REWARD.getRewardTokens() result
     * @return locks Array of detailed lock information
     * @return rewards Array of reward summaries
     */
    function _getBatchTokenDetailsInternal(uint256[] memory tokenIds, address[] memory rewardTokens)
        internal
        view
        returns (LockInfo[] memory locks, RewardSummary[] memory rewards)
    {
        uint256 length = tokenIds.length;
        locks = new LockInfo[](length);
        rewards = new RewardSummary[](length);

        for (uint256 i = 0; i < length; ++i) {
            uint256 tokenId = tokenIds[i];
            locks[i] = _getLockInfo(tokenId);
            rewards[i] = _getRewardSummary(tokenId, rewardTokens);
        }
    }

    /**
     * @notice Get detailed lock information for a token
     * @param tokenId The veNFT token ID
     * @return LockInfo Detailed lock information
     */
    function _getLockInfo(uint256 tokenId) internal view returns (LockInfo memory) {
        IDustLock.LockedBalance memory locked = DUST_LOCK.locked(tokenId);
        address owner = DUST_LOCK.ownerOf(tokenId);
        uint256 votingPower = DUST_LOCK.balanceOfNFT(tokenId);
        address rewardReceiver = REVENUE_REWARD.tokenRewardReceiver(tokenId);

        LockInfo memory info;
        info.tokenId = tokenId;
        info.amount = uint256(locked.amount);
        info.end = locked.end;
        info.effectiveStart = locked.effectiveStart;
        info.isPermanent = locked.isPermanent;
        info.votingPower = votingPower;
        info.rewardReceiver = rewardReceiver;
        info.owner = owner;

        return info;
    }

    /**
     * @notice Get reward summary for a token
     * @param tokenId The veNFT token ID
     * @param rewardTokens Array of reward token addresses
     * @return RewardSummary Reward summary for the token
     */
    function _getRewardSummary(uint256 tokenId, address[] memory rewardTokens)
        internal
        view
        returns (RewardSummary memory)
    {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;

        uint256 length = rewardTokens.length;
        uint256[] memory revenueRewardsResult = new uint256[](length);

        if (rewardTokens.length > 0) {
            address[] memory sortedRewardTokens = NeverlandUiArrayLibrary.sortAndDedupAddresses(
                NeverlandUiArrayLibrary.copyAddressSlice(rewardTokens, 0, rewardTokens.length)
            );
            uint256 maxTokens = REVENUE_REWARD.MAX_TOKENS();
            for (uint256 offset; offset < sortedRewardTokens.length;) {
                uint256 chunkLen = sortedRewardTokens.length - offset;
                if (chunkLen > maxTokens) chunkLen = maxTokens;

                address[] memory chunk = NeverlandUiArrayLibrary.copyAddressSlice(sortedRewardTokens, offset, chunkLen);
                try REVENUE_REWARD.earnedRewardsAll(chunk, tokenIds) returns (
                    uint256[][] memory matrix, uint256[] memory
                ) {
                    if (matrix.length > 0) {
                        for (uint256 c; c < chunkLen;) {
                            for (uint256 j; j < length;) {
                                if (rewardTokens[j] == chunk[c]) {
                                    revenueRewardsResult[j] = matrix[0][c];
                                }
                                unchecked {
                                    ++j;
                                }
                            }
                            unchecked {
                                ++c;
                            }
                        }
                    }
                } catch {}

                offset += chunkLen;
            }
        }

        RewardSummary memory summary;
        summary.tokenId = tokenId;
        summary.revenueRewards = revenueRewardsResult;
        summary.rewardTokens = rewardTokens;

        return summary;
    }

    /**
     * @notice Builds ProtocolMeta using caller-supplied reward-token lists.
     * @param revenueRewardTokensList Pre-fetched REVENUE_REWARD.getRewardTokens() result
     * @param emissionRewardTokensList Pre-fetched DUST_REWARDS_CONTROLLER.getRewardsList() result
     * @return meta Protocol metadata
     */
    function _getProtocolMeta(address[] memory revenueRewardTokensList, address[] memory emissionRewardTokensList)
        internal
        view
        returns (ProtocolMeta memory meta)
    {
        meta.dustLock = address(DUST_LOCK);
        meta.revenueReward = address(REVENUE_REWARD);
        meta.dustRewardsController = address(DUST_REWARDS_CONTROLLER);
        meta.dustOracle = address(DUST_HELPER);
        meta.earlyWithdrawPenalty = DUST_LOCK.earlyWithdrawPenalty();
        meta.minLockAmount = DUST_LOCK.minLockAmount();
        try REVENUE_REWARD.rewardDistributor() returns (address rd) {
            meta.rewardDistributor = rd;
        } catch {
            meta.rewardDistributor = address(0);
        }
        meta.revenueRewardTokens = revenueRewardTokensList;
        meta.emissionRewardTokens = emissionRewardTokensList;
        meta.emissionStrategies = new address[](meta.emissionRewardTokens.length);
        for (uint256 i; i < meta.emissionRewardTokens.length;) {
            meta.emissionStrategies[i] = DUST_REWARDS_CONTROLLER.getTransferStrategy(meta.emissionRewardTokens[i]);
            unchecked {
                ++i;
            }
        }
    }
}
