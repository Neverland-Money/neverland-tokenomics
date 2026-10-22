// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ACLManager} from "@neverland-money/lending-core/contracts/protocol/configuration/ACLManager.sol";
import {
    PoolAddressesProvider
} from "@neverland-money/lending-core/contracts/protocol/configuration/PoolAddressesProvider.sol";
import {IPoolAddressesProvider} from "@neverland-money/lending-core/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPriceOracleSentinel} from "@neverland-money/lending-core/contracts/interfaces/IPriceOracleSentinel.sol";

import {IMarketHoursSentinel} from "../../../src/interfaces/IMarketHoursSentinel.sol";
import {ISessionCalendar} from "../../../src/interfaces/ISessionCalendar.sol";

import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";

import {SessionCalendar} from "../../../src/oracles/SessionCalendar.sol";
import {MarketHoursSentinel} from "../../../src/risk/MarketHoursSentinel.sol";
import {SessionWindowTestBase} from "../../_utils/SessionWindowTestBase.sol";

import {MockBrokenCalendar} from "../mocks/MockBrokenCalendar.sol";

/**
 * @title MarketHoursSentinelTest
 * @author Neverland
 * @notice Unit tests for a tokenized stock pool's price-oracle sentinel
 * @dev Pins the opening grace at every clock boundary, the frontend view against the liquidation verdict, the
 *      always-open borrow hook, the core's hook selectors, the immutable calendar and its deployment probes,
 *      and ACL gating through a real provider and manager.
 */
