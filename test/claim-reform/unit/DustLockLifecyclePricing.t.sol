// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IDustLock} from "../../../src/interfaces/IDustLock.sol";

import {BaseTestLocal} from "../../BaseTestLocal.sol";

contract DustLockLifecyclePricingTest is BaseTestLocal {
    function _setUp() internal override {
        mintErc20Token(address(DUST), user, TOKEN_100K);
        DUST.approve(address(dustLock), type(uint256).max);
    }

    /**
     * @notice Calculates the independent expected penalty for a timed position
     * @param amount Locked DUST principal
     * @param end Lock maturity timestamp
     * @return penalty Exact expected penalty remainder
     */
    function _expectedTimedPenalty(uint256 amount, uint256 end) internal view returns (uint256 penalty) {
        uint256 remaining = end > block.timestamp ? end - block.timestamp : 0;
        if (remaining == 0) return 0;
        remaining = Math.min(remaining, MAXTIME);
        uint256 net = Math.mulDiv(amount, 3 * MAXTIME - 2 * remaining, 4 * MAXTIME);

        return amount - net;
    }

    function testTransferAndSplitPreservePricingInputsWithoutPenaltyReduction() public {
        uint256 amount = 20 * TOKEN_1;
        uint256 tokenId = dustLock.createLock(amount, MAXTIME);
        skipAndRoll(13 weeks);

        IDustLock.LockedBalance memory beforeTransfer = dustLock.locked(tokenId);
        uint256 originalQuote = dustLock.earlyWithdrawPenaltyAmount(tokenId);
        dustLock.transferFrom(user, user2, tokenId);

        IDustLock.LockedBalance memory afterTransfer = dustLock.locked(tokenId);
        assertEq(afterTransfer.amount, beforeTransfer.amount);
        assertEq(afterTransfer.end, beforeTransfer.end);
        assertEq(dustLock.earlyWithdrawPenaltyAmount(tokenId), originalQuote);

        dustLock.toggleSplit(user2, true);
        vm.prank(user2);
        (uint256 first, uint256 second) = dustLock.split(tokenId, 7 * TOKEN_1);

        IDustLock.LockedBalance memory firstLock = dustLock.locked(first);
        IDustLock.LockedBalance memory secondLock = dustLock.locked(second);
        assertEq(dustLock.ownerOf(first), user2);
        assertEq(dustLock.ownerOf(second), user2);
        assertEq(firstLock.end, beforeTransfer.end);
        assertEq(secondLock.end, beforeTransfer.end);
        assertEq(uint256(firstLock.amount) + uint256(secondLock.amount), amount);
        assertGe(
            dustLock.earlyWithdrawPenaltyAmount(first) + dustLock.earlyWithdrawPenaltyAmount(second), originalQuote
        );
    }

    function testMergeUsesResultingLongerEndAndCombinedAmount() public {
        uint256 amount = 10 * TOKEN_1;
        uint256 shorter = dustLock.createLock(amount, 30 weeks);
        uint256 longer = dustLock.createLock(amount, 50 weeks);
        IDustLock.LockedBalance memory longerBefore = dustLock.locked(longer);

        dustLock.merge(shorter, longer);

        IDustLock.LockedBalance memory merged = dustLock.locked(longer);
        assertEq(uint256(merged.amount), 2 * amount);
        assertEq(merged.end, longerBefore.end);
        assertEq(dustLock.earlyWithdrawPenaltyAmount(longer), _expectedTimedPenalty(2 * amount, merged.end));
        assertEq(dustLock.locked(shorter).amount, 0);
    }

    function testAddExtendAndPermanentConversionsSelectCurrentLockState() public {
        uint256 amount = 10 * TOKEN_1;
        uint256 added = 2 * TOKEN_1;
        uint256 tokenId = dustLock.createLock(amount, 30 weeks);
        IDustLock.LockedBalance memory initial = dustLock.locked(tokenId);

        dustLock.depositFor(tokenId, added);
        IDustLock.LockedBalance memory afterDeposit = dustLock.locked(tokenId);
        assertEq(afterDeposit.end, initial.end);
        assertEq(dustLock.earlyWithdrawPenaltyAmount(tokenId), _expectedTimedPenalty(amount + added, afterDeposit.end));

        uint256 quoteBeforeExtension = dustLock.earlyWithdrawPenaltyAmount(tokenId);
        dustLock.increaseUnlockTime(tokenId, MAXTIME);
        IDustLock.LockedBalance memory extended = dustLock.locked(tokenId);
        uint256 quoteAfterExtension = dustLock.earlyWithdrawPenaltyAmount(tokenId);
        assertGt(extended.end, afterDeposit.end);
        assertGe(quoteAfterExtension, quoteBeforeExtension);

        dustLock.lockPermanent(tokenId);
        // The permanent quote prices the executable two-step path at the fresh weekly-rounded end.
        uint256 freshEnd = ((block.timestamp + MAXTIME) / 1 weeks) * 1 weeks;
        assertEq(dustLock.earlyWithdrawPenaltyAmount(tokenId), _expectedTimedPenalty(amount + added, freshEnd));
        assertEq(dustLock.permanentLockBalance(), amount + added);

        dustLock.unlockPermanent(tokenId);
        IDustLock.LockedBalance memory unlocked = dustLock.locked(tokenId);
        assertFalse(unlocked.isPermanent);
        assertEq(dustLock.permanentLockBalance(), 0);
        assertEq(dustLock.earlyWithdrawPenaltyAmount(tokenId), _expectedTimedPenalty(amount + added, unlocked.end));
    }
}
