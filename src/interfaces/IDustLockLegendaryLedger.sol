// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IDustLock} from "./IDustLock.sol";

/**
 * @title IDustLockLegendaryLedger
 * @author Neverland
 * @notice Gateway that mints self-owned veDUST positions through DustLock and
 *         stores immutable legendary-attempt type flags in the same tx.
 * @dev Legendary attempt state is mint-time and token-bound to the minted token id.
 *      Later DustLock lifecycle actions such as merge, split, withdraw, or earlyWithdraw
 *      do not migrate or recalculate gateway attempt state for replacement token ids.
 *      Legendary outcome resolution intentionally happens off-chain for immediate UX,
 *      while this gateway provides canonical on-chain attempt anchoring.
 */
interface IDustLockLegendaryLedger {
    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Error thrown when legendary-attempt threshold is configured as zero
    error InvalidLegendaryAttemptThreshold();

    /// @notice Error thrown when ownership renouncement is intentionally disabled
    error RenounceOwnershipDisabled();

    /// @notice Error thrown when a gateway mint amount is below the configured threshold
    error LockAmountBelowLegendaryThreshold(uint256 value, uint256 threshold);

    /// @notice Error thrown when DustLock's canonical minimum has drifted above the gateway threshold
    error LockAmountBelowDustLockMinimum(uint256 value, uint256 minLockAmount);

    /// @notice Error thrown when ERC20 recovery token is zero address
    error InvalidERC20RecoveryToken();

    /// @notice Error thrown when ERC20 recovery recipient is zero address
    error InvalidERC20RecoveryRecipient();

    /// @notice Error thrown when ERC20 recovery amount is zero
    error InvalidERC20RecoveryAmount();

    /// @notice Error thrown when native recovery recipient is zero address
    error InvalidNativeRecoveryRecipient();

    /// @notice Error thrown when native recovery amount is zero
    error InvalidNativeRecoveryAmount();

    /// @notice Error thrown when native recovery amount exceeds ledger balance
    error InsufficientNativeRecoveryBalance(uint256 amount, uint256 balance);

    /// @notice Error thrown when native recovery transfer fails
    error NativeRecoveryFailed();

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when the gateway attempt threshold changes
     * @param threshold Minimum DUST amount required for gateway mint acceptance
     */
    event LegendaryAttemptThresholdUpdated(uint256 threshold);

