// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IDustLock} from "../../../src/interfaces/IDustLock.sol";

import {ClaimReformModel} from "../_utils/ClaimReformModel.sol";

import {ClaimReformTestBase} from "../_utils/ClaimReformTestBase.sol";

contract ClaimReformLifecycleFuzzTest is ClaimReformTestBase {
    function testFuzzTimedExitActionMatchesIndependentModel(
        uint96 rawAmount,
        uint32 rawDuration,
        uint32 rawPhase,
        uint32 rawElapsed
    ) public {
        uint256 amount = bound(uint256(rawAmount), MIN_LOCK_AMOUNT, TOKEN_1M);
        uint256 duration = bound(uint256(rawDuration), MINTIME + WEEK, MAXTIME);
        _warpToWeekPhase(bound(uint256(rawPhase), 1, WEEK - 1));
        uint256 tokenId = dustLock.createLock(amount, duration);
        IDustLock.LockedBalance memory created = dustLock.locked(tokenId);
        uint256 commitment = created.end - block.timestamp;
        uint256 elapsed = bound(uint256(rawElapsed), 0, commitment);
        skipAndRoll(elapsed);
        _skipEpochBoundaryIfNeeded();

        uint256 remaining = _remaining(dustLock.locked(tokenId));
        (uint256 expectedPenalty, uint256 expectedNet) = ClaimReformModel.timedExit(amount, remaining);
        ExitSnapshot memory beforeExit = _snapshotExit(user);

        assertEq(dustLock.earlyWithdrawPenaltyAmount(tokenId), expectedPenalty);
        dustLock.earlyWithdraw(tokenId);

        _assertExitDeltas(beforeExit, user, amount, expectedPenalty, expectedNet);
    }

    function testFuzzNewTimedClaimActionMatchesIndependentModel(uint96 rawGross, uint32 rawDuration, uint32 rawPhase)
        public
    {
        uint256 gross = bound(uint256(rawGross), 2 * TOKEN_1, TOKEN_1M);
        uint256 duration = bound(uint256(rawDuration), MINTIME + WEEK, MAXTIME);
        _warpToWeekPhase(bound(uint256(rawPhase), 1, WEEK - 1));
        uint256 commitment = ClaimReformModel.realizedCommitment(block.timestamp, duration);
        (uint256 expectedPenalty, uint256 expectedNet) = ClaimReformModel.timedClaim(gross, commitment);
        uint256 treasuryBefore = DUST.balanceOf(BURN_WALLET);
        uint256 vaultBefore = DUST.balanceOf(DUST_VAULT);
        uint256 totalSupplyBefore = DUST.totalSupply();

        _claim(user2, gross, duration, 0);

        uint256 tokenId = dustLock.tokenId();
        assertEq(dustLock.ownerOf(tokenId), user2);
        assertEq(uint256(dustLock.locked(tokenId).amount), expectedNet);
        assertEq(DUST.balanceOf(BURN_WALLET) - treasuryBefore, expectedPenalty);
        assertEq(vaultBefore - DUST.balanceOf(DUST_VAULT), gross);
        assertEq(DUST.totalSupply(), totalSupplyBefore);
        assertEq(DUST.allowance(address(claimStrategy), address(dustLock)), 0);
    }

    function testFuzzExistingTimedClaimThenExitMatchesCompositeModel(
        uint96 rawPrincipal,
        uint96 rawGross,
        uint32 rawElapsed
    ) public {
        uint256 principal = bound(uint256(rawPrincipal), MIN_LOCK_AMOUNT, TOKEN_1M);
        uint256 gross = bound(uint256(rawGross), TOKEN_1, TOKEN_1M);
        uint256 tokenId = _createUser2TimedLock(principal, MAXTIME);
        IDustLock.LockedBalance memory created = dustLock.locked(tokenId);
        uint256 elapsed = bound(uint256(rawElapsed), 0, created.end - block.timestamp - MINTIME - 1);
        skipAndRoll(elapsed);
        _skipEpochBoundaryIfNeeded();

        uint256 remaining = created.end - block.timestamp;
        (uint256 claimPenalty, uint256 claimNet) = ClaimReformModel.timedClaim(gross, remaining);
        uint256 treasuryBefore = DUST.balanceOf(BURN_WALLET);
        uint256 vaultBefore = DUST.balanceOf(DUST_VAULT);

        _claim(user2, gross, 0, tokenId);

        uint256 combinedPrincipal = principal + claimNet;
        assertEq(uint256(dustLock.locked(tokenId).amount), combinedPrincipal);
        assertEq(DUST.balanceOf(BURN_WALLET) - treasuryBefore, claimPenalty);
        assertEq(vaultBefore - DUST.balanceOf(DUST_VAULT), gross);

        (uint256 exitPenalty, uint256 exitNet) = ClaimReformModel.timedExit(combinedPrincipal, remaining);
        ExitSnapshot memory beforeExit = _snapshotExit(user2);

        vm.prank(user2);
        dustLock.earlyWithdraw(tokenId);

        _assertExitDeltas(beforeExit, user2, combinedPrincipal, exitPenalty, exitNet);
        assertEq(DUST.balanceOf(BURN_WALLET) - treasuryBefore, claimPenalty + exitPenalty);
    }

    function testFuzzSplitExitRoundingIsBoundedAndRoutesBothPenalties(
        uint96 rawAmount,
        uint96 rawFirstPart,
        uint32 rawElapsed
    ) public {
        uint256 amount = bound(uint256(rawAmount), 2 * MIN_LOCK_AMOUNT, TOKEN_1M);
        uint256 firstPart = bound(uint256(rawFirstPart), MIN_LOCK_AMOUNT, amount - MIN_LOCK_AMOUNT);
        uint256 tokenId = dustLock.createLock(amount, MAXTIME);
        IDustLock.LockedBalance memory created = dustLock.locked(tokenId);
        uint256 elapsed = bound(uint256(rawElapsed), 0, created.end - block.timestamp - 1);
        skipAndRoll(elapsed);
        _skipEpochBoundaryIfNeeded();

        uint256 unsplitPenalty = dustLock.earlyWithdrawPenaltyAmount(tokenId);
        dustLock.toggleSplit(user, true);
        (uint256 first, uint256 second) = dustLock.split(tokenId, firstPart);
        uint256 firstPenalty = dustLock.earlyWithdrawPenaltyAmount(first);
        uint256 secondPenalty = dustLock.earlyWithdrawPenaltyAmount(second);
        uint256 treasuryBefore = DUST.balanceOf(BURN_WALLET);

        assertGe(firstPenalty + secondPenalty, unsplitPenalty);
        assertLe(firstPenalty + secondPenalty, unsplitPenalty + 1);
        dustLock.earlyWithdraw(first);
        dustLock.earlyWithdraw(second);

        assertEq(DUST.balanceOf(BURN_WALLET) - treasuryBefore, firstPenalty + secondPenalty);
    }

    function testFuzzMergePenaltyReductionIsBoundedToOneAggregationWei(
        uint96 rawFirstAmount,
        uint96 rawSecondAmount,
        uint32 rawFirstDuration,
        uint32 rawSecondDuration
    ) public {
        uint256 firstAmount = bound(uint256(rawFirstAmount), MIN_LOCK_AMOUNT, TOKEN_1M);
        uint256 secondAmount = bound(uint256(rawSecondAmount), MIN_LOCK_AMOUNT, TOKEN_1M);
        uint256 firstDuration = bound(uint256(rawFirstDuration), MINTIME + WEEK, MAXTIME);
        uint256 secondDuration = bound(uint256(rawSecondDuration), MINTIME + WEEK, MAXTIME);
        uint256 first = dustLock.createLock(firstAmount, firstDuration);
        uint256 second = dustLock.createLock(secondAmount, secondDuration);
        uint256 expectedEnd = Math.max(dustLock.locked(first).end, dustLock.locked(second).end);
        uint256 separatePenalty =
            dustLock.earlyWithdrawPenaltyAmount(first) + dustLock.earlyWithdrawPenaltyAmount(second);

        dustLock.merge(first, second);

        IDustLock.LockedBalance memory merged = dustLock.locked(second);
        assertEq(uint256(merged.amount), firstAmount + secondAmount);
        assertEq(merged.end, expectedEnd);
        assertGe(dustLock.earlyWithdrawPenaltyAmount(second) + 1, separatePenalty);
    }

    function testMergeCanRemoveExactlyOneIndependentPenaltyRoundingWei() public {
        _warpToWeekPhase(1);
        uint256 first = dustLock.createLock(TOKEN_1 + 1, MAXTIME);
        uint256 second = dustLock.createLock(TOKEN_1 + 3, MAXTIME);
        uint256 separatePenalty =
            dustLock.earlyWithdrawPenaltyAmount(first) + dustLock.earlyWithdrawPenaltyAmount(second);

        dustLock.merge(first, second);

        uint256 mergedPenalty = dustLock.earlyWithdrawPenaltyAmount(second);
        assertEq(separatePenalty - mergedPenalty, 1);
    }

    function testFuzzTransferDoesNotChangeQuote(uint96 rawAmount, uint32 rawDuration, uint32 rawElapsed) public {
        uint256 amount = bound(uint256(rawAmount), MIN_LOCK_AMOUNT, TOKEN_1M);
        uint256 duration = bound(uint256(rawDuration), MINTIME + WEEK, MAXTIME);
        uint256 tokenId = dustLock.createLock(amount, duration);
        IDustLock.LockedBalance memory created = dustLock.locked(tokenId);
        uint256 elapsed = bound(uint256(rawElapsed), 0, created.end - block.timestamp);
        skipAndRoll(elapsed);
        _skipEpochBoundaryIfNeeded();
        uint256 quoteBefore = dustLock.earlyWithdrawPenaltyAmount(tokenId);

        dustLock.transferFrom(user, user2, tokenId);

        assertEq(dustLock.earlyWithdrawPenaltyAmount(tokenId), quoteBefore);
        assertEq(dustLock.ownerOf(tokenId), user2);
    }

    function testFuzzPermanentExitMatchesIndependentModel(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), MIN_LOCK_AMOUNT, TOKEN_1M);
        uint256 tokenId = dustLock.createLockPermanent(amount, MAXTIME);

        // The one-step path auto-unlocks internally and charges the fresh weekly-rounded end price.
        (uint256 expectedPenalty, uint256 expectedNet) = ClaimReformModel.permanentExit(amount, block.timestamp);
        ExitSnapshot memory beforeExit = _snapshotExit(user);

        assertEq(dustLock.earlyWithdrawPenaltyAmount(tokenId), expectedPenalty);
        dustLock.earlyWithdraw(tokenId);

        _assertExitDeltas(beforeExit, user, amount, expectedPenalty, expectedNet);
        assertEq(dustLock.permanentLockBalance(), 0);
    }

    /**
     * @notice Keeps pricing-only action fuzz cases outside the dedicated finalization second
     */
    function _skipEpochBoundaryIfNeeded() internal {
        if (block.timestamp != 0 && block.timestamp % WEEK == 0) skipAndRoll(1);
    }
}
