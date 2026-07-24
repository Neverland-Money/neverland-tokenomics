// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC20} from "@openzeppelin-v5/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

import {INeverlandProfileItemsSeller} from "../../../src/interfaces/INeverlandProfileItemsSeller.sol";

import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";

import {NeverlandProfileItemsSeller} from "../../../src/utils/NeverlandProfileItemsSeller.sol";

contract MintableDust is ERC20 {
    constructor() ERC20("DUST", "DUST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CountingDust is MintableDust {
    uint256 public transferFromCalls;

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        ++transferFromCalls;

        return super.transferFrom(from, to, value);
    }
}

contract ShortPayDust is MintableDust {
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _spendAllowance(from, _msgSender(), value);
        _transfer(from, to, value - 1);
        _burn(from, 1);

        return true;
    }
}

contract NoCreditDust is MintableDust {
    function transferFrom(address from, address, uint256 value) public override returns (bool) {
        _spendAllowance(from, _msgSender(), value);
        _burn(from, value);

        return true;
    }
}

contract NeverlandProfileItemsSellerTest is Test {
    event FundsRecipientUpdated(address indexed oldFundsRecipient, address indexed newFundsRecipient);
    event ItemConfigured(
        bytes32 indexed itemSlugHash,
        string itemSlug,
        uint256 oldPrice,
        uint256 newPrice,
        INeverlandProfileItemsSeller.ItemCategory category,
        bool available
    );
    event ItemPurchased(
        address indexed buyer,
        address indexed recipient,
        bytes32 indexed itemSlugHash,
        uint256 purchaseId,
        string itemSlug,
        INeverlandProfileItemsSeller.ItemCategory category,
        uint256 quantity,
        uint256 unitPrice,
        uint256 totalPrice
    );

    MintableDust internal dust;
    ProxyAdmin internal proxyAdmin;
    NeverlandProfileItemsSeller internal seller;

    address internal buyer = makeAddr("buyer");
    address internal fundsRecipient = makeAddr("fundsRecipient");
    address internal giftRecipient = makeAddr("giftRecipient");
    address internal owner = makeAddr("owner");

    string internal constant CONSUMABLE_SLUG = "consumable-enchanted-coral";
    string internal constant TITLE_SLUG = "title-tide-rider";

    bytes32 internal constant CONSUMABLE_HASH = keccak256(bytes(CONSUMABLE_SLUG));
    bytes32 internal constant TITLE_HASH = keccak256(bytes(TITLE_SLUG));

    function setUp() public {
        dust = new MintableDust();
        proxyAdmin = new ProxyAdmin();
        seller = _deploySeller();

        dust.mint(buyer, 1_000 ether);
        vm.prank(buyer);
        dust.approve(address(seller), type(uint256).max);
    }

    function testInitializeConfiguresInitialItems() public view {
        assertEq(address(seller.dustToken()), address(dust));
        assertEq(seller.fundsRecipient(), fundsRecipient);
        assertEq(seller.owner(), owner);
        assertEq(seller.nextPurchaseId(), 1);
        assertEq(seller.itemCount(), 2);
        assertEq(seller.itemSlugAt(0), TITLE_SLUG);
        assertEq(seller.itemSlugAt(1), CONSUMABLE_SLUG);
        assertEq(seller.itemSlugHash(TITLE_SLUG), TITLE_HASH);

        INeverlandProfileItemsSeller.Item memory item = seller.getItem(TITLE_SLUG);
        assertEq(item.price, 5 ether);
        assertEq(uint256(item.category), uint256(INeverlandProfileItemsSeller.ItemCategory.Permanent));
        assertTrue(item.available);
        assertTrue(item.configured);
    }

    function testInitializeRejectsZeroAddresses() public {
        INeverlandProfileItemsSeller.ItemConfig[] memory items = _initialItems();

        NeverlandProfileItemsSeller implementation = new NeverlandProfileItemsSeller();

        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        _deploySellerProxy(implementation, address(0), fundsRecipient, owner, items);

        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        _deploySellerProxy(implementation, address(dust), address(0), owner, items);

        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        _deploySellerProxy(implementation, address(dust), fundsRecipient, address(0), items);
    }

    function testInitializeRejectsSellerAsFundsRecipient() public {
        INeverlandProfileItemsSeller.ItemConfig[] memory items = _initialItems();
        NeverlandProfileItemsSeller implementation = new NeverlandProfileItemsSeller();
        address predictedProxy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandProfileItemsSeller.FundsRecipientCannotBeSeller.selector, predictedProxy)
        );
        _deploySellerProxy(implementation, address(dust), predictedProxy, owner, items);
    }

    function testImplementationDisablesInitializers() public {
        NeverlandProfileItemsSeller implementation = new NeverlandProfileItemsSeller();

        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        implementation.initialize(address(dust), fundsRecipient, owner, _initialItems());
    }

    function testInitializeCannotRunTwice() public {
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        seller.initialize(address(dust), fundsRecipient, owner, _initialItems());
    }

    function testConfigureItemUpdatesPriceAndAvailability() public {
        vm.expectEmit(true, false, false, true, address(seller));
        emit ItemConfigured(
            TITLE_HASH, TITLE_SLUG, 5 ether, 7 ether, INeverlandProfileItemsSeller.ItemCategory.Permanent, false
        );

        vm.prank(owner);
        seller.configureItem(
            INeverlandProfileItemsSeller.ItemConfig({
                itemSlug: TITLE_SLUG,
                price: 7 ether,
                category: INeverlandProfileItemsSeller.ItemCategory.Permanent,
                available: false
            })
        );

        INeverlandProfileItemsSeller.Item memory item = seller.getItem(TITLE_SLUG);
        assertEq(item.price, 7 ether);
        assertFalse(item.available);
    }

    function testConfigureItemsRejectsEmptyBatch() public {
        INeverlandProfileItemsSeller.ItemConfig[] memory items = new INeverlandProfileItemsSeller.ItemConfig[](0);

        vm.expectRevert(INeverlandProfileItemsSeller.EmptyItemConfigs.selector);
        vm.prank(owner);
        seller.configureItems(items);
    }

    function testConfigureItemsAddsMultipleItems() public {
        INeverlandProfileItemsSeller.ItemConfig[] memory items = new INeverlandProfileItemsSeller.ItemConfig[](2);
        items[0] = INeverlandProfileItemsSeller.ItemConfig({
            itemSlug: "theme-island-believer",
            price: 25 ether,
            category: INeverlandProfileItemsSeller.ItemCategory.Permanent,
            available: true
        });
        items[1] = INeverlandProfileItemsSeller.ItemConfig({
            itemSlug: "consumable-fairy-wand",
            price: 5 ether,
            category: INeverlandProfileItemsSeller.ItemCategory.Consumable,
            available: false
        });

        vm.prank(owner);
        seller.configureItems(items);

        assertEq(seller.itemCount(), 4);
        assertEq(seller.itemSlugAt(2), "theme-island-believer");
        assertEq(seller.itemSlugAt(3), "consumable-fairy-wand");

        INeverlandProfileItemsSeller.Item memory theme = seller.getItem("theme-island-believer");
        assertEq(theme.price, 25 ether);
        assertTrue(theme.available);

        INeverlandProfileItemsSeller.Item memory wand = seller.getItem("consumable-fairy-wand");
        assertEq(wand.price, 5 ether);
        assertFalse(wand.available);
    }

    function testConfigureRejectsCategoryChange() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                INeverlandProfileItemsSeller.CategoryChangeDisabled.selector,
                TITLE_HASH,
                INeverlandProfileItemsSeller.ItemCategory.Permanent,
                INeverlandProfileItemsSeller.ItemCategory.Consumable
            )
        );
        vm.prank(owner);
        seller.configureItem(
            INeverlandProfileItemsSeller.ItemConfig({
                itemSlug: TITLE_SLUG,
                price: 5 ether,
                category: INeverlandProfileItemsSeller.ItemCategory.Consumable,
                available: true
            })
        );
    }

    function testConfigureRejectsEmptySlugAndZeroPrice() public {
        vm.expectRevert(INeverlandProfileItemsSeller.EmptyItemSlug.selector);
        vm.prank(owner);
        seller.configureItem(
            INeverlandProfileItemsSeller.ItemConfig({
                itemSlug: "",
                price: 1 ether,
                category: INeverlandProfileItemsSeller.ItemCategory.Permanent,
                available: true
            })
        );

        vm.expectRevert(CommonChecksLibrary.ZeroAmount.selector);
        vm.prank(owner);
        seller.configureItem(
            INeverlandProfileItemsSeller.ItemConfig({
                itemSlug: "title-zero",
                price: 0,
                category: INeverlandProfileItemsSeller.ItemCategory.Permanent,
                available: true
            })
        );
    }

    function testConfigureRequiresOwner() public {
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        vm.prank(buyer);
        seller.configureItem(
            INeverlandProfileItemsSeller.ItemConfig({
                itemSlug: "title-other",
                price: 1 ether,
                category: INeverlandProfileItemsSeller.ItemCategory.Permanent,
                available: true
            })
        );
    }

    function testPurchasePermanentForSelf() public {
        vm.expectEmit(true, true, true, true, address(seller));
        emit ItemPurchased(
            buyer,
            buyer,
            TITLE_HASH,
            1,
            TITLE_SLUG,
            INeverlandProfileItemsSeller.ItemCategory.Permanent,
            1,
            5 ether,
            5 ether
        );

        vm.prank(buyer);
        uint256 purchaseId = seller.purchaseItem(TITLE_SLUG, address(0), 5 ether);

        assertEq(purchaseId, 1);
        assertEq(seller.nextPurchaseId(), 2);
        assertEq(dust.balanceOf(fundsRecipient), 5 ether);
        assertTrue(seller.hasPermanentItem(buyer, TITLE_HASH));
    }

    function testPurchasePermanentGiftUsesRecipientOwnership() public {
        vm.prank(buyer);
        seller.purchaseItem(TITLE_SLUG, giftRecipient, 5 ether);

        assertFalse(seller.hasPermanentItem(buyer, TITLE_HASH));
        assertTrue(seller.hasPermanentItem(giftRecipient, TITLE_HASH));

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandProfileItemsSeller.ItemAlreadyBought.selector, giftRecipient, TITLE_HASH)
        );
        vm.prank(buyer);
        seller.purchaseItem(TITLE_SLUG, giftRecipient, 5 ether);
    }

    function testPurchasePermanentCanBeGiftedToDifferentRecipients() public {
        address otherRecipient = makeAddr("otherRecipient");

        vm.prank(buyer);
        seller.purchaseItem(TITLE_SLUG, giftRecipient, 5 ether);

        vm.prank(buyer);
        seller.purchaseItem(TITLE_SLUG, otherRecipient, 5 ether);

        assertTrue(seller.hasPermanentItem(giftRecipient, TITLE_HASH));
        assertTrue(seller.hasPermanentItem(otherRecipient, TITLE_HASH));
        assertEq(dust.balanceOf(fundsRecipient), 10 ether);
    }

    function testFundsRecipientCanGiftWithSelfTransfer() public {
        dust.mint(fundsRecipient, 100 ether);

        vm.prank(fundsRecipient);
        dust.approve(address(seller), 5 ether);

        vm.prank(fundsRecipient);
        uint256 purchaseId = seller.purchaseItem(TITLE_SLUG, giftRecipient, 5 ether);

        assertEq(purchaseId, 1);
        assertEq(dust.balanceOf(fundsRecipient), 100 ether);
        assertEq(dust.allowance(fundsRecipient, address(seller)), 0);
        assertTrue(seller.hasPermanentItem(giftRecipient, TITLE_HASH));
    }

    function testPurchasePermanentRejectsDuplicateSelf() public {
        vm.startPrank(buyer);
        seller.purchaseItem(TITLE_SLUG, address(0), 5 ether);

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandProfileItemsSeller.ItemAlreadyBought.selector, buyer, TITLE_HASH)
        );
        seller.purchaseItem(TITLE_SLUG, address(0), 5 ether);
        vm.stopPrank();
    }

    function testPurchaseConsumableRepeatsAndBatches() public {
        vm.prank(buyer);
        seller.purchaseItem(CONSUMABLE_SLUG, address(0), 5 ether);

        INeverlandProfileItemsSeller.PurchaseLine[] memory lines = new INeverlandProfileItemsSeller.PurchaseLine[](2);
        lines[0] = INeverlandProfileItemsSeller.PurchaseLine({itemSlug: CONSUMABLE_SLUG, quantity: 3});
        lines[1] = INeverlandProfileItemsSeller.PurchaseLine({itemSlug: TITLE_SLUG, quantity: 1});

        vm.prank(buyer);
        uint256 purchaseId = seller.purchaseItems(lines, address(0), 20 ether);

        assertEq(purchaseId, 2);
        assertEq(seller.consumablePurchases(buyer, CONSUMABLE_HASH), 4);
        assertTrue(seller.hasPermanentItem(buyer, TITLE_HASH));
        assertEq(dust.balanceOf(fundsRecipient), 25 ether);
    }

    function testPurchaseBatchGiftUsesRecipientOwnershipAndConsumables() public {
        INeverlandProfileItemsSeller.PurchaseLine[] memory lines = new INeverlandProfileItemsSeller.PurchaseLine[](2);
        lines[0] = INeverlandProfileItemsSeller.PurchaseLine({itemSlug: CONSUMABLE_SLUG, quantity: 2});
        lines[1] = INeverlandProfileItemsSeller.PurchaseLine({itemSlug: TITLE_SLUG, quantity: 1});

        vm.prank(buyer);
        seller.purchaseItems(lines, giftRecipient, 15 ether);

        assertFalse(seller.hasPermanentItem(buyer, TITLE_HASH));
        assertTrue(seller.hasPermanentItem(giftRecipient, TITLE_HASH));
        assertEq(seller.consumablePurchases(buyer, CONSUMABLE_HASH), 0);
        assertEq(seller.consumablePurchases(giftRecipient, CONSUMABLE_HASH), 2);
    }

    function testPurchaseBatchUsesOneDustTransferAndEmitsLines() public {
        CountingDust countingDust = new CountingDust();
        NeverlandProfileItemsSeller countingSellerImpl = new NeverlandProfileItemsSeller();
        NeverlandProfileItemsSeller countingSeller =
            _deploySellerProxy(countingSellerImpl, address(countingDust), fundsRecipient, owner, _initialItems());
        countingDust.mint(buyer, 1_000 ether);
        vm.prank(buyer);
        countingDust.approve(address(countingSeller), type(uint256).max);

        INeverlandProfileItemsSeller.PurchaseLine[] memory lines = new INeverlandProfileItemsSeller.PurchaseLine[](2);
        lines[0] = INeverlandProfileItemsSeller.PurchaseLine({itemSlug: CONSUMABLE_SLUG, quantity: 2});
        lines[1] = INeverlandProfileItemsSeller.PurchaseLine({itemSlug: TITLE_SLUG, quantity: 1});

        vm.expectEmit(true, true, true, true, address(countingSeller));
        emit ItemPurchased(
            buyer,
            buyer,
            CONSUMABLE_HASH,
            1,
            CONSUMABLE_SLUG,
            INeverlandProfileItemsSeller.ItemCategory.Consumable,
            2,
            5 ether,
            10 ether
        );
        vm.expectEmit(true, true, true, true, address(countingSeller));
        emit ItemPurchased(
            buyer,
            buyer,
            TITLE_HASH,
            1,
            TITLE_SLUG,
            INeverlandProfileItemsSeller.ItemCategory.Permanent,
            1,
            5 ether,
            5 ether
        );

        vm.prank(buyer);
        countingSeller.purchaseItems(lines, address(0), 15 ether);

        assertEq(countingDust.transferFromCalls(), 1);
        assertEq(countingDust.balanceOf(fundsRecipient), 15 ether);
    }

    function testPurchaseBatchRejectsDuplicatePermanentLine() public {
        INeverlandProfileItemsSeller.PurchaseLine[] memory lines = new INeverlandProfileItemsSeller.PurchaseLine[](2);
        lines[0] = INeverlandProfileItemsSeller.PurchaseLine({itemSlug: TITLE_SLUG, quantity: 1});
        lines[1] = INeverlandProfileItemsSeller.PurchaseLine({itemSlug: TITLE_SLUG, quantity: 1});

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandProfileItemsSeller.PermanentQuantityInvalid.selector, TITLE_HASH, 1)
        );
        vm.prank(buyer);
        seller.purchaseItems(lines, address(0), 10 ether);
    }

    function testPurchaseBatchRejectsPermanentAlreadyOwnedByRecipient() public {
        vm.prank(buyer);
        seller.purchaseItem(TITLE_SLUG, giftRecipient, 5 ether);

        INeverlandProfileItemsSeller.PurchaseLine[] memory lines = new INeverlandProfileItemsSeller.PurchaseLine[](1);
        lines[0] = INeverlandProfileItemsSeller.PurchaseLine({itemSlug: TITLE_SLUG, quantity: 1});

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandProfileItemsSeller.ItemAlreadyBought.selector, giftRecipient, TITLE_HASH)
        );
        vm.prank(buyer);
        seller.purchaseItems(lines, giftRecipient, 5 ether);
    }

    function testPurchaseRejectsPriceMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(INeverlandProfileItemsSeller.PriceMismatch.selector, 4 ether, 5 ether));
        vm.prank(buyer);
        seller.purchaseItem(TITLE_SLUG, address(0), 4 ether);

        assertEq(dust.balanceOf(fundsRecipient), 0);
        assertFalse(seller.hasPermanentItem(buyer, TITLE_HASH));
    }

    function testPurchaseBatchRejectsTotalPriceMismatch() public {
        INeverlandProfileItemsSeller.PurchaseLine[] memory lines = new INeverlandProfileItemsSeller.PurchaseLine[](1);
        lines[0] = INeverlandProfileItemsSeller.PurchaseLine({itemSlug: CONSUMABLE_SLUG, quantity: 2});

        vm.expectRevert(abi.encodeWithSelector(INeverlandProfileItemsSeller.PriceMismatch.selector, 9 ether, 10 ether));
        vm.prank(buyer);
        seller.purchaseItems(lines, address(0), 9 ether);

        assertEq(dust.balanceOf(fundsRecipient), 0);
        assertEq(seller.consumablePurchases(buyer, CONSUMABLE_HASH), 0);
    }

    function testPurchaseRejectsShortDustTransfer() public {
        ShortPayDust shortPayDust = new ShortPayDust();
        NeverlandProfileItemsSeller shortPaySellerImpl = new NeverlandProfileItemsSeller();
        NeverlandProfileItemsSeller shortPaySeller =
            _deploySellerProxy(shortPaySellerImpl, address(shortPayDust), fundsRecipient, owner, _initialItems());
        shortPayDust.mint(buyer, 1_000 ether);
        vm.prank(buyer);
        shortPayDust.approve(address(shortPaySeller), type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandProfileItemsSeller.DustReceivedMismatch.selector, 5 ether, 5 ether - 1)
        );
        vm.prank(buyer);
        shortPaySeller.purchaseItem(TITLE_SLUG, address(0), 5 ether);

        assertFalse(shortPaySeller.hasPermanentItem(buyer, TITLE_HASH));
    }

    function testPurchaseRejectsNoCreditDustTransfer() public {
        NoCreditDust noCreditDust = new NoCreditDust();
        NeverlandProfileItemsSeller noCreditSellerImpl = new NeverlandProfileItemsSeller();
        NeverlandProfileItemsSeller noCreditSeller =
            _deploySellerProxy(noCreditSellerImpl, address(noCreditDust), fundsRecipient, owner, _initialItems());
        noCreditDust.mint(buyer, 1_000 ether);
        vm.prank(buyer);
        noCreditDust.approve(address(noCreditSeller), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(INeverlandProfileItemsSeller.DustReceivedMismatch.selector, 5 ether, 0));
        vm.prank(buyer);
        noCreditSeller.purchaseItem(TITLE_SLUG, address(0), 5 ether);

        assertEq(noCreditDust.balanceOf(fundsRecipient), 0);
        assertEq(noCreditDust.balanceOf(buyer), 1_000 ether);
        assertFalse(noCreditSeller.hasPermanentItem(buyer, TITLE_HASH));
    }

    function testPurchaseRejectsUnavailableUnconfiguredAndInvalidQuantity() public {
        vm.prank(owner);
        seller.configureItem(
            INeverlandProfileItemsSeller.ItemConfig({
                itemSlug: TITLE_SLUG,
                price: 5 ether,
                category: INeverlandProfileItemsSeller.ItemCategory.Permanent,
                available: false
            })
        );

        vm.expectRevert(abi.encodeWithSelector(INeverlandProfileItemsSeller.ItemUnavailable.selector, TITLE_HASH));
        vm.prank(buyer);
        seller.purchaseItem(TITLE_SLUG, address(0), 5 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                INeverlandProfileItemsSeller.ItemNotConfigured.selector, keccak256(bytes("title-missing"))
            )
        );
        vm.prank(buyer);
        seller.purchaseItem("title-missing", address(0), 5 ether);

        INeverlandProfileItemsSeller.PurchaseLine[] memory lines = new INeverlandProfileItemsSeller.PurchaseLine[](1);
        lines[0] = INeverlandProfileItemsSeller.PurchaseLine({itemSlug: CONSUMABLE_SLUG, quantity: 0});

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandProfileItemsSeller.ItemQuantityInvalid.selector, CONSUMABLE_HASH, 0)
        );
        vm.prank(buyer);
        seller.purchaseItems(lines, address(0), 0);
    }

    function testPurchaseRejectsPermanentQuantityGreaterThanOne() public {
        INeverlandProfileItemsSeller.PurchaseLine[] memory lines = new INeverlandProfileItemsSeller.PurchaseLine[](1);
        lines[0] = INeverlandProfileItemsSeller.PurchaseLine({itemSlug: TITLE_SLUG, quantity: 2});

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandProfileItemsSeller.PermanentQuantityInvalid.selector, TITLE_HASH, 2)
        );
        vm.prank(buyer);
        seller.purchaseItems(lines, address(0), 10 ether);
    }

    function testPurchaseRejectsEmptyBatch() public {
        INeverlandProfileItemsSeller.PurchaseLine[] memory lines = new INeverlandProfileItemsSeller.PurchaseLine[](0);

        vm.expectRevert(INeverlandProfileItemsSeller.EmptyPurchaseLines.selector);
        vm.prank(buyer);
        seller.purchaseItems(lines, address(0), 0);
    }

    function testPurchaseBatchAllowsMaxLines() public {
        uint256 maxBatchLines = seller.MAX_BATCH_LINES();
        INeverlandProfileItemsSeller.PurchaseLine[] memory lines =
            new INeverlandProfileItemsSeller.PurchaseLine[](maxBatchLines);

        for (uint256 i = 0; i < maxBatchLines; ++i) {
            lines[i] = INeverlandProfileItemsSeller.PurchaseLine({itemSlug: CONSUMABLE_SLUG, quantity: 1});
        }

        vm.prank(buyer);
        uint256 purchaseId = seller.purchaseItems(lines, address(0), maxBatchLines * 5 ether);

        assertEq(purchaseId, 1);
        assertEq(seller.consumablePurchases(buyer, CONSUMABLE_HASH), maxBatchLines);
        assertEq(dust.balanceOf(fundsRecipient), maxBatchLines * 5 ether);
    }

    function testPurchaseBatchRejectsTooManyLines() public {
        uint256 maxBatchLines = seller.MAX_BATCH_LINES();
        INeverlandProfileItemsSeller.PurchaseLine[] memory lines =
            new INeverlandProfileItemsSeller.PurchaseLine[](maxBatchLines + 1);

        for (uint256 i = 0; i < lines.length; ++i) {
            lines[i] = INeverlandProfileItemsSeller.PurchaseLine({itemSlug: CONSUMABLE_SLUG, quantity: 1});
        }

        vm.expectRevert(
            abi.encodeWithSelector(
                INeverlandProfileItemsSeller.TooManyPurchaseLines.selector, maxBatchLines + 1, maxBatchLines
            )
        );
        vm.prank(buyer);
        seller.purchaseItems(lines, address(0), 0);
    }

    function testPauseBlocksPurchasesOnly() public {
        vm.prank(owner);
        seller.pause();

        vm.expectRevert(bytes("Pausable: paused"));
        vm.prank(buyer);
        seller.purchaseItem(TITLE_SLUG, address(0), 5 ether);

        vm.prank(owner);
        seller.configureItem(
            INeverlandProfileItemsSeller.ItemConfig({
                itemSlug: "title-live",
                price: 1 ether,
                category: INeverlandProfileItemsSeller.ItemCategory.Permanent,
                available: true
            })
        );

        vm.prank(owner);
        seller.unpause();

        vm.prank(buyer);
        seller.purchaseItem(TITLE_SLUG, address(0), 5 ether);
    }

    function testSetFundsRecipient() public {
        address newFundsRecipient = makeAddr("newFundsRecipient");

        vm.expectEmit(true, true, false, true, address(seller));
        emit FundsRecipientUpdated(fundsRecipient, newFundsRecipient);

        vm.prank(owner);
        seller.setFundsRecipient(newFundsRecipient);

        assertEq(seller.fundsRecipient(), newFundsRecipient);

        vm.prank(buyer);
        seller.purchaseItem(TITLE_SLUG, address(0), 5 ether);

        assertEq(dust.balanceOf(newFundsRecipient), 5 ether);
    }

    function testSetFundsRecipientRejectsZero() public {
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        vm.prank(owner);
        seller.setFundsRecipient(address(0));
    }

    function testSetFundsRecipientRejectsSeller() public {
        vm.expectRevert(
            abi.encodeWithSelector(INeverlandProfileItemsSeller.FundsRecipientCannotBeSeller.selector, address(seller))
        );
        vm.prank(owner);
        seller.setFundsRecipient(address(seller));
    }

    function testAdminFunctionsRequireOwner() public {
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        vm.prank(buyer);
        seller.pause();

        vm.prank(owner);
        seller.pause();

        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        vm.prank(buyer);
        seller.unpause();

        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        vm.prank(buyer);
        seller.setFundsRecipient(makeAddr("notAllowedRecipient"));
    }

    function testRenounceOwnershipDisabled() public {
        vm.expectRevert(INeverlandProfileItemsSeller.RenounceOwnershipDisabled.selector);
        vm.prank(owner);
        seller.renounceOwnership();
    }

    function testTwoStepOwnershipTransfer() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        seller.transferOwnership(newOwner);

        assertEq(seller.pendingOwner(), newOwner);

        vm.prank(newOwner);
        seller.acceptOwnership();

        vm.prank(newOwner);
        seller.configureItem(
            INeverlandProfileItemsSeller.ItemConfig({
                itemSlug: "title-new-owner",
                price: 1 ether,
                category: INeverlandProfileItemsSeller.ItemCategory.Permanent,
                available: true
            })
        );

        assertEq(seller.owner(), newOwner);
    }

    function _deploySeller() internal returns (NeverlandProfileItemsSeller deployedSeller) {
        NeverlandProfileItemsSeller implementation = new NeverlandProfileItemsSeller();

        return _deploySellerProxy(implementation, address(dust), fundsRecipient, owner, _initialItems());
    }

    function _deploySellerProxy(
        NeverlandProfileItemsSeller implementation,
        address dustToken,
        address recipient,
        address initialOwner,
        INeverlandProfileItemsSeller.ItemConfig[] memory items
    ) internal returns (NeverlandProfileItemsSeller deployedSeller) {
        bytes memory initData =
            abi.encodeCall(NeverlandProfileItemsSeller.initialize, (dustToken, recipient, initialOwner, items));
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), initData);

        return NeverlandProfileItemsSeller(address(proxy));
    }

    function _initialItems() internal pure returns (INeverlandProfileItemsSeller.ItemConfig[] memory items) {
        items = new INeverlandProfileItemsSeller.ItemConfig[](2);
        items[0] = INeverlandProfileItemsSeller.ItemConfig({
            itemSlug: TITLE_SLUG,
            price: 5 ether,
            category: INeverlandProfileItemsSeller.ItemCategory.Permanent,
            available: true
        });
        items[1] = INeverlandProfileItemsSeller.ItemConfig({
            itemSlug: CONSUMABLE_SLUG,
            price: 5 ether,
            category: INeverlandProfileItemsSeller.ItemCategory.Consumable,
            available: true
        });
    }
}
