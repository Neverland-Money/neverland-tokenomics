// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IDustLock} from "../../src/interfaces/IDustLock.sol";
import {ICreatorToken} from "../../src/interfaces/ICreatorToken.sol";
import {ITransferValidator} from "../../src/interfaces/ITransferValidator.sol";
import {DustLock} from "../../src/tokens/DustLock.sol";
import {Vm} from "forge-std/Vm.sol";
import {CommonChecksLibrary} from "../../src/libraries/CommonChecksLibrary.sol";
import "../BaseTestLocal.sol";

contract MockTransferValidator is ITransferValidator {
    bool public shouldRevert;

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function validateTransfer(
        address,
        /* caller */
        address,
        /* from */
        address,
        /* to */
        uint256 /* tokenId */
    )
        external
        view
        override
    {
        if (shouldRevert) {
            revert("MockValidator: Transfer not authorized");
        }
    }
}

contract MockTransferValidatorRecording is ITransferValidator {
    function validateTransfer(address, address, address, uint256) external view override {
        // no-op mock validator used for successful view validation flows
    }
}

contract MockTransferValidatorNonView {
    uint256 public callCount;

    function validateTransfer(address, address, address, uint256) external {
        callCount++;
    }
}

contract MockTransferValidatorCapture {
    address public lastCaller;
    address public lastFrom;
    address public lastTo;
    uint256 public lastTokenId;

    function validateTransfer(address caller, address from, address to, uint256 tokenId) external {
        lastCaller = caller;
        lastFrom = from;
        lastTo = to;
        lastTokenId = tokenId;
    }
}

