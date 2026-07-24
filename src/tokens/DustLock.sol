// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC2771ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UD60x18, convert} from "@prb/math/src/UD60x18.sol";

import {IDustLock} from "../interfaces/IDustLock.sol";
import {IRevenueReward} from "../interfaces/IRevenueReward.sol";
import {ICreatorToken} from "../interfaces/ICreatorToken.sol";

import {BalanceLogicLibrary} from "../libraries/BalanceLogicLibrary.sol";
import {CommonChecksLibrary} from "../libraries/CommonChecksLibrary.sol";
import {CreatorTokenLibrary} from "../libraries/CreatorTokenLibrary.sol";
import {SafeCastLibrary} from "../libraries/SafeCastLibrary.sol";
import {CommonLibrary} from "../libraries/CommonLibrary.sol";

/**
 * @title DustLock
 * @author Neverland
 * @notice Upgradeable vote-escrow contract that tokenizes timed and permanent DUST locks
 *         as transferable veNFTs with historical voting-power checkpoints.
 *         Supports lock creation and extension, deposits, splits, merges, withdrawals,
 *         revenue-reward hooks, and ERC2771 meta-transactions.
 *         Enforces early-withdrawal penalties and ERC721-C transfer validation,
 *         with ERC2981 creator royalties.
 */
