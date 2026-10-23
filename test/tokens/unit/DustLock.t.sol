// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";

import {ICreatorToken} from "../../../src/interfaces/ICreatorToken.sol";
import {IDustLock} from "../../../src/interfaces/IDustLock.sol";
import {IRevenueReward} from "../../../src/interfaces/IRevenueReward.sol";
import {Vm} from "forge-std/Vm.sol";

import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";

import {RevenueReward} from "../../../src/rewards/RevenueReward.sol";
import {DustLock} from "../../../src/tokens/DustLock.sol";
import {BaseTestLocal} from "../../BaseTestLocal.sol";

contract MaliciousRevenueReward is RevenueReward {
    constructor(address forwarder) RevenueReward(forwarder) {}

    function notifyAfterTokenTransferred(uint256 tokenId, address from) public override onlyDustLock {
        dustLock.transferFrom(from, address(this), tokenId);
    }

    function notifyAfterTokenBurned(
        uint256 tokenId,
        address /* from */
    )
        public
        override
        onlyDustLock
    {
        dustLock.earlyWithdraw(tokenId);
    }
}

contract BadReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x0;
    }
}

contract EmptyDustLockReceiver {}

contract RevertNoDataValidator {
    fallback() external {
        assembly {
            revert(0, 0)
        }
    }
}

