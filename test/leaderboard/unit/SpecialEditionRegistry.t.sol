// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ISpecialEditionRegistry} from "../../../src/interfaces/ISpecialEditionRegistry.sol";

import {SpecialEditionRegistry} from "../../../src/leaderboard/SpecialEditionRegistry.sol";
import {LeaderboardBase} from "./LeaderboardBase.sol";

contract SpecialEditionRegistryTest is LeaderboardBase {
    event MembershipCorrected(
        uint256 indexed tokenId,
        uint16 indexed editionId,
        bool oldMember,
        bool newMember,
        bytes32 sourceHash,
        string reason,
        uint256 timestamp
    );
    event SpecialEditionRegistered(
        uint256 indexed tokenId,
        uint16 indexed editionId,
        bytes32 indexed sourceHash,
        uint256 tokenEditionBitmap,
        uint256 editionTokenCount,
        uint256 timestamp
    );
    event SpecialEditionRegistrationBatch(
        uint16 indexed editionId, uint256 submittedCount, uint256 registeredCount, uint256 timestamp
    );

    SpecialEditionRegistry internal specialEditionRegistry;
    SpecialEditionRegistry internal implementation;

    address internal publisher = address(0x5151);

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function _setUp() internal override {
        implementation = new SpecialEditionRegistry();
        bytes memory initializer = abi.encodeCall(SpecialEditionRegistry.initialize, (admin, publisher));
        TransparentUpgradeableProxy registryProxy =
            new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), initializer);
        specialEditionRegistry = SpecialEditionRegistry(address(registryProxy));

        vm.label(address(implementation), "SpecialEditionRegistryImplementation");
        vm.label(address(specialEditionRegistry), "SpecialEditionRegistry");
        vm.label(publisher, "SpecialEditionPublisher");
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function testInitialState() public view {
        assertEq(specialEditionRegistry.owner(), admin, "owner");
        assertEq(specialEditionRegistry.publisher(), publisher, "publisher");
        assertEq(specialEditionRegistry.getEditionIds().length, 0, "edition count");
        assertEq(specialEditionRegistry.MAX_BATCH_SIZE(), 400, "max batch size");
        assertEq(specialEditionRegistry.MAX_EDITION_ID(), 255, "max edition id");
        assertEq(specialEditionRegistry.MAX_PER_TOKEN_BOOST_BPS(), 10_000, "max boost");
    }

    function testImplementationAndProxyCannotBeReinitialized() public {
        vm.expectRevert("Initializable: contract is already initialized");
        implementation.initialize(admin, publisher);

        vm.expectRevert("Initializable: contract is already initialized");
        specialEditionRegistry.initialize(admin, publisher);
    }

    function testAtomicInitializationRejectsZeroRoles() public {
        bytes4 addressZero = bytes4(keccak256("AddressZero()"));

        vm.expectRevert(addressZero);
        new TransparentUpgradeableProxy(
            address(implementation),
            address(proxyAdmin),
            abi.encodeCall(SpecialEditionRegistry.initialize, (address(0), publisher))
        );

        vm.expectRevert(addressZero);
        new TransparentUpgradeableProxy(
            address(implementation),
            address(proxyAdmin),
            abi.encodeCall(SpecialEditionRegistry.initialize, (admin, address(0)))
        );
    }

    /*//////////////////////////////////////////////////////////////
                        EDITION CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function testCreateAndConfigureEdition() public {
        vm.startPrank(admin);
        specialEditionRegistry.createEdition(1, "SHINY", "Shiny", 500, true);
        specialEditionRegistry.configureEdition(1, "Shiny veDUST", 800);
        specialEditionRegistry.setEditionEnabled(1, false);
        vm.stopPrank();

        ISpecialEditionRegistry.Edition memory edition = specialEditionRegistry.getEdition(1);
        assertEq(edition.id, 1, "edition id");
        assertEq(edition.key, "SHINY", "edition key");
        assertEq(edition.name, "Shiny veDUST", "edition name");
        assertEq(edition.perTokenBoostBps, 800, "boost");
        assertFalse(edition.enabled, "enabled");
        assertTrue(edition.exists, "exists");

        uint16[] memory ids = specialEditionRegistry.getEditionIds();
        assertEq(ids.length, 1, "ids length");
        assertEq(ids[0], 1, "stored id");
    }

    function testCreateEditionRejectsDuplicateIdAndKey() public {
        vm.startPrank(admin);
        specialEditionRegistry.createEdition(1, "SHINY", "Shiny", 500, true);

        vm.expectRevert(abi.encodeWithSelector(ISpecialEditionRegistry.EditionAlreadyExists.selector, 1));
        specialEditionRegistry.createEdition(1, "GOLD", "Gold", 500, true);

        vm.expectRevert(abi.encodeWithSelector(ISpecialEditionRegistry.EditionKeyAlreadyExists.selector, "SHINY"));
        specialEditionRegistry.createEdition(2, "SHINY", "Shiny Again", 500, true);
        vm.stopPrank();
    }

    function testCreateEditionValidatesInputs() public {
        vm.startPrank(admin);

        vm.expectRevert(abi.encodeWithSelector(ISpecialEditionRegistry.InvalidEditionId.selector, 0));
        specialEditionRegistry.createEdition(0, "ZERO", "Zero", 0, true);

        vm.expectRevert(ISpecialEditionRegistry.InvalidEditionKey.selector);
        specialEditionRegistry.createEdition(1, "", "Shiny", 0, true);

        vm.expectRevert(ISpecialEditionRegistry.InvalidName.selector);
        specialEditionRegistry.createEdition(1, "SHINY", "", 0, true);

        vm.expectRevert(abi.encodeWithSelector(ISpecialEditionRegistry.InvalidPerTokenBoost.selector, 10_001));
        specialEditionRegistry.createEdition(1, "SHINY", "Shiny", 10_001, true);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        PUBLISHER REGISTRATION
    //////////////////////////////////////////////////////////////*/

    function testPublisherBatchRegistersTokensAndSkipsDuplicates() public {
        _createShinyEdition();

        uint256[] memory tokenIds = new uint256[](4);
        tokenIds[0] = 42;
        tokenIds[1] = 42;
        tokenIds[2] = 43;
        tokenIds[3] = 44;

        bytes32[] memory sourceHashes = new bytes32[](4);
        sourceHashes[0] = keccak256("42:a");
        sourceHashes[1] = keccak256("42:b");
        sourceHashes[2] = keccak256("43");
        sourceHashes[3] = keccak256("44");

        vm.expectEmit(true, true, true, true, address(specialEditionRegistry));
        emit SpecialEditionRegistered(42, 1, sourceHashes[0], 2, 1, block.timestamp);
        vm.expectEmit(true, true, true, true, address(specialEditionRegistry));
        emit SpecialEditionRegistered(43, 1, sourceHashes[2], 2, 2, block.timestamp);
        vm.expectEmit(true, true, true, true, address(specialEditionRegistry));
        emit SpecialEditionRegistered(44, 1, sourceHashes[3], 2, 3, block.timestamp);

        vm.prank(publisher);
        uint256 registeredCount = specialEditionRegistry.batchRegisterSpecialEdition(1, tokenIds, sourceHashes);

        assertEq(registeredCount, 3, "registered count");
        assertTrue(specialEditionRegistry.hasEdition(42, 1), "token 42 registered");
        assertEq(specialEditionRegistry.getTokenEditionBitmap(42), 2, "token 42 bitmap");
        assertEq(specialEditionRegistry.getEditionTokenCount(1), 3, "edition token count");
    }

    function testPublisherBatchRequiresPublisherAndMatchingLengths() public {
        _createShinyEdition();

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 42;

        bytes32[] memory sourceHashes = new bytes32[](0);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ISpecialEditionRegistry.NotPublisher.selector, user1));
        specialEditionRegistry.batchRegisterSpecialEdition(1, tokenIds, sourceHashes);

        vm.prank(publisher);
        vm.expectRevert(ISpecialEditionRegistry.InvalidBatchLength.selector);
        specialEditionRegistry.batchRegisterSpecialEdition(1, tokenIds, sourceHashes);
    }

    function testPublisherBatchRequiresExistingEditionAndMaxSize() public {
        uint256[] memory tokenIds = new uint256[](401);
        bytes32[] memory sourceHashes = new bytes32[](401);

        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(ISpecialEditionRegistry.EditionNotFound.selector, 1));
        specialEditionRegistry.batchRegisterSpecialEdition(1, tokenIds, sourceHashes);

        _createShinyEdition();

        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(ISpecialEditionRegistry.BatchTooLarge.selector, 401, 400));
        specialEditionRegistry.batchRegisterSpecialEdition(1, tokenIds, sourceHashes);
    }

    function testPublisherBatchAcceptsEmptyAndExactMaxSize() public {
        _createShinyEdition();

        uint256[] memory emptyTokenIds = new uint256[](0);
        bytes32[] memory emptySourceHashes = new bytes32[](0);
        vm.expectEmit(true, false, false, true, address(specialEditionRegistry));
        emit SpecialEditionRegistrationBatch(1, 0, 0, block.timestamp);
        vm.prank(publisher);
        assertEq(
            specialEditionRegistry.batchRegisterSpecialEdition(1, emptyTokenIds, emptySourceHashes),
            0,
            "empty registered count"
        );

        uint256[] memory tokenIds = new uint256[](400);
        bytes32[] memory sourceHashes = new bytes32[](400);
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            tokenIds[i] = i + 1;
            sourceHashes[i] = keccak256(abi.encode("max", i));
        }

        vm.prank(publisher);
        assertEq(
            specialEditionRegistry.batchRegisterSpecialEdition(1, tokenIds, sourceHashes), 400, "max registered count"
        );
        assertEq(specialEditionRegistry.getEditionTokenCount(1), 400, "max stored count");
    }

    function testPublisherBatchRollsBackWhenLaterTokenIsInvalid() public {
        _createShinyEdition();

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 42;
        tokenIds[1] = 0;
        bytes32[] memory sourceHashes = new bytes32[](2);
        sourceHashes[0] = keccak256("valid-first");
        sourceHashes[1] = keccak256("invalid-last");

        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(ISpecialEditionRegistry.InvalidTokenId.selector, 0));
        specialEditionRegistry.batchRegisterSpecialEdition(1, tokenIds, sourceHashes);

        assertFalse(specialEditionRegistry.hasEdition(42, 1), "first token rolled back");
        assertEq(specialEditionRegistry.getEditionTokenCount(1), 0, "list rolled back");
    }

    function testPublisherCanRegisterArbitraryNonzeroTokenId() public {
        _createShinyEdition();

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = type(uint256).max;
        bytes32[] memory sourceHashes = new bytes32[](1);
        sourceHashes[0] = keccak256("not-validated-against-dust-lock");

        vm.prank(publisher);
        specialEditionRegistry.batchRegisterSpecialEdition(1, tokenIds, sourceHashes);

        assertTrue(
            specialEditionRegistry.hasEdition(type(uint256).max, 1), "any nonzero id is accepted by deployed behavior"
        );
    }

    function testPublisherBatchRejectsZeroTokenId() public {
        _createShinyEdition();

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 0;

        bytes32[] memory sourceHashes = new bytes32[](1);
        sourceHashes[0] = keccak256("zero-token");

        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(ISpecialEditionRegistry.InvalidTokenId.selector, 0));
        specialEditionRegistry.batchRegisterSpecialEdition(1, tokenIds, sourceHashes);
    }

    /*//////////////////////////////////////////////////////////////
                         VIEWS AND MEMBERSHIP
    //////////////////////////////////////////////////////////////*/

    function testPaginationReturnsEditionTokenPages() public {
        _createShinyEdition();
        _registerTokens(1, 5);

        uint256[] memory page = specialEditionRegistry.getEditionTokenIdsPage(1, 1, 3);
        assertEq(page.length, 3, "page length");
        assertEq(page[0], 101, "page 0");
        assertEq(page[1], 102, "page 1");
        assertEq(page[2], 103, "page 2");

        uint256[] memory tail = specialEditionRegistry.getEditionTokenIdsPage(1, 4, 10);
        assertEq(tail.length, 1, "tail length");
        assertEq(tail[0], 104, "tail token");
    }

    function testPaginationEmptyAndOverflowBoundaries() public {
        _createShinyEdition();
        _registerTokens(1, 2);

        assertEq(specialEditionRegistry.getEditionTokenIdsPage(1, 0, 0).length, 0, "zero limit");
        assertEq(specialEditionRegistry.getEditionTokenIdsPage(1, 2, 1).length, 0, "offset at end");
        assertEq(specialEditionRegistry.getEditionTokenIdsPage(1, 3, 1).length, 0, "offset after end");

        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        specialEditionRegistry.getEditionTokenIdsPage(1, 1, type(uint256).max);
    }

    function testMissingAndInvalidEditionViews() public view {
        assertFalse(specialEditionRegistry.hasEdition(42, 1), "valid uncreated edition is false");
    }

    function testInvalidEditionViewsRevert() public {
        vm.expectRevert(abi.encodeWithSelector(ISpecialEditionRegistry.InvalidEditionId.selector, 0));
        specialEditionRegistry.hasEdition(42, 0);

        vm.expectRevert(abi.encodeWithSelector(ISpecialEditionRegistry.InvalidEditionId.selector, 256));
        specialEditionRegistry.hasEdition(42, 256);

        vm.expectRevert(abi.encodeWithSelector(ISpecialEditionRegistry.EditionNotFound.selector, 1));
        specialEditionRegistry.getEdition(1);

        vm.expectRevert(abi.encodeWithSelector(ISpecialEditionRegistry.EditionNotFound.selector, 1));
        specialEditionRegistry.getEditionTokenCount(1);

        vm.expectRevert(abi.encodeWithSelector(ISpecialEditionRegistry.EditionNotFound.selector, 1));
        specialEditionRegistry.getEditionTokenIdsPage(1, 0, 1);
    }

    function testMultiEditionMembershipAndDisableAreIndependent() public {
        vm.startPrank(admin);
        specialEditionRegistry.createEdition(1, "SHINY", "Shiny", 500, true);
        specialEditionRegistry.createEdition(2, "LOST", "Lost Boy", 750, true);
        vm.stopPrank();

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 42;
        bytes32[] memory sourceHashes = new bytes32[](1);
        sourceHashes[0] = keccak256("multi-edition");
        vm.startPrank(publisher);
        specialEditionRegistry.batchRegisterSpecialEdition(1, tokenIds, sourceHashes);
        specialEditionRegistry.batchRegisterSpecialEdition(2, tokenIds, sourceHashes);
        vm.stopPrank();

        assertEq(specialEditionRegistry.getTokenEditionBitmap(42), 6, "bits one and two");
        vm.prank(admin);
        specialEditionRegistry.setEditionEnabled(1, false);
        assertTrue(specialEditionRegistry.hasEdition(42, 1), "disable preserves membership");
        assertTrue(specialEditionRegistry.hasEdition(42, 2), "other membership preserved");

        vm.prank(admin);
        specialEditionRegistry.correctMembership(42, 1, false, keccak256("remove-one"), "remove one");
        assertEq(specialEditionRegistry.getTokenEditionBitmap(42), 4, "only edition two remains");
        assertTrue(specialEditionRegistry.hasEdition(42, 2), "edition two remains");
    }

    function testEditionIdBoundaryAndTopBitBitmap() public {
        vm.prank(admin);
        specialEditionRegistry.createEdition(255, "TOP", "Top Bit", 500, true);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 42;

        bytes32[] memory sourceHashes = new bytes32[](1);
        sourceHashes[0] = keccak256("top-bit");

        vm.prank(publisher);
        specialEditionRegistry.batchRegisterSpecialEdition(255, tokenIds, sourceHashes);

        assertTrue(specialEditionRegistry.hasEdition(42, 255), "top-bit member");
        assertEq(specialEditionRegistry.getTokenEditionBitmap(42), uint256(1) << 255, "top-bit bitmap");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISpecialEditionRegistry.InvalidEditionId.selector, 256));
        specialEditionRegistry.createEdition(256, "TOO_HIGH", "Too High", 500, true);
    }

    /*//////////////////////////////////////////////////////////////
                       GOVERNANCE CORRECTIONS
    //////////////////////////////////////////////////////////////*/

    function testGovernanceCorrectionAddsAndRemovesMembership() public {
        _createShinyEdition();

        vm.expectEmit(true, true, false, true, address(specialEditionRegistry));
        emit MembershipCorrected(42, 1, false, true, keccak256("manual-add"), "manual add", block.timestamp);
        vm.prank(admin);
        specialEditionRegistry.correctMembership(42, 1, true, keccak256("manual-add"), "manual add");

        assertTrue(specialEditionRegistry.hasEdition(42, 1), "added");
        assertEq(specialEditionRegistry.getEditionTokenCount(1), 1, "count after add");

        vm.expectEmit(true, true, false, true, address(specialEditionRegistry));
        emit MembershipCorrected(42, 1, true, false, keccak256("manual-remove"), "manual remove", block.timestamp);
        vm.prank(admin);
        specialEditionRegistry.correctMembership(42, 1, false, keccak256("manual-remove"), "manual remove");

        assertFalse(specialEditionRegistry.hasEdition(42, 1), "removed");
        assertEq(specialEditionRegistry.getEditionTokenCount(1), 0, "count after remove");
        assertEq(specialEditionRegistry.getTokenEditionBitmap(42), 0, "bitmap after remove");
    }

    function testGovernanceCorrectionRemoveMaintainsMovedTokenIndex() public {
        _createShinyEdition();
        _registerTokens(1, 3);

        vm.prank(admin);
        specialEditionRegistry.correctMembership(101, 1, false, keccak256("remove-middle"), "remove middle");

        uint256[] memory page = specialEditionRegistry.getEditionTokenIdsPage(1, 0, 3);
        assertEq(page.length, 2, "page length after middle removal");
        assertEq(page[0], 100, "first token kept");
        assertEq(page[1], 102, "last token moved");
        assertFalse(specialEditionRegistry.hasEdition(101, 1), "middle removed");
        assertTrue(specialEditionRegistry.hasEdition(102, 1), "moved token still member");

        vm.prank(admin);
        specialEditionRegistry.correctMembership(102, 1, false, keccak256("remove-moved"), "remove moved");

        page = specialEditionRegistry.getEditionTokenIdsPage(1, 0, 3);
        assertEq(page.length, 1, "page length after moved removal");
        assertEq(page[0], 100, "remaining token");
        assertFalse(specialEditionRegistry.hasEdition(102, 1), "moved token removed");
    }

    function testGovernanceCorrectionRejectsNoOp() public {
        _createShinyEdition();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISpecialEditionRegistry.MembershipAlreadySet.selector, 42, 1, false));
        specialEditionRegistry.correctMembership(42, 1, false, bytes32(0), "noop");
    }

    function testGovernanceCorrectionRejectsZeroTokenId() public {
        _createShinyEdition();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISpecialEditionRegistry.InvalidTokenId.selector, 0));
        specialEditionRegistry.correctMembership(0, 1, true, keccak256("zero-token"), "manual add");
    }

    /*//////////////////////////////////////////////////////////////
                         ADMIN AND OWNERSHIP
    //////////////////////////////////////////////////////////////*/

    function testOwnerOnlyConfigurationAndPublisherUpdate() public {
        vm.prank(user1);
        _expectOwnableCallerNotOwnerRevert();
        specialEditionRegistry.createEdition(1, "SHINY", "Shiny", 500, true);

        vm.prank(admin);
        specialEditionRegistry.createEdition(1, "SHINY", "Shiny", 500, true);

        vm.prank(user1);
        _expectOwnableCallerNotOwnerRevert();
        specialEditionRegistry.configureEdition(1, "Shiny veDUST", 800);

        vm.prank(user1);
        _expectOwnableCallerNotOwnerRevert();
        specialEditionRegistry.setEditionEnabled(1, false);

        vm.prank(user1);
        _expectOwnableCallerNotOwnerRevert();
        specialEditionRegistry.correctMembership(42, 1, true, keccak256("manual-add"), "manual add");

        vm.prank(user1);
        _expectOwnableCallerNotOwnerRevert();
        specialEditionRegistry.setPublisher(user2);

        vm.prank(admin);
        specialEditionRegistry.setPublisher(user2);

        assertEq(specialEditionRegistry.publisher(), user2, "new publisher");

        vm.prank(admin);
        vm.expectRevert(bytes4(keccak256("AddressZero()")));
        specialEditionRegistry.setPublisher(address(0));
    }

    function testRenounceOwnershipReverts() public {
        vm.prank(admin);
        vm.expectRevert(ISpecialEditionRegistry.CannotRenounceOwnership.selector);
        specialEditionRegistry.renounceOwnership();
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates the canonical edition-one fixture as the registry owner
     */
    function _createShinyEdition() internal {
        vm.prank(admin);
        specialEditionRegistry.createEdition(1, "SHINY", "Shiny", 500, true);
    }

    /**
     * @notice Configures the next call to expect the OpenZeppelin v4 owner guard revert
     */
    function _expectOwnableCallerNotOwnerRevert() internal {
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("Error(string)")), "Ownable: caller is not the owner"));
    }

    /**
     * @notice Registers a deterministic sequence of token IDs and source hashes
     * @param editionId Edition receiving the generated memberships
     * @param count Number of memberships to generate
     */
    function _registerTokens(uint16 editionId, uint256 count) internal {
        uint256[] memory tokenIds = new uint256[](count);
        bytes32[] memory sourceHashes = new bytes32[](count);

        for (uint256 i = 0; i < count; ++i) {
            tokenIds[i] = 100 + i;
            sourceHashes[i] = keccak256(abi.encodePacked("source", i));
        }

        vm.prank(publisher);
        specialEditionRegistry.batchRegisterSpecialEdition(editionId, tokenIds, sourceHashes);
    }
}
