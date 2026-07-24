// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin-v5/contracts/token/ERC20/IERC20.sol";

/**
 * @title IPendlePrincipalToken
 * @author Neverland
 * @notice Minimal interface for a Pendle Principal Token (PT)
 * @dev PTs are ERC20 collateral tokens; only the Pendle-specific `expiry()` extension is declared here.
 *      A PT redeems toward its accounting (underlying) asset at `expiry()`; before maturity it trades
 *      at a discount to that redemption value, and at/after maturity it converges to par.
 */
interface IPendlePrincipalToken is IERC20 {
    /**
     * @notice Returns the UNIX timestamp at which the principal token matures
     * @return The maturity (expiry) timestamp, in seconds since the Unix epoch
     */
    function expiry() external view returns (uint256);
}
