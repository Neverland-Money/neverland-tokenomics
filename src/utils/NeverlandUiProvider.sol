// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPriceOracleGetter} from "@aave/core-v3/contracts/interfaces/IPriceOracleGetter.sol";

import {IDustLock} from "../interfaces/IDustLock.sol";
import {INeverlandUiRevenueReward as IRevenueReward} from "../interfaces/INeverlandUiRevenueReward.sol";
import {IUserVaultFactory} from "../interfaces/IUserVaultFactory.sol";
import {IDustRewardsController} from "../interfaces/IDustRewardsController.sol";
import {INeverlandUiProvider} from "../interfaces/INeverlandUiProvider.sol";
import {INeverlandDustHelper} from "../interfaces/INeverlandDustHelper.sol";

import {CommonChecksLibrary} from "../libraries/CommonChecksLibrary.sol";
import {EpochTimeLibrary} from "../libraries/EpochTimeLibrary.sol";
import {Erc20BalanceLibrary} from "../libraries/Erc20BalanceLibrary.sol";
import {NeverlandUiEmissionLibrary} from "./libraries/NeverlandUiEmissionLibrary.sol";

/**
 * @title NeverlandUiProvider
 * @author Neverland
 * @notice Aggregates data from DustLock, RevenueReward, and DustRewardsController for efficient UI queries
 * @dev This contract is purely for data aggregation and contains no state-changing functions
 */
