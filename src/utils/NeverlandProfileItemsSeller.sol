// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin-v5/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-v5/contracts/token/ERC20/utils/SafeERC20.sol";

import {INeverlandProfileItemsSeller} from "../interfaces/INeverlandProfileItemsSeller.sol";

import {CommonChecksLibrary} from "../libraries/CommonChecksLibrary.sol";

/**
 * @title NeverlandProfileItemsSeller
 * @author Neverland
 * @notice DUST seller for profile shop items with an on-chain catalogue
 */
contract NeverlandProfileItemsSeller is
    INeverlandProfileItemsSeller,
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    /// @notice Maximum checkout lines accepted in one batch purchase
    uint256 public constant MAX_BATCH_LINES = 64;

    /**
     * @notice Disables initializers on the implementation contract
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                              INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandProfileItemsSeller
    function initialize(
        address dustToken_,
        address fundsRecipient_,
        address initialOwner_,
        ItemConfig[] calldata initialItems_
    ) external override initializer {
        if (dustToken_ == address(0) || fundsRecipient_ == address(0) || initialOwner_ == address(0)) {
            revert CommonChecksLibrary.AddressZero();
        }
        _revertIfInvalidFundsRecipient(fundsRecipient_);

        __Ownable2Step_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        dustToken = IERC20(dustToken_);
        fundsRecipient = fundsRecipient_;
        nextPurchaseId = 1;
        _transferOwnership(initialOwner_);

        for (uint256 i = 0; i < initialItems_.length; ++i) {
            _configureItem(initialItems_[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           STORAGE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandProfileItemsSeller
    IERC20 public override dustToken;

    /// @inheritdoc INeverlandProfileItemsSeller
    address public override fundsRecipient;

    /// @inheritdoc INeverlandProfileItemsSeller
    uint256 public override nextPurchaseId;

    /// @notice Consumable purchase counts by recipient and slug hash
    mapping(address => mapping(bytes32 => uint256)) private _consumablePurchases;

    /// @notice Configured items by slug hash
    mapping(bytes32 => Item) private _items;

    /// @notice Enumerable item slugs
    string[] private _itemSlugs;

    /// @notice Permanent item ownership by recipient and slug hash
    mapping(address => mapping(bytes32 => bool)) private _permanentItems;

    /// @dev Storage gap for upgrade-safe future upgrades.
    // slither-disable-next-line naming-convention,unused-state
    uint256[50] private __gap;

    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandProfileItemsSeller
    function configureItem(ItemConfig calldata config) external override onlyOwner {
        _configureItem(config);
    }

    /// @inheritdoc INeverlandProfileItemsSeller
    function configureItems(ItemConfig[] calldata configs) external override onlyOwner {
        if (configs.length == 0) revert EmptyItemConfigs();

        for (uint256 i = 0; i < configs.length; ++i) {
            _configureItem(configs[i]);
        }
    }

    /// @inheritdoc INeverlandProfileItemsSeller
    function pause() external override onlyOwner {
        _pause();
    }

    /// @inheritdoc INeverlandProfileItemsSeller
    function setFundsRecipient(address newFundsRecipient) external override onlyOwner {
        if (newFundsRecipient == address(0)) revert CommonChecksLibrary.AddressZero();
        _revertIfInvalidFundsRecipient(newFundsRecipient);

        address oldFundsRecipient = fundsRecipient;
        fundsRecipient = newFundsRecipient;

        emit FundsRecipientUpdated(oldFundsRecipient, newFundsRecipient);
    }

    /// @inheritdoc INeverlandProfileItemsSeller
    function unpause() external override onlyOwner {
        _unpause();
    }

    /// @inheritdoc INeverlandProfileItemsSeller
    function renounceOwnership() public view override(OwnableUpgradeable, INeverlandProfileItemsSeller) onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    /*//////////////////////////////////////////////////////////////
                          PURCHASE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandProfileItemsSeller
    function purchaseItem(string calldata itemSlug, address giftTo, uint256 expectedPrice)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 purchaseId)
    {
        address recipient = giftTo == address(0) ? msg.sender : giftTo;
        bytes32 slugHash = _itemSlugHash(itemSlug);
        Item memory item = _validatedItem(slugHash, 1);
        if (item.category == ItemCategory.Permanent && _permanentItems[recipient][slugHash]) {
            revert ItemAlreadyBought(recipient, slugHash);
        }

        uint256 totalPrice = item.price;
        if (expectedPrice != totalPrice) revert PriceMismatch(expectedPrice, totalPrice);

        purchaseId = _nextPurchaseId();
        _recordPurchaseLine(recipient, slugHash, item.category, 1);

        _collectDust(totalPrice);

        _emitItemPurchased(recipient, slugHash, purchaseId, itemSlug, item.category, 1, item.price);
    }

    /// @inheritdoc INeverlandProfileItemsSeller
    function purchaseItems(PurchaseLine[] calldata lines, address giftTo, uint256 expectedTotalPrice)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 purchaseId)
    {
        if (lines.length == 0) revert EmptyPurchaseLines();
        if (lines.length > MAX_BATCH_LINES) revert TooManyPurchaseLines(lines.length, MAX_BATCH_LINES);

        address recipient = giftTo == address(0) ? msg.sender : giftTo;
        uint256 totalPrice = _validatedTotalPrice(lines, recipient);
        if (expectedTotalPrice != totalPrice) revert PriceMismatch(expectedTotalPrice, totalPrice);

        purchaseId = _nextPurchaseId();
        for (uint256 i = 0; i < lines.length; ++i) {
            PurchaseLine calldata line = lines[i];
            bytes32 slugHash = _itemSlugHash(line.itemSlug);
            Item memory item = _items[slugHash];

            _recordPurchaseLine(recipient, slugHash, item.category, line.quantity);
        }

        _collectDust(totalPrice);

        for (uint256 i = 0; i < lines.length; ++i) {
            PurchaseLine calldata line = lines[i];
            bytes32 slugHash = _itemSlugHash(line.itemSlug);
            Item memory item = _items[slugHash];
            _emitItemPurchased(recipient, slugHash, purchaseId, line.itemSlug, item.category, line.quantity, item.price);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandProfileItemsSeller
    function consumablePurchases(address recipient, bytes32 slugHash) external view override returns (uint256 count) {
        return _consumablePurchases[recipient][slugHash];
    }

    /// @inheritdoc INeverlandProfileItemsSeller
    function getItem(string calldata itemSlug) external view override returns (Item memory item) {
        return _items[_itemSlugHash(itemSlug)];
    }

    /// @inheritdoc INeverlandProfileItemsSeller
    function hasPermanentItem(address recipient, bytes32 slugHash) external view override returns (bool owned) {
        return _permanentItems[recipient][slugHash];
    }

    /// @inheritdoc INeverlandProfileItemsSeller
    function itemCount() external view override returns (uint256 count) {
        return _itemSlugs.length;
    }

    /// @inheritdoc INeverlandProfileItemsSeller
    function itemSlugAt(uint256 index) external view override returns (string memory itemSlug) {
        return _itemSlugs[index];
    }

    /// @inheritdoc INeverlandProfileItemsSeller
    function itemSlugHash(string calldata itemSlug) external pure override returns (bytes32 slugHash) {
        return _itemSlugHash(itemSlug);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Configure an item and append its slug when first seen
     * @param config Item configuration
     */
    function _configureItem(ItemConfig memory config) internal {
        bytes32 slugHash = _itemSlugHash(config.itemSlug);
        CommonChecksLibrary.revertIfZeroAmount(config.price);

        Item memory currentItem = _items[slugHash];
        if (currentItem.configured && currentItem.category != config.category) {
            revert CategoryChangeDisabled(slugHash, currentItem.category, config.category);
        }

        if (!currentItem.configured) {
            _itemSlugs.push(config.itemSlug);
        }

        _items[slugHash] =
            Item({price: config.price, category: config.category, available: config.available, configured: true});

        emit ItemConfigured(
            slugHash, config.itemSlug, currentItem.price, config.price, config.category, config.available
        );
    }

    /**
     * @notice Pull DUST and require exact non-self funds-recipient balance delta
     * @param amount Expected DUST amount in wei
     */
    function _collectDust(uint256 amount) internal {
        address recipient = fundsRecipient;

        if (msg.sender == recipient) {
            dustToken.safeTransferFrom(msg.sender, recipient, amount);
            return;
        }

        uint256 balanceBefore = dustToken.balanceOf(recipient);

        dustToken.safeTransferFrom(msg.sender, recipient, amount);

        uint256 balanceAfter = dustToken.balanceOf(recipient);
        uint256 received = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received != amount) revert DustReceivedMismatch(amount, received);
    }

    /**
     * @notice Emit one purchase line
     * @param recipient Wallet receiving the item
     * @param slugHash Hash of the canonical item slug
     * @param purchaseId Monotonic checkout id
     * @param itemSlug Canonical profile shop item slug
     * @param category Item category
     * @param quantity Purchased quantity
     * @param unitPrice DUST unit price in wei
     */
    function _emitItemPurchased(
        address recipient,
        bytes32 slugHash,
        uint256 purchaseId,
        string calldata itemSlug,
        ItemCategory category,
        uint256 quantity,
        uint256 unitPrice
    ) internal {
        emit ItemPurchased(
            msg.sender, recipient, slugHash, purchaseId, itemSlug, category, quantity, unitPrice, unitPrice * quantity
        );
    }

    /**
     * @notice Record ownership or consumable count for one purchase line
     * @param recipient Wallet receiving the item
     * @param slugHash Hash of the canonical item slug
     * @param category Item category
     * @param quantity Purchased quantity
     */
    function _recordPurchaseLine(address recipient, bytes32 slugHash, ItemCategory category, uint256 quantity)
        internal
    {
        if (category == ItemCategory.Permanent) {
            _permanentItems[recipient][slugHash] = true;

            return;
        }

        _consumablePurchases[recipient][slugHash] += quantity;
    }

    /**
     * @notice Validate that a funds recipient cannot burn purchases into the seller itself
     * @param candidate Proposed DUST funds recipient
     */
    function _revertIfInvalidFundsRecipient(address candidate) internal view {
        if (candidate == address(this)) revert FundsRecipientCannotBeSeller(candidate);
    }

    /**
     * @notice Validate item existence, availability, quantity, and permanent ownership
     * @param slugHash Hash of the canonical item slug
     * @param quantity Requested quantity
     * @return item Stored item configuration
     */
    function _validatedItem(bytes32 slugHash, uint256 quantity) internal view returns (Item memory item) {
        item = _items[slugHash];
        if (!item.configured) revert ItemNotConfigured(slugHash);
        if (!item.available) revert ItemUnavailable(slugHash);
        if (quantity == 0) revert ItemQuantityInvalid(slugHash, quantity);

        if (item.category == ItemCategory.Permanent && quantity != 1) {
            revert PermanentQuantityInvalid(slugHash, quantity);
        }
    }

    /**
     * @notice Validate a batch and return its total price
     * @param lines Checkout lines
     * @param recipient Wallet receiving the items
     * @return totalPrice DUST total in wei
     */
    function _validatedTotalPrice(PurchaseLine[] calldata lines, address recipient)
        internal
        view
        returns (uint256 totalPrice)
    {
        for (uint256 i = 0; i < lines.length; ++i) {
            PurchaseLine calldata line = lines[i];
            bytes32 slugHash = _itemSlugHash(line.itemSlug);
            Item memory item = _validatedItem(slugHash, line.quantity);
            if (item.category == ItemCategory.Permanent && _permanentItems[recipient][slugHash]) {
                revert ItemAlreadyBought(recipient, slugHash);
            }

            if (item.category == ItemCategory.Permanent) {
                _revertIfDuplicatePermanentLine(lines, slugHash, i);
            }

            totalPrice += item.price * line.quantity;
        }
    }

    /**
     * @notice Reverts when a batch contains the same permanent item twice
     * @param lines Checkout lines
     * @param slugHash Current slug hash
     * @param currentIndex Current line index
     */
    function _revertIfDuplicatePermanentLine(PurchaseLine[] calldata lines, bytes32 slugHash, uint256 currentIndex)
        internal
        pure
    {
        for (uint256 i = 0; i < currentIndex; ++i) {
            if (_itemSlugHash(lines[i].itemSlug) == slugHash) {
                revert PermanentQuantityInvalid(slugHash, lines[currentIndex].quantity);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Validate and hash an item slug
     * @param itemSlug Canonical profile shop item slug
     * @return slugHash Hash of the slug
     */
    function _itemSlugHash(string memory itemSlug) private pure returns (bytes32 slugHash) {
        uint256 itemSlugLength = bytes(itemSlug).length;
        if (itemSlugLength == 0) revert EmptyItemSlug();

        // Hash the in-memory string directly to avoid allocating a second bytes copy.
        // solhint-disable no-inline-assembly
        // slither-disable-next-line assembly
        assembly ("memory-safe") {
            slugHash := keccak256(add(itemSlug, 0x20), itemSlugLength)
        }
        // solhint-enable no-inline-assembly
    }

    /**
     * @notice Return and increment the next purchase id
     * @return purchaseId Current purchase id
     */
    function _nextPurchaseId() private returns (uint256 purchaseId) {
        purchaseId = nextPurchaseId;
        nextPurchaseId = purchaseId + 1;
    }
}
