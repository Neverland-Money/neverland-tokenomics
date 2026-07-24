// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {ISpecialEditionRegistry} from "../interfaces/ISpecialEditionRegistry.sol";

import {CommonChecksLibrary} from "../libraries/CommonChecksLibrary.sol";

/**
 * @title SpecialEditionRegistry
 * @author Neverland
 * @notice Token-bound special edition registry for leaderboard multipliers
 * @dev Emits dense events for Hyperindex and stores token membership as a uint256 bitmap.
 * @custom:oz-upgrades-unsafe-allow constructor
 */
contract SpecialEditionRegistry is ISpecialEditionRegistry, OwnableUpgradeable {
    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISpecialEditionRegistry
    uint256 public constant MAX_BATCH_SIZE = 400;

    /// @inheritdoc ISpecialEditionRegistry
    uint16 public constant MAX_EDITION_ID = 255;

    /// @inheritdoc ISpecialEditionRegistry
    uint256 public constant MAX_PER_TOKEN_BOOST_BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                          STORAGE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISpecialEditionRegistry
    address public publisher;

    /// @dev All created edition IDs.
    uint16[] private allEditionIds;

    /// @dev Edition configs by ID.
    mapping(uint16 => Edition) private editions;

    /// @dev Edition key hashes that have already been used.
    mapping(bytes32 => bool) private editionKeyExists;

    /// @dev Registered token IDs by edition.
    mapping(uint16 => uint256[]) private editionTokenIds;

    /// @dev One-based index into editionTokenIds[editionId], used for O(1) correction removals.
    mapping(uint16 => mapping(uint256 => uint256)) private editionTokenIndexPlusOne;

    /// @dev Token edition bitmap by veDUST token ID.
    mapping(uint256 => uint256) private tokenEditionBitmap;

    /// @dev Storage gap for future upgrade-safe additions.
    uint256[50] private __gap;

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Restricts the caller to the configured publisher.
     */
    modifier onlyPublisher() {
        if (msg.sender != publisher) {
            revert NotPublisher(msg.sender);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Disables initializers on the implementation contract
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the registry
     * @param initialOwner Initial owner
     * @param initialPublisher Initial publisher
     */
    function initialize(address initialOwner, address initialPublisher) external initializer {
        CommonChecksLibrary.revertIfZeroAddress(initialOwner);
        CommonChecksLibrary.revertIfZeroAddress(initialPublisher);

        __Ownable_init();
        _transferOwnership(initialOwner);

        publisher = initialPublisher;

        emit PublisherUpdated(address(0), initialPublisher);
    }

    /*//////////////////////////////////////////////////////////////
                               ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISpecialEditionRegistry
    function batchRegisterSpecialEdition(uint16 editionId, uint256[] calldata tokenIds, bytes32[] calldata sourceHashes)
        external
        onlyPublisher
        returns (uint256 registeredCount)
    {
        _revertIfEditionMissing(editionId);

        uint256 len = tokenIds.length;
        if (len != sourceHashes.length) {
            revert InvalidBatchLength();
        }
        if (len > MAX_BATCH_SIZE) {
            revert BatchTooLarge(len, MAX_BATCH_SIZE);
        }

        for (uint256 i = 0; i < len; ++i) {
            if (_registerToken(editionId, tokenIds[i], sourceHashes[i])) {
                ++registeredCount;
            }
        }

        emit SpecialEditionRegistrationBatch(editionId, len, registeredCount, block.timestamp);
    }

    /// @inheritdoc ISpecialEditionRegistry
    function configureEdition(uint16 editionId, string calldata name, uint256 perTokenBoostBps) external onlyOwner {
        _revertIfEditionMissing(editionId);
        _revertIfInvalidName(name);
        _revertIfInvalidBoost(perTokenBoostBps);

        Edition storage edition = editions[editionId];
        uint256 oldPerTokenBoostBps = edition.perTokenBoostBps;

        edition.name = name;
        edition.perTokenBoostBps = perTokenBoostBps;
        edition.updatedAt = block.timestamp;

        emit EditionConfigured(editionId, name, oldPerTokenBoostBps, perTokenBoostBps, block.timestamp);
    }

    /// @inheritdoc ISpecialEditionRegistry
    function correctMembership(
        uint256 tokenId,
        uint16 editionId,
        bool member,
        bytes32 sourceHash,
        string calldata reason
    ) external onlyOwner {
        _revertIfEditionMissing(editionId);
        _revertIfInvalidTokenId(tokenId);

        bool oldMember = _hasEditionUnchecked(tokenId, editionId);
        if (oldMember == member) {
            revert MembershipAlreadySet(tokenId, editionId, member);
        }

        if (member) {
            _addMembership(editionId, tokenId);
        } else {
            _removeMembership(editionId, tokenId);
        }

        emit MembershipCorrected(tokenId, editionId, oldMember, member, sourceHash, reason, block.timestamp);
    }

    /// @inheritdoc ISpecialEditionRegistry
    function createEdition(
        uint16 editionId,
        string calldata key,
        string calldata name,
        uint256 perTokenBoostBps,
        bool enabled
    ) external onlyOwner {
        _revertIfInvalidEditionId(editionId);
        _revertIfInvalidKey(key);
        _revertIfInvalidName(name);
        _revertIfInvalidBoost(perTokenBoostBps);

        if (editions[editionId].exists) {
            revert EditionAlreadyExists(editionId);
        }

        bytes32 keyHash = _hashCalldataString(key);
        if (editionKeyExists[keyHash]) {
            revert EditionKeyAlreadyExists(key);
        }

        editions[editionId] = Edition({
            id: editionId,
            key: key,
            name: name,
            perTokenBoostBps: perTokenBoostBps,
            enabled: enabled,
            exists: true,
            createdAt: block.timestamp,
            updatedAt: block.timestamp
        });
        editionKeyExists[keyHash] = true;
        allEditionIds.push(editionId);

        emit EditionCreated(editionId, key, name, perTokenBoostBps, enabled, block.timestamp, allEditionIds.length);
    }

    /// @inheritdoc ISpecialEditionRegistry
    function setEditionEnabled(uint16 editionId, bool enabled) external onlyOwner {
        _revertIfEditionMissing(editionId);

        Edition storage edition = editions[editionId];
        bool oldEnabled = edition.enabled;

        edition.enabled = enabled;
        edition.updatedAt = block.timestamp;

        emit EditionEnabledUpdated(editionId, oldEnabled, enabled, block.timestamp);
    }

    /// @inheritdoc ISpecialEditionRegistry
    function setPublisher(address newPublisher) external onlyOwner {
        CommonChecksLibrary.revertIfZeroAddress(newPublisher);

        address oldPublisher = publisher;
        publisher = newPublisher;

        emit PublisherUpdated(oldPublisher, newPublisher);
    }

    /// @notice Ownership renouncement is disabled for governed registry maintenance.
    function renounceOwnership() public view override onlyOwner {
        revert CannotRenounceOwnership();
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISpecialEditionRegistry
    function getEdition(uint16 editionId) external view returns (Edition memory edition) {
        _revertIfEditionMissing(editionId);

        return editions[editionId];
    }

    /// @inheritdoc ISpecialEditionRegistry
    function getEditionIds() external view returns (uint16[] memory ids) {
        return allEditionIds;
    }

    /// @inheritdoc ISpecialEditionRegistry
    function getEditionTokenCount(uint16 editionId) external view returns (uint256 count) {
        _revertIfEditionMissing(editionId);

        return editionTokenIds[editionId].length;
    }

    /// @inheritdoc ISpecialEditionRegistry
    function getEditionTokenIdsPage(uint16 editionId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory tokenIds)
    {
        _revertIfEditionMissing(editionId);

        uint256 len = editionTokenIds[editionId].length;
        if (offset >= len || limit == 0) {
            return new uint256[](0);
        }

        uint256 end = offset + limit;
        if (end > len) {
            end = len;
        }

        tokenIds = new uint256[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            tokenIds[i - offset] = editionTokenIds[editionId][i];
        }
    }

    /// @inheritdoc ISpecialEditionRegistry
    function getTokenEditionBitmap(uint256 tokenId) external view returns (uint256 bitmap) {
        return tokenEditionBitmap[tokenId];
    }

    /// @inheritdoc ISpecialEditionRegistry
    function hasEdition(uint256 tokenId, uint16 editionId) external view returns (bool member) {
        _revertIfInvalidEditionId(editionId);

        return _hasEditionUnchecked(tokenId, editionId);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Adds token membership for an edition.
     * @param editionId Edition ID
     * @param tokenId veDUST token ID
     */
    function _addMembership(uint16 editionId, uint256 tokenId) internal {
        tokenEditionBitmap[tokenId] |= _editionMask(editionId);
        editionTokenIndexPlusOne[editionId][tokenId] = editionTokenIds[editionId].length + 1;
        editionTokenIds[editionId].push(tokenId);
    }

    /**
     * @notice Returns the bitmap mask for an edition.
     * @param editionId Edition ID
     * @return mask Edition bitmap mask
     */
    function _editionMask(uint16 editionId) internal pure returns (uint256 mask) {
        return uint256(1) << uint256(editionId);
    }

    /**
     * @notice Checks membership without validating the edition ID.
     * @param tokenId veDUST token ID
     * @param editionId Edition ID
     * @return member Whether the token has the edition
     */
    function _hasEditionUnchecked(uint256 tokenId, uint16 editionId) internal view returns (bool member) {
        return (tokenEditionBitmap[tokenId] & _editionMask(editionId)) != 0;
    }

    /**
     * @notice Hashes a calldata string without allocating a Solidity bytes copy.
     * @param value Calldata string value
     * @return digest Keccak-256 digest
     */
    function _hashCalldataString(string calldata value) internal pure returns (bytes32 digest) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            let length := value.length
            calldatacopy(ptr, value.offset, length)
            digest := keccak256(ptr, length)
            mstore(0x40, add(ptr, and(add(length, 0x3f), not(0x1f))))
        }
    }

    /**
     * @notice Registers token membership if it is not already present.
     * @param editionId Edition ID
     * @param tokenId veDUST token ID
     * @param sourceHash App-side outbox/source hash
     * @return registered Whether a new membership was added
     */
    function _registerToken(uint16 editionId, uint256 tokenId, bytes32 sourceHash) internal returns (bool registered) {
        _revertIfInvalidTokenId(tokenId);

        if (_hasEditionUnchecked(tokenId, editionId)) {
            return false;
        }

        _addMembership(editionId, tokenId);

        emit SpecialEditionRegistered(
            tokenId,
            editionId,
            sourceHash,
            tokenEditionBitmap[tokenId],
            editionTokenIds[editionId].length,
            block.timestamp
        );

        return true;
    }

    /**
     * @notice Removes token membership for an edition.
     * @param editionId Edition ID
     * @param tokenId veDUST token ID
     */
    function _removeMembership(uint16 editionId, uint256 tokenId) internal {
        tokenEditionBitmap[tokenId] &= ~_editionMask(editionId);

        uint256 indexPlusOne = editionTokenIndexPlusOne[editionId][tokenId];
        uint256 removeIndex = indexPlusOne - 1;
        uint256 lastIndex = editionTokenIds[editionId].length - 1;

        if (removeIndex != lastIndex) {
            uint256 movedTokenId = editionTokenIds[editionId][lastIndex];
            editionTokenIds[editionId][removeIndex] = movedTokenId;
            editionTokenIndexPlusOne[editionId][movedTokenId] = indexPlusOne;
        }

        editionTokenIds[editionId].pop();
        delete editionTokenIndexPlusOne[editionId][tokenId];
    }

    /**
     * @notice Reverts if an edition does not exist.
     * @param editionId Edition ID
     */
    function _revertIfEditionMissing(uint16 editionId) internal view {
        _revertIfInvalidEditionId(editionId);
        if (!editions[editionId].exists) {
            revert EditionNotFound(editionId);
        }
    }

    /**
     * @notice Reverts if a boost is out of range.
     * @param perTokenBoostBps Per-token boost
     */
    function _revertIfInvalidBoost(uint256 perTokenBoostBps) internal pure {
        if (perTokenBoostBps > MAX_PER_TOKEN_BOOST_BPS) {
            revert InvalidPerTokenBoost(perTokenBoostBps);
        }
    }

    /**
     * @notice Reverts if an edition ID cannot be represented by the bitmap.
     * @param editionId Edition ID
     */
    function _revertIfInvalidEditionId(uint16 editionId) internal pure {
        if (editionId == 0 || editionId > MAX_EDITION_ID) {
            revert InvalidEditionId(editionId);
        }
    }

    /**
     * @notice Reverts if an edition key is empty.
     * @param key Edition key
     */
    function _revertIfInvalidKey(string calldata key) internal pure {
        if (bytes(key).length == 0) {
            revert InvalidEditionKey();
        }
    }

    /**
     * @notice Reverts if an edition name is empty.
     * @param name Edition name
     */
    function _revertIfInvalidName(string calldata name) internal pure {
        if (bytes(name).length == 0) {
            revert InvalidName();
        }
    }

    /**
     * @notice Reverts if a token ID is not a minted veDUST token ID.
     * @param tokenId veDUST token ID
     */
    function _revertIfInvalidTokenId(uint256 tokenId) internal pure {
        if (tokenId == 0) {
            revert InvalidTokenId(tokenId);
        }
    }
}
