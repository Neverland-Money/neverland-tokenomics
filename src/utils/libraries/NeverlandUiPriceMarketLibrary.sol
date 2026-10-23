// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPoolAddressesProvider} from "@neverland-money/lending-core/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPriceOracleGetter} from "@neverland-money/lending-core/contracts/interfaces/IPriceOracleGetter.sol";

import {IDustLock} from "../../interfaces/IDustLock.sol";
import {INeverlandDustHelper} from "../../interfaces/INeverlandDustHelper.sol";
import {INeverlandUiProvider} from "../../interfaces/INeverlandUiProvider.sol";
import {INeverlandUiRevenueReward} from "../../interfaces/INeverlandUiRevenueReward.sol";

import {EpochTimeLibrary} from "../../libraries/EpochTimeLibrary.sol";
import {Erc20BalanceLibrary} from "../../libraries/Erc20BalanceLibrary.sol";

/**
 * @title NeverlandUiPriceMarketLibrary
 * @author Neverland
 * @notice Linked read-only price and market-data helpers for `NeverlandUiProvider`.
 * @dev Public library functions are intentionally used here so Solidity links the library instead of
 *      inlining this logic into the UI provider runtime (mirrors `NeverlandUiEmissionLibrary`, added
 *      when the plain + resolved price/market surface together pushed the provider over EIP-170).
 */
