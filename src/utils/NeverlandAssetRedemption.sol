// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin-v5/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin-v5/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin-v5/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin-v5/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin-v5/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin-v5/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin-v5/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin-v5/contracts/utils/math/Math.sol";

import {INeverlandAssetRedemption} from "../interfaces/INeverlandAssetRedemption.sol";

import {CommonChecksLibrary} from "../libraries/CommonChecksLibrary.sol";

/**
 * @title NeverlandAssetRedemption
 * @author Neverland
 * @notice Single-pair redemption of a bearer asset into a destination token at an owner-managed rate
 * @dev A holder surrenders the source token and receives the destination token at
 *      `floor(amount * exchangeRate / FROM_DENOMINATOR)`. The rate is expressed in destination-token
 *      base units per whole source token. Possession of the source token is the entitlement, so there
 *      is no claim list. Payouts are limited by the contract's actual destination-token balance. Rate
 *      updates apply only while paused and only to future redemptions. Source-token recovery requires
 *      zero destination liquidity and does not change the administrative pause state. Recovered bearer
 *      units remain redeemable if recirculated, so governance must account for their later disposition.
 *      Both assets must have exact-transfer, non-rebasing ERC20 semantics, and their addresses must
 *      differ. Ownership renouncement is disabled to preserve lifecycle controls.
 */