contract DustLockTests is BaseTestLocal {
    // Local event declaration for expectEmit matching (ERC-4906)
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    struct PermanentLockEventScan {
        uint256 iTransfer;
        uint256 iDeposit;
        uint256 iLockPerm;
        uint256 iMetadata;
        uint256 cTransfer;
        uint256 cDeposit;
        uint256 cLockPerm;
        uint256 cMetadata;
    }

    function _setUp() internal override {
        // Initial time => 1 sec after the start of week1
        assertEq(block.timestamp, 1 weeks + 1);
        mintErc20Token(address(DUST), user, TOKEN_100K);
    }

    /* ========== NFT ========== */

    function testTransferOfNft() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);
        emit log_named_uint("[dustLock] created tokenId", tokenId);
        skipAndRoll(1);

        dustLock.transferFrom(address(user), address(user2), tokenId);
        emit log("[dustLock] transferFrom user -> user2");

        assertEq(dustLock.balanceOf(address(user)), 0);
        assertEq(dustLock.ownerOf(tokenId), address(user2));
        assertEq(dustLock.balanceOf(address(user2)), 1);

        // flash protection
        assertEq(dustLock.balanceOfNFT(1), 0);
    }

    function testMergeFromSameBlockTransferPropagatesFlashProtection() public {
        mintErc20Token(address(DUST), user2, TOKEN_10K);

        vm.startPrank(user2);
        DUST.approve(address(dustLock), TOKEN_10K);
        uint256 fromToken = dustLock.createLock(TOKEN_1K, MAXTIME);
        uint256 toToken = dustLock.createLock(TOKEN_1K, MAXTIME);
        vm.stopPrank();

        skipAndRoll(1);

        vm.prank(user2);
        dustLock.transferFrom(user2, user4, toToken);

        skipAndRoll(1);

        vm.prank(user2);
        dustLock.transferFrom(user2, user4, fromToken);
        assertEq(dustLock.balanceOfNFT(fromToken), 0);

        vm.prank(user4);
        dustLock.merge(fromToken, toToken);

        assertEq(dustLock.ownerOf(toToken), user4);
        // Same-block flash protection propagates from the just-transferred source to the merge target.
        assertEq(dustLock.balanceOfNFT(toToken), 0);

        skipAndRoll(1);
        // Protection clears the following block; the merged balance becomes readable.
        assertGt(dustLock.balanceOfNFT(toToken), 0);
    }

    function testSplitFromSameBlockTransferPropagatesFlashProtection() public {
        mintErc20Token(address(DUST), user2, TOKEN_10K);

        vm.startPrank(user2);
        DUST.approve(address(dustLock), TOKEN_10K);
        uint256 tokenId = dustLock.createLock(20 * TOKEN_1, MAXTIME);
        vm.stopPrank();

        dustLock.toggleSplit(user4, true);
        skipAndRoll(1);

        vm.prank(user2);
        dustLock.transferFrom(user2, user4, tokenId);
        assertEq(dustLock.balanceOfNFT(tokenId), 0);

        vm.prank(user4);
        (uint256 tokenId1, uint256 tokenId2) = dustLock.split(tokenId, 10 * TOKEN_1);

        assertEq(dustLock.ownerOf(tokenId1), user4);
        assertEq(dustLock.ownerOf(tokenId2), user4);
        // Same-block flash protection propagates from the just-transferred parent to both split children.
        assertEq(dustLock.balanceOfNFT(tokenId1), 0);
        assertEq(dustLock.balanceOfNFT(tokenId2), 0);

        skipAndRoll(1);
        // Protection clears the following block; both children's balances become readable.
        assertGt(dustLock.balanceOfNFT(tokenId1), 0);
        assertGt(dustLock.balanceOfNFT(tokenId2), 0);
    }

    function testMergeAndSplitWithoutSameBlockTransferDoNotFlagFlashProtection() public {
        mintErc20Token(address(DUST), user2, TOKEN_10K);

        vm.startPrank(user2);
        DUST.approve(address(dustLock), TOKEN_10K);
        uint256 fromToken = dustLock.createLock(TOKEN_1K, MAXTIME);
        uint256 toToken = dustLock.createLock(TOKEN_1K, MAXTIME);
        uint256 splitToken = dustLock.createLock(20 * TOKEN_1, MAXTIME);
        vm.stopPrank();

        dustLock.toggleSplit(user4, true);
        skipAndRoll(1);

        vm.startPrank(user2);
        dustLock.transferFrom(user2, user4, fromToken);
        dustLock.transferFrom(user2, user4, toToken);
        dustLock.transferFrom(user2, user4, splitToken);
        vm.stopPrank();

        skipAndRoll(1);

        // Transfers happened in an earlier block, so flash protection must NOT propagate.
        vm.startPrank(user4);
        dustLock.merge(fromToken, toToken);
        (uint256 tokenId1, uint256 tokenId2) = dustLock.split(splitToken, 10 * TOKEN_1);
        vm.stopPrank();

        assertGt(dustLock.balanceOfNFT(toToken), 0);
        assertGt(dustLock.balanceOfNFT(tokenId1), 0);
        assertGt(dustLock.balanceOfNFT(tokenId2), 0);
    }

    function testTransferToAddressZeroReverts() public {
        // arrange
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        // act / assert
        emit log("[dustLock] Expect revert: transfer to zero address");
        vm.expectRevert(abi.encodeWithSelector(CommonChecksLibrary.AddressZero.selector));
        dustLock.transferFrom(user, address(0), tokenId);
    }

    function testTokenUri() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);
        emit log_named_uint("[dustLock] created tokenId", tokenId);

        assertEq(dustLock.tokenURI(tokenId), "https://neverland.money/nfts/1");
    }

    function testBaseUriOnlySetByTeam() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        string memory newBaseURI = "https://google.com/search?q=";

        vm.startPrank(admin);
        emit log("[dustLock] Expect revert: setBaseURI by non-team");
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.setBaseURI(newBaseURI);
        vm.stopPrank();

        dustLock.setBaseURI(newBaseURI);
        emit log_string("[dustLock] baseURI updated");

        assertEq(dustLock.tokenURI(tokenId), "https://google.com/search?q=1");
    }

    /* ========== PERMANENT LOCK BALANCE ========== */

    /// invariant checks
    /// bound timestamp between 1600000000 and 100 years from then
    /// current optimism timestamp >= 1600000000
    function testBalanceOfNFTWithPermanentLocks(uint256 timestamp) public {
        vm.warp(1600000000);
        timestamp = bound(timestamp, 1600000000, 1600000000 + (52 weeks) * 100);

        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);
        dustLock.lockPermanent(tokenId);
        emit log_named_uint("[dustLock] locked permanent tokenId", tokenId);
        vm.warp(timestamp);

        assertEq(dustLock.balanceOfNFT(tokenId), TOKEN_1);
    }

    function testBalanceOfNFTAtWithPermanentLocks(uint256 timestamp) public {
        vm.warp(1600000000);
        timestamp = bound(timestamp, 1600000000, 1600000000 + (52 weeks) * 100);

        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);
        dustLock.lockPermanent(tokenId);
        emit log_named_uint("[dustLock] locked permanent tokenId", tokenId);
        vm.warp(timestamp);

        assertEq(dustLock.balanceOfNFTAt(tokenId, timestamp), TOKEN_1);
    }

    /* ========== PERMANENT/UNLOCK/WITHDRAW EDGE CASES ========== */

    function testWithdrawOnPermanentReverts() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 id = dustLock.createLock(TOKEN_1, MAXTIME);
        dustLock.lockPermanent(id);
        vm.expectRevert(IDustLock.PermanentLock.selector);
        dustLock.withdraw(id);
    }

    function testIncreaseUnlockTimeOnPermanentReverts() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 id = dustLock.createLock(TOKEN_1, MAXTIME);
        dustLock.lockPermanent(id);
        vm.expectRevert(IDustLock.PermanentLock.selector);
        dustLock.increaseUnlockTime(id, 1 weeks);
    }

    function testUnlockPermanentRevertsOnNonPermanent() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 id = dustLock.createLock(TOKEN_1, MAXTIME);
        vm.expectRevert(IDustLock.NotPermanentLock.selector);
        dustLock.unlockPermanent(id);
    }

    function testUnlockPermanentByApprovedOperator() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 id = dustLock.createLock(TOKEN_1, MAXTIME);
        dustLock.lockPermanent(id);

        // Unapproved cannot unlock
        vm.startPrank(user2);
        vm.expectRevert(IDustLock.NotApprovedOrOwner.selector);
        dustLock.unlockPermanent(id);
        vm.stopPrank();

        // Approve and unlock as operator
        dustLock.approve(user2, id);
        vm.prank(user2);
        dustLock.unlockPermanent(id);
        assertFalse(dustLock.locked(id).isPermanent);
    }

    function testDepositForIntoPermanentByThirdParty() public {
        // lock permanent
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 id = dustLock.createLock(TOKEN_1, MAXTIME);
        dustLock.lockPermanent(id);
        uint256 plbBefore = dustLock.permanentLockBalance();

        // third party deposits
        mintErc20Token(address(DUST), user2, TOKEN_1);
        vm.startPrank(user2);
        DUST.approve(address(dustLock), TOKEN_1);
        dustLock.depositFor(id, TOKEN_1);
        vm.stopPrank();

        IDustLock.LockedBalance memory lb1 = dustLock.locked(id);
        assertTrue(lb1.isPermanent);
        assertEq(lb1.end, 0);
        assertEq(uint256(lb1.amount), 2 * TOKEN_1);
        assertEq(dustLock.permanentLockBalance(), plbBefore + TOKEN_1);
    }

    function testMutatingLockCatchesUpWithinLiveCheckpointWindow() public {
        DUST.approve(address(dustLock), TOKEN_10K);
        uint256 id = dustLock.createLockPermanent(TOKEN_1K, MAXTIME);

        skipAndRoll(129 weeks + 1);

        dustLock.increaseAmount(id, TOKEN_1);

        assertEq(uint256(dustLock.locked(id).amount), TOKEN_1K + TOKEN_1);
        assertEq(dustLock.pointHistory(dustLock.epoch()).ts, block.timestamp);
    }

    function testPublicCheckpointCatchesUpLongInactivityInBatches() public {
        DUST.approve(address(dustLock), TOKEN_10K);
        dustLock.createLockPermanent(TOKEN_1K, MAXTIME);

        skipAndRoll(300 weeks);

        uint256 calls;
        while (dustLock.pointHistory(dustLock.epoch()).ts < block.timestamp) {
            assertLt(calls, 3, "checkpoint catch-up should finish in two live batches");
            dustLock.checkpoint();
            ++calls;
        }

        assertEq(calls, 2);
        assertEq(dustLock.pointHistory(dustLock.epoch()).ts, block.timestamp);
    }

    /* ========== MERGE EDGE CASES ========== */

    function testMergeIntoPermanentKeepsPermanent() public {
        // destination permanent
        DUST.approve(address(dustLock), 3 * TOKEN_1);
        uint256 toId = dustLock.createLock(TOKEN_1, MAXTIME);
        dustLock.lockPermanent(toId);
        uint256 fromId = dustLock.createLock(2 * TOKEN_1, MAXTIME);
        uint256 plbBefore = dustLock.permanentLockBalance();

        dustLock.merge(fromId, toId);

        IDustLock.LockedBalance memory lb2 = dustLock.locked(toId);
        assertTrue(lb2.isPermanent);
        assertEq(lb2.end, 0);
        assertEq(uint256(lb2.amount), 3 * TOKEN_1);
        assertEq(dustLock.permanentLockBalance(), plbBefore + 2 * TOKEN_1);
    }

    function testMergePermanentSourceReverts() public {
        DUST.approve(address(dustLock), 3 * TOKEN_1);
        uint256 fromId = dustLock.createLock(TOKEN_1, MAXTIME);
        uint256 toId = dustLock.createLock(2 * TOKEN_1, MAXTIME);
        dustLock.lockPermanent(fromId);
        vm.expectRevert(IDustLock.PermanentLock.selector);
        dustLock.merge(fromId, toId);
    }

    function testMergePermanentToPermanentCombines() public {
        DUST.approve(address(dustLock), 3 * TOKEN_1);
        uint256 fromId = dustLock.createLock(TOKEN_1, MAXTIME);
        uint256 toId = dustLock.createLock(2 * TOKEN_1, MAXTIME);
        dustLock.lockPermanent(fromId);
        dustLock.lockPermanent(toId);
        uint256 plbBefore = dustLock.permanentLockBalance();

        dustLock.merge(fromId, toId);

        IDustLock.LockedBalance memory lb = dustLock.locked(toId);
        assertTrue(lb.isPermanent);
        assertEq(lb.end, 0);
        assertEq(uint256(lb.amount), 3 * TOKEN_1);
        // PLB should not change when both source and dest were already permanent
        assertEq(dustLock.permanentLockBalance(), plbBefore);
    }

    /* ========== ERC721 HYGIENE ========== */

    function testSupportsInterfaceMatrix() public view {
        // ERC165
        assertTrue(dustLock.supportsInterface(0x01ffc9a7));
        // ERC721
        assertTrue(dustLock.supportsInterface(0x80ac58cd));
        // ERC4906
        assertTrue(dustLock.supportsInterface(0x49064906));
        // ERC6372
        assertTrue(dustLock.supportsInterface(0xda287a1d));
        // ERC721Metadata
        assertTrue(dustLock.supportsInterface(0x5b5e139f));
        // IDustLock
        assertTrue(dustLock.supportsInterface(type(IDustLock).interfaceId));
        // Deployed 2.0.0 IDustLock id remains supported explicitly by candidate logic.
        assertTrue(dustLock.supportsInterface(0x03448477));
        // EIP-2981 (royalty info) — required for marketplace fee enforcement; pin so the
        // supportsInterface allow-list cannot silently drop the ERC721-C / royalty branch.
        assertTrue(dustLock.supportsInterface(type(IERC2981).interfaceId));
        // ICreatorToken (Limit Break ERC721-C) — required for transfer-validator integration.
        assertTrue(dustLock.supportsInterface(type(ICreatorToken).interfaceId));
        // Historical IDustLock id before ERC721-C/EIP-2981 and removed-view surface changes.
        assertFalse(dustLock.supportsInterface(0x4c678d9c));
        // IDustLock id from the removed earlyWithdrawPenaltyAmount(uint256) public view
        assertFalse(dustLock.supportsInterface(0xda49082b));
        // Negative case
        assertFalse(dustLock.supportsInterface(0xffffffff));
    }

    function testApprovalsClearedOnTransfer() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 id = dustLock.createLock(TOKEN_1, MAXTIME);
        dustLock.approve(user2, id);
        dustLock.transferFrom(user, user3, id);
        assertEq(dustLock.getApproved(id), address(0));
        vm.startPrank(user2);
        vm.expectRevert(IDustLock.NotApprovedOrOwner.selector);
        dustLock.transferFrom(user3, user, id);
        vm.stopPrank();
    }

    function testSetApprovalForAllOperatorCanTransfer() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 id = dustLock.createLock(TOKEN_1, MAXTIME);
        dustLock.setApprovalForAll(user2, true);
        vm.prank(user2);
        dustLock.transferFrom(user, user3, id);
        assertEq(dustLock.ownerOf(id), user3);
    }

    function testApprovedOperatorCanMutateLockLifecycle() public {
        dustLock.toggleSplit(user, true);
        DUST.approve(address(dustLock), 20 * TOKEN_1);

        uint256 extendId = dustLock.createLock(TOKEN_1, 26 weeks);
        uint256 oldEnd = dustLock.locked(extendId).end;
        dustLock.approve(user2, extendId);
        vm.prank(user2);
        dustLock.increaseUnlockTime(extendId, MAXTIME);
        assertGt(dustLock.locked(extendId).end, oldEnd);

        uint256 earlyWithdrawId = dustLock.createLock(TOKEN_1, MAXTIME);
        dustLock.approve(user2, earlyWithdrawId);
        vm.prank(user2);
        dustLock.earlyWithdraw(earlyWithdrawId);
        assertEq(dustLock.locked(earlyWithdrawId).amount, 0);

        uint256 permanentId = dustLock.createLock(TOKEN_1, MAXTIME);
        dustLock.approve(user2, permanentId);
        vm.prank(user2);
        dustLock.lockPermanent(permanentId);
        assertTrue(dustLock.locked(permanentId).isPermanent);

        vm.prank(user2);
        dustLock.unlockPermanent(permanentId);
        assertFalse(dustLock.locked(permanentId).isPermanent);

        uint256 splitId = dustLock.createLock(2 * TOKEN_1, MAXTIME);
        dustLock.approve(user2, splitId);
        vm.prank(user2);
        (uint256 splitId1, uint256 splitId2) = dustLock.split(splitId, TOKEN_1);
        assertEq(dustLock.ownerOf(splitId1), user);
        assertEq(dustLock.ownerOf(splitId2), user);

        uint256 mergeSource = dustLock.createLock(TOKEN_1, MAXTIME);
        uint256 mergeDestination = dustLock.createLock(TOKEN_1, MAXTIME);
        dustLock.approve(user2, mergeSource);
        dustLock.approve(user2, mergeDestination);
        vm.prank(user2);
        dustLock.merge(mergeSource, mergeDestination);
        assertEq(uint256(dustLock.locked(mergeDestination).amount), 2 * TOKEN_1);
    }

    function testMergeAllowsApprovedCrossOwnerDestination() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 sourceId = dustLock.createLock(TOKEN_1, MAXTIME);

        mintErc20Token(address(DUST), user2, TOKEN_1);
        vm.startPrank(user2);
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 destinationId = dustLock.createLock(TOKEN_1, MAXTIME);
        dustLock.approve(user, destinationId);
        vm.stopPrank();

        dustLock.merge(sourceId, destinationId);

        assertEq(dustLock.ownerOf(destinationId), user2);
        assertEq(uint256(dustLock.locked(sourceId).amount), 0);
        assertEq(uint256(dustLock.locked(destinationId).amount), 2 * TOKEN_1);
    }

    function testSafeTransferToBadReceiverReverts() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 id = dustLock.createLock(TOKEN_1, MAXTIME);
        BadReceiver bad = new BadReceiver();
        vm.expectRevert(IDustLock.ERC721ReceiverRejectedTokens.selector);
        dustLock.safeTransferFrom(user, address(bad), id);
    }

    function testTokenURINonExistentReverts() public {
        vm.expectRevert(CommonChecksLibrary.InvalidTokenId.selector);
        dustLock.tokenURI(999999);
    }

    function testSetBaseURI_NoTokens_NoBatchMetadata() public {
        // tokenId == 0 on fresh deployment
        bytes32 batchSig = keccak256("BatchMetadataUpdate(uint256,uint256)");
        vm.recordLogs();
        dustLock.setBaseURI("https://example.com/");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            // first topic is the keccak of the event signature
            assertTrue(entries[i].topics.length == 0 || entries[i].topics[0] != batchSig);
        }
    }

    function testSetBaseURI_WithTokens_EmitsBatchMetadata() public {
        // Mint one token so tokenId > 0
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId_ = dustLock.createLock(TOKEN_1, MAXTIME);
        assertEq(tokenId_, 1);

        // Expect 4906 batch metadata update on baseURI change
        vm.expectEmit(false, false, false, true);
        emit BatchMetadataUpdate(1, dustLock.tokenId());
        dustLock.setBaseURI("https://another.example/");
    }

    /* ========== SPLIT PERMISSION GLOBAL VS PER-USER ========== */

    function testSplitPermissionGlobalEnablesEvenIfPerUserFalse() public {
        // Create a valid, non-permanent, unexpired lock
        DUST.approve(address(dustLock), 2 * TOKEN_1);
        uint256 id = dustLock.createLock(2 * TOKEN_1, MAXTIME);
        // Ensure per-user is false by default; enable global
        dustLock.toggleSplit(address(0), true);
        // Should succeed
        dustLock.split(id, TOKEN_1);
    }

    function testSplitPermissionPerUserWorksWhenGlobalFalse() public {
        // Create a valid, non-permanent, unexpired lock
        DUST.approve(address(dustLock), 2 * TOKEN_1);
        uint256 id = dustLock.createLock(2 * TOKEN_1, MAXTIME);
        // Enable per-user, keep global false
        dustLock.toggleSplit(user, true);
        dustLock.toggleSplit(address(0), false);
        dustLock.split(id, TOKEN_1); // should succeed
    }

    /* ========== REVENUE REWARD WIRING ========== */

    function testSetRevenueRewardZeroDisables() public {
        // Set to zero address should be allowed and clear the hook
        dustLock.setRevenueReward(IRevenueReward(address(0)));
        assertEq(address(dustLock.revenueReward()), address(0));
    }

    function testSetRevenueRewardToEOAReverts() public {
        vm.expectRevert(IDustLock.InvalidRevenueRewardContract.selector);
        dustLock.setRevenueReward(IRevenueReward(user2));
    }

    /* ========== HAPPY PATH ========== */

    function testCreateLockPermanentOneShot() public {
        uint256 amount = TOKEN_10K;
        // fund user1 and create permanent lock in one tx
        mintErc20Token(address(DUST), user1, amount);
        vm.startPrank(user1);
        DUST.approve(address(dustLock), amount);
        uint256 tokenId = dustLock.createLockPermanent(amount, MAXTIME);
        vm.stopPrank();

        // validate
        IDustLock.LockedBalance memory lb = dustLock.locked(tokenId);
        assertTrue(lb.isPermanent, "should be permanent");
        assertEq(lb.end, 0, "end should be zero for permanent");
        assertEq(uint256(lb.amount), amount, "amount mismatch");
        assertEq(dustLock.ownerOf(tokenId), user1, "owner mismatch");
    }

    function testCreateLockPermanentForOneShot() public {
        uint256 amount = TOKEN_10K;
        // caller is user (address(this)); create a permanent lock for user2
        mintErc20Token(address(DUST), user, amount);
        DUST.approve(address(dustLock), amount);
        uint256 tokenId = dustLock.createLockPermanentFor(amount, MAXTIME, user2);

        // validate minted to user2 and permanent
        IDustLock.LockedBalance memory lb = dustLock.locked(tokenId);
        assertTrue(lb.isPermanent, "should be permanent");
        assertEq(lb.end, 0, "end should be zero for permanent");
        assertEq(uint256(lb.amount), amount, "amount mismatch");
        assertEq(dustLock.ownerOf(tokenId), user2, "owner mismatch");
    }

    function testCreateLockPermanentRevertsMirrorCreateLock() public {
        uint256 validAmount = dustLock.minLockAmount();

        // amount too small
        uint256 tooSmallAmount = dustLock.minLockAmount() - 1;
        mintErc20Token(address(DUST), user, tooSmallAmount);
        DUST.approve(address(dustLock), tooSmallAmount);
        vm.expectRevert(IDustLock.AmountTooSmall.selector);
        dustLock.createLockPermanent(tooSmallAmount, 5 weeks);

        // lock duration not in future (0 duration)
        mintErc20Token(address(DUST), user, validAmount);
        DUST.approve(address(dustLock), validAmount);
        vm.expectRevert(IDustLock.LockDurationNotInFuture.selector);
        dustLock.createLockPermanent(validAmount, 0);

        // lock duration too short (rounds down to 0 weeks)
        mintErc20Token(address(DUST), user, validAmount);
        DUST.approve(address(dustLock), validAmount);
        vm.expectRevert(IDustLock.LockDurationNotInFuture.selector);
        dustLock.createLockPermanent(validAmount, 1 days);

        // lock duration too short (exactly MINTIME - 1)
        mintErc20Token(address(DUST), user, validAmount);
        DUST.approve(address(dustLock), validAmount);
        vm.expectRevert(IDustLock.LockDurationTooShort.selector);
        dustLock.createLockPermanent(validAmount, MINTIME - 1);

        // lock duration too long
        mintErc20Token(address(DUST), user, validAmount);
        DUST.approve(address(dustLock), validAmount);
        vm.expectRevert(IDustLock.LockDurationTooLong.selector);
        dustLock.createLockPermanent(validAmount, MAXTIME + 1 weeks);

        // insufficient balance
        uint256 userBalance = DUST.balanceOf(user);
        DUST.transfer(address(0xdead), userBalance); // burn existing balance
        DUST.approve(address(dustLock), validAmount);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        dustLock.createLockPermanent(validAmount, MAXTIME);

        // insufficient allowance
        mintErc20Token(address(DUST), user, validAmount);
        DUST.approve(address(dustLock), validAmount - 1);
        vm.expectRevert("ERC20: insufficient allowance");
        dustLock.createLockPermanent(validAmount, MAXTIME);
    }

    function testCreateLockPermanentEventsSequence() public {
        uint256 amount = dustLock.minLockAmount();
        mintErc20Token(address(DUST), user, amount);
        DUST.approve(address(dustLock), amount);

        vm.recordLogs();
        dustLock.createLockPermanent(amount, MAXTIME);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        PermanentLockEventScan memory scan = _scanPermanentLockEvents(logs);

        assertEq(scan.cTransfer, 1);
        assertEq(scan.cDeposit, 1);
        assertEq(scan.cLockPerm, 1);
        assertTrue(scan.cMetadata >= 1);

        assertTrue(
            scan.iTransfer < type(uint256).max && scan.iDeposit < type(uint256).max
                && scan.iLockPerm < type(uint256).max && scan.iMetadata < type(uint256).max,
            "events present"
        );
        assertLt(scan.iTransfer, scan.iDeposit, "Transfer before Deposit");
        assertLt(scan.iDeposit, scan.iLockPerm, "Deposit before LockPermanent");

        // Optional: details can be checked here if needed; order sanity is sufficient for this test
    }

    /// @dev Scans recorded logs for the permanent-lock event ordering. Extracted into its own
    /// stack frame so the optimizer-off coverage build does not overflow the EVM stack.
    function _scanPermanentLockEvents(Vm.Log[] memory logs) internal view returns (PermanentLockEventScan memory scan) {
        scan.iTransfer = type(uint256).max;
        scan.iDeposit = type(uint256).max;
        scan.iLockPerm = type(uint256).max;
        scan.iMetadata = type(uint256).max;

        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(dustLock)) {
                _countPermanentLockEvent(logs[i], i, scan);
            }
        }
    }

    /// @dev Records the first index and running count for each permanent-lock event type.
    function _countPermanentLockEvent(Vm.Log memory entry, uint256 index, PermanentLockEventScan memory scan)
        internal
        pure
    {
        if (entry.topics.length == 0) return;

        bytes32 topic0 = entry.topics[0];
        if (topic0 == keccak256("Transfer(address,address,uint256)") && entry.topics.length == 4) {
            if (scan.iTransfer == type(uint256).max) scan.iTransfer = index;
            unchecked {
                scan.cTransfer++;
            }
        } else if (topic0 == keccak256("Deposit(address,uint256,uint8,uint256,uint256,uint256)")) {
            if (scan.iDeposit == type(uint256).max) scan.iDeposit = index;
            unchecked {
                scan.cDeposit++;
            }
        } else if (topic0 == keccak256("LockPermanent(address,uint256,uint256,uint256)")) {
            if (scan.iLockPerm == type(uint256).max) scan.iLockPerm = index;
            unchecked {
                scan.cLockPerm++;
            }
        } else if (topic0 == keccak256("MetadataUpdate(uint256)")) {
            if (scan.iMetadata == type(uint256).max) scan.iMetadata = index;
            unchecked {
                scan.cMetadata++;
            }
        }
    }

    /* ========== LOCK BALANCE DECAY ========== */

    function testBalanceOfNFTDecayFromStartToEndOfLockTime() public {
        DUST.approve(address(dustLock), TOKEN_1 * 2);

        // move block.timestamp
        skipAndRoll(1 weeks);

        assertEq(block.timestamp, 2 weeks + 1);
        uint256 lockTime = MAXTIME / 2;
        uint256 tokenId = dustLock.createLock(TOKEN_1, lockTime);
        emit log_named_uint("[dustLock] created tokenId", tokenId);

        assertApproxEqAbs(
            dustLock.balanceOfNFTAt(tokenId, block.timestamp),
            TOKEN_1 / 2,
            1e16 // tolerable difference up to 0.01
        );

        // move block.timestamp
        skipAndRoll(12 weeks);

        // Calculate expected balance correctly:
        // 1. Time elapsed: 12 weeks
        // 2. Remaining lock duration: lockTime - 12 weeks
        // 3. MAXTIME is the denominator for decay calculations
        uint256 expectedBalance = TOKEN_1 * (lockTime - 12 weeks) / MAXTIME;

        assertApproxEqAbs(dustLock.balanceOfNFTAt(tokenId, block.timestamp), expectedBalance, 1e16);
    }

    function testBalanceOfTotalNftSupply() public {
        // arrange
        DUST.approve(address(dustLock), TOKEN_1 * 6);

        uint256[] memory tokens = new uint256[](6);

        // act
        // epoch 0
        uint256 timestamp0 = block.timestamp;

        tokens[0] = dustLock.createLock(TOKEN_1, MAXTIME / 3);
        tokens[1] = dustLock.createLock(TOKEN_1, MAXTIME / 2);
        emit log_named_uint("[dustLock] created tokenId#0", tokens[0]);
        emit log_named_uint("[dustLock] created tokenId#1", tokens[1]);

        uint256 balanceOfAllNftAt0 = _getBalanceOfAllNftsAt(tokens, timestamp0);
        uint256 totalSupplyAt0 = dustLock.totalSupply();

        // epoch 2
        skipAndRoll(2 weeks);
        uint256 timestamp2 = block.timestamp;

        tokens[2] = dustLock.createLock(TOKEN_1, MAXTIME / 8);
        tokens[3] = dustLock.createLock(TOKEN_1, MAXTIME);
        emit log_named_uint("[dustLock] created tokenId#2", tokens[2]);
        emit log_named_uint("[dustLock] created tokenId#3", tokens[3]);

        uint256 balanceOfAllNftAt2 = _getBalanceOfAllNftsAt(tokens, timestamp2);
        uint256 totalSupplyAt2 = dustLock.totalSupply();

        // epoch 7
        skipAndRoll(5 weeks);
        uint256 timestamp7 = block.timestamp;

        tokens[4] = dustLock.createLock(TOKEN_1, MAXTIME / 4);
        emit log_named_uint("[dustLock] created tokenId#4", tokens[4]);

        uint256 balanceOfAllNftAt7 = _getBalanceOfAllNftsAt(tokens, timestamp7);
        uint256 totalSupplyAt7 = dustLock.totalSupply();

        // assert
        assertEq(balanceOfAllNftAt0, _getBalanceOfAllNftsAt(tokens, timestamp0));
        assertEq(totalSupplyAt0, dustLock.totalSupplyAt(timestamp0));

        assertEq(balanceOfAllNftAt2, _getBalanceOfAllNftsAt(tokens, timestamp2));
        assertEq(totalSupplyAt2, dustLock.totalSupplyAt(timestamp2));

        assertEq(balanceOfAllNftAt7, _getBalanceOfAllNftsAt(tokens, timestamp7));
        assertEq(totalSupplyAt7, dustLock.totalSupplyAt(timestamp7));
    }

    function testMergeDifferentEndTimedLocksConservesGlobalSupplyWhenSourceShorter() public {
        DUST.approve(address(dustLock), TOKEN_1K * 2);
        uint256 shortToken = dustLock.createLock(TOKEN_1K, MINTIME + WEEK);
        uint256 longToken = dustLock.createLock(TOKEN_1K, MAXTIME);

        dustLock.merge(shortToken, longToken);

        _assertSingleLiveTokenMatchesSupply(longToken);
    }

    function testMergeDifferentEndTimedLocksConservesGlobalSupplyWhenDestinationShorter() public {
        DUST.approve(address(dustLock), TOKEN_1K * 2);
        uint256 shortToken = dustLock.createLock(TOKEN_1K, MINTIME + WEEK);
        uint256 longToken = dustLock.createLock(TOKEN_1K, MAXTIME);

        dustLock.merge(longToken, shortToken);

        _assertSingleLiveTokenMatchesSupply(shortToken);
    }

    function _getBalanceOfAllNftsAt(uint256[] memory tokens, uint256 ts) internal view returns (uint256) {
        uint256 balanceOfAllNftAt = 0;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == 0) continue;
            balanceOfAllNftAt += dustLock.balanceOfNFTAt(tokens[i], ts);
        }
        return balanceOfAllNftAt;
    }

    function _assertSingleLiveTokenMatchesSupply(uint256 tokenId_) internal view {
        uint256 nowTs = block.timestamp;
        assertEq(dustLock.balanceOfNFTAt(tokenId_, nowTs), dustLock.totalSupplyAt(nowTs), "current supply mismatch");

        uint256 nextEpoch = (nowTs / WEEK + 1) * WEEK;
        assertEq(
            dustLock.balanceOfNFTAt(tokenId_, nextEpoch),
            dustLock.totalSupplyAt(nextEpoch),
            "next epoch supply mismatch"
        );
    }

    /* ========== MIN/MAX LOCK TIME ========== */

    function testCreateLockMinLockTimeStartOfWeek() public {
        // arrange
        uint256 startOfCurrentWeek = block.timestamp / WEEK * WEEK;
        assertEq(startOfCurrentWeek, 1 weeks);

        // act/assert
        (DustLock.LockedBalance memory lockedTokenId1, DustLock.LockedBalance memory lockedTokenId2) =
            _createLocks(TOKEN_1, MINTIME + WEEK);
        assertEq(lockedTokenId1.end, startOfCurrentWeek + 5 weeks);
        assertEq(lockedTokenId2.end, startOfCurrentWeek + 5 weeks);

        // A sub-MINTIME request reverts at any timestamp.
        emit log("[dustLock] Expect revert: below min lock time");
        vm.expectRevert(IDustLock.LockDurationTooShort.selector);
        dustLock.createLock(TOKEN_1, MINTIME - WEEK);
    }

    function testExactMinDurationRevertsAtBoundaryPlusOneAndTwo() public {
        // Accepted behavior: exact week-multiple durations are unpurchasable. setUp starts at T + 1;
        // exact-MINTIME reverts immediately (no grace) and again at T + 2.
        emit log("[dustLock] Expect revert: exact-MINTIME at T + 1");
        vm.expectRevert(IDustLock.LockDurationTooShort.selector);
        dustLock.createLock(TOKEN_1, MINTIME);

        // one more second puts us at T + 2
        skipAndRoll(1);
        assertEq(block.timestamp, 1 weeks + 2);
        emit log("[dustLock] Expect revert: exact-MINTIME at T + 2");
        vm.expectRevert(IDustLock.LockDurationTooShort.selector);
        dustLock.createLock(TOKEN_1, MINTIME);
    }

    function testSubMintimeRequestRevertsAtBoundaryPlusOne() public {
        // A MINTIME - 1 request rounds to the same unlockTime as exact-MINTIME and reverts at T + 1.
        assertEq(block.timestamp, 1 weeks + 1);

        emit log("[dustLock] Expect revert: sub-MINTIME at T + 1");
        vm.expectRevert(IDustLock.LockDurationTooShort.selector);
        dustLock.createLock(TOKEN_1, MINTIME - 1);
    }

    function testCreateLockMinLockTimeEndOfWeek() public {
        // arrange
        skipAndRoll(1 weeks - 2);
        assertEq(block.timestamp, 2 weeks - 1); // 1 sec before the start of week2

        uint256 startOfCurrentWeek = block.timestamp / WEEK * WEEK;
        assertEq(startOfCurrentWeek, 1 weeks);

        // act/assert
        (DustLock.LockedBalance memory lockedTokenId1, DustLock.LockedBalance memory lockedTokenId2) =
            _createLocks(TOKEN_1, MINTIME + WEEK);
        assertEq(lockedTokenId1.end, startOfCurrentWeek + 5 weeks);
        assertEq(lockedTokenId2.end, startOfCurrentWeek + 5 weeks);

        emit log("[dustLock] Expect revert: min lock time");
        vm.expectRevert(IDustLock.LockDurationTooShort.selector);
        dustLock.createLock(TOKEN_1, MINTIME);

        emit log("[dustLock] Expect revert: createLockFor min lock time");
        vm.expectRevert(IDustLock.LockDurationTooShort.selector);
        dustLock.createLockFor(TOKEN_1, MINTIME, user2);
    }

    function testCreateLockAtExactWeekDefersAndExactMinDurationRevertsAtTPlusOne() public {
        // arrange
        skipAndRoll(1 weeks - 1);
        assertEq(block.timestamp, 2 weeks); // week2

        uint256 startOfCurrentWeek = block.timestamp / WEEK * WEEK;
        assertEq(startOfCurrentWeek, 2 weeks);

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        dustLock.createLock(TOKEN_1, MINTIME);
        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        dustLock.createLockFor(TOKEN_1, MINTIME, user2);

        skipAndRoll(1);

        // MINTIME + WEEK survives weekly rounding from T + 1.
        (DustLock.LockedBalance memory lockedTokenId1, DustLock.LockedBalance memory lockedTokenId2) =
            _createLocks(TOKEN_1, MINTIME + WEEK);
        assertEq(lockedTokenId1.end, startOfCurrentWeek + 5 weeks);
        assertEq(lockedTokenId2.end, startOfCurrentWeek + 5 weeks);

        // Accepted behavior: the exact-MINTIME retry at T + 1 reverts; there is no grace. The rounded
        // commitment of 28 days minus one second stays below the minimum.
        emit log("[dustLock] Expect revert: exact-MINTIME retry at T + 1");
        vm.expectRevert(IDustLock.LockDurationTooShort.selector);
        dustLock.createLock(TOKEN_1, MINTIME);
        vm.expectRevert(IDustLock.LockDurationTooShort.selector);
        dustLock.createLockFor(TOKEN_1, MINTIME, user2);
    }

    function testDepositForAndIncreaseAmountAtMinDurationCutoff() public {
        uint256 lockAmount = TOKEN_1K;
        mintErc20Token(address(DUST), user, lockAmount * 3);
        mintErc20Token(address(DUST), user2, lockAmount);

        vm.startPrank(user);
        DUST.approve(address(dustLock), lockAmount * 3);
        uint256 increaseTokenId = dustLock.createLock(lockAmount, MINTIME + WEEK);
        uint256 depositForTokenId = dustLock.createLock(lockAmount, MINTIME + WEEK);
        vm.stopPrank();

        uint256 cutoff = dustLock.locked(increaseTokenId).end - MINTIME;
        assertEq(cutoff % WEEK, 0, "cutoff should be an exact reward boundary");
        skipAndRoll(cutoff - block.timestamp);

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        vm.prank(user);
        dustLock.increaseAmount(increaseTokenId, lockAmount);

        vm.startPrank(user2);
        DUST.approve(address(dustLock), lockAmount);
        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        dustLock.depositFor(depositForTokenId, lockAmount);
        vm.stopPrank();

        assertEq(dustLock.locked(increaseTokenId).amount, int256(lockAmount));
        assertEq(dustLock.locked(depositForTokenId).amount, int256(lockAmount));

        // Accepted behavior: the deposit window closes at the cutoff boundary; there is no grace at the
        // cutoff + 1 retry, so both deposit paths revert DepositForLockDurationTooShort.
        skipAndRoll(1);
        vm.prank(user);
        vm.expectRevert(IDustLock.DepositForLockDurationTooShort.selector);
        dustLock.increaseAmount(increaseTokenId, lockAmount);

        vm.prank(user2);
        vm.expectRevert(IDustLock.DepositForLockDurationTooShort.selector);
        dustLock.depositFor(depositForTokenId, lockAmount);
    }

    function testMaxLockTime() public {
        // arrange
        uint256 startOfCurrentWeek = block.timestamp / WEEK * WEEK;
        assertEq(startOfCurrentWeek, 1 weeks);

        // act/assert
        (DustLock.LockedBalance memory lockedTokenId1, DustLock.LockedBalance memory lockedTokenId2) =
            _createLocks(TOKEN_1, MAXTIME);
        assertEq(lockedTokenId1.end, startOfCurrentWeek + 52 weeks);
        assertEq(lockedTokenId2.end, startOfCurrentWeek + 52 weeks);

        emit log("[dustLock] Expect revert: duration too long");
        vm.expectRevert(IDustLock.LockDurationTooLong.selector);
        dustLock.createLock(TOKEN_1, MAXTIME + WEEK);

        emit log("[dustLock] Expect revert: createLockFor duration too long");
        vm.expectRevert(IDustLock.LockDurationTooLong.selector);
        dustLock.createLockFor(TOKEN_1, MAXTIME + WEEK, user2);
    }

    /* ========== LOCK/WITHDRAW ========== */

    function testMinLockAmount() public {
        assertEq(dustLock.team(), user);

        // Set minLockAmount to 10 DUST (min increase will be 1 DUST)
        dustLock.setMinLockAmount(10 * TOKEN_1);

        emit log("[dustLock] Expect revert: createLock amount too small");
        vm.expectRevert(IDustLock.AmountTooSmall.selector);
        dustLock.createLock(10 * TOKEN_1 - 1, MAXTIME);

        // Create lock with 10 DUST
        DUST.approve(address(dustLock), 10 * TOKEN_1);
        uint256 tokenId = dustLock.createLock(10 * TOKEN_1, MAXTIME);
        emit log_named_uint("[dustLock] created tokenId", tokenId);

        // Test increase amount: min is minLockAmount / 10 = 1 DUST
        emit log("[dustLock] Expect revert: increaseAmount amount too small");
        vm.expectRevert(IDustLock.AmountTooSmall.selector);
        dustLock.increaseAmount(tokenId, TOKEN_1 - 1);

        // Increase by exactly 1 DUST should work
        DUST.approve(address(dustLock), TOKEN_1);
        dustLock.increaseAmount(tokenId, TOKEN_1);

        // Add more to enable valid split (need at least 20 DUST total for 10+10 split)
        DUST.approve(address(dustLock), 9 * TOKEN_1);
        dustLock.increaseAmount(tokenId, 9 * TOKEN_1); // now has 20 DUST total

        // split - both resulting amounts must meet minLockAmount (10 DUST)
        dustLock.toggleSplit(user, true);

        emit log("[dustLock] Expect revert: split amount too small");
        vm.expectRevert(IDustLock.AmountTooSmall.selector);
        dustLock.split(tokenId, 10 * TOKEN_1 - 1); // split amount < 10

        emit log("[dustLock] Expect revert: split leaving too small amount");
        vm.expectRevert(IDustLock.AmountTooSmall.selector);
        dustLock.split(tokenId, 11 * TOKEN_1); // would leave 9 DUST (< 10)

        dustLock.split(tokenId, 10 * TOKEN_1); // split into 10 DUST and 10 DUST
    }

    function testWithdraw() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 lockDuration = 29 * WEEK;
        dustLock.createLock(TOKEN_1, lockDuration);
        uint256 preBalance = DUST.balanceOf(address(user));

        skipAndRoll(lockDuration);
        dustLock.withdraw(1);
        emit log("[dustLock] withdraw called");

        uint256 postBalance = DUST.balanceOf(address(user));
        emit log_named_uint("[dustLock] received DUST", postBalance - preBalance);
        assertEq(postBalance - preBalance, TOKEN_1);
        vm.expectRevert(CommonChecksLibrary.InvalidTokenId.selector);
        dustLock.ownerOf(1);
        assertEq(dustLock.balanceOf(address(user)), 0);
        // assertEq(dustLock.ownerToNFTokenIdList(address(owner), 0), 0);

        // check voting checkpoint created on burn updating owner
        assertEq(dustLock.balanceOfNFT(1), 0);
    }

    /* ============= EARLY WITHDRAW ============= */

    function testEarlyWithdraw() public {
        mintErc20Token(address(DUST), user2, TOKEN_10K);

        vm.startPrank(user2);
        DUST.approve(address(dustLock), TOKEN_10K);
        uint256 tokenId = dustLock.createLock(TOKEN_10K, MAXTIME);
        vm.stopPrank();

        dustLock.setEarlyWithdrawTreasury(user3);
        dustLock.setEarlyWithdrawPenalty(3_000);

        skipAndRoll(MAXTIME / 2);

        // Get lock details BEFORE calling earlyWithdraw (lock gets destroyed after)
        IDustLock.LockedBalance memory lockedBalance = dustLock.locked(tokenId);
        uint256 remainingTime = lockedBalance.end > block.timestamp ? lockedBalance.end - block.timestamp : 0;
        uint256 totalLockTime = lockedBalance.end - lockedBalance.effectiveStart;
        uint256 expectedPenalty = _expectedTimedPenaltyAtScalar(TOKEN_10K, remainingTime, 3_000);
        assertEq(dustLock.earlyWithdrawPenaltyAmount(tokenId), expectedPenalty);
        uint256 userBalanceBefore = DUST.balanceOf(user2);
        uint256 treasuryBefore = DUST.balanceOf(user3);
        uint256 totalSupplyBefore = DUST.totalSupply();

        emit log_named_uint("[penalty] Remaining time", remainingTime);
        emit log_named_uint("[penalty] Total lock time", totalLockTime);
        emit log_named_uint("[penalty] Time ratio (BP)", (remainingTime * BASIS_POINTS) / totalLockTime);
        emit log_named_uint("[penalty] Expected penalty", expectedPenalty);

        // act
        vm.prank(user2);
        dustLock.earlyWithdraw(tokenId);
        emit log("[dustLock] earlyWithdraw called");

        // assert
        assertEq(dustLock.balanceOfNFT(tokenId), 0);

        uint256 actualUserBalance = DUST.balanceOf(address(user2));
        uint256 actualTreasuryBalance = DUST.balanceOf(address(dustLock.earlyWithdrawTreasury()));

        emit log_named_uint("[penalty] Actual user balance", actualUserBalance);
        emit log_named_uint("[penalty] Actual treasury balance", actualTreasuryBalance);
        emit log_named_uint("[penalty] Expected user balance", TOKEN_10K - expectedPenalty);

        assertEq(actualUserBalance, TOKEN_10K - expectedPenalty);
        assertEq(actualTreasuryBalance - treasuryBefore, expectedPenalty);
        assertEq(DUST.totalSupply(), totalSupplyBefore);
        // Conservation: independently-measured user and treasury deltas sum to the principal.
        assertEq((actualUserBalance - userBalanceBefore) + (actualTreasuryBalance - treasuryBefore), TOKEN_10K);
    }

    function testEarlyWithdrawSameBlockAfterTransfer() public {
        mintErc20Token(address(DUST), user2, TOKEN_10K);

        vm.startPrank(user2);
        DUST.approve(address(dustLock), TOKEN_10K);
        uint256 tokenId = dustLock.createLock(TOKEN_10K, MAXTIME);
        vm.stopPrank();

        dustLock.setEarlyWithdrawTreasury(user3);
        dustLock.setEarlyWithdrawPenalty(3_000);

        skipAndRoll(MAXTIME / 2);

        // Get lock details BEFORE calling earlyWithdraw for calculation
        IDustLock.LockedBalance memory lockedBalance = dustLock.locked(tokenId);
        uint256 remainingTime = lockedBalance.end > block.timestamp ? lockedBalance.end - block.timestamp : 0;
        uint256 totalLockTime = lockedBalance.end - lockedBalance.effectiveStart;

        // Manual calculation for transfer followed by early withdraw:

        // Given scenario:
        // - Create 10,000 token lock for MAXTIME (365 days = 31,536,000 seconds)
        // - Skip MAXTIME/2 (182.5 days = 15,768,000 seconds) - half elapsed
        // - Transfer NFT from user2 to user4 (no penalty impact)
        // - user4 immediately calls earlyWithdraw with 30% penalty rate

        // Time calculations with weekly rounding:
        // MAXTIME = 365 days = 365 x 24 x 60 x 60 = 31,536,000 seconds
        // Contract rounds to weeks: MAXTIME/WEEK = 31,536,000/604,800 = 52.142857... weeks
        // Rounded down: 52 weeks = 52 x 604,800 = 31,449,600 seconds
        // But lock starts at timestamp 1 (not 0), so actual duration = 31,449,599 seconds
        //
        // After skipping MAXTIME/2 = 15,768,000 seconds:
        // Actual remaining = 31,449,599 - 15,768,000 = 15,681,599 seconds
        // Time ratio = 15,681,599 / 31,449,599 = 0.4986 = 49.86%

        // The scalar-as-max curve prices the exit off remaining time only (effectiveStart and
        // totalLockTime are not pricing inputs), so the expectation is the independent curve model
        // at the 3000 scalar set above; the live quote is asserted to match it below.

        // Assert our manually calculated time values match actual contract values
        uint256 expectedRemainingTime = 15681599; // Half of MAXTIME minus week rounding
        uint256 expectedTotalLockTime = 31449599; // MAXTIME minus week rounding
        uint256 expectedTimeRatioBP = 4986; // 49.86% in basis points

        assertEq(remainingTime, expectedRemainingTime);
        assertEq(totalLockTime, expectedTotalLockTime);
        assertEq((remainingTime * BASIS_POINTS) / totalLockTime, expectedTimeRatioBP);

        uint256 expectedPenalty = _expectedTimedPenaltyAtScalar(TOKEN_10K, remainingTime, 3_000);
        assertEq(dustLock.earlyWithdrawPenaltyAmount(tokenId), expectedPenalty);
        uint256 expectedUserAmount = TOKEN_10K - expectedPenalty;
        uint256 userBalanceBefore = DUST.balanceOf(user4);
        uint256 treasuryBefore = DUST.balanceOf(user3);
        uint256 totalSupplyBefore = DUST.totalSupply();

        emit log_named_uint("[penalty] Transfer test: remaining time", remainingTime);
        emit log_named_uint("[penalty] Transfer test: total lock time", totalLockTime);
        emit log_named_uint("[penalty] Transfer test: time ratio (BP)", (remainingTime * BASIS_POINTS) / totalLockTime);
        emit log_named_uint("[penalty] Transfer test: expected penalty", expectedPenalty);

        // act
        vm.prank(user2);
        dustLock.transferFrom(user2, user4, tokenId);
        emit log("[dustLock] transferFrom user2 -> user4 before earlyWithdraw");

        vm.prank(user4);
        dustLock.earlyWithdraw(tokenId);
        emit log("[dustLock] earlyWithdraw by user4");

        // assert
        assertEq(dustLock.balanceOfNFT(tokenId), 0);

        uint256 actualUserBalance = DUST.balanceOf(address(user4));
        uint256 actualTreasuryBalance = DUST.balanceOf(address(dustLock.earlyWithdrawTreasury()));

        emit log_named_uint("[penalty] Transfer test: actual user balance", actualUserBalance);
        emit log_named_uint("[penalty] Transfer test: actual treasury balance", actualTreasuryBalance);

        assertEq(actualUserBalance, expectedUserAmount);
        assertEq(actualTreasuryBalance - treasuryBefore, expectedPenalty);
        assertEq(DUST.totalSupply(), totalSupplyBefore);
        // Conservation: independently-measured user and treasury deltas sum to the principal.
        assertEq((actualUserBalance - userBalanceBefore) + (actualTreasuryBalance - treasuryBefore), TOKEN_10K);
    }

    function testEarlyWithdrawBasicPenalty() public {
        // Set treasury to different address for proper testing
        // Note: team address is set to address(this) in constructor, so no prank needed
        dustLock.setEarlyWithdrawTreasury(user2);

        uint256 lockAmount = TOKEN_1K;
        uint256 tokenId;
        uint256 expectedPenalty;
        uint256 expectedUserAmount;

        {
            uint256 lockDuration = 90 days; // 3 months
            DUST.approve(address(dustLock), lockAmount);
            tokenId = dustLock.createLock(lockAmount, lockDuration);

            // Get actual lock details for verification
            IDustLock.LockedBalance memory lockedBalance = dustLock.locked(tokenId);
            emit log_named_uint("[penalty] Lock start time", lockedBalance.effectiveStart);
            emit log_named_uint("[penalty] Lock end time", lockedBalance.end);

            // Skip 30 days (1 month)
            skipAndRoll(30 days);

            // Manual calculation for 90-day lock with 30-day early withdrawal:

            // Time calculations with weekly rounding:
            // 90 days = 90 x 24 x 60 x 60 = 7,776,000 seconds
            // Contract rounds to weeks: 7,776,000/604,800 = 12.857... weeks
            // Rounded down: 12 weeks = 12 x 604,800 = 7,257,600 seconds
            // But lock starts at timestamp 1 (not 0), so actual duration = 7,257,599 seconds
            //
            // After skipping 30 days = 30 x 24 x 60 x 60 = 2,592,000 seconds:
            // Remaining time = 7,257,599 - 2,592,000 = 4,665,599 seconds
            // Lock amount: 1,000 tokens (1,000,000,000,000,000,000,000 wei)

            // The scalar-as-max curve prices the exit off remaining time only (effectiveStart and
            // totalLockTime are not pricing inputs); at the default 7500 scalar the penalty equals
            // _expectedTimedPenalty(lockAmount, 4,665,599).

            // Assert our manually calculated time values match actual contract values
            uint256 remainingTime = lockedBalance.end > block.timestamp ? lockedBalance.end - block.timestamp : 0;
            uint256 totalLockTime = lockedBalance.end - lockedBalance.effectiveStart;
            uint256 expectedRemainingTime = 4665599; // 90 days rounded to weeks minus 30 days skip
            uint256 expectedTotalLockTime = 7257599; // 90 days rounded to weeks minus timestamp offset
            uint256 expectedTimeRatioBP = 6428; // 64.28% in basis points

            assertEq(remainingTime, expectedRemainingTime);
            assertEq(totalLockTime, expectedTotalLockTime);
            assertEq((remainingTime * BASIS_POINTS) / totalLockTime, expectedTimeRatioBP);

            expectedPenalty = _expectedTimedPenalty(lockAmount, remainingTime);
            assertEq(dustLock.earlyWithdrawPenaltyAmount(tokenId), expectedPenalty);
            expectedUserAmount = lockAmount - expectedPenalty;

            emit log_named_uint("[penalty] Expected penalty (calculated)", expectedPenalty);
            emit log_named_uint("[penalty] Expected user amount (calculated)", expectedUserAmount);
        }

        {
            uint256 userBalanceBefore = DUST.balanceOf(user);
            uint256 treasuryBalanceBefore = DUST.balanceOf(user2);
            uint256 totalSupplyBefore = DUST.totalSupply();

            dustLock.earlyWithdraw(tokenId);

            uint256 userBalanceAfter = DUST.balanceOf(user);
            uint256 treasuryBalanceAfter = DUST.balanceOf(user2);

            uint256 actualUserReceived = userBalanceAfter - userBalanceBefore;
            uint256 actualTreasuryReceived = treasuryBalanceAfter - treasuryBalanceBefore;

            emit log_named_uint("[penalty] Actual user received", actualUserReceived);
            emit log_named_uint("[penalty] Actual treasury received", actualTreasuryReceived);
            emit log_named_uint("[penalty] Total distributed", actualUserReceived + actualTreasuryReceived);

            // Now we can properly validate the distribution
            assertEq(actualUserReceived, expectedUserAmount);
            assertEq(actualTreasuryReceived, expectedPenalty);
            assertEq(DUST.totalSupply(), totalSupplyBefore);
            // Conservation: independently-measured user and treasury deltas sum to the principal.
            assertEq(actualUserReceived + actualTreasuryReceived, lockAmount);
        }
    }

    /**
     * @notice Calculates the independent expected timed exit penalty at the default 7500 maximum
     * @param amount Locked DUST principal being priced
     * @param remainingTime Actual remaining duration in seconds
     * @return penalty Exact expected penalty remainder
     */
    function _expectedTimedPenalty(uint256 amount, uint256 remainingTime) internal pure returns (uint256 penalty) {
        return amount - (amount * (3 * MAXTIME - 2 * remainingTime)) / (4 * MAXTIME);
    }

    /**
     * @notice Calculates the independent expected timed exit penalty at an arbitrary scalar
     * @param amount Locked DUST principal being priced
     * @param remainingTime Actual remaining duration in seconds
     * @param scalar Active earlyWithdrawPenalty maximum in basis points
     * @return penalty Exact expected penalty remainder
     */
    function _expectedTimedPenaltyAtScalar(uint256 amount, uint256 remainingTime, uint256 scalar)
        internal
        pure
        returns (uint256 penalty)
    {
        uint256 numerator = 2_500 * MAXTIME + (scalar - 2_500) * remainingTime;
        uint256 denominator = BASIS_POINTS * MAXTIME;
        return amount - (amount * (denominator - numerator)) / denominator;
    }

    function testEarlyWithdrawMergeGamingPrevention() public {
        // Set treasury to different address for proper testing
        dustLock.setEarlyWithdrawTreasury(user2);

        uint256 lockAmount1 = TOKEN_1K;
        uint256 lockAmount2 = TOKEN_1K / 2;

        DUST.approve(address(dustLock), lockAmount1 + lockAmount2);
        uint256 tokenId1 = dustLock.createLock(lockAmount1, MAXTIME);
        uint256 tokenId2 = dustLock.createLock(lockAmount2, 180 days); // 6 months

        // Skip 90 days (3 months)
        skipAndRoll(90 days);

        // Merge tokens - this should use weighted average to preserve time served
        dustLock.merge(tokenId2, tokenId1);

        // Both locks created at same time (604801), so weighted average = 604801
        assertEq(dustLock.locked(tokenId1).effectiveStart, 604801);

        uint256 totalAmount = lockAmount1 + lockAmount2;
        uint256 userBalanceBefore = DUST.balanceOf(user);
        uint256 treasuryBalanceBefore = DUST.balanceOf(user2);

        // Wait 1 day after merge
        skipAndRoll(1 days);

        // The merged lock keeps tokenId1's MAXTIME end and prices the WHOLE amount at the
        // remaining-duration curve (25% floor rising to the earlyWithdrawPenalty maximum);
        // effectiveStart stays tracked storage but is no longer a pricing input.
        uint256 remainingTime;
        {
            IDustLock.LockedBalance memory lockedAfterWait = dustLock.locked(tokenId1);
            remainingTime = lockedAfterWait.end - block.timestamp;

            // 91 elapsed days against the weekly-rounded MAXTIME end created at 604801.
            assertEq(remainingTime, 23587199);
            assertEq(lockedAfterWait.end - lockedAfterWait.effectiveStart, 31449599);
        }

        // Independent expected penalty at the default 7500 maximum:
        // proceeds = floor(amount * (3T - 2R) / 4T); penalty = amount - proceeds.
        uint256 expectedPenalty = _expectedTimedPenalty(totalAmount, remainingTime);
        assertEq(dustLock.earlyWithdrawPenaltyAmount(tokenId1), expectedPenalty);

        // Merge no-discount: the merged quote never rounds below pricing each tranche
        // separately at the same merged end (per-quote round-up bounds the gap to 1 wei).
        uint256 tranche1Penalty = _expectedTimedPenalty(lockAmount1, remainingTime);
        uint256 tranche2Penalty = _expectedTimedPenalty(lockAmount2, remainingTime);
        assertGe(expectedPenalty + 1, tranche1Penalty + tranche2Penalty);
        assertLe(expectedPenalty, tranche1Penalty + tranche2Penalty);

        uint256 expectedUserAmount = totalAmount - expectedPenalty;

        // Early withdraw after 1 day - penalty should decay from max by 1 day
        uint256 totalSupplyBefore = DUST.totalSupply();
        dustLock.earlyWithdraw(tokenId1);

        uint256 userBalanceAfter = DUST.balanceOf(user);
        uint256 treasuryBalanceAfter = DUST.balanceOf(user2);

        uint256 actualPenalty = treasuryBalanceAfter - treasuryBalanceBefore;

        emit log_named_uint("[penalty] Merge total amount", totalAmount);
        emit log_named_uint("[penalty] Actual penalty", actualPenalty);
        emit log_named_uint("[penalty] Expected penalty (calculated)", expectedPenalty);
        emit log_named_uint("[penalty] Penalty rate basis points", (actualPenalty * BASIS_POINTS) / totalAmount);

        // Assert exact calculated values
        assertEq(actualPenalty, expectedPenalty);
        assertEq(DUST.totalSupply(), totalSupplyBefore);
        assertEq(userBalanceAfter - userBalanceBefore, expectedUserAmount);
        assertEq(actualPenalty + (userBalanceAfter - userBalanceBefore), totalAmount);
    }

    function testEarlyWithdrawAmountIncreaseGamingPrevention() public {
        // Set treasury to different address for proper testing
        dustLock.setEarlyWithdrawTreasury(user2);

        uint256 initialAmount = TOKEN_1K;
        uint256 addedAmount = TOKEN_1K;

        // Mint enough tokens for the test
        mintErc20Token(address(DUST), user, initialAmount + addedAmount);
        DUST.approve(address(dustLock), initialAmount + addedAmount);
        uint256 tokenId = dustLock.createLock(initialAmount, MAXTIME);

        // Skip 26 weeks (half of MAXTIME)
        uint256 originalStart = dustLock.locked(tokenId).effectiveStart;
        skipAndRoll(26 weeks);

        // Add more tokens - this should apply weighted average start time
        uint256 increaseTimestamp = block.timestamp;
        dustLock.increaseAmount(tokenId, addedAmount);

        // Calculate expected weighted average start time
        // Weighted start = (1000 * originalStart + 1000 * increaseTimestamp) / 2000
        uint256 expectedWeightedStart =
            (initialAmount * originalStart + addedAmount * increaseTimestamp) / (initialAmount + addedAmount);

        // Verify start time was updated to weighted average
        assertEq(dustLock.locked(tokenId).effectiveStart, expectedWeightedStart);

        uint256 userBalanceBefore = DUST.balanceOf(user);
        uint256 treasuryBalanceBefore = DUST.balanceOf(user2);
        uint256 totalAmount = initialAmount + addedAmount;

        // The weighted-average start still tracks time served in storage (asserted above), but the
        // scalar-as-max curve prices the whole 2000-token amount off remaining time only. Route the
        // expectation through the shared helper at the default 7500 scalar, then confirm the view agrees.
        uint256 remainingTime = dustLock.locked(tokenId).end - block.timestamp;
        uint256 expectedPenalty = _expectedTimedPenalty(totalAmount, remainingTime);
        assertEq(dustLock.earlyWithdrawPenaltyAmount(tokenId), expectedPenalty);

        uint256 totalSupplyBefore = DUST.totalSupply();

        // Immediate early withdraw after amount increase
        dustLock.earlyWithdraw(tokenId);

        uint256 actualPenalty = DUST.balanceOf(user2) - treasuryBalanceBefore;
        uint256 actualUserAmount = DUST.balanceOf(user) - userBalanceBefore;

        assertEq(actualPenalty, expectedPenalty);
        assertEq(DUST.totalSupply(), totalSupplyBefore);
        // Conservation: independently-measured user and treasury deltas sum to the principal.
        assertEq(actualUserAmount + actualPenalty, totalAmount);
    }

    function testDepositForGriefingPrevention() public {
        // Test that depositFor griefing attack is prevented by weighted average
        dustLock.setEarlyWithdrawTreasury(user2);

        uint256 lockAmount = TOKEN_10K;
        mintErc20Token(address(DUST), user, lockAmount);

        vm.startPrank(user);
        DUST.approve(address(dustLock), lockAmount);
        uint256 tokenId = dustLock.createLock(lockAmount, 52 weeks);
        vm.stopPrank();

        // Skip 11 months - user should have low penalty
        skipAndRoll(333 days);

        // Check penalty before griefing attempt
        uint256 penaltyRatioBefore;
        {
            IDustLock.LockedBalance memory lock = dustLock.locked(tokenId);
            uint256 remaining = lock.end > block.timestamp ? lock.end - block.timestamp : 0;
            uint256 total = lock.end - lock.effectiveStart;
            penaltyRatioBefore = (remaining * BASIS_POINTS) / total;
            assertTrue(penaltyRatioBefore < 1000, "Should be < 10% penalty before attack");
        }

        // GRIEFING ATTEMPT: Attacker deposits minimum amount via depositFor
        uint256 attackAmount = dustLock.minLockAmount();
        mintErc20Token(address(DUST), user1, attackAmount);
        {
            vm.startPrank(user1);
            DUST.approve(address(dustLock), attackAmount);
            dustLock.depositFor(tokenId, attackAmount);
            vm.stopPrank();
        }

        // Check penalty after griefing attempt (should remain low due to weighted average)
        {
            IDustLock.LockedBalance memory lock = dustLock.locked(tokenId);
            uint256 remaining = lock.end > block.timestamp ? lock.end - block.timestamp : 0;
            uint256 total = lock.end - lock.effectiveStart;
            uint256 penaltyRatioAfter = (remaining * BASIS_POINTS) / total;

            // Penalty increase should be minimal (< 1%) instead of jumping to maximum
            uint256 penaltyIncrease =
                penaltyRatioAfter > penaltyRatioBefore ? penaltyRatioAfter - penaltyRatioBefore : 0;
            assertTrue(penaltyIncrease < 100, "Penalty increase should be minimal");
            assertTrue(penaltyRatioAfter < 1000, "Final penalty should remain reasonable");
        }
    }

    function testDepositForLargeAmountGamingPrevention() public {
        // Test that large depositFor amounts still provide proportional gaming prevention
        dustLock.setEarlyWithdrawTreasury(user2);

        uint256 lockAmount = TOKEN_1K;
        mintErc20Token(address(DUST), user, lockAmount);

        vm.startPrank(user);
        DUST.approve(address(dustLock), lockAmount);
        uint256 tokenId = dustLock.createLock(lockAmount, 52 weeks);
        vm.stopPrank();

        // Skip significant time
        skipAndRoll(300 days);

        // Large deposit (10x original) via depositFor
        uint256 largeDeposit = TOKEN_10K;
        mintErc20Token(address(DUST), user1, largeDeposit);
        {
            vm.startPrank(user1);
            DUST.approve(address(dustLock), largeDeposit);
            dustLock.depositFor(tokenId, largeDeposit);
            vm.stopPrank();
        }

        // Large deposit should increase penalty significantly but proportionally
        {
            IDustLock.LockedBalance memory lock = dustLock.locked(tokenId);
            uint256 remaining = lock.end > block.timestamp ? lock.end - block.timestamp : 0;
            uint256 total = lock.end - lock.effectiveStart;
            uint256 ratio = (remaining * BASIS_POINTS) / total;

            assertTrue(ratio > 2000, "Large deposit should increase penalty");
            assertTrue(ratio < 9000, "But not to near-maximum levels");
        }
    }

    function testIncreaseAmountRevertsOnSoonToExpireLock() public {
        // Test that increaseAmount reverts when lock is expiring within MINTIME
        // This prevents griefing similar to depositFor

        uint256 lockAmount = TOKEN_1K;
        mintErc20Token(address(DUST), user, lockAmount * 2);

        vm.startPrank(user);
        DUST.approve(address(dustLock), lockAmount * 2);
        uint256 tokenId = dustLock.createLock(lockAmount, MAXTIME);

        // Skip to just before MINTIME remains
        uint256 MINTIME = 28 days;
        uint256 skipTime = MAXTIME - MINTIME + 1 seconds;
        skipAndRoll(skipTime);

        // Try to increase amount - should revert
        vm.expectRevert(IDustLock.DepositForLockDurationTooShort.selector);
        dustLock.increaseAmount(tokenId, lockAmount);

        vm.stopPrank();
    }

    function testEarlyWithdrawTimeExtensionFairness() public {
        // Set treasury to different address for proper testing
        dustLock.setEarlyWithdrawTreasury(user2);

        uint256 lockAmount = TOKEN_1K;

        DUST.approve(address(dustLock), lockAmount);
        uint256 tokenId = dustLock.createLock(lockAmount, 26 weeks);

        // Skip 13 weeks (half time)
        skipAndRoll(13 weeks);

        // Extend lock time - this should NOT reset start time
        IDustLock.LockedBalance memory lockedBefore = dustLock.locked(tokenId);
        dustLock.increaseUnlockTime(tokenId, MAXTIME);
        IDustLock.LockedBalance memory lockedAfter = dustLock.locked(tokenId);

        // Verify start time unchanged
        assertEq(lockedAfter.effectiveStart, lockedBefore.effectiveStart);

        uint256 userBalanceBefore = DUST.balanceOf(user);
        uint256 treasuryBalanceBefore = DUST.balanceOf(user2);
        uint256 remainingTime = lockedAfter.end > block.timestamp ? lockedAfter.end - block.timestamp : 0;
        uint256 expectedPenalty = _expectedTimedPenalty(lockAmount, remainingTime);
        assertEq(dustLock.earlyWithdrawPenaltyAmount(tokenId), expectedPenalty);
        uint256 totalSupplyBefore = DUST.totalSupply();

        dustLock.earlyWithdraw(tokenId);

        uint256 userBalanceAfter = DUST.balanceOf(user);
        uint256 treasuryBalanceAfter = DUST.balanceOf(user2);

        uint256 actualPenalty = treasuryBalanceAfter - treasuryBalanceBefore;
        uint256 actualUserReceived = userBalanceAfter - userBalanceBefore;

        // Extending the lock does not reset effectiveStart (asserted above), and the scalar-as-max
        // curve prices the exit off remaining time only. Extending to MAXTIME pushes remaining up
        // toward MAXTIME, which raises the penalty toward the ceiling rather than lowering it; the
        // expectation is the independent curve model and the live quote is asserted to match it.

        uint256 expectedUserAmount = lockAmount - expectedPenalty;

        emit log_named_uint("[penalty] Time extension actual penalty", actualPenalty);
        emit log_named_uint("[penalty] Expected penalty (calculated)", expectedPenalty);
        emit log_named_uint("[penalty] User received", actualUserReceived);
        emit log_named_uint("[penalty] Penalty as % of total", (actualPenalty * BASIS_POINTS) / lockAmount);

        // Assert exact calculated values
        assertEq(actualPenalty, expectedPenalty);
        assertEq(DUST.totalSupply(), totalSupplyBefore);
        assertEq(actualUserReceived, expectedUserAmount);
        assertEq(actualUserReceived + actualPenalty, lockAmount);
    }

    function testEarlyWithdrawTimeExtensionGamingPrevention() public {
        // Test: Verify extending lock before early withdraw doesn't reduce penalty percentage

        dustLock.setEarlyWithdrawTreasury(user2);
        uint256 lockAmount = TOKEN_1K;

        uint256 penalty1;
        uint256 penalty2;
        uint256 quote1;
        uint256 quote2;

        // === Scenario A: Early withdraw WITHOUT extension ===
        {
            DUST.approve(address(dustLock), lockAmount);
            uint256 tokenId1 = dustLock.createLock(lockAmount, 26 weeks);

            skipAndRoll(13 weeks); // Skip half time

            // Get lock details before withdraw for calculation
            IDustLock.LockedBalance memory lockDetails = dustLock.locked(tokenId1);
            uint256 remainingTime = lockDetails.end > block.timestamp ? lockDetails.end - block.timestamp : 0;
            uint256 totalLockTime = lockDetails.end - lockDetails.effectiveStart;

            // Weekly rounding: the 26-week lock rounds to 15,724,799s and, after 13 weeks elapse,
            // remaining = 7,862,399s. The scalar-as-max curve prices the exit off remaining only, so
            // the independent expectation is _expectedTimedPenalty(lockAmount, remaining).
            uint256 expectedRemainingTime1 = 7862399;
            uint256 expectedTotalLockTime1 = 15724799;

            assertEq(remainingTime, expectedRemainingTime1);
            assertEq(totalLockTime, expectedTotalLockTime1);

            uint256 expectedPenalty1 = _expectedTimedPenalty(lockAmount, remainingTime);

            uint256 treasuryBefore = DUST.balanceOf(user2);
            quote1 = dustLock.earlyWithdrawPenaltyAmount(tokenId1);
            uint256 totalSupplyBefore = DUST.totalSupply();
            dustLock.earlyWithdraw(tokenId1);
            penalty1 = DUST.balanceOf(user2) - treasuryBefore;
            assertEq(DUST.totalSupply(), totalSupplyBefore);

            // Effect and view both match the independent curve model.
            assertEq(penalty1, expectedPenalty1);
            assertEq(quote1, expectedPenalty1);

            emit log_named_uint("[gaming] Scenario A penalty", penalty1);
        }

        // === Scenario B: Extend lock then immediately early withdraw ===
        {
            DUST.approve(address(dustLock), lockAmount);
            uint256 tokenId2 = dustLock.createLock(lockAmount, 26 weeks);

            skipAndRoll(13 weeks); // Skip same amount of time

            // Extend to MAXTIME right before early withdraw (gaming attempt)
            dustLock.increaseUnlockTime(tokenId2, MAXTIME);

            // Get lock details after extension for calculation
            IDustLock.LockedBalance memory lockDetailsExtended = dustLock.locked(tokenId2);
            uint256 remainingTimeExtended =
                lockDetailsExtended.end > block.timestamp ? lockDetailsExtended.end - block.timestamp : 0;
            uint256 totalLockTimeExtended = lockDetailsExtended.end - lockDetailsExtended.effectiveStart;

            // Extending to MAXTIME pushes remaining up to 31,449,599s (the week-rounded MAXTIME). The
            // scalar-as-max curve prices the exit off remaining only, so the larger remaining yields a
            // higher expectation: _expectedTimedPenalty(lockAmount, remaining).
            uint256 expectedRemainingTime2 = 31449599;
            uint256 expectedTotalLockTime2 = 39311999;

            assertEq(remainingTimeExtended, expectedRemainingTime2);
            assertEq(totalLockTimeExtended, expectedTotalLockTime2);

            uint256 expectedPenalty2 = _expectedTimedPenalty(lockAmount, remainingTimeExtended);

            uint256 treasuryBefore = DUST.balanceOf(user2);
            quote2 = dustLock.earlyWithdrawPenaltyAmount(tokenId2);
            uint256 totalSupplyBefore = DUST.totalSupply();
            dustLock.earlyWithdraw(tokenId2);
            penalty2 = DUST.balanceOf(user2) - treasuryBefore;
            assertEq(DUST.totalSupply(), totalSupplyBefore);

            // Effect and view both match the independent curve model.
            assertEq(penalty2, expectedPenalty2);
            assertEq(quote2, expectedPenalty2);

            emit log_named_uint("[gaming] Scenario B penalty", penalty2);
        }

        // CRITICAL: Extension should NOT reduce penalty - actually increases it
        assertTrue(penalty2 > penalty1, "Extension should increase penalty");

        emit log("[gaming] Gaming prevention verified - extension increases penalty");
    }

    function testEarlyWithdrawPermanentLockAutoUnlocksAndPricesFreshEnd() public {
        // Set treasury to different address for proper testing
        dustLock.setEarlyWithdrawTreasury(user2);

        uint256 lockAmount = TOKEN_1K;

        DUST.approve(address(dustLock), lockAmount);
        uint256 tokenId = dustLock.createLock(lockAmount, MAXTIME);

        // Skip some time, then make permanent
        skipAndRoll(13 weeks);
        dustLock.lockPermanent(tokenId);

        // Skip more time - permanent lock age shouldn't matter
        skipAndRoll(26 weeks);

        // The quote prices the fresh weekly-rounded end that the internal unlock writes, identical to
        // calling unlockPermanent and then earlyWithdraw as two manual steps. Permanent-lock age does
        // not matter because the end is rewritten at exit time.
        uint256 freshRemaining = ((block.timestamp + MAXTIME) / 1 weeks) * 1 weeks - block.timestamp;
        uint256 expectedPenalty = _expectedTimedPenalty(lockAmount, freshRemaining);
        uint256 expectedUserAmount = lockAmount - expectedPenalty;
        assertEq(dustLock.earlyWithdrawPenaltyAmount(tokenId), expectedPenalty);

        uint256 userBalanceBefore = DUST.balanceOf(user);
        uint256 treasuryBalanceBefore = DUST.balanceOf(user2);
        uint256 totalSupplyBefore = DUST.totalSupply();

        dustLock.earlyWithdraw(tokenId);

        uint256 actualPenalty = DUST.balanceOf(user2) - treasuryBalanceBefore;
        assertEq(actualPenalty, expectedPenalty);
        assertEq(DUST.totalSupply(), totalSupplyBefore);
        assertEq(DUST.balanceOf(user) - userBalanceBefore, expectedUserAmount);
        assertEq(DUST.balanceOf(user) - userBalanceBefore + actualPenalty, lockAmount);
        assertEq(dustLock.permanentLockBalance(), 0);
    }

    function testEarlyWithdrawEdgeCases() public {
        // Set treasury to different address for proper testing
        dustLock.setEarlyWithdrawTreasury(user2);

        // Test minimum lock amount with very short remaining time
        // Manual calculation: minimum lock amount is 1e18 (MIN_LOCK_AMOUNT)
        uint256 minLockAmount = 1e18; // Hardcoded min lock amount
        DUST.approve(address(dustLock), minLockAmount * 2);
        {
            uint256 tokenId = dustLock.createLock(minLockAmount, MINTIME + WEEK);

            // Skip almost to expiry (1 minute remaining)
            skipAndRoll(MINTIME + WEEK - 1 minutes);

            uint256 userBalanceBefore = DUST.balanceOf(user);
            uint256 treasuryBalanceBefore = DUST.balanceOf(user2);
            uint256 quotedPenalty = dustLock.earlyWithdrawPenaltyAmount(tokenId);
            uint256 totalSupplyBefore = DUST.totalSupply();

            // Independent curve expectation: the live quote must match the model, not itself.
            IDustLock.LockedBalance memory lockedBalance = dustLock.locked(tokenId);
            uint256 remainingTime = lockedBalance.end > block.timestamp ? lockedBalance.end - block.timestamp : 0;
            assertEq(quotedPenalty, _expectedTimedPenalty(minLockAmount, remainingTime));

            dustLock.earlyWithdraw(tokenId);

            uint256 userBalanceAfter = DUST.balanceOf(user);
            uint256 treasuryBalanceAfter = DUST.balanceOf(user2);

            uint256 actualPenalty = treasuryBalanceAfter - treasuryBalanceBefore;

            // Every still-active timed lock is strictly above the 25% early-exit floor.
            assertEq(actualPenalty, quotedPenalty);
            assertGt(actualPenalty, minLockAmount / 4);
            assertEq(DUST.totalSupply(), totalSupplyBefore);

            emit log_named_uint("[penalty] Edge case penalty", actualPenalty);
            emit log_named_uint("[penalty] Edge case user received", userBalanceAfter - userBalanceBefore);
        }

        // Test zero penalty case (expired lock)
        {
            uint256 tokenId2 = dustLock.createLock(minLockAmount, MINTIME + WEEK);
            skipAndRoll(MINTIME + WEEK + 1);

            uint256 userBalance2Before = DUST.balanceOf(user);
            uint256 treasuryBalance2Before = DUST.balanceOf(user2);
            uint256 totalSupply2Before = DUST.totalSupply();
            assertEq(dustLock.earlyWithdrawPenaltyAmount(tokenId2), 0);

            dustLock.earlyWithdraw(tokenId2);

            uint256 userBalance2After = DUST.balanceOf(user);
            uint256 treasuryBalance2After = DUST.balanceOf(user2);

            // Expired lock should have zero penalty
            assertEq(treasuryBalance2After - treasuryBalance2Before, 0);
            assertEq(userBalance2After - userBalance2Before, minLockAmount);
            assertEq(DUST.totalSupply(), totalSupply2Before);

            emit log("[penalty] Expired lock: zero penalty confirmed");
        }
    }

    /* ============= SYSTEM DISCOUNT ============= */

    function testWeightedAverageStartDoesNotDiscountClaimReformExit() public {
        dustLock.setEarlyWithdrawTreasury(user2);

        // Create initial lock: 1,000,000 DUST, then add 500,000 DUST at halfway point
        mintErc20Token(address(DUST), user, TOKEN_1M + TOKEN_1M / 2);
        DUST.approve(address(dustLock), TOKEN_1M + TOKEN_1M / 2);

        uint256 tokenId = dustLock.createLock(TOKEN_1M, MAXTIME);
        skipAndRoll(MAXTIME / 2);
        dustLock.increaseAmount(tokenId, TOKEN_1M / 2);

        IDustLock.LockedBalance memory lockedBalance = dustLock.locked(tokenId);
        uint256 treasuryBefore = DUST.balanceOf(user2);
        uint256 quotedPenalty = dustLock.earlyWithdrawPenaltyAmount(tokenId);
        uint256 totalSupplyBefore = DUST.totalSupply();

        // Both tranches share the lock's single end; the curve prices amount at the
        // remaining-duration rate only, so separate per-tranche quotes at that same rate
        // can differ from the combined quote by at most the per-quote round-up wei.
        uint256 remainingTime = lockedBalance.end - block.timestamp;
        uint256 expectedSeparatePenalties =
            _expectedTimedPenalty(TOKEN_1M, remainingTime) + _expectedTimedPenalty(TOKEN_1M / 2, remainingTime);

        dustLock.earlyWithdraw(tokenId);
        uint256 actualPenalty = DUST.balanceOf(user2) - treasuryBefore;

        emit log_named_uint("[discount] Actual penalty", actualPenalty);
        emit log_named_uint("[discount] Separate penalties would be", expectedSeparatePenalties);
        emit log_named_uint("[discount] Weighted start", lockedBalance.effectiveStart);

        assertEq(actualPenalty, quotedPenalty);
        assertGe(actualPenalty + 1, expectedSeparatePenalties);
        assertLe(actualPenalty, expectedSeparatePenalties);
        assertEq(DUST.totalSupply(), totalSupplyBefore);
        assertEq(lockedBalance.effectiveStart, 5860801);
    }

    function testTinyAgedLockUsesRemainingDurationRateAfterDeposit() public {
        dustLock.setEarlyWithdrawTreasury(user2);

        // Create tiny lock, age it 300 days, add massive amount
        mintErc20Token(address(DUST), user, TOKEN_1K + TOKEN_1M);
        DUST.approve(address(dustLock), TOKEN_1K + TOKEN_1M);

        uint256 tokenId = dustLock.createLock(TOKEN_1K, MAXTIME);
        skipAndRoll(300 days);
        dustLock.increaseAmount(tokenId, TOKEN_1M);

        IDustLock.LockedBalance memory lockedBalance = dustLock.locked(tokenId);
        uint256 treasuryBefore = DUST.balanceOf(user2);
        uint256 quotedPenalty = dustLock.earlyWithdrawPenaltyAmount(tokenId);
        uint256 totalSupplyBefore = DUST.totalSupply();

        // Independent curve expectation: the live quote must match the model, not itself.
        uint256 remainingTime = lockedBalance.end > block.timestamp ? lockedBalance.end - block.timestamp : 0;
        assertEq(quotedPenalty, _expectedTimedPenalty(TOKEN_1K + TOKEN_1M, remainingTime));

        dustLock.earlyWithdraw(tokenId);
        uint256 actualPenalty = DUST.balanceOf(user2) - treasuryBefore;

        emit log_named_uint("[gaming] Weighted start", lockedBalance.effectiveStart);
        emit log_named_uint("[gaming] Actual penalty", actualPenalty);

        assertEq(lockedBalance.effectiveStart, 26498906);
        assertEq(actualPenalty, quotedPenalty);
        assertEq(DUST.totalSupply(), totalSupplyBefore);
    }

    /* ============= REENTRANCY PROTECTION ============= */

    function testReentrancyBlockedOnTransfer() public {
        emit log("[transfer] Approving DUST and creating a lock");
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);
        emit log_named_uint("[transfer] Created tokenId", tokenId);

        emit log("[transfer] Deploying malicious reward hook and setting it on DustLock");
        MaliciousRevenueReward impl = new MaliciousRevenueReward(FORWARDER);
        MaliciousRevenueReward malicious = MaliciousRevenueReward(_deployProxy(address(impl)));
        malicious.initialize(FORWARDER, dustLock, address(this), userVaultFactory);
        dustLock.setRevenueReward(malicious);
        emit log_named_address("[transfer] Malicious hook address", address(malicious));

        emit log("[transfer] Approving malicious hook to operate on tokenId");
        dustLock.approve(address(malicious), tokenId);

        emit log("[transfer] Attempting reentrant transfer (should revert)");
        vm.expectRevert("ReentrancyGuard: reentrant call");
        dustLock.transferFrom(user, user2, tokenId);
    }

    function testReentrancyBlockedOnBurn() public {
        emit log("[burn] Approving DUST and creating a lock");
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);
        emit log_named_uint("[burn] Created tokenId", tokenId);

        emit log("[burn] Deploying malicious reward hook and setting it on DustLock");
        MaliciousRevenueReward impl = new MaliciousRevenueReward(FORWARDER);
        MaliciousRevenueReward malicious = MaliciousRevenueReward(_deployProxy(address(impl)));
        malicious.initialize(FORWARDER, dustLock, address(this), userVaultFactory);
        dustLock.setRevenueReward(malicious);
        emit log_named_address("[burn] Malicious hook address", address(malicious));

        emit log("[burn] Approving malicious hook to operate on tokenId");
        dustLock.approve(address(malicious), tokenId);

        emit log("[burn] Attempting reentrant earlyWithdraw (should revert)");
        vm.expectRevert("ReentrancyGuard: reentrant call");
        dustLock.earlyWithdraw(tokenId);
    }

    /* ========== TEST SPLIT ========== */

    function testSplittingOfPermanentlyLockedTokenIsReverted() public {
        // arrange
        DUST.approve(address(dustLock), TOKEN_1 * 2);

        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);
        emit log_named_uint("[dustLock] created tokenId", tokenId);

        dustLock.lockPermanent(tokenId);
        emit log("[dustLock] token locked permanent");

        IDustLock.LockedBalance memory lockedTokenId;
        lockedTokenId = dustLock.locked(tokenId);

        assertTrue(lockedTokenId.isPermanent);

        skipAndRoll(1 weeks);

        dustLock.toggleSplit(user, true);

        // act
        emit log("[dustLock] Expect revert: split permanent lock");
        vm.expectRevert(IDustLock.PermanentLock.selector);
        dustLock.split(tokenId, TOKEN_1 / 2);

        // assert
        assertEq(dustLock.ownerOf(tokenId), address(user));

        lockedTokenId = dustLock.locked(tokenId);
        assertTrue(lockedTokenId.isPermanent);

        assertEq(dustLock.balanceOfNFT(tokenId), TOKEN_1);

        // Verify that no new tokens were created
        assertEq(dustLock.tokenId(), 1);
    }

    /* ========== TWO-STEP TEAM OWNERSHIP TRANSFER TESTS ========== */

    function testTwoStepTeamOwnershipTransfer() public {
        address newTeam = address(0x999);

        // Verify initial state
        assertEq(dustLock.team(), user);
        assertEq(dustLock.pendingTeam(), address(0));

        // Step 1: Current team proposes new team
        dustLock.proposeTeam(newTeam);

        assertEq(dustLock.team(), user);
        assertEq(dustLock.pendingTeam(), newTeam);

        // Step 2: New team accepts ownership
        vm.startPrank(newTeam);
        dustLock.acceptTeam();
        vm.stopPrank();

        // Verify final state
        assertEq(dustLock.team(), newTeam);
        assertEq(dustLock.pendingTeam(), address(0));
    }

    function testTeamOwnershipTransferValidations() public {
        address newTeam = address(0x999);
        address malicious = address(0x666);

        // Test 1: Only current team can propose
        vm.startPrank(malicious);
        emit log("[team] Expect revert: propose by non-team");
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.proposeTeam(newTeam);
        vm.stopPrank();

        // Test 2: Cannot propose zero address
        emit log("[team] Expect revert: propose zero address");
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        dustLock.proposeTeam(address(0));

        // Test 3: Cannot propose same address
        emit log("[team] Expect revert: propose same address");
        vm.expectRevert(CommonChecksLibrary.SameAddress.selector);
        dustLock.proposeTeam(user);

        // Test 4: Valid proposal
        dustLock.proposeTeam(newTeam);

        // Test 5: Only pending team can accept
        emit log("[team] Expect revert: accept by non-pending team");
        vm.expectRevert(IDustLock.NotPendingTeam.selector);
        dustLock.acceptTeam();

        vm.startPrank(malicious);
        emit log("[team] Expect revert: accept by malicious");
        vm.expectRevert(IDustLock.NotPendingTeam.selector);
        dustLock.acceptTeam();
        vm.stopPrank();

        // Test 6: Only current team can cancel
        vm.startPrank(malicious);
        emit log("[team] Expect revert: cancel by non-team");
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.cancelTeamProposal();
        vm.stopPrank();

        vm.startPrank(newTeam);
        emit log("[team] Expect revert: cancel by pending team");
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.cancelTeamProposal();
        vm.stopPrank();
    }

    function testTeamOwnershipTransferCancellation() public {
        address newTeam = address(0x999);

        // Test cancelling when no pending team
        emit log("[team] Expect revert: cancel without pending team");
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        dustLock.cancelTeamProposal();

        // Propose team
        dustLock.proposeTeam(newTeam);
        assertEq(dustLock.pendingTeam(), newTeam);

        // Cancel proposal
        dustLock.cancelTeamProposal();

        assertEq(dustLock.team(), user);
        assertEq(dustLock.pendingTeam(), address(0));

        // Pending team can no longer accept
        vm.startPrank(newTeam);
        emit log("[team] Expect revert: pending team accept after cancel");
        vm.expectRevert(IDustLock.NotPendingTeam.selector);
        dustLock.acceptTeam();
        vm.stopPrank();
    }

    function testTeamOwnershipTransferAdminFunctions() public {
        address newTeam = address(0x999);

        // Complete ownership transfer
        dustLock.proposeTeam(newTeam);
        vm.startPrank(newTeam);
        dustLock.acceptTeam();

        // New team can use admin functions
        dustLock.setMinLockAmount(2 * TOKEN_1);
        assertEq(dustLock.minLockAmount(), 2 * TOKEN_1);

        vm.stopPrank();

        // Old team cannot use admin functions
        emit log("[team] Expect revert: old team cannot set min lock amount");
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.setMinLockAmount(TOKEN_1);
    }

    function testTeamOwnershipTransferSecurityScenario() public {
        address wrongTeam = address(0x111);
        address correctTeam = address(0x999);

        // Scenario: Team accidentally proposes wrong address
        dustLock.proposeTeam(wrongTeam);

        // Team realizes mistake and cancels
        dustLock.cancelTeamProposal();
        assertEq(dustLock.pendingTeam(), address(0));

        // Team proposes correct address
        dustLock.proposeTeam(correctTeam);

        // Wrong team cannot accept (even though they were proposed before)
        vm.startPrank(wrongTeam);
        emit log("[team] Expect revert: wrong team accept");
        vm.expectRevert(IDustLock.NotPendingTeam.selector);
        dustLock.acceptTeam();
        vm.stopPrank();

        // Correct team can accept
        vm.startPrank(correctTeam);
        dustLock.acceptTeam();
        vm.stopPrank();

        assertEq(dustLock.team(), correctTeam);
    }

    /* ========== EDGE CASES & ATTACK SCENARIOS ========== */

    function testTeamOwnershipRaceConditionAttack() public {
        address attacker = address(0x666);
        address legitimateTeam = address(0x999);

        // Team proposes legitimate new team
        dustLock.proposeTeam(legitimateTeam);
        assertEq(dustLock.pendingTeam(), legitimateTeam);

        // Attacker tries to front-run the acceptance by proposing themselves
        vm.startPrank(attacker);
        emit log("[team] Expect revert: attacker propose");
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.proposeTeam(attacker);
        vm.stopPrank();

        // Attacker tries to accept before legitimate team
        vm.startPrank(attacker);
        emit log("[team] Expect revert: attacker accept");
        vm.expectRevert(IDustLock.NotPendingTeam.selector);
        dustLock.acceptTeam();
        vm.stopPrank();

        // Legitimate team can still accept
        vm.startPrank(legitimateTeam);
        dustLock.acceptTeam();
        vm.stopPrank();

        assertEq(dustLock.team(), legitimateTeam);
        assertEq(dustLock.pendingTeam(), address(0));
    }

    function testTeamOwnershipDoubleAcceptanceAttack() public {
        address newTeam = address(0x999);

        // Complete normal flow
        dustLock.proposeTeam(newTeam);
        vm.startPrank(newTeam);
        dustLock.acceptTeam();

        // Try to accept again (should fail)
        vm.expectRevert(IDustLock.NotPendingTeam.selector);
        dustLock.acceptTeam();
        vm.stopPrank();

        // State should remain correct
        assertEq(dustLock.team(), newTeam);
        assertEq(dustLock.pendingTeam(), address(0));
    }

    function testTeamOwnershipProposalOverwriteAttack() public {
        address maliciousTeam = address(0x666);
        address legitimateTeam = address(0x999);

        // Team proposes malicious address
        dustLock.proposeTeam(maliciousTeam);
        assertEq(dustLock.pendingTeam(), maliciousTeam);

        // Team immediately overwrites with legitimate address
        dustLock.proposeTeam(legitimateTeam);
        assertEq(dustLock.pendingTeam(), legitimateTeam);

        // Malicious team can no longer accept
        vm.startPrank(maliciousTeam);
        vm.expectRevert(IDustLock.NotPendingTeam.selector);
        dustLock.acceptTeam();
        vm.stopPrank();

        // Only legitimate team can accept
        vm.startPrank(legitimateTeam);
        dustLock.acceptTeam();
        vm.stopPrank();

        assertEq(dustLock.team(), legitimateTeam);
    }

    function testTeamOwnershipAfterTransferAttacks() public {
        address newTeam = address(0x999);
        address attacker = address(0x666);

        // Complete ownership transfer
        dustLock.proposeTeam(newTeam);
        vm.startPrank(newTeam);
        dustLock.acceptTeam();
        vm.stopPrank();

        // Old team cannot propose new teams
        emit log("[team] Expect revert: old team propose");
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.proposeTeam(attacker);

        // Old team cannot cancel (not team anymore)
        emit log("[team] Expect revert: old team cancel");
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.cancelTeamProposal();

        // Attacker cannot propose
        vm.startPrank(attacker);
        emit log("[team] Expect revert: attacker propose");
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.proposeTeam(attacker);
        vm.stopPrank();

        // Only new team has control
        vm.startPrank(newTeam);
        dustLock.proposeTeam(attacker); // New team can propose anyone
        assertEq(dustLock.pendingTeam(), attacker);
        dustLock.cancelTeamProposal(); // And cancel
        assertEq(dustLock.pendingTeam(), address(0));
        vm.stopPrank();
    }

    function testTeamOwnershipSelfProposalAttack() public {
        // Team tries to propose themselves (should fail)
        emit log("[team] Expect revert: propose self");
        vm.expectRevert(CommonChecksLibrary.SameAddress.selector);
        dustLock.proposeTeam(user);

        // State should remain unchanged
        assertEq(dustLock.team(), user);
        assertEq(dustLock.pendingTeam(), address(0));
    }

    function testTeamOwnershipZeroAddressAttacks() public {
        // Try to propose zero address
        emit log("[team] Expect revert: propose zero address");
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        dustLock.proposeTeam(address(0));

        // State should remain unchanged
        assertEq(dustLock.team(), user);
        assertEq(dustLock.pendingTeam(), address(0));
    }

    function testTeamOwnershipContractAddressEdgeCase() public {
        // Propose the DustLock contract itself as new team
        address contractAsTeam = address(dustLock);

        dustLock.proposeTeam(contractAsTeam);
        assertEq(dustLock.pendingTeam(), contractAsTeam);

        // Contract cannot call acceptTeam (no code to do so)
        // This would require the contract to have acceptTeam logic
        // Let's cancel this dangerous proposal
        dustLock.cancelTeamProposal();
        assertEq(dustLock.pendingTeam(), address(0));
    }

    function testTeamOwnershipMultipleProposalsRapidFire() public {
        address team1 = address(0x111);
        address team2 = address(0x222);
        address team3 = address(0x333);

        // Rapid fire proposals (last one wins)
        dustLock.proposeTeam(team1);
        dustLock.proposeTeam(team2);
        dustLock.proposeTeam(team3);

        assertEq(dustLock.pendingTeam(), team3);

        // Only team3 can accept
        vm.startPrank(team1);
        emit log("[team] Expect revert: team1 accept");
        vm.expectRevert(IDustLock.NotPendingTeam.selector);
        dustLock.acceptTeam();
        vm.stopPrank();

        vm.startPrank(team2);
        emit log("[team] Expect revert: team2 accept");
        vm.expectRevert(IDustLock.NotPendingTeam.selector);
        dustLock.acceptTeam();
        vm.stopPrank();

        vm.startPrank(team3);
        dustLock.acceptTeam();
        vm.stopPrank();

        assertEq(dustLock.team(), team3);
    }

    function testTeamOwnershipCancelAfterAcceptance() public {
        address newTeam = address(0x999);

        // Complete transfer
        dustLock.proposeTeam(newTeam);
        vm.startPrank(newTeam);
        dustLock.acceptTeam();
        vm.stopPrank();

        // Old team tries to cancel (should fail - they're not team anymore)
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.cancelTeamProposal();

        // New team tries to cancel when no pending (should fail)
        vm.startPrank(newTeam);
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        dustLock.cancelTeamProposal();
        vm.stopPrank();
    }

    function testTeamOwnershipReentrancyProtection() public {
        // This tests that the functions are protected against reentrancy
        // The functions modify state before external calls, which is good practice

        address newTeam = address(0x999);
        dustLock.proposeTeam(newTeam);

        // The accept function changes state before emitting events
        // Let's verify state is consistent throughout
        vm.startPrank(newTeam);

        // Before acceptance
        assertEq(dustLock.team(), user);
        assertEq(dustLock.pendingTeam(), newTeam);

        dustLock.acceptTeam();

        // After acceptance - state should be immediately consistent
        assertEq(dustLock.team(), newTeam);
        assertEq(dustLock.pendingTeam(), address(0));

        vm.stopPrank();
    }

    function testTeamOwnershipAdminFunctionsByPendingTeam() public {
        address newTeam = address(0x999);

        // Propose new team
        dustLock.proposeTeam(newTeam);

        // Pending team tries to use admin functions before accepting (should fail)
        vm.startPrank(newTeam);
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.setMinLockAmount(2 * TOKEN_1);

        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.proposeTeam(address(0x888));

        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.cancelTeamProposal();

        // Now accept
        dustLock.acceptTeam();

        // Now admin functions should work
        dustLock.setMinLockAmount(2 * TOKEN_1);
        assertEq(dustLock.minLockAmount(), 2 * TOKEN_1);

        vm.stopPrank();
    }

    function testTeamOwnershipChainedTransfers() public {
        address team1 = address(0x111);
        address team2 = address(0x222);
        address team3 = address(0x333);

        // Transfer 1: user -> team1
        dustLock.proposeTeam(team1);
        vm.startPrank(team1);
        dustLock.acceptTeam();

        // Transfer 2: team1 -> team2
        dustLock.proposeTeam(team2);
        vm.stopPrank();

        vm.startPrank(team2);
        dustLock.acceptTeam();

        // Transfer 3: team2 -> team3
        dustLock.proposeTeam(team3);
        vm.stopPrank();

        vm.startPrank(team3);
        dustLock.acceptTeam();
        vm.stopPrank();

        // Verify final state
        assertEq(dustLock.team(), team3);
        assertEq(dustLock.pendingTeam(), address(0));

        // Verify old teams have no control
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.proposeTeam(address(0x444));

        vm.startPrank(team1);
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.proposeTeam(address(0x444));
        vm.stopPrank();

        vm.startPrank(team2);
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.proposeTeam(address(0x444));
        vm.stopPrank();
    }

    function testTeamOwnershipGasGriefingResistance() public {
        address newTeam = address(0x999);

        // Test that functions don't consume excessive gas
        // and can't be griefed by gas limit attacks

        uint256 gasBefore = gasleft();
        dustLock.proposeTeam(newTeam);
        uint256 gasAfter = gasleft();
        uint256 gasUsed = gasBefore - gasAfter;

        // Proposal should be very efficient (about 65k)
        assertLt(gasUsed, 65000, "proposeTeam uses too much gas");

        gasBefore = gasleft();
        vm.startPrank(newTeam);
        dustLock.acceptTeam();
        vm.stopPrank();
        gasAfter = gasleft();
        gasUsed = gasBefore - gasAfter;

        // Acceptance should be efficient (less than 50k gas)
        assertLt(gasUsed, 50000, "acceptTeam uses too much gas");
    }

    function testTeamOwnershipProposalToCurrentTeamAfterTransfer() public {
        address newTeam = address(0x999);

        // Complete ownership transfer
        dustLock.proposeTeam(newTeam);
        vm.startPrank(newTeam);
        dustLock.acceptTeam();

        // New team tries to propose themselves (should fail)
        vm.expectRevert(CommonChecksLibrary.SameAddress.selector);
        dustLock.proposeTeam(newTeam);
        vm.stopPrank();
    }

    function testTeamOwnershipPendingTeamCannotProposeOthers() public {
        address pendingTeam = address(0x999);
        address anotherTeam = address(0x888);

        // Propose pending team
        dustLock.proposeTeam(pendingTeam);

        // Pending team tries to propose another team before accepting (should fail)
        vm.startPrank(pendingTeam);
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.proposeTeam(anotherTeam);
        vm.stopPrank();
    }

    function testTeamOwnershipZeroAddressCannotAccept() public {
        // This tests that zero address cannot somehow become pending
        // and then try to accept (should be impossible but let's verify)

        // Propose a legitimate team first
        address legitimateTeam = address(0x999);
        dustLock.proposeTeam(legitimateTeam);

        // Zero address tries to accept (should fail)
        vm.startPrank(address(0));
        vm.expectRevert(IDustLock.NotPendingTeam.selector);
        dustLock.acceptTeam();
        vm.stopPrank();
    }

    function testTeamOwnershipMultipleProposalsSameBatch() public {
        address team1 = address(0x111);
        address team2 = address(0x222);

        // Multiple proposals in same transaction context
        dustLock.proposeTeam(team1);
        // Immediately overwrite
        dustLock.proposeTeam(team2);

        // Only team2 should be able to accept
        vm.startPrank(team1);
        vm.expectRevert(IDustLock.NotPendingTeam.selector);
        dustLock.acceptTeam();
        vm.stopPrank();

        vm.startPrank(team2);
        dustLock.acceptTeam();
        vm.stopPrank();

        assertEq(dustLock.team(), team2);
    }

    function testTeamOwnershipStatePersistenceAfterRevert() public {
        address newTeam = address(0x999);

        // Propose team
        dustLock.proposeTeam(newTeam);
        assertEq(dustLock.pendingTeam(), newTeam);

        // Cause a revert in acceptance (by calling from wrong address)
        vm.startPrank(address(0x666));
        emit log("[team] Expect revert: wrong address accept");
        vm.expectRevert(IDustLock.NotPendingTeam.selector);
        dustLock.acceptTeam();
        vm.stopPrank();

        // State should remain unchanged after revert
        assertEq(dustLock.team(), user);
        assertEq(dustLock.pendingTeam(), newTeam);

        // Legitimate team can still accept
        vm.startPrank(newTeam);
        dustLock.acceptTeam();
        vm.stopPrank();

        assertEq(dustLock.team(), newTeam);
        assertEq(dustLock.pendingTeam(), address(0));
    }

    function testLockStartFieldBehavior() public {
        uint256 initialTimestamp = block.timestamp;

        // Test 1: Lock creation sets start field correctly
        emit log("[startField] Test 1: Lock creation");
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        IDustLock.LockedBalance memory lockedBalance = dustLock.locked(tokenId);
        emit log_named_uint("[startField] Initial lock start timestamp", lockedBalance.effectiveStart);
        emit log_named_uint("[startField] Initial block timestamp", initialTimestamp);
        assertEq(lockedBalance.effectiveStart, initialTimestamp);

        // Test 2: Amount increase uses weighted average start field
        emit log("[startField] Test 2: Amount increase uses weighted average start");
        skipAndRoll(WEEK);
        uint256 beforeDepositTimestamp = block.timestamp;
        uint256 originalStart = lockedBalance.effectiveStart;

        DUST.approve(address(dustLock), TOKEN_1);
        dustLock.increaseAmount(tokenId, TOKEN_1);

        // Calculate expected weighted average: (1 * originalStart + 1 * beforeDepositTimestamp) / 2
        uint256 expectedWeightedStart =
            (TOKEN_1 * originalStart + TOKEN_1 * beforeDepositTimestamp) / (TOKEN_1 + TOKEN_1);

        lockedBalance = dustLock.locked(tokenId);
        emit log_named_uint("[startField] After deposit start timestamp", lockedBalance.effectiveStart);
        emit log_named_uint("[startField] Expected weighted start", expectedWeightedStart);
        emit log_named_uint("[startField] Before deposit block timestamp", beforeDepositTimestamp);
        assertEq(lockedBalance.effectiveStart, expectedWeightedStart);
        assertEq(lockedBalance.amount, 2e18);

        // Test 3: Time extension preserves start field
        emit log("[startField] Test 3: Time extension preserves start");
        skipAndRoll(WEEK);
        uint256 beforeExtensionTimestamp = block.timestamp;
        uint256 startBeforeExtension = lockedBalance.effectiveStart;
        uint256 currentEndTime = lockedBalance.end;

        dustLock.increaseUnlockTime(tokenId, (currentEndTime + WEEK) - block.timestamp);

        lockedBalance = dustLock.locked(tokenId);
        emit log_named_uint("[startField] After extension start timestamp", lockedBalance.effectiveStart);
        emit log_named_uint("[startField] Start before extension", startBeforeExtension);
        emit log_named_uint("[startField] Current timestamp", beforeExtensionTimestamp);
        assertEq(lockedBalance.effectiveStart, startBeforeExtension); // Should NOT change
        assertTrue(lockedBalance.effectiveStart != beforeExtensionTimestamp); // Confirm it wasn't reset

        // Test 4: Merge uses weighted average to preserve time served
        emit log("[startField] Test 4: Merge uses weighted average");
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId2 = dustLock.createLock(TOKEN_1, MAXTIME);

        skipAndRoll(WEEK);

        // Get actual effectiveStart values before merge
        IDustLock.LockedBalance memory lock1 = dustLock.locked(tokenId);
        IDustLock.LockedBalance memory lock2 = dustLock.locked(tokenId2);

        // Calculate expected weighted average: (2e18 * lock1Start + 1e18 * lock2Start) / 3e18
        uint256 expectedMergeStart = (2 * lock1.effectiveStart + 1 * lock2.effectiveStart) / 3;

        dustLock.merge(tokenId2, tokenId);

        lockedBalance = dustLock.locked(tokenId);
        emit log_named_uint("[startField] After merge start timestamp", lockedBalance.effectiveStart);
        emit log_named_uint("[startField] Expected weighted start", expectedMergeStart);
        assertEq(lockedBalance.effectiveStart, expectedMergeStart);
        assertEq(lockedBalance.amount, 3e18);

        // Test 5: Permanent lock unlock resets start field
        emit log("[startField] Test 5: Permanent unlock resets start");
        dustLock.lockPermanent(tokenId);

        lockedBalance = dustLock.locked(tokenId);
        assertTrue(lockedBalance.isPermanent);

        skipAndRoll(WEEK);
        uint256 beforeUnlockTimestamp = block.timestamp;

        dustLock.unlockPermanent(tokenId);

        lockedBalance = dustLock.locked(tokenId);
        emit log_named_uint("[startField] After unlock start timestamp", lockedBalance.effectiveStart);
        emit log_named_uint("[startField] Before unlock block timestamp", beforeUnlockTimestamp);
        assertEq(lockedBalance.effectiveStart, beforeUnlockTimestamp);
        assertFalse(lockedBalance.isPermanent);
    }

    /* ========== COVERAGE BRANCHES ========== */

    /*
     * DustLock storage slots the coverage tests write with vm.store; re-derive them from
     * `forge inspect DustLock storage-layout` whenever the layout changes.
     */
    uint256 private constant POINT_HISTORY_SLOT = 155;
    uint256 private constant EPOCH_SLOT = 166;
    uint256 private constant LOCKED_SLOT = 168;
    uint256 private constant SLOPE_CHANGES_SLOT = 171;

    function testRevenueCoverageDustLockRemainingViewsAndReverts() public {
        assertEq(dustLock.owner(), address(this));
        assertEq(dustLock.clock(), uint48(block.timestamp));
        assertEq(dustLock.CLOCK_MODE(), "mode=timestamp");

        assertFalse(dustLock.isApprovedForAll(address(this), user2));
        dustLock.setApprovalForAll(user2, true);
        assertTrue(dustLock.isApprovedForAll(address(this), user2));
        dustLock.setApprovalForAll(user2, false);
        assertFalse(dustLock.isApprovedForAll(address(this), user2));

        mintErc20Token(address(DUST), user, TOKEN_10K);
        DUST.approve(address(dustLock), TOKEN_10K);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        vm.prank(user2);
        vm.expectRevert(IDustLock.NotApprovedOrOwner.selector);
        dustLock.approve(user3, tokenId);

        vm.expectRevert(IDustLock.NotOwner.selector);
        dustLock.transferFrom(user2, user3, tokenId);

        EmptyDustLockReceiver emptyReceiver = new EmptyDustLockReceiver();
        vm.expectRevert(IDustLock.ERC721TransferToNonERC721ReceiverImplementer.selector);
        dustLock.safeTransferFrom(user, address(emptyReceiver), tokenId);

        vm.expectRevert(IDustLock.NoLockFound.selector);
        dustLock.depositFor(99_999, TOKEN_1);

        vm.prank(user2);
        vm.expectRevert(IDustLock.NotApprovedOrOwner.selector);
        dustLock.earlyWithdraw(tokenId);

        vm.prank(user2);
        vm.expectRevert(IDustLock.NotApprovedOrOwner.selector);
        dustLock.lockPermanent(tokenId);

        vm.prank(user2);
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.toggleSplit(user, true);

        vm.prank(user2);
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.setRevenueReward(revenueReward);

        vm.prank(user2);
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.setEarlyWithdrawPenalty(1);

        vm.expectRevert(IDustLock.InvalidWithdrawPenalty.selector);
        dustLock.setEarlyWithdrawPenalty(BASIS_POINTS);

        vm.prank(user2);
        vm.expectRevert(IDustLock.NotTeam.selector);
        dustLock.setEarlyWithdrawTreasury(user2);

        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        dustLock.setEarlyWithdrawTreasury(address(0));

        dustLock.setFeeEnforcedOperator(user2, false);
    }

    function testRevenueCoverageDustLockExpiredAndBoundaryReverts() public {
        mintErc20Token(address(DUST), user, TOKEN_10K);
        DUST.approve(address(dustLock), TOKEN_10K);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MINTIME + WEEK);
        IDustLock.LockedBalance memory locked = dustLock.locked(tokenId);
        skipAndRoll(locked.end - block.timestamp + 1);

        vm.expectRevert(IDustLock.LockExpired.selector);
        dustLock.depositFor(tokenId, TOKEN_1);

        vm.expectRevert(IDustLock.LockExpired.selector);
        dustLock.lockPermanent(tokenId);

        vm.expectRevert(IDustLock.LockExpired.selector);
        dustLock.increaseUnlockTime(tokenId, MINTIME);
    }

    function testRevenueCoverageDustLockIncreaseUnlockTimeReverts() public {
        mintErc20Token(address(DUST), user, TOKEN_10K);
        DUST.approve(address(dustLock), TOKEN_10K);

        uint256 maxTokenId = dustLock.createLock(TOKEN_1, MAXTIME);
        vm.expectRevert(IDustLock.LockDurationNotInFuture.selector);
        dustLock.increaseUnlockTime(maxTokenId, MINTIME);

        uint256 shortTokenId = dustLock.createLock(TOKEN_1, MINTIME + WEEK);
        vm.expectRevert(IDustLock.LockDurationTooLong.selector);
        dustLock.increaseUnlockTime(shortTokenId, MAXTIME + WEEK);

        uint256 emptyTokenId = dustLock.createLock(TOKEN_1, MINTIME + WEEK);
        _storeLocked(address(dustLock), emptyTokenId, 0, block.timestamp, block.timestamp + WEEK, false);
        vm.expectRevert(IDustLock.NoLockFound.selector);
        dustLock.increaseUnlockTime(emptyTokenId, MAXTIME);
    }

    function testRevenueCoverageDustLockWithdrawReverts() public {
        mintErc20Token(address(DUST), user, TOKEN_10K);
        DUST.approve(address(dustLock), TOKEN_10K);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        vm.prank(user2);
        vm.expectRevert(IDustLock.NotApprovedOrOwner.selector);
        dustLock.withdraw(tokenId);

        vm.expectRevert(IDustLock.LockNotExpired.selector);
        dustLock.withdraw(tokenId);
    }

    function testRevenueCoverageDustLockSplitMergeAndPermanentReverts() public {
        mintErc20Token(address(DUST), user, TOKEN_10K);
        DUST.approve(address(dustLock), TOKEN_10K);
        uint256 from = dustLock.createLock(TOKEN_1 * 3, MAXTIME);
        uint256 to = dustLock.createLock(TOKEN_1, MAXTIME);

        vm.expectRevert(IDustLock.SameNFT.selector);
        dustLock.merge(from, from);

        vm.prank(user2);
        vm.expectRevert(IDustLock.NotApprovedOrOwner.selector);
        dustLock.merge(from, to);

        dustLock.approve(user2, from);
        vm.prank(user2);
        vm.expectRevert(IDustLock.NotApprovedOrOwner.selector);
        dustLock.merge(from, to);

        vm.expectRevert(IDustLock.SplitNotAllowed.selector);
        dustLock.split(from, TOKEN_1);

        dustLock.toggleSplit(user, true);

        vm.prank(user3);
        vm.expectRevert(IDustLock.NotApprovedOrOwner.selector);
        dustLock.split(from, TOKEN_1);

        vm.expectRevert(IDustLock.AmountTooBig.selector);
        dustLock.split(from, TOKEN_1 * 3);
        vm.expectRevert(IDustLock.AmountTooSmall.selector);
        dustLock.split(from, TOKEN_1 * 2 + 1);

        dustLock.lockPermanent(to);
        vm.expectRevert(IDustLock.PermanentLock.selector);
        dustLock.lockPermanent(to);
    }

    function testRevenueCoverageDustLockMergeExpiredTokenBranches() public {
        _assertMergeExpiredReverts(false);
        _assertMergeExpiredReverts(true);
    }

    function testRevenueCoverageDustLockSplitExpiredBranch() public {
        mintErc20Token(address(DUST), user, TOKEN_10K);
        DUST.approve(address(dustLock), TOKEN_10K);
        uint256 tokenId = dustLock.createLock(TOKEN_1 * 3, MINTIME + WEEK);
        IDustLock.LockedBalance memory locked = dustLock.locked(tokenId);
        dustLock.toggleSplit(user, true);

        skipAndRoll(locked.end - block.timestamp + 1);

        vm.expectRevert(IDustLock.LockExpired.selector);
        dustLock.split(tokenId, TOKEN_1);
    }

    function testRevenueCoverageDustLockInternalDefensiveBranches() public {
        mintErc20Token(address(DUST), user, TOKEN_10K);
        DUST.approve(address(dustLock), TOKEN_10K);

        uint256 unauthorizedWithdrawTokenId = dustLock.createLock(TOKEN_1, MAXTIME);
        vm.expectRevert(IDustLock.NotApprovedOrOwner.selector);
        vm.prank(user2);
        dustLock.withdraw(unauthorizedWithdrawTokenId);

        uint256 emptyTokenId = dustLock.createLock(TOKEN_1, MINTIME + WEEK);
        _storeLocked(address(dustLock), emptyTokenId, 0, block.timestamp, block.timestamp + WEEK, false);
        vm.expectRevert(IDustLock.NoLockFound.selector);
        dustLock.lockPermanent(emptyTokenId);

        uint256 wrongFromTokenId = dustLock.createLock(TOKEN_1, MAXTIME);
        vm.expectRevert(IDustLock.NotOwner.selector);
        dustLock.transferFrom(user2, user, wrongFromTokenId);
    }

    function testRevenueCoverageDustLockCheckpointDefensiveBranches() public {
        uint256 nextWeek = ((block.timestamp / WEEK) + 1) * WEEK;
        uint256 lastTimestamp = nextWeek - WEEK;
        vm.warp(nextWeek + 1);
        _storeEpoch(address(dustLock), 1);
        _storeGlobalPoint(address(dustLock), 1, 1, 1, lastTimestamp, 0, 0);
        _storeSlopeChange(address(dustLock), nextWeek, -2);
        dustLock.checkpoint();

        mintErc20Token(address(DUST), user, TOKEN_100K);
        DUST.approve(address(dustLock), TOKEN_100K);
        dustLock.createLock(TOKEN_100K, MAXTIME);
    }

    function testRevenueCoverageDustLockCheckpointTokenClampBranches() public {
        mintErc20Token(address(DUST), user, TOKEN_10K);
        DUST.approve(address(dustLock), TOKEN_10K);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        _storeGlobalPoint(address(dustLock), dustLock.epoch(), 0, 0, block.timestamp, block.number, 0);
        dustLock.lockPermanent(tokenId);
    }

    function testRevenueCoverageDustLockRoyaltyAndValidatorNoDataBranches() public {
        mintErc20Token(address(DUST), user, TOKEN_10K);
        DUST.approve(address(dustLock), TOKEN_10K);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        dustLock.setRoyaltyInfo(user2, 500);
        DustLock(address(dustLock)).setTransferValidator(address(new RevertNoDataValidator()));
        dustLock.setFeeEnforcedOperator(user, true);

        vm.expectRevert(IDustLock.TransferValidationFailed.selector);
        dustLock.transferFrom(user, user2, tokenId);
    }

    function _mappingSlot(uint256 key, uint256 slot) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, slot));
    }

    function _storeEpoch(address target, uint256 value) internal {
        vm.store(target, bytes32(EPOCH_SLOT), bytes32(value));

        assertEq(IDustLock(target).epoch(), value, "EPOCH_SLOT drifted");
    }

    function _storeGlobalPoint(
        address target,
        uint256 index,
        int256 bias,
        int256 slope,
        uint256 timestamp,
        uint256 blockNumber,
        uint256 permanent
    ) internal {
        bytes32 base = _mappingSlot(index, POINT_HISTORY_SLOT);
        vm.store(target, base, _intToBytes32(bias));
        vm.store(target, bytes32(uint256(base) + 1), _intToBytes32(slope));
        vm.store(target, bytes32(uint256(base) + 2), bytes32(timestamp));
        vm.store(target, bytes32(uint256(base) + 3), bytes32(blockNumber));
        vm.store(target, bytes32(uint256(base) + 4), bytes32(permanent));

        IDustLock.GlobalPoint memory point = IDustLock(target).pointHistory(index);
        assertEq(point.bias, bias, "POINT_HISTORY_SLOT bias drifted");
        assertEq(point.slope, slope, "POINT_HISTORY_SLOT slope drifted");
        assertEq(point.ts, timestamp, "POINT_HISTORY_SLOT ts drifted");
        assertEq(point.blk, blockNumber, "POINT_HISTORY_SLOT blk drifted");
        assertEq(point.permanentLockBalance, permanent, "POINT_HISTORY_SLOT permanentLockBalance drifted");
    }

    function _storeLocked(
        address target,
        uint256 tokenId_,
        int256 amount,
        uint256 effectiveStart,
        uint256 end,
        bool isPermanent
    ) internal {
        bytes32 base = _mappingSlot(tokenId_, LOCKED_SLOT);
        vm.store(target, base, _intToBytes32(amount));
        vm.store(target, bytes32(uint256(base) + 1), bytes32(effectiveStart));
        vm.store(target, bytes32(uint256(base) + 2), bytes32(end));
        vm.store(target, bytes32(uint256(base) + 3), bytes32(isPermanent ? uint256(1) : uint256(0)));

        IDustLock.LockedBalance memory stored = IDustLock(target).locked(tokenId_);
        assertEq(stored.amount, amount, "LOCKED_SLOT amount drifted");
        assertEq(stored.effectiveStart, effectiveStart, "LOCKED_SLOT effectiveStart drifted");
        assertEq(stored.end, end, "LOCKED_SLOT end drifted");
        assertEq(stored.isPermanent, isPermanent, "LOCKED_SLOT isPermanent drifted");
    }

    function _storeSlopeChange(address target, uint256 timestamp, int256 slopeChange) internal {
        vm.store(target, _mappingSlot(timestamp, SLOPE_CHANGES_SLOT), _intToBytes32(slopeChange));

        assertEq(IDustLock(target).slopeChanges(timestamp), slopeChange, "SLOPE_CHANGES_SLOT drifted");
    }

    function _intToBytes32(int256 value) internal pure returns (bytes32 word) {
        assembly {
            word := value
        }
    }

    /**
     * @notice Merges two fresh locks after the short one expires and expects LockExpired.
     * @param expireFrom Whether the short lock is the `from` side of the merge or the `to` side.
     */
    function _assertMergeExpiredReverts(bool expireFrom) internal {
        mintErc20Token(address(DUST), user, TOKEN_10K);
        DUST.approve(address(dustLock), TOKEN_10K);
        uint256 from = dustLock.createLock(TOKEN_1, expireFrom ? MINTIME + WEEK : MAXTIME);
        uint256 to = dustLock.createLock(TOKEN_1, expireFrom ? MAXTIME : MINTIME + WEEK);
        IDustLock.LockedBalance memory shortLock = dustLock.locked(expireFrom ? from : to);

        skipAndRoll(shortLock.end - block.timestamp + 1);

        vm.expectRevert(IDustLock.LockExpired.selector);
        dustLock.merge(from, to);
    }

    /* ========== HELPER FUNCTIONS ========== */

    function _createLocks(uint256 amount, uint256 duration)
        internal
        returns (IDustLock.LockedBalance memory lockedTokenId1, IDustLock.LockedBalance memory lockedTokenId2)
    {
        DUST.approve(address(dustLock), amount * 2);

        uint256 tokenId1 = dustLock.createLock(amount, duration);
        lockedTokenId1 = dustLock.locked(tokenId1);

        uint256 tokenId2 = dustLock.createLock(amount, duration);
        lockedTokenId2 = dustLock.locked(tokenId2);
    }
}
