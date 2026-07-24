// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/**
 * @title ISpecialEditionRegistry
 * @author Neverland
 * @notice Registry for token-bound special editions that provide leaderboard multipliers
 */
interface ISpecialEditionRegistry {
    /*//////////////////////////////////////////////////////////////
                               STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct Edition {
        uint16 id;
        string key;
        string name;
        uint256 perTokenBoostBps;
        bool enabled;
        bool exists;
        uint256 createdAt;
        uint256 updatedAt;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when an edition's display name or boost is updated
     * @param editionId Edition ID
     * @param name New display name
     * @param oldPerTokenBoostBps Previous per-token boost in basis points
     * @param newPerTokenBoostBps New per-token boost in basis points
     * @param timestamp Block timestamp of the update
     */
    event EditionConfigured(
        uint16 indexed editionId,
        string name,
        uint256 oldPerTokenBoostBps,
        uint256 newPerTokenBoostBps,
        uint256 timestamp
    );

    /**
     * @notice Emitted when a new special edition is created
     * @param editionId Edition ID
     * @param key Stable machine key
     * @param name Display name
     * @param perTokenBoostBps Per-token boost in basis points
     * @param enabled Whether the edition affects leaderboard multipliers
     * @param timestamp Block timestamp of creation
     * @param totalEditions Total edition count after creation
     */
    event EditionCreated(
        uint16 indexed editionId,
        string key,
        string name,
        uint256 perTokenBoostBps,
        bool enabled,
        uint256 timestamp,
        uint256 totalEditions
    );

    /**
     * @notice Emitted when an edition is enabled or disabled
     * @param editionId Edition ID
     * @param oldEnabled Previous enabled flag
     * @param newEnabled New enabled flag
     * @param timestamp Block timestamp of the update
     */
    event EditionEnabledUpdated(uint16 indexed editionId, bool oldEnabled, bool newEnabled, uint256 timestamp);

    /**
     * @notice Emitted when governance corrects mistaken token membership
     * @param tokenId veDUST token ID
     * @param editionId Edition ID
     * @param oldMember Previous membership flag
     * @param newMember New membership flag
     * @param sourceHash Operator-provided audit hash
     * @param reason Human-readable correction reason
     * @param timestamp Block timestamp of the correction
     */
    event MembershipCorrected(
        uint256 indexed tokenId,
        uint16 indexed editionId,
        bool oldMember,
        bool newMember,
        bytes32 sourceHash,
        string reason,
        uint256 timestamp
    );

    /**
     * @notice Emitted when the publisher address changes
     * @param oldPublisher Previous publisher
     * @param newPublisher New publisher
     */
    event PublisherUpdated(address indexed oldPublisher, address indexed newPublisher);

    /**
     * @notice Emitted when a token is registered for a special edition
     * @param tokenId veDUST token ID
     * @param editionId Edition ID
     * @param sourceHash App-side outbox/source hash
     * @param tokenEditionBitmap Token's edition bitmap after registration
     * @param editionTokenCount Edition membership count after registration
     * @param timestamp Block timestamp of registration
     */
    event SpecialEditionRegistered(
        uint256 indexed tokenId,
        uint16 indexed editionId,
        bytes32 indexed sourceHash,
        uint256 tokenEditionBitmap,
        uint256 editionTokenCount,
        uint256 timestamp
    );

    /**
     * @notice Emitted after a publisher registration batch completes
     * @param editionId Edition ID
     * @param requestedCount Number of submitted token IDs
     * @param registeredCount Number of newly registered token IDs
     * @param timestamp Block timestamp of the batch
     */
    event SpecialEditionRegistrationBatch(
        uint16 indexed editionId, uint256 requestedCount, uint256 registeredCount, uint256 timestamp
    );

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Thrown when a batch exceeds the maximum supported size
     * @param batchSize Submitted batch size
     * @param maxBatchSize Maximum supported batch size
     */
    error BatchTooLarge(uint256 batchSize, uint256 maxBatchSize);

    /**
     * @notice Thrown when ownership renouncement is attempted
     */
    error CannotRenounceOwnership();

    /**
     * @notice Thrown when an edition ID already exists
     * @param editionId Existing edition ID
     */
    error EditionAlreadyExists(uint16 editionId);

    /**
     * @notice Thrown when an edition key already exists
     * @param key Existing edition key
     */
    error EditionKeyAlreadyExists(string key);

    /**
     * @notice Thrown when an edition does not exist
     * @param editionId Missing edition ID
     */
    error EditionNotFound(uint16 editionId);

    /**
     * @notice Thrown when token and source hash arrays differ in length
     */
    error InvalidBatchLength();

    /**
     * @notice Thrown when an edition ID is zero or outside the bitmap range
     * @param editionId Invalid edition ID
     */
    error InvalidEditionId(uint16 editionId);

    /**
     * @notice Thrown when the edition key is empty
     */
    error InvalidEditionKey();