contract NeverlandAssetRedemption is INeverlandAssetRedemption, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /**
     * @notice Wires the token pair, initial exchange rate, and governance owner
     * @dev Reverts with `Ownable.OwnableInvalidOwner` for a zero initial owner,
     *      CommonChecksLibrary.AddressZero for a zero token,
     *      CommonChecksLibrary.SameAddress when both token roles are identical, and
     *      `InvalidExchangeRate` for a zero rate. The denominator is read from the source token's decimals
     *      at deployment. Emits `ExchangeRateChanged` from zero to the initial rate. Construction leaves
     *      redemption unpaused; without destination-token liquidity, every nonzero payout still reverts.
     *      The explicit initial owner receives authority atomically at construction. `Ownable2Step`
     *      applies only to future ownership changes, so the deployer receives no temporary authority.
     * @param fromToken_ The token surrendered on redemption
     * @param toToken_ The token paid out on redemption
     * @param exchangeRate_ The initial destination-token base units payable per whole source token
     * @param initialOwner_ The governance address receiving ownership at construction
     */
    constructor(IERC20 fromToken_, IERC20 toToken_, uint256 exchangeRate_, address initialOwner_)
        Ownable(initialOwner_)
    {
        CommonChecksLibrary.revertIfZeroAddress(address(fromToken_));
        CommonChecksLibrary.revertIfZeroAddress(address(toToken_));
        CommonChecksLibrary.revertIfSameAddress(address(fromToken_), address(toToken_));
        if (exchangeRate_ == 0) revert InvalidExchangeRate();

        FROM_TOKEN = fromToken_;
        TO_TOKEN = toToken_;
        FROM_DENOMINATOR = 10 ** IERC20Metadata(address(fromToken_)).decimals();
        exchangeRate = exchangeRate_;

        emit ExchangeRateChanged(0, exchangeRate_);
    }

    /*//////////////////////////////////////////////////////////////
                            IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandAssetRedemption
    uint256 public immutable FROM_DENOMINATOR;

    /// @inheritdoc INeverlandAssetRedemption
    IERC20 public immutable FROM_TOKEN;

    /// @inheritdoc INeverlandAssetRedemption
    IERC20 public immutable TO_TOKEN;

    /*//////////////////////////////////////////////////////////////
                          MUTABLE STATE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandAssetRedemption
    uint256 public exchangeRate;

    /// @inheritdoc INeverlandAssetRedemption
    uint256 public totalPaid;

    /// @inheritdoc INeverlandAssetRedemption
    uint256 public totalRedeemed;

    /*//////////////////////////////////////////////////////////////
                              ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandAssetRedemption
    function withdraw(IERC20 token, uint256 amount) external onlyOwner {
        CommonChecksLibrary.revertIfZeroAmount(amount);
        if (amount == type(uint256).max) {
            amount = token.balanceOf(address(this));
            CommonChecksLibrary.revertIfZeroBalance(amount);
        }

        _withdraw(token, amount);
    }

    /// @inheritdoc INeverlandAssetRedemption
    function setExchangeRate(uint256 newRate) external onlyOwner whenPaused {
        if (newRate == 0) revert InvalidExchangeRate();

        uint256 previousRate = exchangeRate;
        exchangeRate = newRate;

        emit ExchangeRateChanged(previousRate, newRate);
    }

    /// @inheritdoc INeverlandAssetRedemption
    function pause() external onlyOwner {
        _pause();
    }

    /// @inheritdoc INeverlandAssetRedemption
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @inheritdoc INeverlandAssetRedemption
    function renounceOwnership() public view override(INeverlandAssetRedemption, Ownable) onlyOwner {
        revert OwnershipRequired();
    }

    /*//////////////////////////////////////////////////////////////
                     LIQUIDITY AND REDEMPTION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandAssetRedemption
    function supply(uint256 amount) external {
        CommonChecksLibrary.revertIfZeroAmount(amount);

        TO_TOKEN.safeTransferFrom(msg.sender, address(this), amount);

        emit Supplied(msg.sender, amount);
    }

    /// @inheritdoc INeverlandAssetRedemption
    function redeem(uint256 amount) external whenNotPaused nonReentrant returns (uint256 amountOut) {
        CommonChecksLibrary.revertIfZeroAmount(amount);
        amountOut = calculateRedeem(amount);
        CommonChecksLibrary.revertIfZeroAmount(amountOut);
        if (TO_TOKEN.balanceOf(address(this)) < amountOut) revert InsufficientLiquidity();

        FROM_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        totalRedeemed = Math.saturatingAdd(totalRedeemed, amount);
        totalPaid = Math.saturatingAdd(totalPaid, amountOut);
        TO_TOKEN.safeTransfer(msg.sender, amountOut);

        emit Redeemed(msg.sender, amount, amountOut);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandAssetRedemption
    function availableLiquidity() external view returns (uint256) {
        return TO_TOKEN.balanceOf(address(this));
    }

    /// @inheritdoc INeverlandAssetRedemption
    function maxRedeemable() external view returns (uint256) {
        uint256 liquidity = TO_TOKEN.balanceOf(address(this));
        if (liquidity == 0) return 0;

        uint256 rate = exchangeRate;
        uint256 denominator = FROM_DENOMINATOR;
        if (rate <= denominator && Math.mulDiv(type(uint256).max, rate, denominator) <= liquidity) {
            return type(uint256).max;
        }

        if (liquidity < type(uint256).max) {
            return Math.mulDiv(liquidity + 1, denominator, rate, Math.Rounding.Ceil) - 1;
        }

        uint256 quotient = Math.mulDiv(liquidity, denominator, rate);
        uint256 remainder = mulmod(liquidity, denominator, rate);

        return quotient + (remainder >= rate - denominator + 1 ? 1 : 0);
    }

    /// @inheritdoc INeverlandAssetRedemption
    function calculateRedeem(uint256 amount) public view returns (uint256 amountOut) {
        return Math.mulDiv(amount, exchangeRate, FROM_DENOMINATOR);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sends a token amount to the owner
     * @dev Source-token recovery requires zero payout liquidity and preserves the current administrative
     *      pause state. Recovered source remains redeemable if governance recirculates it. No cumulative
     *      counter is kept for liquidity movements: a direct token transfer into the contract cannot be
     *      intercepted, so any such counter could be bypassed and would then disagree with the balance.
     *      `availableLiquidity` is the authoritative figure and the `Withdrawn` event is the record.
     * @param token The token to send
     * @param amount The amount to send, in the token's own base units
     */
    function _withdraw(IERC20 token, uint256 amount) private {
        if (token == FROM_TOKEN) {
            if (TO_TOKEN.balanceOf(address(this)) != 0) revert SourceTokenRecoveryLocked();
        }

        address recipient = owner();
        token.safeTransfer(recipient, amount);

        emit Withdrawn(address(token), recipient, amount);
    }
}
