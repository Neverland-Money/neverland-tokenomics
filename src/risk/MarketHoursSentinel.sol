// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IACLManager} from "@neverland-money/lending-core/contracts/interfaces/IACLManager.sol";
import {IPoolAddressesProvider} from "@neverland-money/lending-core/contracts/interfaces/IPoolAddressesProvider.sol";

import {IMarketHoursSentinel} from "../interfaces/IMarketHoursSentinel.sol";
import {ISessionCalendar} from "../interfaces/ISessionCalendar.sol";

import {CommonChecksLibrary} from "../libraries/CommonChecksLibrary.sol";

/**
 * @title MarketHoursSentinel
 * @author Neverland
 * @notice Price-oracle sentinel for a tokenized stock pool: a deterministic grace after every market open
 * @dev Direct deployment, no upgrade path, no owner. The pool runs through market closures on the last print
 *      and nothing off chain feeds this contract. For openingGrace seconds after each calendar window opens,
 *      liquidation of positions in the core's [0.95, 1) health-factor band is held while the reopen gap is
 *      repaired; below 0.95 the core never consults the sentinel, and borrowing is never gated. The calendar
 *      is read directly while the grace is enabled: it is validated at deployment and fixed for life.
 *      Zero disables the hold; the maximum is twelve hours. Launch opening grace: 3,600 seconds.
 */
contract MarketHoursSentinel is IMarketHoursSentinel {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMarketHoursSentinel
    uint256 public constant MAX_OPENING_GRACE = 12 hours;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMarketHoursSentinel
    IPoolAddressesProvider public immutable ADDRESSES_PROVIDER;

    /// @inheritdoc IMarketHoursSentinel
    ISessionCalendar public immutable CALENDAR;

    /*//////////////////////////////////////////////////////////////
                            STORAGE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMarketHoursSentinel
    uint256 public openingGrace;

    /*//////////////////////////////////////////////////////////////
                             ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts the caller to risk or pool admins on the pool's ACLManager
    modifier onlyRiskOrPoolAdmins() {
        IACLManager aclManager = IACLManager(ADDRESSES_PROVIDER.getACLManager());
        if (!aclManager.isRiskAdmin(msg.sender) && !aclManager.isPoolAdmin(msg.sender)) {
            revert CommonChecksLibrary.UnauthorizedAccess();
        }

        _;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys the sentinel
     * @dev Reverts on a zero provider or calendar, on an opening grace above MAX_OPENING_GRACE, and on a
     *      calendar that cannot be read or holds no window that has yet to end. Zero disables the grace.
     * @param provider The pool's PoolAddressesProvider, used to resolve the ACLManager
     * @param sessionCalendar The trading-session calendar
     * @param initialOpeningGrace The post-open grace window in seconds, or zero to disable it
     */
    constructor(IPoolAddressesProvider provider, ISessionCalendar sessionCalendar, uint256 initialOpeningGrace) {
        CommonChecksLibrary.revertIfZeroAddress(address(provider));
        CommonChecksLibrary.revertIfZeroAddress(address(sessionCalendar));
        _revertIfInvalidOpeningGrace(initialOpeningGrace);
        _revertIfInvalidCalendar(address(sessionCalendar));

        ADDRESSES_PROVIDER = provider;
        CALENDAR = sessionCalendar;
        openingGrace = initialOpeningGrace;
    }

    /*//////////////////////////////////////////////////////////////
                                  ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMarketHoursSentinel
    function setOpeningGrace(uint256 newOpeningGrace) external onlyRiskOrPoolAdmins {
        _revertIfInvalidOpeningGrace(newOpeningGrace);

        uint256 previousOpeningGrace = openingGrace;
        openingGrace = newOpeningGrace;

        emit OpeningGraceUpdated(previousOpeningGrace, newOpeningGrace);
    }

    /*//////////////////////////////////////////////////////////////
                             SENTINEL CHECKS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMarketHoursSentinel
    function isBorrowAllowed() external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IMarketHoursSentinel
    function isLiquidationAllowed() external view returns (bool) {
        return _liquidationGraceUntil() == 0;
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMarketHoursSentinel
    function liquidationGraceUntil() external view returns (uint256) {
        return _liquidationGraceUntil();
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns when the running opening grace ends, or 0 when none is running
     * @dev A zero opening grace returns immediately without reading the calendar. Otherwise the grace runs
     *      from the start of the last window that has started to the earlier of that start plus openingGrace
     *      and the window's end. A shorter window or a truncation can end the grace early. With no started
     *      window the calendar answers the zero window, whose end of 0 bounds the grace to 0, so the market
     *      reads open before the schedule begins without a separate branch.
     * @return The grace end timestamp, or 0
     */
    function _liquidationGraceUntil() private view returns (uint256) {
        uint256 grace = openingGrace;
        if (grace == 0) return 0;

        ISessionCalendar.Window memory window = CALENDAR.lastStartedWindow(block.timestamp);
        uint256 graceEnd = window.start + grace;
        if (graceEnd > window.end) graceEnd = window.end;

        return block.timestamp < graceEnd ? graceEnd : 0;
    }

    /**
     * @notice Reverts when an opening grace exceeds MAX_OPENING_GRACE
     * @param candidate The opening grace to validate
     */
    function _revertIfInvalidOpeningGrace(uint256 candidate) private pure {
        if (candidate > MAX_OPENING_GRACE) revert InvalidOpeningGrace();
    }

    /**
     * @notice Reverts when a calendar cannot be read or holds no window that has yet to end
     * @dev Probes the schedule's shape through windowCount and windowAt, then lastStartedWindow, the view the
     *      gate reads while the grace is enabled. The calendar is fixed at deployment, so a target that cannot
     *      answer one of them is rejected here. An exhausted schedule is rejected too: it would never grant
     *      an opening grace again.
     * @param candidate The calendar to validate
     */
    function _revertIfInvalidCalendar(address candidate) private view {
        if (candidate.code.length == 0) revert InvalidCalendar();

        uint256 count;
        try ISessionCalendar(candidate).windowCount() returns (uint256 stored) {
            count = stored;
        } catch {
            revert InvalidCalendar();
        }
        if (count == 0) revert InvalidCalendar();

        try ISessionCalendar(candidate).windowAt(count - 1) returns (ISessionCalendar.Window memory last) {
            if (last.end <= block.timestamp) revert InvalidCalendar();
        } catch {
            revert InvalidCalendar();
        }

        try ISessionCalendar(candidate).lastStartedWindow(block.timestamp) returns (ISessionCalendar.Window memory) {
            return;
        } catch {
            revert InvalidCalendar();
        }
    }
}
