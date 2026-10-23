// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/**
 * @title IPendleMaturityPrincipalToken
 * @author Neverland
 * @notice Subset of a Pendle principal token used to detect maturity and resolve its SY and YT
 */
interface IPendleMaturityPrincipalToken {
    /**
     * @notice Whether the token has reached its maturity
     * @return True once expired
     */
    function isExpired() external view returns (bool);

    /**
     * @notice The standardized yield token backing this PT
     * @return The SY address
     */
    function SY() external view returns (address);

    /**
     * @notice The yield token paired with this PT
     * @return The YT address
     */
    function YT() external view returns (address);
}