contract NeverlandUiProvider is INeverlandUiProvider {
    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev USD oracle unit (8 decimals)
    uint256 private constant USD_PRICE_UNIT = 1e8;

    /// @dev Minimum raw DustLock enumeration slots scanned by one paginated call.
    uint256 private constant MIN_RAW_TOKEN_SCAN_PER_CALL = 32;

    /// @dev Maximum raw DustLock enumeration slots scanned by one paginated call.
    uint256 private constant MAX_RAW_TOKEN_SCAN_PER_CALL = 1024;

    /// @dev Raw slots scanned per requested valid token before applying the maximum scan cap.
    uint256 private constant RAW_TOKEN_SCAN_MULTIPLIER = 32;

    /// @dev Deployed isolated Pendle AUSD pool provider. Used only while controller-side asset enumeration is unavailable.
    address private constant PENDLE_AUSD_POOL_ADDRESSES_PROVIDER = 0xb80397A931FcFdA3aC999a3a5639C328Dc72A58F;

    /*//////////////////////////////////////////////////////////////
                          IMMUTABLE CONTRACTS
    //////////////////////////////////////////////////////////////*/

    /// @dev DustLock contract for veNFT and voting power data
    IDustLock public immutable DUST_LOCK;

    /// @dev RevenueReward contract for revenue distribution data
    IRevenueReward public immutable REVENUE_REWARD;

    /// @dev DustRewardsController contract for emission rewards data
    IDustRewardsController public immutable DUST_REWARDS_CONTROLLER;

    /// @dev DustOracle contract for DUST price data
    INeverlandDustHelper public immutable DUST_HELPER;

    /// @dev Aave Lending Pool Address Provider for protocol integration
    IPoolAddressesProvider public immutable AAVE_LENDING_POOL_ADDRESS_PROVIDER;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the NeverlandUiProvider with core contract addresses
     * @param _dustLock Address of the DustLock contract
     * @param _revenueReward Address of the RevenueReward contract
     * @param _dustRewardsController Address of the DustRewardsController contract
     * @param _dustOracle Address of the DUST price oracle
     * @param _aaveLendingPoolAddressProvider Address of the Aave Lending Pool Address Provider
     */
    constructor(
        address _dustLock,
        address _revenueReward,
        address _dustRewardsController,
        address _dustOracle,
        address _aaveLendingPoolAddressProvider
    ) {
        CommonChecksLibrary.revertIfZeroAddress(_dustLock);
        CommonChecksLibrary.revertIfZeroAddress(_revenueReward);
        CommonChecksLibrary.revertIfZeroAddress(_dustRewardsController);
        CommonChecksLibrary.revertIfZeroAddress(_dustOracle);
        CommonChecksLibrary.revertIfZeroAddress(_aaveLendingPoolAddressProvider);

        DUST_LOCK = IDustLock(_dustLock);
        REVENUE_REWARD = IRevenueReward(_revenueReward);
        DUST_REWARDS_CONTROLLER = IDustRewardsController(_dustRewardsController);
        DUST_HELPER = INeverlandDustHelper(_dustOracle);
        AAVE_LENDING_POOL_ADDRESS_PROVIDER = IPoolAddressesProvider(_aaveLendingPoolAddressProvider);
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

        (uint256[] memory tokenIds, uint256 tokenCount, uint256 nextRawOffset, bool hasMore) =
            _getValidatedOwnedTokenPage(user, offset, limit);

        (LockInfo[] memory locks, RewardSummary[] memory rewardSummaries) = _getBatchTokenDetailsInternal(tokenIds);

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

    /// @inheritdoc INeverlandUiProvider
    function getGlobalStats() public view override returns (GlobalStats memory) {
        address[] memory rewardTokens = REVENUE_REWARD.getRewardTokens();
        uint256[] memory totalRewardsPerToken = new uint256[](rewardTokens.length);

        for (uint256 i; i < rewardTokens.length;) {
            totalRewardsPerToken[i] = REVENUE_REWARD.totalRewardsPerToken(rewardTokens[i]);
            unchecked {
                ++i;
            }
        }

        GlobalStats memory stats;
        stats.totalSupply = DUST_LOCK.supply();
        stats.totalVotingPower = DUST_LOCK.totalSupplyAt(block.timestamp);
        stats.permanentLockBalance = DUST_LOCK.permanentLockBalance();
        stats.rewardTokens = rewardTokens;
        stats.totalRewardsPerToken = totalRewardsPerToken;
        stats.epoch = DUST_LOCK.epoch();
        stats.activeTokenCount = DUST_LOCK.tokenId();
        return stats;
    }

    /// @inheritdoc INeverlandUiProvider
    function getUserRewardsSummary(address user, address[] calldata rewardTokens)
        public
        view
        override
        returns (UserRewardsSummary memory summary)
    {
        CommonChecksLibrary.revertIfZeroAddress(user);

        return _getUserRewardsSummaryInternal(user, rewardTokens);
    }

    /**
     * @notice Internal function to get user rewards summary
     * @param user The user address
     * @param rewardTokens Array of reward token addresses
     * @return summary User rewards summary
     */
    function _getUserRewardsSummaryInternal(address user, address[] memory rewardTokens)
        internal
        view
        returns (UserRewardsSummary memory summary)
    {
        uint256[] memory tokenIds = _getUserRelatedTokenIds(user);
        uint256 tokenCount = tokenIds.length;
        uint256 rewardTokenCount = rewardTokens.length;

        summary.totalRevenue = new uint256[](rewardTokenCount);
        summary.totalEmissions = new uint256[](rewardTokenCount);

        if (tokenCount > 0 && rewardTokenCount > 0) {
            _fillUserRevenueRewards(summary, rewardTokens, tokenIds);
        }

        IUserVaultFactory vaultFactory = REVENUE_REWARD.userVaultFactory();
        address vault = address(vaultFactory) == address(0) ? address(0) : vaultFactory.getUserVault(user);

        address[] memory emissionTokens = DUST_REWARDS_CONTROLLER.getRewardsList();
        for (uint256 j; j < rewardTokenCount;) {
            address rewardToken = rewardTokens[j];

            uint256 pending = REVENUE_REWARD.pendingRewards(rewardToken, user);
            if (vault != address(0)) {
                pending += REVENUE_REWARD.pendingRewards(rewardToken, vault);
            }
            summary.totalRevenue[j] += pending;

            for (uint256 k; k < emissionTokens.length;) {
                if (emissionTokens[k] == rewardToken) {
                    summary.totalEmissions[j] = _getUserEmissionRewards(user, rewardToken);
                    break;
                }
                unchecked {
                    ++k;
                }
            }
            unchecked {
                ++j;
            }
        }
    }

    /**
     * @notice Get all tokenIds that contribute rewards to `user`: owned tokens and tokens forwarding rewards to `user` (self-repay loan)
     * @param user The user address
     * @return ids Array of tokenIds
     */
    function _getUserRelatedTokenIds(address user) internal view returns (uint256[] memory ids) {
        uint256[] memory ownedTokenIds = _getValidatedOwnedTokenIds(user);
        uint256 owned = ownedTokenIds.length;
        uint256[] memory srl = REVENUE_REWARD.getUserTokensWithSelfRepayingLoan(user);

        if (owned == 0 && srl.length == 0) return new uint256[](0);

        // Preallocate max size, then shrink
        uint256[] memory tmp = new uint256[](owned + srl.length);
        uint256 n = 0;

        // Add owned tokenIds (unique by ERC721 invariant)
        for (uint256 i; i < owned;) {
            tmp[n] = ownedTokenIds[i];
            unchecked {
                ++n;
            }
            unchecked {
                ++i;
            }
        }

        // Add SRL tokenIds, dedup against already added entries (SRL itself is an EnumerableSet -> unique)
        if (srl.length > 0) {
            for (uint256 j; j < srl.length;) {
                uint256 tokenId = srl[j];
                bool duplicate = false;
                for (uint256 k; k < n;) {
                    if (tmp[k] == tokenId) {
                        duplicate = true;
                        break;
                    }
                    unchecked {
                        ++k;
                    }
                }
                if (!duplicate) {
                    tmp[n] = tokenId;
                    unchecked {
                        ++n;
                    }
                }
                unchecked {
                    ++j;
                }
            }
        }

        // Resize to actual length
        ids = new uint256[](n);
        for (uint256 i; i < n;) {
            ids[i] = tmp[i];
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Get currently owned tokenIds from DustLock's enumerable list, skipping stale entries.
     * @param user The owner address to enumerate.
     * @return ids Array of tokenIds still owned by `user`.
     */
    function _getValidatedOwnedTokenIds(address user) internal view returns (uint256[] memory ids) {
        uint256 tokenCount = DUST_LOCK.balanceOf(user);
        uint256 upperBound = _ownedTokenIndexUpperBound(tokenCount);
        uint256[] memory tmp = new uint256[](tokenCount);
        uint256 n;
        for (uint256 i; n < tokenCount && i < upperBound;) {
            try DUST_LOCK.ownerToNFTokenIdList(user, i) returns (uint256 tokenId) {
                if (_tokenIsOwnedByUser(user, tokenId)) {
                    tmp[n] = tokenId;
                    unchecked {
                        ++n;
                    }
                }
            } catch {
                // Skip stale/corrupt enumerable entries and return surviving tokenIds.
            }
            unchecked {
                ++i;
            }
        }

        ids = new uint256[](n);
        for (uint256 i; i < n;) {
            ids[i] = tmp[i];
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Returns a compacted page of owned token ids, skipping stale raw enumerable slots.
     * @param user The owner address to enumerate.
     * @param offset Raw enumerable index to start scanning from.
     * @param limit Maximum valid token ids to collect.
     * @return ids Valid token ids for this page.
     * @return tokenCount Current live balance reported by DustLock.
     * @return nextRawOffset Raw enumerable index for the next page.
     * @return hasMore Whether this page left expected live entries or sparse raw slots unscanned.
     */
    function _getValidatedOwnedTokenPage(address user, uint256 offset, uint256 limit)
        internal
        view
        returns (uint256[] memory ids, uint256 tokenCount, uint256 nextRawOffset, bool hasMore)
    {
        tokenCount = DUST_LOCK.balanceOf(user);
        uint256 upperBound = _ownedTokenIndexUpperBound(tokenCount);
        nextRawOffset = offset > upperBound ? upperBound : offset;
        uint256 scanStart = nextRawOffset;
        uint256 liveSlotsRemaining = tokenCount;
        if (scanStart < tokenCount) liveSlotsRemaining = tokenCount - scanStart;
        uint256 pageLen = limit < liveSlotsRemaining ? limit : liveSlotsRemaining;

        if (pageLen == 0) return (new uint256[](0), tokenCount, nextRawOffset, false);

        uint256 scanEnd = _rawTokenScanEnd(nextRawOffset, upperBound, limit);

        // Clamp the page buffer to the raw-scan budget so a large `limit` can't over-allocate `tmp`.
        if (scanEnd > nextRawOffset) {
            uint256 scanRange = scanEnd - nextRawOffset;
            if (scanRange < pageLen) pageLen = scanRange;
        } else {
            pageLen = 0;
        }

        uint256[] memory tmp = new uint256[](pageLen);
        uint256 n;
        while (n < pageLen && nextRawOffset < scanEnd) {
            try DUST_LOCK.ownerToNFTokenIdList(user, nextRawOffset) returns (uint256 tokenId) {
                if (_tokenIsOwnedByUser(user, tokenId)) {
                    tmp[n] = tokenId;
                    unchecked {
                        ++n;
                    }
                }
            } catch {
                // Skip stale/corrupt enumerable entries and continue until the page is filled.
            }
            unchecked {
                ++nextRawOffset;
            }
        }
        bool returnedEveryCompactEntry =
            scanStart < tokenCount && nextRawOffset >= tokenCount && n == liveSlotsRemaining;
        hasMore = nextRawOffset < upperBound && !returnedEveryCompactEntry;

        ids = new uint256[](n);
        for (uint256 i; i < n;) {
            ids[i] = tmp[i];
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Returns a bounded raw enumerable index limit for owned-token scans.
     * @dev `balanceOf` counts live tokens, not max raw index; use DustLock.tokenId() as the global bound, falling back to `tokenCount` if unreadable.
     * @param tokenCount Current live balance reported by DustLock.
     * @return upperBound Exclusive raw index upper bound.
     */
    function _ownedTokenIndexUpperBound(uint256 tokenCount) internal view returns (uint256 upperBound) {
        if (tokenCount == 0) return 0;
        try DUST_LOCK.tokenId() returns (uint256 maxTokenId) {
            upperBound = maxTokenId;
        } catch {
            upperBound = tokenCount;
        }
        if (upperBound < tokenCount) upperBound = tokenCount;
    }

    /**
     * @notice Returns the exclusive raw index boundary for one paginated scan.
     * @param start Raw enumerable index where the scan starts.
     * @param upperBound Global exclusive raw index upper bound.
     * @param limit Requested valid-token page size.
     * @return scanEnd Exclusive raw index where this call must stop scanning.
     */
    function _rawTokenScanEnd(uint256 start, uint256 upperBound, uint256 limit)
        internal
        pure
        returns (uint256 scanEnd)
    {
        if (start >= upperBound || limit == 0) return start;

        uint256 scanBudget;
        unchecked {
            scanBudget = limit > type(uint256).max / RAW_TOKEN_SCAN_MULTIPLIER
                ? type(uint256).max
                : limit * RAW_TOKEN_SCAN_MULTIPLIER;
        }
        scanBudget = scanBudget < MIN_RAW_TOKEN_SCAN_PER_CALL ? MIN_RAW_TOKEN_SCAN_PER_CALL : scanBudget;
        if (scanBudget > MAX_RAW_TOKEN_SCAN_PER_CALL) {
            scanBudget = MAX_RAW_TOKEN_SCAN_PER_CALL;
        }

        uint256 remaining = upperBound - start;

        return start + (scanBudget < remaining ? scanBudget : remaining);
    }

    /**
     * @notice Returns true only when `tokenId` is nonzero and DustLock still reports `user` as owner.
     * @param user Expected owner address.
     * @param tokenId Token id to verify.
     * @return ownedByUser True when the token currently belongs to `user`.
     */
    function _tokenIsOwnedByUser(address user, uint256 tokenId) internal view returns (bool ownedByUser) {
        if (tokenId == 0) return false;
        try DUST_LOCK.ownerOf(tokenId) returns (address owner) {
            return owner == user;
        } catch {
            return false;
        }
    }

    /**
     * @notice Accumulates revenue rewards across RevenueReward's bounded preview chunks.
     * @param summary Summary object whose `totalRevenue` array is updated in memory.
     * @param rewardTokens User-requested reward-token order.
     * @param tokenIds User-related veNFT ids to include in the totals.
     */
    function _fillUserRevenueRewards(
        UserRewardsSummary memory summary,
        address[] memory rewardTokens,
        uint256[] memory tokenIds
    ) internal view {
        address[] memory sortedRevTokens = _sortAndDedupAddresses(REVENUE_REWARD.getRewardTokens());
        uint256[] memory sortedTokenIds = _sortAndDedupUint256(tokenIds);
        if (sortedRevTokens.length == 0 || sortedTokenIds.length == 0) return;

        uint256 maxTokens = REVENUE_REWARD.MAX_TOKENS();
        uint256 maxTokenIds = REVENUE_REWARD.MAX_TOKENIDS();
        if (maxTokens == 0 || maxTokenIds == 0) return;

        for (uint256 tokenOffset; tokenOffset < sortedTokenIds.length;) {
            uint256 tokenChunkLen = sortedTokenIds.length - tokenOffset;
            if (tokenChunkLen > maxTokenIds) tokenChunkLen = maxTokenIds;
            uint256[] memory tokenChunk = _copyUint256Slice(sortedTokenIds, tokenOffset, tokenChunkLen);

            for (uint256 rewardOffset; rewardOffset < sortedRevTokens.length;) {
                uint256 rewardChunkLen = sortedRevTokens.length - rewardOffset;
                if (rewardChunkLen > maxTokens) rewardChunkLen = maxTokens;
                address[] memory rewardChunk = _copyAddressSlice(sortedRevTokens, rewardOffset, rewardChunkLen);

                try REVENUE_REWARD.earnedRewardsAll(rewardChunk, tokenChunk) returns (
                    uint256[][] memory, uint256[] memory totalsPerToken
                ) {
                    _accumulateRevenueTotals(summary, rewardTokens, rewardChunk, totalsPerToken);
                } catch {
                    // Preserve fail-soft summary semantics for chunks that cannot be previewed.
                }

                rewardOffset += rewardChunkLen;
            }

            tokenOffset += tokenChunkLen;
        }
    }

    /**
     * @notice Adds a RevenueReward chunk's totals into a user summary in caller-requested token order.
     * @param summary Summary object whose `totalRevenue` array is updated in memory.
     * @param rewardTokens User-requested reward-token order.
     * @param rewardChunk Reward-token chunk returned by the preview call.
     * @param totalsPerToken Totals parallel to `rewardChunk`.
     */
    function _accumulateRevenueTotals(
        UserRewardsSummary memory summary,
        address[] memory rewardTokens,
        address[] memory rewardChunk,
        uint256[] memory totalsPerToken
    ) internal pure {
        for (uint256 r; r < rewardChunk.length;) {
            address rewardToken = rewardChunk[r];
            if (r < totalsPerToken.length) {
                for (uint256 j; j < rewardTokens.length;) {
                    if (rewardTokens[j] == rewardToken) {
                        summary.totalRevenue[j] += totalsPerToken[r];
                    }
                    unchecked {
                        ++j;
                    }
                }
            }
            unchecked {
                ++r;
            }
        }
    }

    /**
     * @notice Sorts and deduplicates address arrays in ascending order
     * @param arr Input address array (mutated in-place during sorting)
     * @return sorted Sorted array with unique addresses only
     */
    function _sortAndDedupAddresses(address[] memory arr) internal pure returns (address[] memory sorted) {
        uint256 len = arr.length;
        if (len == 0) return new address[](0);

        // In-place insertion sort
        for (uint256 i = 1; i < len; ++i) {
            address key = arr[i];
            uint256 j = i;
            while (j > 0 && arr[j - 1] > key) {
                arr[j] = arr[j - 1];
                unchecked {
                    --j;
                }
            }
            arr[j] = key;
        }

        // Dedup into new array
        sorted = new address[](len);
        uint256 n = 0;
        for (uint256 i = 0; i < len; ++i) {
            if (i == 0 || arr[i] != arr[i - 1]) {
                sorted[n] = arr[i];
                unchecked {
                    ++n;
                }
            }
        }

        assembly ("memory-safe") {
            mstore(sorted, n)
        }
    }

    /**
     * @notice Sorts and deduplicates uint256 arrays in ascending order
     * @param arr Input uint256 array (mutated in-place during sorting)
     * @return sorted Sorted array with unique values only
     */
    function _sortAndDedupUint256(uint256[] memory arr) internal pure returns (uint256[] memory sorted) {
        uint256 len = arr.length;
        if (len == 0) return new uint256[](0);

        // In-place insertion sort
        for (uint256 i = 1; i < len; ++i) {
            uint256 key = arr[i];
            uint256 j = i;
            while (j > 0 && arr[j - 1] > key) {
                arr[j] = arr[j - 1];
                unchecked {
                    --j;
                }
            }
            arr[j] = key;
        }

        // Dedup into new array
        sorted = new uint256[](len);
        uint256 n = 0;
        for (uint256 i = 0; i < len; ++i) {
            if (i == 0 || arr[i] != arr[i - 1]) {
                sorted[n] = arr[i];
                unchecked {
                    ++n;
                }
            }
        }

        assembly ("memory-safe") {
            mstore(sorted, n)
        }
    }

    /// @inheritdoc INeverlandUiProvider
    function getUserEmissionBreakdown(address user, address rewardToken)
        public
        view
        override
        returns (UserEmissionAsset[] memory breakdown)
    {
        CommonChecksLibrary.revertIfZeroAddress(user);

        return NeverlandUiEmissionLibrary.getUserEmissionBreakdown(
            DUST_REWARDS_CONTROLLER,
            AAVE_LENDING_POOL_ADDRESS_PROVIDER,
            PENDLE_AUSD_POOL_ADDRESSES_PROVIDER,
            user,
            rewardToken
        );
    }

    /// @inheritdoc INeverlandUiProvider
    function getUserEmissions(address user)
        public
        view
        override
        returns (address[] memory rewardTokens, uint256[] memory totalRewards)
    {
        CommonChecksLibrary.revertIfZeroAddress(user);

        return NeverlandUiEmissionLibrary.getUserEmissions(
            DUST_REWARDS_CONTROLLER, AAVE_LENDING_POOL_ADDRESS_PROVIDER, PENDLE_AUSD_POOL_ADDRESSES_PROVIDER, user
        );
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

        uint256[] memory ownedTokenIds = _getValidatedOwnedTokenIds(user);
        uint256 tokenCount = ownedTokenIds.length;
        uint256 unlockCount = 0;
        for (uint256 i; i < tokenCount;) {
            IDustLock.LockedBalance memory locked = DUST_LOCK.locked(ownedTokenIds[i]);
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
            IDustLock.LockedBalance memory locked = DUST_LOCK.locked(tokenId);

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
        CommonChecksLibrary.revertIfZeroAddress(user);

        return _essentialFromDashboard(user, getUserDashboard(user, offset, limit));
    }

    /// @inheritdoc INeverlandUiProvider
    function getExtendedUserView(address user, uint256 offset, uint256 limit)
        public
        view
        override
        returns (ExtendedUserView memory ext)
    {
        CommonChecksLibrary.revertIfZeroAddress(user);

        UserDashboardData memory pageDash = getUserDashboard(user, offset, limit);
        ext.unlockSchedule = _unlockScheduleFromLocks(pageDash.locks, pageDash.tokenIds);
        ext.allPrices = getAllPrices();
    }

    /**
     * @notice Builds the essential user view from an already-computed dashboard page.
     * @dev Lets callers (notably the full bundle) page a user's tokens once and reuse the result.
     * @param user Token owner being viewed
     * @param dash Pre-computed dashboard page for `user`
     * @return v Essential user view (dashboard + global stats + emissions + market)
     */
    function _essentialFromDashboard(address user, UserDashboardData memory dash)
        internal
        view
        returns (EssentialUserView memory v)
    {
        v.user = dash;
        v.globalStats = getGlobalStats();
        (v.emissions.rewardTokens, v.emissions.totalRewards) = getUserEmissions(user);
        v.marketData = getMarketData();
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

    /*//////////////////////////////////////////////////////////////
                         COMPREHENSIVE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandUiProvider
    function getMarketData() public view override returns (MarketData memory) {
        address[] memory rewardTokens = REVENUE_REWARD.getRewardTokens();
        uint256 length = rewardTokens.length;

        uint256[] memory balances = new uint256[](length);
        uint256[] memory rates = new uint256[](length);
        uint256[] memory epochRewards = new uint256[](length);
        uint256[] memory nextEpochRewards = new uint256[](length);
        uint256[] memory followingEpochRewards = new uint256[](length);

        uint256 currentEpoch = EpochTimeLibrary.epochStart(block.timestamp);
        uint256 nextEpoch = EpochTimeLibrary.epochNext(block.timestamp);
        // DURATION == WEEK, so this is the epoch-after-next bucket funded by notifyRewardAmountForFollowingEpoch.
        uint256 followingEpoch = EpochTimeLibrary.epochNext(nextEpoch);

        for (uint256 i; i < length;) {
            address token = rewardTokens[i];
            (bool ok, uint256 bal) = Erc20BalanceLibrary.tryBalanceOf(token, address(REVENUE_REWARD));
            if (!ok) revert BalanceUnreadable(token, address(REVENUE_REWARD));
            balances[i] = bal;

            uint256 perEpoch = REVENUE_REWARD.tokenRewardsPerEpoch(token, currentEpoch);
            rates[i] = perEpoch;
            epochRewards[i] = perEpoch;
            nextEpochRewards[i] = REVENUE_REWARD.tokenRewardsPerEpoch(token, nextEpoch);
            followingEpochRewards[i] = REVENUE_REWARD.tokenRewardsPerEpoch(token, followingEpoch);
            unchecked {
                ++i;
            }
        }

        MarketData memory m;
        m.rewardTokens = rewardTokens;
        m.rewardTokenBalances = balances;
        m.distributionRates = rates;
        m.nextEpochTimestamp = nextEpoch;
        m.currentEpoch = DUST_LOCK.epoch();
        m.epochRewards = epochRewards;
        m.nextEpochRewards = nextEpochRewards;
        m.totalValueLockedUSD = _getDustValueInUSDOrZero(DUST_LOCK.supply());
        m.followingEpochRewards = followingEpochRewards;

        return m;
    }

    /// @inheritdoc INeverlandUiProvider
    function getAllPrices() public view override returns (PriceData memory) {
        address[] memory rewardTokens = REVENUE_REWARD.getRewardTokens();
        uint256 length = rewardTokens.length + 1;

        PriceData memory p;
        p.tokens = new address[](length);
        p.prices = new uint256[](length);
        p.lastUpdated = new uint256[](length);

        p.tokens[0] = DUST_LOCK.token();
        p.prices[0] = _getDustPriceOrZero();
        p.lastUpdated[0] = _getDustLatestTimestampOrZero();
        for (uint256 i; i < rewardTokens.length;) {
            uint256 idx = i + 1;
            address t = rewardTokens[i];
            uint256 price = _getTokenPriceInUSD(t);
            p.tokens[idx] = t;
            p.prices[idx] = price;
            if (price != 0) {
                p.lastUpdated[idx] = t == DUST_LOCK.token() ? _getDustLatestTimestampOrZero() : block.timestamp;
            }
            unchecked {
                ++i;
            }
        }

        return p;
    }

    /// @inheritdoc INeverlandUiProvider
    function getNetworkData() public view override returns (NetworkData memory) {
        NetworkData memory n;
        n.currentBlock = block.number;
        n.currentTimestamp = block.timestamp;
        n.gasPrice = tx.gasprice;
        return n;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Internal function to get batch token details
     * @param tokenIds Array of veNFT token IDs
     * @return locks Array of detailed lock information
     * @return rewards Array of reward summaries
     */
    function _getBatchTokenDetailsInternal(uint256[] memory tokenIds)
        internal
        view
        returns (LockInfo[] memory locks, RewardSummary[] memory rewards)
    {
        uint256 length = tokenIds.length;
        locks = new LockInfo[](length);
        rewards = new RewardSummary[](length);

        address[] memory rewardTokens = REVENUE_REWARD.getRewardTokens();
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
            address[] memory sortedRewardTokens = _sortAndDedupAddresses(_copyAddressArray(rewardTokens));
            uint256 maxTokens = REVENUE_REWARD.MAX_TOKENS();
            for (uint256 offset; offset < sortedRewardTokens.length;) {
                uint256 chunkLen = sortedRewardTokens.length - offset;
                if (chunkLen > maxTokens) chunkLen = maxTokens;

                address[] memory chunk = _copyAddressSlice(sortedRewardTokens, offset, chunkLen);
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
     * @notice Returns a fresh in-memory copy of `arr` so callers can mutate without aliasing.
     * @dev Used to detach paginated view results from cached arrays returned by upstream contracts.
     * @param arr Source array to copy.
     * @return copy Newly-allocated array with the same length and elements as `arr`.
     */
    function _copyAddressArray(address[] memory arr) internal pure returns (address[] memory copy) {
        uint256 len = arr.length;
        copy = new address[](len);
        for (uint256 i; i < len;) {
            copy[i] = arr[i];
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Returns a fresh in-memory `len`-element slice of `arr` starting at `offset`.
     * @dev Caller is responsible for ensuring `offset + len <= arr.length`; out-of-bounds reads
     *      revert via the memory access check.
     * @param arr Source array to slice.
     * @param offset Index of the first element to copy.
     * @param len Number of elements to copy.
     * @return slice Newly-allocated array containing `arr[offset..offset+len)`.
     */
    function _copyAddressSlice(address[] memory arr, uint256 offset, uint256 len)
        internal
        pure
        returns (address[] memory slice)
    {
        slice = new address[](len);
        for (uint256 i; i < len;) {
            slice[i] = arr[offset + i];
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Returns a fresh in-memory `len`-element slice of `arr` starting at `offset`.
     * @param arr Source array to slice.
     * @param offset Index of the first element to copy.
     * @param len Number of elements to copy.
     * @return slice Newly-allocated array containing `arr[offset..offset+len)`.
     */
    function _copyUint256Slice(uint256[] memory arr, uint256 offset, uint256 len)
        internal
        pure
        returns (uint256[] memory slice)
    {
        slice = new uint256[](len);
        for (uint256 i; i < len;) {
            slice[i] = arr[offset + i];
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc INeverlandUiProvider
    function getProtocolMeta() public view override returns (ProtocolMeta memory meta) {
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
        meta.revenueRewardTokens = REVENUE_REWARD.getRewardTokens();
        meta.emissionRewardTokens = DUST_REWARDS_CONTROLLER.getRewardsList();
        meta.emissionStrategies = new address[](meta.emissionRewardTokens.length);
        for (uint256 i; i < meta.emissionRewardTokens.length;) {
            meta.emissionStrategies[i] = DUST_REWARDS_CONTROLLER.getTransferStrategy(meta.emissionRewardTokens[i]);
            unchecked {
                ++i;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                         ONE-CALL UI AGGREGATES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandUiProvider
    function getUiBootstrap() public view override returns (UiBootstrap memory boot) {
        boot.meta = getProtocolMeta();
        boot.globalStats = getGlobalStats();
        boot.marketData = getMarketData();
        boot.allPrices = getAllPrices();
        boot.network = getNetworkData();
    }

    /// @inheritdoc INeverlandUiProvider
    function getUiFullBundle(address user, uint256 offset, uint256 limit)
        public
        view
        override
        returns (UiFullBundle memory bundle)
    {
        CommonChecksLibrary.revertIfZeroAddress(user);

        UserDashboardData memory dash = getUserDashboard(user, offset, limit);
        bundle.meta = getProtocolMeta();
        bundle.essential = _essentialFromDashboard(user, dash);
        bundle.extended.unlockSchedule = _unlockScheduleFromLocks(dash.locks, dash.tokenIds);
        bundle.extended.allPrices = getAllPrices();
        bundle.network = getNetworkData();
    }

    /*//////////////////////////////////////////////////////////////
                         EMISSION REWARD HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get user's total emission rewards for a specific reward token
     * @param user User address
     * @param rewardToken Reward token address
     * @return totalRewards Total emission rewards for the user
     */
    function _getUserEmissionRewards(address user, address rewardToken) internal view returns (uint256 totalRewards) {
        return NeverlandUiEmissionLibrary.getUserEmissionRewards(
            DUST_REWARDS_CONTROLLER,
            AAVE_LENDING_POOL_ADDRESS_PROVIDER,
            PENDLE_AUSD_POOL_ADDRESSES_PROVIDER,
            user,
            rewardToken
        );
    }

    /**
     * @notice Returns token USD price (8 decimals) using DustHelper for DUST and Aave Oracle for pool assets
     * @dev Returns 0 if price is unavailable (graceful degradation) to prevent UI DoS from missing oracle prices
     * @param token The token address
     * @return price USD price (8 decimals), or 0 if unavailable
     */
    function _getTokenPriceInUSD(address token) internal view returns (uint256 price) {
        if (token == DUST_LOCK.token()) return _getDustPriceOrZero();

        address oracleAddr;
        try AAVE_LENDING_POOL_ADDRESS_PROVIDER.getPriceOracle() returns (address resolvedOracle) {
            oracleAddr = resolvedOracle;
        } catch {
            return 0;
        }
        if (oracleAddr == address(0)) return 0;

        IPriceOracleGetter oracle = IPriceOracleGetter(oracleAddr);
        uint256 unit;
        try oracle.BASE_CURRENCY_UNIT() returns (uint256 u) {
            unit = u;
        } catch {
            return 0;
        }
        if (unit < 1) return 0;

        uint256 p;
        try oracle.getAssetPrice(token) returns (uint256 price_) {
            p = price_;
        } catch {
            return 0;
        }
        if (p < 1) return 0;

        if (unit == USD_PRICE_UNIT) return p;
        if (p > type(uint256).max / USD_PRICE_UNIT) return 0;
        return (p * USD_PRICE_UNIT) / unit;
    }

    /**
     * @notice Reads the DUST helper price without letting helper/oracle failures revert UI bundles.
     * @return price DUST USD price in 8 decimals, or zero when unavailable.
     */
    function _getDustPriceOrZero() internal view returns (uint256 price) {
        try DUST_HELPER.getPrice() returns (
            uint256 dustPrice,
            bool /* fromOracle */
        ) {
            return dustPrice;
        } catch {
            return 0;
        }
    }

    /**
     * @notice Reads the DUST helper timestamp without letting helper/oracle failures revert UI bundles.
     * @return timestamp Latest DUST helper timestamp, or zero when unavailable.
     */
    function _getDustLatestTimestampOrZero() internal view returns (uint256 timestamp) {
        try DUST_HELPER.latestTimestamp() returns (uint256 latestTimestamp) {
            return latestTimestamp;
        } catch {
            return 0;
        }
    }

    /**
     * @notice Converts DUST amount to USD without letting helper/oracle failures revert UI bundles.
     * @param dustAmount DUST amount to value.
     * @return valueUsd USD value in helper decimals, or zero when unavailable.
     */
    function _getDustValueInUSDOrZero(uint256 dustAmount) internal view returns (uint256 valueUsd) {
        try DUST_HELPER.getDustValueInUSD(dustAmount) returns (uint256 value) {
            return value;
        } catch {
            return 0;
        }
    }
}
