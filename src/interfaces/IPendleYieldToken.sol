// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/**
 * @title IPendleYieldToken
 * @author Neverland
 * @notice Subset of a Pendle yield token used to redeem a matured PT into SY
 */
interface IPendleYieldToken {
    /**
     * @notice Redeems the PT (and, before maturity, YT) held by the yield token into SY
     * @param receiver The recipient of the SY
     * @return amountSyOut The SY sent to `receiver`
     */
    function redeemPY(address receiver) external returns (uint256 amountSyOut);

    /**
     * @notice Stored high-water index used to convert PT into SY
     * @return index Stored index, scaled by 1e18
     */
    function pyIndexStored() external view returns (uint256 index);
}
