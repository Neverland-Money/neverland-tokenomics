// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin-v5/contracts/token/ERC20/IERC20.sol";

/**
 * @title INeverlandProfileItemsSeller
 * @author Neverland
 * @notice Interface for the DUST-powered profile item seller
 */
interface INeverlandProfileItemsSeller {
    /*//////////////////////////////////////////////////////////////
                                ENUMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sale category used to decide whether an item is unique or stackable
    enum ItemCategory {
        Permanent,
        Consumable
    }

    /*//////////////////////////////////////////////////////////////
                               STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Stored item sale configuration
     * @param price DUST price in wei
     * @param category Permanent or consumable category
     * @param available Whether purchases are currently enabled
     * @param configured Whether the item exists in the seller catalogue
     */
    struct Item {
        uint256 price;
        ItemCategory category;
        bool available;
        bool configured;
    }

    /**
     * @notice Owner-provided item configuration
     * @param itemSlug Canonical profile shop item slug
     * @param price DUST price in wei
     * @param category Permanent or consumable category
     * @param available Whether purchases should be enabled
     */
    struct ItemConfig {
        string itemSlug;
        uint256 price;
        ItemCategory category;
        bool available;
    }

    /**
     * @notice One requested checkout line
     * @param itemSlug Canonical profile shop item slug
     * @param quantity Units to buy
     */
    struct PurchaseLine {
        string itemSlug;
        uint256 quantity;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when the DUST recipient changes
     * @param oldFundsRecipient Previous funds recipient
     * @param newFundsRecipient New funds recipient
     */
    event FundsRecipientUpdated(address indexed oldFundsRecipient, address indexed newFundsRecipient);

    /**
     * @notice Emitted when an item sale configuration changes
     * @param itemSlugHash Hash of the canonical item slug
     * @param itemSlug Canonical item slug
     * @param oldPrice Previous DUST price in wei
     * @param newPrice New DUST price in wei
     * @param category Permanent or consumable category
     * @param available Whether purchases are enabled
     */
    event ItemConfigured(
        bytes32 indexed itemSlugHash,
        string itemSlug,
        uint256 oldPrice,
        uint256 newPrice,
        ItemCategory category,
        bool available
    );

    /**
     * @notice Emitted for each purchased item line
     * @param buyer Wallet paying DUST
     * @param recipient Wallet receiving the item
     * @param itemSlugHash Hash of the canonical item slug
     * @param purchaseId Monotonic checkout id shared by every line in a batch
     * @param itemSlug Canonical item slug
     * @param category Permanent or consumable category
     * @param quantity Units purchased
     * @param unitPrice DUST price per unit in wei
     * @param totalPrice DUST paid for this line in wei
     */
    event ItemPurchased(
        address indexed buyer,
        address indexed recipient,
        bytes32 indexed itemSlugHash,
        uint256 purchaseId,
        string itemSlug,
        ItemCategory category,
        uint256 quantity,
        uint256 unitPrice,
        uint256 totalPrice
    );

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Item category cannot change after first configuration
     * @param itemSlugHash Hash of the canonical item slug
     * @param oldCategory Existing item category
     * @param newCategory Requested item category
     */
    error CategoryChangeDisabled(bytes32 itemSlugHash, ItemCategory oldCategory, ItemCategory newCategory);

    /**
     * @notice DUST recipient did not receive the exact expected amount
     * @param expected Expected DUST received in wei
     * @param actual Actual DUST received in wei
     */
    error DustReceivedMismatch(uint256 expected, uint256 actual);

    /// @notice Empty item configuration array
    error EmptyItemConfigs();

    /// @notice Item slug was empty
    error EmptyItemSlug();

    /// @notice Empty purchase lines array
    error EmptyPurchaseLines();

    /**
     * @notice Purchase batch exceeded the maximum supported line count
     * @param provided Number of checkout lines provided
     * @param maxAllowed Maximum supported checkout lines
     */
    error TooManyPurchaseLines(uint256 provided, uint256 maxAllowed);

    /**
     * @notice DUST recipient cannot be the seller proxy itself
     * @param fundsRecipient Invalid funds recipient
     */
    error FundsRecipientCannotBeSeller(address fundsRecipient);

    /**
     * @notice Permanent item has already been bought for the recipient
     * @param recipient Wallet that already owns the item
     * @param itemSlugHash Hash of the canonical item slug
     */
    error ItemAlreadyBought(address recipient, bytes32 itemSlugHash);

    /**
     * @notice Item is not configured
     * @param itemSlugHash Hash of the canonical item slug
     */
    error ItemNotConfigured(bytes32 itemSlugHash);

