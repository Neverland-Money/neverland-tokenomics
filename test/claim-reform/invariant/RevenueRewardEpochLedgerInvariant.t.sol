// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {StdInvariant} from "forge-std/StdInvariant.sol";

import {IDustLock} from "../../../src/interfaces/IDustLock.sol";
import {BaseTestLocal} from "../../BaseTestLocal.sol";
import {RevenueRewardEpochLedgerHandler} from "./RevenueRewardEpochLedgerHandler.sol";

/**
 * @title RevenueRewardEpochLedgerFixture
 * @author Neverland
 * @notice Real RevenueReward/DustLock fixture with three independently weighted permanent locks
 */
abstract contract RevenueRewardEpochLedgerFixture is BaseTestLocal {
    uint256 internal constant REWARD_FUND = 1e30;

    RevenueRewardEpochLedgerHandler internal handler;
    address[3] internal ledgerActors;
    uint256[3] internal ledgerTokenIds;
    uint256[3] internal ledgerWeights;

    function _setUp() internal virtual override {
        ledgerActors = [user1, user2, user3];
        ledgerWeights = [uint256(1 ether), uint256(2 ether), uint256(4 ether)];
        uint256 commonMintTimestamp = block.timestamp;

        for (uint256 i = 0; i < ledgerActors.length; ++i) {
            mintErc20Token(address(DUST), ledgerActors[i], ledgerWeights[i]);
            vm.startPrank(ledgerActors[i]);
            DUST.approve(address(dustLock), ledgerWeights[i]);
            ledgerTokenIds[i] = dustLock.createLockPermanent(ledgerWeights[i], MAXTIME);
            vm.stopPrank();
            assertEq(block.timestamp, commonMintTimestamp);
        }

        mintErc20Token(address(mockUSDC), admin, REWARD_FUND);
        vm.prank(admin);
        mockUSDC.approve(address(revenueReward), type(uint256).max);

        handler = new RevenueRewardEpochLedgerHandler(
            revenueReward, mockUSDC, admin, ledgerActors, ledgerTokenIds, ledgerWeights, commonMintTimestamp
        );
        vm.label(address(handler), "RevenueRewardEpochLedgerHandler");
    }
}

/**
 * @title RevenueRewardEpochLedgerInvariantTest
 * @author Neverland
 * @notice Stateful proof of epoch-keyed liabilities, cursor progress, backing, and recovery safety
 */
