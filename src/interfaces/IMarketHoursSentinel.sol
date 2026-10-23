// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPoolAddressesProvider} from "@neverland-money/lending-core/contracts/interfaces/IPoolAddressesProvider.sol";

import {ISessionCalendar} from "./ISessionCalendar.sol";

/**
 * @title IMarketHoursSentinel
 * @author Neverland
 * @notice Interface for the price-oracle sentinel of a tokenized stock pool
 * @dev Implements the two hooks the lending core reads from its price-oracle sentinel, isBorrowAllowed and
 *      isLiquidationAllowed, without the sequencer surface of the core's IPriceOracleSentinel: the chain has
 *      no sequencer uptime feed and nothing off chain feeds this gate. The pool runs on the last print while
 *      the market is closed. For openingGrace seconds after each calendar window opens, liquidation is held so
 *      nobody is liquidated on a reopen gap they could not act on; the core bypasses the sentinel below health
 *      factor 0.95, and borrowing is never gated. liquidationGraceUntil exposes the hold's end for frontends.
 *      The calendar is immutable; risk or pool admins set the opening grace up to MAX_OPENING_GRACE.
 *      A zero opening grace disables the hold without reading the calendar.
 */
interface IMarketHoursSentinel {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Reverts when a calendar has no code, cannot answer its views, or holds no window that has yet to end
    error InvalidCalendar();

    /// @notice Reverts when an opening grace exceeds MAX_OPENING_GRACE
    error InvalidOpeningGrace();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when a risk or pool admin changes the opening grace
     * @param previousOpeningGrace The previous opening grace in seconds
     * @param newOpeningGrace The new opening grace in seconds
     */
    event OpeningGraceUpdated(uint256 previousOpeningGrace, uint256 newOpeningGrace);

    /*//////////////////////////////////////////////////////////////
                                FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the grace window after each session start (risk or pool admin only)
     * @dev Reverts with InvalidOpeningGrace above MAX_OPENING_GRACE. Zero disables the hold. Applies at once,
     *      to a grace already running included. The feeds print within 90 seconds of every open, so this
     *      window is the time users get to act on the new prices before liquidations at or above a 0.95
     *      health factor resume.
     * @param newOpeningGrace The new opening grace in seconds, or zero to disable it
     */
    function setOpeningGrace(uint256 newOpeningGrace) external;

    /**
     * @notice Returns whether the core may open new debt
     * @dev Always true. Borrowing is not gated on this chain; the function exists because the core's borrow
     *      validation calls it whenever a sentinel is installed.
     * @return True
     */
    function isBorrowAllowed() external view returns (bool);

    /**
     * @notice Returns whether the core may liquidate a position with a health factor in [0.95, 1)
     * @dev False only while an opening grace is running, that is while liquidationGraceUntil is non-zero. A
     *      disabled grace, a closed market, a schedule with no started window, and every moment after the
     *      grace read true.
     * @return True when no opening grace is running
     */
    function isLiquidationAllowed() external view returns (bool);

    /**
     * @notice Returns when the running opening grace ends, or 0 when none is running
     * @dev The grace runs from the start of the last window that has started to the earlier of that start plus
     *      openingGrace and the window's end, so a session shortened inside its own grace ends the grace at the
     *      new close. Returns zero without reading the calendar when disabled. Frontends read this to show
     *      the hold and the time left on it.
     * @return The grace end timestamp, or 0
     */
    function liquidationGraceUntil() external view returns (uint256);

    /**
     * @notice Returns the pool's addresses provider
     * @dev Fixed at deployment; resolves the ACLManager that gates setOpeningGrace.
     * @return The PoolAddressesProvider of the stock pool
     */
    function ADDRESSES_PROVIDER() external view returns (IPoolAddressesProvider);

    /**
     * @notice Returns the session calendar
     * @dev Fixed at deployment, as it is in the price adapters, so both consumers answer from one schedule.
     *      Changing the schedule source means redeploying the sentinel and every adapter and re-pointing
     *      AaveOracle at the new adapters in one governance batch. Deployment validation must assert that
     *      every adapter reports this calendar.
     * @return The calendar read by liquidation checks while the grace is enabled
     */
    function CALENDAR() external view returns (ISessionCalendar);

    /**
     * @notice Returns the largest opening grace risk or pool admins can set
     * @return The maximum opening grace in seconds (12 hours)
     */
    function MAX_OPENING_GRACE() external view returns (uint256);

    /**
     * @notice Returns the grace window after each session start
     * @dev Closed markets hold nothing; only this window after each open does. Zero disables the hold.
     * @return The opening grace in seconds, or zero when disabled
     */
    function openingGrace() external view returns (uint256);
}
