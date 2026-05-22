// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IReClammPool
 * @author Neverland
 * @notice Minimal interface for Balancer V3 reCLAMM pool price reading
 * @dev reCLAMM pools are two-token concentrated liquidity pools on Balancer V3.
 *      The spot price is derived from virtual balances (constant-product on virtual reserves).
 *      See: https://github.com/balancer/reclamm/blob/main/contracts/ReClammPool.sol
 */
interface IReClammPool {
    struct ReClammPoolDynamicData {
        // Base Pool
        uint256[] balancesLiveScaled18;
        uint256[] tokenRates;
        uint256 staticSwapFeePercentage;
        uint256 totalSupply;
        // ReClamm
        uint256 lastTimestamp;
        uint256[] lastVirtualBalances;
        uint256 dailyPriceShiftExponent;
        uint256 dailyPriceShiftBase;
        uint256 centerednessMargin;
        uint256 currentPriceRatio;
        uint256 currentFourthRootPriceRatio;
        uint256 startFourthRootPriceRatio;
        uint256 endFourthRootPriceRatio;
        uint32 priceRatioUpdateStartTime;
        uint32 priceRatioUpdateEndTime;
        // Pool State
        bool isPoolInitialized;
        bool isPoolPaused;
        bool isPoolInRecoveryMode;
    }

    struct ReClammPoolImmutableData {
        // Base Pool
        IERC20[] tokens;
        uint256[] decimalScalingFactors;
        bool tokenAPriceIncludesRate;
        bool tokenBPriceIncludesRate;
        uint256 minSwapFeePercentage;
        uint256 maxSwapFeePercentage;
        // Initialization
        uint256 initialMinPrice;
        uint256 initialMaxPrice;
        uint256 initialTargetPrice;
        uint256 initialDailyPriceShiftExponent;
        uint256 initialCenterednessMargin;
        // Operating Limits
        uint256 maxDailyPriceShiftExponent;
        uint256 maxDailyPriceRatioUpdateRate;
        uint256 minPriceRatioUpdateDuration;
        uint256 minPriceRatioDelta;
        uint256 balanceRatioAndPriceTolerance;
    }

    /**
     * @notice Get reCLAMM pool dynamic data including virtual balances and pool state
     * @return data ReClammPoolDynamicData struct
     */
    function getReClammPoolDynamicData() external view returns (ReClammPoolDynamicData memory data);

    /**
     * @notice Get reCLAMM pool immutable data including tokens and configuration
     * @return data ReClammPoolImmutableData struct
     */
    function getReClammPoolImmutableData() external view returns (ReClammPoolImmutableData memory data);
}
