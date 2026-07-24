// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

import {GPv2SafeERC20} from "@aave/core-v3/contracts/dependencies/gnosis/contracts/GPv2SafeERC20.sol";
import {IERC20} from "@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20.sol";
import {SafeERC20} from "@aave/core-v3/contracts/dependencies/openzeppelin/contracts/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IDustLock} from "../interfaces/IDustLock.sol";
import {IDustLockTransferStrategy, IDustTransferStrategy} from "../interfaces/IDustLockTransferStrategy.sol";
import {IDustRewardsController} from "../interfaces/IDustRewardsController.sol";

import {CommonChecksLibrary} from "../libraries/CommonChecksLibrary.sol";

import {DustTransferStrategyBase} from "./DustTransferStrategyBase.sol";

/**
 * @title DustLockTransferStrategy
 * @author Neverland
 * @notice NGV-05 transfer strategy that prices gross DUST reward release by
 *         realized commitment, routes the exact penalty to the configured
 *         early-exit burn wallet, and sends net proceeds to a wallet or veDUST lock.
 * @dev Gross controller accrual is unchanged. Every nonzero transfer requires
 *      the DustLock V3 quote capability before the vault pull.
 */
contract DustLockTransferStrategy is DustTransferStrategyBase, IDustLockTransferStrategy {
    using GPv2SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Maximum lock duration for veDUST
    uint256 internal constant MAX_LOCK_DURATION = 365 days;

    /// @dev Minimum timed commitment eligible for a reward lock
    uint256 internal constant MIN_LOCK_DURATION = 28 days;

    /// @dev DustLock unlock-time rounding unit
    uint256 internal constant WEEK = 1 weeks;

    /**
     * @dev Commitments at or above this band are untolled: every route to a maximum-duration
     *      position (permanent claim, max-duration timed claim, or deposit into a max lock)
     *      lands above it, so all of them price identically at zero.
     */
    uint256 internal constant ZERO_TOLL_COMMITMENT = MAX_LOCK_DURATION - WEEK;

    /// @dev Basis-point denominator used by timed-claim penalty pricing
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev Maximum timed-claim penalty: 40% at minimum commitment, declining to zero at maximum
    uint256 internal constant MAX_TIMED_CLAIM_PENALTY_BPS = 4_000;

    /// @inheritdoc IDustLockTransferStrategy
    uint256 public constant version = 3;

    /*//////////////////////////////////////////////////////////////
                          STORAGE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDustLockTransferStrategy
    IDustLock public immutable DUST_LOCK;

    /// @inheritdoc IDustLockTransferStrategy
    address public immutable DUST_VAULT;

    /// @inheritdoc IDustLockTransferStrategy
    address public immutable DUST;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Constructs the DUST lock transfer strategy
     * @param incentivesController The incentives controller authorized to call performTransfer
     * @param rewardsAdmin The rewards admin allowed to emergency withdraw tokens
     * @param dustVault The vault address that holds DUST balances
     * @param dustLock The DustLock contract address
     */
    constructor(address incentivesController, address rewardsAdmin, address dustVault, address dustLock)
        DustTransferStrategyBase(incentivesController, rewardsAdmin)
    {
        CommonChecksLibrary.revertIfZeroAddress(incentivesController);
        CommonChecksLibrary.revertIfZeroAddress(rewardsAdmin);
        CommonChecksLibrary.revertIfZeroAddress(dustVault);
        CommonChecksLibrary.revertIfZeroAddress(dustLock);

        DUST_VAULT = dustVault;
        DUST_LOCK = IDustLock(dustLock);
        DUST = DUST_LOCK.token();
    }

    /*//////////////////////////////////////////////////////////////
                         TRANSFER STRATEGY
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc DustTransferStrategyBase
    function performTransfer(address to, address reward, uint256 amount, uint256 lockTime, uint256 tokenId)
        external
        override(DustTransferStrategyBase, IDustTransferStrategy)
        onlyIncentivesController
        returns (bool)
    {
        // Gracefully handle zero amount transfers
        if (amount == 0) return true;
        CommonChecksLibrary.revertIfInvalidToAddress(to);
        if (reward != DUST) revert InvalidRewardAddress();
        if (tokenId > 0 && DUST_LOCK.ownerOf(tokenId) != to) revert NotTokenOwner();
        (uint256 penaltyAmount, uint256 netAmount) = _previewClaim(amount, lockTime, tokenId);
        if (!_hasClaimReformCapability()) revert DustLockClaimReformInactive();

        address penaltyRecipient;
        if (penaltyAmount != 0) {
            penaltyRecipient = DUST_LOCK.earlyWithdrawTreasury();
            CommonChecksLibrary.revertIfZeroAddress(penaltyRecipient);
        }

        IERC20 rewardToken = IERC20(reward);
        rewardToken.safeTransferFrom(DUST_VAULT, address(this), amount);
        if (penaltyAmount != 0) rewardToken.safeTransfer(penaltyRecipient, penaltyAmount);

        /*
         * tokenId > 0                      -> add DUST to existing veDUST
         * tokenId == 0 && lockTime > 0     -> create new veDUST lock
         * tokenId == 0 && lockTime == max  -> create permanent veDUST lock
         * tokenId == 0 && lockTime == 0    -> direct DUST transfer with fixed instant-claim penalty
         */
        uint256 destinationTokenId = tokenId;
        if (tokenId > 0) {
            // Add DUST to existing veDUST
            SafeERC20.safeIncreaseAllowance(rewardToken, address(DUST_LOCK), netAmount);
            DUST_LOCK.depositFor(tokenId, netAmount);
            SafeERC20.safeApprove(rewardToken, address(DUST_LOCK), 0);
        } else if (lockTime > 0) {
            // Create new veDUST lock; use type(uint256).max as the sentinel for permanent locks
            bool makePermanent = lockTime == type(uint256).max;

            SafeERC20.safeIncreaseAllowance(rewardToken, address(DUST_LOCK), netAmount);
            destinationTokenId = makePermanent
                ? DUST_LOCK.createLockPermanentFor(netAmount, MAX_LOCK_DURATION, to)
                : DUST_LOCK.createLockFor(netAmount, lockTime, to);

            SafeERC20.safeApprove(rewardToken, address(DUST_LOCK), 0);
        } else {
            rewardToken.safeTransfer(to, netAmount);
        }

        emit RewardClaimPriced(to, destinationTokenId, lockTime, amount, penaltyAmount, netAmount);

        return true;
    }

    /// @inheritdoc IDustLockTransferStrategy
    function previewClaim(uint256 amount, uint256 lockTime, uint256 tokenId)
        external
        view
        override
        returns (uint256 penaltyAmount, uint256 netAmount)
    {
        return _previewClaim(amount, lockTime, tokenId);
    }

    /// @inheritdoc IDustLockTransferStrategy
    function assertActivationState(bool expectedActive) external view override {
        if (IDustRewardsController(INCENTIVES_CONTROLLER).getTransferStrategy(DUST) != address(this)) {
            revert InvalidActivationState();
        }
        if (IERC20(DUST).allowance(DUST_VAULT, address(this)) != type(uint256).max) {
            revert InvalidActivationState();
        }
        if (DUST_LOCK.token() != DUST) revert InvalidActivationState();
        if (DUST_LOCK.earlyWithdrawTreasury() == address(0)) revert InvalidActivationState();

        if (_hasClaimReformCapability() != expectedActive) revert InvalidActivationState();
    }

    /**
     * @notice Quotes the exact penalty allocation and proceeds for each supported claim route
     * @param amount Gross DUST reward amount
     * @param lockTime Requested duration, zero for instant, or max uint for permanent
     * @param tokenId Existing veNFT to receive the reward, or zero for a new position
     * @return penaltyAmount Exact DUST amount routed to the early-exit burn wallet
     * @return netAmount Exact liquid or locked user proceeds
     */
    function _previewClaim(uint256 amount, uint256 lockTime, uint256 tokenId)
        internal
        view
        returns (uint256 penaltyAmount, uint256 netAmount)
    {
        if (amount == 0) return (0, 0);

        uint256 commitment;
        if (tokenId > 0) {
            IDustLock.LockedBalance memory lock = DUST_LOCK.locked(tokenId);
            if (lock.isPermanent) return (0, amount);
            if (lock.end <= block.timestamp) revert IDustLock.LockExpired();

            commitment = lock.end - block.timestamp;
            if (commitment < MIN_LOCK_DURATION) revert IDustLock.DepositForLockDurationTooShort();
            if (commitment > MAX_LOCK_DURATION) revert IDustLock.LockDurationTooLong();
        } else if (lockTime == 0) {
            penaltyAmount = amount / 2;
            return (penaltyAmount, amount - penaltyAmount);
        } else if (lockTime == type(uint256).max) {
            return (0, amount);
        } else {
            uint256 unlockTime = ((block.timestamp + lockTime) / WEEK) * WEEK;
            if (unlockTime > block.timestamp + MAX_LOCK_DURATION) revert IDustLock.LockDurationTooLong();
            if (unlockTime <= block.timestamp) revert IDustLock.LockDurationTooShort();

            commitment = unlockTime - block.timestamp;
            if (commitment < MIN_LOCK_DURATION) revert IDustLock.LockDurationTooShort();
        }

        /*
         * Commitments in the top week band are untolled: permanent and max-duration positions price
         * identically at zero, so claiming permanent and then unlocking buys nothing.
         */
        if (commitment >= ZERO_TOLL_COMMITMENT) return (0, amount);

        penaltyAmount = Math.mulDiv(
            amount,
            MAX_TIMED_CLAIM_PENALTY_BPS * (MAX_LOCK_DURATION - commitment),
            BPS_DENOMINATOR * (MAX_LOCK_DURATION - MIN_LOCK_DURATION),
            Math.Rounding.Up
        );
        netAmount = amount - penaltyAmount;
    }

    /**
     * @notice Checks the DustLock V3 quote capability with bounded return-data copying
     * @return hasCapability True only when the capability probe succeeds and returns exactly zero
     */
    function _hasClaimReformCapability() internal view returns (bool hasCapability) {
        address dustLock = address(DUST_LOCK);
        uint256 selector = uint32(IDustLock.earlyWithdrawPenaltyAmount.selector);
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, selector))
            mstore(add(ptr, 4), 0)
            let success := staticcall(gas(), dustLock, ptr, 36, ptr, 32)
            hasCapability := and(success, and(eq(returndatasize(), 32), iszero(mload(ptr))))
        }
    }
}
