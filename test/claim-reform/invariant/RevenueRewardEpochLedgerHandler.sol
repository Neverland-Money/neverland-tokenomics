// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IRevenueReward} from "../../../src/interfaces/IRevenueReward.sol";
import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";
import {MockERC20} from "../../_utils/MockERC20.sol";

/**
 * @title RevenueRewardEpochLedgerHandler
 * @author Neverland
 * @notice Bounded state machine and independent ghost ledger for RevenueReward epoch accounting
 * @dev The reward model uses fixed permanent-lock weights supplied by the fixture. It never uses
 *      RevenueReward previews or claim outputs as expected values.
 */
contract RevenueRewardEpochLedgerHandler is Test {
    /**
     * @notice Binds the state machine to three immutable real DustLock positions
     * @param revenueReward RevenueReward proxy under test
     * @param rewardToken Exact-transfer ERC20 used as pooled backing
     * @param distributor Authorized reward distributor and source of direct transfers
     * @param actorSet Owners of the three permanent locks
     * @param tokenIdSet Permanent lock identifiers
     * @param weightSet Independently known constant lock weights
     * @param lockMintTimestamp Common fixture timestamp at which the locks were created
     */
    constructor(
        IRevenueReward revenueReward,
        MockERC20 rewardToken,
        address distributor,
        address[3] memory actorSet,
        uint256[3] memory tokenIdSet,
        uint256[3] memory weightSet,
        uint256 lockMintTimestamp
    ) {
        REVENUE_REWARD = revenueReward;
        REWARD_TOKEN = rewardToken;
        DISTRIBUTOR = distributor;
        actors = actorSet;
        tokenIds = tokenIdSet;
        weights = weightSet;

        mintTimestamp = lockMintTimestamp;
        firstRewardEpoch = _epochNext(lockMintTimestamp);
        maxSettlementEpoch = firstRewardEpoch + SETTLEMENT_EPOCH_HORIZON * WEEK;
        maxTimestamp = maxSettlementEpoch + 1;

        uint256 summedWeight;
        for (uint256 i = 0; i < actorSet.length; ++i) {
            assertNotEq(actorSet[i], address(0));
            assertGt(tokenIdSet[i], 0);
            assertGt(weightSet[i], 0);
            summedWeight += weightSet[i];
            initialActorBalances[i] = rewardToken.balanceOf(actorSet[i]);
        }
        totalWeight = summedWeight;
        initialDistributorBalance = rewardToken.balanceOf(distributor);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant WEEK = 7 days;
    uint256 internal constant REMAINDER_SCALE = 1e18;
    uint256 internal constant MAX_NOTIFICATION_AMOUNT = 1e12;
    uint256 internal constant MAX_DIRECT_TRANSFER = 1e12;
    uint256 internal constant SETTLEMENT_EPOCH_HORIZON = 24;

    /*//////////////////////////////////////////////////////////////
                          STORAGE VARIABLES
    //////////////////////////////////////////////////////////////*/

    IRevenueReward internal immutable REVENUE_REWARD;
    MockERC20 internal immutable REWARD_TOKEN;
    address internal immutable DISTRIBUTOR;

    uint256 public immutable mintTimestamp;
    uint256 public immutable firstRewardEpoch;
    uint256 public immutable maxSettlementEpoch;
    uint256 public immutable maxTimestamp;
    uint256 public immutable totalWeight;
    uint256 public immutable initialDistributorBalance;

    address[3] internal actors;
    uint256[3] internal tokenIds;
    uint256[3] internal weights;
    uint256[3] internal initialActorBalances;

    mapping(uint256 => uint256) public ghostEpochRewards;

    uint256[3] internal ghostPaidByToken;
    uint256[3] internal ghostLastEarnTime;
    uint256[3] internal ghostRemainderScaled;

    uint256 public ghostTotalNotified;
    uint256 public ghostTotalPaid;
    uint256 public ghostDirectTransfers;
    uint256 public ghostRecovered;

    uint256 public totalCalls;
    uint256 public ordinaryNotificationSuccesses;
    uint256 public followingNotificationSuccesses;
    uint256 public advanceTimeSuccesses;
    uint256 public settlementAttempts;
    uint256 public settlementProgresses;
    uint256 public settlementNoops;
    uint256 public exactBoundaryAttempts;
    uint256 public exactBoundaryDeferrals;
    uint256 public recoveryAttempts;
    uint256 public successfulRecoverCalls;
    uint256 public recoveryTransfers;
    uint256 public preconditionSkips;

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Credits a bounded exact-transfer amount to the ordinary E+1 bucket
    function actionNotifyOrdinary(uint256 rawAmount) external {
        ++totalCalls;
        uint256 amount = _boundedPositive(rawAmount, MAX_NOTIFICATION_AMOUNT);
        uint256 targetEpoch = _epochNext(block.timestamp);

        vm.prank(DISTRIBUTOR);
        REVENUE_REWARD.notifyRewardAmount(address(REWARD_TOKEN), amount);

        _creditGhostEpoch(targetEpoch, amount);
        ++ordinaryNotificationSuccesses;
        _assertNotificationState(targetEpoch);
    }

    /// @notice Credits a bounded exact-transfer amount to the following E+2 bucket
    function actionNotifyFollowing(uint256 rawAmount) external {
        ++totalCalls;
        uint256 amount = _boundedPositive(rawAmount, MAX_NOTIFICATION_AMOUNT);
        uint256 targetEpoch = _epochNext(block.timestamp) + WEEK;

        vm.prank(DISTRIBUTOR);
        REVENUE_REWARD.notifyRewardAmountForFollowingEpoch(address(REWARD_TOKEN), amount);

        _creditGhostEpoch(targetEpoch, amount);
        ++followingNotificationSuccesses;
        _assertNotificationState(targetEpoch);
    }

    /// @notice Moves time forward within a fixed epoch horizon so deep invariant profiles stay bounded
    function actionAdvanceTime(uint256 rawEpochSteps, uint256 rawPhase) external {
        ++totalCalls;
        ++advanceTimeSuccesses;
        if (block.timestamp >= maxTimestamp) return;

        uint256 epochSteps = _boundedPositive(rawEpochSteps, 3);
        uint256 phaseSeed = rawPhase % 3;
        uint256 phase = phaseSeed == 0 ? 1 : phaseSeed == 1 ? WEEK / 2 : WEEK - 1;
        uint256 target = _epochStart(block.timestamp) + epochSteps * WEEK + phase;
        if (target > maxTimestamp) target = maxTimestamp;
        if (target <= block.timestamp) target = block.timestamp + 1;

        vm.warp(target);
        vm.roll(block.number + 1);
    }

    /**
     * @notice Settles one lock at a randomized finalized historical/current epoch endpoint
     * @dev Repeated or backwards endpoints are deliberate successful no-ops. At exact T, the
     *      expected EpochFinalizationPending revert is caught and atomicity is asserted.
     */
    function actionSettle(uint256 rawActor, uint256 rawEpoch, uint256 rawPhase) external {
        ++totalCalls;
        ++settlementAttempts;
        uint256 actorIndex = rawActor % actors.length;

        if (block.timestamp % WEEK == 0) {
            _assertExactBoundaryDeferral(actorIndex, block.timestamp);
            return;
        }
        if (ghostTotalNotified == 0) {
            ++preconditionSkips;
            return;
        }

        uint256 latestEpoch = _epochStart(block.timestamp);
        if (latestEpoch < firstRewardEpoch) {
            ++preconditionSkips;
            return;
        }

        uint256 epochCount = (latestEpoch - firstRewardEpoch) / WEEK + 1;
        uint256 selectedEpoch = firstRewardEpoch + (rawEpoch % epochCount) * WEEK;
        uint256 maxPhase = block.timestamp - selectedEpoch;
        if (maxPhase > WEEK - 1) maxPhase = WEEK - 1;
        uint256 phase = _boundedPositive(rawPhase, maxPhase);

        _settle(actorIndex, selectedEpoch + phase);
    }

    /// @notice Warps to an exact nonzero epoch boundary and proves claim deferral is atomic
    function actionExactBoundaryDeferral(uint256 rawActor) external {
        ++totalCalls;
        ++exactBoundaryAttempts;
        uint256 boundary = block.timestamp % WEEK == 0 ? block.timestamp : _epochNext(block.timestamp);
        if (boundary > maxSettlementEpoch) {
            ++preconditionSkips;
            return;
        }

        vm.warp(boundary);
        vm.roll(block.number + 1);
        _assertExactBoundaryDeferral(rawActor % actors.length, boundary);
    }

    /**
     * @notice Sends unnotified backing then invokes the conservative lifetime-credit recovery path
     * @dev A meaningful sweep occurs only after direct transfers exceed historical paid rewards.
     */
    function actionRecover(uint256 rawAmount) external {
        ++totalCalls;
        ++recoveryAttempts;
        if (ghostTotalNotified == 0) {
            ++preconditionSkips;
            return;
        }

        uint256 amount = _boundedPositive(rawAmount, MAX_DIRECT_TRANSFER);
        uint256 distributorBefore = REWARD_TOKEN.balanceOf(DISTRIBUTOR);
        uint256 balanceBefore = expectedContractBalance();
        assertEq(REWARD_TOKEN.balanceOf(address(REVENUE_REWARD)), balanceBefore);

        vm.prank(DISTRIBUTOR);
        assertTrue(REWARD_TOKEN.transfer(address(REVENUE_REWARD), amount));
        ghostDirectTransfers += amount;

        uint256 balanceWithTransfer = balanceBefore + amount;
        uint256 expectedRecovery =
            balanceWithTransfer > ghostTotalNotified ? balanceWithTransfer - ghostTotalNotified : 0;

        vm.prank(DISTRIBUTOR);
        REVENUE_REWARD.recoverTokens();

        ghostRecovered += expectedRecovery;
        ++successfulRecoverCalls;
        if (expectedRecovery != 0) ++recoveryTransfers;

        assertEq(
            REWARD_TOKEN.balanceOf(DISTRIBUTOR),
            distributorBefore - amount + expectedRecovery,
            "recovery distributor delta"
        );
        assertEq(REWARD_TOKEN.balanceOf(address(REVENUE_REWARD)), expectedContractBalance(), "recovery pool delta");
        assertGe(REWARD_TOKEN.balanceOf(address(REVENUE_REWARD)), ghostOutstanding(), "recovery touched liability");
    }

    /*//////////////////////////////////////////////////////////////
                          INDEPENDENT MODEL
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Computes and applies one modeled settlement before reconciling the real transfer
     * @param actorIndex Fixed lock/owner index
     * @param endTs Historical or current non-boundary settlement endpoint
     */
    function _settle(uint256 actorIndex, uint256 endTs) internal {
        uint256 balanceBefore = REWARD_TOKEN.balanceOf(actors[actorIndex]);
        uint256 cursorBefore = ghostLastEarnTime[actorIndex];
        (bool processed, uint256 expectedPayout, uint256 expectedRemainder) = _modelSettlement(actorIndex, endTs);

        vm.prank(actors[actorIndex]);
        REVENUE_REWARD.getRewardUntilTs(tokenIds[actorIndex], _rewardTokens(), endTs);

        if (processed) {
            ghostLastEarnTime[actorIndex] = endTs;
            ghostRemainderScaled[actorIndex] = expectedRemainder;
            ghostPaidByToken[actorIndex] += expectedPayout;
            ghostTotalPaid += expectedPayout;
            ++settlementProgresses;
        } else {
            ++settlementNoops;
        }

        assertGe(ghostLastEarnTime[actorIndex], cursorBefore, "ghost cursor regressed");
        assertEq(REWARD_TOKEN.balanceOf(actors[actorIndex]) - balanceBefore, expectedPayout, "modeled payout mismatch");
        assertEq(
            REVENUE_REWARD.lastEarnTime(address(REWARD_TOKEN), tokenIds[actorIndex]),
            ghostLastEarnTime[actorIndex],
            "modeled cursor mismatch"
        );
        assertEq(
            REVENUE_REWARD.tokenRewardsRemainingAccScaled(address(REWARD_TOKEN), tokenIds[actorIndex]),
            ghostRemainderScaled[actorIndex],
            "modeled remainder mismatch"
        );
    }

    /**
     * @notice Reproduces the epoch walk using only ghost buckets and fixed known weights
     * @dev Bounded reward amounts make direct multiplication safe, avoiding production Math helpers.
     * @param actorIndex Fixed lock/owner index
     * @param endTs Historical or current non-boundary settlement endpoint
     * @return processed True when at least one finalized epoch was walked
     * @return payout Modeled whole-unit transfer amount including realized remainder carry
     * @return finalRemainder Scaled sub-unit remainder carried forward after settlement
     */
    function _modelSettlement(uint256 actorIndex, uint256 endTs)
        internal
        view
        returns (bool processed, uint256 payout, uint256 finalRemainder)
    {
        uint256 effectiveCursor = ghostLastEarnTime[actorIndex];
        if (mintTimestamp > effectiveCursor) effectiveCursor = mintTimestamp;
        uint256 startEpoch = _epochNext(effectiveCursor);
        uint256 endEpoch = _epochStart(endTs);
        if (startEpoch > endEpoch) return (false, 0, ghostRemainderScaled[actorIndex]);

        uint256 accumulatedRemainder = ghostRemainderScaled[actorIndex];
        for (uint256 epoch = startEpoch; epoch <= endEpoch; epoch += WEEK) {
            uint256 numerator = ghostEpochRewards[epoch] * weights[actorIndex];
            payout += numerator / totalWeight;
            uint256 rawRemainder = numerator % totalWeight;
            accumulatedRemainder += rawRemainder * REMAINDER_SCALE / totalWeight;
        }

        payout += accumulatedRemainder / REMAINDER_SCALE;
        finalRemainder = accumulatedRemainder % REMAINDER_SCALE;
        processed = true;
    }

    /**
     * @notice Catches exact-T claim failure and proves all token-local and pooled state is unchanged
     * @param actorIndex Fixed lock/owner index
     * @param endTs Exact epoch-boundary settlement endpoint
     */
    function _assertExactBoundaryDeferral(uint256 actorIndex, uint256 endTs) internal {
        uint256 actorBalanceBefore = REWARD_TOKEN.balanceOf(actors[actorIndex]);
        uint256 poolBalanceBefore = REWARD_TOKEN.balanceOf(address(REVENUE_REWARD));
        uint256 cursorBefore = REVENUE_REWARD.lastEarnTime(address(REWARD_TOKEN), tokenIds[actorIndex]);
        uint256 remainderBefore =
            REVENUE_REWARD.tokenRewardsRemainingAccScaled(address(REWARD_TOKEN), tokenIds[actorIndex]);
        uint256 totalBefore = REVENUE_REWARD.totalRewardsPerToken(address(REWARD_TOKEN));

        vm.prank(actors[actorIndex]);
        (bool success, bytes memory returnData) = address(REVENUE_REWARD)
            .call(abi.encodeCall(IRevenueReward.getRewardUntilTs, (tokenIds[actorIndex], _rewardTokens(), endTs)));

        assertFalse(success, "exact-boundary settlement unexpectedly succeeded");
        assertGe(returnData.length, 4, "exact-boundary revert missing selector");
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(returnData, 0x20))
        }
        assertEq(selector, CommonChecksLibrary.EpochFinalizationPending.selector);
        assertEq(REWARD_TOKEN.balanceOf(actors[actorIndex]), actorBalanceBefore);
        assertEq(REWARD_TOKEN.balanceOf(address(REVENUE_REWARD)), poolBalanceBefore);
        assertEq(REVENUE_REWARD.lastEarnTime(address(REWARD_TOKEN), tokenIds[actorIndex]), cursorBefore);
        assertEq(
            REVENUE_REWARD.tokenRewardsRemainingAccScaled(address(REWARD_TOKEN), tokenIds[actorIndex]), remainderBefore
        );
        assertEq(REVENUE_REWARD.totalRewardsPerToken(address(REWARD_TOKEN)), totalBefore);
        ++exactBoundaryDeferrals;
    }

    /**
     * @notice Credits one notified amount to the ghost epoch bucket and the lifetime total
     * @param epoch Target reward epoch start
     * @param amount Notified reward amount
     */
    function _creditGhostEpoch(uint256 epoch, uint256 amount) internal {
        ghostEpochRewards[epoch] += amount;
        ghostTotalNotified += amount;
    }

    /**
     * @notice Asserts the credited epoch bucket, lifetime notified total, and pooled balance each match their ghosts
     * @param targetEpoch Epoch bucket credited by the completed notification
     */
    function _assertNotificationState(uint256 targetEpoch) internal view {
        assertEq(
            REVENUE_REWARD.tokenRewardsPerEpoch(address(REWARD_TOKEN), targetEpoch),
            ghostEpochRewards[targetEpoch],
            "notification bucket mismatch"
        );
        assertEq(
            REVENUE_REWARD.totalRewardsPerToken(address(REWARD_TOKEN)),
            ghostTotalNotified,
            "lifetime notification mismatch"
        );
        assertEq(REWARD_TOKEN.balanceOf(address(REVENUE_REWARD)), expectedContractBalance(), "notification pool delta");
    }

    /*//////////////////////////////////////////////////////////////
                               VIEWS
    //////////////////////////////////////////////////////////////*/

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    function tokenIdAt(uint256 index) external view returns (uint256) {
        return tokenIds[index];
    }

    function weightAt(uint256 index) external view returns (uint256) {
        return weights[index];
    }

    function initialActorBalanceAt(uint256 index) external view returns (uint256) {
        return initialActorBalances[index];
    }

    function ghostPaidAt(uint256 index) external view returns (uint256) {
        return ghostPaidByToken[index];
    }

    function ghostLastEarnTimeAt(uint256 index) external view returns (uint256) {
        return ghostLastEarnTime[index];
    }

    function ghostRemainderAt(uint256 index) external view returns (uint256) {
        return ghostRemainderScaled[index];
    }

    function ghostOutstanding() public view returns (uint256) {
        return ghostTotalNotified - ghostTotalPaid;
    }

    function expectedContractBalance() public view returns (uint256) {
        return ghostTotalNotified + ghostDirectTransfers - ghostTotalPaid - ghostRecovered;
    }

    function expectedDistributorBalance() external view returns (uint256) {
        return initialDistributorBalance - ghostTotalNotified - ghostDirectTransfers + ghostRecovered;
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Builds the single-element claim array holding the pooled reward token
     * @return tokens Reward token array for getRewardUntilTs calls
     */
    function _rewardTokens() internal view returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = address(REWARD_TOKEN);
    }

    /**
     * @notice Bounds a raw fuzz value into [1, maximum]
     * @dev Zero maps to 1; any other value maps via the 1-indexed form (rawValue - 1) % maximum + 1.
     * @param rawValue Unbounded fuzz input
     * @param maximum Inclusive upper bound
     * @return Bounded value in [1, maximum]
     */
    function _boundedPositive(uint256 rawValue, uint256 maximum) internal pure returns (uint256) {
        if (rawValue == 0) return 1;
        return (rawValue - 1) % maximum + 1;
    }

    /**
     * @notice Rounds a timestamp down to its WEEK-aligned epoch start
     * @param timestamp Timestamp to align
     * @return Epoch start containing the timestamp
     */
    function _epochStart(uint256 timestamp) internal pure returns (uint256) {
        return timestamp - timestamp % WEEK;
    }

    /**
     * @notice Returns the first WEEK-aligned epoch boundary strictly after a timestamp
     * @param timestamp Timestamp to align
     * @return Next epoch start
     */
    function _epochNext(uint256 timestamp) internal pure returns (uint256) {
        return _epochStart(timestamp) + WEEK;
    }
}
