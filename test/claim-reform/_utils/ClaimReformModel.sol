// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title ClaimReformModel
 * @author Neverland
 * @notice Independent integer oracle for NGV-05 claim and early-exit economics
 * @dev This test-only library intentionally imports no Neverland production contract.
 */
library ClaimReformModel {
    /// @dev Minimum eligible timed commitment in seconds
    uint256 internal constant MIN_COMMITMENT = 28 days;

    /// @dev Maximum eligible timed commitment in seconds
    uint256 internal constant MAX_COMMITMENT = 365 days;

    /// @dev DustLock unlock-time rounding unit
    uint256 internal constant WEEK = 1 weeks;

    /**
     * @notice Calculates the instant-claim penalty and user proceeds
     * @param gross Gross DUST claim amount
     * @return penalty Exact remainder routed to the burn wallet
     * @return net User liquid proceeds
     */
    function instantClaim(uint256 gross) internal pure returns (uint256 penalty, uint256 net) {
        penalty = gross / 2;
        net = gross - penalty;
    }

    /**
     * @notice Calculates timed-claim penalty and locked proceeds
     * @param gross Gross DUST claim amount
     * @param commitment Realized commitment duration in seconds
     * @return penalty Exact remainder routed to the burn wallet
     * @return net User locked proceeds
     */
    function timedClaim(uint256 gross, uint256 commitment) internal pure returns (uint256 penalty, uint256 net) {
        // Commitments in the top week band are untolled, matching the strategy's ZERO_TOLL_COMMITMENT.
        if (commitment >= MAX_COMMITMENT - WEEK) return (0, gross);

        net = Math.mulDiv(
            gross, 3 * MAX_COMMITMENT - 5 * MIN_COMMITMENT + 2 * commitment, 5 * (MAX_COMMITMENT - MIN_COMMITMENT)
        );
        penalty = gross - net;
    }

    /**
     * @notice Calculates timed early-exit penalty and liquid proceeds
     * @param amount Locked DUST principal
     * @param remaining Actual remaining lock duration in seconds
     * @return penalty Exact remainder routed to the burn wallet
     * @return net User liquid proceeds
     */
    function timedExit(uint256 amount, uint256 remaining) internal pure returns (uint256 penalty, uint256 net) {
        if (remaining == 0) return (0, amount);

        remaining = Math.min(remaining, MAX_COMMITMENT);
        net = Math.mulDiv(amount, 3 * MAX_COMMITMENT - 2 * remaining, 4 * MAX_COMMITMENT);
        penalty = amount - net;
    }

    /**
     * @notice Calculates the permanent early-exit price on the direct route's timed pricing path
     * @dev DustLock.earlyWithdraw handles permanent positions by internally invoking `_unlockPermanent`
     *      before settlement, writing a fresh weekly-rounded ~MAXTIME end at `timestamp` and pricing
     *      the exit on the timed curve at that remaining. This models that direct one-call route;
     *      the identical price applies to a manual unlockPermanent + earlyWithdraw sequence.
     * @param amount Locked DUST principal
     * @param timestamp Exit timestamp (determines the fresh rounded end)
     * @return penalty Exact remainder routed to the burn wallet
     * @return net User liquid proceeds
     */
    function permanentExit(uint256 amount, uint256 timestamp) internal pure returns (uint256 penalty, uint256 net) {
        uint256 freshRemaining = realizedCommitment(timestamp, MAX_COMMITMENT);

        return timedExit(amount, freshRemaining);
    }

    /**
     * @notice Calculates proceeds from honestly selecting the elapsed commitment
     * @param gross Gross DUST claim amount
     * @param elapsed Elapsed time before the modeled break
     * @return net Honest instant or timed claim proceeds
     */
    function honestClaimNet(uint256 gross, uint256 elapsed) internal pure returns (uint256 net) {
        if (elapsed < MIN_COMMITMENT) {
            (, net) = instantClaim(gross);

            return net;
        }

        (, net) = timedClaim(gross, elapsed);
    }

    /**
     * @notice Applies DustLock weekly end rounding to a requested duration
     * @param timestamp Claim timestamp
     * @param requested Requested commitment duration in seconds
     * @return commitment Realized commitment duration in seconds
     */
    function realizedCommitment(uint256 timestamp, uint256 requested) internal pure returns (uint256 commitment) {
        uint256 unlockTime = ((timestamp + requested) / WEEK) * WEEK;

        return unlockTime - timestamp;
    }
}