library NeverlandUiPriceMarketLibrary {
    /// @dev USD oracle unit (8 decimals)
    uint256 private constant USD_PRICE_UNIT = 1e8;

    /**
     * @notice Builds PriceData using a caller-supplied reward-token list, tracking per-row resolution.
     * @dev `resolvedMask` bit i mirrors `p.tokens[i]`/`p.prices[i]`. For i >= 1 (non-DUST rows),
     *      `p.lastUpdated[i]` keys off the returned value being nonzero, not `resolvedMask`, matching
     *      the pre-existing `NeverlandUiProvider.getAllPrices()` output byte-for-byte for every row
     *      except DUST. For the DUST row (i == 0), `p.lastUpdated[0]` is gated on the DUST price
     *      read's own success rather than set unconditionally from an independent timestamp call:
     *      previously a failed DUST price could still carry a nonzero timestamp that looked like
     *      confirmation, which is the one place this intentionally alters the pre-existing output.
     * @param dustLock DustLock contract (for the DUST token address).
     * @param dustHelper DUST price oracle.
     * @param poolAddressesProvider Lending pool address provider whose oracle prices non-DUST rows.
     * @param rewardTokens Pre-fetched RevenueReward.getRewardTokens() result.
     * @return p Price data.
     * @return resolvedMask Per-row resolution bits, positionally aligned with p.tokens/p.prices.
     * @return dustPriceFromOracle True when the DUST price came from DustHelper's live oracle path.
     */
    function getAllPrices(
        IDustLock dustLock,
        INeverlandDustHelper dustHelper,
        IPoolAddressesProvider poolAddressesProvider,
        address[] memory rewardTokens
    ) public view returns (INeverlandUiProvider.PriceData memory p, uint256 resolvedMask, bool dustPriceFromOracle) {
        uint256 length = rewardTokens.length + 1;
        p.tokens = new address[](length);
        p.prices = new uint256[](length);
        p.lastUpdated = new uint256[](length);

        address dustToken = dustLock.token();
        p.tokens[0] = dustToken;
        bool dustResolved;
        (p.prices[0], dustResolved, dustPriceFromOracle) = getDustPriceResolved(dustHelper);
        if (dustResolved) {
            resolvedMask |= 1;
            p.lastUpdated[0] = getDustLatestTimestampOrZero(dustHelper);
        }

        for (uint256 i; i < rewardTokens.length;) {
            uint256 idx = i + 1;
            address t = rewardTokens[i];
            (uint256 price, bool tokenResolved) =
                getTokenPriceInUSDResolved(dustLock, dustHelper, poolAddressesProvider, t);
            p.tokens[idx] = t;
            p.prices[idx] = price;
            if (tokenResolved) {
                resolvedMask |= (uint256(1) << idx);
            }
            if (price != 0) {
                p.lastUpdated[idx] = t == dustToken ? getDustLatestTimestampOrZero(dustHelper) : block.timestamp;
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Builds MarketData using a caller-supplied reward-token list, tracking whether the one
     *         fail-soft field (totalValueLockedUSD) actually resolved.
     * @param dustLock DustLock contract (for epoch/supply).
     * @param dustHelper DUST price oracle (for the TVL value read).
     * @param revenueReward RevenueReward contract (for per-token balances/epoch rewards).
     * @param rewardTokens Pre-fetched RevenueReward.getRewardTokens() result.
     * @return m Market and economic data, identical value semantics to the pre-existing getMarketData.
     * @return tvlResolved False means m.totalValueLockedUSD defaulted to 0 because the DUST price
     *         was unavailable or the DUST value read failed.
     */
    function getMarketData(
        IDustLock dustLock,
        INeverlandDustHelper dustHelper,
        INeverlandUiRevenueReward revenueReward,
        address[] memory rewardTokens
    ) public view returns (INeverlandUiProvider.MarketData memory m, bool tvlResolved) {
        uint256 nextEpoch = EpochTimeLibrary.epochNext(block.timestamp);

        (m.rewardTokenBalances, m.distributionRates, m.epochRewards, m.nextEpochRewards, m.followingEpochRewards) =
            _getPerTokenRows(
                revenueReward,
                rewardTokens,
                EpochTimeLibrary.epochStart(block.timestamp),
                nextEpoch,
                EpochTimeLibrary.epochNext(nextEpoch)
            );

        m.rewardTokens = rewardTokens;
        m.nextEpochTimestamp = nextEpoch;
        m.currentEpoch = dustLock.epoch();
        (m.totalValueLockedUSD, tvlResolved) = getDustValueInUSDResolved(dustHelper, dustLock.supply());
    }

    /**
     * @notice Returns token USD price (8 decimals) using DustHelper for DUST and the pool's configured
     *         price oracle for pool assets, tracking whether a usable price was actually obtained.
     * @dev Distinguishes "the call reverted" from "the call succeeded and the value failed a sanity
     *      guard" (the `p < 1` branch): both collapse to price == 0, but only the latter had a
     *      dependency actually answer.
     * @param dustLock DustLock contract providing the DUST token address.
     * @param dustHelper Helper providing DUST price data.
     * @param poolAddressesProvider Lending pool provider whose oracle prices non-DUST assets.
     * @param token Token whose USD price is requested.
     * @return price Token USD price in 8 decimals, or zero when unavailable.
     * @return resolved True when a usable price was obtained.
     */
    function getTokenPriceInUSDResolved(
        IDustLock dustLock,
        INeverlandDustHelper dustHelper,
        IPoolAddressesProvider poolAddressesProvider,
        address token
    ) public view returns (uint256 price, bool resolved) {
        if (token == dustLock.token()) {
            (price, resolved,) = getDustPriceResolved(dustHelper);

            return (price, resolved);
        }

        address oracleAddr;
        try poolAddressesProvider.getPriceOracle() returns (address resolvedOracle) {
            oracleAddr = resolvedOracle;
        } catch {}

        if (oracleAddr == address(0)) return (0, false);

        IPriceOracleGetter oracle = IPriceOracleGetter(oracleAddr);
        uint256 unit;
        try oracle.BASE_CURRENCY_UNIT() returns (uint256 u) {
            unit = u;
        } catch {}

        if (unit < 1) return (0, false);

        uint256 p;
        try oracle.getAssetPrice(token) returns (uint256 price_) {
            p = price_;
        } catch {}

        if (p < 1) return (0, false);

        if (unit == USD_PRICE_UNIT) return (p, true);
        if (p > type(uint256).max / USD_PRICE_UNIT) return (0, false);
        uint256 scaledPrice = (p * USD_PRICE_UNIT) / unit;
        if (scaledPrice == 0) return (0, false);

        return (scaledPrice, true);
    }

    /**
     * @notice Reads the DUST helper price without letting helper/oracle failures revert UI bundles,
     *         also surfacing DustHelper's own oracle-vs-fallback provenance bool.
     * @param dustHelper Helper providing DUST price data.
     * @return price DUST USD price in 8 decimals, or zero when unavailable.
     * @return resolved True when the price read returned a usable non-zero price.
     * @return fromOracle True when DustHelper reports the price came from its live oracle path.
     *         Meaningless when `resolved` is false.
     */
    function getDustPriceResolved(INeverlandDustHelper dustHelper)
        public
        view
        returns (uint256 price, bool resolved, bool fromOracle)
    {
        try dustHelper.getPrice() returns (uint256 dustPrice, bool oracleSourced) {
            if (dustPrice == 0) return (0, false, false);

            return (dustPrice, true, oracleSourced);
        } catch {
            return (0, false, false);
        }
    }

    /**
     * @notice Reads the DUST helper timestamp without letting helper/oracle failures revert UI bundles.
     * @param dustHelper Helper providing the DUST price timestamp.
     * @return timestamp Latest DUST helper timestamp, or zero when unavailable.
     */
    function getDustLatestTimestampOrZero(INeverlandDustHelper dustHelper) public view returns (uint256 timestamp) {
        try dustHelper.latestTimestamp() returns (uint256 latestTimestamp) {
            return latestTimestamp;
        } catch {
            return 0;
        }
    }

    /**
     * @notice Converts DUST amount to USD without letting helper/oracle failures revert UI bundles,
     *         tracking whether both the current DUST price and conversion read succeeded.
     * @param dustHelper Helper providing DUST value conversion.
     * @param dustAmount Amount of DUST to value.
     * @return valueUsd USD value in helper decimals, or zero when unavailable.
     * @return resolved True when a usable DUST price was available and the value read succeeded.
     */
    function getDustValueInUSDResolved(INeverlandDustHelper dustHelper, uint256 dustAmount)
        public
        view
        returns (uint256 valueUsd, bool resolved)
    {
        (, bool priceResolved,) = getDustPriceResolved(dustHelper);
        if (!priceResolved) return (0, false);

        try dustHelper.getDustValueInUSD(dustAmount) returns (uint256 value) {
            return (value, true);
        } catch {
            return (0, false);
        }
    }

    /**
     * @notice Computes the five per-reward-token MarketData rows. Split out of `getMarketData` purely
     *         to keep both functions' stack frames small under the legacy (non-viaIR) codegen this
     *         repo builds with; `getMarketData`'s combined loop plus TVL/epoch bookkeeping alone hit
     *         "stack too deep" once this became a library's external entry point.
     * @param revenueReward RevenueReward contract providing balances and epoch rewards.
     * @param rewardTokens Reward tokens whose rows are built.
     * @param currentEpoch Current reward epoch (EpochTimeLibrary.epochStart(block.timestamp)).
     * @param nextEpoch Next reward epoch.
     * @param followingEpoch Epoch after next; DURATION == WEEK, so this is the epoch-after-next
     *        bucket funded by notifyRewardAmountForFollowingEpoch.
     * @return balances Reward-token balances held by RevenueReward.
     * @return rates Current-epoch distribution rates.
     * @return epochRewards Current-epoch reward amounts.
     * @return nextEpochRewards Next-epoch reward amounts.
     * @return followingEpochRewards Following-epoch reward amounts.
     */
    function _getPerTokenRows(
        INeverlandUiRevenueReward revenueReward,
        address[] memory rewardTokens,
        uint256 currentEpoch,
        uint256 nextEpoch,
        uint256 followingEpoch
    )
        private
        view
        returns (
            uint256[] memory balances,
            uint256[] memory rates,
            uint256[] memory epochRewards,
            uint256[] memory nextEpochRewards,
            uint256[] memory followingEpochRewards
        )
    {
        balances = _getRewardTokenBalances(revenueReward, rewardTokens);
        (rates, epochRewards, nextEpochRewards, followingEpochRewards) =
            _getEpochRewardRows(revenueReward, rewardTokens, currentEpoch, nextEpoch, followingEpoch);
    }

    /**
     * @notice Reads each reward token's balance held by RevenueReward, reverting with
     *         `BalanceUnreadable` on the first unreadable one (unchanged, pre-existing behavior).
     *         Split out of `_getPerTokenRows` for the same stack-depth reason.
     * @param revenueReward RevenueReward contract holding the balances.
     * @param rewardTokens Reward tokens whose balances are read.
     * @return balances Reward-token balances held by RevenueReward.
     */
    function _getRewardTokenBalances(INeverlandUiRevenueReward revenueReward, address[] memory rewardTokens)
        private
        view
        returns (uint256[] memory balances)
    {
        uint256 length = rewardTokens.length;
        balances = new uint256[](length);
        for (uint256 i; i < length;) {
            address token = rewardTokens[i];
            (bool ok, uint256 bal) = Erc20BalanceLibrary.tryBalanceOf(token, address(revenueReward));
            if (!ok) revert INeverlandUiProvider.BalanceUnreadable(token, address(revenueReward));

            balances[i] = bal;
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Reads each reward token's current/next/following-epoch reward amounts. `rates` and
     *         `epochRewards` are intentionally identical (both mirror `tokenRewardsPerEpoch` for
     *         `currentEpoch`), matching the pre-existing `getMarketData` output exactly.
     * @param revenueReward RevenueReward contract providing epoch rewards.
     * @param rewardTokens Reward tokens whose epoch rows are read.
     * @param currentEpoch Current reward epoch.
     * @param nextEpoch Next reward epoch.
     * @param followingEpoch Epoch after next.
     * @return rates Current-epoch distribution rates.
     * @return epochRewards Current-epoch reward amounts.
     * @return nextEpochRewards Next-epoch reward amounts.
     * @return followingEpochRewards Following-epoch reward amounts.
     */
    function _getEpochRewardRows(
        INeverlandUiRevenueReward revenueReward,
        address[] memory rewardTokens,
        uint256 currentEpoch,
        uint256 nextEpoch,
        uint256 followingEpoch
    )
        private
        view
        returns (
            uint256[] memory rates,
            uint256[] memory epochRewards,
            uint256[] memory nextEpochRewards,
            uint256[] memory followingEpochRewards
        )
    {
        uint256 length = rewardTokens.length;
        rates = new uint256[](length);
        epochRewards = new uint256[](length);
        nextEpochRewards = new uint256[](length);
        followingEpochRewards = new uint256[](length);

        for (uint256 i; i < length;) {
            address token = rewardTokens[i];
            uint256 perEpoch = revenueReward.tokenRewardsPerEpoch(token, currentEpoch);
            rates[i] = perEpoch;
            epochRewards[i] = perEpoch;
            nextEpochRewards[i] = revenueReward.tokenRewardsPerEpoch(token, nextEpoch);
            followingEpochRewards[i] = revenueReward.tokenRewardsPerEpoch(token, followingEpoch);
            unchecked {
                ++i;
            }
        }
    }
}
