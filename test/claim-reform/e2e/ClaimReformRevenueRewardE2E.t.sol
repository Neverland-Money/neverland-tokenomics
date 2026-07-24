// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IDustLock} from "../../../src/interfaces/IDustLock.sol";

import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";

import {ClaimReformTestBase} from "../_utils/ClaimReformTestBase.sol";

/**
 * @title ClaimReformRevenueRewardE2ETest
 * @author Neverland
 * @notice Adversarial RevenueReward boundary tests for claim-created veNFTs
 */
contract ClaimReformRevenueRewardE2ETest is ClaimReformTestBase {
    function testExactBoundaryPreviewRetainsNonzeroFinalizedEpochsAndOnlyDefersCurrentEpoch() public {
        _claim(user, TOKEN_1K, MAXTIME, 0);
        uint256 tokenId = dustLock.tokenId();

        _notifyReward(USDC_10K);
        uint256 olderFundedBoundary = _nextBoundary();
        vm.warp(olderFundedBoundary + 1);
        vm.roll(block.number + 1);

        _notifyReward(2 * USDC_10K);
        uint256 currentFundedBoundary = _nextBoundary();
        vm.warp(currentFundedBoundary);
        vm.roll(block.number + 1);

        uint256 previewAtTMinusOne = revenueReward.earnedRewards(address(mockUSDC), tokenId, currentFundedBoundary - 1);
        uint256 previewAtT = revenueReward.earnedRewards(address(mockUSDC), tokenId, currentFundedBoundary);

        assertGt(previewAtTMinusOne, 0, "the finalized older epoch must be visible");
        assertEq(previewAtT, previewAtTMinusOne, "exact T must defer only epoch T");

        vm.warp(currentFundedBoundary + 1);
        vm.roll(block.number + 1);
        assertGt(
            revenueReward.earnedRewards(address(mockUSDC), tokenId, currentFundedBoundary),
            previewAtT,
            "T+1 must add the newly finalized epoch"
        );
    }

    function testEveryDustLockRewardCloseoutHookDefersAtomicallyAtExactBoundary() public {
        _claim(user, TOKEN_1K, MAXTIME, 0);
        uint256 transferredTokenId = dustLock.tokenId();
        _claim(user, TOKEN_1K, MAXTIME, 0);
        uint256 burnedTokenId = dustLock.tokenId();
        _claim(user, TOKEN_1K, MAXTIME, 0);
        uint256 mergeFromTokenId = dustLock.tokenId();
        _claim(user, TOKEN_1K, MAXTIME, 0);
        uint256 mergeToTokenId = dustLock.tokenId();
        _claim(user, TOKEN_1K, MAXTIME, 0);
        uint256 splitFromTokenId = dustLock.tokenId();

        _notifyReward(USDC_10K);
        uint256 boundary = _nextBoundary();
        vm.warp(boundary);
        vm.roll(block.number + 1);
        uint256 userBalanceBefore = mockUSDC.balanceOf(user);

        vm.startPrank(address(dustLock));
        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        revenueReward.notifyAfterTokenTransferred(transferredTokenId, user);
        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        revenueReward.notifyAfterTokenBurned(burnedTokenId, user);
        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        revenueReward.notifyAfterTokenMerged(mergeFromTokenId, mergeToTokenId, user);
        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        revenueReward.notifyAfterTokenSplit(splitFromTokenId, 10_001, TOKEN_1, 10_002, TOKEN_1, user);
        vm.stopPrank();

        assertEq(mockUSDC.balanceOf(user), userBalanceBefore);
        assertEq(mockUSDC.balanceOf(address(revenueReward)), USDC_10K);
        assertEq(revenueReward.lastEarnTime(address(mockUSDC), transferredTokenId), 0);
        assertEq(revenueReward.lastEarnTime(address(mockUSDC), burnedTokenId), 0);
        assertEq(revenueReward.lastEarnTime(address(mockUSDC), mergeFromTokenId), 0);
        assertEq(revenueReward.lastEarnTime(address(mockUSDC), mergeToTokenId), 0);
        assertEq(revenueReward.lastEarnTime(address(mockUSDC), splitFromTokenId), 0);
        assertEq(revenueReward.tokenMintTime(10_001), 0);
        assertEq(revenueReward.tokenMintTime(10_002), 0);

        vm.warp(boundary + 1);
        vm.roll(block.number + 1);
        vm.startPrank(address(dustLock));
        revenueReward.notifyAfterTokenTransferred(transferredTokenId, user);
        revenueReward.notifyAfterTokenBurned(burnedTokenId, user);
        revenueReward.notifyAfterTokenMerged(mergeFromTokenId, mergeToTokenId, user);
        revenueReward.notifyAfterTokenSplit(splitFromTokenId, 10_001, TOKEN_1, 10_002, TOKEN_1, user);
        vm.stopPrank();
        revenueReward.getReward(mergeToTokenId, _rewardTokens());

        uint256 paidRewards = mockUSDC.balanceOf(user) - userBalanceBefore;
        uint256 retainedRoundingDust = mockUSDC.balanceOf(address(revenueReward));
        assertGt(paidRewards, 0);
        assertEq(paidRewards + retainedRoundingDust, USDC_10K);
        assertEq(revenueReward.tokenMintTime(10_001), boundary + 1);
        assertEq(revenueReward.tokenMintTime(10_002), boundary + 1);
    }

    function testTMinusOneEarlyExitLeavesNextEpochRewardToSurvivingLock() public {
        (uint256 exitingTokenId, uint256 survivingTokenId) = _createEqualTimedClaimLocks();
        _notifyReward(USDC_10K);
        uint256 boundary = _nextBoundary();
        vm.warp(boundary - 1);
        vm.roll(block.number + 1);

        uint256 userRewardBefore = mockUSDC.balanceOf(user);
        dustLock.earlyWithdraw(exitingTokenId);

        assertEq(mockUSDC.balanceOf(user), userRewardBefore, "T-1 exit must not claim epoch-T rewards");
        assertEq(revenueReward.lastEarnTime(address(mockUSDC), exitingTokenId), 0);
        assertEq(mockUSDC.balanceOf(address(revenueReward)), USDC_10K);

        vm.warp(boundary + 1);
        vm.roll(block.number + 1);
        uint256 survivorRewardBefore = mockUSDC.balanceOf(user2);
        vm.prank(user2);
        revenueReward.getReward(survivingTokenId, _rewardTokens());
        uint256 survivorClaim = mockUSDC.balanceOf(user2) - survivorRewardBefore;

        assertEq(survivorClaim, USDC_10K, "surviving lock must receive the entire epoch-T reward");
        assertEq(revenueReward.lastEarnTime(address(mockUSDC), survivingTokenId), boundary + 1);
        assertEq(mockUSDC.balanceOf(address(revenueReward)), 0);

        vm.prank(user2);
        revenueReward.getReward(survivingTokenId, _rewardTokens());
        assertEq(
            mockUSDC.balanceOf(user2) - survivorRewardBefore,
            survivorClaim,
            "repeated T+1 claim must not settle epoch T twice"
        );
    }

    function testExactFundedBoundaryDefersClaimsAndPowerMutationUntilTPlusOne() public {
        (uint256 exitingTokenId, uint256 survivingTokenId) = _createEqualTimedClaimLocks();
        _notifyReward(USDC_10K);
        skipToNextEpoch(0);

        uint256 boundary = block.timestamp;
        IDustLock.LockedBalance memory exitingLockBefore = dustLock.locked(exitingTokenId);
        uint256 lockedSupplyBefore = dustLock.supply();
        uint256 userBalanceBefore = mockUSDC.balanceOf(user);
        uint256 rewardBalanceBefore = mockUSDC.balanceOf(address(revenueReward));

        assertEq(
            revenueReward.earnedRewards(address(mockUSDC), exitingTokenId, boundary),
            0,
            "exact-boundary preview must defer epoch T"
        );
        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        revenueReward.getReward(exitingTokenId, _rewardTokens());

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        dustLock.earlyWithdraw(exitingTokenId);

        assertEq(mockUSDC.balanceOf(user), userBalanceBefore);
        assertEq(mockUSDC.balanceOf(address(revenueReward)), rewardBalanceBefore);
        assertEq(revenueReward.lastEarnTime(address(mockUSDC), exitingTokenId), 0);
        assertEq(keccak256(abi.encode(dustLock.locked(exitingTokenId))), keccak256(abi.encode(exitingLockBefore)));
        assertEq(dustLock.supply(), lockedSupplyBefore);

        vm.warp(boundary + 1);
        vm.roll(block.number + 1);

        uint256 exitingEntitlement = revenueReward.earnedRewards(address(mockUSDC), exitingTokenId, boundary);
        uint256 survivingEntitlement = revenueReward.earnedRewards(address(mockUSDC), survivingTokenId, boundary);
        assertGt(exitingEntitlement, 0, "T+1 must expose the exiting lock's epoch-T entitlement");
        assertGt(survivingEntitlement, 0, "T+1 must expose the surviving lock's epoch-T entitlement");

        revenueReward.getReward(exitingTokenId, _rewardTokens());
        uint256 exitingClaim = mockUSDC.balanceOf(user) - userBalanceBefore;

        uint256 survivorBalanceBefore = mockUSDC.balanceOf(user2);
        vm.prank(user2);
        revenueReward.getReward(survivingTokenId, _rewardTokens());
        uint256 survivingClaim = mockUSDC.balanceOf(user2) - survivorBalanceBefore;

        assertEq(exitingClaim + survivingClaim, USDC_10K);
        assertEq(mockUSDC.balanceOf(address(revenueReward)), 0);
        dustLock.earlyWithdraw(exitingTokenId);
    }

    function testExactFundedBoundaryExistingLockClaimRollsBackAtomically() public {
        _claim(user2, TOKEN_1K, MAXTIME, 0);
        uint256 tokenId = dustLock.tokenId();
        _notifyReward(USDC_10K);
        skipToNextEpoch(0);

        uint256 gross = 100 * TOKEN_1;
        IDustLock.LockedBalance memory lockBefore = dustLock.locked(tokenId);
        uint256 vaultBefore = DUST.balanceOf(DUST_VAULT);
        uint256 burnBefore = DUST.balanceOf(BURN_WALLET);
        uint256 escrowBefore = DUST.balanceOf(address(dustLock));
        uint256 supplyBefore = dustLock.supply();
        uint256 totalSupplyBefore = DUST.totalSupply();

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        vm.prank(CLAIM_CONTROLLER);
        claimStrategy.performTransfer(user2, address(DUST), gross, 0, tokenId);

        assertEq(keccak256(abi.encode(dustLock.locked(tokenId))), keccak256(abi.encode(lockBefore)));
        assertEq(DUST.balanceOf(DUST_VAULT), vaultBefore);
        assertEq(DUST.balanceOf(BURN_WALLET), burnBefore);
        assertEq(DUST.balanceOf(address(dustLock)), escrowBefore);
        assertEq(dustLock.supply(), supplyBefore);
        assertEq(DUST.totalSupply(), totalSupplyBefore);
        assertEq(DUST.balanceOf(address(claimStrategy)), 0);
        assertEq(DUST.allowance(address(claimStrategy), address(dustLock)), 0);

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        (uint256 penalty, uint256 net) = claimStrategy.previewClaim(gross, 0, tokenId);
        _claim(user2, gross, 0, tokenId);

        assertEq(uint256(dustLock.locked(tokenId).amount), uint256(lockBefore.amount) + net);
        assertEq(vaultBefore - DUST.balanceOf(DUST_VAULT), gross);
        assertEq(DUST.balanceOf(BURN_WALLET) - burnBefore, penalty);
        assertEq(DUST.balanceOf(address(dustLock)) - escrowBefore, net);
        assertEq(dustLock.supply() - supplyBefore, net);
        assertEq(DUST.totalSupply(), totalSupplyBefore);
    }

    function testExactUnfundedBoundaryDefersCheckpointMutationUntilTPlusOne() public {
        _claim(user, TOKEN_1K, MAXTIME, 0);
        uint256 tokenId = dustLock.tokenId();
        uint256 boundary = _nextBoundary();
        vm.warp(boundary);
        vm.roll(block.number + 1);
        uint256 lockedAmount = uint256(dustLock.locked(tokenId).amount);
        uint256 supplyBefore = dustLock.supply();

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        dustLock.earlyWithdraw(tokenId);
        assertEq(dustLock.supply(), supplyBefore);

        vm.warp(boundary + 1);
        vm.roll(block.number + 1);
        dustLock.earlyWithdraw(tokenId);
        assertEq(supplyBefore - dustLock.supply(), lockedAmount);
    }

    function testTPlusOneClaimThenEarlyExitPreservesRewardConservation() public {
        (uint256 exitingTokenId, uint256 survivingTokenId) = _createEqualTimedClaimLocks();
        _notifyReward(USDC_10K);
        uint256 boundary = _nextBoundary();
        vm.warp(boundary + 1);
        vm.roll(block.number + 1);

        uint256 firstBalanceBefore = mockUSDC.balanceOf(user);
        revenueReward.getReward(exitingTokenId, _rewardTokens());
        uint256 firstClaim = mockUSDC.balanceOf(user) - firstBalanceBefore;
        assertGt(firstClaim, 0, "exiting lock must receive a nonzero epoch-T share");

        dustLock.earlyWithdraw(exitingTokenId);
        assertEq(
            mockUSDC.balanceOf(user) - firstBalanceBefore,
            firstClaim,
            "exit hook must not replay an already settled epoch"
        );

        uint256 secondBalanceBefore = mockUSDC.balanceOf(user2);
        vm.prank(user2);
        revenueReward.getReward(survivingTokenId, _rewardTokens());
        uint256 secondClaim = mockUSDC.balanceOf(user2) - secondBalanceBefore;
        uint256 rewardRemainder = mockUSDC.balanceOf(address(revenueReward));

        assertGt(secondClaim, 0, "surviving lock must receive a nonzero epoch-T share");
        assertEq(firstClaim + secondClaim + rewardRemainder, USDC_10K, "reward assets must remain conserved");
        assertEq(revenueReward.lastEarnTime(address(mockUSDC), exitingTokenId), boundary + 1);
        assertEq(revenueReward.lastEarnTime(address(mockUSDC), survivingTokenId), boundary + 1);

        vm.prank(user2);
        revenueReward.getReward(survivingTokenId, _rewardTokens());
        assertEq(mockUSDC.balanceOf(user2) - secondBalanceBefore, secondClaim, "epoch T must not be claimable twice");
        assertEq(mockUSDC.balanceOf(address(revenueReward)), rewardRemainder);
    }

    function _createEqualTimedClaimLocks() internal returns (uint256 exitingTokenId, uint256 survivingTokenId) {
        _claim(user, TOKEN_1K, MAXTIME, 0);
        exitingTokenId = dustLock.tokenId();

        _claim(user2, TOKEN_1K, MAXTIME, 0);
        survivingTokenId = dustLock.tokenId();
    }

    function _nextBoundary() internal view returns (uint256) {
        return block.timestamp - (block.timestamp % WEEK) + WEEK;
    }

    function _notifyReward(uint256 amount) internal {
        mintErc20Token(address(mockUSDC), admin, amount);
        vm.startPrank(admin);
        mockUSDC.approve(address(revenueReward), amount);
        revenueReward.notifyRewardAmount(address(mockUSDC), amount);
        vm.stopPrank();
    }

    function _rewardTokens() internal view returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = address(mockUSDC);
    }
}
