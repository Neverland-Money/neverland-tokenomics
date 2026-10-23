// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin-v5/contracts/token/ERC20/IERC20.sol";

/**
 * @title INeverlandAssetRedemption
 * @author Neverland
 * @notice Interface for single-pair redemption of a bearer asset into a destination token
 * @dev A holder surrenders the source token and receives the destination token at
 *      `floor(amount * exchangeRate / FROM_DENOMINATOR)`. The rate is expressed in destination-token
 *      base units per whole source token. Possession of the source token is the entitlement, so there
 *      is no claim list. Payouts are limited by the contract's actual destination-token balance. Rate
 *      updates apply only while paused and only to future redemptions. Source-token recovery requires
 *      zero destination liquidity and does not change the administrative pause state. Recovered bearer
 *      units remain redeemable if recirculated, so governance must account for their later disposition.
 *      Both assets must have exact-transfer, non-rebasing ERC20 semantics, and the source and destination
 *      token addresses must differ. Ownership renouncement is disabled to preserve lifecycle controls.
 */
interface INeverlandAssetRedemption {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Reverts when the contract holds less of the destination token than the redemption owes
    error InsufficientLiquidity();

    /// @notice Reverts when an exchange rate of zero is supplied
    error InvalidExchangeRate();

    /// @notice Reverts when ownership renouncement is attempted (disabled to keep lifecycle control)
    error OwnershipRequired();

    /// @notice Reverts when source-token recovery is attempted while payout liquidity remains
    error SourceTokenRecoveryLocked();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when the exchange rate changes
     * @param previousRate The rate before the change, or zero during construction
     * @param newRate The rate after the change, in destination-token base units per whole source token
     */
    event ExchangeRateChanged(uint256 previousRate, uint256 newRate);

    /**
     * @notice Emitted when a holder redeems the source token for the destination token
     * @param user The redeeming holder
     * @param amountIn The source token surrendered, in its own base units
     * @param amountOut The destination token paid, in its own base units
     */
    event Redeemed(address indexed user, uint256 amountIn, uint256 amountOut);

    /**
     * @notice Emitted when destination-token liquidity is supplied to the contract
     * @param supplier The account supplying the liquidity
     * @param amount The amount supplied, in destination-token base units
     */
    event Supplied(address indexed supplier, uint256 amount);

    /**
     * @notice Emitted when the owner withdraws a token balance
     * @param token The token withdrawn
     * @param to The recipient, always the current owner
     * @param amount The amount withdrawn, in the token's own base units
     */
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                              ADMIN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pauses redemption (owner only)
     * @dev This is an explicit emergency control. Liquidity can still be supplied or withdrawn while
     *      paused. Reverts with Pausable.EnforcedPause when already paused.
     */
    function pause() external;

    /**
     * @notice Renouncing ownership is disabled to preserve pause and rescue control
     * @dev Reverts on every call.
     */
    function renounceOwnership() external view;

    /**
     * @notice Updates the exchange rate applied to future redemptions (owner only, while paused)
     * @dev The rate is cumulative rather than incremental and is not applied retroactively. Reverts
     *      with `InvalidExchangeRate` for zero and with Pausable.ExpectedPause while redemption is live.
     *      Emits `ExchangeRateChanged`.
     * @param newRate The destination-token base units payable per whole source token
     */
    function setExchangeRate(uint256 newRate) external;

    /**
     * @notice Resumes redemption (owner only)
     * @dev Reverts with Pausable.ExpectedPause when redemption is already live.
     */
    function unpause() external;

    /**
     * @notice Withdraws a token amount to the owner, or the full balance for the maximum sentinel (owner only)
     * @dev `type(uint256).max` resolves to the contract's current token balance and emits that resolved
     *      amount. Source-token recovery requires zero destination-token liquidity and preserves the
     *      current pause state. Recovered source remains redeemable if governance recirculates it. Reverts
     *      with CommonChecksLibrary.ZeroAmount when `amount` is zero and CommonChecksLibrary.ZeroBalance
     *      when the maximum sentinel resolves to zero. Emits `Withdrawn`.
     * @param token The token to withdraw
     * @param amount The amount to withdraw in token base units, or `type(uint256).max` for the full balance
     */
    function withdraw(IERC20 token, uint256 amount) external;

    /*//////////////////////////////////////////////////////////////
                     LIQUIDITY AND REDEMPTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Surrenders the source token and receives the destination token at the current rate
     * @dev Reverts with CommonChecksLibrary.ZeroAmount when `amount` is zero, and with the same error
     *      when the amount is small enough that the payout floors to zero, so a transfer is never
     *      consumed without payment. Reverts with `InsufficientLiquidity` when the contract cannot cover
     *      the payout. Emits `Redeemed`.
     * @param amount The source token to surrender, in its own base units
     * @return amountOut The destination token paid, in its own base units
     */
    function redeem(uint256 amount) external returns (uint256 amountOut);

    /**
     * @notice Supplies destination-token liquidity to the contract
     * @dev Permissionless; the supplier must have approved this contract. A direct token transfer also
     *      works and is not blockable, so no cumulative supply counter is kept: it could be bypassed and
     *      would then disagree with the balance. `availableLiquidity` is the authoritative figure and the
     *      `Supplied` event is the record. Reverts with CommonChecksLibrary.ZeroAmount on zero.
     * @param amount The amount to supply, in destination-token base units
     */
    function supply(uint256 amount) external;

    /*//////////////////////////////////////////////////////////////
                              VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Ten raised to the source token's decimals, the divisor in the rate formula
     * @return The source token's denominator
     */
    function FROM_DENOMINATOR() external view returns (uint256);

    /**
     * @notice The token surrendered on redemption
     * @return The source token
     */
    function FROM_TOKEN() external view returns (IERC20);

    /**
     * @notice The token paid out on redemption
     * @return The destination token
     */
    function TO_TOKEN() external view returns (IERC20);

    /**
     * @notice The destination-token balance currently available to pay redemptions
     * @return The authoritative liquidity figure, in destination-token base units
     */
    function availableLiquidity() external view returns (uint256);

    /**
     * @notice Quotes the destination token payable for a given source amount
     * @dev Uses full-precision multiplication and floors the result. Truncation favours the contract.
     * @param amount The source token amount, in its own base units
     * @return amountOut The destination token payable, in its own base units
     */
    function calculateRedeem(uint256 amount) external view returns (uint256 amountOut);

    /**
     * @notice The current destination-token base units payable per whole source token
     * @return The current exchange rate
     */
    function exchangeRate() external view returns (uint256);

    /**
     * @notice Returns the largest source-token amount payable from current destination liquidity
     * @dev Uses the same floored quote as `calculateRedeem`. Returns zero when no positive redemption is
     *      payable, including at zero liquidity. Saturates at uint256 maximum when every representable
     *      source amount is covered.
     * @return The exact largest payable source-token amount, in source-token base units
     */
    function maxRedeemable() external view returns (uint256);

    /**
     * @notice The cumulative destination token paid out to redeemers
     * @dev Saturates at uint256 maximum rather than blocking redemption. `Redeemed` events preserve the
     *      exact per-redemption history beyond that theoretical boundary.
     * @return The cumulative payout, in destination-token base units, capped at uint256 maximum
     */
    function totalPaid() external view returns (uint256);

    /**
     * @notice The cumulative source token surrendered
     * @dev Saturates at uint256 maximum rather than blocking redemption. `Redeemed` events preserve the
     *      exact per-redemption history beyond that theoretical boundary.
     * @return The cumulative intake, in source-token base units, capped at uint256 maximum
     */
    function totalRedeemed() external view returns (uint256);
}
