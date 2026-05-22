// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IDustLock} from "../interfaces/IDustLock.sol";
import {IDustLockLegendaryLedger} from "../interfaces/IDustLockLegendaryLedger.sol";

import {CommonChecksLibrary} from "../libraries/CommonChecksLibrary.sol";

/**
 * @title DustLockLegendaryLedger
 * @author Neverland
 * @notice Minimal non-upgradeable gateway that mints self-owned veDUST locks
 *         through DustLock and stores immutable legendary-attempt type flags on-chain.
 * @dev This gateway intentionally anchors attempt data on-chain and leaves legendary
 *      outcome resolution to off-chain metadata services for immediate UX.
 *      Legendary outcomes are cosmetic metadata only and do not alter lock accounting,
 *      governance power, reward accrual, or custody of user funds.
 *      DustLock will observe this ledger as the caller during mint, so downstream consumers must not assume
 *      DustLock-side provider fields always equal the end user when ledger-backed mints are enabled.
 *      This contract does not accept native ETH; plain transfers revert because it exposes no payable receive
 *      or fallback function. If native balance is forcibly credited by protocol-level mechanisms,
 *      owner can sweep it with recoverNative.
 */
contract DustLockLegendaryLedger is IDustLockLegendaryLedger, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint8 private constant LEGENDARY_ATTEMPT_NONE = 0;
    uint8 private constant LEGENDARY_ATTEMPT_TIMED = 1;
    uint8 private constant LEGENDARY_ATTEMPT_PERMANENT = 2;

    /*//////////////////////////////////////////////////////////////
                           IMMUTABLE STATE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDustLockLegendaryLedger
    IDustLock public immutable override dustLock;

    /// @inheritdoc IDustLockLegendaryLedger
    IERC20 public immutable override dustToken;

    /*//////////////////////////////////////////////////////////////
                           ATTEMPT CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @dev Minimum DUST amount required for gateway mint acceptance.
    uint256 private _legendaryAttemptThreshold;

    /// @dev Per-token attempt type (0 none, 1 timed, 2 permanent).
    mapping(uint256 tokenId => uint8 attemptType) private _legendaryAttemptTypeByTokenId;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys the legendary gateway for a DustLock instance.
     * @dev The constructor discovers the underlying DUST token from DustLock and stores both
     *      addresses as immutables. Ownership is explicitly assigned and renouncement stays disabled.
     *      Legendary outcome resolution is intentionally off-chain and this contract
     *      only anchors attempt existence and type.
     * @param dustLock_ DustLock contract used for canonical veDUST minting.
     * @param initialOwner_ Address that will control the gateway threshold.
     * @param threshold_ Minimum DUST required for gateway mint acceptance.
     */
    constructor(address dustLock_, address initialOwner_, uint256 threshold_) {
        CommonChecksLibrary.revertIfZeroAddress(dustLock_);
        CommonChecksLibrary.revertIfZeroAddress(initialOwner_);
        if (threshold_ == 0) revert InvalidLegendaryAttemptThreshold();

        dustLock = IDustLock(dustLock_);

        address dustTokenAddress = IDustLock(dustLock_).token();
        CommonChecksLibrary.revertIfZeroAddress(dustTokenAddress);
        dustToken = IERC20(dustTokenAddress);

        _legendaryAttemptThreshold = threshold_;
        emit LegendaryAttemptThresholdUpdated(threshold_);

        _transferOwnership(initialOwner_);
    }

    /*//////////////////////////////////////////////////////////////
                              MINT FLOWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDustLockLegendaryLedger
    function createLock(uint256 value, uint256 lockDuration) external override nonReentrant returns (uint256 tokenId) {
        tokenId = _createLockFor(msg.sender, value, lockDuration, false);
    }

    /// @inheritdoc IDustLockLegendaryLedger
    function createLockPermanent(uint256 value, uint256 lockDuration)
        external
        override
        nonReentrant
        returns (uint256 tokenId)
    {
        // DustLock enforces duration constraints; gateway forwards lockDuration unchanged.
        tokenId = _createLockFor(msg.sender, value, lockDuration, true);
    }

    /**
     * @notice Pulls DUST from the user, mints through DustLock, and stores a legendary-attempt type flag.
     * @dev Reverts early when value_ is below the configured gateway threshold
     *      or when DustLock's canonical minLockAmount has drifted above that threshold.
     *      The flow is intentionally atomic: any downstream revert unwinds the prior transfer and approval.
     *      Approval is explicitly reset to zero post-mint as defense-in-depth.
     *      Emits LegendaryLedgerAttemptRecorded so off-chain consumers can attribute self-mints to owner_
     *      without relying on DustLock.Deposit.provider.
     *      Attempt anchoring is immutable per token id and does not perform on-chain
     *      legendary outcome resolution.
     * @param owner_ End user receiving the veDUST position.
     * @param value_ Amount of DUST to lock.
     * @param lockDuration_ Lock duration forwarded into DustLock.
     * @param permanent_ Whether the mint should be converted into a permanent lock.
     * @return tokenId Newly minted DustLock token id.
     */
    function _createLockFor(address owner_, uint256 value_, uint256 lockDuration_, bool permanent_)
        internal
        returns (uint256 tokenId)
    {
        uint256 threshold = _legendaryAttemptThreshold;
        if (value_ < threshold) revert LockAmountBelowLegendaryThreshold(value_, threshold);
        uint256 dustMin = dustLock.minLockAmount();
        if (value_ < dustMin) revert LockAmountBelowDustLockMinimum(value_, dustMin);

        dustToken.safeTransferFrom(owner_, address(this), value_);
        dustToken.forceApprove(address(dustLock), value_);

        tokenId = permanent_
            ? dustLock.createLockPermanentFor(value_, lockDuration_, owner_)
            : dustLock.createLockFor(value_, lockDuration_, owner_);

        dustToken.forceApprove(address(dustLock), 0);
        uint8 attemptType = _recordLegendaryAttempt(tokenId, permanent_);

        emit LegendaryLedgerAttemptRecorded(owner_, tokenId, attemptType, value_, lockDuration_);
    }

    /*//////////////////////////////////////////////////////////////
                         LEGENDARY ATTEMPT LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Records an immutable mint-time attempt type flag for off-chain resolution.
     * @dev Attempt type is 1 for timed mints and 2 for permanent mints.
     * @param tokenId_ Newly minted DustLock token id.
     * @param permanent_ Whether the mint used createLockPermanent flow.
     */
    function _recordLegendaryAttempt(uint256 tokenId_, bool permanent_) internal returns (uint8 attemptType) {
        attemptType = permanent_ ? LEGENDARY_ATTEMPT_PERMANENT : LEGENDARY_ATTEMPT_TIMED;
        _legendaryAttemptTypeByTokenId[tokenId_] = attemptType;
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDustLockLegendaryLedger
    function legendaryAttemptTypeOf(uint256 tokenId) external view override returns (uint8 attemptType) {
        attemptType = _legendaryAttemptTypeByTokenId[tokenId];
    }

    /// @inheritdoc IDustLockLegendaryLedger
    function hasLegendaryAttempt(uint256 tokenId) external view override returns (bool) {
        return _legendaryAttemptTypeByTokenId[tokenId] != LEGENDARY_ATTEMPT_NONE;
    }

    /// @inheritdoc IDustLockLegendaryLedger
    function legendaryAttemptThreshold() external view override returns (uint256 threshold) {
        threshold = _legendaryAttemptThreshold;
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDustLockLegendaryLedger
    function setLegendaryAttemptThreshold(uint256 threshold) external override onlyOwner {
        if (threshold == 0) revert InvalidLegendaryAttemptThreshold();
        if (threshold == _legendaryAttemptThreshold) return;
        _legendaryAttemptThreshold = threshold;

        emit LegendaryAttemptThresholdUpdated(threshold);
    }

    /// @inheritdoc IDustLockLegendaryLedger
    function recoverERC20(address token, address recipient, uint256 amount) external override onlyOwner nonReentrant {
        if (token == address(0)) revert InvalidERC20RecoveryToken();
        if (recipient == address(0)) revert InvalidERC20RecoveryRecipient();
        if (amount == 0) revert InvalidERC20RecoveryAmount();

        IERC20(token).safeTransfer(recipient, amount);

        emit ERC20Recovered(token, recipient, amount);
    }

    /// @inheritdoc IDustLockLegendaryLedger
    function recoverNative(address recipient, uint256 amount) external override onlyOwner nonReentrant {
        if (recipient == address(0)) revert InvalidNativeRecoveryRecipient();
        if (amount == 0) revert InvalidNativeRecoveryAmount();
        uint256 nativeBalance = address(this).balance;
        if (amount > nativeBalance) revert InsufficientNativeRecoveryBalance(amount, nativeBalance);

        (bool success,) = payable(recipient).call{value: amount}("");
        if (!success) revert NativeRecoveryFailed();

        emit NativeRecovered(recipient, amount);
    }

    /// @inheritdoc IDustLockLegendaryLedger
    function renounceOwnership() public view override(Ownable, IDustLockLegendaryLedger) onlyOwner {
        revert RenounceOwnershipDisabled();
    }
}
