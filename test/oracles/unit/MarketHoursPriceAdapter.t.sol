// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPoolAddressesProvider} from "@neverland-money/lending-core/contracts/interfaces/IPoolAddressesProvider.sol";
import {AaveOracle} from "@neverland-money/lending-core/contracts/misc/AaveOracle.sol";
import {
    PoolAddressesProvider
} from "@neverland-money/lending-core/contracts/protocol/configuration/PoolAddressesProvider.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {IMarketHoursPriceAdapter} from "../../../src/interfaces/IMarketHoursPriceAdapter.sol";
import {ISessionCalendar} from "../../../src/interfaces/ISessionCalendar.sol";

import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";

import {MarketHoursPriceAdapter} from "../../../src/oracles/MarketHoursPriceAdapter.sol";
import {SessionCalendar} from "../../../src/oracles/SessionCalendar.sol";
import {SessionWindowTestBase} from "../../_utils/SessionWindowTestBase.sol";

import {MockBrokenCalendar} from "../../risk/mocks/MockBrokenCalendar.sol";
import {MockChainlinkAggregator} from "../../_utils/MockChainlinkAggregator.sol";

/**
 * @title MarketHoursPriceAdapterTest
 * @author Neverland
 * @notice Unit tests for the session-aware stock price source
 * @dev Covers the two age bounds and the calendar boundary that switches between them, the last print carried
 *      through closures and reopens, feed faults, and AaveOracle's unset-fallback behavior. Fuzzing checks
 *      that a rejected round never revives on its own.
 */
