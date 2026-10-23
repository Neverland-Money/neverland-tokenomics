// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IDustRewardsController} from "../../interfaces/IDustRewardsController.sol";
import {INeverlandUiProvider} from "../../interfaces/INeverlandUiProvider.sol";
import {INeverlandUiRevenueReward} from "../../interfaces/INeverlandUiRevenueReward.sol";
import {IUserVaultFactory} from "../../interfaces/IUserVaultFactory.sol";

import {NeverlandUiArrayLibrary} from "./NeverlandUiArrayLibrary.sol";
import {NeverlandUiEmissionLibrary} from "./NeverlandUiEmissionLibrary.sol";

/**
 * @title NeverlandUiRewardsSummaryLibrary
 * @author Neverland
 * @notice Linked read-only resolved-rewards-summary engine for `NeverlandUiProvider`.
 * @dev Public library functions are intentionally used here so Solidity links the library instead of
 *      inlining this logic into the UI provider runtime (mirrors `NeverlandUiEmissionLibrary`, added
 *      when the plain + resolved surface together pushed the provider over EIP-170).
 *      The provider delegates its rewards-summary read to this single engine. Generic address-array
 *      algorithms are shared through `NeverlandUiArrayLibrary`; uint256-specific helpers remain local
 *      because Solidity has no generics.
 */
