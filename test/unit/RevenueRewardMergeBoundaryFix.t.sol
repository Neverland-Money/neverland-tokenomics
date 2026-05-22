// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../BaseTestLocal.sol";

/// @notice Regression pins for exact-boundary reward finality.
/// @dev At an exact epoch boundary T, DustLock checkpoints for timestamp T are still mutable
///      inside that block. RevenueReward therefore defers epoch-T settlement until block.timestamp > T.
contract RevenueRewardMergeBoundaryFixTest is BaseTestLocal {
    uint256 internal constant ROUNDING_TOLERANCE = 3;

    uint256 internal sourceTokenId;
    uint256 internal destinationTokenId;

    function setUp() public override {
        _testSetup();
    }

    /// @notice Epoch T is not claimable in the exact boundary block, but is claimable one second later.
    function testBoundaryClaimDefersEpochUntilNextSecond() public {
        _seedScenario();

        uint256 boundary = block.timestamp;
        uint256 sourceEntitlement = _epochShare(sourceTokenId, boundary);

        uint256 attackerBalanceBefore = mockUSDC.balanceOf(user);
        vm.prank(user);
        revenueReward.getReward(sourceTokenId, _usdcArray());
        uint256 sourceClaimAtBoundary = mockUSDC.balanceOf(user) - attackerBalanceBefore;
        assertEq(sourceClaimAtBoundary, 0, "epoch T must not be claimable at exact boundary T");

        skip(1);
        vm.prank(user);
        revenueReward.getReward(sourceTokenId, _usdcArray());
        uint256 sourceClaimAfterBoundary = mockUSDC.balanceOf(user) - attackerBalanceBefore;
        assertApproxEqAbs(
            sourceClaimAfterBoundary,
            sourceEntitlement,
            ROUNDING_TOLERANCE,
            "epoch T should become claimable after the boundary block"
        );
    }

    /// @notice Users with finalized previous-epoch rewards can claim at T-1, T, or T+1 without loss or lockout.
    function testBoundaryClaimTimingWithPreviousRewardsDoesNotLoseOrDdos() public {
        uint256 tokenBeforeBoundary = _createPermanentLockLocal(user, TOKEN_1, MAXTIME);
        uint256 tokenAtBoundary = _createPermanentLockLocal(user1, TOKEN_1, MAXTIME);
        uint256 tokenAfterBoundary = _createPermanentLockLocal(user2, TOKEN_1, MAXTIME);

        _addRewardLocal(admin, mockUSDC, 3 * USDC_1);

        uint256 boundary = 3 * WEEK;
        _warpAndRoll(boundary - 1);
        assertEq(_claimLocal(user, tokenBeforeBoundary), USDC_1, "T-1 claim should pay finalized previous epoch");
        assertEq(revenueReward.lastEarnTime(address(mockUSDC), tokenBeforeBoundary), boundary - 1);

        _warpAndRoll(boundary);
        assertEq(_claimLocal(user1, tokenAtBoundary), USDC_1, "T claim should pay finalized previous epoch");
        assertEq(revenueReward.lastEarnTime(address(mockUSDC), tokenAtBoundary), boundary - 1);

        _warpAndRoll(boundary + 1);
        assertEq(_claimLocal(user2, tokenAfterBoundary), USDC_1, "T+1 claim should pay finalized previous epoch");
        assertEq(revenueReward.lastEarnTime(address(mockUSDC), tokenAfterBoundary), boundary + 1);
    }

    /// @notice Users with no finalized rewards can claim at T-1, T, or T+1 without reverting or losing future state.
    function testBoundaryClaimTimingWithZeroPreviousRewardsDoesNotLoseOrDdos() public {
        _addRewardLocal(admin, mockUSDC, USDC_1);
        _warpAndRoll(2 * WEEK + 1);

        uint256 tokenBeforeBoundary = _createPermanentLockLocal(user, TOKEN_1, MAXTIME);
        uint256 tokenAtBoundary = _createPermanentLockLocal(user1, TOKEN_1, MAXTIME);
        uint256 tokenAfterBoundary = _createPermanentLockLocal(user2, TOKEN_1, MAXTIME);

        uint256 boundary = 3 * WEEK;
        _warpAndRoll(boundary - 1);
        assertEq(_claimLocal(user, tokenBeforeBoundary), 0, "T-1 zero-reward claim should no-op");
        assertEq(revenueReward.lastEarnTime(address(mockUSDC), tokenBeforeBoundary), 0);

        _warpAndRoll(boundary);
        assertEq(_claimLocal(user1, tokenAtBoundary), 0, "T zero-reward claim should no-op");
        assertEq(revenueReward.lastEarnTime(address(mockUSDC), tokenAtBoundary), 0);

        _warpAndRoll(boundary + 1);
        assertEq(_claimLocal(user2, tokenAfterBoundary), 0, "T+1 zero-reward claim should no-op");
        assertEq(revenueReward.lastEarnTime(address(mockUSDC), tokenAfterBoundary), boundary + 1);
    }

    /// @notice Explicit getRewardUntilTs(T) follows the same finality rule at T, then includes T after T passes.
    function testGetRewardUntilTsBoundaryTimestampIncludesEpochAfterBoundaryPasses() public {
        _seedScenario();

        uint256 boundary = block.timestamp;
        uint256 sourceEntitlement = _epochShare(sourceTokenId, boundary);

        uint256 attackerBalanceBefore = mockUSDC.balanceOf(user);
        vm.prank(user);
        revenueReward.getRewardUntilTs(sourceTokenId, _usdcArray(), boundary);
        uint256 sourceClaimAtBoundary = mockUSDC.balanceOf(user) - attackerBalanceBefore;
        assertEq(sourceClaimAtBoundary, 0, "explicit endTs=T must not settle T while block.timestamp is T");

        skip(1);
        vm.prank(user);
        revenueReward.getRewardUntilTs(sourceTokenId, _usdcArray(), boundary);
        uint256 sourceClaimAfterBoundary = mockUSDC.balanceOf(user) - attackerBalanceBefore;
        assertApproxEqAbs(
            sourceClaimAfterBoundary,
            sourceEntitlement,
            ROUNDING_TOLERANCE,
            "explicit endTs=T should settle T after the boundary block"
        );
    }

    /// @notice Pins the original merge path: no same-boundary extraction, then one finalized destination claim.
    function testMergeBoundaryAttack_FinalizedSnapshotClaimsOnce() public {
        _seedScenario();

        uint256 boundary = block.timestamp;

        uint256 attackerBalanceBefore = mockUSDC.balanceOf(user);
        vm.prank(user);
        revenueReward.getReward(sourceTokenId, _usdcArray());
        uint256 sourceClaimAmount = mockUSDC.balanceOf(user) - attackerBalanceBefore;
        assertEq(sourceClaimAmount, 0, "source must not claim epoch T in the boundary block");

        uint256 attackerBalanceAfterSourceClaim = mockUSDC.balanceOf(user);
        vm.prank(user);
        dustLock.merge(sourceTokenId, destinationTokenId);
        uint256 attackerBalanceAfterMerge = mockUSDC.balanceOf(user);
        uint256 mergeSideClaimAmount = attackerBalanceAfterMerge - attackerBalanceAfterSourceClaim;
        assertEq(mergeSideClaimAmount, 0, "merge hook must not settle epoch T in the boundary block");

        uint256 finalizedDestinationEntitlement = _epochShare(destinationTokenId, boundary);
        skip(1);
        uint256 attackerBalanceBeforeDestClaim = attackerBalanceAfterMerge;
        vm.prank(user);
        revenueReward.getReward(destinationTokenId, _usdcArray());
        uint256 destClaimAmount = mockUSDC.balanceOf(user) - attackerBalanceBeforeDestClaim;
        assertApproxEqAbs(
            destClaimAmount,
            finalizedDestinationEntitlement,
            ROUNDING_TOLERANCE,
            "destination should claim the finalized epoch-T snapshot once"
        );

        uint256 totalExtraction = mockUSDC.balanceOf(user) - attackerBalanceBefore;
        assertApproxEqAbs(
            totalExtraction,
            finalizedDestinationEntitlement,
            ROUNDING_TOLERANCE,
            "merge-boundary accounting should settle the finalized epoch-T entitlement once"
        );
    }

    /// @notice Boundary merge/relock cannot be paid against two different epoch-T snapshots.
    function testMergeBoundaryRelockAdvantage_UsesOneFinalizedSnapshot() public {
        sourceTokenId = _createLockLocal(user, 80 * TOKEN_1, MINTIME + WEEK);
        destinationTokenId = _createPermanentLockLocal(user, 20 * TOKEN_1, MAXTIME);
        _createPermanentLockLocal(user2, 1_000 * TOKEN_1, MAXTIME);
        _addRewardLocal(admin, mockUSDC, USDC_10K);
        skipToNextEpoch(0);
        assertEq(block.timestamp % WEEK, 0, "test must align to exact epoch boundary");

        uint256 boundary = block.timestamp;
        uint256 sourcePower = dustLock.balanceOfNFTAt(sourceTokenId, boundary);
        uint256 destinationPower = dustLock.balanceOfNFTAt(destinationTokenId, boundary);

        uint256 attackerBalanceBefore = mockUSDC.balanceOf(user);
        vm.prank(user);
        dustLock.merge(sourceTokenId, destinationTokenId);
        uint256 mergeClaimAmount = mockUSDC.balanceOf(user) - attackerBalanceBefore;

        uint256 postMergeDestinationPower = dustLock.balanceOfNFTAt(destinationTokenId, boundary);
        uint256 finalizedDestinationEntitlement = _epochShare(destinationTokenId, boundary);
        assertGt(
            postMergeDestinationPower,
            sourcePower + destinationPower,
            "scenario sanity: merge creates a larger boundary checkpoint than pre-merge power"
        );
        assertEq(mergeClaimAmount, 0, "boundary merge must not settle epoch T inside the boundary block");

        skip(1);
        uint256 attackerBalanceBeforeDestClaim = mockUSDC.balanceOf(user);
        vm.prank(user);
        revenueReward.getReward(destinationTokenId, _usdcArray());
        uint256 destClaimAmount = mockUSDC.balanceOf(user) - attackerBalanceBeforeDestClaim;
        assertApproxEqAbs(
            destClaimAmount,
            finalizedDestinationEntitlement,
            ROUNDING_TOLERANCE,
            "relocked boundary checkpoint should be paid only once after finality"
        );
    }

    /// @notice Mixed boundary mutations cannot overpay the epoch budget once claims are deferred past T.
    function testBoundaryMixedSnapshotAfterMergeCannotOverpayEpochBudget() public {
        sourceTokenId = _createLockLocal(user, 100_000 * TOKEN_1, MAXTIME);
        destinationTokenId = _createLockLocal(user, 100_000 * TOKEN_1, MAXTIME);
        uint256 mutableTokenId = _createLockLocal(user, 1_000_000 * TOKEN_1, MINTIME + WEEK);

        _addRewardLocal(admin, mockUSDC, USDC_10K);
        mintErc20Token(address(mockUSDC), address(revenueReward), USDC_100K);
        skipToNextEpoch(0);
        assertEq(block.timestamp % WEEK, 0, "test must align to exact epoch boundary");

        uint256 boundary = block.timestamp;
        uint256 epochBudget = revenueReward.tokenRewardsPerEpoch(address(mockUSDC), boundary);
        uint256 oldSupply = dustLock.totalSupplyAt(boundary);

        uint256 attackerBalanceBefore = mockUSDC.balanceOf(user);
        vm.prank(user);
        dustLock.merge(sourceTokenId, destinationTokenId);
        uint256 mergeSettlement = mockUSDC.balanceOf(user) - attackerBalanceBefore;
        assertEq(mergeSettlement, 0, "merge must not settle epoch T in the boundary block");

        uint256 mutablePowerBefore = dustLock.balanceOfNFTAt(mutableTokenId, boundary);
        vm.prank(user);
        dustLock.lockPermanent(mutableTokenId);
        uint256 mutablePowerAfter = dustLock.balanceOfNFTAt(mutableTokenId, boundary);
        uint256 finalSupply = dustLock.totalSupplyAt(boundary);
        assertGt(mutablePowerAfter, mutablePowerBefore, "mutation must increase token power at T");
        assertGt(finalSupply, oldSupply, "mutation must increase totalSupplyAt(T)");

        vm.prank(user);
        revenueReward.getReward(mutableTokenId, _usdcArray());
        uint256 mutableClaimAtBoundary = mockUSDC.balanceOf(user) - attackerBalanceBefore;
        assertEq(mutableClaimAtBoundary, 0, "mutation claim must not settle epoch T in the boundary block");

        skip(1);
        vm.prank(user);
        revenueReward.getReward(destinationTokenId, _usdcArray());
        vm.prank(user);
        revenueReward.getReward(mutableTokenId, _usdcArray());

        uint256 totalExtraction = mockUSDC.balanceOf(user) - attackerBalanceBefore;
        emit log_named_uint("epochBudget", epochBudget);
        emit log_named_uint("totalExtraction", totalExtraction);
        assertLe(totalExtraction, epochBudget, "same epoch must not pay more than tokenRewardsPerEpoch[T]");
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

    function _claimLocal(address who, uint256 tokenId) internal returns (uint256 claimed) {
        uint256 balanceBefore = mockUSDC.balanceOf(who);

        vm.prank(who);
        revenueReward.getReward(tokenId, _usdcArray());

        claimed = mockUSDC.balanceOf(who) - balanceBefore;
    }

    function _warpAndRoll(uint256 timestamp) internal {
        vm.warp(timestamp);
        vm.roll(block.number + 1);
    }
}
