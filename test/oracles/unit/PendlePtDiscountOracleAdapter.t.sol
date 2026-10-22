// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {AaveOracle} from "@aave/core-v3/contracts/misc/AaveOracle.sol";
import {PoolAddressesProvider} from "@aave/core-v3/contracts/protocol/configuration/PoolAddressesProvider.sol";
import {Test} from "forge-std/Test.sol";

import {IPendlePtDiscountOracleAdapter} from "../../../src/interfaces/IPendlePtDiscountOracleAdapter.sol";

import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";

import {PendlePtDiscountOracleAdapter} from "../../../src/oracles/PendlePtDiscountOracleAdapter.sol";
import {MockChainlinkAggregator} from "../../_utils/MockChainlinkAggregator.sol";

/**
 * @title MockAusdPt
 * @author Neverland
 * @notice Minimal mock of a Pendle AUSD principal token (PT-AUSD)
 * @dev Only `expiry()` is consumed by the adapter; the token-like fields add realism for lifecycle tests.
 */
contract MockAusdPt {
    uint256 public expiry;
    string public name = "Principal Token AUSD";
    string public symbol = "PT-AUSD";
    uint8 public decimals = 18;

    constructor(uint256 expiry_) {
        expiry = expiry_;
    }

    function setExpiry(uint256 expiry_) external {
        expiry = expiry_;
    }
}

/**
 * @title RevertingAggregator
 * @author Neverland
 * @notice Minimal Chainlink-style feed that reverts on round reads
 */
contract RevertingAggregator {
    error FeedReverted();

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData()
        external
        pure
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        roundId;
        answer;
        startedAt;
        updatedAt;
        answeredInRound;
        revert FeedReverted();
    }
}

/**
 * @title ConfigurableReturnDataFeed
 * @author Neverland
 * @notice Chainlink-style feed whose raw latestRoundData reply can be corrupted after deployment
 * @dev Starts with a valid five-word reply so constructor checks exercise the real adapter. Tests then change
 *      the byte length or uint80 words to exercise caller-side decoding failures.
 */