contract DustLock is IDustLock, Initializable, ERC2771ContextUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using SafeCastLibrary for uint256;
    using SafeCastLibrary for int256;
    using Strings for uint256;

    /**
     * @notice Sets ERC2771 forwarder for the implementation and disables initializers
     * @param _forwarder Trusted forwarder used by ERC2771 context
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(address _forwarder) ERC2771ContextUpgradeable(_forwarder) {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                              INITIALIZER
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Initializer (for proxy deployments)
     * @param _forwarder address of trusted forwarder
     * @param _token `DUST` token address
     * @param _baseURI base URI for NFT metadata
     */
    function initialize(address _forwarder, address _token, string memory _baseURI) external initializer {
        CommonChecksLibrary.revertIfZeroAddress(_forwarder);
        CommonChecksLibrary.revertIfZeroAddress(_token);

        __ReentrancyGuard_init();

        forwarder = _forwarder;
        token = _token;
        team = _msgSender();
        baseURI = _baseURI;

        earlyWithdrawTreasury = _msgSender();
        earlyWithdrawPenalty = DEFAULT_EARLY_WITHDRAW_PENALTY_BP;
        minLockAmount = 1e18;

        _pointHistory[0].blk = block.number;
        _pointHistory[0].ts = block.timestamp;

        supportedInterfaces[ERC165_INTERFACE_ID] = true;
        supportedInterfaces[ERC721_INTERFACE_ID] = true;
        supportedInterfaces[ERC4906_INTERFACE_ID] = true;
        supportedInterfaces[ERC6372_INTERFACE_ID] = true;
        supportedInterfaces[ERC721_METADATA_INTERFACE_ID] = true;
        supportedInterfaces[type(IDustLock).interfaceId] = true;

        // mint-ish
        emit Transfer(address(0), address(this), tokenId);
        // burn-ish
        emit Transfer(address(this), address(0), tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                         INTERFACE CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 internal constant ERC165_INTERFACE_ID = 0x01ffc9a7;
    bytes4 internal constant ERC721_INTERFACE_ID = 0x80ac58cd;
    bytes4 internal constant ERC4906_INTERFACE_ID = 0x49064906;
    bytes4 internal constant ERC6372_INTERFACE_ID = 0xda287a1d;
    bytes4 internal constant ERC721_METADATA_INTERFACE_ID = 0x5b5e139f;
    bytes4 internal constant PREDECESSOR_INTERFACE_ID = 0x03448477;

    /*//////////////////////////////////////////////////////////////
                          METADATA CONSTANTS
    //////////////////////////////////////////////////////////////*/

    string public constant name = "Voting Escrow DUST";
    string public constant symbol = "veDUST";
    string public constant version = "2.1.0";

    /*//////////////////////////////////////////////////////////////
                           ESCROW CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant WEEK = 1 weeks;
    uint256 internal constant MINTIME = 28 days;
    uint256 internal constant MAXTIME = 365 days;
    uint256 internal constant MULTIPLIER = 1 ether;
    uint256 internal constant BASIS_POINTS = 10_000;

    /// @dev Floor of the early-withdrawal penalty curve in basis points (25%)
    uint256 internal constant MIN_EARLY_WITHDRAW_PENALTY_BPS = 2_500;
    /// @dev Maximum number of user points that can be stored for a single veNFT
    uint256 internal constant MAX_USER_POINTS = 1_000_000_000;
    /// @dev Maximum number of iterations to perform when calculating checkpoints
    uint256 internal constant MAX_CHECKPOINT_ITERATIONS = 255;
    /// @dev Default early-withdrawal penalty (curve maximum) in basis points (75%)
    uint256 internal constant DEFAULT_EARLY_WITHDRAW_PENALTY_BP = 7_500;

    /*//////////////////////////////////////////////////////////////
                             CORE STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDustLock
    address public override forwarder;
    /// @inheritdoc IDustLock
    address public override token;
    /// @inheritdoc IDustLock
    address public override team;
    /// @inheritdoc IDustLock
    address public override pendingTeam;

    /// @dev Mapping of epoch number to its unsigned global point
    mapping(uint256 => GlobalPoint) internal _pointHistory;
    /// @dev Mapping of interface id to bool about whether or not it's supported
    mapping(bytes4 => bool) internal supportedInterfaces;
    /// @inheritdoc IDustLock
    uint256 public override tokenId;

    /*//////////////////////////////////////////////////////////////
                            ERC721 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Base URI for token metadata
    string internal baseURI;
    /// @dev Mapping from NFT ID to the address that owns it.
    mapping(uint256 => address) internal idToOwner;
    /// @dev Mapping from owner address to count of his tokens.
    mapping(address => uint256) internal ownerToNFTokenCount;
    /// @dev Mapping from NFT ID to approved address.
    mapping(uint256 => address) internal idToApprovals;
    /// @dev Mapping from owner address to mapping of operator addresses.
    mapping(address => mapping(address => bool)) internal ownerToOperators;
    /// @dev Mapping from NFT ID to the block number of the last ownership change.
    mapping(uint256 => uint256) internal ownershipChange;
    /// @inheritdoc IDustLock
    mapping(address => mapping(uint256 => uint256)) public override ownerToNFTokenIdList;
    /// @notice Mapping from NFT ID to index of owner
    mapping(uint256 => uint256) internal tokenToOwnerIndex;

    /*//////////////////////////////////////////////////////////////
                            ESCROW STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDustLock
    uint256 public override epoch;
    /// @inheritdoc IDustLock
    uint256 public override supply;

    /// @notice Mapping from veNFT id to locked balance
    mapping(uint256 => LockedBalance) internal _locked;
    /// @notice Mapping from veNFT id to user point history
    mapping(uint256 => UserPoint[MAX_USER_POINTS]) internal _userPointHistory;
    /// @notice Mapping from veNFT id to user point epoch
    mapping(uint256 => uint256) public userPointEpoch;

    /// @inheritdoc IDustLock
    mapping(uint256 => int256) public override slopeChanges;
    /// @inheritdoc IDustLock
    mapping(address => bool) public override canSplit;
    /// @inheritdoc IDustLock
    uint256 public override permanentLockBalance;
    /// @inheritdoc IDustLock
    uint256 public override earlyWithdrawPenalty;
    /// @inheritdoc IDustLock
    address public override earlyWithdrawTreasury;

    /*//////////////////////////////////////////////////////////////
                    PROTOCOL CONFIGURATION STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Minimum amount of DUST required to create or increase a lock (18 decimals)
    uint256 public override minLockAmount;
    /// @notice Revenue reward contract used for distributing external rewards (address(0) if unset)
    IRevenueReward public override revenueReward;

    /*//////////////////////////////////////////////////////////////
                      CREATOR EARNINGS STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDustLock
    address public override transferValidator;
    /// @inheritdoc IDustLock
    address public override royaltyReceiver;
    /// @inheritdoc IDustLock
    uint96 public override royaltyFeeBps;
    /// @notice Selector used for transfer validation calls to the validator (ERC721-C)
    bytes4 private transferValidationFunctionSelector;
    /// @notice Whether the transfer validation selector should be invoked as a view call
    bool private transferValidationFunctionIsView;
    /// @notice Operator index+1 in the fee-enforced operator list (0 = not enforced)
    mapping(address => uint256) private feeEnforcedOperatorIndexPlusOne;
    /// @notice List of operators that enforce creator fees
    address[] private feeEnforcedOperators;

    /*//////////////////////////////////////////////////////////////
                       UPGRADEABILITY STORAGE
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Storage gap for upgradeable safety reduced by 5 slots for:
     *      1) transferValidator
     *      2) royaltyReceiver + royaltyFeeBps (packed)
     *      3) transferValidationFunctionSelector + transferValidationFunctionIsView (packed)
     *      4) feeEnforcedOperatorIndexPlusOne
     *      5) feeEnforcedOperators
     */
    uint256[45] private __gap;

    /**
     * @notice Returns whether `forwarderToCheck` is the trusted ERC2771 forwarder.
     * @dev Uses storage `forwarder` (initialized on the proxy) instead of immutable
     *      constructor state so trusted-forwarder checks remain upgrade-safe.
     * @param forwarderToCheck Forwarder address to validate
     * @return isTrusted True if `forwarderToCheck` is configured as trusted
     */
    function isTrustedForwarder(address forwarderToCheck) public view override returns (bool isTrusted) {
        isTrusted = forwarderToCheck == forwarder;
    }

    /// @inheritdoc IDustLock
    function proposeTeam(address _newTeam) external override {
        if (_msgSender() != team) revert NotTeam();
        CommonChecksLibrary.revertIfZeroAddress(_newTeam);
        CommonChecksLibrary.revertIfSameAddress(_newTeam, team);

        pendingTeam = _newTeam;

        emit TeamProposed(team, _newTeam);
    }

    /// @inheritdoc IDustLock
    function acceptTeam() external override {
        if (_msgSender() != pendingTeam) revert NotPendingTeam();

        address oldTeam = team;
        team = pendingTeam;
        pendingTeam = address(0);

        emit TeamAccepted(oldTeam, team);
    }

    /// @inheritdoc IDustLock
    function owner() external view override returns (address) {
        return team;
    }

    /// @inheritdoc IDustLock
    function cancelTeamProposal() external override {
        if (_msgSender() != team) revert NotTeam();
        CommonChecksLibrary.revertIfZeroAddress(pendingTeam);

        address cancelledTeam = pendingTeam;
        pendingTeam = address(0);

        emit TeamProposalCancelled(team, cancelledTeam);
    }

    /*//////////////////////////////////////////////////////////////
                                ERC721 LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC721Metadata
    function tokenURI(uint256 _tokenId) public view override returns (string memory) {
        _ownerOfOrRevert(_tokenId);

        return bytes(baseURI).length > 0 ? string.concat(baseURI, _tokenId.toString()) : "";
    }

    /// @inheritdoc IDustLock
    function setBaseURI(string calldata newBaseURI) external override {
        if (_msgSender() != team) revert NotTeam();

        string memory oldBaseURIMemory = baseURI;
        string memory newBaseURIMemory = newBaseURI;
        baseURI = newBaseURIMemory;

        emit BaseURIUpdated(oldBaseURIMemory, newBaseURIMemory);
        if (tokenId > 0) emit BatchMetadataUpdate(1, tokenId);
    }

    /**
     * @notice Returns the owner address of a token without reverting.
     * @dev Returns address(0) if the token does not exist.
     * @param _tokenId The veNFT id to query ownership for.
     * @return The current owner address or address(0) if burned/non-minted.
     */
    function _ownerOf(uint256 _tokenId) internal view returns (address) {
        address tokenOwner = idToOwner[_tokenId];
        return tokenOwner;
    }

    /**
     * @notice Returns the owner address of a token or reverts if it is not minted.
     * @dev Uses CommonChecksLibrary to revert when owner is address(0).
     * @param _tokenId The veNFT id to query.
     * @return tokenOwner The current owner address.
     */
    function _ownerOfOrRevert(uint256 _tokenId) internal view returns (address tokenOwner) {
        tokenOwner = _ownerOf(_tokenId);
        CommonChecksLibrary.revertIfInvalidTokenId(tokenOwner);
    }

    /// @inheritdoc IDustLock
    function ownerOf(uint256 _tokenId) external view override returns (address) {
        return _ownerOfOrRevert(_tokenId);
    }

    /// @inheritdoc IDustLock
    function balanceOf(address _owner) external view override returns (uint256) {
        CommonChecksLibrary.revertIfZeroAddress(_owner);

        return ownerToNFTokenCount[_owner];
    }

    /// @inheritdoc IDustLock
    function getApproved(uint256 _tokenId) external view override returns (address) {
        _ownerOfOrRevert(_tokenId);

        return idToApprovals[_tokenId];
    }

    /// @inheritdoc IDustLock
    function isApprovedForAll(address _owner, address _operator) external view override returns (bool) {
        return (ownerToOperators[_owner])[_operator];
    }

    /// @inheritdoc IDustLock
    function isApprovedOrOwner(address _spender, uint256 _tokenId) external view override returns (bool) {
        return _isApprovedOrOwner(_spender, _tokenId);
    }

    /**
     * @notice Checks whether `_spender` is allowed to manage `_tokenId`.
     * @dev True if `_spender` is the owner, approved for the token, or approved for all.
     * @param _spender The address to check permissions for.
     * @param _tokenId The token id to check against.
     * @return True if `_spender` is owner or approved.
     */
    function _isApprovedOrOwner(address _spender, uint256 _tokenId) internal view returns (bool) {
        address tokenOwner = _ownerOf(_tokenId);
        bool spenderIsOwner = tokenOwner == _spender;
        bool spenderIsApproved = _spender == idToApprovals[_tokenId];
        bool spenderIsApprovedForAll = (ownerToOperators[tokenOwner])[_spender];
        return spenderIsOwner || spenderIsApproved || spenderIsApprovedForAll;
    }

    /*//////////////////////////////////////////////////////////////
                        ERC721 APPROVAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDustLock
    function approve(address _approved, uint256 _tokenId) external override {
        address sender = _msgSender();
        address tokenOwner = _ownerOfOrRevert(_tokenId);
        // Throws if `_approved` is the current owner
        CommonChecksLibrary.revertIfSameAddress(tokenOwner, _approved);

        // Check requirements
        bool senderIsOwner = (_ownerOf(_tokenId) == sender);
        bool senderIsApprovedForAll = (ownerToOperators[tokenOwner])[sender];
        if (!senderIsOwner && !senderIsApprovedForAll) revert NotApprovedOrOwner();

        // Set the approval
        idToApprovals[_tokenId] = _approved;

        emit Approval(tokenOwner, _approved, _tokenId);
    }

    /// @inheritdoc IDustLock
    function setApprovalForAll(address _operator, bool _approved) external override {
        address sender = _msgSender();
        // Throws if `_operator` is the `msg.sender`
        CommonChecksLibrary.revertIfSameAddress(_operator, sender);

        ownerToOperators[sender][_operator] = _approved;

        emit ApprovalForAll(sender, _operator, _approved);
    }

    /*//////////////////////////////////////////////////////////////
                           TRANSFER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Transfers `_tokenId` from `_from` to `_to` and performs bookkeeping.
     * @dev Clears approvals, updates owner counts and index mappings, sets flash-vote block,
     *      notifies external hooks, and emits the Transfer event. Reverts on invalid ownership
     *      or insufficient approvals.
     * @param _from Current owner of the token.
     * @param _to Recipient address (must be non-zero).
     * @param _tokenId The token id being transferred.
     * @param _sender The original caller used for approval checks and receiver callbacks.
     */
    function _transferFrom(address _from, address _to, uint256 _tokenId, address _sender) internal {
        CommonChecksLibrary.revertIfEpochFinalizationPending(WEEK);
        CommonChecksLibrary.revertIfZeroAddress(_to);
        // Check requirements
        if (!_isApprovedOrOwner(_sender, _tokenId)) revert NotApprovedOrOwner();
        // Clear approval. Throws if `_from` is not the current owner
        if (_ownerOf(_tokenId) != _from) revert NotOwner();

        // ERC721-C: Validate transfer for marketplace royalty enforcement
        _validateTransfer(msg.sender, _from, _to, _tokenId);

        delete idToApprovals[_tokenId];
        // Remove NFT. Throws if `_tokenId` is not a valid NFT
        _removeTokenFrom(_from, _tokenId);
        // Add NFT
        _addTokenTo(_to, _tokenId);
        // Set the block of ownership transfer (for Flash NFT protection)
        ownershipChange[_tokenId] = block.number;
        // notify other contracts
        _notifyAfterTokenTransferred(_tokenId, _from, _to, _sender);

        // Log the transfer
        emit Transfer(_from, _to, _tokenId);
    }

    /// @inheritdoc IDustLock
    function transferFrom(address _from, address _to, uint256 _tokenId) external override nonReentrant {
        _transferFrom(_from, _to, _tokenId, _msgSender());
    }

    /// @inheritdoc IDustLock
    function safeTransferFrom(address _from, address _to, uint256 _tokenId) external override nonReentrant {
        _safeTransferFrom(_from, _to, _tokenId, "", _msgSender());
    }

    /// @inheritdoc IDustLock
    function safeTransferFrom(address _from, address _to, uint256 _tokenId, bytes calldata _data)
        external
        override
        nonReentrant
    {
        bytes memory data = _data;
        _safeTransferFrom(_from, _to, _tokenId, data, _msgSender());
    }

    /**
     * @notice Safe transfer variant that invokes `onERC721Received` when `_to` is a contract.
     * @dev Reverts if the target contract rejects the transfer.
     * @param _from Current owner of the token.
     * @param _to Recipient address.
     * @param _tokenId The token id being transferred.
     * @param _data Additional data forwarded to the receiver hook.
     * @param sender Original caller used in receiver callback.
     */
    function _safeTransferFrom(address _from, address _to, uint256 _tokenId, bytes memory _data, address sender)
        internal
    {
        _transferFrom(_from, _to, _tokenId, sender);

        if (CommonLibrary.isContract(_to)) {
            // Throws if transfer destination is a contract which does not implement 'onERC721Received'
            try IERC721Receiver(_to).onERC721Received(sender, _from, _tokenId, _data) returns (bytes4 response) {
                if (response != IERC721Receiver(_to).onERC721Received.selector) {
                    revert ERC721ReceiverRejectedTokens();
                }
            } catch (bytes memory reason) {
                if (reason.length == 0) {
                    revert ERC721TransferToNonERC721ReceiverImplementer();
                } else {
                    assembly {
                        revert(add(32, reason), mload(reason))
                    }
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                              ERC165 LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDustLock
    function supportsInterface(bytes4 _interfaceID) external view override returns (bool) {
        return _interfaceID == ERC165_INTERFACE_ID || _interfaceID == ERC721_INTERFACE_ID
            || _interfaceID == ERC721_METADATA_INTERFACE_ID || _interfaceID == ERC4906_INTERFACE_ID
            || _interfaceID == ERC6372_INTERFACE_ID || _interfaceID == PREDECESSOR_INTERFACE_ID
            || _interfaceID == type(IDustLock).interfaceId || _interfaceID == type(IERC2981).interfaceId
            || _interfaceID == type(ICreatorToken).interfaceId || supportedInterfaces[_interfaceID];
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL MINT/BURN LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Internal function to add a NFT to an index mapping to a given address
     * @param _to address of the receiver
     * @param _tokenId uint ID Of the token to be added
     */
    function _addTokenToOwnerList(address _to, uint256 _tokenId) internal {
        uint256 currentCount = ownerToNFTokenCount[_to];

        ownerToNFTokenIdList[_to][currentCount] = _tokenId;
        tokenToOwnerIndex[_tokenId] = currentCount;
    }

    /**
     * @notice Internal function to add a NFT to a given address
     * @param _to address of the receiver
     * @param _tokenId uint ID Of the token to be added
     */
    function _addTokenTo(address _to, uint256 _tokenId) internal {
        // Throws if `_tokenId` is owned by someone
        if (_ownerOf(_tokenId) != address(0)) revert AlreadyOwned();

        // Change the owner
        idToOwner[_tokenId] = _to;
        // Update owner token index tracking
        _addTokenToOwnerList(_to, _tokenId);
        // Change count tracking
        ++ownerToNFTokenCount[_to];
    }

    /**
     * @notice Internal function to mint tokens
     * @param _to The address that will receive the minted tokens.
     * @param _tokenId The token id to mint.
     * @return A boolean that indicates if the operation was successful.
     */
    function _mint(address _to, uint256 _tokenId) internal returns (bool) {
        // Throws if `_to` is zero address
        CommonChecksLibrary.revertIfZeroAddress(_to);

        // Add NFT. Throws if `_tokenId` is owned by someone
        _addTokenTo(_to, _tokenId);

        emit Transfer(address(0), _to, _tokenId);

        return true;
    }

    /**
     * @notice Internal function to remove a NFT from an index mapping to a given address
     * @param _from address of the sender
     * @param _tokenId uint ID Of the token to be removed
     */
    function _removeTokenFromOwnerList(address _from, uint256 _tokenId) internal {
        // Delete
        uint256 currentCount = ownerToNFTokenCount[_from] - 1;
        uint256 currentIndex = tokenToOwnerIndex[_tokenId];

        if (currentCount == currentIndex) {
            // update ownerToNFTokenIdList
            ownerToNFTokenIdList[_from][currentCount] = 0;
            // update tokenToOwnerIndex
            tokenToOwnerIndex[_tokenId] = 0;
        } else {
            uint256 lastTokenId = ownerToNFTokenIdList[_from][currentCount];

            // add ownerToNFTokenIdList
            ownerToNFTokenIdList[_from][currentIndex] = lastTokenId;
            // update tokenToOwnerIndex
            tokenToOwnerIndex[lastTokenId] = currentIndex;

            // delete ownerToNFTokenIdList
            ownerToNFTokenIdList[_from][currentCount] = 0;
            // update tokenToOwnerIndex
            tokenToOwnerIndex[_tokenId] = 0;
        }
    }

    /**
     * @notice Remove a NFT from a given address
     * @param _from address of the sender
     * @param _tokenId uint ID Of the token to be removed
     */
    function _removeTokenFrom(address _from, uint256 _tokenId) internal {
        // Throws if `_from` is not the current owner
        if (_ownerOf(_tokenId) != _from) revert NotOwner();

        // Change the owner
        idToOwner[_tokenId] = address(0);
        // Update owner token index tracking
        _removeTokenFromOwnerList(_from, _tokenId);
        // Change count tracking
        --ownerToNFTokenCount[_from];
    }

    /**
     * @notice Burns the veNFT token, removing ownership and permissions. Only callable by approved users or the owner of the token
     * @dev Must be called prior to updating `LockedBalance`
     * @param _tokenId The ID of the veNFT token to burn
     */
    function _burn(uint256 _tokenId) internal {
        address sender = _msgSender();
        if (!_isApprovedOrOwner(sender, _tokenId)) revert NotApprovedOrOwner();

        address tokenOwner = _ownerOf(_tokenId);
        // Clear approval
        delete idToApprovals[_tokenId];
        // Remove token
        _removeTokenFrom(tokenOwner, _tokenId);

        emit Transfer(tokenOwner, address(0), _tokenId);
    }

    /// @inheritdoc IDustLock
    function locked(uint256 _tokenId) external view override returns (LockedBalance memory) {
        return _locked[_tokenId];
    }

    /// @inheritdoc IDustLock
    function userPointHistory(uint256 _tokenId, uint256 _loc) external view override returns (UserPoint memory) {
        return _userPointHistory[_tokenId][_loc];
    }

    /// @inheritdoc IDustLock
    function pointHistory(uint256 _loc) external view override returns (GlobalPoint memory) {
        return _pointHistory[_loc];
    }

    /*//////////////////////////////////////////////////////////////
                              ESCROW LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Record global and per-user voting power data to checkpoints
     * @dev This critical function:
     *      1. Updates user voting power points when their lock changes
     *      2. Updates global voting power points
     *      3. Updates slope changes for future epochs
     *      4. Handles both normal and permanent locks
     * @param _tokenId NFT token ID (0 means only update global checkpoints, no user checkpoint)
     * @param _oldLocked Previous locked amount / end lock time / permanent status for the user
     * @param _newLocked New locked amount / end lock time / permanent status for the user
     */
    function _checkpoint(uint256 _tokenId, LockedBalance memory _oldLocked, LockedBalance memory _newLocked) internal {
        CommonChecksLibrary.revertIfEpochFinalizationPending(WEEK);

        UserPoint memory uOld;
        UserPoint memory uNew;
        int256 oldDSlope = 0;
        int256 newDSlope = 0;
        uint256 _epoch = epoch;

        if (_tokenId != 0) {
            uNew.permanent = _newLocked.isPermanent ? _newLocked.amount.toUint256() : 0;
            // Calculate slopes and biases using PRB Math v4
            if (_oldLocked.end > block.timestamp && _oldLocked.amount > 0) {
                uint256 amount = _oldLocked.amount.toUint256();
                uint256 timeDiff = _oldLocked.end - block.timestamp;
                uint256 maxTime = MAXTIME;

                // convert inputs to WAD
                UD60x18 amountWAD = convert(amount);
                UD60x18 timeDiffWAD = convert(timeDiff);
                UD60x18 maxTimeWAD = convert(maxTime);

                UD60x18 biasResult = amountWAD.mul(timeDiffWAD).div(maxTimeWAD);
                uOld.bias = int256(biasResult.intoUint256());

                // Calculate slope with 18 decimal precision: amount / maxTime
                UD60x18 slopeResult = amountWAD.div(maxTimeWAD);
                uOld.slope = int256(slopeResult.intoUint256());
            }
            if (_newLocked.end > block.timestamp && _newLocked.amount > 0) {
                uint256 amount = _newLocked.amount.toUint256();
                uint256 timeDiff = _newLocked.end - block.timestamp;
                uint256 maxTime = MAXTIME;

                // convert inputs to WAD
                UD60x18 amountWAD = convert(amount);
                UD60x18 timeDiffWAD = convert(timeDiff);
                UD60x18 maxTimeWAD = convert(maxTime);

                UD60x18 biasResult = amountWAD.mul(timeDiffWAD).div(maxTimeWAD);
                uNew.bias = int256(biasResult.intoUint256());

                // Calculate slope with 18 decimal precision: amount / maxTime
                UD60x18 slopeResult = amountWAD.div(maxTimeWAD);
                uNew.slope = int256(slopeResult.intoUint256());
            }

            /*
             * Read values of scheduled changes in the slope
             * _oldLocked.end can be in the past and in the future
             * _newLocked.end can ONLY by in the FUTURE unless everything expired: than zeros
             */
            oldDSlope = slopeChanges[_oldLocked.end];
            if (_newLocked.end != 0) {
                if (_newLocked.end == _oldLocked.end) {
                    newDSlope = oldDSlope;
                } else {
                    newDSlope = slopeChanges[_newLocked.end];
                }
            }
        }

        GlobalPoint memory lastPoint =
            GlobalPoint({bias: 0, slope: 0, ts: block.timestamp, blk: block.number, permanentLockBalance: 0});
        if (_epoch > 0) {
            lastPoint = _pointHistory[_epoch];
        }
        uint256 lastCheckpoint = lastPoint.ts;
        /*
         * initialLastPoint is used for extrapolation to calculate block number
         * (approximately, for *At methods) and save them
         * as we cannot figure that out exactly from inside the contract
         */
        GlobalPoint memory initialLastPoint = GlobalPoint({
            bias: lastPoint.bias,
            slope: lastPoint.slope,
            ts: lastPoint.ts,
            blk: lastPoint.blk,
            permanentLockBalance: lastPoint.permanentLockBalance
        });
        uint256 blockSlope = 0; // dBlock/dt
        if (block.timestamp > lastPoint.ts) {
            blockSlope = (MULTIPLIER * (block.number - lastPoint.blk)) / (block.timestamp - lastPoint.ts);
        }
        /*
         * If last point is already recorded in this block, slope=0
         * But that's ok b/c we know the block in such case
         */

        // Go over weeks to fill history and calculate what the current point is
        {
            uint256 tCurr = (lastCheckpoint / WEEK) * WEEK;
            for (uint256 i = 0; i < MAX_CHECKPOINT_ITERATIONS; ++i) {
                /*
                 * Hopefully it won't happen that this won't get used in 5 years!
                 * If it does, users will be able to withdraw but vote weight will be broken
                 */
                tCurr += WEEK; // Initial value of tCurr is always larger than the ts of the last point
                int256 dSlope = 0;
                if (tCurr > block.timestamp) {
                    tCurr = block.timestamp;
                } else {
                    dSlope = slopeChanges[tCurr];
                }
                /*
                 * Time difference in seconds, slope is in WAD format
                 * slope * time_seconds gives WAD result
                 */
                lastPoint.bias -= lastPoint.slope * int256(tCurr - lastCheckpoint);
                lastPoint.slope += dSlope;
                if (lastPoint.bias < 0) {
                    // This can happen
                    lastPoint.bias = 0;
                }
                if (lastPoint.slope < 0) {
                    // This cannot happen - just in case
                    lastPoint.slope = 0;
                }
                lastCheckpoint = tCurr;
                lastPoint.ts = tCurr;
                lastPoint.blk = initialLastPoint.blk + (blockSlope * (tCurr - initialLastPoint.ts)) / MULTIPLIER;
                ++_epoch;
                if (tCurr == block.timestamp) {
                    lastPoint.blk = block.number;
                    break;
                } else {
                    _pointHistory[_epoch] = lastPoint;
                }
            }
        }

        if (_tokenId != 0) {
            /*
             * If last point was in this block, the slope change has been applied already
             * But in such case we have 0 slope(s)
             */
            lastPoint.slope += (uNew.slope - uOld.slope);
            lastPoint.bias += (uNew.bias - uOld.bias);
            if (lastPoint.slope < 0) {
                lastPoint.slope = 0;
            }
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }
            lastPoint.permanentLockBalance = permanentLockBalance;
        }

        /*
         * If timestamp of last global point is the same, overwrite the last global point
         * Else record the new global point into history
         * Exclude epoch 0 (note: _epoch is always >= 1, see above)
         * Two possible outcomes:
         * Missing global checkpoints in prior weeks. In this case, _epoch = epoch + x, where x > 1
         * No missing global checkpoints, but timestamp != block.timestamp. Create new checkpoint.
         * No missing global checkpoints, but timestamp == block.timestamp. Overwrite last checkpoint.
         */
        if (_epoch != 1 && _pointHistory[_epoch - 1].ts == block.timestamp) {
            // _epoch = epoch + 1, so we do not increment epoch
            _pointHistory[_epoch - 1] = lastPoint;
        } else {
            // more than one global point may have been written, so we update epoch
            epoch = _epoch;
            _pointHistory[_epoch] = lastPoint;
        }

        if (_tokenId != 0) {
            /*
             * Schedule the slope changes (slope is going down)
             * We subtract new_user_slope from [_newLocked.end]
             * and add old_user_slope to [_oldLocked.end]
             */
            if (_oldLocked.end > block.timestamp) {
                // oldDSlope was <something> - uOld.slope, so we cancel that
                oldDSlope += uOld.slope;
                if (_newLocked.end == _oldLocked.end) {
                    oldDSlope -= uNew.slope; // It was a new deposit, not extension
                }
                slopeChanges[_oldLocked.end] = oldDSlope;
            }

            if (_newLocked.end > block.timestamp) {
                // update slope if new lock is greater than old lock and is not permanent or if old lock is permanent
                if ((_newLocked.end > _oldLocked.end)) {
                    newDSlope -= uNew.slope; // old slope disappeared at this point
                    slopeChanges[_newLocked.end] = newDSlope;
                }
                // else: we recorded it already in oldDSlope
            }
            /*
             * If timestamp of last user point is the same, overwrite the last user point
             * Else record the new user point into history
             * Exclude epoch 0
             */
            uNew.ts = block.timestamp;
            uNew.blk = block.number;
            uint256 userEpoch = userPointEpoch[_tokenId];
            if (userEpoch != 0 && _userPointHistory[_tokenId][userEpoch].ts == block.timestamp) {
                _userPointHistory[_tokenId][userEpoch] = uNew;
            } else {
                userPointEpoch[_tokenId] = ++userEpoch;
                _userPointHistory[_tokenId][userEpoch] = uNew;
            }
        }
    }

    /**
     * @notice Deposit and lock tokens for an existing veNFT
     * @dev Core internal function that handles all token deposits including:
     *      1. Updating supply
     *      2. Updating token lock parameters
     *      3. Creating checkpoints for voting power
     *      4. Transferring tokens from sender to contract
     *      5. Emitting appropriate events
     * @param _tokenId The ID of the veNFT that holds the lock
     * @param _value Amount of tokens to deposit (can be 0 for lock extensions)
     * @param _unlockTime New time when to unlock the tokens, or 0 if unchanged
     * @param _oldLocked Previous locked amount, timestamp and permanent status
     * @param _depositType The type of deposit (create, increase amount, extend time, etc.)
     */
    function _depositFor(
        uint256 _tokenId,
        uint256 _value,
        uint256 _unlockTime,
        LockedBalance memory _oldLocked,
        DepositType _depositType
    ) internal {
        uint256 supplyBefore = supply;
        supply = supplyBefore + _value;

        // Set newLocked to _oldLocked without mangling memory
        LockedBalance memory newLocked;
        (newLocked.amount, newLocked.effectiveStart, newLocked.end, newLocked.isPermanent) =
        (_oldLocked.amount, _oldLocked.effectiveStart, _oldLocked.end, _oldLocked.isPermanent);

        // Adding to existing lock, or if a lock is expired - creating a new one
        newLocked.amount += _value.toInt256();
        if (_unlockTime != 0) {
            newLocked.end = _unlockTime;
        }

        // Set effective start time based on deposit type
        if (_depositType == DepositType.CREATE_LOCK_TYPE) {
            // Set effective start time to current block timestamp for new locks
            newLocked.effectiveStart = block.timestamp;
        } else if (
            (_depositType == DepositType.INCREASE_LOCK_AMOUNT || _depositType == DepositType.DEPOSIT_FOR_TYPE)
                && !_oldLocked.isPermanent && !newLocked.isPermanent
        ) {
            // Calculate weighted average start time for timed locks
            newLocked.effectiveStart = _calculateWeightedStart(
                _oldLocked.amount.toUint256(), _oldLocked.effectiveStart, _value, block.timestamp
            );
        }

        _locked[_tokenId] = newLocked;

        /*
         * Possibilities:
         * Both _oldLocked.end could be current or expired (>/< block.timestamp)
         * or if the lock is a permanent lock, then _oldLocked.end == 0
         * value == 0 (extend lock) or value > 0 (add to lock or extend lock)
         * newLocked.end > block.timestamp (always)
         */
        _checkpoint(_tokenId, _oldLocked, newLocked);

        address from = _msgSender();
        if (_value != 0) {
            IERC20(token).safeTransferFrom(from, address(this), _value);
        }

        emit Deposit(from, _tokenId, _depositType, _value, newLocked.end, block.timestamp);
        emit Supply(supplyBefore, supply);

        if (_value != 0 || _unlockTime != 0) emit MetadataUpdate(_tokenId);
    }

    /// @inheritdoc IDustLock
    function checkpoint() external override nonReentrant {
        _checkpoint(0, LockedBalance(0, 0, 0, false), LockedBalance(0, 0, 0, false));
    }

    /// @inheritdoc IDustLock
    function depositFor(uint256 _tokenId, uint256 _value) external override nonReentrant {
        _increaseAmountFor(_tokenId, _value, DepositType.DEPOSIT_FOR_TYPE);
    }

    /**
     * @notice Calculates weighted average start timestamp for two lock segments
     * @dev Calculates the weighted start time of two locks based on their amounts.
     * @param _amountA Amount of DUST in the first lock.
     * @param _startA Effective start time of the first lock.
     * @param _amountB Amount of DUST in the second lock.
     * @param _startB Effective start time of the second lock.
     * @return Weighted start time across the two segments
     */
    function _calculateWeightedStart(uint256 _amountA, uint256 _startA, uint256 _amountB, uint256 _startB)
        internal
        pure
        returns (uint256)
    {
        uint256 totalAmount = _amountA + _amountB;
        uint256 numerator = _amountA * _startA + _amountB * _startB;
        return numerator / totalAmount;
    }

    /**
     * @notice This internal function is used by createLock and createLockFor to create a new veNFT
     * @dev Creates a new lock position by depositing tokens for a specified address.
     *      Copies `_locked[_tokenId]` (storage) to memory when passed to `_depositFor`. No storage mutation occurs.
     * @param _value Amount of tokens to deposit
     * @param _lockDuration Number of seconds to lock tokens for (rounded down to nearest week)
     * @param _to Address that will own the newly created veNFT
     * @return The ID of the newly created veNFT
     */
    function _createLock(uint256 _value, uint256 _lockDuration, address _to) internal returns (uint256) {
        CommonChecksLibrary.revertIfZeroAmount(_value);
        if (_value < minLockAmount) revert AmountTooSmall();

        uint256 unlockTime = ((block.timestamp + _lockDuration) / WEEK) * WEEK; // Locktime is rounded down to weeks
        if (unlockTime <= block.timestamp) revert LockDurationNotInFuture();
        if (unlockTime < block.timestamp + MINTIME) revert LockDurationTooShort();
        if (unlockTime > block.timestamp + MAXTIME) revert LockDurationTooLong();

        uint256 _tokenId = ++tokenId;
        _mint(_to, _tokenId);
        _notifyTokenMinted(_tokenId, _to, _msgSender());

        _depositFor(_tokenId, _value, unlockTime, _locked[_tokenId], DepositType.CREATE_LOCK_TYPE);

        return _tokenId;
    }

    /// @inheritdoc IDustLock
    function createLock(uint256 _value, uint256 _lockDuration) external override nonReentrant returns (uint256) {
        return _createLock(_value, _lockDuration, _msgSender());
    }

    /// @inheritdoc IDustLock
    function createLockFor(uint256 _value, uint256 _lockDuration, address _to)
        external
        override
        nonReentrant
        returns (uint256)
    {
        return _createLock(_value, _lockDuration, _to);
    }

    /// @inheritdoc IDustLock
    function createLockPermanent(uint256 _value, uint256 _lockDuration)
        external
        override
        nonReentrant
        returns (uint256)
    {
        address creator = _msgSender();
        uint256 newTokenId = _createLock(_value, _lockDuration, creator);
        _lockPermanent(creator, newTokenId);

        return newTokenId;
    }

    /// @inheritdoc IDustLock
    function createLockPermanentFor(uint256 _value, uint256 _lockDuration, address _to)
        external
        override
        nonReentrant
        returns (uint256)
    {
        uint256 newTokenId = _createLock(_value, _lockDuration, _to);
        _lockPermanent(_to, newTokenId);

        return newTokenId;
    }

    /**
     * @notice Internal helper to increase the locked amount for a given veNFT
     * @dev The minimum amount for increases is 1/10th of minLockAmount to allow smaller
     *      incremental additions to existing locks while maintaining a higher barrier for
     *      new lock creation. This enables flexible reward distribution and user deposits
     *      without requiring the full creation minimum.
     * @param _tokenId The veNFT id to increase the amount for
     * @param _value The additional amount of DUST to add to the lock
     * @param _depositType The deposit type (direct increase or depositFor)
     */
    function _increaseAmountFor(uint256 _tokenId, uint256 _value, DepositType _depositType) internal {
        CommonChecksLibrary.revertIfZeroAmount(_value);
        if (_value < minLockAmount / 10) revert AmountTooSmall();

        LockedBalance memory oldLocked = _locked[_tokenId];
        if (oldLocked.amount <= 0) revert NoLockFound();
        if (oldLocked.end <= block.timestamp && !oldLocked.isPermanent) revert LockExpired();

        // Prevent depositFor to locks expiring within MINTIME
        if (
            (_depositType == DepositType.DEPOSIT_FOR_TYPE || _depositType == DepositType.INCREASE_LOCK_AMOUNT)
                && !oldLocked.isPermanent
        ) {
            if (oldLocked.end < block.timestamp + MINTIME) {
                revert DepositForLockDurationTooShort();
            }
        }

        if (oldLocked.isPermanent) permanentLockBalance += _value;
        _depositFor(_tokenId, _value, 0, oldLocked, _depositType);

        emit MetadataUpdate(_tokenId);
    }

    /// @inheritdoc IDustLock
    function increaseAmount(uint256 _tokenId, uint256 _value) external override nonReentrant {
        if (!_isApprovedOrOwner(_msgSender(), _tokenId)) revert NotApprovedOrOwner();

        _increaseAmountFor(_tokenId, _value, DepositType.INCREASE_LOCK_AMOUNT);
    }

    /// @inheritdoc IDustLock
    function increaseUnlockTime(uint256 _tokenId, uint256 _lockDuration) external override nonReentrant {
        if (!_isApprovedOrOwner(_msgSender(), _tokenId)) revert NotApprovedOrOwner();

        LockedBalance memory oldLocked = _locked[_tokenId];
        if (oldLocked.isPermanent) revert PermanentLock();
        if (oldLocked.end <= block.timestamp) revert LockExpired();
        if (oldLocked.amount <= 0) revert NoLockFound();

        uint256 unlockTime = ((block.timestamp + _lockDuration) / WEEK) * WEEK; // Locktime is rounded down to weeks
        if (unlockTime <= oldLocked.end) revert LockDurationNotInFuture();
        if (unlockTime > block.timestamp + MAXTIME) revert LockDurationTooLong();

        _depositFor(_tokenId, 0, unlockTime, oldLocked, DepositType.INCREASE_UNLOCK_TIME);

        emit MetadataUpdate(_tokenId);
    }

    /// @inheritdoc IDustLock
    function withdraw(uint256 _tokenId) public override nonReentrant {
        address sender = _msgSender();
        if (!_isApprovedOrOwner(sender, _tokenId)) revert NotApprovedOrOwner();

        LockedBalance memory oldLocked = _locked[_tokenId];
        if (oldLocked.isPermanent) revert PermanentLock();
        if (block.timestamp < oldLocked.end) revert LockNotExpired();

        uint256 value = oldLocked.amount.toUint256();

        // Burn the NFT
        address tokenOwner = _ownerOf(_tokenId);
        _burn(_tokenId);

        _locked[_tokenId] = LockedBalance(0, 0, 0, false);
        uint256 supplyBefore = supply;
        supply = supplyBefore - value;

        /*
         * oldLocked can have either expired <= timestamp or zero end
         * oldLocked has only 0 end
         * Both can have >= 0 amount
         */
        _checkpoint(_tokenId, oldLocked, LockedBalance(0, 0, 0, false));
        _notifyAfterTokenBurned(_tokenId, tokenOwner, sender);

        IERC20(token).safeTransfer(tokenOwner, value);

        emit Withdraw(tokenOwner, _tokenId, value, block.timestamp);
        emit Supply(supplyBefore, supply);
    }

    /// @inheritdoc IDustLock
    function earlyWithdrawPenaltyAmount(uint256 _tokenId) public view override returns (uint256) {
        LockedBalance memory lock = _locked[_tokenId];
        uint256 amount = lock.amount.toUint256();
        if (amount == 0) return 0;

        /*
         * Permanent locks cannot earlyWithdraw directly; the executable exit path is
         * unlockPermanent followed by earlyWithdraw. Quote that path: the fresh weekly-rounded
         * end unlockPermanent would write, priced on the timed curve.
         */
        uint256 remaining;
        if (lock.isPermanent) {
            remaining = ((block.timestamp + MAXTIME) / WEEK) * WEEK - block.timestamp;
        } else {
            remaining = lock.end > block.timestamp ? lock.end - block.timestamp : 0;
        }
        if (remaining == 0) return 0;
        remaining = Math.min(remaining, MAXTIME);

        uint256 penaltyDenominator = BASIS_POINTS * MAXTIME;
        uint256 penaltyNumerator = MIN_EARLY_WITHDRAW_PENALTY_BPS * MAXTIME
            + (earlyWithdrawPenalty - MIN_EARLY_WITHDRAW_PENALTY_BPS) * remaining;

        // Floor user proceeds, then take the complement so the exact penalty rounds up.
        uint256 proceeds = Math.mulDiv(amount, penaltyDenominator - penaltyNumerator, penaltyDenominator);

        return amount - proceeds;
    }

    /// @inheritdoc IDustLock
    function earlyWithdraw(uint256 _tokenId) external override nonReentrant {
        _earlyWithdraw(_msgSender(), _tokenId, type(uint256).max);
    }

    /// @inheritdoc IDustLock
    function earlyWithdraw(uint256 _tokenId, uint256 _maxPenalty) external override nonReentrant {
        _earlyWithdraw(_msgSender(), _tokenId, _maxPenalty);
    }

    /**
     * @notice Executes an early withdrawal with a penalty ceiling
     * @dev Reverts with `EarlyWithdrawPenaltyAboveMax` before unlocking or burning when the
     *      execution-time penalty exceeds `_maxPenalty`.
     * @param sender The original caller used for approval checks
     * @param _tokenId The veNFT id to withdraw early from
     * @param _maxPenalty The maximum acceptable penalty (type(uint256).max for unbounded)
     */
    function _earlyWithdraw(address sender, uint256 _tokenId, uint256 _maxPenalty) internal {
        if (!_isApprovedOrOwner(sender, _tokenId)) revert NotApprovedOrOwner();

        LockedBalance memory oldLocked = _locked[_tokenId];
        uint256 userPenaltyAmount = earlyWithdrawPenaltyAmount(_tokenId);
        if (userPenaltyAmount > _maxPenalty) revert EarlyWithdrawPenaltyAboveMax(userPenaltyAmount, _maxPenalty);

        if (oldLocked.isPermanent) {
            _unlockPermanent(sender, _tokenId);
            oldLocked = _locked[_tokenId];
        }

        uint256 userLockedAmount = oldLocked.amount.toUint256();

        // Burn the NFT
        address tokenOwner = _ownerOf(_tokenId);
        _burn(_tokenId);

        _locked[_tokenId] = LockedBalance(0, 0, 0, false);
        uint256 supplyBefore = supply;
        supply = supplyBefore - userLockedAmount;

        uint256 userTransferAmount = userLockedAmount - userPenaltyAmount;

        /*
         * oldLocked can have either expired <= timestamp or zero end.
         * oldLocked has only 0 end. Both can have a nonnegative amount.
         */
        _checkpoint(_tokenId, oldLocked, LockedBalance(0, 0, 0, false));
        _notifyAfterTokenBurned(_tokenId, tokenOwner, sender);

        IERC20(token).safeTransfer(tokenOwner, userTransferAmount);
        if (userPenaltyAmount != 0) IERC20(token).safeTransfer(earlyWithdrawTreasury, userPenaltyAmount);

        emit EarlyWithdraw(tokenOwner, _tokenId, userLockedAmount, userTransferAmount, block.timestamp);
        emit Supply(supplyBefore, supply);
    }

    /// @inheritdoc IDustLock
    function setEarlyWithdrawPenalty(uint256 _earlyWithdrawPenalty) external override nonReentrant {
        if (_msgSender() != team) revert NotTeam();
        if (_earlyWithdrawPenalty < MIN_EARLY_WITHDRAW_PENALTY_BPS || _earlyWithdrawPenalty >= BASIS_POINTS) {
            revert InvalidWithdrawPenalty();
        }

        uint256 old = earlyWithdrawPenalty;
        earlyWithdrawPenalty = _earlyWithdrawPenalty;

        emit EarlyWithdrawPenaltyUpdated(old, _earlyWithdrawPenalty);
    }

    /// @inheritdoc IDustLock
    function setEarlyWithdrawTreasury(address _account) external override nonReentrant {
        if (_msgSender() != team) revert NotTeam();
        CommonChecksLibrary.revertIfZeroAddress(_account);

        address old = earlyWithdrawTreasury;
        earlyWithdrawTreasury = _account;

        emit EarlyWithdrawTreasuryUpdated(old, _account);
    }

    /// @inheritdoc IDustLock
    function merge(uint256 _from, uint256 _to) external override nonReentrant {
        address sender = _msgSender();
        if (_from == _to) revert SameNFT();
        if (!_isApprovedOrOwner(sender, _from)) revert NotApprovedOrOwner();
        if (!_isApprovedOrOwner(sender, _to)) revert NotApprovedOrOwner();

        LockedBalance memory oldLockedTo = _locked[_to];
        if (oldLockedTo.end <= block.timestamp && !oldLockedTo.isPermanent) revert LockExpired();

        LockedBalance memory oldLockedFrom = _locked[_from];
        if (oldLockedFrom.end <= block.timestamp && !oldLockedFrom.isPermanent) revert LockExpired();
        if (oldLockedFrom.isPermanent && !oldLockedTo.isPermanent) revert PermanentLock();

        uint256 end = oldLockedFrom.end >= oldLockedTo.end ? oldLockedFrom.end : oldLockedTo.end;
        bool ownershipChangedThisBlock = ownershipChange[_from] == block.number || ownershipChange[_to] == block.number;

        address tokenOwner = _ownerOf(_from);
        _notifyAfterTokenMerged(_from, _to, tokenOwner);

        _burn(_from);
        _locked[_from] = LockedBalance(0, 0, 0, false);
        _checkpoint(_from, oldLockedFrom, LockedBalance(0, 0, 0, false));

        LockedBalance memory newLockedTo;
        newLockedTo.amount = oldLockedTo.amount + oldLockedFrom.amount;

        newLockedTo.isPermanent = oldLockedTo.isPermanent;
        if (newLockedTo.isPermanent) {
            if (!oldLockedFrom.isPermanent) permanentLockBalance += oldLockedFrom.amount.toUint256();
        } else {
            newLockedTo.end = end;
            // Use weighted average to preserve time served from both locks for timed locks
            newLockedTo.effectiveStart = _calculateWeightedStart(
                oldLockedTo.amount.toUint256(),
                oldLockedTo.effectiveStart,
                oldLockedFrom.amount.toUint256(),
                oldLockedFrom.effectiveStart
            );
        }
        _checkpoint(_to, oldLockedTo, newLockedTo);
        _locked[_to] = newLockedTo;
        if (ownershipChangedThisBlock) ownershipChange[_to] = block.number;

        emit Merge(
            sender,
            _from,
            _to,
            oldLockedFrom.amount.toUint256(),
            oldLockedTo.amount.toUint256(),
            newLockedTo.amount.toUint256(),
            newLockedTo.end,
            block.timestamp
        );
        emit MetadataUpdate(_to);
    }

    /// @inheritdoc IDustLock
    function split(uint256 _from, uint256 _amount)
        external
        override
        nonReentrant
        returns (uint256 _tokenId1, uint256 _tokenId2)
    {
        CommonChecksLibrary.revertIfZeroAmount(_amount);
        address tokenOwner = _ownerOfOrRevert(_from);
        address sender = _msgSender();
        if (!canSplit[tokenOwner] && !canSplit[address(0)]) revert SplitNotAllowed();
        if (!_isApprovedOrOwner(sender, _from)) revert NotApprovedOrOwner();

        LockedBalance memory newLocked = _locked[_from];
        if (newLocked.end <= block.timestamp && !newLocked.isPermanent) revert LockExpired();
        if (newLocked.isPermanent) revert PermanentLock();
        if (_amount < minLockAmount) revert AmountTooSmall();

        bool ownershipChangedThisBlock = ownershipChange[_from] == block.number;
        int256 splitAmount = _amount.toInt256();
        if (newLocked.amount <= splitAmount) revert AmountTooBig();
        if (uint256(newLocked.amount - splitAmount) < minLockAmount) revert AmountTooSmall();

        // Zero out and burn old veNFT
        _burn(_from);
        _locked[_from] = LockedBalance(0, 0, 0, false);
        _checkpoint(_from, newLocked, LockedBalance(0, 0, 0, false));

        // Create new veNFT using old balance - amount
        newLocked.amount -= splitAmount;
        uint256 token1Amount = newLocked.amount.toUint256();
        _tokenId1 = _createSplitNFT(tokenOwner, newLocked);

        // Create new veNFT using amount
        newLocked.amount = splitAmount;
        _tokenId2 = _createSplitNFT(tokenOwner, newLocked);
        if (ownershipChangedThisBlock) {
            ownershipChange[_tokenId1] = block.number;
            ownershipChange[_tokenId2] = block.number;
        }

        _notifyAfterTokenSplit(_from, _tokenId1, token1Amount, _tokenId2, _amount, tokenOwner);

        emit Split(
            _from,
            _tokenId1,
            _tokenId2,
            sender,
            _locked[_tokenId1].amount.toUint256(),
            splitAmount.toUint256(),
            newLocked.end,
            block.timestamp
        );
    }

    /**
     * @notice Helper function to create a new veNFT as part of the split operation
     * @dev This function:
     *      1. Increments the global tokenId counter to get a new ID
     *      2. Sets the lock parameters for the new token
     *      3. Creates a checkpoint for the new veNFT
     *      4. Mints the new veNFT to the specified owner
     * @param _to Address that will own the new veNFT
     * @param _newLocked Lock parameters (amount, end time, permanent status) for the new veNFT
     * @return _tokenId The ID of the newly created veNFT
     */
    function _createSplitNFT(address _to, LockedBalance memory _newLocked) private returns (uint256 _tokenId) {
        _tokenId = ++tokenId;
        _locked[_tokenId] = _newLocked;
        _checkpoint(_tokenId, LockedBalance(0, 0, 0, false), _newLocked);
        _mint(_to, _tokenId);
    }

    /// @inheritdoc IDustLock
    function toggleSplit(address _account, bool _bool) external override {
        if (_msgSender() != team) revert NotTeam();

        canSplit[_account] = _bool;

        emit SplitPermissionUpdated(_account, _bool);
    }

    /// @inheritdoc IDustLock
    function lockPermanent(uint256 _tokenId) external override nonReentrant {
        _lockPermanent(_msgSender(), _tokenId);
    }

    /// @inheritdoc IDustLock
    function unlockPermanent(uint256 _tokenId) external override nonReentrant {
        _unlockPermanent(_msgSender(), _tokenId);
    }

    /**
     * @notice Converts a time-locked veNFT into a permanent lock
     * @dev Core implementation to convert a time-locked veNFT into a permanent lock.
     *      Centralizes checks, checkpointing and events for reuse by wrappers.
     *      Copies `_locked[_tokenId]` (storage) to memory when passed to `_checkpoint`. No storage mutation occurs.
     * @param caller Address used for approval/ownership checks (msg.sender).
     * @param _tokenId The veNFT id to make permanent.
     */
    function _lockPermanent(address caller, uint256 _tokenId) internal {
        if (!_isApprovedOrOwner(caller, _tokenId)) revert NotApprovedOrOwner();
        LockedBalance memory _newLocked = _locked[_tokenId];
        if (_newLocked.isPermanent) revert PermanentLock();
        if (_newLocked.end <= block.timestamp) revert LockExpired();
        if (_newLocked.amount <= 0) revert NoLockFound();

        address tokenOwner = _ownerOf(_tokenId);
        uint256 _amount = _newLocked.amount.toUint256();
        permanentLockBalance += _amount;
        _newLocked.end = 0;
        _newLocked.isPermanent = true;
        _checkpoint(_tokenId, _locked[_tokenId], _newLocked);
        _locked[_tokenId] = _newLocked;

        emit LockPermanent(tokenOwner, _tokenId, _amount, block.timestamp);
        emit MetadataUpdate(_tokenId);
    }

    /**
     * @notice Converts a permanent lock back into a time-locked veNFT
     * @dev Core implementation shared by the external wrapper and permanent early withdrawals.
     * @param caller Address used for approval/ownership checks (msg.sender).
     * @param _tokenId The veNFT id to unlock.
     */
    function _unlockPermanent(address caller, uint256 _tokenId) internal {
        if (!_isApprovedOrOwner(caller, _tokenId)) revert NotApprovedOrOwner();
        LockedBalance memory _newLocked = _locked[_tokenId];
        if (!_newLocked.isPermanent) revert NotPermanentLock();

        address tokenOwner = _ownerOf(_tokenId);
        uint256 _amount = _newLocked.amount.toUint256();
        permanentLockBalance -= _amount;
        _newLocked.effectiveStart = block.timestamp;
        _newLocked.end = ((block.timestamp + MAXTIME) / WEEK) * WEEK;
        _newLocked.isPermanent = false;
        _checkpoint(_tokenId, _locked[_tokenId], _newLocked);
        _locked[_tokenId] = _newLocked;

        emit UnlockPermanent(tokenOwner, _tokenId, _amount, block.timestamp);
        emit MetadataUpdate(_tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                            GAUGE VOTING LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Computes voting power for `_tokenId` at timestamp `_t`.
     * @dev Delegates to BalanceLogicLibrary; wraps internal storage mappings.
     * @param _tokenId The veNFT id to query.
     * @param _t The timestamp to evaluate voting power at.
     * @return The voting power in token units.
     */
    function _balanceOfNFTAt(uint256 _tokenId, uint256 _t) internal view returns (uint256) {
        return BalanceLogicLibrary.balanceOfNFTAt(userPointEpoch, _userPointHistory, _tokenId, _t);
    }

    /**
     * @notice Computes total voting power (supply) at a given timestamp.
     * @dev Delegates to BalanceLogicLibrary; wraps internal storage mappings.
     * @param _timestamp The timestamp to evaluate.
     * @return Total voting power in token units.
     */
    function _supplyAt(uint256 _timestamp) internal view returns (uint256) {
        return BalanceLogicLibrary.supplyAt(slopeChanges, _pointHistory, epoch, _timestamp);
    }

    /// @inheritdoc IDustLock
    function balanceOfNFT(uint256 _tokenId) public view override returns (uint256) {
        if (ownershipChange[_tokenId] == block.number) return 0;
        return _balanceOfNFTAt(_tokenId, block.timestamp);
    }

    /// @inheritdoc IDustLock
    function balanceOfNFTAt(uint256 _tokenId, uint256 _t) external view override returns (uint256) {
        return _balanceOfNFTAt(_tokenId, _t);
    }

    /// @inheritdoc IDustLock
    function totalSupply() external view override returns (uint256) {
        return _supplyAt(block.timestamp);
    }

    /// @inheritdoc IDustLock
    function totalSupplyAt(uint256 _timestamp) external view override returns (uint256) {
        return _supplyAt(_timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                              ERC6372 LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDustLock
    function clock() external view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @inheritdoc IDustLock
    function CLOCK_MODE() external pure override returns (string memory) {
        return "mode=timestamp";
    }

    /*//////////////////////////////////////////////////////////////
                          MIN LOCK AMOUNT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDustLock
    function setMinLockAmount(uint256 newMinLockAmount) public override {
        if (_msgSender() != team) revert NotTeam();
        CommonChecksLibrary.revertIfZeroAmount(newMinLockAmount);

        uint256 old = minLockAmount;
        minLockAmount = newMinLockAmount;

        emit MinLockAmountUpdated(old, newMinLockAmount);
    }

    /*//////////////////////////////////////////////////////////////
                          NOTIFY CONTRACTS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDustLock
    function setRevenueReward(IRevenueReward _revenueReward) public override {
        if (_msgSender() != team) revert NotTeam();

        IRevenueReward old = revenueReward;
        address newReward = address(_revenueReward);
        // Allow disabling by setting to zero address; otherwise require a contract
        if (newReward != address(0) && !CommonLibrary.isContract(newReward)) revert InvalidRevenueRewardContract();

        revenueReward = _revenueReward;

        emit RevenueRewardUpdated(address(old), newReward);
    }

    /**
     * @notice Internal hook to notify the reward system after a token transfer.
     * @dev No-op if `revenueReward` is unset.
     * @param _tokenId The transferred token id.
     * @param _previousOwner The address that previously owned the token.
     * @param _to The new owner address (unused in reward notification)
     * @param _sender The operator that initiated the transfer (unused in reward notification)
     */
    function _notifyAfterTokenTransferred(uint256 _tokenId, address _previousOwner, address _to, address _sender)
        internal
    {
        (_to, _sender);
        if (address(revenueReward) != address(0)) {
            revenueReward.notifyAfterTokenTransferred(_tokenId, _previousOwner);
        }
    }

    /**
     * @notice Internal hook to notify the reward system after a token burn.
     * @dev No-op if `revenueReward` is unset.
     * @param _tokenId The burned token id.
     * @param _previousOwner The address that previously owned the token.
     * @param _sender The operator that initiated the burn (unused in reward notification)
     */
    function _notifyAfterTokenBurned(uint256 _tokenId, address _previousOwner, address _sender) internal {
        _sender;
        if (address(revenueReward) != address(0)) {
            revenueReward.notifyAfterTokenBurned(_tokenId, _previousOwner);
        }
    }

    /**
     * @notice Internal hook to notify the reward system after a token mint.
     * @dev No-op if `revenueReward` is unset.
     * @param _tokenId The newly minted token id.
     * @param _owner The initial owner address (unused in reward notification)
     * @param _sender The operator that initiated the mint (unused in reward notification)
     */
    function _notifyTokenMinted(uint256 _tokenId, address _owner, address _sender) internal {
        (_owner, _sender);
        if (address(revenueReward) != address(0)) {
            revenueReward.notifyTokenMinted(_tokenId);
        }
    }

    /**
     * @notice Internal hook to notify the reward system after a token merge.
     * @dev No-op if `revenueReward` is unset.
     * @param _fromToken The source token id that was burned.
     * @param _toToken The destination token id that persists.
     * @param tokenOwner The owner involved in the merge.
     */
    function _notifyAfterTokenMerged(uint256 _fromToken, uint256 _toToken, address tokenOwner) internal {
        if (address(revenueReward) != address(0)) {
            revenueReward.notifyAfterTokenMerged(_fromToken, _toToken, tokenOwner);
        }
    }

    /**
     * @notice Internal hook to notify the reward system after a token split.
     * @dev No-op if `revenueReward` is unset.
     * @param fromToken The original token id that was split.
     * @param tokenId1 The first resulting token id.
     * @param token1Amount Amount allocated to `tokenId1`.
     * @param tokenId2 The second resulting token id.
     * @param token2Amount Amount allocated to `tokenId2`.
     * @param tokenOwner The owner involved in the split.
     */
    function _notifyAfterTokenSplit(
        uint256 fromToken,
        uint256 tokenId1,
        uint256 token1Amount,
        uint256 tokenId2,
        uint256 token2Amount,
        address tokenOwner
    ) internal {
        if (address(revenueReward) != address(0)) {
            revenueReward.notifyAfterTokenSplit(fromToken, tokenId1, token1Amount, tokenId2, token2Amount, tokenOwner);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        CREATOR EARNINGS (ERC721-C)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICreatorToken
    function getTransferValidator() external view override returns (address) {
        return transferValidator;
    }

    /// @inheritdoc ICreatorToken
    function getTransferValidationFunction() external view override returns (bytes4, bool) {
        return CreatorTokenLibrary.getTransferValidationFunction(
            transferValidationFunctionSelector, transferValidationFunctionIsView
        );
    }

    /// @inheritdoc ICreatorToken
    function setTransferValidator(address newValidator) external override {
        if (_msgSender() != team) revert NotTeam();

        CreatorTokenLibrary.setTransferValidator(transferValidator, newValidator);
        transferValidator = newValidator;
    }

    /// @inheritdoc IDustLock
    function setTransferValidationFunction(bytes4 validationSelector, bool isViewFunction) external override {
        if (_msgSender() != team) revert NotTeam();

        bool nextIsViewFunction = CreatorTokenLibrary.setTransferValidationFunction(
            transferValidationFunctionSelector, transferValidationFunctionIsView, validationSelector, isViewFunction
        );
        transferValidationFunctionSelector = validationSelector;
        transferValidationFunctionIsView = nextIsViewFunction;
    }

    /// @inheritdoc IDustLock
    function setFeeEnforcedOperator(address operator, bool enforced) external override {
        if (_msgSender() != team) revert NotTeam();

        CreatorTokenLibrary.setFeeEnforcedOperator(
            feeEnforcedOperatorIndexPlusOne, feeEnforcedOperators, operator, enforced
        );
    }

    /// @inheritdoc IDustLock
    function isFeeEnforcedOperator(address operator) public view override returns (bool) {
        return feeEnforcedOperatorIndexPlusOne[operator] != 0;
    }

    /// @inheritdoc IDustLock
    function feeEnforcedOperatorCount() external view override returns (uint256) {
        return feeEnforcedOperators.length;
    }

    /// @inheritdoc IDustLock
    function feeEnforcedOperatorAt(uint256 index) external view override returns (address) {
        return feeEnforcedOperators[index];
    }

    /*//////////////////////////////////////////////////////////////
                        ROYALTY INFO (EIP-2981)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC2981
    function royaltyInfo(uint256, uint256 salePrice)
        external
        view
        override
        returns (address receiver, uint256 royaltyAmount)
    {
        receiver = royaltyReceiver;
        royaltyAmount = (salePrice * royaltyFeeBps) / BASIS_POINTS;
    }

    /// @inheritdoc IDustLock
    function setRoyaltyInfo(address receiver, uint96 feeBps) external override {
        if (_msgSender() != team) revert NotTeam();
        CommonChecksLibrary.revertIfZeroAddress(receiver);
        if (feeBps > BASIS_POINTS) revert InvalidRoyaltyFee();

        address oldReceiver = royaltyReceiver;
        uint96 oldFeeBps = royaltyFeeBps;

        royaltyReceiver = receiver;
        royaltyFeeBps = feeBps;

        emit RoyaltyInfoUpdated(oldReceiver, receiver, oldFeeBps, feeBps);
        if (tokenId > 0) emit BatchMetadataUpdate(1, tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                      ERC721-C INTERNALS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Validates a token transfer against the ERC721-C transfer validator.
     * @dev Delegates to `CreatorTokenLibrary.validateTransfer`, which runs under this contract's
     *      `delegatecall`. Fee-enforced operators are validated; forwarder-relayed transfers are
     *      blocked while a validator is active; all other callers skip validation.
     * @param caller The address initiating the transfer (msg.sender).
     * @param from The current owner of the token.
     * @param to The recipient of the token.
     * @param tokenId_ The token id being transferred.
     */
    function _validateTransfer(address caller, address from, address to, uint256 tokenId_) internal {
        CreatorTokenLibrary.validateTransfer(
            transferValidator,
            isTrustedForwarder(msg.sender),
            transferValidationFunctionSelector,
            transferValidationFunctionIsView,
            feeEnforcedOperatorIndexPlusOne,
            caller,
            from,
            to,
            tokenId_
        );
    }
}
