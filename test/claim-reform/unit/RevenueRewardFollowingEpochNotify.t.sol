// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IRevenueReward} from "../../../src/interfaces/IRevenueReward.sol";
import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";

import "../../BaseTestLocal.sol";

/**
 * @title RevenueRewardFollowingEpochNotifyTest
 * @author Neverland
 * @notice Focused PR50 following-epoch notification regressions for the NGV-05 candidate
 */
contract RevenueRewardFollowingEpochNotifyTest is BaseTestLocal {
    event NotifyReward(address indexed from, address indexed token, uint256 epoch, uint256 amount);

    function _setUp() internal view override {
        assertEq(block.timestamp, WEEK + 1);
    }

    function testFollowingEpochNotifyCreditsOnlyEpochAfterNext() public {
        uint256 nextEpoch = _getEpochStart(block.timestamp) + WEEK;
        uint256 followingEpoch = nextEpoch + WEEK;
        mintErc20Token(address(mockUSDC), admin, USDC_10K);

        vm.startPrank(admin);
        mockUSDC.approve(address(revenueReward), USDC_10K);
        vm.expectEmit(true, true, false, true, address(revenueReward));
        emit NotifyReward(admin, address(mockUSDC), followingEpoch, USDC_10K);
        revenueReward.notifyRewardAmountForFollowingEpoch(address(mockUSDC), USDC_10K);
        vm.stopPrank();

        assertEq(revenueReward.tokenRewardsPerEpoch(address(mockUSDC), nextEpoch), 0);
        assertEq(revenueReward.tokenRewardsPerEpoch(address(mockUSDC), followingEpoch), USDC_10K);
        assertEq(revenueReward.totalRewardsPerToken(address(mockUSDC)), USDC_10K);
        assertEq(mockUSDC.balanceOf(address(revenueReward)), USDC_10K);
    }

    function testFollowingEpochNotifyDefersTargetClaimUntilTPlusOne() public {
        uint256 tokenId = _createLock(user, TOKEN_1, MAXTIME);
        uint256 targetEpoch = _getEpochStart(block.timestamp) + 2 * WEEK;
        _fundFollowing(USDC_10K);

        skipToNextEpoch(1);
        revenueReward.getReward(tokenId, _rewardTokens());
        assertEq(mockUSDC.balanceOf(user), 0);

        vm.warp(targetEpoch);
        vm.roll(block.number + 1);
        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        revenueReward.getReward(tokenId, _rewardTokens());

        vm.warp(targetEpoch + 1);
        vm.roll(block.number + 1);
        revenueReward.getReward(tokenId, _rewardTokens());
        assertEqApprThreeWei(mockUSDC.balanceOf(user), USDC_10K);
    }

    function testOrdinaryAndFollowingNotificationsRemainIndependentAndConserved() public {
        _fundOrdinary(USDC_1K);
        _fundFollowing(USDC_10K);

        uint256 nextEpoch = _getEpochStart(block.timestamp) + WEEK;
        assertEq(revenueReward.tokenRewardsPerEpoch(address(mockUSDC), nextEpoch), USDC_1K);
        assertEq(revenueReward.tokenRewardsPerEpoch(address(mockUSDC), nextEpoch + WEEK), USDC_10K);
        assertEq(revenueReward.totalRewardsPerToken(address(mockUSDC)), USDC_1K + USDC_10K);
        assertEq(mockUSDC.balanceOf(address(revenueReward)), USDC_1K + USDC_10K);
    }

    function testFollowingNotificationsAccumulate() public {
        _fundFollowing(USDC_1K);
        _fundFollowing(USDC_10K);

        uint256 targetEpoch = _getEpochStart(block.timestamp) + 2 * WEEK;
        assertEq(revenueReward.tokenRewardsPerEpoch(address(mockUSDC), targetEpoch), USDC_1K + USDC_10K);
        assertEq(revenueReward.totalRewardsPerToken(address(mockUSDC)), USDC_1K + USDC_10K);
        assertEq(mockUSDC.balanceOf(address(revenueReward)), USDC_1K + USDC_10K);
    }

    function testFollowingEpochNotifyAtTMinusOneTargetsTPlusOneWeek() public {
        uint256 boundary = _getEpochStart(block.timestamp) + WEEK;
        vm.warp(boundary - 1);

        _fundFollowing(USDC_10K);

        assertEq(revenueReward.tokenRewardsPerEpoch(address(mockUSDC), boundary + WEEK), USDC_10K);
    }

    function testFollowingEpochNotifyAtExactTTargetsTPlusTwoWeeks() public {
        uint256 boundary = _getEpochStart(block.timestamp) + WEEK;
        vm.warp(boundary);

        _fundFollowing(USDC_10K);

        assertEq(revenueReward.tokenRewardsPerEpoch(address(mockUSDC), boundary + 2 * WEEK), USDC_10K);
    }

    function testFollowingEpochNotifyAtTPlusOneTargetsTPlusTwoWeeks() public {
        uint256 boundary = _getEpochStart(block.timestamp) + WEEK;
        vm.warp(boundary + 1);

        _fundFollowing(USDC_10K);

        assertEq(revenueReward.tokenRewardsPerEpoch(address(mockUSDC), boundary + 2 * WEEK), USDC_10K);
    }

    function testFollowingAtTMinusOneAndOrdinaryAtTAccumulateInSameBucket() public {
        uint256 boundary = _getEpochStart(block.timestamp) + WEEK;
        uint256 sharedTarget = boundary + WEEK;

        vm.warp(boundary - 1);
        _fundFollowing(USDC_1K);

        vm.warp(boundary);
        _fundOrdinary(USDC_10K);

        assertEq(revenueReward.tokenRewardsPerEpoch(address(mockUSDC), boundary), 0);
        assertEq(revenueReward.tokenRewardsPerEpoch(address(mockUSDC), sharedTarget), USDC_1K + USDC_10K);
        assertEq(revenueReward.totalRewardsPerToken(address(mockUSDC)), USDC_1K + USDC_10K);
        assertEq(mockUSDC.balanceOf(address(revenueReward)), USDC_1K + USDC_10K);
    }

    function testFollowingEpochNotifyRejectsNonDistributor() public {
        mintErc20Token(address(mockUSDC), user1, USDC_10K);

        vm.startPrank(user1);
        mockUSDC.approve(address(revenueReward), USDC_10K);
        vm.expectRevert(IRevenueReward.NotRewardDistributor.selector);
        revenueReward.notifyRewardAmountForFollowingEpoch(address(mockUSDC), USDC_10K);
        vm.stopPrank();
    }

    function testFollowingEpochNotifyRejectsZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert(CommonChecksLibrary.ZeroAmount.selector);
        revenueReward.notifyRewardAmountForFollowingEpoch(address(mockUSDC), 0);
    }

    function testFollowingEpochNotifyRejectsZeroToken() public {
        vm.prank(admin);
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        revenueReward.notifyRewardAmountForFollowingEpoch(address(0), USDC_10K);
    }

    function testFollowingEpochNotifyFailedTransferRollsBackRegistrationAndAccounting() public {
        uint256 targetEpoch = _getEpochStart(block.timestamp) + 2 * WEEK;
        mintErc20Token(address(mockUSDC), admin, USDC_10K);

        vm.prank(admin);
        vm.expectRevert();
        revenueReward.notifyRewardAmountForFollowingEpoch(address(mockUSDC), USDC_10K);

        assertFalse(revenueReward.isRewardToken(address(mockUSDC)));
        assertEq(revenueReward.rewardTokensLength(), 0);
        assertEq(revenueReward.totalRewardsPerToken(address(mockUSDC)), 0);
        assertEq(revenueReward.tokenRewardsPerEpoch(address(mockUSDC), targetEpoch), 0);
        assertEq(mockUSDC.balanceOf(address(revenueReward)), 0);
    }

    function testFuzzFollowingEpochNotifyTargetsModeledBucket(uint64 rawTimestamp, uint96 rawAmount) public {
        uint256 timestamp = bound(uint256(rawTimestamp), WEEK, type(uint64).max - 2 * WEEK);
        uint256 amount = bound(uint256(rawAmount), 1, type(uint96).max);
        vm.warp(timestamp);

        _fundFollowing(amount);

        uint256 targetEpoch = _getEpochStart(timestamp) + 2 * WEEK;
        assertEq(targetEpoch % WEEK, 0);
        assertEq(revenueReward.tokenRewardsPerEpoch(address(mockUSDC), targetEpoch), amount);
        assertEq(revenueReward.totalRewardsPerToken(address(mockUSDC)), amount);
        assertEq(mockUSDC.balanceOf(address(revenueReward)), amount);
    }

    function _fundOrdinary(uint256 amount) internal {
        mintErc20Token(address(mockUSDC), admin, amount);
        vm.startPrank(admin);
        mockUSDC.approve(address(revenueReward), amount);
        revenueReward.notifyRewardAmount(address(mockUSDC), amount);
        vm.stopPrank();
    }

    function _fundFollowing(uint256 amount) internal {
        mintErc20Token(address(mockUSDC), admin, amount);
        vm.startPrank(admin);
        mockUSDC.approve(address(revenueReward), amount);
        revenueReward.notifyRewardAmountForFollowingEpoch(address(mockUSDC), amount);
        vm.stopPrank();
    }

    function _createLock(address owner, uint256 amount, uint256 duration) internal returns (uint256 tokenId) {
        mintErc20Token(address(DUST), owner, amount);
        vm.startPrank(owner);
        DUST.approve(address(dustLock), amount);
        tokenId = dustLock.createLock(amount, duration);
        vm.stopPrank();
    }

    function _rewardTokens() internal view returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = address(mockUSDC);
    }
}