contract DustLockCreatorEarningsTests is BaseTestLocal {
    MockTransferValidator public validator;
    MockTransferValidatorRecording public validatorRecording;
    MockTransferValidatorNonView public validatorNonView;
    MockTransferValidatorCapture public validatorCapture;

    address public protocolTreasury;
    uint96 public constant FEE_250_BPS = 250; // 2.5%
    uint96 public constant FEE_500_BPS = 500; // 5%

    event TransferValidatorUpdated(address oldValidator, address newValidator);
    event TransferValidationFunctionUpdated(bytes4 oldSelector, bytes4 newSelector, bool oldIsView, bool newIsView);
    event FeeEnforcedOperatorUpdated(address operator, bool enforced);
    event RoyaltyInfoUpdated(address oldReceiver, address newReceiver, uint96 oldFeeBps, uint96 newFeeBps);

    function _setUp() internal override {
        assertEq(block.timestamp, 1 weeks + 1);
        mintErc20Token(address(DUST), user, TOKEN_100K);

        validator = new MockTransferValidator();
        validatorRecording = new MockTransferValidatorRecording();
        validatorNonView = new MockTransferValidatorNonView();
        validatorCapture = new MockTransferValidatorCapture();
        protocolTreasury = makeAddr("protocolTreasury");
    }

    /*//////////////////////////////////////////////////////////////
                        EIP-2981 ROYALTY INFO
    //////////////////////////////////////////////////////////////*/

    function testRoyaltyInfoNotConfigured() public view {
        (address receiver, uint256 royaltyAmount) = dustLock.royaltyInfo(1, 100 ether);

        assertEq(receiver, address(0), "Receiver should be zero before config");
        assertEq(royaltyAmount, 0, "Royalty should be zero before config");
    }

    function testSetRoyaltyInfo() public {
        vm.expectEmit(false, false, false, true);
        emit RoyaltyInfoUpdated(address(0), protocolTreasury, 0, FEE_250_BPS);
        dustLock.setRoyaltyInfo(protocolTreasury, FEE_250_BPS);

        (address receiver, uint256 royaltyAmount) = dustLock.royaltyInfo(1, 100 ether);

        assertEq(receiver, protocolTreasury, "Receiver should be treasury");
        assertEq(royaltyAmount, 2.5 ether, "Royalty should be 2.5% of 100 ETH");
    }

    function testSetRoyaltyInfoDifferentAmounts() public {
        dustLock.setRoyaltyInfo(protocolTreasury, FEE_500_BPS);

        (, uint256 royalty1) = dustLock.royaltyInfo(1, 1 ether);
        assertEq(royalty1, 0.05 ether, "5% of 1 ETH");

        (, uint256 royalty2) = dustLock.royaltyInfo(1, 1000 ether);
        assertEq(royalty2, 50 ether, "5% of 1000 ETH");

        (, uint256 royalty3) = dustLock.royaltyInfo(1, 0.1 ether);
        assertEq(royalty3, 0.005 ether, "5% of 0.1 ETH");
    }

    function testSetRoyaltyInfoOnlyTeam() public {
        vm.startPrank(admin);
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.setRoyaltyInfo(protocolTreasury, FEE_250_BPS);
        vm.stopPrank();

        vm.startPrank(user2);
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.setRoyaltyInfo(protocolTreasury, FEE_250_BPS);
        vm.stopPrank();
    }

    function testSetRoyaltyInfoZeroAddressReverts() public {
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        dustLock.setRoyaltyInfo(address(0), FEE_250_BPS);
    }

    function testSetRoyaltyInfoOver100PercentReverts() public {
        vm.expectRevert(IDustLock.InvalidRoyaltyFee.selector);
        dustLock.setRoyaltyInfo(protocolTreasury, 10001);
    }

    function testSetRoyaltyInfoExactly100Percent() public {
        dustLock.setRoyaltyInfo(protocolTreasury, 10000);

        (, uint256 royaltyAmount) = dustLock.royaltyInfo(1, 100 ether);
        assertEq(royaltyAmount, 100 ether, "100% royalty");
    }

    /*//////////////////////////////////////////////////////////////
                    ERC721-C TRANSFER VALIDATOR
    //////////////////////////////////////////////////////////////*/

    function testGetTransferValidatorInitiallyZero() public view {
        assertEq(dustLock.getTransferValidator(), address(0), "Validator should be zero initially");
    }

    function testSetTransferValidator() public {
        vm.expectEmit(true, true, false, false);
        emit TransferValidatorUpdated(address(0), address(validator));

        dustLock.setTransferValidator(address(validator));

        assertEq(dustLock.getTransferValidator(), address(validator), "Validator should be set");
    }

    function testSetTransferValidatorOnlyTeam() public {
        vm.startPrank(admin);
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.setTransferValidator(address(validator));
        vm.stopPrank();

        vm.startPrank(user2);
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.setTransferValidator(address(validator));
        vm.stopPrank();
    }

    function testSetTransferValidatorCanBeZero() public {
        dustLock.setTransferValidator(address(validator));
        assertEq(dustLock.getTransferValidator(), address(validator));

        vm.expectEmit(true, true, false, false);
        emit TransferValidatorUpdated(address(validator), address(0));

        dustLock.setTransferValidator(address(0));
        assertEq(dustLock.getTransferValidator(), address(0), "Validator can be disabled");
    }

    function testGetTransferValidationFunction() public view {
        (bytes4 functionSig, bool isViewFunction) = dustLock.getTransferValidationFunction();

        assertEq(
            uint32(functionSig),
            uint32(ITransferValidator.validateTransfer.selector),
            "Should return substandard 8 selector"
        );
        assertTrue(isViewFunction, "Should be view function");
    }

    function testSetTransferValidationFunction() public {
        bytes4 selector = bytes4(keccak256("validateTransfer(address,address,address,uint256)"));

        dustLock.setTransferValidationFunction(selector, false);

        (bytes4 functionSig, bool isViewFunction) = dustLock.getTransferValidationFunction();
        assertEq(functionSig, selector, "Selector should update");
        assertFalse(isViewFunction, "Should be non-view");
    }

    function testSetTransferValidationFunctionFirstCallEmitsEffectiveOldValues() public {
        bytes4 customSelector = bytes4(keccak256("customValidate(address,address,address,uint256)"));

        // First call from default state: effective old values should be
        // (ITransferValidator.validateTransfer.selector, true) not (bytes4(0), false)
        vm.expectEmit(false, false, false, true);
        emit TransferValidationFunctionUpdated(
            ITransferValidator.validateTransfer.selector, customSelector, true, false
        );
        dustLock.setTransferValidationFunction(customSelector, false);
    }

    function testSetTransferValidatorRevertsForNonContract() public {
        address eoa = makeAddr("eoaValidator");
        vm.expectRevert(IDustLock.InvalidTransferValidatorContract.selector);
        dustLock.setTransferValidator(eoa);
    }

    function testSetTransferValidationFunctionOnlyTeam() public {
        bytes4 selector = bytes4(keccak256("validateTransfer(address,address,address,uint256)"));

        vm.startPrank(admin);
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.setTransferValidationFunction(selector, false);
        vm.stopPrank();

        vm.startPrank(user2);
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.setTransferValidationFunction(selector, false);
        vm.stopPrank();
    }

    function testSetTransferValidationFunctionZeroSelectorResetsToDefault() public {
        bytes4 customSelector = bytes4(keccak256("validateTransfer(address,address,address,uint256)"));
        dustLock.setTransferValidationFunction(customSelector, false);

        vm.expectEmit(false, false, false, true);
        emit TransferValidationFunctionUpdated(customSelector, bytes4(0), false, true);
        dustLock.setTransferValidationFunction(bytes4(0), false);

        (bytes4 functionSig, bool isViewFunction) = dustLock.getTransferValidationFunction();
        assertEq(functionSig, ITransferValidator.validateTransfer.selector, "Zero selector should reset to default");
        assertTrue(isViewFunction, "Reset path should restore view mode");
    }

    /*//////////////////////////////////////////////////////////////
                    TRANSFER WITH VALIDATOR
    //////////////////////////////////////////////////////////////*/

    function testTransferWithoutValidator() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        dustLock.transferFrom(user, user2, tokenId);

        assertEq(dustLock.ownerOf(tokenId), user2, "Transfer should succeed");
    }

    function testTransferWithValidatorEnabled() public {
        address marketOperator = makeAddr("marketOperator");

        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        dustLock.setTransferValidator(address(validator));
        dustLock.setFeeEnforcedOperator(marketOperator, true);
        dustLock.approve(marketOperator, tokenId);

        vm.prank(marketOperator);
        dustLock.transferFrom(user, user2, tokenId);

        assertEq(dustLock.ownerOf(tokenId), user2, "Transfer should succeed with validator");
    }

    function testTransferRevertsWhenValidatorReverts() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        dustLock.setTransferValidator(address(validator));
        validator.setShouldRevert(true);

        dustLock.approve(user2, tokenId);
        dustLock.setFeeEnforcedOperator(user2, true);

        vm.expectRevert("MockValidator: Transfer not authorized");
        vm.prank(user2);
        dustLock.transferFrom(user, user3, tokenId);

        assertEq(dustLock.ownerOf(tokenId), user, "Transfer should fail, owner unchanged");
    }

    function testSafeTransferWithValidator() public {
        address marketOperator = makeAddr("marketOperator");

        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        dustLock.setTransferValidator(address(validatorNonView));
        dustLock.setTransferValidationFunction(validatorNonView.validateTransfer.selector, false);
        dustLock.setFeeEnforcedOperator(marketOperator, true);
        dustLock.approve(marketOperator, tokenId);

        vm.prank(marketOperator);
        dustLock.safeTransferFrom(user, user2, tokenId);

        assertEq(dustLock.ownerOf(tokenId), user2, "Safe transfer should succeed with validator");
        assertEq(validatorNonView.callCount(), 1, "Validator should be called");
    }

    function testSafeTransferWithDataWithValidator() public {
        address marketOperator = makeAddr("marketOperator");

        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        dustLock.setTransferValidator(address(validatorNonView));
        dustLock.setTransferValidationFunction(validatorNonView.validateTransfer.selector, false);
        dustLock.setFeeEnforcedOperator(marketOperator, true);
        dustLock.approve(marketOperator, tokenId);

        vm.prank(marketOperator);
        dustLock.safeTransferFrom(user, user2, tokenId, "");

        assertEq(dustLock.ownerOf(tokenId), user2, "Safe transfer with data should succeed");
        assertEq(validatorNonView.callCount(), 1, "Validator should be called");
    }

    function testTransferWithNonViewValidator() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        dustLock.setTransferValidator(address(validatorNonView));
        dustLock.setTransferValidationFunction(validatorNonView.validateTransfer.selector, false);

        dustLock.approve(user2, tokenId);
        dustLock.setFeeEnforcedOperator(user2, true);

        vm.prank(user2);
        dustLock.transferFrom(user, user2, tokenId);

        assertEq(validatorNonView.callCount(), 1, "Non-view validator should be called");
        assertEq(dustLock.ownerOf(tokenId), user2, "Transfer should succeed with non-view validator");
    }

    function testApprovedTransferWithValidator() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        dustLock.approve(user2, tokenId);
        dustLock.setTransferValidator(address(validatorRecording));
        dustLock.setFeeEnforcedOperator(user2, true);

        vm.prank(user2);
        dustLock.transferFrom(user, user3, tokenId);

        assertEq(dustLock.ownerOf(tokenId), user3, "Approved transfer should succeed with validator");
    }

    function testTransferSkipsValidatorWhenOperatorNotEnforced() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        dustLock.setTransferValidator(address(validator));
        validator.setShouldRevert(true);

        // Operator not enforced => validator not called
        dustLock.transferFrom(user, user2, tokenId);

        assertEq(dustLock.ownerOf(tokenId), user2, "Transfer should bypass validator");
    }

    function testTransferEnforcesForOperator() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        dustLock.setTransferValidator(address(validator));
        validator.setShouldRevert(true);

        dustLock.approve(user2, tokenId);
        dustLock.setFeeEnforcedOperator(user2, true);

        vm.expectRevert("MockValidator: Transfer not authorized");
        vm.prank(user2);
        dustLock.transferFrom(user, user3, tokenId);
    }

    function testFeeEnforcedOperatorList() public {
        assertEq(dustLock.feeEnforcedOperatorCount(), 0);

        vm.expectEmit(false, false, false, true);
        emit FeeEnforcedOperatorUpdated(user2, true);
        dustLock.setFeeEnforcedOperator(user2, true);

        vm.expectEmit(false, false, false, true);
        emit FeeEnforcedOperatorUpdated(user3, true);
        dustLock.setFeeEnforcedOperator(user3, true);

        assertTrue(dustLock.isFeeEnforcedOperator(user2));
        assertTrue(dustLock.isFeeEnforcedOperator(user3));
        assertEq(dustLock.feeEnforcedOperatorCount(), 2);
        assertEq(dustLock.feeEnforcedOperatorAt(0), user2);
        assertEq(dustLock.feeEnforcedOperatorAt(1), user3);

        vm.expectEmit(false, false, false, true);
        emit FeeEnforcedOperatorUpdated(user2, false);
        dustLock.setFeeEnforcedOperator(user2, false);

        assertFalse(dustLock.isFeeEnforcedOperator(user2));
        assertEq(dustLock.feeEnforcedOperatorCount(), 1);
        assertEq(dustLock.feeEnforcedOperatorAt(0), user3);
    }

    function testFeeEnforcedOperatorAtOutOfBoundsReverts() public {
        vm.expectRevert();
        dustLock.feeEnforcedOperatorAt(0);
    }

    function testSetFeeEnforcedOperatorIdempotentAdd() public {
        dustLock.setFeeEnforcedOperator(user2, true);

        vm.recordLogs();
        dustLock.setFeeEnforcedOperator(user2, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0, "Second add should emit no events");
        assertEq(dustLock.feeEnforcedOperatorCount(), 1, "Operator should not be duplicated");
        assertEq(dustLock.feeEnforcedOperatorAt(0), user2, "Operator should remain at index 0");
    }

    function testFeeEnforcedOperatorSwapAndPopWithThreeOperators() public {
        address user4 = makeAddr("user4");

        dustLock.setFeeEnforcedOperator(user2, true);
        dustLock.setFeeEnforcedOperator(user3, true);
        dustLock.setFeeEnforcedOperator(user4, true);

        dustLock.setFeeEnforcedOperator(user3, false);

        assertFalse(dustLock.isFeeEnforcedOperator(user3), "Removed operator should be disabled");
        assertEq(dustLock.feeEnforcedOperatorCount(), 2, "Count should decrease");
        assertEq(dustLock.feeEnforcedOperatorAt(0), user2, "First operator should stay in place");
        assertEq(dustLock.feeEnforcedOperatorAt(1), user4, "Last operator should be swapped into removed slot");
    }

    function testSetFeeEnforcedOperatorOnlyTeam() public {
        vm.startPrank(admin);
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.setFeeEnforcedOperator(user2, true);
        vm.stopPrank();

        vm.startPrank(user2);
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.setFeeEnforcedOperator(user2, true);
        vm.stopPrank();
    }

    function testSetFeeEnforcedOperatorZeroAddressReverts() public {
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        dustLock.setFeeEnforcedOperator(address(0), true);
    }

    function testSetApprovalForAllTransferWithFeeEnforcedOperator() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        dustLock.setTransferValidator(address(validator));
        validator.setShouldRevert(true);
        dustLock.setFeeEnforcedOperator(user2, true);
        dustLock.setApprovalForAll(user2, true);

        vm.expectRevert("MockValidator: Transfer not authorized");
        vm.prank(user2);
        dustLock.transferFrom(user, user3, tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                INTERNAL OPERATIONS BYPASS VALIDATOR
    //////////////////////////////////////////////////////////////*/

    function testMergeBypassesValidator() public {
        DUST.approve(address(dustLock), TOKEN_100K);
        uint256 tokenId1 = dustLock.createLock(TOKEN_1, MAXTIME);
        uint256 tokenId2 = dustLock.createLock(TOKEN_1, MAXTIME);

        dustLock.setTransferValidator(address(validatorRecording));

        // Merge should succeed even with validator set
        dustLock.merge(tokenId1, tokenId2);

        vm.expectRevert();
        dustLock.ownerOf(tokenId1);
        assertEq(dustLock.ownerOf(tokenId2), user, "Merge succeeds with validator");
    }

    function testSplitBypassesValidator() public {
        DUST.approve(address(dustLock), TOKEN_100K);
        uint256 tokenId = dustLock.createLock(TOKEN_1 * 10, MAXTIME);

        // Enable split for user
        dustLock.toggleSplit(user, true);

        dustLock.setTransferValidator(address(validatorRecording));

        // Split should succeed even with validator set
        (uint256 newTokenId1, uint256 newTokenId2) = dustLock.split(tokenId, TOKEN_1 * 4);

        vm.expectRevert();
        dustLock.ownerOf(tokenId);
        assertEq(dustLock.ownerOf(newTokenId1), user, "Split succeeds with validator");
        assertEq(dustLock.ownerOf(newTokenId2), user, "Split succeeds with validator");
    }

    function testCreateLockBypassesValidator() public {
        dustLock.setTransferValidator(address(validatorRecording));

        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        assertEq(dustLock.ownerOf(tokenId), user, "Create lock succeeds with validator");
    }

    function testWithdrawBypassesValidator() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, 8 weeks);

        dustLock.setTransferValidator(address(validatorRecording));

        skipAndRoll(9 weeks);
        dustLock.withdraw(tokenId);

        vm.expectRevert();
        dustLock.ownerOf(tokenId);
    }

    function testEarlyWithdrawBypassesValidator() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        skipAndRoll(28 days);

        dustLock.setTransferValidator(address(validatorRecording));

        dustLock.earlyWithdraw(tokenId);

        vm.expectRevert();
        dustLock.ownerOf(tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                        ERC165 INTERFACE SUPPORT
    //////////////////////////////////////////////////////////////*/

    function testSupportsERC2981Interface() public view {
        assertTrue(dustLock.supportsInterface(0x2a55205a), "Should support ERC2981");
    }

    function testSupportsICreatorTokenInterface() public view {
        assertTrue(dustLock.supportsInterface(type(ICreatorToken).interfaceId), "Should support ICreatorToken");
    }

    function testSupportsExistingInterfaces() public view {
        assertTrue(dustLock.supportsInterface(0x01ffc9a7), "ERC165");
        assertTrue(dustLock.supportsInterface(0x80ac58cd), "ERC721");
        assertTrue(dustLock.supportsInterface(0x5b5e139f), "ERC721Metadata");
        assertTrue(dustLock.supportsInterface(0x49064906), "ERC4906");
    }

    /*//////////////////////////////////////////////////////////////
                        INTEGRATION SCENARIOS
    //////////////////////////////////////////////////////////////*/

    function testCompleteWorkflow() public {
        address marketOperator = makeAddr("marketOperator");

        // 1. Configure royalties
        dustLock.setRoyaltyInfo(protocolTreasury, FEE_250_BPS);

        // 2. Create lock
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        // 3. Check royalty info
        (address receiver, uint256 royalty) = dustLock.royaltyInfo(tokenId, 100 ether);
        assertEq(receiver, protocolTreasury);
        assertEq(royalty, 2.5 ether);

        // 4. Enable validator
        dustLock.setTransferValidator(address(validator));
        dustLock.setFeeEnforcedOperator(marketOperator, true);
        dustLock.approve(marketOperator, tokenId);

        // 5. Marketplace-style transfer succeeds with validator
        vm.prank(marketOperator);
        dustLock.transferFrom(user, user2, tokenId);
        assertEq(dustLock.ownerOf(tokenId), user2);

        // 6. Merge operation succeeds with validator
        mintErc20Token(address(DUST), user2, TOKEN_1);
        vm.startPrank(user2);
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId2 = dustLock.createLock(TOKEN_1, MAXTIME);
        dustLock.merge(tokenId, tokenId2);
        vm.stopPrank();

        assertEq(dustLock.ownerOf(tokenId2), user2, "Merged token exists");
    }

    function testDisableAndReEnableValidator() public {
        address marketOperator = makeAddr("marketOperator");

        DUST.approve(address(dustLock), TOKEN_1 * 3);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        // Enable validator and enforce fees for marketplace operator
        dustLock.setTransferValidator(address(validator));
        dustLock.setFeeEnforcedOperator(marketOperator, true);
        dustLock.approve(marketOperator, tokenId);
        vm.prank(marketOperator);
        dustLock.transferFrom(user, user2, tokenId);

        // Disable validator; even a rejecting validator should no longer affect transfers
        validator.setShouldRevert(true);
        dustLock.setTransferValidator(address(0));

        vm.prank(user2);
        dustLock.approve(marketOperator, tokenId);
        vm.prank(marketOperator);
        dustLock.transferFrom(user2, user3, tokenId);

        // Re-enable validator
        validator.setShouldRevert(false);
        dustLock.setTransferValidator(address(validator));

        vm.prank(user3);
        dustLock.approve(marketOperator, tokenId);
        vm.prank(marketOperator);
        dustLock.transferFrom(user3, user, tokenId);

        assertEq(dustLock.ownerOf(tokenId), user, "All transfers succeed");
    }

    function testMultipleTransfersWithValidator() public {
        address marketOperator = makeAddr("marketOperator");

        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        dustLock.setTransferValidator(address(validatorNonView));
        dustLock.setTransferValidationFunction(validatorNonView.validateTransfer.selector, false);
        dustLock.setFeeEnforcedOperator(marketOperator, true);
        dustLock.approve(marketOperator, tokenId);
        vm.prank(marketOperator);
        dustLock.transferFrom(user, user2, tokenId);

        vm.prank(user2);
        dustLock.approve(marketOperator, tokenId);
        vm.prank(marketOperator);
        dustLock.transferFrom(user2, user3, tokenId);

        vm.prank(user3);
        dustLock.approve(marketOperator, tokenId);
        vm.prank(marketOperator);
        dustLock.transferFrom(user3, user, tokenId);

        assertEq(dustLock.ownerOf(tokenId), user, "Multiple transfers succeed with validator");
        assertEq(validatorNonView.callCount(), 3, "Validator should be called for each operator transfer");
    }

    /*//////////////////////////////////////////////////////////////
            ERC2771 META-TX ROYALTY ENFORCEMENT (REGRESSION)
    //////////////////////////////////////////////////////////////*/

    /// @dev Helper: call DustLock.transferFrom via the trusted forwarder,
    ///      appending `signer` as the ERC2771 suffix so _msgSender() == signer.
    function _relayTransferFrom(address signer, address from, address to, uint256 _tokenId) internal {
        bytes memory payload = abi.encodeWithSelector(IDustLock.transferFrom.selector, from, to, _tokenId);
        // ERC2771: append the original signer address (20 bytes) to calldata
        bytes memory fullData = abi.encodePacked(payload, signer);
        vm.prank(FORWARDER);
        (bool success, bytes memory returnData) = address(dustLock).call(fullData);
        if (!success) {
            // Bubble up the revert
            assembly {
                revert(add(32, returnData), mload(returnData))
            }
        }
    }

    function testERC2771MetaTxBlockedWhenValidatorActive() public {
        // Forwarder-relayed transfers are explicitly blocked when a validator is active
        // because the forwarder obscures the original operator identity.
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 _tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        dustLock.setTransferValidator(address(validator));

        vm.expectRevert(IDustLock.ForwarderTransferNotAllowed.selector);
        _relayTransferFrom(user, user, user2, _tokenId);

        assertEq(dustLock.ownerOf(_tokenId), user, "Token should not have been transferred");
    }

    function testERC2771MetaTxBlockedEvenWhenValidatorWouldAllow() public {
        // Even with a permissive validator, forwarder transfers are blocked
        // to prevent marketplace fee bypass via meta-transactions.
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 _tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        dustLock.setTransferValidator(address(validatorRecording));

        vm.expectRevert(IDustLock.ForwarderTransferNotAllowed.selector);
        _relayTransferFrom(user, user, user2, _tokenId);

        assertEq(dustLock.ownerOf(_tokenId), user, "Token should not have been transferred");
    }

    function testERC2771MetaTxSucceedsWhenNoValidatorSet() public {
        // Without a validator, forwarder-relayed transfers work normally.
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 _tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        // No validator set — forwarder transfers should succeed
        _relayTransferFrom(user, user, user2, _tokenId);

        assertEq(dustLock.ownerOf(_tokenId), user2, "Transfer should succeed without validator");
    }

    function testDirectCallByNonEnforcedOperatorStillBypasses() public {
        // Confirm that direct (non-forwarder) calls from non-enforced operators
        // still skip the validator, preserving existing behavior.
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 _tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        dustLock.setTransferValidator(address(validator));
        validator.setShouldRevert(true);

        // user is not a fee-enforced operator; direct call should bypass validator
        dustLock.transferFrom(user, user2, _tokenId);

        assertEq(dustLock.ownerOf(_tokenId), user2, "Direct non-enforced transfer should still bypass validator");
    }

    function testValidatorReceivesDirectOperatorAsCaller() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 _tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        dustLock.setTransferValidator(address(validatorCapture));
        dustLock.setTransferValidationFunction(validatorCapture.validateTransfer.selector, false);
        dustLock.setFeeEnforcedOperator(user2, true);
        dustLock.approve(user2, _tokenId);

        vm.prank(user2);
        dustLock.transferFrom(user, user3, _tokenId);

        assertEq(validatorCapture.lastCaller(), user2, "Validator caller should be operator");
        assertEq(validatorCapture.lastFrom(), user, "Validator from should match owner");
        assertEq(validatorCapture.lastTo(), user3, "Validator to should match recipient");
        assertEq(validatorCapture.lastTokenId(), _tokenId, "Validator tokenId should match");
    }

    function testForwarderRelayedTransferBlockedWithValidatorCapture() public {
        // Even with a capture validator, forwarder transfers are blocked before reaching the validator.
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 _tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        dustLock.setTransferValidator(address(validatorCapture));
        dustLock.setTransferValidationFunction(validatorCapture.validateTransfer.selector, false);

        vm.expectRevert(IDustLock.ForwarderTransferNotAllowed.selector);
        _relayTransferFrom(user, user, user2, _tokenId);

        // Validator should not have been called
        assertEq(validatorCapture.lastCaller(), address(0), "Validator should not be reached");
    }

    function testIsTrustedForwarderUsesConfiguredStorageAddress() public view {
        DustLock lock = DustLock(address(dustLock));
        assertTrue(lock.isTrustedForwarder(FORWARDER), "Configured forwarder should be trusted");
        assertFalse(lock.isTrustedForwarder(user2), "Arbitrary address should not be trusted");
    }
}
