// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/**
 * @title IPendleMarket
 * @author Neverland
 * @notice Subset of a Pendle market used to resolve its tokens and maturity
 */
interface IPendleMarket {
    /**
     * @notice Whether the market has reached its maturity
     * @return True once expired
     */
    function isExpired() external view returns (bool);

    /**
     * @notice The tokens the market trades
     * @return sy The standardized yield token
     * @return pt The principal token
     * @return yt The yield token
     */
    function readTokens() external view returns (address sy, address pt, address yt);
}