    /**
     * @notice Thrown when the edition name is empty
     */
    error InvalidName();

    /**
     * @notice Thrown when a veDUST token ID is zero
     * @param tokenId Invalid token ID
     */
    error InvalidTokenId(uint256 tokenId);

    /**
     * @notice Thrown when a per-token boost exceeds the configured bound
     * @param perTokenBoostBps Invalid boost
     */
    error InvalidPerTokenBoost(uint256 perTokenBoostBps);

    /**
     * @notice Thrown when a correction does not change membership
     * @param tokenId veDUST token ID
     * @param editionId Edition ID
     * @param member Current membership flag
     */
    error MembershipAlreadySet(uint256 tokenId, uint16 editionId, bool member);

    /**
     * @notice Thrown when a non-publisher attempts publisher-only registration
     * @param caller Unauthorized caller
     */
    error NotPublisher(address caller);

    /*//////////////////////////////////////////////////////////////
                               ACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Register token IDs for an edition
     * @param editionId Edition ID
     * @param tokenIds veDUST token IDs
     * @param sourceHashes App-side outbox/source hashes
     * @return registeredCount Number of newly registered token IDs
     */
    function batchRegisterSpecialEdition(uint16 editionId, uint256[] calldata tokenIds, bytes32[] calldata sourceHashes)
        external
        returns (uint256 registeredCount);

    /**
     * @notice Configure an existing edition's display name and boost
     * @param editionId Edition ID
     * @param name New display name
     * @param perTokenBoostBps New per-token boost in basis points
     */
    function configureEdition(uint16 editionId, string calldata name, uint256 perTokenBoostBps) external;

    /**
     * @notice Correct a mistaken token membership
     * @param tokenId veDUST token ID
     * @param editionId Edition ID
     * @param member Desired membership flag
     * @param sourceHash Operator-provided audit hash
     * @param reason Human-readable correction reason
     */
    function correctMembership(
        uint256 tokenId,
        uint16 editionId,
        bool member,
        bytes32 sourceHash,
        string calldata reason
    ) external;

    /**
     * @notice Create a new edition
     * @param editionId Edition ID
     * @param key Stable machine key
     * @param name Display name
     * @param perTokenBoostBps Per-token boost in basis points
     * @param enabled Whether the edition affects leaderboard multipliers
     */
    function createEdition(
        uint16 editionId,
        string calldata key,
        string calldata name,
        uint256 perTokenBoostBps,
        bool enabled
    ) external;

    /**
     * @notice Enable or disable an edition
     * @param editionId Edition ID
     * @param enabled New enabled flag
     */
    function setEditionEnabled(uint16 editionId, bool enabled) external;

    /**
     * @notice Set the publisher address
     * @param newPublisher New publisher address
     */
    function setPublisher(address newPublisher) external;

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Maximum number of token IDs accepted in one registration batch
     * @return maxBatchSize Maximum batch size
     */
    function MAX_BATCH_SIZE() external view returns (uint256 maxBatchSize);

    /**
     * @notice Maximum edition ID representable in the token bitmap
     * @return maxEditionId Maximum edition ID
     */
    function MAX_EDITION_ID() external view returns (uint16 maxEditionId);

    /**
     * @notice Maximum per-token boost in basis points
     * @return maxPerTokenBoostBps Maximum per-token boost
     */
    function MAX_PER_TOKEN_BOOST_BPS() external view returns (uint256 maxPerTokenBoostBps);

    /**
     * @notice Get an edition config
     * @param editionId Edition ID
     * @return edition Edition config
     */
    function getEdition(uint16 editionId) external view returns (Edition memory edition);

    /**
     * @notice Get all edition IDs
     * @return ids Edition IDs
     */
    function getEditionIds() external view returns (uint16[] memory ids);

    /**
     * @notice Get the number of tokens registered for an edition
     * @param editionId Edition ID
     * @return count Token count
     */
    function getEditionTokenCount(uint16 editionId) external view returns (uint256 count);

    /**
     * @notice Get a page of token IDs registered for an edition
     * @param editionId Edition ID
     * @param offset Start offset
     * @param limit Maximum number of token IDs
     * @return tokenIds Token IDs
     */
    function getEditionTokenIdsPage(uint16 editionId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory tokenIds);

    /**
     * @notice Get a token's edition bitmap
     * @param tokenId veDUST token ID
     * @return bitmap Edition bitmap
     */
    function getTokenEditionBitmap(uint256 tokenId) external view returns (uint256 bitmap);

    /**
     * @notice Check whether a token has an edition
     * @param tokenId veDUST token ID
     * @param editionId Edition ID
     * @return member Whether the token has the edition
     */
    function hasEdition(uint256 tokenId, uint16 editionId) external view returns (bool member);

    /**
     * @notice Current publisher authorized to batch-register memberships
     * @return publisherAddress Publisher address
     */
    function publisher() external view returns (address publisherAddress);
}
