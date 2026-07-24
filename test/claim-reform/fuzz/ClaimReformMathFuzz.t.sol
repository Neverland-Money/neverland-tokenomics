// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

import {ClaimReformModel} from "../_utils/ClaimReformModel.sol";

contract ClaimReformMathFuzzTest is Test {
    uint256 internal constant EXECUTABLE_AMOUNT = 1 ether;
    uint256 internal constant MIN_COMMITMENT = 28 days;
    uint256 internal constant MAX_COMMITMENT = 365 days;
    uint256 internal constant WEEK = 1 weeks;

    function testFuzzTimedClaimConservesAndMatchesEndpoints(uint128 rawGross, uint32 rawCommitment) public pure {
        uint256 gross = uint256(rawGross);
        uint256 commitment = bound(uint256(rawCommitment), MIN_COMMITMENT, MAX_COMMITMENT);
        (uint256 penalty, uint256 net) = ClaimReformModel.timedClaim(gross, commitment);

        assertEq(penalty + net, gross);
        assertLe(net, gross);
        if (commitment == MIN_COMMITMENT) assertEq(net, Math.mulDiv(gross, 3, 5));
        if (commitment == MAX_COMMITMENT) assertEq(net, gross);
    }

    function testFuzzTimedClaimNetIsMonotoneBySecond(uint128 rawGross, uint32 rawFirst, uint32 rawSecond) public pure {
        uint256 first = bound(uint256(rawFirst), MIN_COMMITMENT, MAX_COMMITMENT);
        uint256 second = bound(uint256(rawSecond), MIN_COMMITMENT, MAX_COMMITMENT);
        if (first > second) (first, second) = (second, first);

        (, uint256 firstNet) = ClaimReformModel.timedClaim(uint256(rawGross), first);
        (, uint256 secondNet) = ClaimReformModel.timedClaim(uint256(rawGross), second);

        assertGe(secondNet, firstNet);
    }

    function testFuzzTimedExitConservesAndImprovesAsRemainingFalls(uint128 rawAmount, uint32 rawFirst, uint32 rawSecond)
        public
        pure
    {
        uint256 first = bound(uint256(rawFirst), 0, MAX_COMMITMENT);
        uint256 second = bound(uint256(rawSecond), 0, MAX_COMMITMENT);
        if (first > second) (first, second) = (second, first);

        (uint256 firstPenalty, uint256 firstNet) = ClaimReformModel.timedExit(uint256(rawAmount), first);
        (uint256 secondPenalty, uint256 secondNet) = ClaimReformModel.timedExit(uint256(rawAmount), second);

        assertEq(firstPenalty + firstNet, uint256(rawAmount));
        assertEq(secondPenalty + secondNet, uint256(rawAmount));
        assertGe(firstNet, secondNet);
        assertLe(firstPenalty, secondPenalty);
    }

    function testFuzzExtensionCannotReduceExitPenalty(uint128 rawAmount, uint32 rawBefore, uint32 rawAfter)
        public
        pure
    {
        uint256 beforeRemaining = bound(uint256(rawBefore), 1, MAX_COMMITMENT);
        uint256 afterRemaining = bound(uint256(rawAfter), beforeRemaining, MAX_COMMITMENT);
        (uint256 beforePenalty,) = ClaimReformModel.timedExit(uint256(rawAmount), beforeRemaining);
        (uint256 afterPenalty,) = ClaimReformModel.timedExit(uint256(rawAmount), afterRemaining);

        assertGe(afterPenalty, beforePenalty);
    }

    function testFuzzSplitCannotUnderallocateExitPenalty(uint128 rawAmount, uint128 rawFirstPart, uint32 rawRemaining)
        public
        pure
    {
        uint256 amount = uint256(rawAmount);
        uint256 firstPart = amount == 0 ? 0 : bound(uint256(rawFirstPart), 0, amount);
        uint256 remaining = bound(uint256(rawRemaining), 1, MAX_COMMITMENT);
        (uint256 unsplitPenalty,) = ClaimReformModel.timedExit(amount, remaining);
        (uint256 firstPenalty,) = ClaimReformModel.timedExit(firstPart, remaining);
        (uint256 secondPenalty,) = ClaimReformModel.timedExit(amount - firstPart, remaining);

        assertGe(firstPenalty + secondPenalty, unsplitPenalty);
    }

    function testFuzzLongerCommitmentThenBreakNeverBeatsHonestExecutableChoice(
        uint128 rawGross,
        uint32 rawCommitment,
        uint32 rawElapsed
    ) public pure {
        uint256 gross = bound(uint256(rawGross), EXECUTABLE_AMOUNT, type(uint128).max);
        uint256 commitment = bound(uint256(rawCommitment), MIN_COMMITMENT, MAX_COMMITMENT);
        uint256 elapsed = bound(uint256(rawElapsed), 0, commitment - 1);
        (, uint256 lockedAmount) = ClaimReformModel.timedClaim(gross, commitment);
        (, uint256 brokenCommitmentNet) = ClaimReformModel.timedExit(lockedAmount, commitment - elapsed);
        uint256 honestNet = ClaimReformModel.honestClaimNet(gross, elapsed);

        assertLt(brokenCommitmentNet, honestNet);
    }

    function testFuzzWeeklyRoundingNeverCreatesMoreCommitmentThanRequested(uint32 rawTimestamp, uint32 rawRequest)
        public
        pure
    {
        uint256 timestamp = bound(uint256(rawTimestamp), WEEK, type(uint32).max);
        uint256 request = bound(uint256(rawRequest), WEEK, MAX_COMMITMENT);
        uint256 commitment = ClaimReformModel.realizedCommitment(timestamp, request);

        assertLe(commitment, request);
        assertLt(request - commitment, WEEK);
    }

    function testFuzzPermanentExitMatchesFreshEndTimedExit(uint128 rawAmount, uint32 rawTimestamp) public pure {
        uint256 timestamp = bound(uint256(rawTimestamp), WEEK, type(uint32).max);
        (uint256 permanentPenalty, uint256 permanentNet) = ClaimReformModel.permanentExit(uint256(rawAmount), timestamp);

        // The two-step price always sits inside the fresh-end band: net is bounded below by the
        // MAXTIME curve and above by the curve one second above MAXTIME - WEEK.
        (, uint256 floorNet) = ClaimReformModel.timedExit(uint256(rawAmount), MAX_COMMITMENT);
        (, uint256 ceilNet) = ClaimReformModel.timedExit(uint256(rawAmount), MAX_COMMITMENT - WEEK + 1);

        assertGe(permanentNet, floorNet);
        assertLe(permanentNet, ceilNet);
        assertEq(permanentPenalty + permanentNet, uint256(rawAmount));
    }

    function testExhaustiveWholeDayInvariantForExecutableAmount() public pure {
        for (uint256 commitmentDays = 28; commitmentDays <= 365; ++commitmentDays) {
            uint256 commitment = commitmentDays * 1 days;
            (, uint256 lockedAmount) = ClaimReformModel.timedClaim(EXECUTABLE_AMOUNT, commitment);
            for (uint256 elapsedDays; elapsedDays < commitmentDays; ++elapsedDays) {
                (, uint256 brokenCommitmentNet) =
                    ClaimReformModel.timedExit(lockedAmount, (commitmentDays - elapsedDays) * 1 days);
                uint256 honestNet = ClaimReformModel.honestClaimNet(EXECUTABLE_AMOUNT, elapsedDays * 1 days);

                assertLt(brokenCommitmentNet, honestNet);
            }
        }
    }

    function testMicroscopicEqualityAndWrong364DayMutantAreVisible() public pure {
        (, uint256 lockedAmount) = ClaimReformModel.timedClaim(3, 85 days);
        (, uint256 brokenCommitmentNet) = ClaimReformModel.timedExit(lockedAmount, 57 days);

        assertEq(brokenCommitmentNet, ClaimReformModel.honestClaimNet(3, 28 days));

        uint256 wrongMaximum = 364 days;
        uint256 wrongNet = Math.mulDiv(
            EXECUTABLE_AMOUNT,
            3 * wrongMaximum - 5 * MIN_COMMITMENT + 2 * MAX_COMMITMENT,
            5 * (wrongMaximum - MIN_COMMITMENT)
        );
        (, uint256 correctNet) = ClaimReformModel.timedClaim(EXECUTABLE_AMOUNT, MAX_COMMITMENT);

        assertGt(wrongNet, EXECUTABLE_AMOUNT);
        assertEq(correctNet, EXECUTABLE_AMOUNT);
    }
}
