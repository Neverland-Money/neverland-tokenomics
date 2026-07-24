// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IDustLock} from "../../../src/interfaces/IDustLock.sol";

import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";

import "../../BaseTestLocal.sol";

/// @notice Regression pins for immutable funded-epoch voting-power snapshots.
/// @dev Checkpoint-changing operations defer from exact T to T+1 so a claim and
///      later lifecycle mutation cannot price the same funded epoch from different histories.
contract RevenueRewardMergeBoundaryFixTest is BaseTestLocal {
    uint256 internal constant ROUNDING_TOLERANCE = 3;

    uint256 internal sourceTokenId;
    uint256 internal destinationTokenId;

    function setUp() public override {
        _testSetup();
    }

    /// @notice Claims and merge both defer at T, then settle the immutable entitlement at T+1.
    function testFundedBoundaryClaimsAndMergeDeferWithoutRepricing() public {
        _seedScenario();

        uint256 boundary = block.timestamp;
        uint256 sourceEntitlement = _epochShare(sourceTokenId, boundary);
        uint256 destinationEntitlement = _epochShare(destinationTokenId, boundary);
        uint256 correctEntitlement = sourceEntitlement + destinationEntitlement;

        uint256 attackerBalanceBefore = mockUSDC.balanceOf(user);
        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        vm.prank(user);
        revenueReward.getReward(sourceTokenId, _usdcArray());

        IDustLock.LockedBalance memory sourceBefore = dustLock.locked(sourceTokenId);
        IDustLock.LockedBalance memory destinationBefore = dustLock.locked(destinationTokenId);
        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        vm.prank(user);
        dustLock.merge(sourceTokenId, destinationTokenId);
        assertEq(keccak256(abi.encode(dustLock.locked(sourceTokenId))), keccak256(abi.encode(sourceBefore)));
        assertEq(keccak256(abi.encode(dustLock.locked(destinationTokenId))), keccak256(abi.encode(destinationBefore)));

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        vm.prank(user);
        revenueReward.getReward(destinationTokenId, _usdcArray());
        assertEq(mockUSDC.balanceOf(user), attackerBalanceBefore, "all exact-boundary actions must roll back");

        vm.warp(boundary + 1);
        vm.roll(block.number + 1);

        vm.prank(user);
        revenueReward.getReward(sourceTokenId, _usdcArray());
        uint256 sourceClaimAmount = mockUSDC.balanceOf(user) - attackerBalanceBefore;
        assertApproxEqAbs(sourceClaimAmount, sourceEntitlement, ROUNDING_TOLERANCE);

        vm.prank(user);
        dustLock.merge(sourceTokenId, destinationTokenId);

        vm.prank(user);
        revenueReward.getReward(destinationTokenId, _usdcArray());

        uint256 totalExtraction = mockUSDC.balanceOf(user) - attackerBalanceBefore;
        assertApproxEqAbs(
            totalExtraction,
            correctEntitlement,
            ROUNDING_TOLERANCE,
            "funded-boundary accounting should settle exactly the pre-mutation entitlement"
        );
    }

    /// @notice A blocked boundary merge succeeds normally one second later.
    function testFundedBoundaryMergeSucceedsAtTPlusOne() public {
        _seedScenario();
        uint256 boundary = block.timestamp;
        uint256 correctEntitlement = _epochShare(sourceTokenId, boundary) + _epochShare(destinationTokenId, boundary);
        uint256 attackerBalanceBefore = mockUSDC.balanceOf(user);

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        vm.prank(user);
        dustLock.merge(sourceTokenId, destinationTokenId);

        vm.warp(boundary + 1);
        vm.roll(block.number + 1);
        vm.prank(user);
        dustLock.merge(sourceTokenId, destinationTokenId);

        vm.prank(user);
        revenueReward.getReward(destinationTokenId, _usdcArray());

        assertApproxEqAbs(
            mockUSDC.balanceOf(user) - attackerBalanceBefore,
            correctEntitlement,
            ROUNDING_TOLERANCE,
            "T+1 merge should preserve the finalized epoch-T entitlement"
        );
    }

    /// @notice A merge at T+1 cannot relock source power into the finalized epoch T.
    function testTPlusOneMergeSettlesPreMergeEntitlementOnly() public {
        sourceTokenId = _createLockLocal(user, 80 * TOKEN_1, MINTIME + WEEK);
        destinationTokenId = _createPermanentLockLocal(user, 20 * TOKEN_1, MAXTIME);
        _createPermanentLockLocal(user2, 1_000 * TOKEN_1, MAXTIME);
        _addRewardLocal(admin, mockUSDC, USDC_10K);
        skipToNextEpoch(0);
        assertEq(block.timestamp % WEEK, 0, "test must align to exact epoch boundary");

        uint256 boundary = block.timestamp;
        uint256 sourcePower = dustLock.balanceOfNFTAt(sourceTokenId, boundary);
        uint256 destinationPower = dustLock.balanceOfNFTAt(destinationTokenId, boundary);
        uint256 correctEntitlement = _epochShare(sourceTokenId, boundary) + _epochShare(destinationTokenId, boundary);

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        vm.prank(user);
        dustLock.merge(sourceTokenId, destinationTokenId);
        assertEq(dustLock.balanceOfNFTAt(sourceTokenId, boundary), sourcePower);
        assertEq(dustLock.balanceOfNFTAt(destinationTokenId, boundary), destinationPower);

        vm.warp(boundary + 1);
        vm.roll(block.number + 1);
        uint256 attackerBalanceBefore = mockUSDC.balanceOf(user);
        vm.prank(user);
        dustLock.merge(sourceTokenId, destinationTokenId);
        uint256 mergeClaimAmount = mockUSDC.balanceOf(user) - attackerBalanceBefore;

        uint256 postMergeDestinationPower = dustLock.balanceOfNFTAt(destinationTokenId, boundary);
        assertEq(postMergeDestinationPower, destinationPower, "T+1 merge must not rewrite epoch-T power");
        assertApproxEqAbs(
            mergeClaimAmount,
            _epochShare(sourceTokenId, boundary),
            ROUNDING_TOLERANCE,
            "merge hook should settle the source's finalized epoch-T entitlement"
        );

        uint256 attackerBalanceBeforeDestClaim = mockUSDC.balanceOf(user);
        vm.prank(user);
        revenueReward.getReward(destinationTokenId, _usdcArray());
        uint256 destClaimAmount = mockUSDC.balanceOf(user) - attackerBalanceBeforeDestClaim;
        assertApproxEqAbs(destClaimAmount, _epochShare(destinationTokenId, boundary), ROUNDING_TOLERANCE);
        assertApproxEqAbs(
            mockUSDC.balanceOf(user) - attackerBalanceBefore,
            correctEntitlement,
            ROUNDING_TOLERANCE,
            "T+1 merge should settle only pre-merge epoch-T power"
        );
    }

    function _seedScenario() internal {
        sourceTokenId = _createLockLocal(user, 8 * TOKEN_1, MAXTIME);
        destinationTokenId = _createLockLocal(user, 6 * TOKEN_1, MAXTIME);
        _createLockLocal(user2, 1_000_000 * TOKEN_1, MAXTIME);
        _addRewardLocal(admin, mockUSDC, USDC_10K);
        skipToNextEpoch(0);
        assertEq(block.timestamp % WEEK, 0, "test must align to exact epoch boundary");
    }

    function _usdcArray() internal view returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = address(mockUSDC);
    }

    function _epochShare(uint256 tokenId, uint256 epochTs) internal view returns (uint256) {
        uint256 rewardsPerEpoch = revenueReward.tokenRewardsPerEpoch(address(mockUSDC), epochTs);
        uint256 tokenPower = dustLock.balanceOfNFTAt(tokenId, epochTs);
        uint256 totalSupply = dustLock.totalSupplyAt(epochTs);
        return (rewardsPerEpoch * tokenPower) / totalSupply;
    }

    function _createLockLocal(address who, uint256 amount, uint256 duration) internal returns (uint256 tokenId) {
        mintErc20Token(address(DUST), who, amount);

        vm.startPrank(who);
        DUST.approve(address(dustLock), amount);
        tokenId = dustLock.createLock(amount, duration);
        vm.stopPrank();
    }

    function _createPermanentLockLocal(address who, uint256 amount, uint256 duration)
        internal
        returns (uint256 tokenId)
    {
        mintErc20Token(address(DUST), who, amount);

        vm.startPrank(who);
        DUST.approve(address(dustLock), amount);
        tokenId = dustLock.createLockPermanent(amount, duration);
        vm.stopPrank();
    }

    function _addRewardLocal(address who, IERC20 token, uint256 amount) internal {
        mintErc20Token(address(token), who, amount);

        vm.startPrank(who);
        token.approve(address(revenueReward), amount);
        revenueReward.notifyRewardAmount(address(token), amount);
        vm.stopPrank();
    }
}
