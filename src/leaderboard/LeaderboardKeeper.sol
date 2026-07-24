// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;
// Required for optimizer-off Forge coverage: the ABI v2 decoder for
// syncLPPositions' six dynamic calldata arrays overflows the stack.
// Current external parameters are first-order arrays, so ABI coder v1 is sufficient.
pragma abicoder v1;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {ILeaderboardKeeper} from "../interfaces/ILeaderboardKeeper.sol";

import {CommonChecksLibrary} from "../libraries/CommonChecksLibrary.sol";

/**
 * @title ILeaderboardKeeperDustLock
 * @author Neverland
 * @notice Minimal DustLock interface used by LeaderboardKeeper
 */
interface ILeaderboardKeeperDustLock {
    /**
     * @notice Returns the voting power of a specific NFT
     * @param tokenId The ID of the NFT
     * @return The voting power of the NFT
     */
    function balanceOfNFT(uint256 tokenId) external view returns (uint256);

    /**
     * @notice Returns the total number of user NFTs, not voting power
     * @param owner The address of the user
     * @return The total number of user NFTs
     */
    function balanceOf(address owner) external view returns (uint256);

    /**
     * @notice Returns the list of NFTs owned by a user
     * @param owner The address of the user
     * @param index The index of the NFT
     * @return The ID of the NFT
     */
    function ownerToNFTokenIdList(address owner, uint256 index) external view returns (uint256);
}

/**
 * @title ILeaderboardKeeperNFTRegistry
 * @author Neverland
 * @notice Minimal NFT partnership registry interface used by LeaderboardKeeper
 */
interface ILeaderboardKeeperNFTRegistry {
    /**
     * @notice Returns the list of active partnerships
     * @return The list of active partnerships
     */
    function getActivePartnerships() external view returns (address[] memory);
}

/**
 * @title LeaderboardKeeper
 * @author Neverland
 * @notice Handles automated user state verification and settlement
 * @dev Keeper bot submits verified on-chain state, triggers subgraph updates
 * @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
 */