    /**
     * @notice Purchase quantity is invalid
     * @param itemSlugHash Hash of the canonical item slug
     * @param quantity Invalid quantity
     */
    error ItemQuantityInvalid(bytes32 itemSlugHash, uint256 quantity);

    /**
     * @notice Item purchases are not currently available
     * @param itemSlugHash Hash of the canonical item slug
     */
    error ItemUnavailable(bytes32 itemSlugHash);

    /**
     * @notice Permanent item quantity must be exactly one
     * @param itemSlugHash Hash of the canonical item slug
     * @param quantity Invalid quantity
     */
    error PermanentQuantityInvalid(bytes32 itemSlugHash, uint256 quantity);

    /**
     * @notice Caller-provided expected price did not match the configured price
     * @param expected Expected total price in wei
     * @param actual Actual configured total price in wei
     */
    error PriceMismatch(uint256 expected, uint256 actual);

    /// @notice Ownership renouncement is disabled
    error RenounceOwnershipDisabled();

    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Configure one item
     * @param config Item configuration
     */
    function configureItem(ItemConfig calldata config) external;

    /**
     * @notice Configure multiple items
     * @param configs Item configurations
     */
    function configureItems(ItemConfig[] calldata configs) external;

    /**
     * @notice Initialize proxy storage
     * @param dustToken_ DUST token address
     * @param fundsRecipient_ Initial DUST recipient
     * @param initialOwner_ Initial owner
     * @param initialItems_ Initial profile shop item configurations
     */
    function initialize(
        address dustToken_,
        address fundsRecipient_,
        address initialOwner_,
        ItemConfig[] calldata initialItems_
    ) external;

    /**
     * @notice Pause purchases
     */
    function pause() external;

    /**
     * @notice Disable ownership renouncement
     */
    function renounceOwnership() external;

    /**
     * @notice Update the DUST recipient
     * @param newFundsRecipient New funds recipient
     */
    function setFundsRecipient(address newFundsRecipient) external;

    /**
     * @notice Unpause purchases
     */
    function unpause() external;

    /*//////////////////////////////////////////////////////////////
                           PURCHASE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Purchase one item with exact DUST pricing
     * @param itemSlug Canonical profile shop item slug
     * @param giftTo Recipient wallet; zero address means msg.sender
     * @param expectedPrice Caller-provided expected DUST price in wei
     * @return purchaseId Monotonic checkout id
     */
    function purchaseItem(string calldata itemSlug, address giftTo, uint256 expectedPrice)
        external
        returns (uint256 purchaseId);

    /**
     * @notice Purchase multiple item lines with exact DUST pricing
     * @param lines Checkout lines
     * @param giftTo Recipient wallet; zero address means msg.sender
     * @param expectedTotalPrice Caller-provided expected DUST total in wei
     * @return purchaseId Monotonic checkout id
     */
    function purchaseItems(PurchaseLine[] calldata lines, address giftTo, uint256 expectedTotalPrice)
        external
        returns (uint256 purchaseId);

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Number of purchased consumable units for a recipient and slug hash
     * @param recipient Recipient wallet
     * @param slugHash Hash of the canonical item slug
     * @return count Purchased unit count
     */
    function consumablePurchases(address recipient, bytes32 slugHash) external view returns (uint256 count);

    /**
     * @notice DUST token used for purchases
     * @return token DUST token
     */
    function dustToken() external view returns (IERC20 token);

    /**
     * @notice Current DUST recipient
     * @return recipient Funds recipient
     */
    function fundsRecipient() external view returns (address recipient);

    /**
     * @notice Read an item by slug
     * @param itemSlug Canonical profile shop item slug
     * @return item Stored item configuration
     */
    function getItem(string calldata itemSlug) external view returns (Item memory item);

    /**
     * @notice Check whether a recipient owns a permanent item
     * @param recipient Recipient wallet
     * @param slugHash Hash of the canonical item slug
     * @return owned Whether the permanent item was already bought
     */
    function hasPermanentItem(address recipient, bytes32 slugHash) external view returns (bool owned);

    /**
     * @notice Number of configured item slugs
     * @return count Item slug count
     */
    function itemCount() external view returns (uint256 count);

    /**
     * @notice Hash a canonical item slug
     * @param itemSlug Canonical profile shop item slug
     * @return slugHash Hash of the slug
     */
    function itemSlugHash(string calldata itemSlug) external pure returns (bytes32 slugHash);

    /**
     * @notice Read an item slug by enumerable index
     * @param index Item slug index
     * @return itemSlug Canonical profile shop item slug
     */
    function itemSlugAt(uint256 index) external view returns (string memory itemSlug);

    /**
     * @notice Next checkout id
     * @return purchaseId Next purchase id
     */
    function nextPurchaseId() external view returns (uint256 purchaseId);
}
