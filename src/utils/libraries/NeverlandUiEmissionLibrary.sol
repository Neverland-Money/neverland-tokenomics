// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPoolDataProvider} from "@aave/core-v3/contracts/interfaces/IPoolDataProvider.sol";

import {IDustRewardsController} from "../../interfaces/IDustRewardsController.sol";
import {INeverlandUiProvider} from "../../interfaces/INeverlandUiProvider.sol";

interface IRewardsControllerAssetList {
    function getAssetsList() external view returns (address[] memory assets);
}

interface IERC20Symbol {
    function symbol() external view returns (string memory);
}

/**
 * @title NeverlandUiEmissionLibrary
 * @author Neverland
 * @notice Linked read-only emission helpers for `NeverlandUiProvider`.
 * @dev Public library functions are intentionally used here so Solidity links the library instead of inlining
 *      the heavy pool/reward enumeration logic into the UI provider runtime.
 */
library NeverlandUiEmissionLibrary {
    struct AssetData {
        address asset;
        bool isDebt;
    }

    /**
     * @notice Returns total emission rewards for one reward token.
     * @param rewardsController Shared DustRewardsController.
     * @param canonicalAddressesProvider Canonical pool addresses provider.
     * @param fallbackPoolAddressesProvider Additional isolated pool provider used when controller enumeration is unavailable.
     * @param user User whose rewards are being queried.
     * @param rewardToken Reward token to total.
     * @return totalRewards Total rewards across all enumerated assets.
     */
    function getUserEmissionRewards(
        IDustRewardsController rewardsController,
        IPoolAddressesProvider canonicalAddressesProvider,
        address fallbackPoolAddressesProvider,
        address user,
        address rewardToken
    ) public view returns (uint256 totalRewards) {
        address[] memory assets = getAllLendingPoolAssets(
            rewardsController, canonicalAddressesProvider, fallbackPoolAddressesProvider
        );

        for (uint256 i; i < assets.length;) {
            totalRewards += _tryUserRewardsSingle(rewardsController, user, assets[i], rewardToken);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Returns per-asset emission rewards for a reward token.
     * @param rewardsController Shared DustRewardsController.
     * @param canonicalAddressesProvider Canonical pool addresses provider.
     * @param fallbackPoolAddressesProvider Additional isolated pool provider used when controller enumeration is unavailable.
     * @param user User whose rewards are being queried.
     * @param rewardToken Reward token to break down.
     * @return breakdown Enumerated emission rows.
     */
    function getUserEmissionBreakdown(
        IDustRewardsController rewardsController,
        IPoolAddressesProvider canonicalAddressesProvider,
        address fallbackPoolAddressesProvider,
        address user,
        address rewardToken
    ) public view returns (INeverlandUiProvider.UserEmissionAsset[] memory breakdown) {
        AssetData[] memory assetData = getAllLendingPoolAssetData(
            rewardsController, canonicalAddressesProvider, fallbackPoolAddressesProvider
        );
        uint256 n = assetData.length;
        breakdown = new INeverlandUiProvider.UserEmissionAsset[](n);
        for (uint256 i; i < n;) {
            address asset = assetData[i].asset;
            breakdown[i] = INeverlandUiProvider.UserEmissionAsset({
                asset: asset,
                amount: _tryUserRewardsSingle(rewardsController, user, asset, rewardToken),
                symbol: _trySymbol(asset),
                isDebt: assetData[i].isDebt
            });
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Returns aggregate emission rewards across all reward tokens.
     * @param rewardsController Shared DustRewardsController.
     * @param canonicalAddressesProvider Canonical pool addresses provider.
     * @param fallbackPoolAddressesProvider Additional isolated pool provider used when controller enumeration is unavailable.
     * @param user User whose rewards are being queried.
     * @return rewardTokens Reward token list returned by the controller.
     * @return totalRewards Total rewards per reward token.
     */
    function getUserEmissions(
        IDustRewardsController rewardsController,
        IPoolAddressesProvider canonicalAddressesProvider,
        address fallbackPoolAddressesProvider,
        address user
    ) public view returns (address[] memory rewardTokens, uint256[] memory totalRewards) {
        rewardTokens = rewardsController.getRewardsList();
        totalRewards = new uint256[](rewardTokens.length);

        address[] memory assets =
            getAllLendingPoolAssets(rewardsController, canonicalAddressesProvider, fallbackPoolAddressesProvider);
        if (assets.length == 0) return (rewardTokens, totalRewards);

        try rewardsController.getAllUserRewards(assets, user) returns (
            address[] memory aggregatedTokens, uint256[] memory aggregatedAmounts
        ) {
            rewardTokens = aggregatedTokens;
            totalRewards = aggregatedAmounts;
        } catch {
            // Fail-soft: keep zeroed totals so aggregate UI queries degrade instead of reverting.
        }
    }

    /**
     * @notice Enumerates emission assets from the controller when available or from known pool providers.
     * @param rewardsController Shared DustRewardsController.
     * @param canonicalAddressesProvider Canonical pool addresses provider.
     * @param fallbackPoolAddressesProvider Additional isolated pool provider used when controller enumeration is unavailable.
     * @return assets Deduped non-zero emission asset list.
     */
    function getAllLendingPoolAssets(
        IDustRewardsController rewardsController,
        IPoolAddressesProvider canonicalAddressesProvider,
        address fallbackPoolAddressesProvider
    ) public view returns (address[] memory assets) {
        assets = _getRewardsControllerAssets(rewardsController);
        if (assets.length != 0) return assets;

        AssetData[] memory assetData =
            _dedupNonZeroAssetData(_getKnownPoolAssetData(canonicalAddressesProvider, fallbackPoolAddressesProvider));
        assets = new address[](assetData.length);
        for (uint256 i; i < assetData.length;) {
            assets[i] = assetData[i].asset;
            unchecked {
                ++i;
            }
        }
    }

    function getAllLendingPoolAssetData(
        IDustRewardsController rewardsController,
        IPoolAddressesProvider canonicalAddressesProvider,
        address fallbackPoolAddressesProvider
    ) public view returns (AssetData[] memory assetData) {
        address[] memory controllerAssets = _getRewardsControllerAssets(rewardsController);
        AssetData[] memory poolAssets =
            _getKnownPoolAssetData(canonicalAddressesProvider, fallbackPoolAddressesProvider);

        if (controllerAssets.length != 0) {
            assetData = new AssetData[](controllerAssets.length);
            for (uint256 i; i < controllerAssets.length;) {
                assetData[i] =
                    AssetData({asset: controllerAssets[i], isDebt: _isKnownDebtAsset(poolAssets, controllerAssets[i])});
                unchecked {
                    ++i;
                }
            }
            return assetData;
        }

        assetData = _dedupNonZeroAssetData(poolAssets);
    }

    function _getKnownPoolAssetData(
        IPoolAddressesProvider canonicalAddressesProvider,
        address fallbackPoolAddressesProvider
    ) private view returns (AssetData[] memory assets) {
        AssetData[] memory canonicalAssets = _getLendingPoolAssetDataFromProvider(canonicalAddressesProvider);
        AssetData[] memory fallbackAssets =
            _getLendingPoolAssetDataFromProvider(IPoolAddressesProvider(fallbackPoolAddressesProvider));

        uint256 totalLength = canonicalAssets.length + fallbackAssets.length;
        assets = new AssetData[](totalLength);
        uint256 n;
        for (uint256 i; i < canonicalAssets.length;) {
            assets[n] = canonicalAssets[i];
            unchecked {
                ++n;
                ++i;
            }
        }
        for (uint256 i; i < fallbackAssets.length;) {
            assets[n] = fallbackAssets[i];
            unchecked {
                ++n;
                ++i;
            }
        }

        assembly ("memory-safe") {
            mstore(assets, n)
        }
    }

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

    function _getLendingPoolAssetDataFromProvider(IPoolAddressesProvider addressesProvider)
        private
        view
        returns (AssetData[] memory assets)
    {
        if (address(addressesProvider).code.length == 0) {
            return new AssetData[](0);
        }

        address dataProviderAddr;
        try addressesProvider.getPoolDataProvider() returns (address resolvedDataProvider) {
            dataProviderAddr = resolvedDataProvider;
        } catch {
            return new AssetData[](0);
        }
        if (dataProviderAddr == address(0) || dataProviderAddr.code.length == 0) {
            return new AssetData[](0);
        }

        IPoolDataProvider dp = IPoolDataProvider(dataProviderAddr);
        IPoolDataProvider.TokenData[] memory reserveTokens;
        try dp.getAllReservesTokens() returns (IPoolDataProvider.TokenData[] memory resolvedReserveTokens) {
            reserveTokens = resolvedReserveTokens;
        } catch {
            return new AssetData[](0);
        }

        uint256 reserveTokensLen = reserveTokens.length;
        if (reserveTokensLen == 0) return new AssetData[](0);

        assets = new AssetData[](reserveTokensLen * 2);
        uint256 assetCount;

        for (uint256 i; i < reserveTokensLen;) {
            try dp.getReserveTokensAddresses(reserveTokens[i].tokenAddress) returns (
                address aTokenAddr, address, /*stableDebt*/ address variableDebtTokenAddr
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
                // Skip only the unreadable reserve, preserving the rest of the market.
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

    function _isKnownDebtAsset(AssetData[] memory assets, address target) private pure returns (bool) {
        for (uint256 i; i < assets.length;) {
            if (assets[i].asset == target) return assets[i].isDebt;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function _trySymbol(address asset) private view returns (string memory) {
        if (asset.code.length == 0) return "";

        try IERC20Symbol(asset).symbol() returns (string memory assetSymbol) {
            return assetSymbol;
        } catch {
            return "";
        }
    }

    function _tryUserRewardsSingle(
        IDustRewardsController rewardsController,
        address user,
        address asset,
        address rewardToken
    ) private view returns (uint256 amount) {
        address[] memory singleAsset = new address[](1);
        singleAsset[0] = asset;
        try rewardsController.getUserRewards(singleAsset, user, rewardToken) returns (uint256 userRewards) {
            return userRewards;
        } catch {
            return 0;
        }
    }
}