contract ConfigurableReturnDataFeed {
    bool public revertResponse;
    uint256 public returnSize;
    uint256 public rawRoundId;
    int256 public rawAnswer;
    uint256 public rawStartedAt;
    uint256 public rawUpdatedAt;
    uint256 public rawAnsweredInRound;

    constructor(int256 answer_) {
        returnSize = 160;
        rawRoundId = 1;
        rawAnswer = answer_;
        rawStartedAt = block.timestamp;
        rawUpdatedAt = block.timestamp;
        rawAnsweredInRound = 1;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function setReturnSize(uint256 returnSize_) external {
        returnSize = returnSize_;
    }

    function setRevertResponse(bool revertResponse_) external {
        revertResponse = revertResponse_;
    }

    function setRawRoundIds(uint256 rawRoundId_, uint256 rawAnsweredInRound_) external {
        rawRoundId = rawRoundId_;
        rawAnsweredInRound = rawAnsweredInRound_;
    }

    fallback() external {
        uint256 size = returnSize;
        uint256 roundId_ = rawRoundId;
        int256 answer_ = rawAnswer;
        uint256 startedAt_ = rawStartedAt;
        uint256 updatedAt_ = rawUpdatedAt;
        uint256 answeredInRound_ = rawAnsweredInRound;
        uint256 revertResponse_ = revertResponse ? 1 : 0;

        assembly {
            mstore(0, roundId_)
            mstore(32, answer_)
            mstore(64, startedAt_)
            mstore(96, updatedAt_)
            mstore(128, answeredInRound_)
            switch revertResponse_
            case 0 { return(0, size) }
            default { revert(0, size) }
        }
    }
}

/**
 * @title PendlePtDiscountOracleAdapterTest
 * @author Neverland
 * @notice Unit, fuzz, and full lifecycle tests for the PT-AUSD discount oracle
 * @dev Parity: an independent reference (`_referenceAnswer`) recomputes the documented linear-discount
 *      formula — discount = timeToMaturity * rateWad / SECONDS_PER_YEAR; price = base * (1e18 - discount) / 1e18 —
 *      which is the same model Aave/BGD's PendlePriceCapAdapter implements. With an 8-decimal base feed the
 *      adapter's output is bit-for-bit equal to that reference (and therefore to the BGD formula).
 */
contract PendlePtDiscountOracleAdapterTest is Test {
    /**
     * @notice Mirrors adapter event for expectEmit assertions
     * @param previousRatePerYear The previous annual discount rate in basis points
     * @param newRatePerYear The new annual discount rate in basis points
     */
    event DiscountRatePerYearUpdated(uint16 previousRatePerYear, uint16 newRatePerYear);

    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS_TO_WAD = 1e14;

    /// @dev AUSD ~= $1.00 on an 8-decimal USD feed.
    int256 internal constant AUSD_PRICE = 1e8;
    uint8 internal constant FEED_DECIMALS = 8;
    /// @dev PT term.
    uint256 internal constant LIFE = 365 days;
    /// @dev 25% annual discount rate.
    uint16 internal constant RATE = 2500;
    /// @dev 30% annual discount-rate ceiling.
    uint16 internal constant MAX_RATE = 3000;
    uint256 internal constant MAX_DELAY = 1 days;

    MockChainlinkAggregator internal feed;
    MockAusdPt internal pt;
    PendlePtDiscountOracleAdapter internal adapter;

    uint256 internal maturity;

    function setUp() public {
        vm.warp(365 days);

        feed = new MockChainlinkAggregator(AUSD_PRICE, FEED_DECIMALS, "AUSD / USD");
        maturity = block.timestamp + LIFE;
        pt = new MockAusdPt(maturity);

        adapter =
            new PendlePtDiscountOracleAdapter(address(feed), address(pt), MAX_DELAY, MAX_RATE, RATE, "PT-AUSD / USD");
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Computes the expected answer using an independent linear-discount reference
     * @dev Matches the public BGD formula but avoids calling adapter code.
     * @param basePrice The base feed price before discounting
     * @param rateBps The annual discount rate in basis points
     * @param nowTs The timestamp at which the answer is evaluated
     * @param maturityTs The PT maturity timestamp
     * @param feedDecimals The base feed decimals
     * @return The expected 8-decimal PT/USD answer
     */
    function _referenceAnswer(uint256 basePrice, uint16 rateBps, uint256 nowTs, uint256 maturityTs, uint8 feedDecimals)
        internal
        pure
        returns (int256)
    {
        uint256 discountWad;
        if (maturityTs > nowTs) {
            uint256 ttm = maturityTs - nowTs;
            discountWad = (ttm * (uint256(rateBps) * BPS_TO_WAD)) / SECONDS_PER_YEAR;
        }

        if (discountWad >= WAD) return 0;

        uint256 numerator = WAD - discountWad;
        uint256 denominator = WAD;
        if (feedDecimals > 8) {
            denominator *= 10 ** (uint256(feedDecimals) - 8);
        } else if (feedDecimals < 8) {
            numerator *= 10 ** (8 - uint256(feedDecimals));
        }

        return int256((basePrice * numerator) / denominator);
    }

    /**
     * @notice Refreshes the feed so the round is fresh at the current timestamp
     * @param price The new answer to publish
     */
    function _refresh(int256 price) internal {
        feed.set(price, 1, block.timestamp, block.timestamp, 1);
    }

    /**
     * @notice Deploys a PT adapter against the shared test feed and a fresh mock PT
     * @param maturityTs The mock PT maturity timestamp
     * @param maxRate The immutable maximum annual discount rate in basis points
     * @param rate The initial annual discount rate in basis points
     * @return The deployed adapter
     */
    function _deploy(uint256 maturityTs, uint16 maxRate, uint16 rate) internal returns (PendlePtDiscountOracleAdapter) {
        MockAusdPt token = new MockAusdPt(maturityTs);

        return
            new PendlePtDiscountOracleAdapter(address(feed), address(token), MAX_DELAY, maxRate, rate, "PT-AUSD / USD");
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_setsState() public view {
        assertEq(address(adapter.baseAggregator()), address(feed));
        assertEq(address(adapter.principalToken()), address(pt));
        assertEq(adapter.maturity(), maturity);
        assertEq(adapter.maxDelay(), MAX_DELAY);
        assertEq(adapter.baseDecimals(), FEED_DECIMALS);
        assertEq(adapter.discountRatePerYear(), RATE);
        assertEq(adapter.maxDiscountRatePerYear(), MAX_RATE);
        assertEq(adapter.description(), "PT-AUSD / USD");
        assertEq(adapter.decimals(), 8);
        assertEq(adapter.version(), 2);
        assertEq(adapter.owner(), address(this));
    }

    function test_constructor_revertsOnZeroAggregator() public {
        MockAusdPt token = new MockAusdPt(maturity);
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        new PendlePtDiscountOracleAdapter(address(0), address(token), MAX_DELAY, MAX_RATE, RATE, "x");
    }

    function test_constructor_revertsOnZeroPrincipalToken() public {
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        new PendlePtDiscountOracleAdapter(address(feed), address(0), MAX_DELAY, MAX_RATE, RATE, "x");
    }

    function test_constructor_acceptsZeroMaxDelayAndSkipsStaleness() public {
        MockAusdPt token = new MockAusdPt(maturity);
        feed.setStale(300 days);
        PendlePtDiscountOracleAdapter zeroDelay =
            new PendlePtDiscountOracleAdapter(address(feed), address(token), 0, MAX_RATE, RATE, "x");

        assertEq(zeroDelay.maxDelay(), 0);

        // A months-stale round is still served on both paths: zero maxDelay disables the staleness bound.
        assertEq(zeroDelay.latestAnswer(), 75_000_000);
        (, int256 answer,,,) = zeroDelay.latestRoundData();
        assertEq(answer, 75_000_000);

        // Validity checks stay live: a zero updatedAt is still rejected in both regimes.
        feed.set(AUSD_PRICE, 1, 0, 0, 1);
        assertEq(zeroDelay.latestAnswer(), 0);
        vm.expectRevert(CommonChecksLibrary.StaleRound.selector);
        zeroDelay.latestRoundData();

        // Future-dated rounds are still rejected.
        feed.setFuture(1);
        assertEq(zeroDelay.latestAnswer(), 0);
    }

    function test_constructor_acceptsAnsweredInRoundZero() public {
        feed.set(AUSD_PRICE, 2, block.timestamp, block.timestamp, 0);
        MockAusdPt token = new MockAusdPt(maturity);

        PendlePtDiscountOracleAdapter zeroAnsweredInRound =
            new PendlePtDiscountOracleAdapter(address(feed), address(token), MAX_DELAY, MAX_RATE, RATE, "x");

        assertEq(zeroAnsweredInRound.latestAnswer(), 75_000_000);
    }

    function test_constructor_revertsOnZeroMaxDiscount() public {
        MockAusdPt token = new MockAusdPt(maturity);
        vm.expectRevert(IPendlePtDiscountOracleAdapter.InvalidDiscountRate.selector);
        new PendlePtDiscountOracleAdapter(address(feed), address(token), MAX_DELAY, 0, 0, "x");
    }

    function test_constructor_revertsOnMaxDiscountAtOrAbove100Pct() public {
        MockAusdPt token = new MockAusdPt(maturity);
        vm.expectRevert(IPendlePtDiscountOracleAdapter.InvalidDiscountRate.selector);
        new PendlePtDiscountOracleAdapter(address(feed), address(token), MAX_DELAY, 10000, 5000, "x");
    }

    function test_constructor_revertsOnZeroRate() public {
        MockAusdPt token = new MockAusdPt(maturity);
        vm.expectRevert(IPendlePtDiscountOracleAdapter.InvalidDiscountRate.selector);
        new PendlePtDiscountOracleAdapter(address(feed), address(token), MAX_DELAY, MAX_RATE, 0, "x");
    }

    function test_constructor_revertsOnRateAboveMax() public {
        MockAusdPt token = new MockAusdPt(maturity);
        vm.expectRevert(IPendlePtDiscountOracleAdapter.InvalidDiscountRate.selector);
        new PendlePtDiscountOracleAdapter(address(feed), address(token), MAX_DELAY, MAX_RATE, MAX_RATE + 1, "x");
    }

    function test_constructor_revertsOnMaturityPassed() public {
        MockAusdPt token = new MockAusdPt(block.timestamp);
        vm.expectRevert(IPendlePtDiscountOracleAdapter.MaturityHasPassed.selector);
        new PendlePtDiscountOracleAdapter(address(feed), address(token), MAX_DELAY, MAX_RATE, RATE, "x");
    }

    function test_constructor_revertsOnDiscountExceeding100PctAtDeploy() public {
        // 5-year PT at 25%/yr implies a 125% discount today and must be rejected.
        MockAusdPt token = new MockAusdPt(block.timestamp + 5 * 365 days);
        vm.expectRevert(IPendlePtDiscountOracleAdapter.DiscountExceedsHundredPercent.selector);
        new PendlePtDiscountOracleAdapter(address(feed), address(token), MAX_DELAY, MAX_RATE, RATE, "x");
    }

    function test_constructor_revertsOnDiscountEqualTo100PctAtDeploy() public {
        // 4-year PT at 25%/yr implies an exact 100% discount today and must be rejected.
        MockAusdPt token = new MockAusdPt(block.timestamp + 4 * 365 days);
        vm.expectRevert(IPendlePtDiscountOracleAdapter.DiscountExceedsHundredPercent.selector);
        new PendlePtDiscountOracleAdapter(address(feed), address(token), MAX_DELAY, MAX_RATE, RATE, "x");
    }

    function test_constructor_revertsWhenDiscountMathOverflows() public {
        MockAusdPt token = new MockAusdPt(type(uint256).max);

        vm.expectRevert(IPendlePtDiscountOracleAdapter.DiscountExceedsHundredPercent.selector);
        new PendlePtDiscountOracleAdapter(address(feed), address(token), MAX_DELAY, MAX_RATE, RATE, "x");
    }

    function test_constructor_revertsWhenSubHundredPercentDiscountNormalizesPriceToZero() public {
        /*
         * One second below a nominal 100% discount leaves a nonzero WAD factor, but an 8-decimal $1 answer
         * still rounds to zero. A zero-valued source must never be deployable.
         */
        MockAusdPt token = new MockAusdPt(block.timestamp + 4 * 365 days - 1);

        vm.expectRevert(IPendlePtDiscountOracleAdapter.InvalidPtPrice.selector);
        new PendlePtDiscountOracleAdapter(address(feed), address(token), MAX_DELAY, MAX_RATE, RATE, "x");
    }

    function test_constructor_acceptsMinimumPositiveNormalizedPrice() public {
        MockChainlinkAggregator minimumFeed = new MockChainlinkAggregator(2, FEED_DECIMALS, "minimum");
        MockAusdPt token = new MockAusdPt(maturity);

        PendlePtDiscountOracleAdapter minimumPriceAdapter =
            new PendlePtDiscountOracleAdapter(address(minimumFeed), address(token), MAX_DELAY, RATE, RATE, "x");

        assertEq(minimumPriceAdapter.latestAnswer(), 1);
    }

    function test_constructor_revertsWhenBaseRoundReturndataIsMalformed() public {
        ConfigurableReturnDataFeed malformedFeed = new ConfigurableReturnDataFeed(AUSD_PRICE);
        malformedFeed.setReturnSize(32);
        MockAusdPt token = new MockAusdPt(maturity);

        vm.expectRevert(IPendlePtDiscountOracleAdapter.InvalidPtPrice.selector);
        new PendlePtDiscountOracleAdapter(address(malformedFeed), address(token), MAX_DELAY, MAX_RATE, RATE, "x");
    }

    function test_constructor_revertsWhenBaseRoundIsStaleWithNonzeroMaxDelay() public {
        MockAusdPt token = new MockAusdPt(maturity);
        feed.setStale(MAX_DELAY + 1);

        vm.expectRevert(IPendlePtDiscountOracleAdapter.InvalidPtPrice.selector);
        new PendlePtDiscountOracleAdapter(address(feed), address(token), MAX_DELAY, MAX_RATE, RATE, "x");
    }

    function test_constructor_revertsOnLowFeedDecimals() public {
        MockChainlinkAggregator badFeed = new MockChainlinkAggregator(AUSD_PRICE, 5, "bad");
        MockAusdPt token = new MockAusdPt(maturity);
        vm.expectRevert(CommonChecksLibrary.InvalidDecimals.selector);
        new PendlePtDiscountOracleAdapter(address(badFeed), address(token), MAX_DELAY, MAX_RATE, RATE, "x");
    }

    function test_constructor_revertsOnHighFeedDecimals() public {
        MockChainlinkAggregator badFeed = new MockChainlinkAggregator(AUSD_PRICE, 19, "bad");
        MockAusdPt token = new MockAusdPt(maturity);
        vm.expectRevert(CommonChecksLibrary.InvalidDecimals.selector);
        new PendlePtDiscountOracleAdapter(address(badFeed), address(token), MAX_DELAY, MAX_RATE, RATE, "x");
    }

    /*//////////////////////////////////////////////////////////////
                          GOLDEN VALUES
    //////////////////////////////////////////////////////////////*/

    function test_golden_atIssuance_quarter_half_maturity() public {
        // At issuance (full term, 25% rate): price = $1 * 0.75 = 0.75e8.
        assertEq(adapter.latestAnswer(), 75_000_000);
        assertEq(adapter.getCurrentDiscount(), 25e16); // 0.25 * 1e18

        // Quarter year elapsed -> 18.75% discount -> 0.8125e8.
        vm.warp(block.timestamp + SECONDS_PER_YEAR / 4);
        _refresh(AUSD_PRICE);
        assertEq(adapter.latestAnswer(), 81_250_000);

        // Half year elapsed (cumulative) -> 12.5% discount -> 0.875e8.
        vm.warp(block.timestamp + SECONDS_PER_YEAR / 4);
        _refresh(AUSD_PRICE);
        assertEq(adapter.latestAnswer(), 87_500_000);

        // At maturity -> par.
        vm.warp(maturity);
        _refresh(AUSD_PRICE);
        assertEq(adapter.latestAnswer(), 100_000_000);
        assertEq(adapter.getCurrentDiscount(), 0);
    }

    function test_afterMaturity_pricesAtPar() public {
        vm.warp(maturity + 1000 days);
        _refresh(AUSD_PRICE);
        assertEq(adapter.latestAnswer(), AUSD_PRICE);
        assertEq(adapter.getCurrentDiscount(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                  DECIMAL NORMALIZATION (USD output = 8)
    //////////////////////////////////////////////////////////////*/

    function test_normalization_18DecimalFeed() public {
        MockChainlinkAggregator feed18 = new MockChainlinkAggregator(1e18, 18, "AUSD/USD 18d");
        MockAusdPt token = new MockAusdPt(maturity);
        PendlePtDiscountOracleAdapter a =
            new PendlePtDiscountOracleAdapter(address(feed18), address(token), MAX_DELAY, MAX_RATE, RATE, "x");
        // Output is always 8 decimals regardless of feed decimals.
        assertEq(a.latestAnswer(), 75_000_000);
    }

    function test_normalization_6DecimalFeed() public {
        MockChainlinkAggregator feed6 = new MockChainlinkAggregator(1e6, 6, "AUSD/USD 6d");
        MockAusdPt token = new MockAusdPt(maturity);
        PendlePtDiscountOracleAdapter a =
            new PendlePtDiscountOracleAdapter(address(feed6), address(token), MAX_DELAY, MAX_RATE, RATE, "x");
        assertEq(a.latestAnswer(), 75_000_000);
    }

    function test_normalization_6DecimalFeed_preservesDiscountPrecisionBeforeUpscaling() public {
        MockChainlinkAggregator feed6 = new MockChainlinkAggregator(1_000_001, 6, "AUSD/USD 6d");
        MockAusdPt token = new MockAusdPt(maturity);
        PendlePtDiscountOracleAdapter a =
            new PendlePtDiscountOracleAdapter(address(feed6), address(token), MAX_DELAY, MAX_RATE, RATE, "x");
        assertEq(a.latestAnswer(), 75_000_075);
    }

    function test_normalization_6DecimalFeed_rejectsResultAboveInt256() public {
        int256 largeButMultipliablePrice = type(int256).max / 50;
        MockChainlinkAggregator feed6 = new MockChainlinkAggregator(1e6, 6, "AUSD/USD 6d");
        MockAusdPt token = new MockAusdPt(maturity);
        PendlePtDiscountOracleAdapter a =
            new PendlePtDiscountOracleAdapter(address(feed6), address(token), MAX_DELAY, MAX_RATE, RATE, "x");

        feed6.setAnswer(largeButMultipliablePrice);

        assertEq(a.latestAnswer(), 0, "legacy read must reject a normalized value above int256");
        vm.expectRevert(IPendlePtDiscountOracleAdapter.InvalidPtPrice.selector);
        a.latestRoundData();
    }

    function test_normalization_7DecimalFeed_preservesDiscountPrecisionBeforeUpscaling() public {
        MockChainlinkAggregator feed7 = new MockChainlinkAggregator(10_000_001, 7, "AUSD/USD 7d");
        MockAusdPt token = new MockAusdPt(maturity);
        PendlePtDiscountOracleAdapter a =
            new PendlePtDiscountOracleAdapter(address(feed7), address(token), MAX_DELAY, MAX_RATE, RATE, "x");
        assertEq(a.latestAnswer(), 75_000_007);
    }

    /*//////////////////////////////////////////////////////////////
                    LENIENT latestAnswer (0 on failure)
    //////////////////////////////////////////////////////////////*/

    function test_latestAnswer_zeroOnNegativeBase() public {
        _refresh(-1);
        assertEq(adapter.latestAnswer(), 0);
    }

    function test_latestAnswer_zeroOnZeroBase() public {
        _refresh(0);
        assertEq(adapter.latestAnswer(), 0);
    }

    function test_latestAnswer_zeroOnStaleFeed() public {
        feed.setStale(MAX_DELAY + 1);
        assertEq(adapter.latestAnswer(), 0);
    }

    function test_latestAnswer_acceptsExactMaxDelayBoundary() public {
        // Inclusive boundary: exactly maxDelay old is still fresh for the lenient read.
        feed.setStale(MAX_DELAY);
        assertGt(adapter.latestAnswer(), 0);
        assertEq(adapter.latestAnswer(), 75_000_000);

        // One second past the boundary fails closed to zero.
        feed.setStale(MAX_DELAY + 1);
        assertEq(adapter.latestAnswer(), 0);
    }

    function test_latestAnswer_zeroOnZeroUpdatedAt() public {
        feed.set(AUSD_PRICE, 1, 0, 0, 1);
        assertEq(adapter.latestAnswer(), 0);
        assertEq(adapter.latestTimestamp(), 0);
        assertEq(adapter.latestRound(), 0);
    }

    function test_latestAnswer_zeroOnFutureTimestamp() public {
        feed.setFuture(1);
        assertEq(adapter.latestAnswer(), 0);
    }

    function test_latestAnswer_zeroOnZeroRoundId() public {
        feed.set(AUSD_PRICE, 0, block.timestamp, block.timestamp, 0);
        assertEq(adapter.latestAnswer(), 0);
    }

    function test_latestAnswer_zeroOnAnsweredInRoundBehindRoundId() public {
        feed.set(AUSD_PRICE, 2, block.timestamp, block.timestamp, 1);
        assertEq(adapter.latestAnswer(), 0);
    }

    function test_latestAnswer_acceptsAnsweredInRoundZero() public {
        // answeredInRound is deprecated by Chainlink; zero is informational, freshness comes from updatedAt.
        feed.set(AUSD_PRICE, 2, block.timestamp, block.timestamp, 0);
        assertEq(adapter.latestAnswer(), 75_000_000);
        assertEq(adapter.latestTimestamp(), block.timestamp);
        assertEq(adapter.latestRound(), 2);
    }

    function test_latestAnswer_zeroOnStartedAtAfterUpdatedAt() public {
        feed.set(AUSD_PRICE, 1, block.timestamp + 1, block.timestamp, 1);
        assertEq(adapter.latestAnswer(), 0);
    }

    function test_latestAnswer_zeroOnShortReturnData() public {
        ConfigurableReturnDataFeed shortFeed = new ConfigurableReturnDataFeed(AUSD_PRICE);
        MockAusdPt token = new MockAusdPt(maturity);
        PendlePtDiscountOracleAdapter a =
            new PendlePtDiscountOracleAdapter(address(shortFeed), address(token), MAX_DELAY, MAX_RATE, RATE, "x");
        shortFeed.setReturnSize(32);

        // Pre-v2 the caller-side decode of the short reply reverted the legacy reads; the size guard fails soft.
        assertEq(a.latestAnswer(), 0);
        assertEq(a.latestTimestamp(), 0);
        assertEq(a.latestRound(), 0);

        // The strict diagnostic path still reverts loudly on the malformed reply.
        vm.expectRevert();
        a.latestRoundData();
    }

    function test_latestAnswer_zeroOnOversizedReturnData() public {
        ConfigurableReturnDataFeed wideFeed = new ConfigurableReturnDataFeed(AUSD_PRICE);
        MockAusdPt token = new MockAusdPt(maturity);
        PendlePtDiscountOracleAdapter a =
            new PendlePtDiscountOracleAdapter(address(wideFeed), address(token), MAX_DELAY, MAX_RATE, RATE, "x");
        wideFeed.setReturnSize(192);

        assertEq(a.latestAnswer(), 0);

        /*
         * Intended divergence: solc's strict ABI decoder tolerates trailing bytes, while the bounded
         * fail-soft reader requires the exact five-word reply. Monitor latestAnswer (the production
         * read), not latestRoundData, as the health signal.
         */
        (, int256 answer,,,) = a.latestRoundData();
        assertEq(answer, 75_000_000);
    }

    function test_latestAnswer_boundsCopyOfVeryLargeReturnData() public {
        ConfigurableReturnDataFeed returnBomb = new ConfigurableReturnDataFeed(AUSD_PRICE);
        MockAusdPt token = new MockAusdPt(maturity);
        PendlePtDiscountOracleAdapter a =
            new PendlePtDiscountOracleAdapter(address(returnBomb), address(token), MAX_DELAY, MAX_RATE, RATE, "x");
        returnBomb.setReturnSize(256 * 1024);

        (bool success, bytes memory result) =
            address(a).staticcall{gas: 300_000}(abi.encodeCall(PendlePtDiscountOracleAdapter.latestAnswer, ()));

        assertTrue(success, "oversized returndata must not exhaust the adapter's bounded read budget");
        assertEq(abi.decode(result, (int256)), 0);
    }

    function test_latestAnswer_zeroOnDirtyRoundIdHighBits() public {
        ConfigurableReturnDataFeed dirtyFeed = new ConfigurableReturnDataFeed(AUSD_PRICE);
        MockAusdPt token = new MockAusdPt(maturity);
        PendlePtDiscountOracleAdapter a =
            new PendlePtDiscountOracleAdapter(address(dirtyFeed), address(token), MAX_DELAY, MAX_RATE, RATE, "x");
        dirtyFeed.setRawRoundIds((uint256(1) << 80) | 1, 1);

        assertEq(a.latestAnswer(), 0, "dirty uint80 roundId must fail soft");
        assertEq(a.latestTimestamp(), 0);
        assertEq(a.latestRound(), 0);

        // The strict diagnostic path reverts on the same dirty word (solc decoder validates uint80 cleanup).
        vm.expectRevert();
        a.latestRoundData();
    }

    function test_latestAnswer_zeroOnDirtyAnsweredInRoundHighBits() public {
        ConfigurableReturnDataFeed dirtyFeed = new ConfigurableReturnDataFeed(AUSD_PRICE);
        MockAusdPt token = new MockAusdPt(maturity);
        PendlePtDiscountOracleAdapter a =
            new PendlePtDiscountOracleAdapter(address(dirtyFeed), address(token), MAX_DELAY, MAX_RATE, RATE, "x");
        dirtyFeed.setRawRoundIds(1, (uint256(1) << 80) | 1);

        assertEq(a.latestAnswer(), 0, "dirty uint80 answeredInRound must fail soft");
        assertEq(a.latestTimestamp(), 0);
        assertEq(a.latestRound(), 0);

        // The strict diagnostic path reverts on the same dirty word (solc decoder validates uint80 cleanup).
        vm.expectRevert();
        a.latestRoundData();
    }

    function test_latestAnswer_acceptsCanonicalBoundaryAndAheadMetadata() public {
        // Exactly type(uint80).max is canonical, not dirty; the exact-160 positive path is pinned first.
        ConfigurableReturnDataFeed boundaryFeed = new ConfigurableReturnDataFeed(AUSD_PRICE);
        MockAusdPt token = new MockAusdPt(maturity);
        PendlePtDiscountOracleAdapter a =
            new PendlePtDiscountOracleAdapter(address(boundaryFeed), address(token), MAX_DELAY, MAX_RATE, RATE, "x");

        assertEq(a.latestAnswer(), 75_000_000);

        boundaryFeed.setRawRoundIds(type(uint80).max, type(uint80).max);
        assertEq(a.latestAnswer(), 75_000_000);
        assertEq(a.latestRound(), uint256(type(uint80).max));
        assertEq(a.getAnswer(type(uint80).max), 75_000_000);
        assertEq(a.getTimestamp(type(uint80).max), block.timestamp);

        // answeredInRound ahead of roundId is accepted on both paths (rejected only when nonzero and behind).
        feed.set(AUSD_PRICE, 2, block.timestamp, block.timestamp, 3);
        assertEq(adapter.latestAnswer(), 75_000_000);
        (, int256 answer,,,) = adapter.latestRoundData();
        assertEq(answer, 75_000_000);
    }

    function test_latestAnswer_zeroWhenBaseAggregatorHasNoCode() public {
        vm.etch(address(feed), "");

        assertEq(adapter.latestAnswer(), 0);
        assertEq(adapter.latestTimestamp(), 0);
        assertEq(adapter.latestRound(), 0);

        // The strict path keeps its own extcodesize revert on a codeless target.
        vm.expectRevert();
        adapter.latestRoundData();
    }

    function test_latestAnswer_zeroWhenBaseLatestRoundDataReverts() public {
        RevertingAggregator revertingFeed = new RevertingAggregator();
        vm.etch(address(feed), address(revertingFeed).code);

        assertEq(adapter.latestAnswer(), 0);
        assertEq(adapter.latestTimestamp(), 0);
        assertEq(adapter.latestRound(), 0);
        assertEq(adapter.getAnswer(1), 0);
        assertEq(adapter.getTimestamp(1), 0);
    }

    function test_failedStaticcallIsRejectedEvenWithCanonicalExactLengthRevertData() public {
        ConfigurableReturnDataFeed revertingFeed = new ConfigurableReturnDataFeed(AUSD_PRICE);
        MockAusdPt token = new MockAusdPt(maturity);
        PendlePtDiscountOracleAdapter a =
            new PendlePtDiscountOracleAdapter(address(revertingFeed), address(token), MAX_DELAY, MAX_RATE, RATE, "x");
        revertingFeed.setRevertResponse(true);

        (bool feedCallSuccess, bytes memory revertData) =
            address(revertingFeed).staticcall(abi.encodeWithSignature("latestRoundData()"));
        bytes32 expectedRevertHash =
            keccak256(abi.encode(uint80(1), AUSD_PRICE, block.timestamp, block.timestamp, uint80(1)));

        assertFalse(feedCallSuccess);
        assertEq(revertData.length, 160);
        assertEq(keccak256(revertData), expectedRevertHash);

        assertEq(a.latestAnswer(), 0);
        assertEq(a.latestTimestamp(), 0);
        assertEq(a.latestRound(), 0);

        vm.expectRevert(IPendlePtDiscountOracleAdapter.InvalidPtPrice.selector);
        a.setDiscountRatePerYear(1000);

        assertEq(a.discountRatePerYear(), RATE);
    }

    /*//////////////////////////////////////////////////////////////
                   STRICT latestRoundData (reverts)
    //////////////////////////////////////////////////////////////*/

    function test_latestRoundData_returnsDiscountedPriceAndMetadata() public view {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            adapter.latestRoundData();
        assertEq(answer, 75_000_000);
        assertEq(roundId, 1);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, 1);
    }

    function test_latestRoundData_revertsOnNegativeBase() public {
        _refresh(-1);
        vm.expectRevert(CommonChecksLibrary.InvalidBasePrice.selector);
        adapter.latestRoundData();
    }

    function test_latestRoundData_revertsOnZeroBase() public {
        _refresh(0);
        vm.expectRevert(CommonChecksLibrary.InvalidBasePrice.selector);
        adapter.latestRoundData();
    }

    function test_latestRoundData_revertsOnZeroUpdatedAt() public {
        feed.set(AUSD_PRICE, 1, 0, 0, 1);
        vm.expectRevert(CommonChecksLibrary.StaleRound.selector);
        adapter.latestRoundData();
    }

    function test_latestRoundData_revertsOnStale() public {
        feed.setStale(MAX_DELAY + 1);
        uint256 updatedAt = block.timestamp - MAX_DELAY - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                CommonChecksLibrary.PriceTooOld.selector, block.timestamp, updatedAt, updatedAt + MAX_DELAY
            )
        );
        adapter.latestRoundData();
    }

    function test_latestRoundData_acceptsExactMaxDelayBoundary() public {
        feed.setStale(MAX_DELAY);
        (, int256 answer,, uint256 updatedAt,) = adapter.latestRoundData();

        assertEq(answer, 75_000_000);
        assertEq(updatedAt, block.timestamp - MAX_DELAY);
    }

    function test_latestRoundData_acceptsAnsweredInRoundZero() public {
        feed.set(AUSD_PRICE, 2, block.timestamp, block.timestamp, 0);
        (uint80 roundId, int256 answer,,, uint80 answeredInRound) = adapter.latestRoundData();

        assertEq(roundId, 2);
        assertEq(answer, 75_000_000);
        assertEq(answeredInRound, 0);
    }

    function test_latestRoundData_revertsOnFutureTimestamp() public {
        feed.setFuture(1);
        vm.expectRevert(CommonChecksLibrary.StaleRound.selector);
        adapter.latestRoundData();
    }

    function test_latestRoundData_revertsOnZeroRoundId() public {
        feed.set(AUSD_PRICE, 0, block.timestamp, block.timestamp, 0);
        vm.expectRevert(CommonChecksLibrary.StaleRound.selector);
        adapter.latestRoundData();
    }

    function test_latestRoundData_revertsOnAnsweredInRoundBehindRoundId() public {
        feed.set(AUSD_PRICE, 2, block.timestamp, block.timestamp, 1);
        vm.expectRevert(CommonChecksLibrary.StaleRound.selector);
        adapter.latestRoundData();
    }

    function test_latestRoundData_revertsOnStartedAtAfterUpdatedAt() public {
        feed.set(AUSD_PRICE, 1, block.timestamp + 1, block.timestamp, 1);
        vm.expectRevert(CommonChecksLibrary.StaleRound.selector);
        adapter.latestRoundData();
    }

    function test_latestRoundData_revertsWhenDiscountedPriceFloorsToZero() public {
        _refresh(1);
        assertEq(adapter.latestAnswer(), 0, "lenient read must fail closed to zero");

        vm.expectRevert(IPendlePtDiscountOracleAdapter.InvalidPtPrice.selector);
        adapter.latestRoundData();
    }

    function test_latestRoundData_bubblesBaseFeedRevert() public {
        RevertingAggregator revertingFeed = new RevertingAggregator();
        vm.etch(address(feed), address(revertingFeed).code);

        vm.expectRevert(RevertingAggregator.FeedReverted.selector);
        adapter.latestRoundData();
    }

    function test_getRoundData_returnsDiscountedPriceAndMetadata() public {
        uint256 startedAt = block.timestamp - 12;
        uint256 updatedAt = block.timestamp - 7;
        feed.set(AUSD_PRICE, 7, startedAt, updatedAt, 7);

        (uint80 roundId, int256 answer, uint256 returnedStartedAt, uint256 returnedUpdatedAt, uint80 answeredInRound) =
            adapter.getRoundData(7);

        assertEq(roundId, 7);
        assertEq(answer, 75_000_000);
        assertEq(returnedStartedAt, startedAt);
        assertEq(returnedUpdatedAt, updatedAt);
        assertEq(answeredInRound, 7);
    }

    function test_getRoundData_revertsOnNonLatestRound() public {
        vm.expectRevert(CommonChecksLibrary.StaleRound.selector);
        adapter.getRoundData(0);
    }

    function test_getRoundData_revertsOnStaleLatestRound() public {
        feed.setStale(MAX_DELAY + 1);
        uint256 updatedAt = block.timestamp - MAX_DELAY - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                CommonChecksLibrary.PriceTooOld.selector, block.timestamp, updatedAt, updatedAt + MAX_DELAY
            )
        );
        adapter.getRoundData(1);
    }

    function test_getRoundData_bubblesBaseFeedRevert() public {
        RevertingAggregator revertingFeed = new RevertingAggregator();
        vm.etch(address(feed), address(revertingFeed).code);

        vm.expectRevert(RevertingAggregator.FeedReverted.selector);
        adapter.getRoundData(1);
    }

    /*//////////////////////////////////////////////////////////////
                       LEGACY AGGREGATOR READS
    //////////////////////////////////////////////////////////////*/

    function test_legacy_latestTimestampRoundAndGetters() public view {
        assertEq(adapter.latestTimestamp(), block.timestamp);
        assertEq(adapter.latestRound(), 1);
        assertEq(adapter.getAnswer(1), 75_000_000);
        assertEq(adapter.getTimestamp(1), block.timestamp);
    }

    function test_legacy_timestampUsesUpdatedAtWhenStartedAtDiffers() public {
        uint256 startedAt = block.timestamp - 12;
        uint256 updatedAt = block.timestamp - 7;
        feed.set(AUSD_PRICE, 7, startedAt, updatedAt, 7);

        assertEq(adapter.latestTimestamp(), updatedAt);
        assertEq(adapter.getTimestamp(7), updatedAt);
    }

    function test_legacy_getAnswerZeroOnOversizedAndNonLatestRound() public view {
        assertEq(adapter.getAnswer(uint256(type(uint80).max) + 1), 0);
        assertEq(adapter.getTimestamp(uint256(type(uint80).max) + 1), 0);
        assertEq(adapter.getAnswer(2), 0);
        assertEq(adapter.getTimestamp(2), 0);
    }

    function test_legacy_zeroOnStale() public {
        feed.setStale(MAX_DELAY + 1);
        assertEq(adapter.latestTimestamp(), 0);
        assertEq(adapter.latestRound(), 0);
        assertEq(adapter.getAnswer(1), 0);
    }

    /*//////////////////////////////////////////////////////////////
                       DISCOUNT RATE GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    function test_setDiscountRate_updatesAndEmits() public {
        vm.expectEmit(false, false, false, true, address(adapter));
        emit DiscountRatePerYearUpdated(RATE, 1000);
        adapter.setDiscountRatePerYear(1000);
        assertEq(adapter.discountRatePerYear(), 1000);
        // 10% over a full year -> 0.90e8.
        assertEq(adapter.latestAnswer(), 90_000_000);
    }

    function test_setDiscountRate_acceptsAnsweredInRoundZero() public {
        feed.set(AUSD_PRICE, 2, block.timestamp, block.timestamp, 0);

        adapter.setDiscountRatePerYear(1000);

        assertEq(adapter.discountRatePerYear(), 1000);
        assertEq(adapter.latestAnswer(), 90_000_000);
    }

    function test_setDiscountRate_revertsWhenBaseRoundIsStale() public {
        feed.setStale(MAX_DELAY + 1);

        vm.expectRevert(IPendlePtDiscountOracleAdapter.InvalidPtPrice.selector);
        adapter.setDiscountRatePerYear(1000);

        assertEq(adapter.discountRatePerYear(), RATE);
    }

    function test_setDiscountRate_revertsForNonOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        adapter.setDiscountRatePerYear(1000);
    }

    function test_setDiscountRate_revertsOnZero() public {
        vm.expectRevert(IPendlePtDiscountOracleAdapter.InvalidDiscountRate.selector);
        adapter.setDiscountRatePerYear(0);
    }

    function test_setDiscountRate_revertsAboveMax() public {
        vm.expectRevert(IPendlePtDiscountOracleAdapter.InvalidDiscountRate.selector);
        adapter.setDiscountRatePerYear(MAX_RATE + 1);
    }

    function test_setDiscountRate_revertsWhenImplyingFullDiscount() public {
        // 5-year PT: 10% deploys fine (50%), but raising to 25% implies 125% and must be rejected.
        PendlePtDiscountOracleAdapter a = _deploy(block.timestamp + 5 * 365 days, MAX_RATE, 1000);
        vm.expectRevert(IPendlePtDiscountOracleAdapter.DiscountExceedsHundredPercent.selector);
        a.setDiscountRatePerYear(2500);
    }

    function test_setDiscountRate_revertsWhenImplyingExactlyFullDiscount() public {
        // 2-year PT with a 50%/yr ceiling: 5000 bps over 2 years implies an exact 100% discount.
        PendlePtDiscountOracleAdapter a = _deploy(block.timestamp + 730 days, 5000, 1000);
        vm.expectRevert(IPendlePtDiscountOracleAdapter.DiscountExceedsHundredPercent.selector);
        a.setDiscountRatePerYear(5000);

        // 1 bp below implies a 99.98% discount: accepted, with a small strictly positive price.
        a.setDiscountRatePerYear(4999);
        assertEq(a.discountRatePerYear(), 4999);
        assertGt(a.latestAnswer(), 0);
        assertEq(a.latestAnswer(), 20_000);
    }

    function test_setDiscountRate_revertsBeforeStoringRateThatNormalizesPriceToZero() public {
        PendlePtDiscountOracleAdapter a = _deploy(block.timestamp + 4 * 365 days - 1, MAX_RATE, 1000);

        vm.expectRevert(IPendlePtDiscountOracleAdapter.InvalidPtPrice.selector);
        a.setDiscountRatePerYear(RATE);

        assertEq(a.discountRatePerYear(), 1000, "failed update must leave the previous rate intact");
        assertEq(a.latestAnswer(), 60_000_000);
    }

    function test_setDiscountRate_acceptsMinimumPositiveNormalizedPrice() public {
        MockChainlinkAggregator minimumFeed = new MockChainlinkAggregator(3, FEED_DECIMALS, "minimum");
        MockAusdPt token = new MockAusdPt(maturity);
        PendlePtDiscountOracleAdapter minimumPriceAdapter =
            new PendlePtDiscountOracleAdapter(address(minimumFeed), address(token), MAX_DELAY, 5000, 1000, "x");

        assertEq(minimumPriceAdapter.latestAnswer(), 2);

        minimumPriceAdapter.setDiscountRatePerYear(5000);

        assertEq(minimumPriceAdapter.discountRatePerYear(), 5000);
        assertEq(minimumPriceAdapter.latestAnswer(), 1);
    }

    function test_setDiscountRate_revertsBeforeStateChangeWhenCurrentBaseRoundIsInvalid() public {
        _refresh(-1);

        vm.expectRevert(IPendlePtDiscountOracleAdapter.InvalidPtPrice.selector);
        adapter.setDiscountRatePerYear(1000);

        assertEq(adapter.discountRatePerYear(), RATE);
    }

    function test_setDiscountRate_revertsBeforeStateChangeWhenCurrentBaseMetadataIsInvalid() public {
        feed.set(AUSD_PRICE, 0, block.timestamp, block.timestamp, 0);

        vm.expectRevert(IPendlePtDiscountOracleAdapter.InvalidPtPrice.selector);
        adapter.setDiscountRatePerYear(1000);

        assertEq(adapter.discountRatePerYear(), RATE);
    }

    function test_setDiscountRate_afterMaturity_succeedsUpToCeilingAndPricesAtPar() public {
        vm.warp(maturity + 1 days);
        _refresh(AUSD_PRICE);

        // Post-maturity the discount is zero, so the full-discount guard passes for any in-range rate.
        adapter.setDiscountRatePerYear(1000);
        assertEq(adapter.discountRatePerYear(), 1000);
        adapter.setDiscountRatePerYear(MAX_RATE);
        assertEq(adapter.discountRatePerYear(), MAX_RATE);

        // The stored rate no longer applies: the PT prices at par.
        assertEq(adapter.latestAnswer(), AUSD_PRICE);
        assertEq(adapter.getCurrentDiscount(), 0);
    }

    function test_ownership_renounceDisabled() public {
        vm.expectRevert(IPendlePtDiscountOracleAdapter.OwnershipRequired.selector);
        adapter.renounceOwnership();
    }

    function test_ownership_twoStepTransfer() public {
        address newOwner = address(0xA11CE);
        adapter.transferOwnership(newOwner);
        assertEq(adapter.owner(), address(this));
        vm.prank(newOwner);
        adapter.acceptOwnership();
        assertEq(adapter.owner(), newOwner);

        // New owner can govern the rate.
        vm.prank(newOwner);
        adapter.setDiscountRatePerYear(1000);
        assertEq(adapter.discountRatePerYear(), 1000);
    }

    /*//////////////////////////////////////////////////////////////
                                FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice 1:1 parity: adapter output equals the independent linear-discount reference (BGD formula).
    function testFuzz_parityWithReference(uint256 basePrice, uint16 rateBps, uint256 warpBy) public {
        basePrice = bound(basePrice, 1, 1e12);
        rateBps = uint16(bound(rateBps, 1, MAX_RATE));
        warpBy = bound(warpBy, 0, 2 * LIFE);

        adapter.setDiscountRatePerYear(rateBps);
        vm.warp(block.timestamp + warpBy);
        _refresh(int256(basePrice));

        int256 expected = _referenceAnswer(basePrice, rateBps, block.timestamp, maturity, FEED_DECIMALS);
        assertEq(adapter.latestAnswer(), expected);

        /*
         * The strict path must agree with the lenient path on a fresh, valid feed. When the discounted
         * price floors to zero (dust base price), the strict path correctly reverts instead.
         */
        if (expected > 0) {
            (, int256 rdAnswer,,,) = adapter.latestRoundData();
            assertEq(rdAnswer, expected);
        }
    }

    /// @notice Price never exceeds par and is non-negative for any time/rate.
    function testFuzz_priceWithinBounds(uint16 rateBps, uint256 warpBy) public {
        rateBps = uint16(bound(rateBps, 1, MAX_RATE));
        warpBy = bound(warpBy, 0, 2 * LIFE);

        adapter.setDiscountRatePerYear(rateBps);
        vm.warp(block.timestamp + warpBy);
        _refresh(AUSD_PRICE);

        int256 answer = adapter.latestAnswer();
        assertGe(answer, 0);
        assertLe(answer, AUSD_PRICE);
        if (block.timestamp >= maturity) {
            assertEq(answer, AUSD_PRICE);
        }
    }

    /// @notice Discount is monotonically non-increasing as time approaches maturity (price non-decreasing).
    function testFuzz_priceMonotonicTowardMaturity(uint256 t1, uint256 step) public {
        t1 = bound(t1, 0, LIFE);
        step = bound(step, 0, LIFE);

        vm.warp(block.timestamp + t1);
        _refresh(AUSD_PRICE);
        int256 priceEarly = adapter.latestAnswer();

        vm.warp(block.timestamp + step);
        _refresh(AUSD_PRICE);
        int256 priceLater = adapter.latestAnswer();

        assertGe(priceLater, priceEarly);
    }

    /// @notice For a <=1yr PT, the current discount never exceeds the configured annual rate (in WAD).
    function testFuzz_discountNeverExceedsAnnualRate(uint256 warpBy) public {
        warpBy = bound(warpBy, 0, LIFE);
        vm.warp(block.timestamp + warpBy);
        assertLe(adapter.getCurrentDiscount(), uint256(adapter.discountRatePerYear()) * BPS_TO_WAD);
    }

    /// @notice Setting any in-range rate succeeds and is stored exactly.
    function testFuzz_setDiscountRateInRange(uint16 rateBps) public {
        rateBps = uint16(bound(rateBps, 1, MAX_RATE));
        adapter.setDiscountRatePerYear(rateBps);
        assertEq(adapter.discountRatePerYear(), rateBps);
    }

    /// @notice Any rate above the ceiling reverts.
    function testFuzz_setDiscountRateAboveMaxReverts(uint16 rateBps) public {
        rateBps = uint16(bound(rateBps, MAX_RATE + 1, type(uint16).max));
        vm.expectRevert(IPendlePtDiscountOracleAdapter.InvalidDiscountRate.selector);
        adapter.setDiscountRatePerYear(rateBps);
    }
}

/**
 * @title MockFallbackOracle
 * @author Neverland
 * @notice Minimal Aave fallback price oracle returning a fixed price
 */
contract MockFallbackOracle {
    uint256 public price;

    constructor(uint256 price_) {
        price = price_;
    }

    function getAssetPrice(address) external view returns (uint256) {
        return price;
    }
}

/**
 * @title PendlePtDiscountAdapterE2ETest
 * @author Neverland
 * @notice End-to-end lifecycle through a real Aave `AaveOracle`, from issuance to post-maturity,
 *         including an AUSD depeg, a risk-admin discount tightening, and a feed outage.
 */
contract PendlePtDiscountAdapterE2ETest is Test {
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    int256 internal constant AUSD_PRICE = 1e8;
    uint8 internal constant FEED_DECIMALS = 8;
    uint256 internal constant LIFE = 365 days;
    uint16 internal constant RATE = 2500;
    uint16 internal constant MAX_RATE = 3000;
    uint256 internal constant MAX_DELAY = 1 days;
    address internal constant BASE_CURRENCY = address(0x1);
    uint256 internal constant BASE_CURRENCY_UNIT = 1e8;
    /// @dev Sentinel fallback price so failover is observable.
    uint256 internal constant FALLBACK_PRICE = 50_000_000;

    MockChainlinkAggregator internal feed;
    MockAusdPt internal pt;
    PendlePtDiscountOracleAdapter internal adapter;
    AaveOracle internal aaveOracle;
    MockFallbackOracle internal fallbackOracle;

    uint256 internal maturity;

    function setUp() public {
        vm.warp(365 days);

        feed = new MockChainlinkAggregator(AUSD_PRICE, FEED_DECIMALS, "AUSD / USD");
        maturity = block.timestamp + LIFE;
        pt = new MockAusdPt(maturity);
        adapter =
            new PendlePtDiscountOracleAdapter(address(feed), address(pt), MAX_DELAY, MAX_RATE, RATE, "PT-AUSD / USD");

        /*
         * Minimal Aave market: provider + oracle wired directly to the PT adapter as the asset source,
         * with a fallback oracle so a feed outage routes to fallback rather than reverting.
         */
        PoolAddressesProvider provider = new PoolAddressesProvider("PT-AUSD Market", address(this));
        fallbackOracle = new MockFallbackOracle(FALLBACK_PRICE);
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = address(pt);
        sources[0] = address(adapter);
        aaveOracle = new AaveOracle(
            IPoolAddressesProvider(address(provider)),
            assets,
            sources,
            address(fallbackOracle),
            BASE_CURRENCY,
            BASE_CURRENCY_UNIT
        );
    }

    function _refresh(int256 price) internal {
        feed.set(price, 1, block.timestamp, block.timestamp, 1);
    }

    function test_e2e_lifecycle() public {
        // Issuance: AaveOracle reads the discounted price through the adapter (0.75e8).
        assertEq(aaveOracle.getAssetPrice(address(pt)), 75_000_000);
        assertEq(uint256(adapter.latestAnswer()), aaveOracle.getAssetPrice(address(pt)));

        int256 prev = adapter.latestAnswer();

        // Accrue toward maturity in quarters; price rises monotonically toward par.
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + SECONDS_PER_YEAR / 4);
            _refresh(AUSD_PRICE);
            int256 cur = adapter.latestAnswer();
            assertGe(cur, prev);
            assertEq(aaveOracle.getAssetPrice(address(pt)), uint256(cur));
            prev = cur;
        }

        // AUSD depegs to $0.97 near maturity: PT tracks the cheaper base feed.
        vm.warp(maturity - 1 days);
        _refresh(97e6);
        uint256 depegPrice = aaveOracle.getAssetPrice(address(pt));
        assertLt(depegPrice, 97_000_000);
        assertGt(depegPrice, 96_000_000);

        // Risk admin tightens the discount mid-life: PT price drops at the same instant.
        _refresh(AUSD_PRICE);
        uint256 before = aaveOracle.getAssetPrice(address(pt));
        adapter.setDiscountRatePerYear(MAX_RATE);
        assertLt(aaveOracle.getAssetPrice(address(pt)), before);

        // Maturity: par.
        vm.warp(maturity);
        _refresh(AUSD_PRICE);
        assertEq(aaveOracle.getAssetPrice(address(pt)), 100_000_000);

        /*
         * Feed outage after maturity: adapter refuses to serve a stale price (returns 0), so AaveOracle
         * fails over to the configured fallback rather than reading a stale PT valuation.
         */
        feed.setStale(MAX_DELAY + 1);
        assertEq(adapter.latestAnswer(), 0);
        assertEq(aaveOracle.getAssetPrice(address(pt)), FALLBACK_PRICE);
    }

    function test_e2e_invalidAnsweredInRoundReturnsZeroAndAaveFallsBack() public {
        feed.set(AUSD_PRICE, 2, block.timestamp, block.timestamp, 1);

        assertEq(adapter.latestAnswer(), 0, "Aave-facing source read must fail closed to zero");
        assertEq(aaveOracle.getAssetPrice(address(pt)), FALLBACK_PRICE, "AaveOracle must use fallback on zero source");
    }

    /// @notice Production config has no fallback, so an invalid source must fail closed by reverting.
    function test_e2e_noFallbackRevertsOnOutage() public {
        PoolAddressesProvider provider = new PoolAddressesProvider("PT-AUSD No-Fallback Market", address(this));
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = address(pt);
        sources[0] = address(adapter);
        AaveOracle noFallbackOracle = new AaveOracle(
            IPoolAddressesProvider(address(provider)), assets, sources, address(0), BASE_CURRENCY, BASE_CURRENCY_UNIT
        );

        feed.setStale(MAX_DELAY + 1);
        assertEq(adapter.latestAnswer(), 0, "precondition: adapter must reject the stale feed");
        vm.expectRevert();
        noFallbackOracle.getAssetPrice(address(pt));
    }
}
