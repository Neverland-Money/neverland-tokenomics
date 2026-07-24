// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IDustLock} from "../../../src/interfaces/IDustLock.sol";

import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";

import {DustLock} from "../../../src/tokens/DustLock.sol";
import {BaseTestLocal} from "../../BaseTestLocal.sol";

contract DustLockExitPricingTest is BaseTestLocal {
    using Math for uint256;

    function _setUp() internal override {
        mintErc20Token(address(DUST), user, TOKEN_100K);
        DUST.approve(address(dustLock), type(uint256).max);
    }

    /**
     * @notice Calculates the independent expected penalty for a timed position
     * @param amount Locked DUST principal
     * @param remaining Actual remaining duration in seconds
     * @return penalty Exact expected penalty remainder
     */
    function _expectedTimedPenalty(uint256 amount, uint256 remaining) internal pure returns (uint256 penalty) {
        return _expectedTimedPenaltyAt(amount, remaining, 7_500);
    }

    /**
     * @notice Calculates the independent expected timed penalty at an arbitrary curve maximum
     * @param amount Locked DUST principal
     * @param remaining Actual remaining duration in seconds
     * @param scalar Curve maximum in basis points (the earlyWithdrawPenalty storage value)
     * @return penalty Exact expected penalty remainder
     */
    function _expectedTimedPenaltyAt(uint256 amount, uint256 remaining, uint256 scalar)
        internal
        pure
        returns (uint256 penalty)
    {
        if (remaining == 0) return 0;
        remaining = Math.min(remaining, MAXTIME);
        uint256 numerator = 2_500 * MAXTIME + (scalar - 2_500) * remaining;
        uint256 net = Math.mulDiv(amount, BASIS_POINTS * MAXTIME - numerator, BASIS_POINTS * MAXTIME);

        return amount - net;
    }

    /**
     * @notice Returns a lock's nonnegative actual remaining duration
     * @param lock Lock record being measured
     * @return remaining Actual remaining duration in seconds
     */
    function _remaining(IDustLock.LockedBalance memory lock) internal view returns (uint256 remaining) {
        return lock.end > block.timestamp ? lock.end - block.timestamp : 0;
    }

    function testVersionCapabilityAndInterfaceBoundary() public view {
        assertEq(DustLock(address(dustLock)).version(), "2.1.0");
        assertEq(dustLock.earlyWithdrawPenaltyAmount(0), 0);
        assertEq(dustLock.earlyWithdrawPenaltyAmount(type(uint256).max), 0);
        assertEq(type(IDustLock).interfaceId, bytes4(0xef81dd26));
        assertTrue(dustLock.supportsInterface(type(IDustLock).interfaceId));
        assertTrue(dustLock.supportsInterface(0xda287a1d));
    }

    function testTimedQuoteMatchesActionAndRoutesExactPenalty() public {
        uint256 amount = TOKEN_10K;
        dustLock.setEarlyWithdrawTreasury(user3);
        uint256 tokenId = dustLock.createLock(amount, MAXTIME);
        skipAndRoll(MAXTIME / 2);

        IDustLock.LockedBalance memory lock = dustLock.locked(tokenId);
        uint256 expectedPenalty = _expectedTimedPenalty(amount, _remaining(lock));
        uint256 quotedPenalty = dustLock.earlyWithdrawPenaltyAmount(tokenId);
        assertEq(quotedPenalty, expectedPenalty);

        uint256 ownerBefore = DUST.balanceOf(user);
        uint256 treasuryBefore = DUST.balanceOf(dustLock.earlyWithdrawTreasury());
        uint256 totalSupplyBefore = DUST.totalSupply();
        uint256 lockedSupplyBefore = dustLock.supply();

        dustLock.earlyWithdraw(tokenId);

        assertEq(DUST.balanceOf(user) - ownerBefore, amount - quotedPenalty);
        assertEq(DUST.balanceOf(dustLock.earlyWithdrawTreasury()) - treasuryBefore, quotedPenalty);
        assertEq(DUST.totalSupply(), totalSupplyBefore);
        assertEq(lockedSupplyBefore - dustLock.supply(), amount);
        assertEq(dustLock.locked(tokenId).amount, 0);
        vm.expectRevert(CommonChecksLibrary.InvalidTokenId.selector);
        dustLock.ownerOf(tokenId);
    }

    function testEffectiveStartDoesNotPriceExitButPenaltyScalarDoes() public {
        uint256 amount = TOKEN_1K;
        uint256 first = dustLock.createLock(amount, MAXTIME);
        skipAndRoll(1 days);
        uint256 second = dustLock.createLock(amount, MAXTIME - 1 days);

        IDustLock.LockedBalance memory firstLock = dustLock.locked(first);
        IDustLock.LockedBalance memory secondLock = dustLock.locked(second);
        assertEq(firstLock.end, secondLock.end);
        assertNotEq(firstLock.effectiveStart, secondLock.effectiveStart);
        assertEq(dustLock.earlyWithdrawPenaltyAmount(first), dustLock.earlyWithdrawPenaltyAmount(second));

        // Differing effectiveStart never prices the exit: matching end and amount yield matching quotes.
        uint256 quoteBefore = dustLock.earlyWithdrawPenaltyAmount(first);

        // The penalty scalar does price the exit: lowering the curve maximum reprices both locks downward.
        dustLock.setEarlyWithdrawPenalty(5_000);
        dustLock.setEarlyWithdrawTreasury(user3);
        assertEq(dustLock.earlyWithdrawPenaltyAmount(first), dustLock.earlyWithdrawPenaltyAmount(second));
        assertLt(dustLock.earlyWithdrawPenaltyAmount(first), quoteBefore);
    }

    function testPenaltyScalarSetsPermanentAndTimedCurveMaximum() public {
        uint256 amount = TOKEN_1K;
        dustLock.setEarlyWithdrawPenalty(6_000);
        vm.warp(13 days);
        vm.roll(block.number + 1);

        /*
         * Permanent exit quotes the two-step path; at this timestamp the fresh rounded end realizes
         * exactly MAXTIME remaining, so the quote equals the scalar (60%).
         */
        uint256 permanentId = dustLock.createLock(amount, MAXTIME);
        dustLock.lockPermanent(permanentId);
        assertEq(dustLock.earlyWithdrawPenaltyAmount(permanentId), amount * 6 / 10);

        // Timed exit at maximum remaining duration tops out at the scalar (60%).
        uint256 timedId = dustLock.createLock(amount, MAXTIME);
        IDustLock.LockedBalance memory lock = dustLock.locked(timedId);
        assertEq(lock.end - block.timestamp, MAXTIME);
        assertEq(dustLock.earlyWithdrawPenaltyAmount(timedId), amount * 6 / 10);

        // The maximum is reached only at full remaining; a shorter remaining prices strictly below 60%.
        vm.warp(lock.end - MINTIME);
        vm.roll(block.number + 1);
        assertLt(dustLock.earlyWithdrawPenaltyAmount(timedId), amount * 6 / 10);
    }

    function testPenaltyScalarBoundaryValues() public {
        uint256 amount = TOKEN_1K;
        vm.warp(13 days);
        vm.roll(block.number + 1);
        uint256 tokenId = dustLock.createLock(amount, MAXTIME);
        dustLock.lockPermanent(tokenId);

        // Floor scalar (2_500 bps) prices the permanent two-step quote at exactly 25% (fresh end realizes MAXTIME here).
        dustLock.setEarlyWithdrawPenalty(2_500);
        assertEq(dustLock.earlyWithdrawPenaltyAmount(tokenId), amount / 4);

        // Ceiling scalar (9_999 bps) prices the permanent two-step quote at exactly 99.99%.
        dustLock.setEarlyWithdrawPenalty(9_999);
        assertEq(dustLock.earlyWithdrawPenaltyAmount(tokenId), amount - amount / 10_000);
    }

    function testPermanentExitAutoUnlocksAndPricesAtFreshWeeklyEnd() public {
        uint256 amount = TOKEN_1K;
        dustLock.setEarlyWithdrawTreasury(user3);
        uint256 tokenId = dustLock.createLock(amount, MAXTIME);
        dustLock.lockPermanent(tokenId);

        /*
         * The quote prices the fresh weekly-rounded end that the internal unlock writes, identical
         * to calling unlockPermanent and then earlyWithdraw as two manual steps.
         */
        uint256 freshRemaining = ((block.timestamp + MAXTIME) / 1 weeks) * 1 weeks - block.timestamp;
        uint256 expectedPenalty = _expectedTimedPenalty(amount, freshRemaining);
        assertEq(dustLock.earlyWithdrawPenaltyAmount(tokenId), expectedPenalty);
        uint256 expectedNet = amount - expectedPenalty;

        uint256 ownerBefore = DUST.balanceOf(user);
        uint256 treasuryBefore = DUST.balanceOf(dustLock.earlyWithdrawTreasury());
        uint256 totalSupplyBefore = DUST.totalSupply();
        assertEq(dustLock.permanentLockBalance(), amount);

        dustLock.earlyWithdraw(tokenId);

        assertEq(DUST.balanceOf(user) - ownerBefore, expectedNet);
        assertEq(DUST.totalSupply(), totalSupplyBefore);
        assertEq(DUST.balanceOf(dustLock.earlyWithdrawTreasury()) - treasuryBefore, expectedPenalty);
        assertEq(dustLock.permanentLockBalance(), 0);
    }

    function testEarlyWithdrawMaxPenaltyBindsPermanentExitAcrossSawtooth() public {
        uint256 amount = TOKEN_1K;
        dustLock.setEarlyWithdrawTreasury(user3);
        uint256 tokenId = dustLock.createLock(amount, MAXTIME);
        dustLock.lockPermanent(tokenId);

        // Just below the 6-day weekly mark the fresh end is 52 weeks out; just at it, 53 weeks.
        vm.warp(2 weeks + 6 days - 1);
        vm.roll(block.number + 1);
        uint256 quoteBelow = dustLock.earlyWithdrawPenaltyAmount(tokenId);

        // One second later the fresh end jumps a week and the penalty steps up.
        vm.warp(2 weeks + 6 days);
        vm.roll(block.number + 1);
        uint256 quoteAbove = dustLock.earlyWithdrawPenaltyAmount(tokenId);
        assertGt(quoteAbove, quoteBelow);

        // The bound reverts before any state change when the execution-time penalty exceeds it.
        vm.expectRevert(abi.encodeWithSelector(IDustLock.EarlyWithdrawPenaltyAboveMax.selector, quoteAbove, quoteBelow));
        dustLock.earlyWithdraw(tokenId, quoteBelow);
        assertTrue(dustLock.locked(tokenId).isPermanent);

        // Binding at the execution-time quote succeeds and charges exactly it.
        dustLock.earlyWithdraw(tokenId, quoteAbove);
        assertEq(DUST.balanceOf(user3), quoteAbove);
        assertEq(dustLock.permanentLockBalance(), 0);
    }

    function testEarlyWithdrawMaxPenaltyBindsTimedExit() public {
        uint256 amount = TOKEN_1K;
        dustLock.setEarlyWithdrawTreasury(user3);
        uint256 tokenId = dustLock.createLock(amount, MAXTIME);

        uint256 quote = dustLock.earlyWithdrawPenaltyAmount(tokenId);
        assertGt(quote, 0);

        vm.expectRevert(abi.encodeWithSelector(IDustLock.EarlyWithdrawPenaltyAboveMax.selector, quote, 0));
        dustLock.earlyWithdraw(tokenId, 0);

        // An at-quote bound admits the exit with identical proceeds to the unbounded call.
        uint256 userBefore = DUST.balanceOf(user);
        dustLock.earlyWithdraw(tokenId, quote);
        assertEq(DUST.balanceOf(user3), quote);
        assertEq(DUST.balanceOf(user) - userBefore, amount - quote);
    }

    function testMatureTimedExitHasNoPenalty() public {
        uint256 amount = TOKEN_1K;
        uint256 tokenId = dustLock.createLock(amount, 29 weeks);
        IDustLock.LockedBalance memory lock = dustLock.locked(tokenId);
        vm.warp(lock.end);
        vm.roll(block.number + 1);

        assertEq(dustLock.earlyWithdrawPenaltyAmount(tokenId), 0);
        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        dustLock.earlyWithdraw(tokenId);

        vm.warp(lock.end + 1);
        vm.roll(block.number + 1);
        uint256 ownerBefore = DUST.balanceOf(user);
        uint256 totalSupplyBefore = DUST.totalSupply();
        dustLock.earlyWithdraw(tokenId);
        assertEq(DUST.balanceOf(user) - ownerBefore, amount);
        assertEq(DUST.totalSupply(), totalSupplyBefore);
    }

    function testTimedQuoteExplicitRemainingSecondBoundaries() public {
        vm.warp(13 days);
        vm.roll(block.number + 1);
        uint256 amount = TOKEN_1K;
        uint256 tokenId = dustLock.createLock(amount, MAXTIME);
        IDustLock.LockedBalance memory lock = dustLock.locked(tokenId);
        assertEq(lock.end - block.timestamp, MAXTIME);

        uint256[5] memory remaining = [MAXTIME, 364 days, MINTIME, uint256(1), uint256(0)];
        for (uint256 i; i < remaining.length; ++i) {
            vm.warp(lock.end - remaining[i]);
            vm.roll(block.number + 1);
            assertEq(dustLock.earlyWithdrawPenaltyAmount(tokenId), _expectedTimedPenalty(amount, remaining[i]));
        }
    }

    function testApprovedCallerRoutesProceedsToOwner() public {
        uint256 amount = TOKEN_1K;
        uint256 tokenId = dustLock.createLockFor(amount, MAXTIME, user2);
        uint256 penalty = dustLock.earlyWithdrawPenaltyAmount(tokenId);
        vm.prank(user2);
        dustLock.approve(user3, tokenId);

        uint256 ownerBefore = DUST.balanceOf(user2);
        uint256 callerBefore = DUST.balanceOf(user3);
        vm.prank(user3);
        dustLock.earlyWithdraw(tokenId);

        assertEq(DUST.balanceOf(user2) - ownerBefore, amount - penalty);
        assertEq(DUST.balanceOf(user3), callerBefore);
    }

    function testSplitCannotUnderallocatePenaltyRelativeToOriginalLock() public {
        uint256 amount = 20 * TOKEN_1;
        uint256 tokenId = dustLock.createLock(amount, MAXTIME);
        skipAndRoll(13 weeks);
        uint256 unsplitPenalty = dustLock.earlyWithdrawPenaltyAmount(tokenId);

        dustLock.toggleSplit(user, true);
        (uint256 first, uint256 second) = dustLock.split(tokenId, 7 * TOKEN_1);
        uint256 splitPenalty = dustLock.earlyWithdrawPenaltyAmount(first) + dustLock.earlyWithdrawPenaltyAmount(second);

        assertGe(splitPenalty, unsplitPenalty);
        assertEq(dustLock.locked(first).end, dustLock.locked(second).end);
    }

    function testFuzzTimedQuoteUsesRemainingDuration(uint128 rawAmount, uint32 rawElapsed) public {
        uint256 amount = bound(uint256(rawAmount), MIN_LOCK_AMOUNT, TOKEN_100K);
        uint256 tokenId = dustLock.createLock(amount, MAXTIME);
        IDustLock.LockedBalance memory original = dustLock.locked(tokenId);
        uint256 elapsed = bound(uint256(rawElapsed), 0, original.end - block.timestamp);
        skipAndRoll(elapsed);

        uint256 remaining = _remaining(dustLock.locked(tokenId));
        uint256 quote = dustLock.earlyWithdrawPenaltyAmount(tokenId);
        assertEq(quote, _expectedTimedPenalty(amount, remaining));
        assertLe(quote, amount * 3 / 4 + 1);
    }

    function testFuzzPenaltyScalarParameterizesTheWholeCurve(uint128 rawAmount, uint32 rawElapsed, uint16 rawScalar)
        public
    {
        uint256 amount = bound(uint256(rawAmount), MIN_LOCK_AMOUNT, TOKEN_100K);
        uint256 scalar = bound(uint256(rawScalar), 2_500, 9_999);
        dustLock.setEarlyWithdrawPenalty(scalar);
        uint256 tokenId = dustLock.createLock(amount, MAXTIME);
        IDustLock.LockedBalance memory original = dustLock.locked(tokenId);
        uint256 elapsed = bound(uint256(rawElapsed), 0, original.end - block.timestamp);
        skipAndRoll(elapsed);

        /*
         * The quote must match the scalar-parameterized model exactly, never exceed the
         * scalar ceiling (plus the round-up wei), and never price below the 25% floor.
         */
        uint256 remaining = _remaining(dustLock.locked(tokenId));
        uint256 quote = dustLock.earlyWithdrawPenaltyAmount(tokenId);
        assertEq(quote, _expectedTimedPenaltyAt(amount, remaining, scalar));
        assertLe(quote, Math.mulDiv(amount, scalar, BASIS_POINTS) + 1);
        if (remaining > 0) assertGe(quote, amount / 4);

        // Raising the scalar can never lower the quote for the same lock state.
        if (scalar < 9_999) {
            dustLock.setEarlyWithdrawPenalty(scalar + 1);
            assertGe(dustLock.earlyWithdrawPenaltyAmount(tokenId), quote);
        }
    }
}