contract RevenueRewardEpochLedgerInvariantTest is StdInvariant, RevenueRewardEpochLedgerFixture {
    function _setUp() internal override {
        super._setUp();

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.actionNotifyOrdinary.selector;
        selectors[1] = handler.actionNotifyFollowing.selector;
        selectors[2] = handler.actionAdvanceTime.selector;
        selectors[3] = handler.actionSettle.selector;
        selectors[4] = handler.actionExactBoundaryDeferral.selector;
        selectors[5] = handler.actionRecover.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariantEpochBucketsAndLifetimeCreditsMatchIndependentGhosts() public view {
        uint256 firstEpoch = handler.firstRewardEpoch();
        uint256 lastPossibleEpoch = handler.maxSettlementEpoch() + 2 * WEEK;
        uint256 summedBuckets;

        for (uint256 epoch = firstEpoch; epoch <= lastPossibleEpoch; epoch += WEEK) {
            uint256 expected = handler.ghostEpochRewards(epoch);
            assertEq(revenueReward.tokenRewardsPerEpoch(address(mockUSDC), epoch), expected);
            summedBuckets += expected;
        }

        assertEq(summedBuckets, handler.ghostTotalNotified());
        assertEq(revenueReward.totalRewardsPerToken(address(mockUSDC)), handler.ghostTotalNotified());
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariantPayoutsRemaindersAndLastEarnTimesMatchIndependentGhosts() public view {
        uint256 summedPayouts;
        for (uint256 i = 0; i < ledgerActors.length; ++i) {
            uint256 expectedPaid = handler.ghostPaidAt(i);
            uint256 tokenId = handler.tokenIdAt(i);
            summedPayouts += expectedPaid;

            assertEq(
                mockUSDC.balanceOf(handler.actorAt(i)), handler.initialActorBalanceAt(i) + expectedPaid, "owner payout"
            );
            assertEq(
                revenueReward.lastEarnTime(address(mockUSDC), tokenId), handler.ghostLastEarnTimeAt(i), "lastEarnTime"
            );
            assertEq(
                revenueReward.tokenRewardsRemainingAccScaled(address(mockUSDC), tokenId),
                handler.ghostRemainderAt(i),
                "scaled remainder"
            );
            assertLt(handler.ghostRemainderAt(i), 1e18);
            assertLe(handler.ghostLastEarnTimeAt(i), block.timestamp);
        }
        assertEq(summedPayouts, handler.ghostTotalPaid());
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariantPooledBalanceConservesBackingAndRecoveryNeverSweepsLiabilities() public view {
        uint256 poolBalance = mockUSDC.balanceOf(address(revenueReward));
        assertEq(poolBalance, handler.expectedContractBalance());
        assertGe(poolBalance, handler.ghostOutstanding());
        assertLe(handler.ghostTotalPaid(), handler.ghostTotalNotified());
        assertLe(handler.ghostRecovered(), handler.ghostDirectTransfers());
        assertEq(
            poolBalance + handler.ghostTotalPaid() + handler.ghostRecovered(),
            handler.ghostTotalNotified() + handler.ghostDirectTransfers()
        );
        assertEq(mockUSDC.balanceOf(admin), handler.expectedDistributorBalance());
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariantPermanentWeightBasisRemainsFixedAndIndependent() public view {
        uint256 firstEpoch = handler.firstRewardEpoch();
        uint256 summedWeight;
        for (uint256 i = 0; i < ledgerTokenIds.length; ++i) {
            uint256 tokenId = handler.tokenIdAt(i);
            uint256 expectedWeight = handler.weightAt(i);
            IDustLock.LockedBalance memory lock = dustLock.locked(tokenId);

            assertEq(uint256(lock.amount), expectedWeight);
            assertTrue(lock.isPermanent);
            assertEq(lock.end, 0);
            assertEq(dustLock.ownerOf(tokenId), handler.actorAt(i));
            assertEq(revenueReward.tokenMintTime(tokenId), handler.mintTimestamp());
            assertEq(dustLock.balanceOfNFTAt(tokenId, firstEpoch), expectedWeight);
            summedWeight += expectedWeight;
        }
        assertEq(summedWeight, handler.totalWeight());
        assertEq(dustLock.totalSupplyAt(firstEpoch), handler.totalWeight());
    }

    /**
     * @notice Bookkeeping-only post-campaign check
     * @dev Absolute coverage counters must not be asserted in afterInvariant: foundry's shrinker
     *      replays short prefixes of a failing sequence, and threshold asserts on these counters
     *      would collapse genuine invariant failures into 1-call replay artifacts. Anti-vacuity is
     *      pinned by the deterministic RevenueRewardEpochLedgerDeterministicTest instead. The
     *      partition equality below holds on any prefix, so it is shrinker-safe.
     */
    function afterInvariant() public view {
        assertEq(
            handler.totalCalls(),
            handler.ordinaryNotificationSuccesses() + handler.followingNotificationSuccesses()
                + handler.advanceTimeSuccesses() + handler.settlementAttempts() + handler.exactBoundaryAttempts()
                + handler.recoveryAttempts(),
            "coverage: action counters do not partition totalCalls"
        );
    }
}

/**
 * @title RevenueRewardEpochLedgerDeterministicTest
 * @author Neverland
 * @notice Deterministic mixed E+1/E+2 partial-settlement and conservative-recovery proof
 */
contract RevenueRewardEpochLedgerDeterministicTest is RevenueRewardEpochLedgerFixture {
    function testMixedE1E2PartialSettlementKeepsLaterReserveEpochKeyedAndUnsweepable() public {
        uint256 ordinaryAmount = 7_000_003;
        uint256 followingAmount = 14_000_005;
        uint256 ordinaryEpoch = handler.firstRewardEpoch();
        uint256 followingEpoch = ordinaryEpoch + WEEK;

        handler.actionRecover(1);
        handler.actionNotifyOrdinary(ordinaryAmount);
        handler.actionNotifyFollowing(followingAmount);
        assertEq(revenueReward.tokenRewardsPerEpoch(address(mockUSDC), ordinaryEpoch), ordinaryAmount);
        assertEq(revenueReward.tokenRewardsPerEpoch(address(mockUSDC), followingEpoch), followingAmount);
        assertEq(revenueReward.totalRewardsPerToken(address(mockUSDC)), ordinaryAmount + followingAmount);

        handler.actionAdvanceTime(1, 0);
        assertEq(block.timestamp, ordinaryEpoch + 1);
        handler.actionSettle(0, 0, 0);
        uint256 firstPayout = handler.ghostPaidAt(0);
        assertGt(firstPayout, 0);
        uint256 firstCursor = handler.ghostLastEarnTimeAt(0);

        handler.actionSettle(0, 0, 0);
        assertEq(handler.ghostPaidAt(0), firstPayout);
        assertEq(handler.ghostLastEarnTimeAt(0), firstCursor);
        assertEq(handler.settlementNoops(), 1);

        handler.actionExactBoundaryDeferral(1);
        assertEq(block.timestamp, followingEpoch);
        assertEq(handler.ghostLastEarnTimeAt(1), 0);
        uint256 expectedDeferredPreview = ordinaryAmount * ledgerWeights[1] / handler.totalWeight();
        assertEq(
            revenueReward.earnedRewards(address(mockUSDC), ledgerTokenIds[1], followingEpoch), expectedDeferredPreview
        );

        uint256 recoveryPadding = 1_234;
        handler.actionRecover(firstPayout + recoveryPadding);
        assertEq(handler.ghostRecovered(), recoveryPadding);
        assertEq(mockUSDC.balanceOf(address(revenueReward)), ordinaryAmount + followingAmount);
        assertGe(mockUSDC.balanceOf(address(revenueReward)), followingAmount);
        assertEq(revenueReward.tokenRewardsPerEpoch(address(mockUSDC), followingEpoch), followingAmount);

        vm.warp(followingEpoch + 1);
        vm.roll(block.number + 1);

        handler.actionSettle(1, 0, 0);
        uint256 partialCursor = handler.ghostLastEarnTimeAt(1);
        uint256 partialPayout = handler.ghostPaidAt(1);
        assertEq(partialCursor, ordinaryEpoch + 1);
        assertGt(partialPayout, 0);

        handler.actionSettle(1, 0, 0);
        assertEq(handler.ghostLastEarnTimeAt(1), partialCursor);
        assertEq(handler.ghostPaidAt(1), partialPayout);
        assertEq(handler.settlementNoops(), 2);

        handler.actionSettle(0, 1, 0);
        handler.actionSettle(1, 1, 0);
        handler.actionSettle(2, 1, 0);

        for (uint256 i = 0; i < ledgerTokenIds.length; ++i) {
            assertEq(handler.ghostLastEarnTimeAt(i), followingEpoch + 1);
            assertEq(
                revenueReward.lastEarnTime(address(mockUSDC), ledgerTokenIds[i]), followingEpoch + 1, "final cursor"
            );
        }

        assertEq(revenueReward.tokenRewardsPerEpoch(address(mockUSDC), ordinaryEpoch), ordinaryAmount);
        assertEq(revenueReward.tokenRewardsPerEpoch(address(mockUSDC), followingEpoch), followingAmount);
        assertEq(revenueReward.totalRewardsPerToken(address(mockUSDC)), ordinaryAmount + followingAmount);
        assertEq(mockUSDC.balanceOf(address(revenueReward)), handler.expectedContractBalance());
        assertGe(mockUSDC.balanceOf(address(revenueReward)), handler.ghostOutstanding());
        assertEq(handler.ordinaryNotificationSuccesses(), 1);
        assertEq(handler.followingNotificationSuccesses(), 1);
        assertEq(handler.advanceTimeSuccesses(), 1);
        assertEq(handler.settlementProgresses(), 5);
        assertEq(handler.exactBoundaryDeferrals(), 1);
        assertEq(handler.successfulRecoverCalls(), 1);
        assertEq(handler.recoveryTransfers(), 1);
        assertEq(handler.preconditionSkips(), 1);
        assertEq(handler.totalCalls(), 13);
    }
}
