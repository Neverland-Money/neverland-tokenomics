// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

contract ClaimReformEconomicInvariantTest is Test {
    uint256 internal constant MIN_COMMITMENT = 28 days;
    uint256 internal constant MAX_COMMITMENT = 365 days;
    uint256 internal constant MIN_EXECUTABLE_LOCK = 1 ether;

    /**
     * @notice Calculates timed-claim proceeds from the independent invariant oracle
     * @param gross Gross DUST reward amount
     * @param commitment Realized commitment duration in seconds
     * @return net Exact expected locked proceeds
     */
    function _timedClaimNet(uint256 gross, uint256 commitment) internal pure returns (uint256 net) {
        return Math.mulDiv(
            gross, 3 * MAX_COMMITMENT - 5 * MIN_COMMITMENT + 2 * commitment, 5 * (MAX_COMMITMENT - MIN_COMMITMENT)
        );
    }

    /**
     * @notice Calculates timed-exit proceeds from the independent invariant oracle
     * @param lockedAmount Locked DUST principal
     * @param remaining Actual remaining duration in seconds
     * @return net Exact expected liquid proceeds
     */
    function _timedExitNet(uint256 lockedAmount, uint256 remaining) internal pure returns (uint256 net) {
        if (remaining == 0) return lockedAmount;
        remaining = Math.min(remaining, MAX_COMMITMENT);

        return Math.mulDiv(lockedAmount, 3 * MAX_COMMITMENT - 2 * remaining, 4 * MAX_COMMITMENT);
    }

    /**
     * @notice Calculates proceeds from claiming only after the elapsed honest commitment
     * @param gross Gross DUST reward amount
     * @param elapsed Elapsed commitment duration in seconds
     * @return net Exact expected honest-claim proceeds
     */
    function _honestClaimNet(uint256 gross, uint256 elapsed) internal pure returns (uint256 net) {
        if (elapsed < MIN_COMMITMENT) return gross - gross / 2;

        return _timedClaimNet(gross, elapsed);
    }

    function testFuzzClaimAndExitConserveExactPenalties(uint128 rawGross, uint32 rawCommitment, uint32 rawRemaining)
        public
        pure
    {
        uint256 gross = uint256(rawGross);
        uint256 commitment = bound(uint256(rawCommitment), MIN_COMMITMENT, MAX_COMMITMENT);
        uint256 remaining = bound(uint256(rawRemaining), 0, MAX_COMMITMENT);

        uint256 claimNet = _timedClaimNet(gross, commitment);
        uint256 claimPenalty = gross - claimNet;
        uint256 exitNet = _timedExitNet(claimNet, remaining);
        uint256 exitPenalty = claimNet - exitNet;

        assertEq(claimPenalty + claimNet, gross);
        assertEq(exitPenalty + exitNet, claimNet);
    }

    function testFuzzLongCommitmentThenEarlyExitIsStrictlyWorseAtExecutableAmounts(
        uint128 rawGross,
        uint32 rawCommitment,
        uint32 rawElapsed
    ) public pure {
        uint256 gross = bound(uint256(rawGross), MIN_EXECUTABLE_LOCK, type(uint128).max);
        uint256 commitment = bound(uint256(rawCommitment), MIN_COMMITMENT, MAX_COMMITMENT);
        uint256 elapsed = bound(uint256(rawElapsed), 0, commitment - 1);

        uint256 lockedAmount = _timedClaimNet(gross, commitment);
        uint256 brokenCommitmentNet = _timedExitNet(lockedAmount, commitment - elapsed);
        uint256 honestNet = _honestClaimNet(gross, elapsed);

        assertLt(brokenCommitmentNet, honestNet);
    }

    function testFuzzSplitExitRoundingCannotUnderallocatePenalty(
        uint128 rawAmount,
        uint128 rawFirstPart,
        uint32 rawRemaining
    ) public pure {
        uint256 amount = uint256(rawAmount);
        uint256 firstPart = amount == 0 ? 0 : bound(uint256(rawFirstPart), 0, amount);
        uint256 remaining = bound(uint256(rawRemaining), 1, MAX_COMMITMENT);

        uint256 unsplitPenalty = amount - _timedExitNet(amount, remaining);
        uint256 splitPenalty = firstPart - _timedExitNet(firstPart, remaining)
            + (amount - firstPart - _timedExitNet(amount - firstPart, remaining));

        assertGe(splitPenalty, unsplitPenalty);
    }

    function testMicroscopicEqualityIsDocumentedWithoutAClaimGuard() public pure {
        uint256 gross = 3;
        uint256 commitment = 85 days;
        uint256 elapsed = 28 days;
        uint256 brokenCommitmentNet = _timedExitNet(_timedClaimNet(gross, commitment), commitment - elapsed);

        assertEq(brokenCommitmentNet, _honestClaimNet(gross, elapsed));
        assertEq(brokenCommitmentNet, 1);
    }
}
