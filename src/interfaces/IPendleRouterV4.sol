// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/**
 * @title IPendleRouterV4
 * @author Neverland
 * @notice Subset of the Pendle V4 router used to buy a PT with a single token
 * @dev Struct layouts match the router ABI byte for byte; only the members the gateway uses are declared.
 */
interface IPendleRouterV4 {
    /// @notice Aggregator kind for a token swap before minting SY; `NONE` for a direct deposit
    enum SwapType {
        NONE,
        KYBERSWAP,
        ODOS,
        ETH_WETH,
        OKX,
        ONE_INCH,
        PARASWAP,
        RESERVE_2,
        RESERVE_3,
        RESERVE_4,
        RESERVE_5
    }

    /// @notice Limit-order direction
    enum OrderType {
        SY_FOR_PT,
        PT_FOR_SY,
        SY_FOR_YT,
        YT_FOR_SY
    }

    /**
     * @notice Aggregator swap executed before minting SY
     * @param swapType The aggregator kind
     * @param extRouter The aggregator router
     * @param extCalldata The aggregator calldata
     * @param needScale Whether the router rescales the calldata amounts to the actual input
     */
    struct SwapData {
        SwapType swapType;
        address extRouter;
        bytes extCalldata;
        bool needScale;
    }

    /**
     * @notice The token spent and how it becomes SY
     * @param tokenIn The token spent
     * @param netTokenIn The amount spent
     * @param tokenMintSy The token the SY accepts for minting
     * @param pendleSwap The Pendle swap helper, zero for a direct deposit
     * @param swapData The aggregator swap, `NONE` for a direct deposit
     */
    struct TokenInput {
        address tokenIn;
        uint256 netTokenIn;
        address tokenMintSy;
        address pendleSwap;
        SwapData swapData;
    }

    /**
     * @notice Bounds for the router's PT-out search
     * @param guessMin Lower bound
     * @param guessMax Upper bound
     * @param guessOffchain Exact off-chain guess, 0 for the on-chain search
     * @param maxIteration Search iterations
     * @param eps Relative precision, 1e18 = 100%
     */
    struct ApproxParams {
        uint256 guessMin;
        uint256 guessMax;
        uint256 guessOffchain;
        uint256 maxIteration;
        uint256 eps;
    }

    /**
     * @notice A signed limit order
     * @param salt Uniqueness salt
     * @param expiry Expiry timestamp
     * @param nonce Maker nonce
     * @param orderType The order direction
     * @param token The token the maker spends or receives
     * @param YT The yield token of the market
     * @param maker The order maker
     * @param receiver The recipient of the maker's proceeds
     * @param makingAmount The amount the maker offers
     * @param lnImpliedRate The ln implied rate of the order
     * @param failSafeRate The rate bound at which the order stops filling
     * @param permit Optional permit data for the maker's token
     */
    struct Order {
        uint256 salt;
        uint256 expiry;
        uint256 nonce;
        OrderType orderType;
        address token;
        address YT;
        address maker;
        address receiver;
        uint256 makingAmount;
        uint256 lnImpliedRate;
        uint256 failSafeRate;
        bytes permit;
    }

    /**
     * @notice A limit order with the amount to fill
     * @param order The order
     * @param signature The maker signature
     * @param makingAmount The amount to fill
     */
    struct FillOrderParams {
        Order order;
        bytes signature;
        uint256 makingAmount;
    }

    /**
     * @notice Limit orders to fill alongside the AMM swap
     * @param limitRouter The limit router
     * @param epsSkipMarket Relative precision under which the AMM is skipped
     * @param normalFills Orders filled before the swap
     * @param flashFills Orders filled inside the swap
     * @param optData Optional router data
     */
    struct LimitOrderData {
        address limitRouter;
        uint256 epsSkipMarket;
        FillOrderParams[] normalFills;
        FillOrderParams[] flashFills;
        bytes optData;
    }

    /**
     * @notice Buys PT with an exact amount of a token
     * @param receiver Recipient of the PT
     * @param market The Pendle market
     * @param minPtOut Minimum PT out
     * @param guessPtOut Search bounds
     * @param input The token spent
     * @param limit Limit orders to fill, empty for none
     * @return netPtOut PT received
     * @return netSyFee Fee paid in SY
     * @return netSyInterm SY minted from the token
     */
    function swapExactTokenForPt(
        address receiver,
        address market,
        uint256 minPtOut,
        ApproxParams calldata guessPtOut,
        TokenInput calldata input,
        LimitOrderData calldata limit
    ) external payable returns (uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm);
}