library NeverlandUiRewardsSummaryLibrary {
    /**
     * @dev Per-call context for `_fillRewardTokenRow`, bundled into one memory reference so the row
     *      loop does not carry each field as a separate live local across every iteration.
     * @param user User whose rewards are queried.
     * @param vault UserVault whose deferred rewards are included, or address(0).
     * @param vaultResolved Whether the configured UserVault dependency was read successfully.
     * @param emissionTokens Reward tokens supported by the emission controller.
     * @param emissionTokensResolved Whether the emission-token list was read successfully.
     * @param emissionAssets Cached lending assets included in emission aggregation.
     * @param emissionAssetsResolved Whether the cached asset enumeration was complete.
     * @param revenueReward RevenueReward contract.
     * @param rewardsController DustRewardsController contract.
     */
    struct RewardRowContext {
        address user;
        bool vaultResolved;
        bool emissionTokensResolved;
        bool emissionAssetsResolved;
        address vault;
        address[] emissionTokens;
        address[] emissionAssets;
        INeverlandUiRevenueReward revenueReward;
        IDustRewardsController rewardsController;
    }

    /**
     * @notice Builds the provider's user reward summary with per-row resolution masks.
     * @dev `pendingRewards` reads are fail-soft so one unavailable selector degrades only the affected
     *      row. Numeric totals retain the successful-read semantics while the masks identify partial data.
     * @param revenueReward RevenueReward contract.
     * @param rewardsController DustRewardsController (for the emission-token list and breakdown).
     * @param poolAddressesProviders Every registered lending pool address provider (threaded through
     *        to the emission library, which sums each reward token's emissions across every one).
     * @param user The user address.
     * @param rewardTokens Array of reward token addresses.
     * @param tokenIds User-related veNFT ids (owned + self-repay-routed), pre-computed by the caller.
     * @return summary User rewards summary (identical value semantics to getUserRewardsSummary).
     * @return revenueResolvedMask Bit j set means summary.totalRevenue[j] is fully trustworthy.
     * @return emissionsResolvedMask Bit j set means summary.totalEmissions[j] is trustworthy.
     */
    function getUserRewardsSummaryResolved(
        INeverlandUiRevenueReward revenueReward,
        IDustRewardsController rewardsController,
        address[] memory poolAddressesProviders,
        address user,
        address[] memory rewardTokens,
        uint256[] memory tokenIds
    )
        public
        view
        returns (
            INeverlandUiProvider.UserRewardsSummary memory summary,
            uint256 revenueResolvedMask,
            uint256 emissionsResolvedMask
        )
    {
        uint256 rewardTokenCount = rewardTokens.length;

        summary.totalRevenue = new uint256[](rewardTokenCount);
        summary.totalEmissions = new uint256[](rewardTokenCount);

        uint256 earnedFailedMask;
        if (tokenIds.length > 0 && rewardTokenCount > 0) {
            earnedFailedMask = _fillUserRevenueRewardsResolved(revenueReward, summary, rewardTokens, tokenIds);
        }

        RewardRowContext memory ctx =
            _buildRewardRowContext(revenueReward, rewardsController, poolAddressesProviders, user, rewardTokens);

        uint256 pendingFailedMask;
        uint256 emissionsFailedMask;
        for (uint256 j; j < rewardTokenCount;) {
            (uint256 pendingFailedBit, uint256 emissionsFailedBit) =
                _fillRewardTokenRow(summary, rewardTokens[j], j, ctx);
            pendingFailedMask |= pendingFailedBit;
            emissionsFailedMask |= emissionsFailedBit;
            unchecked {
                ++j;
            }
        }

        uint256 allBitsMask = _lowBitsMask(rewardTokenCount);
        revenueResolvedMask = allBitsMask & ~(earnedFailedMask | pendingFailedMask);
        emissionsResolvedMask = allBitsMask & ~emissionsFailedMask;
    }

    /**
     * @notice Fills `summary`'s row `j` (pending-rewards addition + emissions lookup) for one
     *         reward token, keeping the caller's own stack frame small.
     * @param summary Summary receiving the row totals.
     * @param rewardToken Reward token represented by the row.
     * @param j Row index in the caller-supplied reward-token order.
     * @param ctx Shared per-call reward context.
     * @return pendingFailedBit `1 << j` if either pendingRewards read for this row failed, else 0.
     * @return emissionsFailedBit `1 << j` if this row's emissions read failed, else 0.
     */
    function _fillRewardTokenRow(
        INeverlandUiProvider.UserRewardsSummary memory summary,
        address rewardToken,
        uint256 j,
        RewardRowContext memory ctx
    ) private view returns (uint256 pendingFailedBit, uint256 emissionsFailedBit) {
        uint256 bit = uint256(1) << j;

        (uint256 pending, bool pendingOk) =
            _pendingRewardsResolved(ctx.revenueReward, rewardToken, ctx.user, ctx.vault, ctx.vaultResolved);
        summary.totalRevenue[j] += pending;
        if (!pendingOk) pendingFailedBit = bit;

        /*
         * A reward token not on the emissions list contributes zero emissions with full confidence;
         * there is nothing to read, so it leaves emissionsFailedBit at zero.
         */
        if (!ctx.emissionTokensResolved) {
            emissionsFailedBit = bit;
        } else if (_isEmissionToken(ctx.emissionTokens, rewardToken)) {
            bool emissionResolved;
            (summary.totalEmissions[j], emissionResolved) =
                NeverlandUiEmissionLibrary.getUserEmissionRewardsForAssetsResolved(
                    ctx.rewardsController, ctx.emissionAssets, ctx.emissionAssetsResolved, ctx.user, rewardToken
                );
            if (!emissionResolved) emissionsFailedBit = bit;
        }
    }

    /**
     * @notice Resolves fail-soft reward dependencies and enumerates emission assets once per summary.
     * @param revenueReward RevenueReward contract.
     * @param rewardsController DustRewardsController contract.
     * @param poolAddressesProviders Lending pool providers included in emission aggregation.
     * @param user User whose reward rows are queried.
     * @param rewardTokens Caller-requested reward tokens.
     * @return ctx Cached dependency context shared by every reward-token row.
     */
    function _buildRewardRowContext(
        INeverlandUiRevenueReward revenueReward,
        IDustRewardsController rewardsController,
        address[] memory poolAddressesProviders,
        address user,
        address[] memory rewardTokens
    ) private view returns (RewardRowContext memory ctx) {
        ctx.user = user;
        ctx.revenueReward = revenueReward;
        ctx.rewardsController = rewardsController;
        (ctx.vault, ctx.vaultResolved) = _resolveUserVault(revenueReward, user);
        (ctx.emissionTokens, ctx.emissionTokensResolved) = _getRewardsListResolved(rewardsController);

        if (ctx.emissionTokensResolved && _hasEmissionTokenMatch(ctx.emissionTokens, rewardTokens)) {
            (ctx.emissionAssets, ctx.emissionAssetsResolved) =
                NeverlandUiEmissionLibrary.getAllLendingPoolAssets(rewardsController, poolAddressesProviders);
        }
    }

    /**
     * @notice Returns true when any caller-requested row is a controller emission token.
     * @param emissionTokens Controller emission reward tokens.
     * @param rewardTokens Caller-requested reward tokens.
     * @return True when at least one requested row needs emission-asset aggregation.
     */
    function _hasEmissionTokenMatch(address[] memory emissionTokens, address[] memory rewardTokens)
        private
        pure
        returns (bool)
    {
        for (uint256 i; i < rewardTokens.length;) {
            if (_isEmissionToken(emissionTokens, rewardTokens[i])) return true;
            unchecked {
                ++i;
            }
        }

        return false;
    }

    /**
     * @notice Reads pending rewards for a user and optional vault with independent fail-soft handling.
     * @param revenueReward RevenueReward contract.
     * @param rewardToken Reward token whose pending amount is read.
     * @param user User whose pending amount is read.
     * @param vault Optional UserVault whose pending amount is included.
     * @param vaultResolved Whether resolving the optional vault succeeded.
     * @return pending Sum of whichever pendingRewards reads succeeded.
     * @return ok True only if vault resolution and every attempted pendingRewards read succeeded.
     */
    function _pendingRewardsResolved(
        INeverlandUiRevenueReward revenueReward,
        address rewardToken,
        address user,
        address vault,
        bool vaultResolved
    ) private view returns (uint256 pending, bool ok) {
        ok = vaultResolved;
        try revenueReward.pendingRewards(rewardToken, user) returns (uint256 userPending) {
            pending += userPending;
        } catch {
            ok = false;
        }
        if (vault != address(0)) {
            try revenueReward.pendingRewards(rewardToken, vault) returns (uint256 vaultPending) {
                pending += vaultPending;
            } catch {
                ok = false;
            }
        }
    }

    /**
     * @notice Resolves a user's UserVault address from RevenueReward's configured factory.
     * @param revenueReward RevenueReward contract.
     * @param user User whose vault is resolved.
     * @return vault The user's vault, or address(0) if no vault factory is configured or none exists.
     * @return resolved True when both dependency reads that were needed succeeded.
     */
    function _resolveUserVault(INeverlandUiRevenueReward revenueReward, address user)
        private
        view
        returns (address vault, bool resolved)
    {
        try revenueReward.userVaultFactory() returns (IUserVaultFactory vaultFactory) {
            if (address(vaultFactory) == address(0)) return (address(0), true);

            try vaultFactory.getUserVault(user) returns (address userVault) {
                return (userVault, true);
            } catch {
                return (address(0), false);
            }
        } catch {
            return (address(0), false);
        }
    }

    /**
     * @notice Reads the controller's emission reward-token list with an explicit resolution signal.
     * @param rewardsController DustRewardsController contract.
     * @return rewardTokens Controller reward tokens, or an empty fallback on failure.
     * @return resolved True only when the controller read succeeded.
     */
    function _getRewardsListResolved(IDustRewardsController rewardsController)
        private
        view
        returns (address[] memory rewardTokens, bool resolved)
    {
        try rewardsController.getRewardsList() returns (address[] memory tokens) {
            return (tokens, true);
        } catch {
            return (new address[](0), false);
        }
    }

    /**
     * @notice Returns true if `rewardToken` appears in `emissionTokens`.
     * @param emissionTokens Emission reward tokens to search.
     * @param rewardToken Reward token to find.
     * @return True when `rewardToken` appears in `emissionTokens`.
     */
    function _isEmissionToken(address[] memory emissionTokens, address rewardToken) private pure returns (bool) {
        for (uint256 k; k < emissionTokens.length;) {
            if (emissionTokens[k] == rewardToken) return true;
            unchecked {
                ++k;
            }
        }

        return false;
    }

    /**
     * @notice Fills earned revenue rewards and tracks whether every covering chunk resolved.
     * @param revenueReward RevenueReward contract.
     * @param summary Summary receiving earned revenue totals.
     * @param rewardTokens Caller-requested reward-token order.
     * @param tokenIds User-related veNFT ids.
     * @return failedMask Bit j set means at least one earnedRewardsAll chunk covering rewardTokens[j]
     *         failed. A reward token that is not actually registered on RevenueReward never appears
     *         in any chunk, so its bit is never set here: its true contribution is definitionally 0,
     *         not unresolved.
     */
    function _fillUserRevenueRewardsResolved(
        INeverlandUiRevenueReward revenueReward,
        INeverlandUiProvider.UserRewardsSummary memory summary,
        address[] memory rewardTokens,
        uint256[] memory tokenIds
    ) private view returns (uint256 failedMask) {
        address[] memory sortedRevTokens =
            NeverlandUiArrayLibrary.sortAndDedupAddresses(revenueReward.getRewardTokens());
        uint256[] memory sortedTokenIds = _sortAndDedupUint256(tokenIds);

        if (sortedRevTokens.length == 0 || sortedTokenIds.length == 0) return 0;

        uint256 maxTokens = revenueReward.MAX_TOKENS();
        uint256 maxTokenIds = revenueReward.MAX_TOKENIDS();

        if (maxTokens == 0 || maxTokenIds == 0) return _rewardTokenBits(rewardTokens, sortedRevTokens);

        for (uint256 tokenOffset; tokenOffset < sortedTokenIds.length;) {
            uint256 tokenChunkLen = sortedTokenIds.length - tokenOffset;
            if (tokenChunkLen > maxTokenIds) tokenChunkLen = maxTokenIds;
            uint256[] memory tokenChunk =
                NeverlandUiArrayLibrary.copyUint256Slice(sortedTokenIds, tokenOffset, tokenChunkLen);

            failedMask |= _fillUserRevenueRewardsForTokenChunk(
                revenueReward, summary, rewardTokens, sortedRevTokens, tokenChunk, maxTokens
            );

            tokenOffset += tokenChunkLen;
        }
    }

    /**
     * @notice Runs the reward-token-chunked `earnedRewardsAll` sweep for one already-sliced tokenId
     *         chunk. Split out purely to keep stack frames small.
     * @param revenueReward RevenueReward contract.
     * @param summary Summary receiving earned revenue totals.
     * @param rewardTokens Caller-requested reward-token order.
     * @param sortedRevTokens Sorted registered RevenueReward tokens.
     * @param tokenChunk Token-id chunk included in this sweep.
     * @param maxTokens Maximum reward-token chunk length.
     * @return failedMask Bit j set means at least one reward-token chunk covering rewardTokens[j]
     *         failed for this tokenChunk.
     */
    function _fillUserRevenueRewardsForTokenChunk(
        INeverlandUiRevenueReward revenueReward,
        INeverlandUiProvider.UserRewardsSummary memory summary,
        address[] memory rewardTokens,
        address[] memory sortedRevTokens,
        uint256[] memory tokenChunk,
        uint256 maxTokens
    ) private view returns (uint256 failedMask) {
        for (uint256 rewardOffset; rewardOffset < sortedRevTokens.length;) {
            uint256 rewardChunkLen = sortedRevTokens.length - rewardOffset;
            if (rewardChunkLen > maxTokens) rewardChunkLen = maxTokens;
            address[] memory rewardChunk =
                NeverlandUiArrayLibrary.copyAddressSlice(sortedRevTokens, rewardOffset, rewardChunkLen);

            try revenueReward.earnedRewardsAll(rewardChunk, tokenChunk) returns (
                uint256[][] memory, uint256[] memory totalsPerToken
            ) {
                failedMask |= _accumulateRevenueTotals(summary, rewardTokens, rewardChunk, totalsPerToken);
            } catch {
                failedMask |= _rewardTokenBits(rewardTokens, rewardChunk);
            }

            rewardOffset += rewardChunkLen;
        }
    }

    /**
     * @notice Adds a RevenueReward chunk's totals into a user summary in caller-requested order.
     * @param summary Summary receiving the accumulated totals.
     * @param rewardTokens Caller-requested reward-token order.
     * @param rewardChunk Reward tokens represented by `totalsPerToken`.
     * @param totalsPerToken Aggregate totals aligned with `rewardChunk`.
     * @return failedMask Bits for requested reward-token rows missing from a short aggregate response.
     */
    function _accumulateRevenueTotals(
        INeverlandUiProvider.UserRewardsSummary memory summary,
        address[] memory rewardTokens,
        address[] memory rewardChunk,
        uint256[] memory totalsPerToken
    ) private pure returns (uint256 failedMask) {
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
            } else {
                failedMask |= _rewardTokenBit(rewardTokens, rewardToken);
            }
            unchecked {
                ++r;
            }
        }
    }

    /**
     * @notice Returns a bitmask of positions matching one reward token.
     * @param rewardTokens Caller-requested reward-token order.
     * @param rewardToken Reward token whose positions are marked.
     * @return bits Bitmask of matching positions in `rewardTokens`.
     */
    function _rewardTokenBit(address[] memory rewardTokens, address rewardToken) private pure returns (uint256 bits) {
        for (uint256 j; j < rewardTokens.length;) {
            if (rewardTokens[j] == rewardToken) {
                bits |= (uint256(1) << j);
            }
            unchecked {
                ++j;
            }
        }
    }

    /**
     * @notice Returns a bitmask of positions in `rewardTokens` that match an address in `chunk`.
     * @dev Shared bit-position helper for the Resolved* mask fields: bit j always mirrors
     *      rewardTokens[j], never a separate index space, so no legend is needed client-side.
     *      Positions at or beyond 256 are unrepresentable and silently contribute no bit (EVM SHL
     *      returns 0 for a shift amount >= 256); this only ever biases toward under-reporting
     *      resolution, never toward a false "resolved."
     * @param rewardTokens Caller-requested reward-token order.
     * @param chunk Reward-token chunk whose positions are marked.
     * @return bits Bitmask of matching positions in `rewardTokens`.
     */
    function _rewardTokenBits(address[] memory rewardTokens, address[] memory chunk)
        private
        pure
        returns (uint256 bits)
    {
        for (uint256 c; c < chunk.length;) {
            bits |= _rewardTokenBit(rewardTokens, chunk[c]);
            unchecked {
                ++c;
            }
        }
    }

    /**
     * @notice Returns a bitmask with the low `n` bits set (bit i for i in [0, n)).
     * @dev Shared "everything starts presumed resolved" base mask; callers clear bits only for
     *      positions that were attempted and failed. Saturates to type(uint256).max for n >= 256.
     * @param n Number of low bits to set.
     * @return mask Bitmask with the low `n` bits set, saturated at 256 bits.
     */
    function _lowBitsMask(uint256 n) private pure returns (uint256 mask) {
        if (n == 0) return 0;
        if (n >= 256) return type(uint256).max;
        return (uint256(1) << n) - 1;
    }

    /**
     * @notice Sorts and deduplicates a uint256 array in ascending order.
     * @param arr Array to sort and deduplicate.
     * @return sorted Sorted array containing each value once.
     */
    function _sortAndDedupUint256(uint256[] memory arr) private pure returns (uint256[] memory sorted) {
        uint256 len = arr.length;

        if (len == 0) return new uint256[](0);

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
}
