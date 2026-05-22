// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/**
 * @title ILeaderboardKeeper
 * @author Neverland
 * @notice Interface for automated user state verification and settlement
 * @dev Separated sync methods for VP, NFTs, LP. Settlement is independent.
 */
interface ILeaderboardKeeper {
    /*//////////////////////////////////////////////////////////////
                                        EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when voting power is synced for a user
     * @param user User address
     * @param votingPower Total voting power from all veNFTs
     * @param timestamp Block timestamp
     */
    event VotingPowerSynced(address indexed user, uint256 votingPower, uint256 timestamp);

    /**
     * @notice Emitted when NFT collection balance is synced for a user
     * @param user User address
     * @param collection NFT collection address
     * @param balance Number of NFTs from this collection
     * @param timestamp Block timestamp
     */
    event NFTBalanceSynced(address indexed user, address indexed collection, uint256 balance, uint256 timestamp);

    /**
     * @notice Emitted when LP position is synced with full position data
     * @param user User address owning the position
     * @param pool LP pool address
     * @param tokenId Position NFT token ID
     * @param tickLower Lower tick of position range
     * @param tickUpper Upper tick of position range
     * @param liquidity Liquidity amount in the position
     * @param timestamp Block timestamp
     */
    event LPPositionSynced(
        address indexed user,
        address indexed pool,
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 timestamp
    );

    /**
     * @notice Emitted to trigger point settlement for a user
     * @dev Emitted by both keeper-driven settle() and user-driven syncMyState().
     *      Off-chain consumers must not infer keeper origin from UserSettled alone.
     *      Use tx.sender or the BatchComplete("settle", ...) event for keeper batches.
     * @param user User address
     * @param timestamp Block timestamp
     */
    event UserSettled(address indexed user, uint256 timestamp);

    /**
     * @notice Emitted when batch operation completes
     * @param operation Operation type (sync_vp, sync_nft, sync_lp, settle)
     * @param count Number of items processed
     * @param timestamp Block timestamp
     */
    event BatchComplete(string operation, uint256 count, uint256 timestamp);

    /**
     * @notice Emitted when keeper address changes
     * @param oldKeeper Previous keeper address
     * @param newKeeper New keeper address
     */
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);

    /**
     * @notice Emitted when minimum settlement interval changes
     * @param oldInterval Previous interval in seconds
     * @param newInterval New interval in seconds
     */
    event MinSettlementIntervalUpdated(uint256 oldInterval, uint256 newInterval);

    /**
     * @notice Emitted when self-sync cooldown changes
     * @param oldCooldown Previous cooldown in seconds
     * @param newCooldown New cooldown in seconds
     */
    event SelfSyncCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);

    /*//////////////////////////////////////////////////////////////
                                        ERRORS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Thrown when arrays have mismatched lengths
     * @param expected Expected length
     * @param actual Actual length
     */
    error ArrayLengthMismatch(uint256 expected, uint256 actual);

    /**
     * @notice Thrown when batch size exceeds maximum
     * @param batchSize Attempted batch size
     * @param maxBatchSize Maximum allowed batch size
     */
    error BatchTooLarge(uint256 batchSize, uint256 maxBatchSize);

    /**
     * @notice Thrown when caller is not keeper or owner
     * @param caller Address of caller
     */
    error NotKeeper(address caller);

    /**
     * @notice Thrown when trying to sync/settle user too soon
     * @param user User address
     * @param timeSinceLast Time since last action
     * @param minInterval Required minimum interval
     */
    error CooldownNotElapsed(address user, uint256 timeSinceLast, uint256 minInterval);

    /*//////////////////////////////////////////////////////////////
                                       ACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sync voting power for multiple users
     * @param users Array of user addresses
     * @param votingPowers Array of voting power values
     */
    function syncVotingPower(address[] calldata users, uint256[] calldata votingPowers) external;

    /**
     * @notice Sync NFT balances for users across collections
     * @param users Array of user addresses
     * @param collections Array of NFT collection addresses
     * @param balances Array of balances (indexed as [userIndex * collectionsLength + collectionIndex])
     */
    function syncNFTBalances(address[] calldata users, address[] calldata collections, uint256[] calldata balances)
        external;

    /**
     * @notice Sync LP positions with full position data for indexer
     * @param users Array of user addresses
     * @param pools Array of pool addresses
     * @param tokenIds Array of position NFT token IDs
     * @param tickLowers Array of lower ticks
     * @param tickUppers Array of upper ticks
     * @param liquidities Array of liquidity amounts
     * @dev Emits LPPositionSynced for each position so indexer can build positions without RPC
     */
    function syncLPPositions(
        address[] calldata users,
        address[] calldata pools,
        uint256[] calldata tokenIds,
        int24[] calldata tickLowers,
        int24[] calldata tickUppers,
        uint128[] calldata liquidities
    ) external;

    /**
     * @notice Trigger settlement for multiple users
     * @param users Array of user addresses to settle
     */
    function settle(address[] calldata users) external;

    /**
     * @notice Emergency function to settle a single user (bypasses cooldown)
     * @param user User address to settle
     */
    function emergencySettle(address user) external;

    /**
     * @notice User-callable function to sync their own state
     * @dev Emits only UserSettled; indexers must re-read user VP/NFT/LP.
     *      UserSettled is shared with keeper settle() and is not a keeper-only signal.
     * @dev Subject to cooldown to prevent spam
     */
    function syncMyState() external;

    /**
     * @notice Update keeper address
     * @param newKeeper New keeper address
     */
    function setKeeper(address newKeeper) external;

    /**
     * @notice Update minimum settlement interval
     * @param newInterval New interval in seconds
     */
    function setMinSettlementInterval(uint256 newInterval) external;

    /**
     * @notice Update self-sync cooldown
     * @param newCooldown New cooldown in seconds
     */
    function setSelfSyncCooldown(uint256 newCooldown) external;

    /*//////////////////////////////////////////////////////////////
                                         VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get keeper address
     * @return Keeper address
     */
    function keeper() external view returns (address);

    /**
     * @notice Get minimum settlement interval
     * @return Minimum interval in seconds
     */
    function minSettlementInterval() external view returns (uint256);

    /**
     * @notice Get last settlement timestamp for a user
     * @param user User address
     * @return Last settlement timestamp
     */
    function lastSettlement(address user) external view returns (uint256);

    /**
     * @notice Get maximum batch size for sync operations
     * @return Maximum batch size
     */
    function MAX_BATCH_SIZE() external view returns (uint256);
}
