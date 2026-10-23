// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPoolAddressesProvider} from "@neverland-money/lending-core/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPoolDataProvider} from "@neverland-money/lending-core/contracts/interfaces/IPoolDataProvider.sol";

import {IDustRewardsController} from "../../interfaces/IDustRewardsController.sol";
import {INeverlandUiProvider} from "../../interfaces/INeverlandUiProvider.sol";

/**
 * @title IRewardsControllerAssetList
 * @author Neverland
 * @notice Minimal optional emission-asset enumeration surface used by the UI library.
 */
interface IRewardsControllerAssetList {
    /**
     * @notice Returns every emission asset known to the rewards controller.
     * @return assets Registered emission assets.
     */
    function getAssetsList() external view returns (address[] memory assets);
}

/**
 * @title IERC20Symbol
 * @author Neverland
 * @notice Minimal ERC20 metadata surface used for fail-soft UI labels.
 */
interface IERC20Symbol {
    /**
     * @notice Returns the token symbol.
     * @return The token symbol string.
     */
    function symbol() external view returns (string memory);
}

/**
 * @title NeverlandUiEmissionLibrary
 * @author Neverland
 * @notice Linked read-only emission helpers for `NeverlandUiProvider`.
 * @dev Public library functions are intentionally used here so Solidity links the library instead of inlining
 *      the heavy pool/reward enumeration logic into the UI provider runtime.
 *
 *      Enumerates every pool address provider passed in (the caller is expected to pass the full
 *      registered-market list), not a hardcoded canonical/fallback pair. A new isolated market
 *      becoming visible here never requires a redeploy: registering it on the pool address provider
 *      registry is enough. The one exception is `_getRewardsControllerAssets`, the controller-native
 *      path tried first: if the rewards controller's own asset list is already complete, per-provider
 *      enumeration below is never reached at all.
 */