contract MarketHoursSentinelTest is SessionWindowTestBase {
    /// @dev Deployment timestamp used by every test.
    uint256 internal constant T0 = 365 days;

    /// @dev The single session window.
    uint256 internal constant SESSION_START = T0 + 1 days;
    uint256 internal constant SESSION_END = T0 + 6 days;

    /// @dev Launch opening grace.
    uint256 internal constant OPENING_GRACE = 3600;

    PoolAddressesProvider internal provider;

    SessionCalendar internal calendar;

    MarketHoursSentinel internal sentinel;

    address internal poolAdmin = makeAddr("poolAdmin");

    address internal riskAdmin = makeAddr("riskAdmin");

    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(T0);

        provider = new PoolAddressesProvider("Tokenized Stocks", address(this));
        provider.setACLAdmin(address(this));
        ACLManager aclManager = new ACLManager(provider);
        provider.setACLManager(address(aclManager));
        aclManager.addPoolAdmin(poolAdmin);
        aclManager.addRiskAdmin(riskAdmin);

        calendar = new SessionCalendar();
        calendar.appendWindows(_single(SESSION_START, SESSION_END));

        sentinel = new MarketHoursSentinel(_provider(), calendar, OPENING_GRACE);
    }

    /*//////////////////////////////////////////////////////////////
                               DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Deployment stores the provider, the calendar, and the opening grace, and exposes its bounds
    function test_constructor_setsState() public view {
        assertEq(address(sentinel.ADDRESSES_PROVIDER()), address(provider));
        assertEq(address(sentinel.CALENDAR()), address(calendar));
        assertEq(sentinel.openingGrace(), OPENING_GRACE);
        assertEq(sentinel.MAX_OPENING_GRACE(), 12 hours);
    }

    /// @notice Zero addresses and an opening grace above twelve hours are rejected
    function test_constructor_revertsOnInvalidInputs() public {
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        new MarketHoursSentinel(IPoolAddressesProvider(address(0)), calendar, OPENING_GRACE);

        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        new MarketHoursSentinel(_provider(), ISessionCalendar(address(0)), OPENING_GRACE);

        vm.expectRevert(IMarketHoursSentinel.InvalidOpeningGrace.selector);
        new MarketHoursSentinel(_provider(), calendar, 12 hours + 1);

        vm.expectRevert(IMarketHoursSentinel.InvalidOpeningGrace.selector);
        new MarketHoursSentinel(_provider(), calendar, type(uint256).max);
    }

    /// @notice Deployment accepts disabled, one-second, and twelve-hour graces with their exact boundaries
    function test_constructor_acceptsDisabledAndPositiveGraces() public {
        sentinel = new MarketHoursSentinel(_provider(), calendar, 0);
        vm.warp(SESSION_START);
        _assertOpen();

        sentinel = new MarketHoursSentinel(_provider(), calendar, 1);
        _assertHeld(SESSION_START + 1);
        vm.warp(SESSION_START + 1);
        _assertOpen();

        sentinel = new MarketHoursSentinel(_provider(), calendar, 12 hours);
        _assertGraceEndBoundary(SESSION_START + 12 hours);
    }

    /// @notice A calendar with no code, no windows, or no window that has yet to end is rejected at deployment
    function test_constructor_rejectsUnreadableOrExhaustedCalendar() public {
        SessionCalendar empty = new SessionCalendar();
        SessionCalendar exhausted = new SessionCalendar();
        exhausted.appendWindows(_single(T0 + 1, T0 + 1 + 8 hours));

        vm.expectRevert(IMarketHoursSentinel.InvalidCalendar.selector);
        new MarketHoursSentinel(_provider(), ISessionCalendar(makeAddr("calendarV2")), OPENING_GRACE);

        vm.expectRevert(IMarketHoursSentinel.InvalidCalendar.selector);
        new MarketHoursSentinel(_provider(), empty, OPENING_GRACE);

        vm.warp(T0 + 1 + 8 hours);
        vm.expectRevert(IMarketHoursSentinel.InvalidCalendar.selector);
        new MarketHoursSentinel(_provider(), exhausted, OPENING_GRACE);
    }

    /**
     * @notice A calendar that cannot answer the view the gate reads is rejected at deployment
     * @dev While enabled, the gate reads lastStartedWindow on liquidations at or above a 0.95 health factor.
     *      A calendar that answers for its stored windows but not that call would pass a shape-only probe and
     *      then revert those liquidations until the grace is disabled.
     */
    function test_constructor_rejectsCalendarThatCannotAnswerLastStartedWindow() public {
        vm.mockCallRevert(
            address(calendar), abi.encodeCall(ISessionCalendar.lastStartedWindow, (block.timestamp)), "calendar gone"
        );

        vm.expectRevert(IMarketHoursSentinel.InvalidCalendar.selector);
        new MarketHoursSentinel(_provider(), calendar, OPENING_GRACE);
    }

    /**
     * @notice A calendar that cannot report its own windows is rejected at deployment
     * @dev The shape probe reads the window count and then the last window, so a calendar that carries code
     *      and answers lastStartedWindow can still fail either one. The same target is deployed against first
     *      with both views answering, so each rejection is the reverting view rather than a target the sentinel
     *      would never have taken.
     */
    function test_constructor_rejectsCalendarThatCannotReportItsWindows() public {
        MockBrokenCalendar broken = new MockBrokenCalendar(uint64(SESSION_START), uint64(SESSION_END));
        ISessionCalendar brokenCalendar = ISessionCalendar(address(broken));

        MarketHoursSentinel accepted = new MarketHoursSentinel(_provider(), brokenCalendar, OPENING_GRACE);
        assertEq(address(accepted.CALENDAR()), address(broken));

        broken.setRevertOnWindowCount(true);
        vm.expectRevert(IMarketHoursSentinel.InvalidCalendar.selector);
        new MarketHoursSentinel(_provider(), brokenCalendar, OPENING_GRACE);

        broken.setRevertOnWindowCount(false);
        broken.setRevertOnWindowAt(true);
        vm.expectRevert(IMarketHoursSentinel.InvalidCalendar.selector);
        new MarketHoursSentinel(_provider(), brokenCalendar, OPENING_GRACE);
    }

    /*//////////////////////////////////////////////////////////////
                               CORE HOOKS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The two hooks and the provider getter keep the selectors of the core's IPriceOracleSentinel
     * @dev The sentinel no longer inherits that interface, so the calls the core makes are pinned here instead.
     */
    function test_hooks_matchTheCoreSentinelSelectors() public pure {
        assertEq(
            bytes32(IMarketHoursSentinel.isBorrowAllowed.selector),
            bytes32(IPriceOracleSentinel.isBorrowAllowed.selector)
        );
        assertEq(
            bytes32(IMarketHoursSentinel.isLiquidationAllowed.selector),
            bytes32(IPriceOracleSentinel.isLiquidationAllowed.selector)
        );
        assertEq(
            bytes32(IMarketHoursSentinel.ADDRESSES_PROVIDER.selector),
            bytes32(IPriceOracleSentinel.ADDRESSES_PROVIDER.selector)
        );
    }

    /*//////////////////////////////////////////////////////////////
                             OPENING GRACE
    //////////////////////////////////////////////////////////////*/

    /// @notice Before the first window starts nothing is held
    function test_checks_openBeforeTheFirstWindow() public view {
        _assertOpen();
    }

    /// @notice The hold runs from the session start to the last second of the grace and lifts on the next
    function test_checks_holdsForTheOpeningGrace() public {
        vm.warp(SESSION_START);
        _assertHeld(SESSION_START + OPENING_GRACE);

        vm.warp(SESSION_START + OPENING_GRACE - 1);
        _assertHeld(SESSION_START + OPENING_GRACE);

        vm.warp(SESSION_START + OPENING_GRACE);
        _assertOpen();
    }

    /// @notice A live session past its grace, a closed market, and an exhausted schedule all read open
    function test_checks_openMidSessionThroughTheClosureAndAfterTheSchedule() public {
        vm.warp(SESSION_START + 2 days);
        _assertOpen();

        vm.warp(SESSION_END);
        _assertOpen();

        vm.warp(SESSION_END + 3 days);
        _assertOpen();

        vm.warp(SESSION_END + 400 days);
        _assertOpen();
    }

    /**
     * @notice Adjacent windows start a new grace at the shared second although the market never read closed
     * @dev One window ending as the next starts is a reopen, so the hold restarts at the boundary exactly as it
     *      does at any other session start.
     */
    function test_checks_adjacentWindowsRestartTheOpeningGrace() public {
        calendar.appendWindows(_single(SESSION_END, SESSION_END + 5 days));

        vm.warp(SESSION_END - 1);
        _assertOpen();

        vm.warp(SESSION_END);
        _assertHeld(SESSION_END + OPENING_GRACE);

        vm.warp(SESSION_END + OPENING_GRACE - 1);
        _assertHeld(SESSION_END + OPENING_GRACE);

        vm.warp(SESSION_END + OPENING_GRACE);
        _assertOpen();
    }

    /**
     * @notice A session truncated inside its own grace ends the hold at the new close
     * @dev The hold only runs while the window is open, so a closed market reads open even when the session
     *      that just ended opened less than an opening grace ago, and the view reports the new close.
     */
    function test_checks_truncationInsideTheGraceEndsItAtTheNewClose() public {
        vm.warp(SESSION_START + 10 minutes);
        _assertHeld(SESSION_START + OPENING_GRACE);

        calendar.truncateCurrentWindow(uint64(SESSION_START + 30 minutes));
        _assertHeld(SESSION_START + 30 minutes);

        vm.warp(SESSION_START + 30 minutes - 1);
        _assertHeld(SESSION_START + 30 minutes);

        vm.warp(SESSION_START + 30 minutes);
        _assertOpen();
    }

    /// @notice A twelve-hour grace ends at an eight-hour window's close without requiring truncation
    function test_checks_graceEndsAtAShorterWindowClose() public {
        calendar = new SessionCalendar();
        calendar.appendWindows(_single(SESSION_START, SESSION_START + 8 hours));
        sentinel = new MarketHoursSentinel(_provider(), calendar, 12 hours);

        vm.warp(SESSION_START);
        _assertHeld(SESSION_START + 8 hours);
        vm.warp(SESSION_START + 8 hours - 1);
        _assertHeld(SESSION_START + 8 hours);
        vm.warp(SESSION_START + 8 hours);
        _assertOpen();
    }

    /// @notice A disabled grace leaves both hooks open even if the calendar stops answering
    function test_checks_disabledGraceSkipsFaultingCalendar() public {
        vm.prank(riskAdmin);
        sentinel.setOpeningGrace(0);
        vm.warp(SESSION_START);
        vm.mockCallRevert(
            address(calendar), abi.encodeCall(ISessionCalendar.lastStartedWindow, (block.timestamp)), "calendar gone"
        );

        _assertOpen();
    }

    /**
     * @notice A calendar that stops answering reverts the liquidation hook and leaves borrowing untouched
     * @dev The calendar is read directly while the grace is enabled. The core calls the hook for health factors in
     *      [0.95, 1), so a reverting calendar can stall those liquidations and nothing else; the borrow hook
     *      reads nothing.
     */
    function test_checks_calendarFaultStallsOnlyTheLiquidationHook() public {
        vm.warp(SESSION_START + 2 days);
        vm.mockCallRevert(
            address(calendar), abi.encodeCall(ISessionCalendar.lastStartedWindow, (block.timestamp)), "calendar gone"
        );

        vm.expectRevert(bytes("calendar gone"));
        sentinel.isLiquidationAllowed();
        vm.expectRevert(bytes("calendar gone"));
        sentinel.liquidationGraceUntil();
        assertTrue(sentinel.isBorrowAllowed());
    }

    /**
     * @notice The frontend view and the liquidation verdict agree at every moment, and borrowing never closes
     * @param elapsed Seconds since deployment, spanning the closure before the window, the window, and the
     *        closure after it
     */
    function testFuzz_checks_viewAndVerdictAgree(uint256 elapsed) public {
        vm.warp(T0 + bound(elapsed, 0, 10 days));

        uint256 graceUntil = sentinel.liquidationGraceUntil();
        bool inGrace = block.timestamp >= SESSION_START && block.timestamp < SESSION_START + OPENING_GRACE;

        assertEq(sentinel.isLiquidationAllowed(), graceUntil == 0);
        assertEq(graceUntil, inGrace ? SESSION_START + OPENING_GRACE : 0);
        assertTrue(sentinel.isBorrowAllowed());
    }

    /**
     * @notice The hold covers every second of the configured grace
     * @param offset Elapsed seconds within the opening grace
     */
    function testFuzz_checks_heldThroughoutTheOpeningGrace(uint256 offset) public {
        vm.warp(SESSION_START + bound(offset, 0, OPENING_GRACE - 1));
        _assertHeld(SESSION_START + OPENING_GRACE);

        vm.warp(SESSION_START + OPENING_GRACE);
        _assertOpen();
    }

    /*//////////////////////////////////////////////////////////////
                                  ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Risk and pool admins can disable the grace or set up to twelve hours; anyone else is refused
    function test_setOpeningGrace_riskOrPoolAdminWithinBounds() public {
        vm.expectEmit(false, false, false, true);
        emit IMarketHoursSentinel.OpeningGraceUpdated(OPENING_GRACE, 2 hours);
        vm.prank(riskAdmin);
        sentinel.setOpeningGrace(2 hours);
        vm.warp(SESSION_START + 2 hours - 1);
        _assertHeld(SESSION_START + 2 hours);
        vm.warp(SESSION_START + 2 hours);
        _assertOpen();

        vm.prank(poolAdmin);
        sentinel.setOpeningGrace(12 hours);
        _assertHeld(SESSION_START + 12 hours);
        vm.warp(SESSION_START + 12 hours - 1);
        _assertGraceEndBoundary(SESSION_START + 12 hours);
        vm.prank(poolAdmin);
        sentinel.setOpeningGrace(1);
        assertEq(sentinel.openingGrace(), 1);
        vm.prank(poolAdmin);
        sentinel.setOpeningGrace(0);
        _assertOpen();

        vm.prank(riskAdmin);
        vm.expectRevert(IMarketHoursSentinel.InvalidOpeningGrace.selector);
        sentinel.setOpeningGrace(12 hours + 1);
        vm.prank(poolAdmin);
        vm.expectRevert(IMarketHoursSentinel.InvalidOpeningGrace.selector);
        sentinel.setOpeningGrace(type(uint256).max);
        vm.prank(stranger);
        vm.expectRevert(CommonChecksLibrary.UnauthorizedAccess.selector);
        sentinel.setOpeningGrace(2 hours);
    }

    /// @notice Disabling lifts a running hold immediately; re-enabling uses the original session start
    function test_setOpeningGrace_disablesAndReenablesARunningGrace() public {
        vm.warp(SESSION_START + 10 minutes);
        _assertHeld(SESSION_START + OPENING_GRACE);

        vm.prank(stranger);
        vm.expectRevert(CommonChecksLibrary.UnauthorizedAccess.selector);
        sentinel.setOpeningGrace(0);
        _assertHeld(SESSION_START + OPENING_GRACE);

        vm.expectEmit(false, false, false, true);
        emit IMarketHoursSentinel.OpeningGraceUpdated(OPENING_GRACE, 0);
        vm.prank(riskAdmin);
        sentinel.setOpeningGrace(0);
        _assertOpen();

        vm.expectEmit(false, false, false, true);
        emit IMarketHoursSentinel.OpeningGraceUpdated(0, OPENING_GRACE);
        vm.prank(poolAdmin);
        sentinel.setOpeningGrace(OPENING_GRACE);
        _assertHeld(SESSION_START + OPENING_GRACE);

        vm.warp(SESSION_START + OPENING_GRACE);
        _assertOpen();
    }

    /// @notice A new grace length applies to a grace already running, in both directions
    function test_setOpeningGrace_appliesToARunningGrace() public {
        vm.warp(SESSION_START + 90 minutes);
        _assertOpen();

        vm.prank(riskAdmin);
        sentinel.setOpeningGrace(2 hours);
        _assertHeld(SESSION_START + 2 hours);

        vm.prank(riskAdmin);
        sentinel.setOpeningGrace(1 hours);
        _assertOpen();
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the provider typed for the sentinel's constructor
     */
    function _provider() internal view returns (IPoolAddressesProvider) {
        return IPoolAddressesProvider(address(provider));
    }

    /**
     * @notice Asserts an opening grace is running: liquidation held, borrowing open, the view reporting its end
     * @param expectedUntil The timestamp the grace is expected to end at
     */
    function _assertHeld(uint256 expectedUntil) internal view {
        assertFalse(sentinel.isLiquidationAllowed());
        assertTrue(sentinel.isBorrowAllowed());
        assertEq(sentinel.liquidationGraceUntil(), expectedUntil);
    }

    /**
     * @notice Asserts no grace is running: both hooks open and the view reporting 0
     */
    function _assertOpen() internal view {
        assertTrue(sentinel.isLiquidationAllowed());
        assertTrue(sentinel.isBorrowAllowed());
        assertEq(sentinel.liquidationGraceUntil(), 0);
    }

    /**
     * @notice Asserts the grace is active immediately before its end and open at the boundary
     * @param expectedUntil The grace end timestamp
     */
    function _assertGraceEndBoundary(uint256 expectedUntil) internal {
        _assertHeld(expectedUntil);
        vm.warp(expectedUntil);
        _assertOpen();
    }
}
