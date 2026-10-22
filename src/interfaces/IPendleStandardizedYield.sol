// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/**
 * @title IPendleStandardizedYield
 * @author Neverland
 * @notice Subset of a Pendle standardized yield token used to redeem SY into an underlying token
 */
interface IPendleStandardizedYield {
    /**
     * @notice Redeems SY into a token
     * @param receiver The recipient of the token
     * @param amountSharesToRedeem The SY to redeem
     * @param tokenOut The token to receive
     * @param minTokenOut Minimum token out
     * @param burnFromInternalBalance Whether to burn SY already held by the SY contract instead of the caller's
     * @return amountTokenOut The token received
     */
    function redeem(
        address receiver,
        uint256 amountSharesToRedeem,
        address tokenOut,
        uint256 minTokenOut,
        bool burnFromInternalBalance
    ) external returns (uint256 amountTokenOut);

    /**
     * @notice Current asset value of one SY, scaled by 1e18
     * @return rate Assets per SY
     */
    function exchangeRate() external view returns (uint256 rate);

    /**
     * @notice Quotes token output from an SY redemption
     * @param tokenOut The output token
     * @param amountSharesToRedeem SY shares to redeem
     * @return amountTokenOut Quoted output after redemption fees
     */
    function previewRedeem(address tokenOut, uint256 amountSharesToRedeem)
        external
        view
        returns (uint256 amountTokenOut);

    /**
     * @notice Whether the SY accepts a token for minting
     * @param token The token to check
     * @return True if accepted
     */
    function isValidTokenIn(address token) external view returns (bool);

    /**
     * @notice Whether the SY can redeem into a token
     * @param token The token to check
     * @return True if supported
     */
    function isValidTokenOut(address token) external view returns (bool);
}
