// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPool} from "@neverland-money/lending-core/contracts/interfaces/IPool.sol";
import {IWETH} from "@neverland-money/lending-core/contracts/misc/interfaces/IWETH.sol";

/**
 * @title INeverlandNativeGateway
 * @author Neverland
 * @notice Native-asset entry point for a single Neverland lending market
 * @dev Thin wrappers around `IPool` that wrap and unwrap the native asset, so a caller never has to
 *      hold the wrapped token to supply, withdraw, borrow, or repay it. Market rules apply unchanged.
 */
interface INeverlandNativeGateway {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Thrown when the native asset reaches the gateway from anything but the wrapped token
     * @param sender The unexpected caller
     */
    error DirectNativeTransferNotAllowed(address sender);

    /// @notice Thrown on any call to a function the gateway does not implement
    error FallbackNotAllowed();

    /**
     * @notice Thrown when the caller sends less than the repayment requires
     * @param provided The amount sent
     * @param required The amount needed
     */
    error InsufficientRepaymentValue(uint256 provided, uint256 required);

    /**
     * @notice Thrown when a native transfer out of the gateway fails
     * @param to The intended recipient
     * @param amount The amount that failed to send
     */
    error NativeTransferFailed(address to, uint256 amount);

    /// @notice Thrown when ownership renouncement is attempted; the gateway must stay owned
    error OwnershipRequired();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when the owner recovers an accidentally transferred ERC20 from the gateway
     * @param token The token recovered
     * @param to The recipient of the recovered tokens
     * @param amount The amount recovered
     */
    event ERC20Recovered(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice Emitted when the owner recovers the native asset from the gateway
     * @param to The recipient of the recovered amount
     * @param amount The amount recovered
     */
    event NativeRecovered(address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Recovers the native asset sent directly to the gateway (owner only)
     * @param to The recipient of the recovered amount
     * @param amount The amount to recover
     */
    function emergencyNativeTransfer(address to, uint256 amount) external;

    /**
     * @notice Recovers ERC20 tokens sent directly to the gateway (owner only)
     * @param token The token to recover
     * @param to The recipient of the recovered tokens
     * @param amount The amount to recover
     */
    function emergencyTokenTransfer(address token, address to, uint256 amount) external;

    /**
     * @notice Renouncing ownership is disabled; the gateway must stay able to recover stuck funds
     * @dev Reverts on every call.
     */
    function renounceOwnership() external view;

    /*//////////////////////////////////////////////////////////////
                            USER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Borrows on behalf of the caller, unwraps, and sends the native asset to the caller
     * @dev The caller must first grant the gateway borrow allowance via `approveDelegation`.
     * @param amount The amount to borrow
     * @param interestRateMode The interest rate mode of the new debt
     * @param referralCode Integrator referral code, 0 if none
     */
    function borrow(uint256 amount, uint256 interestRateMode, uint16 referralCode) external;

    /**
     * @notice Repays a borrow with the attached native asset
     * @dev Anything sent beyond the amount repaid is refunded in the same transaction.
     * @param amount The amount to repay, or `type(uint256).max` for the full debt
     * @param rateMode The interest rate mode of the debt being repaid
     * @param onBehalfOf The address whose debt is repaid
     */
    function repay(uint256 amount, uint256 rateMode, address onBehalfOf) external payable;

    /**
     * @notice Supplies the attached native asset as its wrapped token and mints nTokens to `onBehalfOf`
     * @param onBehalfOf The address receiving the nTokens
     * @param referralCode Integrator referral code, 0 if none
     */
    function supply(address onBehalfOf, uint16 referralCode) external payable;

    /**
     * @notice Withdraws from the pool, unwraps, and sends the native asset to `to`
     * @dev The caller must have approved the gateway on the nToken.
     * @param amount The amount to withdraw, or `type(uint256).max` for the caller's full balance
     * @param to The address receiving the native asset
     */
    function withdraw(uint256 amount, address to) external;

    /**
     * @notice Withdraws using an EIP-2612 permit on the nToken, unwraps, and sends the native asset to `to`
     * @dev Signed over `amount`, not the resolved amount; a permit already consumed elsewhere is tolerated.
     * @param amount The amount to withdraw, or `type(uint256).max` for the caller's full balance
     * @param to The address receiving the native asset
     * @param deadline The permit validity deadline
     * @param permitV The V component of the permit signature
     * @param permitR The R component of the permit signature
     * @param permitS The S component of the permit signature
     */
    function withdrawWithPermit(
        uint256 amount,
        address to,
        uint256 deadline,
        uint8 permitV,
        bytes32 permitR,
        bytes32 permitS
    ) external;

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The lending pool this gateway is bound to
     * @return The lending pool
     */
    function POOL() external view returns (IPool);

    /**
     * @notice The wrapped native token this gateway wraps into
     * @return The wrapped native token
     */
    function WRAPPED_NATIVE() external view returns (IWETH);
}