contract MarketHoursPriceAdapterTest is SessionWindowTestBase {
    /// @dev Deployment timestamp used by every test.
    uint256 internal constant T0 = 365 days;

    /// @dev First session window.
    uint256 internal constant SESSION_A_START = T0 + 1 days;
    uint256 internal constant SESSION_A_END = T0 + 6 days;

    /// @dev Second session window, after a closed weekend.
    uint256 internal constant SESSION_B_START = T0 + 8 days;
    uint256 internal constant SESSION_B_END = T0 + 13 days;

    /// @dev $650.00 at 8 decimals.
    int256 internal constant PRICE = 650e8;

    /// @dev Launch age limits.
    uint256 internal constant MAX_SESSION_AGE = 2 days;
    uint256 internal constant MAX_CLOSURE_AGE = 5 days;

    SessionCalendar internal calendar;

    MockChainlinkAggregator internal feed;

    MarketHoursPriceAdapter internal adapter;

    address internal stock = makeAddr("SPY");

    uint80 internal round = 1;

    function setUp() public {
        vm.warp(T0);

        calendar = new SessionCalendar();
        ISessionCalendar.Window[] memory windows = new ISessionCalendar.Window[](2);
        windows[0] = ISessionCalendar.Window({start: uint64(SESSION_A_START), end: uint64(SESSION_A_END)});
        windows[1] = ISessionCalendar.Window({start: uint64(SESSION_B_START), end: uint64(SESSION_B_END)});
        calendar.appendWindows(windows);

        feed = new MockChainlinkAggregator(PRICE, 8, "SPY / USD");
        adapter = _deploy(calendar, "SPY / USD market hours");
    }

    /*//////////////////////////////////////////////////////////////
                               DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Deployment stores the feed, calendar, limits, and metadata
    function test_constructor_setsState() public view {
        assertEq(address(adapter.FEED()), address(feed));
        assertEq(address(adapter.CALENDAR()), address(calendar));
        assertEq(adapter.MAX_SESSION_AGE(), MAX_SESSION_AGE);
        assertEq(adapter.MAX_CLOSURE_AGE(), MAX_CLOSURE_AGE);
        assertEq(adapter.description(), "SPY / USD market hours");
        assertEq(adapter.decimals(), 8);
        assertEq(adapter.version(), 1);
    }

    /// @notice Zero addresses, a zero session age, and a closure age below the session age are rejected
    function test_constructor_revertsOnInvalidInputs() public {
        AggregatorV3Interface aggregator = AggregatorV3Interface(address(feed));
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        new MarketHoursPriceAdapter(AggregatorV3Interface(address(0)), calendar, MAX_SESSION_AGE, MAX_CLOSURE_AGE, "");
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        new MarketHoursPriceAdapter(aggregator, ISessionCalendar(address(0)), MAX_SESSION_AGE, MAX_CLOSURE_AGE, "");
        vm.expectRevert(CommonChecksLibrary.ZeroAmount.selector);
        new MarketHoursPriceAdapter(aggregator, calendar, 0, MAX_CLOSURE_AGE, "");
        vm.expectRevert(IMarketHoursPriceAdapter.InvalidClosureAge.selector);
        new MarketHoursPriceAdapter(aggregator, calendar, MAX_SESSION_AGE, MAX_SESSION_AGE - 1, "");
        vm.expectRevert(IMarketHoursPriceAdapter.InvalidClosureAge.selector);
        new MarketHoursPriceAdapter(aggregator, calendar, MAX_SESSION_AGE, 7 days + 1, "");
    }

    /// @notice A feed with anything other than 8 decimals is rejected
    function test_constructor_revertsOnNonEightDecimalFeed() public {
        MockChainlinkAggregator wideFeed = new MockChainlinkAggregator(PRICE, 18, "wide");

        vm.expectRevert(CommonChecksLibrary.InvalidDecimals.selector);
        new MarketHoursPriceAdapter(
            AggregatorV3Interface(address(wideFeed)), calendar, MAX_SESSION_AGE, MAX_CLOSURE_AGE, ""
        );
    }

    /*//////////////////////////////////////////////////////////////
                               AGE BOUNDS
    //////////////////////////////////////////////////////////////*/

    /// @notice A fresh in-session price passes through
    function test_latestAnswer_passesThroughInSession() public {
        vm.warp(SESSION_A_START + 2 hours);
        _postRound(block.timestamp - 10 minutes);

        assertEq(adapter.latestAnswer(), PRICE);
    }

    /// @notice A round posted in session is served up to MAX_SESSION_AGE and rejected one second later
    function test_latestAnswer_rejectsStaleRoundInSession() public {
        uint256 postedAt = SESSION_A_START + 1 hours;
        _postRound(postedAt);

        vm.warp(postedAt + MAX_SESSION_AGE);
        assertEq(adapter.latestAnswer(), PRICE);

        vm.warp(postedAt + MAX_SESSION_AGE + 1);
        assertEq(adapter.latestAnswer(), 0);
    }

    /// @notice A round posted at the exact open counts as in session
    function test_latestAnswer_roundAtTheOpenIsInSession() public {
        _postRound(SESSION_B_START);

        vm.warp(SESSION_B_START + MAX_SESSION_AGE);
        assertEq(adapter.latestAnswer(), PRICE);

        vm.warp(SESSION_B_START + MAX_SESSION_AGE + 1);
        assertEq(adapter.latestAnswer(), 0);
    }

    /**
     * @notice The last print before a close is served through the closure and into the next session, up to
     *         MAX_CLOSURE_AGE from the print, until the feed posts a new round
     * @dev Friday's close prices the weekend; the market's reopen changes nothing until the feed prints.
     */
    function test_latestAnswer_carriesTheLastPrintThroughTheClosure() public {
        uint256 postedAt = SESSION_A_END - 1 hours;
        _postRound(postedAt);
        vm.warp(SESSION_A_END - 1);
        assertEq(adapter.latestAnswer(), PRICE);

        vm.warp(SESSION_A_END);
        assertEq(adapter.latestAnswer(), PRICE);

        vm.warp(SESSION_A_END + 1 days);
        assertEq(adapter.latestAnswer(), PRICE);

        vm.warp(SESSION_B_START);
        assertEq(adapter.latestAnswer(), PRICE);

        vm.warp(SESSION_B_START + 2 hours);
        assertEq(adapter.latestAnswer(), PRICE);

        vm.warp(postedAt + MAX_CLOSURE_AGE);
        assertEq(adapter.latestAnswer(), PRICE);

        vm.warp(postedAt + MAX_CLOSURE_AGE + 1);
        assertEq(adapter.latestAnswer(), 0);

        _postRound(block.timestamp);
        assertEq(adapter.latestAnswer(), PRICE);
    }

    /// @notice A round that went stale in session stays rejected through the closure and the next session
    function test_latestAnswer_keepsStaleSessionPriceRejectedUntilNewRound() public {
        uint256 postedAt = SESSION_A_START + 1 hours;
        _postRound(postedAt);

        vm.warp(postedAt + MAX_SESSION_AGE + 1);
        assertEq(adapter.latestAnswer(), 0);

        vm.warp(SESSION_A_END);
        assertEq(adapter.latestAnswer(), 0);

        vm.warp(SESSION_B_START + 1 hours);
        assertEq(adapter.latestAnswer(), 0);

        _postRound(block.timestamp);
        assertEq(adapter.latestAnswer(), PRICE);
    }

    /// @notice A round posted while closed is served under the closure bound
    function test_latestAnswer_servesARoundPostedWhileClosed() public {
        vm.warp(SESSION_A_END + 1 days);
        _postRound(block.timestamp);
        assertEq(adapter.latestAnswer(), PRICE);

        vm.warp(SESSION_A_END + 1 days + MAX_CLOSURE_AGE + 1);
        assertEq(adapter.latestAnswer(), 0);
    }

    /**
     * @notice A round from before the open switches from the closure bound to the session bound only once the
     *         feed prints after the open
     * @dev At the reopen the pre-open print is still under the 5-day bound although older than 2 days; the first
     *      in-session print restarts the clock under the 2-day bound.
     */
    function test_latestAnswer_switchesBoundsAtTheFirstInSessionRound() public {
        uint256 postedAt = SESSION_B_START - 3 days;
        _postRound(postedAt);
        vm.warp(SESSION_B_START + 1 hours);
        assertEq(adapter.latestAnswer(), PRICE);

        _postRound(SESSION_B_START - 1);
        assertEq(adapter.latestAnswer(), PRICE);

        _postRound(SESSION_B_START + 1 hours);
        vm.warp(SESSION_B_START + 1 hours + MAX_SESSION_AGE + 1);
        assertEq(adapter.latestAnswer(), 0);
    }

    /// @notice An empty or not-yet-started calendar serves the last print under the closure bound
    function test_latestAnswer_bootstrapUsesTheClosureBound() public {
        MarketHoursPriceAdapter emptyAdapter = _deploy(new SessionCalendar(), "empty");
        vm.warp(T0 + 1 hours);
        _postRound(block.timestamp);
        assertEq(emptyAdapter.latestAnswer(), PRICE);
        assertEq(adapter.latestAnswer(), PRICE);

        vm.warp(T0 + 1 hours + MAX_CLOSURE_AGE + 1);
        assertEq(emptyAdapter.latestAnswer(), 0);
        assertEq(adapter.latestAnswer(), 0);
    }

    /// @notice An exhausted schedule falls back to the closure bound rather than rejecting the price
    function test_latestAnswer_exhaustedCalendarUsesTheClosureBound() public {
        uint256 postedAt = SESSION_B_END - 1 hours;
        _postRound(postedAt);

        vm.warp(SESSION_B_END + 1 days);
        assertEq(adapter.latestAnswer(), PRICE);

        vm.warp(postedAt + MAX_CLOSURE_AGE + 1);
        assertEq(adapter.latestAnswer(), 0);
    }

    /// @notice Truncating the live session moves a fresh round from the session bound to the closure bound
    function test_latestAnswer_truncationWidensTheBound() public {
        vm.warp(SESSION_A_START + 2 hours);
        _postRound(block.timestamp);
        calendar.truncateCurrentWindow(uint64(block.timestamp));
        assertEq(adapter.latestAnswer(), PRICE);

        vm.warp(block.timestamp + MAX_SESSION_AGE + 1);
        assertEq(adapter.latestAnswer(), PRICE);

        vm.warp(block.timestamp + MAX_CLOSURE_AGE - MAX_SESSION_AGE);
        assertEq(adapter.latestAnswer(), 0);
    }

    /**
     * @notice Once a round is rejected, every later read of it returns 0 until the feed posts a new round
     * @dev Uses its own calendar with long, short, adjacent, and separated windows over a 22-day horizon. The
     *      applicable bound can only tighten as time passes, so a rejection never reverses on its own.
     */
    function testFuzz_latestAnswer_rejectionHoldsUntilNewRound(uint256 postedAt, uint256 t1, uint256 t2) public {
        MarketHoursPriceAdapter fuzzAdapter = _deployFuzzAdapter();
        uint256 horizon = T0 + 23 days;
        postedAt = bound(postedAt, T0, horizon - 1);
        t1 = bound(t1, postedAt, horizon - 1);
        t2 = bound(t2, t1 + 1, horizon);
        _postRound(postedAt);

        vm.warp(t1);
        int256 first = fuzzAdapter.latestAnswer();

        vm.warp(t2);
        int256 second = fuzzAdapter.latestAnswer();

        if (first == 0) assertEq(second, 0);
    }

    /*//////////////////////////////////////////////////////////////
                              FAULT ANSWERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Zero and negative answers are rejected in session and while closed
    function test_latestAnswer_rejectsNonPositiveAnswers() public {
        vm.warp(SESSION_A_START + 1 hours);
        _postRound(block.timestamp);

        feed.setAnswer(0);
        assertEq(adapter.latestAnswer(), 0);

        feed.setAnswer(-1);
        assertEq(adapter.latestAnswer(), 0);

        vm.warp(SESSION_A_END + 1 hours);
        assertEq(adapter.latestAnswer(), 0);
    }

    /// @notice A missing update timestamp rejects both price surfaces even in an open session
    function test_latestAnswer_rejectsZeroTimestamp() public {
        vm.warp(SESSION_A_START + 1 hours);
        _postRound(0);

        assertEq(adapter.latestAnswer(), 0);
        (, int256 answer,, uint256 updatedAt,) = adapter.latestRoundData();
        assertEq(answer, 0);
        assertEq(updatedAt, 0);
    }

    /// @notice A round stamped at the current block is served, and one stamped a single second ahead is not
    function test_latestAnswer_rejectsFutureTimestamp() public {
        vm.warp(SESSION_A_START + 1 hours);
        feed.setFuture(0);
        assertEq(adapter.latestAnswer(), PRICE);

        feed.setFuture(1);
        assertEq(adapter.latestAnswer(), 0);

        feed.setFuture(60);
        assertEq(adapter.latestAnswer(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                           CHAINLINK V3 READS
    //////////////////////////////////////////////////////////////*/

    /// @notice Round data carries the feed's metadata with the served answer
    function test_latestRoundData_reportsServedAnswer() public {
        uint256 postedAt = _postFreshSessionRound();

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = adapter.latestRoundData();
        assertEq(answer, PRICE);
        assertEq(roundId, round);
        assertEq(answeredInRound, round);
        assertEq(updatedAt, postedAt);
        assertEq(adapter.latestTimestamp(), postedAt);

        vm.warp(postedAt + MAX_SESSION_AGE + 1);
        (, answer,,,) = adapter.latestRoundData();
        assertEq(answer, 0);
    }

    /*//////////////////////////////////////////////////////////////
                               AAVE ORACLE
    //////////////////////////////////////////////////////////////*/

    /// @notice AaveOracle serves the price, and reverts through its unset fallback on a rejection
    function test_aaveOracle_readsServedPriceAndRevertsOnRejection() public {
        PoolAddressesProvider provider = new PoolAddressesProvider("Tokenized Stocks", address(this));
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = stock;
        sources[0] = address(adapter);
        AaveOracle aaveOracle =
            new AaveOracle(IPoolAddressesProvider(address(provider)), assets, sources, address(0), address(0), 1e8);

        uint256 postedAt = _postFreshSessionRound();
        assertEq(aaveOracle.getAssetPrice(stock), uint256(PRICE));

        vm.warp(postedAt + MAX_SESSION_AGE + 1);
        vm.expectRevert();
        aaveOracle.getAssetPrice(stock);
    }

    /**
     * @notice A valid early close can reject a carried pre-open print that was eligible before truncation
     * @dev The new close applies the stale-at-close check. With no Aave fallback, the rejected adapter answer
     *      makes the lending oracle revert until the feed publishes a new eligible round.
     */
    function test_aaveOracle_truncationRechecksCarriedRoundAtNewClose() public {
        uint256 postedAt = SESSION_A_END - 1 hours;
        _postRound(postedAt);
        vm.warp(SESSION_B_START + 2 hours);

        PoolAddressesProvider provider = new PoolAddressesProvider("Tokenized Stocks", address(this));
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = stock;
        sources[0] = address(adapter);
        AaveOracle aaveOracle =
            new AaveOracle(IPoolAddressesProvider(address(provider)), assets, sources, address(0), address(0), 1e8);

        assertGt(block.timestamp - postedAt, MAX_SESSION_AGE);
        assertLt(block.timestamp - postedAt, MAX_CLOSURE_AGE);
        assertEq(adapter.latestAnswer(), PRICE);
        assertEq(aaveOracle.getAssetPrice(stock), uint256(PRICE));

        calendar.truncateCurrentWindow(uint64(block.timestamp));

        assertEq(calendar.lastEndedSession(block.timestamp), block.timestamp);
        assertEq(adapter.latestAnswer(), 0);
        vm.expectRevert();
        aaveOracle.getAssetPrice(stock);
    }

    /*//////////////////////////////////////////////////////////////
                               FEED FAULTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice A feed that reverts reads as 0 on the legacy path and reverts on the Chainlink V3 path
     * @dev AaveOracle reads latestAnswer, where 0 is the same rejection as any invalid price; latestRoundData
     *      keeps the feed's fault visible to diagnostics, as the other adapters do.
     */
    function test_latestAnswer_readsZeroWhenTheFeedReverts() public {
        vm.warp(SESSION_A_START + 1 hours);
        _postRound(block.timestamp);
        assertEq(adapter.latestAnswer(), PRICE);
        assertEq(adapter.latestTimestamp(), block.timestamp);

        vm.mockCallRevert(address(feed), abi.encodeWithSelector(feed.latestRoundData.selector), "gone");
        assertEq(adapter.latestAnswer(), 0);
        assertEq(adapter.latestTimestamp(), 0);
        vm.expectRevert(bytes("gone"));
        adapter.latestRoundData();
    }

    /**
     * @notice A feed whose answer no longer decodes reverts every read
     * @dev A try statement catches a revert, not a decoding failure, so a short answer or a feed with its code
     *      removed reverts the adapter the way it reverts RatioOracleAggregator and YieldBearingOracleAdapter.
     *      AaveOracle then reverts as it does on a 0 with the fallback unset, so the pool lands in the same place.
     */
    function test_reads_revertWhenTheFeedAnswerNoLongerDecodes() public {
        vm.warp(SESSION_A_START + 1 hours);
        _postRound(block.timestamp);

        vm.mockCall(address(feed), abi.encodeWithSelector(feed.latestRoundData.selector), abi.encode(PRICE));
        _assertReadsRevert();
        vm.clearMockedCalls();

        vm.etch(address(feed), "");
        _assertReadsRevert();
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT PROBES
    //////////////////////////////////////////////////////////////*/

    /// @notice The two fixed sources are probed and the age limits are capped at deployment
    function test_constructor_probesSourcesAndCapsLimits() public {
        AggregatorV3Interface aggregator = AggregatorV3Interface(address(feed));
        assertEq(adapter.MAX_SESSION_AGE_CEILING(), 7 days);
        assertEq(adapter.MAX_CLOSURE_AGE_CEILING(), 7 days);

        vm.expectRevert(IMarketHoursPriceAdapter.InvalidSessionAge.selector);
        new MarketHoursPriceAdapter(aggregator, calendar, 7 days + 1, 7 days + 1, "");

        vm.expectRevert(IMarketHoursPriceAdapter.InvalidFeed.selector);
        new MarketHoursPriceAdapter(
            AggregatorV3Interface(makeAddr("codelessFeed")), calendar, MAX_SESSION_AGE, MAX_CLOSURE_AGE, ""
        );

        vm.mockCallRevert(address(feed), abi.encodeWithSelector(feed.latestRoundData.selector), "gone");
        vm.expectRevert(IMarketHoursPriceAdapter.InvalidFeed.selector);
        new MarketHoursPriceAdapter(aggregator, calendar, MAX_SESSION_AGE, MAX_CLOSURE_AGE, "");
        vm.clearMockedCalls();

        vm.expectRevert(IMarketHoursPriceAdapter.InvalidCalendar.selector);
        new MarketHoursPriceAdapter(
            aggregator, ISessionCalendar(makeAddr("codelessCalendar")), MAX_SESSION_AGE, MAX_CLOSURE_AGE, ""
        );

        vm.mockCallRevert(
            address(calendar), abi.encodeCall(ISessionCalendar.sessionStart, (block.timestamp)), "calendar gone"
        );
        vm.expectRevert(IMarketHoursPriceAdapter.InvalidCalendar.selector);
        new MarketHoursPriceAdapter(aggregator, calendar, MAX_SESSION_AGE, MAX_CLOSURE_AGE, "");
        vm.clearMockedCalls();

        vm.mockCallRevert(
            address(calendar), abi.encodeCall(ISessionCalendar.lastEndedSession, (block.timestamp)), "calendar gone"
        );
        vm.expectRevert(IMarketHoursPriceAdapter.InvalidCalendar.selector);
        new MarketHoursPriceAdapter(aggregator, calendar, MAX_SESSION_AGE, MAX_CLOSURE_AGE, "");
        vm.clearMockedCalls();

        vm.mockCall(
            address(calendar),
            abi.encodeCall(ISessionCalendar.sessionStart, (block.timestamp)),
            abi.encode(block.timestamp + 1)
        );
        vm.expectRevert(IMarketHoursPriceAdapter.InvalidCalendar.selector);
        new MarketHoursPriceAdapter(aggregator, calendar, MAX_SESSION_AGE, MAX_CLOSURE_AGE, "");
        vm.clearMockedCalls();

        vm.mockCall(
            address(calendar),
            abi.encodeCall(ISessionCalendar.lastEndedSession, (block.timestamp)),
            abi.encode(block.timestamp + 1)
        );
        vm.expectRevert(IMarketHoursPriceAdapter.InvalidCalendar.selector);
        new MarketHoursPriceAdapter(aggregator, calendar, MAX_SESSION_AGE, MAX_CLOSURE_AGE, "");
    }

    /// @notice A calendar that answers only the schedule views is rejected, since the served path never reads them
    function test_constructor_rejectsCalendarWithoutServedPathReads() public {
        MockBrokenCalendar shapeOnly = new MockBrokenCalendar(uint64(SESSION_A_START), uint64(SESSION_A_END));
        assertEq(shapeOnly.windowCount(), 1);

        vm.expectRevert(IMarketHoursPriceAdapter.InvalidCalendar.selector);
        new MarketHoursPriceAdapter(
            AggregatorV3Interface(address(feed)),
            ISessionCalendar(address(shapeOnly)),
            MAX_SESSION_AGE,
            MAX_CLOSURE_AGE,
            ""
        );
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Asserts that every price-read surface rejects undecodable feed data
     */
    function _assertReadsRevert() internal {
        vm.expectRevert();
        adapter.latestAnswer();
        vm.expectRevert();
        adapter.latestTimestamp();
        vm.expectRevert();
        adapter.latestRoundData();
    }

    /**
     * @notice Posts a new feed round at PRICE stamped at `at`
     * @param at The round's update timestamp
     */
    function _postRound(uint256 at) internal {
        ++round;
        feed.set(PRICE, round, at, at, round);
    }

    /**
     * @notice Posts the standard fresh in-session round and advances one minute
     * @return postedAt The round timestamp
     */
    function _postFreshSessionRound() internal returns (uint256 postedAt) {
        postedAt = SESSION_A_START + 1 hours;
        _postRound(postedAt);
        vm.warp(postedAt + 1 minutes);
    }

    /**
     * @notice Deploys an adapter over the shared feed with the launch limits
     * @param sessionCalendar The calendar the adapter reads
     * @param label The adapter description
     * @return The adapter
     */
    function _deploy(SessionCalendar sessionCalendar, string memory label) internal returns (MarketHoursPriceAdapter) {
        return new MarketHoursPriceAdapter(
            AggregatorV3Interface(address(feed)), sessionCalendar, MAX_SESSION_AGE, MAX_CLOSURE_AGE, label
        );
    }

    /**
     * @notice Deploys an adapter over the shared feed with its own calendar of long, short, and adjacent windows
     * @dev Exercises long, short, adjacent, and separated sessions over a 22-day horizon.
     * @return The adapter
     */
    function _deployFuzzAdapter() internal returns (MarketHoursPriceAdapter) {
        ISessionCalendar.Window[] memory windows = new ISessionCalendar.Window[](6);
        windows[0] = _window(T0 + 1 days, T0 + 6 days);
        windows[1] = _window(T0 + 7 days, T0 + 7 days + 8 hours);
        windows[2] = _window(T0 + 7 days + 8 hours, T0 + 7 days + 16 hours);
        windows[3] = _window(T0 + 9 days, T0 + 12 days);
        windows[4] = _window(T0 + 12 days, T0 + 15 days);
        windows[5] = _window(T0 + 17 days, T0 + 22 days);
        SessionCalendar fuzzCalendar = new SessionCalendar();
        fuzzCalendar.appendWindows(windows);

        return _deploy(fuzzCalendar, "fuzz");
    }
}
