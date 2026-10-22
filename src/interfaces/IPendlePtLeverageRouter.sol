// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPendleRouterV4} from "./IPendleRouterV4.sol";

/**
 * @title IPendlePtLeverageRouter
 * @author Neverland
 * @notice Typed Pendle V4 PT sales extension; struct layouts match the router ABI.
 */
interface IPendlePtLeverageRouter is IPendleRouterV4 {
    /**
     * @notice SY redemption route for a PT sale.
     * @param tokenOut Output token, fixed to the leverager debt asset.
     * @param minTokenOut Router minimum; aggregate protection is enforced by the leverager.
     * @param tokenRedeemSy SY redemption token, fixed to the debt asset.
     * @param pendleSwap Aggregator helper, zero for the direct route.
     * @param swapData Empty aggregator data with swap type NONE.
     */
    struct TokenOutput {
        address tokenOut;
        uint256 minTokenOut;
        address tokenRedeemSy;
        address pendleSwap;
        SwapData swapData;
    }

    /**
     * @notice Sell exact PT for one output token.
     * @param receiver Recipient of output tokens.
     * @param market Pendle market.
     * @param exactPtIn Exact PT sold.
     * @param output Typed token output route.
     * @param limit Limit orders, empty for the leverager.
     * @return netTokenOut Router-reported output; the leverager measures actual balance changes.
     * @return netSyFee SY fee.
     * @return netSyInterm Intermediate SY proceeds.
     */
    function swapExactPtForToken(
        address receiver,
        address market,
        uint256 exactPtIn,
        TokenOutput calldata output,
        LimitOrderData calldata limit
    ) external returns (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm);
}