    /**
     * @notice Emitted when owner recovers accidentally transferred ERC20 from the ledger
     * @param token ERC20 token that was recovered
     * @param recipient Address that receives recovered tokens
     * @param amount Amount of tokens recovered
     */
    event ERC20Recovered(address indexed token, address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when owner recovers forcibly credited native gas token from the ledger
     * @param recipient Address that receives recovered native token
     * @param amount Amount of native token recovered
     */
    event NativeRecovered(address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when a ledger-backed self-mint succeeds.
     * @dev This is the canonical off-chain attribution signal for ledger mints.
     *      Consumers should not infer self-mint attribution from DustLock.Deposit.provider,
     *      because DustLock records this ledger as the provider during forwarded mint flows.
     * @param owner End user that receives the newly minted veNFT
     * @param tokenId ID of the newly minted veNFT
     * @param attemptType 1 for timed-lock attempt, 2 for permanent-lock attempt
     * @param value Amount of DUST locked through the ledger
     * @param lockDuration Lock duration forwarded into DustLock
     */
    event LegendaryLedgerAttemptRecorded(
        address indexed owner, uint256 indexed tokenId, uint8 indexed attemptType, uint256 value, uint256 lockDuration
    );

    /*//////////////////////////////////////////////////////////////
                                   VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the canonical DustLock contract used for veDUST minting
     * @return The DustLock contract address
     */
    function dustLock() external view returns (IDustLock);

    /**
     * @notice Returns the underlying DUST token pulled from users before minting
     * @return The underlying DUST token address
     */
    function dustToken() external view returns (IERC20);

    /**
     * @notice Returns the gateway attempt type for a token id.
     * @dev Returns 0 when the token was not minted through this gateway,
     *      1 for timed-lock gateway mints, and 2 for permanent-lock gateway mints.
     * @param tokenId The veNFT id
     * @return attemptType Tri-state attempt flag: 0 = none, 1 = timed, 2 = permanent
     */
    function legendaryAttemptTypeOf(uint256 tokenId) external view returns (uint8 attemptType);

    /**
     * @notice Returns whether a token has a gateway-recorded legendary attempt type.
     * @dev This only reflects gateway attempt anchoring and does not verify that the token id
     *      still exists in DustLock after merge/split/burn flows.
     * @param tokenId The veNFT id
     * @return True when legendaryAttemptTypeOf(tokenId) is nonzero
     */
    function hasLegendaryAttempt(uint256 tokenId) external view returns (bool);

    /**
     * @notice Returns the current gateway attempt threshold
     * @return threshold Minimum DUST amount required for gateway mint acceptance
     */
    function legendaryAttemptThreshold() external view returns (uint256 threshold);

    /*//////////////////////////////////////////////////////////////
                          STATE-CHANGING MINTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a self-owned time-locked veDUST position
     * @dev Reverts when value is below the configured gateway threshold or DustLock's canonical minimum.
     *      Direct calls to DustLock bypass this gateway and therefore bypass on-chain attempt anchoring.
     *      Off-chain consumers should use LegendaryLedgerAttemptRecorded for canonical owner attribution
     *      instead of relying on DustLock.Deposit.provider for ledger-backed mints.
     * @param value Amount of DUST to lock
     * @param lockDuration Lock duration in seconds
     * @return tokenId The newly minted veDUST token id
     */
    function createLock(uint256 value, uint256 lockDuration) external returns (uint256 tokenId);

    /**
     * @notice Creates a self-owned permanent veDUST position
     * @dev Reverts when value is below the configured gateway threshold or DustLock's canonical minimum.
     *      lockDuration is forwarded to DustLock and must satisfy DustLock duration constraints.
     *      Direct calls to DustLock bypass this gateway and therefore bypass on-chain attempt anchoring.
     *      Off-chain consumers should use LegendaryLedgerAttemptRecorded for canonical owner attribution
     *      instead of relying on DustLock.Deposit.provider for ledger-backed mints.
     * @param value Amount of DUST to lock
     * @param lockDuration Lock duration in seconds forwarded to DustLock before permanent conversion
     * @return tokenId The newly minted veDUST token id
     */
    function createLockPermanent(uint256 value, uint256 lockDuration) external returns (uint256 tokenId);

    /*//////////////////////////////////////////////////////////////
                                   ADMIN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the gateway attempt threshold
     * @param threshold Minimum DUST amount required for gateway mint acceptance
     */
    function setLegendaryAttemptThreshold(uint256 threshold) external;

    /**
     * @notice Recovers ERC20 tokens accidentally sent directly to the ledger
     * @dev Owner-only safety function; does not affect DustLock-held user positions.
     *      Native gas token recovery uses recoverNative instead of address(0).
     * @param token ERC20 token to recover
     * @param recipient Address receiving recovered tokens
     * @param amount Amount of tokens to recover
     */
    function recoverERC20(address token, address recipient, uint256 amount) external;

    /**
     * @notice Recovers native gas token forcibly credited to the ledger
     * @dev Owner-only safety function for balances that can appear through protocol-level
     *      mechanisms such as forced sends. Normal direct native transfers still revert because
     *      this contract exposes no payable receive or fallback function.
     * @param recipient Address receiving recovered native token
     * @param amount Amount of native token to recover
     */
    function recoverNative(address recipient, uint256 amount) external;

    /**
     * @notice Reverts to prevent accidental renouncement of ownership.
     * @dev This gateway intentionally disables ownership renouncement.
     */
    function renounceOwnership() external view;
}
