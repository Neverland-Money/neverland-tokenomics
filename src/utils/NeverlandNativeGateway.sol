// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAToken} from "@neverland-money/lending-core/contracts/interfaces/IAToken.sol";
import {IPool} from "@neverland-money/lending-core/contracts/interfaces/IPool.sol";
import {IWETH} from "@neverland-money/lending-core/contracts/misc/interfaces/IWETH.sol";
import {DataTypes} from "@neverland-money/lending-core/contracts/protocol/libraries/types/DataTypes.sol";
import {Ownable} from "@openzeppelin-v5/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin-v5/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin-v5/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-v5/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin-v5/contracts/utils/ReentrancyGuard.sol";

import {INeverlandNativeGateway} from "../interfaces/INeverlandNativeGateway.sol";

import {CommonChecksLibrary} from "../libraries/CommonChecksLibrary.sol";

/**
 * @title NeverlandNativeGateway
 * @author Neverland
 * @notice Native-asset entry point for a single Neverland lending market
 * @dev Wraps the native asset a caller sends before forwarding it to the pool, and unwraps it on the
 *      way out, so the market's wrapped native reserve is used without the caller ever holding it.
 */
contract NeverlandNativeGateway is INeverlandNativeGateway, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /**
     * @notice Binds the gateway to its wrapped native token and pool and assigns the governance owner
     * @dev Approves the pool for unlimited wrapped native so supply and repay forward in one call.
     * @param wrappedNative_ The wrapped native token address
     * @param pool_ The lending pool this gateway serves
     * @param initialOwner_ The governance address receiving ownership at construction
     */
    constructor(IWETH wrappedNative_, IPool pool_, address initialOwner_) Ownable(initialOwner_) {
        CommonChecksLibrary.revertIfZeroAddress(address(wrappedNative_));
        CommonChecksLibrary.revertIfZeroAddress(address(pool_));

        WRAPPED_NATIVE = wrappedNative_;
        POOL = pool_;

        wrappedNative_.approve(address(pool_), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandNativeGateway
    IWETH public immutable WRAPPED_NATIVE;

    /// @inheritdoc INeverlandNativeGateway
    IPool public immutable POOL;

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandNativeGateway
    function emergencyNativeTransfer(address to, uint256 amount) external onlyOwner {
        CommonChecksLibrary.revertIfZeroAddress(to);

        _safeTransferNative(to, amount);

        emit NativeRecovered(to, amount);
    }

    /// @inheritdoc INeverlandNativeGateway
    function emergencyTokenTransfer(address token, address to, uint256 amount) external onlyOwner {
        CommonChecksLibrary.revertIfZeroAddress(to);

        IERC20(token).safeTransfer(to, amount);

        emit ERC20Recovered(token, to, amount);
    }

    /// @inheritdoc INeverlandNativeGateway
    function renounceOwnership() public view override(INeverlandNativeGateway, Ownable) onlyOwner {
        revert OwnershipRequired();
    }

    /*//////////////////////////////////////////////////////////////
                            USER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandNativeGateway
    function supply(address onBehalfOf, uint16 referralCode) external payable nonReentrant {
        CommonChecksLibrary.revertIfInvalidUserAddress(onBehalfOf);

        WRAPPED_NATIVE.deposit{value: msg.value}();
        POOL.supply(address(WRAPPED_NATIVE), msg.value, onBehalfOf, referralCode);
    }

    /// @inheritdoc INeverlandNativeGateway
    function withdraw(uint256 amount, address to) external nonReentrant {
        IAToken nToken = _nToken();

        _withdrawNative(nToken, to, _resolveWithdrawAmount(nToken, amount));
    }

    /// @inheritdoc INeverlandNativeGateway
    function repay(uint256 amount, uint256 rateMode, address onBehalfOf) external payable nonReentrant {
        DataTypes.ReserveData memory reserve = POOL.getReserveData(address(WRAPPED_NATIVE));

        // Full outstanding debt for the requested rate mode.
        uint256 paybackAmount = DataTypes.InterestRateMode(rateMode) == DataTypes.InterestRateMode.STABLE
            ? IERC20(reserve.stableDebtTokenAddress).balanceOf(onBehalfOf)
            : IERC20(reserve.variableDebtTokenAddress).balanceOf(onBehalfOf);

        if (amount < paybackAmount) paybackAmount = amount;
        if (msg.value < paybackAmount) revert InsufficientRepaymentValue(msg.value, paybackAmount);

        WRAPPED_NATIVE.deposit{value: paybackAmount}();

        // The resolved amount, not `msg.value`: only `paybackAmount` was wrapped.
        POOL.repay(address(WRAPPED_NATIVE), paybackAmount, rateMode, onBehalfOf);

        // Refund the overpayment rather than stranding it.
        if (msg.value > paybackAmount) _safeTransferNative(msg.sender, msg.value - paybackAmount);
    }

    /// @inheritdoc INeverlandNativeGateway
    function borrow(uint256 amount, uint256 interestRateMode, uint16 referralCode) external nonReentrant {
        POOL.borrow(address(WRAPPED_NATIVE), amount, interestRateMode, referralCode, msg.sender);
        WRAPPED_NATIVE.withdraw(amount);
        _safeTransferNative(msg.sender, amount);
    }

    /// @inheritdoc INeverlandNativeGateway
    function withdrawWithPermit(
        uint256 amount,
        address to,
        uint256 deadline,
        uint8 permitV,
        bytes32 permitR,
        bytes32 permitS
    ) external nonReentrant {
        IAToken nToken = _nToken();
        uint256 amountToWithdraw = _resolveWithdrawAmount(nToken, amount);

        /*
         * Permit `amount`, not the resolved amount. A permit consumed elsewhere already set the
         * allowance, so tolerating the failure leaves the pull below to gate the withdrawal.
         */
        try nToken.permit(msg.sender, address(this), amount, deadline, permitV, permitR, permitS) {} catch {}

        _withdrawNative(nToken, to, amountToWithdraw);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pulls nTokens from the caller, withdraws, unwraps, and forwards the native asset
     * @param nToken The market's wrapped native nToken
     * @param to The recipient of the native asset
     * @param amountToWithdraw The resolved amount to withdraw
     */
    function _withdrawNative(IAToken nToken, address to, uint256 amountToWithdraw) internal {
        CommonChecksLibrary.revertIfInvalidToAddress(to);

        nToken.transferFrom(msg.sender, address(this), amountToWithdraw);
        POOL.withdraw(address(WRAPPED_NATIVE), amountToWithdraw, address(this));
        WRAPPED_NATIVE.withdraw(amountToWithdraw);

        _safeTransferNative(to, amountToWithdraw);
    }

    /**
     * @notice Sends the native asset, reverting on failure
     * @param to The recipient
     * @param value The amount to send
     */
    function _safeTransferNative(address to, uint256 value) internal {
        (bool success,) = to.call{value: value}(new bytes(0));

        if (!success) revert NativeTransferFailed(to, value);
    }

    /**
     * @notice Resolves a withdrawal request into a concrete nToken amount
     * @param nToken The market's wrapped native nToken
     * @param amount The requested amount, or `type(uint256).max` for the caller's full balance
     * @return amountToWithdraw The concrete amount to withdraw
     */
    function _resolveWithdrawAmount(IAToken nToken, uint256 amount) internal view returns (uint256 amountToWithdraw) {
        if (amount != type(uint256).max) return amount;

        return nToken.balanceOf(msg.sender);
    }

    /**
     * @notice Returns the market's wrapped native nToken
     * @dev Read per call so an nToken upgrade needs no gateway redeploy.
     * @return nToken The wrapped native nToken
     */
    function _nToken() internal view returns (IAToken nToken) {
        return IAToken(POOL.getReserveData(address(WRAPPED_NATIVE)).aTokenAddress);
    }

    /*//////////////////////////////////////////////////////////////
                         NATIVE ASSET HANDLING
    //////////////////////////////////////////////////////////////*/

    /// @notice Accepts the native asset only from the wrapped token, which sends it while unwrapping
    receive() external payable {
        if (msg.sender != address(WRAPPED_NATIVE)) revert DirectNativeTransferNotAllowed(msg.sender);
    }

    /// @notice Rejects any call to a function this gateway does not implement
    fallback() external payable {
        revert FallbackNotAllowed();
    }
}
