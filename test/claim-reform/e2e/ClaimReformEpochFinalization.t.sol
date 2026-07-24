// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";
import {EpochTimeLibrary} from "../../../src/libraries/EpochTimeLibrary.sol";

import {ClaimReformTestBase} from "../_utils/ClaimReformTestBase.sol";

/**
 * @title ClaimReformEpochFinalizationTest
 * @author Neverland
 * @notice End-to-end regression matrix for the PR-50 exact-epoch finalization guard
 */
contract ClaimReformEpochFinalizationTest is ClaimReformTestBase {
    struct BoundaryTokens {
        uint256 mature;
        uint256 deposit;
        uint256 increase;
        uint256 extend;
        uint256 earlyExit;
        uint256 mergeFrom;
        uint256 mergeTo;
        uint256 split;
        uint256 makePermanent;
        uint256 permanent;
        uint256 transfer;
    }

    function testRevenueRewardDurationMatchesSharedEpochGrid() public view {
        uint256 sampleTimestamp = 13 weeks + 3 days + 7 hours;
        uint256 epochDuration =
            EpochTimeLibrary.epochNext(sampleTimestamp) - EpochTimeLibrary.epochStart(sampleTimestamp);

        assertEq(epochDuration, WEEK);
        assertEq(revenueReward.DURATION(), epochDuration);
    }

    function testExactEpochDefersEveryOwnershipAndCheckpointMutationUntilTPlusOne() public {
        uint256 amount = 10 * TOKEN_1;
        BoundaryTokens memory tokens;
        tokens.mature = dustLock.createLock(amount, MINTIME + WEEK);
        tokens.deposit = dustLock.createLock(amount, MAXTIME);
        tokens.increase = dustLock.createLock(amount, MAXTIME);
        tokens.extend = dustLock.createLock(amount, 180 days);
        tokens.earlyExit = dustLock.createLock(amount, MAXTIME);
        tokens.mergeFrom = dustLock.createLock(amount, MAXTIME);
        tokens.mergeTo = dustLock.createLock(amount, MAXTIME);
        tokens.split = dustLock.createLock(2 * amount, MAXTIME);
        tokens.makePermanent = dustLock.createLock(amount, MAXTIME);
        tokens.permanent = dustLock.createLockPermanent(amount, MAXTIME);
        tokens.transfer = dustLock.createLock(amount, MAXTIME);
        dustLock.toggleSplit(user, true);

        uint256 boundary = dustLock.locked(tokens.mature).end;
        vm.warp(boundary);
        vm.roll(block.number + 1);
        bytes32 beforeFingerprint = _stateFingerprint();

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        dustLock.checkpoint();

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        dustLock.createLock(TOKEN_1, MINTIME + WEEK);

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        dustLock.createLockFor(TOKEN_1, MINTIME + WEEK, user2);

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        dustLock.createLockPermanent(TOKEN_1, MAXTIME);

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        dustLock.createLockPermanentFor(TOKEN_1, MAXTIME, user2);

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        dustLock.depositFor(tokens.deposit, TOKEN_1);

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        dustLock.increaseAmount(tokens.increase, TOKEN_1);

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        dustLock.increaseUnlockTime(tokens.extend, MAXTIME);

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        dustLock.withdraw(tokens.mature);

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        dustLock.earlyWithdraw(tokens.earlyExit);

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        dustLock.merge(tokens.mergeFrom, tokens.mergeTo);

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        dustLock.split(tokens.split, amount);

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        dustLock.lockPermanent(tokens.makePermanent);

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        dustLock.unlockPermanent(tokens.permanent);

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        dustLock.transferFrom(user, user2, tokens.transfer);

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        dustLock.safeTransferFrom(user, user2, tokens.transfer);

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        dustLock.safeTransferFrom(user, user2, tokens.transfer, hex"1234");

        assertEq(_stateFingerprint(), beforeFingerprint);

        vm.warp(boundary + 1);
        vm.roll(block.number + 1);
        dustLock.checkpoint();
        dustLock.withdraw(tokens.mature);
        dustLock.earlyWithdraw(tokens.earlyExit);
        dustLock.transferFrom(user, user2, tokens.transfer);
        uint256 createdAtTPlusOne = dustLock.createLock(TOKEN_1, MINTIME + WEEK);

        assertEq(dustLock.ownerOf(tokens.transfer), user2);
        assertEq(dustLock.ownerOf(createdAtTPlusOne), user);
    }

    function _stateFingerprint() internal view returns (bytes32 fingerprint) {
        fingerprint = keccak256(
            abi.encode(
                dustLock.tokenId(),
                dustLock.supply(),
                dustLock.permanentLockBalance(),
                DUST.balanceOf(address(dustLock)),
                DUST.balanceOf(user),
                DUST.balanceOf(BURN_WALLET)
            )
        );

        for (uint256 id = 1; id <= dustLock.tokenId(); ++id) {
            fingerprint = keccak256(abi.encode(fingerprint, dustLock.ownerOf(id), dustLock.locked(id)));
        }
    }
}