contract LeaderboardKeeper is ILeaderboardKeeper, OwnableUpgradeable {
    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Maximum batch size for sync/settle operations (gas limit protection)
     * @dev Monad charges full gas limit, so larger batches = fewer txs = lower cost
     */
    uint256 public constant MAX_BATCH_SIZE = 400;

    /*//////////////////////////////////////////////////////////////
                            STORAGE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Address authorized to submit state verifications
    address public keeper;

    /// @notice Minimum time between settlements for a user (prevents spam)
    uint256 public minSettlementInterval;

    /// @notice Last settlement timestamp for each user
    mapping(address => uint256) public lastSettlement;

    /// @notice DustLock contract for voting power
    ILeaderboardKeeperDustLock public immutable dustLock;

    /// @notice NFT Partnership Registry for partner collections
    ILeaderboardKeeperNFTRegistry public immutable nftRegistry;

    /// @notice Minimum time between self-syncs (default 1 hour)
    uint256 public selfSyncCooldown;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets immutable dependencies and disables implementation initializers
     * @param _dustLock Address of DustLock used for voting power and ownership snapshots
     * @param _nftRegistry Address of partnership registry used for collection sync
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(address _dustLock, address _nftRegistry) {
        CommonChecksLibrary.revertIfZeroAddress(_dustLock);
        CommonChecksLibrary.revertIfZeroAddress(_nftRegistry);
        dustLock = ILeaderboardKeeperDustLock(_dustLock);
        nftRegistry = ILeaderboardKeeperNFTRegistry(_nftRegistry);
        _disableInitializers();
    }

    /**
     * @notice Initialize keeper contract
     * @param initialOwner Initial owner for Ownable
     * @param initialKeeper Initial keeper address
     * @param initialInterval Initial minimum settlement interval (3600 = 1 hour)
     */
    function initialize(address initialOwner, address initialKeeper, uint256 initialInterval) external initializer {
        __Ownable_init();
        _transferOwnership(initialOwner);
        CommonChecksLibrary.revertIfZeroAddress(initialOwner);
        CommonChecksLibrary.revertIfZeroAddress(initialKeeper);

        keeper = initialKeeper;
        minSettlementInterval = initialInterval;
        selfSyncCooldown = 1 hours; // Default 1 hour cooldown

        emit KeeperUpdated(address(0), initialKeeper);
        emit MinSettlementIntervalUpdated(0, initialInterval);
        emit SelfSyncCooldownUpdated(0, selfSyncCooldown);
    }

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Restrict access to keeper or owner
    modifier onlyKeeper() {
        _revertIfNotKeeperOrOwner();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILeaderboardKeeper
    function syncVotingPower(address[] calldata users, uint256[] calldata votingPowers) external onlyKeeper {
        uint256 len = users.length;

        if (votingPowers.length != len) {
            revert ArrayLengthMismatch(len, votingPowers.length);
        }
        if (len > MAX_BATCH_SIZE) {
            revert BatchTooLarge(len, MAX_BATCH_SIZE);
        }

        for (uint256 i = 0; i < len;) {
            emit VotingPowerSynced(users[i], votingPowers[i], block.timestamp);
            unchecked {
                ++i;
            }
        }

        emit BatchComplete("sync_vp", len, block.timestamp);
    }

    /// @inheritdoc ILeaderboardKeeper
    function syncNFTBalances(address[] calldata users, address[] calldata collections, uint256[] calldata balances)
        external
        onlyKeeper
    {
        uint256 usersLen = users.length;
        uint256 collectionsLen = collections.length;
        uint256 expectedLen = usersLen * collectionsLen;

        if (balances.length != expectedLen) {
            revert ArrayLengthMismatch(expectedLen, balances.length);
        }
        if (expectedLen > MAX_BATCH_SIZE) {
            revert BatchTooLarge(expectedLen, MAX_BATCH_SIZE);
        }

        for (uint256 i = 0; i < usersLen;) {
            address user = users[i];
            for (uint256 j = 0; j < collectionsLen;) {
                emit NFTBalanceSynced(user, collections[j], balances[i * collectionsLen + j], block.timestamp);
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }

        emit BatchComplete("sync_nft", expectedLen, block.timestamp);
    }

    /// @inheritdoc ILeaderboardKeeper
    function syncLPPositions(
        address[] calldata users,
        address[] calldata pools,
        uint256[] calldata tokenIds,
        int24[] calldata tickLowers,
        int24[] calldata tickUppers,
        uint128[] calldata liquidities
    ) external onlyKeeper {
        uint256 len = users.length;

        _revertIfLPPositionLengthMismatch(
            len, pools.length, tokenIds.length, tickLowers.length, tickUppers.length, liquidities.length
        );
        if (len > MAX_BATCH_SIZE) {
            revert BatchTooLarge(len, MAX_BATCH_SIZE);
        }

        for (uint256 i = 0; i < len;) {
            _emitLPPositionSynced(users[i], pools[i], tokenIds[i], tickLowers[i], tickUppers[i], liquidities[i]);
            unchecked {
                ++i;
            }
        }

        emit BatchComplete("sync_lp", len, block.timestamp);
    }

    /// @inheritdoc ILeaderboardKeeper
    function settle(address[] calldata users) external onlyKeeper {
        uint256 len = users.length;

        if (len > MAX_BATCH_SIZE) {
            revert BatchTooLarge(len, MAX_BATCH_SIZE);
        }

        for (uint256 i = 0; i < len;) {
            address user = users[i];

            // Skip if recently settled
            if (block.timestamp < lastSettlement[user] + minSettlementInterval) {
                unchecked {
                    ++i;
                }
                continue;
            }

            emit UserSettled(user, block.timestamp);
            lastSettlement[user] = block.timestamp;

            unchecked {
                ++i;
            }
        }

        emit BatchComplete("settle", len, block.timestamp);
    }

    /// @inheritdoc ILeaderboardKeeper
    function emergencySettle(address user) external onlyOwner {
        CommonChecksLibrary.revertIfZeroAddress(user);

        emit UserSettled(user, block.timestamp);
        lastSettlement[user] = block.timestamp;
    }

    /// @inheritdoc ILeaderboardKeeper
    function syncMyState() external {
        address user = msg.sender;

        // Check cooldown
        uint256 lastSync = lastSettlement[user];
        if (block.timestamp < lastSync + selfSyncCooldown) {
            revert CooldownNotElapsed(user, block.timestamp - lastSync, selfSyncCooldown);
        }

        // Emit settlement event. Off-chain consumers must not infer keeper origin from UserSettled.
        // Use tx.sender or BatchComplete("settle", ...) to identify keeper batches.
        emit UserSettled(user, block.timestamp);
        lastSettlement[user] = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILeaderboardKeeper
    function setKeeper(address newKeeper) external onlyOwner {
        CommonChecksLibrary.revertIfZeroAddress(newKeeper);

        address oldKeeper = keeper;
        keeper = newKeeper;

        emit KeeperUpdated(oldKeeper, newKeeper);
    }

    /// @inheritdoc ILeaderboardKeeper
    function setMinSettlementInterval(uint256 newInterval) external onlyOwner {
        uint256 oldInterval = minSettlementInterval;
        minSettlementInterval = newInterval;

        emit MinSettlementIntervalUpdated(oldInterval, newInterval);
    }

    /// @inheritdoc ILeaderboardKeeper
    function setSelfSyncCooldown(uint256 newCooldown) external onlyOwner {
        uint256 oldCooldown = selfSyncCooldown;
        selfSyncCooldown = newCooldown;

        emit SelfSyncCooldownUpdated(oldCooldown, newCooldown);
    }

    /// @notice Disabled to prevent accidental renouncement of ownership
    function renounceOwnership() public view override onlyOwner {
        // Keep the existing no-data revert surface for deployed LeaderboardKeeper compatibility.
        // solhint-disable-next-line reason-string, gas-custom-errors
        revert();
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emits one LP position sync row for the off-chain leaderboard indexer.
     * @param user User address owning the LP position
     * @param pool LP pool address
     * @param tokenId Position NFT token ID
     * @param tickLower Lower tick of the position range
     * @param tickUpper Upper tick of the position range
     * @param liquidity Liquidity amount in the position
     */
    function _emitLPPositionSynced(
        address user,
        address pool,
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) private {
        emit LPPositionSynced(user, pool, tokenId, tickLower, tickUpper, liquidity, block.timestamp);
    }

    /**
     * @notice Reverts when LP position arrays do not all match the user array length.
     * @param expectedLen Expected array length from the users array
     * @param poolsLen Pools array length
     * @param tokenIdsLen Token IDs array length
     * @param tickLowersLen Lower ticks array length
     * @param tickUppersLen Upper ticks array length
     * @param liquiditiesLen Liquidities array length
     */
    function _revertIfLPPositionLengthMismatch(
        uint256 expectedLen,
        uint256 poolsLen,
        uint256 tokenIdsLen,
        uint256 tickLowersLen,
        uint256 tickUppersLen,
        uint256 liquiditiesLen
    ) private pure {
        if (poolsLen != expectedLen) revert ArrayLengthMismatch(expectedLen, poolsLen);
        if (tokenIdsLen != expectedLen) revert ArrayLengthMismatch(expectedLen, tokenIdsLen);
        if (tickLowersLen != expectedLen) revert ArrayLengthMismatch(expectedLen, tickLowersLen);
        if (tickUppersLen != expectedLen) revert ArrayLengthMismatch(expectedLen, tickUppersLen);
        if (liquiditiesLen != expectedLen) revert ArrayLengthMismatch(expectedLen, liquiditiesLen);
    }

    /// @notice Reverts unless the caller is the configured keeper or owner.
    function _revertIfNotKeeperOrOwner() private view {
        if (msg.sender == keeper) return;
        if (msg.sender == owner()) return;
        revert NotKeeper(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                            STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    /// @dev Reserved storage gap for future upgrades
    uint256[50] private __gap;
}