library NeverlandUiEmissionLibrary {
    /**
     * @notice One lending-pool emission asset and its supply/debt classification.
     * @param asset aToken or variable-debt-token address.
     * @param isDebt True for a variable debt token and false for an aToken.
     */
    struct AssetData {
        address asset;
        bool isDebt;
    }

    /**
     * @notice Returns per-asset emission rewards and labels for a reward token, across every asset in
     *         every one of `poolAddressesProviders`, with a per-row resolution signal.
     * @dev Each row is one asset (one aToken or debt token) from exactly one market; rows from
     *      different markets are never merged into one another, only concatenated into one list. A
     *      row does not currently say which market it came from (see NatSpec on the caller in
     *      `NeverlandUiProvider.sol` for that limitation).
     * @param rewardsController Shared DustRewardsController.
     * @param poolAddressesProviders Every registered lending pool address provider to enumerate.
     * @param user User whose rewards are being queried.
     * @param rewardToken Reward token to break down.
     * @return breakdown Enumerated emission rows; a row's `resolved` field is false when that
     *         specific asset's read failed, not when the user genuinely has no accrued reward there.
     * @return enumerationResolved Aggregate signal, distinct from any row's own `resolved`: false
     *         means at least one registered pool's asset list itself could not be enumerated, so
     *         `breakdown` is missing that pool's rows entirely rather than reporting them as zero.
     */
    function getUserEmissionBreakdown(
        IDustRewardsController rewardsController,
        address[] memory poolAddressesProviders,
        address user,
        address rewardToken
    ) public view returns (INeverlandUiProvider.UserEmissionAsset[] memory breakdown, bool enumerationResolved) {
        (AssetData[] memory assetData, bool resolved) =
            getAllLendingPoolAssetData(rewardsController, poolAddressesProviders);
        enumerationResolved = resolved;
        uint256 n = assetData.length;
        breakdown = new INeverlandUiProvider.UserEmissionAsset[](n);
        for (uint256 i; i < n;) {
            address asset = assetData[i].asset;
            (uint256 amount, bool assetResolved) =
                _tryUserRewardsSingleResolved(rewardsController, user, asset, rewardToken);
            breakdown[i] = INeverlandUiProvider.UserEmissionAsset({
                asset: asset,
                amount: amount,
                symbol: _trySymbol(asset),
                isDebt: assetData[i].isDebt,
                resolved: assetResolved
            });
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Total emission rewards for one reward token, summed across every asset in every one of
     *         `poolAddressesProviders`, with a resolution signal.
     * @param rewardsController Shared DustRewardsController.
     * @param poolAddressesProviders Every registered lending pool address provider to enumerate.
     * @param user User whose rewards are being queried.
     * @param rewardToken Reward token to aggregate.
     * @return totalRewards Total rewards across all enumerated assets; sums whichever asset reads
     *         succeeded even when `resolved` is false.
     * @return resolved True when every registered pool's asset list was itself fully enumerated AND
     *         every enumerated asset's read succeeded, or there were no assets to query (a legitimate
     *         resolved zero). False if any pool could not be enumerated or any single asset read
     *         failed: a partial sum is never reported as complete.
     */
    function getUserEmissionRewardsResolved(
        IDustRewardsController rewardsController,
        address[] memory poolAddressesProviders,
        address user,
        address rewardToken
    ) public view returns (uint256 totalRewards, bool resolved) {
        (address[] memory assets, bool enumerationResolved) =
            getAllLendingPoolAssets(rewardsController, poolAddressesProviders);

        return
            getUserEmissionRewardsForAssetsResolved(rewardsController, assets, enumerationResolved, user, rewardToken);
    }

    /**
     * @notice Same as the aggregate `getUserEmissions` read, but reuses a caller-supplied reward-token list instead of
     *         calling `rewardsController.getRewardsList()` again.
     * @dev Lets `NeverlandUiProvider`'s bundle functions fetch that list once per top-level call and
     *      thread it through here instead of paying for a second independent STATICCALL.
     * @param rewardsController Shared DustRewardsController.
     * @param poolAddressesProviders Every registered lending pool address provider to enumerate.
     * @param user User whose rewards are being queried.
     * @param rewardTokensList Pre-fetched reward-token list.
     * @return rewardTokens The supplied reward-token list or the controller's aggregate token list.
     * @return totalRewards Total rewards aligned with `rewardTokens`.
     */
    function getUserEmissionsWithTokens(
        IDustRewardsController rewardsController,
        address[] memory poolAddressesProviders,
        address user,
        address[] memory rewardTokensList
    ) public view returns (address[] memory rewardTokens, uint256[] memory totalRewards) {
        (rewardTokens, totalRewards,) =
            _getUserEmissionsEngine(rewardsController, poolAddressesProviders, user, rewardTokensList);
    }

    /**
     * @notice Resolved-tracking counterpart of `getUserEmissions`/`getUserEmissionsWithTokens`.
     * @param rewardsController Shared DustRewardsController.
     * @param poolAddressesProviders Every registered lending pool address provider to enumerate.
     * @param user User whose rewards are being queried.
     * @param rewardTokensList Pre-fetched reward-token list.
     * @return rewardTokens Reward token list (aggregatedTokens on success, rewardTokensList otherwise).
     * @return totalRewards Total rewards per token (zeroed on failure).
     * @return resolved True when every provider was enumerated and the aggregate read succeeded, or
     *         when there were no assets to query. False on incomplete enumeration or aggregate failure.
     */
    function getUserEmissionsResolved(
        IDustRewardsController rewardsController,
        address[] memory poolAddressesProviders,
        address user,
        address[] memory rewardTokensList
    ) public view returns (address[] memory rewardTokens, uint256[] memory totalRewards, bool resolved) {
        return _getUserEmissionsEngine(rewardsController, poolAddressesProviders, user, rewardTokensList);
    }

    /**
     * @notice Enumerates emission assets from the controller when available, or from every provider
     *         in `poolAddressesProviders` otherwise.
     * @param rewardsController Shared DustRewardsController.
     * @param poolAddressesProviders Every registered lending pool address provider to enumerate.
     * @return assets Deduped non-zero emission asset list.
     * @return enumerationResolved True when the controller-native list was used (it is trusted
     *         complete by construction when it answers at all), or when every provider in the
     *         per-provider fallback enumerated cleanly. False if any provider's enumeration failed,
     *         since a caller summing across providers cannot tell a missing provider from an empty one.
     */
    function getAllLendingPoolAssets(IDustRewardsController rewardsController, address[] memory poolAddressesProviders)
        public
        view
        returns (address[] memory assets, bool enumerationResolved)
    {
        assets = _getRewardsControllerAssets(rewardsController);

        if (assets.length != 0) return (assets, true);

        (AssetData[] memory rawAssetData, bool resolved) = _getKnownPoolAssetData(poolAddressesProviders);
        AssetData[] memory assetData = _dedupNonZeroAssetData(rawAssetData);
        assets = new address[](assetData.length);
        for (uint256 i; i < assetData.length;) {
            assets[i] = assetData[i].asset;
            unchecked {
                ++i;
            }
        }
        enumerationResolved = resolved;
    }

    /**
     * @notice Enumerates emission assets with their debt/aToken classification.
     * @dev When the controller-native list is used, provider enumeration is still cross-referenced
     *      for `isDebt`; incomplete provider enumeration therefore makes the result unresolved.
     * @param rewardsController Shared DustRewardsController.
     * @param poolAddressesProviders Every registered lending pool address provider to enumerate.
     * @return assetData Deduped emission assets with per-asset debt/aToken side included.
     * @return enumerationResolved False if the asset list or its debt classification is incomplete.
     */
    function getAllLendingPoolAssetData(
        IDustRewardsController rewardsController,
        address[] memory poolAddressesProviders
    ) public view returns (AssetData[] memory assetData, bool enumerationResolved) {
        address[] memory controllerAssets = _getRewardsControllerAssets(rewardsController);
        (AssetData[] memory poolAssets, bool resolved) = _getKnownPoolAssetData(poolAddressesProviders);

        if (controllerAssets.length != 0) {
            assetData = new AssetData[](controllerAssets.length);
            for (uint256 i; i < controllerAssets.length;) {
                assetData[i] =
                    AssetData({asset: controllerAssets[i], isDebt: _isKnownDebtAsset(poolAssets, controllerAssets[i])});
                unchecked {
                    ++i;
                }
            }

            return (assetData, resolved);
        }

        assetData = _dedupNonZeroAssetData(poolAssets);
        enumerationResolved = resolved;
    }

    /**
     * @notice Total emission rewards for one reward token over an already-enumerated asset list.
     * @dev Internal so callers can cache one asset enumeration per top-level request without adding
     *      a new linked-library selector or changing `getUserEmissionRewardsResolved`'s ABI.
     * @param rewardsController Shared DustRewardsController.
     * @param assets Pre-enumerated emission assets.
     * @param enumerationResolved Whether the supplied asset enumeration was complete.
     * @param user User whose rewards are being queried.
     * @param rewardToken Reward token to aggregate.
     * @return totalRewards Total rewards across all supplied assets.
     * @return resolved True when enumeration and every per-asset reward read resolved.
     */
    function getUserEmissionRewardsForAssetsResolved(
        IDustRewardsController rewardsController,
        address[] memory assets,
        bool enumerationResolved,
        address user,
        address rewardToken
    ) internal view returns (uint256 totalRewards, bool resolved) {
        resolved = enumerationResolved;
        for (uint256 i; i < assets.length;) {
            (uint256 amount, bool assetResolved) =
                _tryUserRewardsSingleResolved(rewardsController, user, assets[i], rewardToken);
            totalRewards += amount;
            if (!assetResolved) resolved = false;
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Shared engine behind `getUserEmissionsWithTokens` and `getUserEmissionsResolved`.
     * @dev `rewardTokensList` doubles as the fallback return value when the aggregate read is
     *      unavailable, mirroring the pre-existing `getUserEmissions` behavior this replaces.
     * @param rewardsController Shared DustRewardsController.
     * @param poolAddressesProviders Every registered lending pool address provider to enumerate.
     * @param user User whose rewards are being queried.
     * @param rewardTokensList Pre-fetched reward-token list.
     * @return rewardTokens Reward token list (aggregatedTokens on success, rewardTokensList otherwise).
     * @return totalRewards Total rewards per token (zeroed on failure).
     * @return resolved True when every registered pool's asset list was itself fully enumerated AND
     *         the aggregate read succeeded (or there were no assets to query). False if any pool
     *         could not be enumerated or the aggregate read failed: an asset list that is silently
     *         missing a whole pool's assets must never be indistinguishable from a genuinely empty one.
     */
    function _getUserEmissionsEngine(
        IDustRewardsController rewardsController,
        address[] memory poolAddressesProviders,
        address user,
        address[] memory rewardTokensList
    ) private view returns (address[] memory rewardTokens, uint256[] memory totalRewards, bool resolved) {
        rewardTokens = rewardTokensList;
        totalRewards = new uint256[](rewardTokens.length);

        (address[] memory assets, bool enumerationResolved) =
            getAllLendingPoolAssets(rewardsController, poolAddressesProviders);

        if (assets.length == 0) return (rewardTokens, totalRewards, enumerationResolved);

        try rewardsController.getAllUserRewards(assets, user) returns (
            address[] memory aggregatedTokens, uint256[] memory aggregatedAmounts
        ) {
            return (aggregatedTokens, aggregatedAmounts, enumerationResolved);
        } catch {
            // Fail-soft: keep zeroed totals so aggregate UI queries degrade instead of reverting.
            return (rewardTokens, totalRewards, false);
        }
    }

    /**
     * @notice Concatenates every provider's reserve-asset data and reports aggregate completeness.
     * @dev Split into collection and flatten passes to keep the stack frame small under legacy
     *      non-viaIR codegen. One unread provider makes the aggregate unresolved because a caller
     *      cannot distinguish a missing provider from an empty one.
     * @param poolAddressesProviders Lending pool address providers to enumerate.
     * @return assets Concatenated asset data from every readable provider.
     * @return allEnumerationResolved True only when every provider enumerated completely.
     */
    function _getKnownPoolAssetData(address[] memory poolAddressesProviders)
        private
        view
        returns (AssetData[] memory assets, bool allEnumerationResolved)
    {
        (AssetData[][] memory perProvider, uint256 totalLength, bool resolved) =
            _collectPerProviderAssetData(poolAddressesProviders);
        assets = _flattenAssetData(perProvider, totalLength);
        allEnumerationResolved = resolved;
    }

    /**
     * @notice Collects each provider's asset list without flattening the lists.
     * @param poolAddressesProviders Lending pool address providers to enumerate.
     * @return perProvider Asset data grouped by provider.
     * @return totalLength Sum of all grouped list lengths.
     * @return allEnumerationResolved True only when every provider enumerated completely.
     */
    function _collectPerProviderAssetData(address[] memory poolAddressesProviders)
        private
        view
        returns (AssetData[][] memory perProvider, uint256 totalLength, bool allEnumerationResolved)
    {
        uint256 providerCount = poolAddressesProviders.length;
        perProvider = new AssetData[][](providerCount);
        allEnumerationResolved = true;
        for (uint256 p; p < providerCount;) {
            (AssetData[] memory providerAssets, bool enumerationResolved) =
                _getLendingPoolAssetDataFromProvider(IPoolAddressesProvider(poolAddressesProviders[p]));
            perProvider[p] = providerAssets;
            totalLength += providerAssets.length;
            if (!enumerationResolved) allEnumerationResolved = false;
            unchecked {
                ++p;
            }
        }
    }

    /**
     * @notice Flattens provider-grouped asset data into one ordered array.
     * @param perProvider Asset data grouped by provider.
     * @param totalLength Sum of all grouped list lengths.
     * @return assets Flattened asset data in provider order.
     */
    function _flattenAssetData(AssetData[][] memory perProvider, uint256 totalLength)
        private
        pure
        returns (AssetData[] memory assets)
    {
        assets = new AssetData[](totalLength);
        uint256 n;
        for (uint256 p; p < perProvider.length;) {
            AssetData[] memory providerAssets = perProvider[p];
            for (uint256 i; i < providerAssets.length;) {
                assets[n] = providerAssets[i];
                unchecked {
                    ++n;
                    ++i;
                }
            }
            unchecked {
                ++p;
            }
        }
    }

    /**
     * @notice Reads and deduplicates the rewards controller's optional native asset list.
     * @dev Returns an empty array when the optional selector is unavailable or reverts.
     * @param rewardsController Rewards controller to query.
     * @return assets Deduped non-zero controller assets, or an empty array when unavailable.
     */
    function _getRewardsControllerAssets(IDustRewardsController rewardsController)
        private
        view
        returns (address[] memory assets)
    {
        try IRewardsControllerAssetList(address(rewardsController)).getAssetsList() returns (
            address[] memory controllerAssets
        ) {
            return _dedupNonZeroAddresses(controllerAssets);
        } catch {
            return new address[](0);
        }
    }

    /**
     * @notice Reads one provider's asset data, reporting whether enumeration was actually complete.
     * @dev A pool that genuinely has zero reserves (`getAllReservesTokens()` succeeds, returns empty)
     *      is `enumerationResolved: true` with an empty array: a real, complete answer. Every other
     *      empty-array path here (no code, a reverting call, an unreadable reserve) is `false`: an
     *      unread pool must never look identical to a genuinely empty one to a caller summing across
     *      providers, or a per-pool failure would silently understate an aggregate total.
     * @param addressesProvider Lending pool address provider to enumerate.
     * @return assets This provider's enumerated assets (possibly a partial list; see `enumerationResolved`).
     * @return enumerationResolved False if any step of reading this provider's assets failed.
     */
    function _getLendingPoolAssetDataFromProvider(IPoolAddressesProvider addressesProvider)
        private
        view
        returns (AssetData[] memory assets, bool enumerationResolved)
    {
        if (address(addressesProvider).code.length == 0) {
            return (new AssetData[](0), false);
        }

        address dataProviderAddr;
        try addressesProvider.getPoolDataProvider() returns (address resolvedDataProvider) {
            dataProviderAddr = resolvedDataProvider;
        } catch {
            return (new AssetData[](0), false);
        }

        if (dataProviderAddr == address(0) || dataProviderAddr.code.length == 0) {
            return (new AssetData[](0), false);
        }

        IPoolDataProvider dp = IPoolDataProvider(dataProviderAddr);
        IPoolDataProvider.TokenData[] memory reserveTokens;
        try dp.getAllReservesTokens() returns (IPoolDataProvider.TokenData[] memory resolvedReserveTokens) {
            reserveTokens = resolvedReserveTokens;
        } catch {
            return (new AssetData[](0), false);
        }

        uint256 reserveTokensLen = reserveTokens.length;

        if (reserveTokensLen == 0) return (new AssetData[](0), true);

        assets = new AssetData[](reserveTokensLen * 2);
        uint256 assetCount;
        enumerationResolved = true;

        for (uint256 i; i < reserveTokensLen;) {
            try dp.getReserveTokensAddresses(reserveTokens[i].tokenAddress) returns (
                address aTokenAddr, address, address variableDebtTokenAddr
            ) {
                if (aTokenAddr != address(0)) {
                    assets[assetCount] = AssetData({asset: aTokenAddr, isDebt: false});
                    unchecked {
                        ++assetCount;
                    }
                }

                if (variableDebtTokenAddr != address(0)) {
                    assets[assetCount] = AssetData({asset: variableDebtTokenAddr, isDebt: true});
                    unchecked {
                        ++assetCount;
                    }
                }
            } catch {
                /*
                 * Skip only the unreadable reserve, preserving the rest of the market, but this pool's
                 * asset list is now provably incomplete: never let this look like a resolved read.
                 */
                enumerationResolved = false;
            }

            unchecked {
                ++i;
            }
        }

        if (assetCount != reserveTokensLen * 2) {
            assembly ("memory-safe") {
                mstore(assets, assetCount)
            }
        }
    }

    /**
     * @notice Removes zero and duplicate asset addresses while preserving first-seen classification.
     * @param arr Asset data to compact.
     * @return deduped First-occurrence-ordered non-zero asset data.
     */
    function _dedupNonZeroAssetData(AssetData[] memory arr) private pure returns (AssetData[] memory deduped) {
        deduped = new AssetData[](arr.length);
        uint256 n;

        for (uint256 i; i < arr.length;) {
            address candidate = arr[i].asset;
            if (candidate != address(0)) {
                bool duplicate;
                for (uint256 j; j < n;) {
                    if (deduped[j].asset == candidate) {
                        duplicate = true;
                        break;
                    }
                    unchecked {
                        ++j;
                    }
                }

                if (!duplicate) {
                    deduped[n] = arr[i];
                    unchecked {
                        ++n;
                    }
                }
            }

            unchecked {
                ++i;
            }
        }

        assembly ("memory-safe") {
            mstore(deduped, n)
        }
    }

    /**
     * @notice Removes zero and duplicate addresses while preserving first-seen order.
     * @param arr Addresses to compact.
     * @return deduped First-occurrence-ordered non-zero addresses.
     */
    function _dedupNonZeroAddresses(address[] memory arr) private pure returns (address[] memory deduped) {
        deduped = new address[](arr.length);
        uint256 n;

        for (uint256 i; i < arr.length;) {
            address candidate = arr[i];
            if (candidate != address(0)) {
                bool duplicate;
                for (uint256 j; j < n;) {
                    if (deduped[j] == candidate) {
                        duplicate = true;
                        break;
                    }
                    unchecked {
                        ++j;
                    }
                }

                if (!duplicate) {
                    deduped[n] = candidate;
                    unchecked {
                        ++n;
                    }
                }
            }

            unchecked {
                ++i;
            }
        }

        assembly ("memory-safe") {
            mstore(deduped, n)
        }
    }

    /**
     * @notice Returns the known debt classification for one asset.
     * @param assets Asset data to search.
     * @param target Asset address whose classification is requested.
     * @return isDebt True when the matching known asset is a variable debt token.
     */
    function _isKnownDebtAsset(AssetData[] memory assets, address target) private pure returns (bool isDebt) {
        for (uint256 i; i < assets.length;) {
            if (assets[i].asset == target) return assets[i].isDebt;
            unchecked {
                ++i;
            }
        }

        return false;
    }

    /**
     * @notice Reads an asset symbol without allowing missing metadata to revert a UI query.
     * @param asset Token whose symbol is requested.
     * @return symbol_ Token symbol, or an empty string when unavailable.
     */
    function _trySymbol(address asset) private view returns (string memory symbol_) {
        if (asset.code.length == 0) return "";

        try IERC20Symbol(asset).symbol() returns (string memory assetSymbol) {
            return assetSymbol;
        } catch {
            return "";
        }
    }

    /**
     * @notice Reads one user's reward amount for one asset and reward token without bubbling failures.
     * @param rewardsController Rewards controller to query.
     * @param user User whose reward is requested.
     * @param asset Emission asset contributing the reward.
     * @param rewardToken Reward token being accrued.
     * @return amount Accrued reward amount, or zero when unavailable.
     * @return resolved True when the controller read succeeded.
     */
    function _tryUserRewardsSingleResolved(
        IDustRewardsController rewardsController,
        address user,
        address asset,
        address rewardToken
    ) private view returns (uint256 amount, bool resolved) {
        address[] memory singleAsset = new address[](1);
        singleAsset[0] = asset;
        try rewardsController.getUserRewards(singleAsset, user, rewardToken) returns (uint256 userRewards) {
            return (userRewards, true);
        } catch {
            return (0, false);
        }
    }
}
