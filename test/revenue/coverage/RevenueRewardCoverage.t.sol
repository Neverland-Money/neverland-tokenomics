// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRevenueReward} from "../../../src/interfaces/IRevenueReward.sol";
import {IDustLock} from "../../../src/interfaces/IDustLock.sol";
import {IUserVaultFactory} from "../../../src/interfaces/IUserVaultFactory.sol";
import {RevenueReward} from "../../../src/rewards/RevenueReward.sol";
import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";

import "../../BaseTestLocal.sol";

/**
 * @title RevenueRewardCoverageTest
 * @notice Branch/statement-coverage-focused unit tests for RevenueReward.
 * @dev Targets the defensive revert arms, zero-supply/zero-amount guards, registry append-only
 *      path, the `acc == 0` split arm, the `recoverTokens` no-excess arm, the range/clamp arms of
 *      `getUsersWithSelfRepayingLoan`, and the early-exit/no-pay arms of the reward math that the
 *      existing happy-path suites do not drive. Only uses CURRENT-src API.
 */
contract RevenueRewardCoverageTest is BaseTestLocal {
    /// @dev Local mirror of the NotifyReward event for expectEmit.
    event NotifyReward(address indexed from, address indexed token, uint256 epoch, uint256 amount);

    function _setUp() internal view override {
        // Initial time => 1 sec after the start of week1 (matches the other RevenueReward suites)
        assertEq(block.timestamp, 1 weeks + 1);
    }

    /*//////////////////////////////////////////////////////////////
                  INITIALIZE ZERO-ADDRESS REVERT ARMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Each of the four initializer zero-address guards must revert independently.
    function testInitializeRevertsOnZeroForwarder() public {
        RevenueReward impl = new RevenueReward(FORWARDER);
        RevenueReward fresh = RevenueReward(_deployProxy(address(impl)));

        vm.expectRevert(abi.encodeWithSelector(CommonChecksLibrary.AddressZero.selector));
        fresh.initialize(ZERO_ADDRESS, dustLock, admin, userVaultFactory);
    }

    function testInitializeRevertsOnZeroDustLock() public {
        RevenueReward impl = new RevenueReward(FORWARDER);
        RevenueReward fresh = RevenueReward(_deployProxy(address(impl)));

        vm.expectRevert(abi.encodeWithSelector(CommonChecksLibrary.AddressZero.selector));
        fresh.initialize(FORWARDER, IDustLock(ZERO_ADDRESS), admin, userVaultFactory);
    }

    function testInitializeRevertsOnZeroRewardDistributor() public {
        RevenueReward impl = new RevenueReward(FORWARDER);
        RevenueReward fresh = RevenueReward(_deployProxy(address(impl)));

        vm.expectRevert(abi.encodeWithSelector(CommonChecksLibrary.AddressZero.selector));
        fresh.initialize(FORWARDER, dustLock, ZERO_ADDRESS, userVaultFactory);
    }

    function testInitializeRevertsOnZeroUserVaultFactory() public {
        RevenueReward impl = new RevenueReward(FORWARDER);
        RevenueReward fresh = RevenueReward(_deployProxy(address(impl)));

        vm.expectRevert(abi.encodeWithSelector(CommonChecksLibrary.AddressZero.selector));
        fresh.initialize(FORWARDER, dustLock, admin, IUserVaultFactory(ZERO_ADDRESS));
    }

    /*//////////////////////////////////////////////////////////////
                  setRewardDistributor ZERO-ADDRESS ARM
    //////////////////////////////////////////////////////////////*/

    /// @notice The zero-address guard in setRewardDistributor fires before the distributor check.
    function testSetRewardDistributorRevertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CommonChecksLibrary.AddressZero.selector));
        revenueReward.setRewardDistributor(ZERO_ADDRESS);
    }

    /*//////////////////////////////////////////////////////////////
                   notifyRewardAmount GUARD ARMS
    //////////////////////////////////////////////////////////////*/

    /// @notice notifyRewardAmount reverts on a zero amount (CommonChecksLibrary.ZeroAmount).
    function testNotifyRewardAmountRevertsOnZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CommonChecksLibrary.ZeroAmount.selector));
        revenueReward.notifyRewardAmount(address(mockUSDC), 0);
    }

    /// @notice notifyRewardAmount reverts on a zero token address (CommonChecksLibrary.AddressZero).
    function testNotifyRewardAmountRevertsOnZeroToken() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CommonChecksLibrary.AddressZero.selector));
        revenueReward.notifyRewardAmount(ZERO_ADDRESS, USDC_10K);
    }

    /// @notice First notify registers the token (append path); a second notify must NOT re-append.
    function testNotifyRewardAmountRegistersTokenOnceAppendOnly() public {
        assertEq(revenueReward.rewardTokensLength(), 0);
        assertFalse(revenueReward.isRewardToken(address(mockUSDC)));

        // First notify: hits the `!isRewardToken` TRUE arm (register + push) and emits with epochNext.
        uint256 expectedEpoch = ((block.timestamp / 1 weeks) + 1) * 1 weeks;
        mintErc20Token(address(mockUSDC), admin, USDC_10K);
        vm.startPrank(admin);
        mockUSDC.approve(address(revenueReward), USDC_10K);
        vm.expectEmit(true, true, false, true, address(revenueReward));
        emit NotifyReward(admin, address(mockUSDC), expectedEpoch, USDC_10K);
        revenueReward.notifyRewardAmount(address(mockUSDC), USDC_10K);
        vm.stopPrank();

        assertTrue(revenueReward.isRewardToken(address(mockUSDC)));
        assertEq(revenueReward.rewardTokensLength(), 1);
        assertEq(revenueReward.totalRewardsPerToken(address(mockUSDC)), USDC_10K);

        // Second notify of the SAME token: hits the `!isRewardToken` FALSE arm (no re-push).
        mintErc20Token(address(mockUSDC), admin, USDC_10K);
        vm.startPrank(admin);
        mockUSDC.approve(address(revenueReward), USDC_10K);
        revenueReward.notifyRewardAmount(address(mockUSDC), USDC_10K);
        vm.stopPrank();

        assertEq(revenueReward.rewardTokensLength(), 1, "token must not be appended twice");
        assertEq(revenueReward.totalRewardsPerToken(address(mockUSDC)), 2 * USDC_10K);
    }

    /*//////////////////////////////////////////////////////////////
                          recoverTokens ARMS
    //////////////////////////////////////////////////////////////*/

    /// @notice recoverTokens with no stray balance hits the `balance > credited` FALSE arm (no transfer).
    function testRecoverTokensNoExcessIsNoOp() public {
        // Notify exactly USDC_10K so balance == credited for the only registered token.
        mintErc20Token(address(mockUSDC), admin, USDC_10K);
        vm.startPrank(admin);
        mockUSDC.approve(address(revenueReward), USDC_10K);
        revenueReward.notifyRewardAmount(address(mockUSDC), USDC_10K);
        vm.stopPrank();

        assertEq(mockUSDC.balanceOf(address(revenueReward)), revenueReward.totalRewardsPerToken(address(mockUSDC)));

        uint256 adminBefore = mockUSDC.balanceOf(admin);
        uint256 contractBefore = mockUSDC.balanceOf(address(revenueReward));

        // balance == credited => the `balance > credited` FALSE arm: no transfer, no event, nothing moves.
        vm.prank(admin);
        revenueReward.recoverTokens();

        assertEq(mockUSDC.balanceOf(admin), adminBefore, "admin balance unchanged");
        assertEq(mockUSDC.balanceOf(address(revenueReward)), contractBefore, "contract balance unchanged");
    }

    /// @notice recoverTokens with an empty reward-token list skips the loop body entirely.
    function testRecoverTokensWithNoRegisteredTokensIsNoOp() public {
        assertEq(revenueReward.rewardTokensLength(), 0);

        vm.prank(admin);
        revenueReward.recoverTokens();
    }

    /*//////////////////////////////////////////////////////////////
                       onlyDustLock REVERT ARMS
    //////////////////////////////////////////////////////////////*/

    /// @notice notifyTokenMinted called by a non-DustLock address reverts (onlyDustLock FALSE arm).
    function testNotifyTokenMintedRevertsForNonDustLock() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IRevenueReward.NotDustLock.selector));
        revenueReward.notifyTokenMinted(1);
    }

    /// @notice notifyAfterTokenTransferred called by a non-DustLock address reverts.
    function testNotifyAfterTokenTransferredRevertsForNonDustLock() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IRevenueReward.NotDustLock.selector));
        revenueReward.notifyAfterTokenTransferred(1, user1);
    }

    /// @notice notifyAfterTokenBurned called by a non-DustLock address reverts.
    function testNotifyAfterTokenBurnedRevertsForNonDustLock() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IRevenueReward.NotDustLock.selector));
        revenueReward.notifyAfterTokenBurned(1, user1);
    }

    /// @notice notifyAfterTokenMerged called by a non-DustLock address reverts.
    function testNotifyAfterTokenMergedRevertsForNonDustLock() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IRevenueReward.NotDustLock.selector));
        revenueReward.notifyAfterTokenMerged(1, 2, user1);
    }

    /// @notice notifyAfterTokenSplit called by a non-DustLock address reverts.
    function testNotifyAfterTokenSplitRevertsForNonDustLock() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IRevenueReward.NotDustLock.selector));
        revenueReward.notifyAfterTokenSplit(1, 2, TOKEN_1, 3, TOKEN_1, user1);
    }

    /*//////////////////////////////////////////////////////////////
                  UNKNOWN REWARD TOKEN REVERT ARMS
    //////////////////////////////////////////////////////////////*/

    /// @notice getReward over an unregistered token hits the `!isRewardToken` revert in claim math.
    function testGetRewardRevertsOnUnknownRewardToken() public {
        uint256 tokenId = _createLock(user, TOKEN_1, MAXTIME);
        _addReward(admin, mockUSDC, USDC_10K);
        skipToNextEpoch(1);

        // mockERC20 was never notified, so it is not a registered reward token.
        assertFalse(revenueReward.isRewardToken(address(mockERC20)));

        address[] memory tokens = new address[](1);
        tokens[0] = address(mockERC20);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IRevenueReward.UnknownRewardToken.selector));
        revenueReward.getReward(tokenId, tokens);
    }

    /// @notice earnedRewards view over an unregistered token reverts with UnknownRewardToken.
    function testEarnedRewardsRevertsOnUnknownRewardToken() public {
        uint256 tokenId = _createLock(user, TOKEN_1, MAXTIME);

        assertFalse(revenueReward.isRewardToken(address(mockERC20)));

        vm.expectRevert(abi.encodeWithSelector(IRevenueReward.UnknownRewardToken.selector));
        revenueReward.earnedRewards(address(mockERC20), tokenId, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                       _earned EARLY-EXIT / ZERO ARMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Claiming in the same epoch as mint (no completed epoch) drives the `startTs > endTsEpoch`
    ///         early-return arm in `_earned` (success == false), so lastEarnTime stays at 0 and no payout.
    function testClaimSameEpochAsMintReturnsEarlyNoSuccess() public {
        // Reward already credited to NEXT epoch; lock minted same epoch, claim before any epoch elapses.
        _addReward(admin, mockUSDC, USDC_10K);
        uint256 tokenId = _createLock(user, TOKEN_1, MAXTIME);

        address[] memory tokens = new address[](1);
        tokens[0] = address(mockUSDC);

        uint256 balBefore = mockUSDC.balanceOf(user);

        // No epoch boundary crossed since mint => _earned returns (0,0,false), lastEarnTime untouched.
        vm.prank(user);
        revenueReward.getReward(tokenId, tokens);

        assertEq(mockUSDC.balanceOf(user), balBefore, "no reward when claim epoch == mint epoch");
        assertEq(revenueReward.lastEarnTime(address(mockUSDC), tokenId), 0, "lastEarnTime not advanced on no-op");
        // View mirror returns 0 too.
        assertEq(revenueReward.earnedRewards(address(mockUSDC), tokenId, block.timestamp), 0);
    }

    /// @notice An epoch whose totalSupplyAt == 0 hits the zero-supply `continue` arm in `_earned`:
    ///         the loop iterates a registered-reward epoch with no live supply and pays nothing for it.
    function testEarnedSkipsZeroSupplyEpoch() public {
        // epoch1 (ts = 1w+1): notify reward -> credited to epoch2 start. No locks exist yet.
        _addReward(admin, mockUSDC, USDC_10K);
        uint256 epoch2Start = ((block.timestamp / 1 weeks) + 1) * 1 weeks;
        assertEq(revenueReward.tokenRewardsPerEpoch(address(mockUSDC), epoch2Start), USDC_10K);

        // Move to epoch2; supply at epoch2Start is 0 because no lock existed at that checkpoint.
        skipToNextEpoch(1);
        assertEq(dustLock.totalSupplyAt(epoch2Start), 0, "scenario: epoch2 must have zero supply");

        // Now create a lock in epoch2; its reward credits epoch3.
        uint256 tokenId = _createLock(user, TOKEN_1, MAXTIME);
        _addReward(admin, mockUSDC, USDC_10K);

        // Move to epoch3 so the claim window spans the zero-supply epoch2 AND the funded epoch3.
        skipToNextEpoch(1);

        address[] memory tokens = new address[](1);
        tokens[0] = address(mockUSDC);

        uint256 balBefore = mockUSDC.balanceOf(user);
        vm.prank(user);
        revenueReward.getReward(tokenId, tokens);
        uint256 claimed = mockUSDC.balanceOf(user) - balBefore;

        // The zero-supply epoch2 budget (USDC_10K) is skipped; only the epoch3 budget can pay out.
        assertGt(claimed, 0, "epoch3 reward should pay");
        assertLe(claimed, USDC_10K, "must not pay the skipped zero-supply epoch budget");
        assertEq(revenueReward.lastEarnTime(address(mockUSDC), tokenId), block.timestamp);
    }

    /// @notice success==true but `unclaimedRewards == 0`: a fully-elapsed epoch with NO reward budget
    ///         advances lastEarnTime (success arm) yet emits/transfers nothing (the > 0 FALSE arm).
    function testProcessedEpochWithZeroRewardAdvancesTimeWithoutPayout() public {
        // Lock in epoch1; never notify any reward for mockUSDC's epoch budgets that this token sees.
        uint256 tokenId = _createLock(user, TOKEN_1, MAXTIME);

        // Register mockUSDC as a reward token (notify) but credit it to a FUTURE epoch the claim won't reach,
        // OR more simply: register it now (credits epoch2) and DO NOT let supply earn — instead claim a token
        // that holds zero balance at the funded epoch. Simplest: use a second token registered with zero-share.
        // Here: register mockUSDC for epoch2, then a SECOND independent lock dominates so this token's share
        // floors to 0 while still processing the epoch (success == true, unclaimedRewards == 0).
        _createLock(user2, TOKEN_100M, MAXTIME); // whale dominates supply
        _addReward(admin, mockUSDC, 1); // 1 base unit: user's tiny share floors to 0

        skipToNextEpoch(1);

        address[] memory tokens = new address[](1);
        tokens[0] = address(mockUSDC);

        uint256 balBefore = mockUSDC.balanceOf(user);
        vm.prank(user);
        revenueReward.getReward(tokenId, tokens);

        // Epoch was processed (success) so lastEarnTime advances, but the floored payout is 0.
        assertEq(mockUSDC.balanceOf(user), balBefore, "payout floors to zero for the dust share");
        assertEq(
            revenueReward.lastEarnTime(address(mockUSDC), tokenId),
            block.timestamp,
            "lastEarnTime advances on processed-but-zero epoch"
        );
        // The scaled remainder accumulator should be non-zero (precision carry recorded).
        assertGt(revenueReward.tokenRewardsRemainingAccScaled(address(mockUSDC), tokenId), 0);
    }

    /*//////////////////////////////////////////////////////////////
                  notifyAfterTokenSplit acc == 0 ARM
    //////////////////////////////////////////////////////////////*/

    /// @notice Splitting a token that has ZERO accumulated remainder for a registered reward token hits
    ///         the `acc != 0` FALSE arm in notifyAfterTokenSplit (no per-token remainder distribution),
    ///         while still initializing mint times and clearing source state.
    function testSplitWithZeroRemainderSkipsDistributionArm() public {
        // Register a reward token so the loop body in notifyAfterTokenSplit executes for it,
        // but ensure the split token carries NO accumulated remainder (acc == 0) for that token.
        _addReward(admin, mockUSDC, USDC_10K);

        uint256 tokenId = _createLock(user, 8 * TOKEN_1, MAXTIME);
        vm.prank(user);
        dustLock.lockPermanent(tokenId);

        // No epoch elapses before the split => remainder accumulator for this token stays 0.
        assertEq(revenueReward.tokenRewardsRemainingAccScaled(address(mockUSDC), tokenId), 0);

        vm.startPrank(user);
        dustLock.toggleSplit(user, true);
        dustLock.unlockPermanent(tokenId);
        (uint256 tokenId1, uint256 tokenId2) = dustLock.split(tokenId, 2 * TOKEN_1);
        vm.stopPrank();

        // acc was 0 -> the if-body never ran -> both children carry zero remainder for this token.
        assertEq(revenueReward.tokenRewardsRemainingAccScaled(address(mockUSDC), tokenId1), 0);
        assertEq(revenueReward.tokenRewardsRemainingAccScaled(address(mockUSDC), tokenId2), 0);

        // Mint times were still initialized for the children (statement coverage in the same function).
        assertEq(revenueReward.tokenMintTime(tokenId1), block.timestamp);
        assertEq(revenueReward.tokenMintTime(tokenId2), block.timestamp);

        // Source remainder cleared / source removed.
        assertEq(revenueReward.tokenRewardsRemainingAccScaled(address(mockUSDC), tokenId), 0);
    }

    /*//////////////////////////////////////////////////////////////
              getUsersWithSelfRepayingLoan RANGE / CLAMP ARMS
    //////////////////////////////////////////////////////////////*/

    /// @notice from > to reverts via CommonChecksLibrary.revertIfInvalidRange.
    function testGetUsersWithSelfRepayingLoanRevertsOnInvalidRange() public {
        vm.expectRevert(abi.encodeWithSelector(CommonChecksLibrary.InvalidRange.selector));
        revenueReward.getUsersWithSelfRepayingLoan(5, 1);
    }

    /// @notice from >= len returns an empty array (the early-empty arm).
    function testGetUsersWithSelfRepayingLoanFromBeyondLenReturnsEmpty() public {
        // No users enrolled yet => len == 0, so any from >= 0 returns empty.
        address[] memory empty = revenueReward.getUsersWithSelfRepayingLoan(0, 10);
        assertEq(empty.length, 0);

        // Enroll one user, then query starting past the end.
        uint256 tokenId = _createLock(user, TOKEN_1, MAXTIME);
        vm.prank(user);
        revenueReward.enableSelfRepayLoan(tokenId);

        address[] memory beyond = revenueReward.getUsersWithSelfRepayingLoan(5, 10);
        assertEq(beyond.length, 0, "from beyond len returns empty");
    }

    /// @notice to > len is clamped to len, returning all available users from `from`.
    function testGetUsersWithSelfRepayingLoanClampsToLen() public {
        uint256 id1 = _createLock(user, TOKEN_1, MAXTIME);
        uint256 id2 = _createLock(user1, TOKEN_1, MAXTIME);

        vm.prank(user);
        revenueReward.enableSelfRepayLoan(id1);
        vm.prank(user1);
        revenueReward.enableSelfRepayLoan(id2);

        // len == 2; ask for [0, 100) -> clamped to [0, 2).
        address[] memory all = revenueReward.getUsersWithSelfRepayingLoan(0, 100);
        assertEq(all.length, 2, "to clamps to len");

        // Ask for [1, 100) -> clamped to [1, 2) => single element.
        address[] memory tail = revenueReward.getUsersWithSelfRepayingLoan(1, 100);
        assertEq(tail.length, 1, "partial range with clamp");
    }

    /*//////////////////////////////////////////////////////////////
              SELF-REPAY ENUMERATION GETTERS (FUNCTIONAL)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The four self-repay enumeration getters report the correct counts, user set, and paged token slices.
     * @dev `user` (address(this)) holds three self-repay tokens, `user1` holds one. EnumerableSet preserves
     *      insertion order under add-only, so the user set is [user, user1] and the token set for `user` is
     *      [idA, idB, idC]. Exercises `usersWithSelfRepayingLoanLength`, `userTokensWithSelfRepayingLoanLength`,
     *      `getAllUsersWithSelfRepayingLoan`, and every `getUserTokensWithSelfRepayingLoanRange` arm.
     */
    function testSelfRepayEnumerationGetters() public {
        // user owns three tokens, enabled together via the batch entry point.
        uint256 idA = _createLock(user, TOKEN_1, MAXTIME);
        uint256 idB = _createLock(user, TOKEN_1, MAXTIME);
        uint256 idC = _createLock(user, TOKEN_1, MAXTIME);
        uint256[] memory userIds = new uint256[](3);
        userIds[0] = idA;
        userIds[1] = idB;
        userIds[2] = idC;
        revenueReward.enableSelfRepayLoanBatch(userIds);

        // user1 owns a single self-repay token.
        uint256 idD = _createLock(user1, TOKEN_1, MAXTIME);
        vm.prank(user1);
        revenueReward.enableSelfRepayLoan(idD);

        // (a) Length getters return the expected counts.
        assertEq(revenueReward.usersWithSelfRepayingLoanLength(), 2, "two users enrolled");
        assertEq(revenueReward.userTokensWithSelfRepayingLoanLength(user), 3, "user holds three tokens");
        assertEq(revenueReward.userTokensWithSelfRepayingLoanLength(user1), 1, "user1 holds one token");

        // (b) getAllUsersWithSelfRepayingLoan equals the known user set, in insertion order.
        address[] memory allUsers = revenueReward.getAllUsersWithSelfRepayingLoan();
        assertEq(allUsers.length, 2, "all-users length");
        assertEq(allUsers[0], user, "first enrolled user");
        assertEq(allUsers[1], user1, "second enrolled user");

        // (c) Interior slice [1, 2) => the single middle element idB.
        uint256[] memory mid = revenueReward.getUserTokensWithSelfRepayingLoanRange(user, 1, 2);
        assertEq(mid.length, 1, "interior slice length");
        assertEq(mid[0], idB, "interior slice element");

        // (c) to > len clamps to len: [1, 100) => [idB, idC].
        uint256[] memory clamped = revenueReward.getUserTokensWithSelfRepayingLoanRange(user, 1, 100);
        assertEq(clamped.length, 2, "clamped tail length");
        assertEq(clamped[0], idB, "clamped tail first");
        assertEq(clamped[1], idC, "clamped tail second");

        // (c) from >= len returns an empty array.
        uint256[] memory empty = revenueReward.getUserTokensWithSelfRepayingLoanRange(user, 3, 10);
        assertEq(empty.length, 0, "from beyond len returns empty");

        // (c) from > to reverts via CommonChecksLibrary.revertIfInvalidRange.
        vm.expectRevert(abi.encodeWithSelector(CommonChecksLibrary.InvalidRange.selector));
        revenueReward.getUserTokensWithSelfRepayingLoanRange(user, 3, 1);
    }

    /**
     * @dev Transfers `tokenId` from `from` to `to` while the DustLock -> RevenueReward hook is disabled
     *      (the emergency valve), so the moved token keeps its stale self-repay receiver.
     */
    function _transferWhileHooksDisabled(uint256 tokenId, address from, address to) private {
        dustLock.setRevenueReward(IRevenueReward(address(0)));
        dustLock.transferFrom(from, to, tokenId);
        dustLock.setRevenueReward(revenueReward);
    }

    /**
     * @dev Burns `tokenId` via `earlyWithdraw` (pranked as `owner`) while the DustLock -> RevenueReward hook is
     *      disabled (the emergency valve), so the burned token keeps its stale self-repay receiver and accrual.
     */
    function _earlyWithdrawWhileHooksDisabled(uint256 tokenId, address owner) private {
        dustLock.setRevenueReward(IRevenueReward(address(0)));
        vm.prank(owner);
        dustLock.earlyWithdraw(tokenId);
        dustLock.setRevenueReward(revenueReward);
    }

    /**
     * @notice Split does not carry a stale self-repay receiver onto the child tokens.
     * @dev During a hooks-disabled window (revenueReward unset) a transferred SRL token keeps its
     *      former-owner receiver. That receiver is not the new owner's vault, so the split hook does
     *      not propagate it: the children get no receiver and the new owner is not enrolled.
     */
    function testSplitDoesNotCarryStaleReceiverToChildren() public {
        uint256 tokenId = _createLock(user, TOKEN_1K, MAXTIME);
        revenueReward.enableSelfRepayLoan(tokenId);
        assertEq(revenueReward.usersWithSelfRepayingLoanLength(), 1, "user enrolled");

        // Hooks-disabled window leaves the former owner's receiver stale on the token.
        _transferWhileHooksDisabled(tokenId, user, user1);
        assertEq(revenueReward.userTokensWithSelfRepayingLoanLength(user1), 0, "new owner unindexed");

        dustLock.toggleSplit(user1, true);
        vm.prank(user1);
        (uint256 child1, uint256 child2) = dustLock.split(tokenId, TOKEN_1K / 2);

        // The stale receiver is not the new owner's vault, so it is not carried to the children.
        assertEq(revenueReward.tokenRewardReceiver(child1), address(0), "child 1 has no stale receiver");
        assertEq(revenueReward.tokenRewardReceiver(child2), address(0), "child 2 has no stale receiver");
        assertEq(revenueReward.userTokensWithSelfRepayingLoanLength(user1), 0, "new owner not enrolled by split");
    }

    /**
     * @notice A stale self-repay receiver from a hooks-disabled-window transfer does not misroute a claim.
     * @dev The stored receiver points at the previous owner's vault, which is not the new owner's canonical
     *      vault, so the claim resolves to the current owner and the stale vault receives nothing.
     */
    function testStaleReceiverClaimRoutesToCurrentOwnerNotPriorVault() public {
        uint256 tokenId = _createLock(user, TOKEN_1K, MAXTIME);
        revenueReward.enableSelfRepayLoan(tokenId);
        address priorVault = revenueReward.tokenRewardReceiver(tokenId);
        assertTrue(priorVault != address(0), "self-repay vault set");

        // Hooks-disabled window leaves the previous owner's receiver stale on the token.
        _transferWhileHooksDisabled(tokenId, user, user1);
        assertEq(revenueReward.tokenRewardReceiver(tokenId), priorVault, "receiver remained stale");
        assertEq(dustLock.ownerOf(tokenId), user1, "user1 is the current owner");

        // Fund an epoch and claim as the current owner.
        _addReward(admin, mockUSDC, USDC_10K);
        skipToNextEpoch(1);
        address[] memory tokens = new address[](1);
        tokens[0] = address(mockUSDC);
        uint256 vaultBefore = mockUSDC.balanceOf(priorVault);
        uint256 ownerBefore = mockUSDC.balanceOf(user1);

        vm.prank(user1);
        revenueReward.getReward(tokenId, tokens);

        // Rewards route to the current owner; the stale prior vault receives nothing.
        assertGt(mockUSDC.balanceOf(user1), ownerBefore, "current owner received the rewards");
        assertEq(mockUSDC.balanceOf(priorVault), vaultBefore, "stale prior vault received nothing");
    }

    /**
     * @notice A self-repay veNFT burned during a hooks-disabled window keeps its rewards claimable to the vault.
     * @dev Regression pin for the resolver freeze: before the fix, `_resolveRewardsReceiver` called
     *      `dustLock.ownerOf` unconditionally and reverted `InvalidTokenId` for the burned token, so every claim
     *      path reverted and the accrued rewards were permanently frozen. The try/catch resolver now salvages them
     *      to the stored self-repay vault while still guarding live tokens against misrouting.
     */
    function testBurnedSelfRepayTokenRewardsRemainClaimableToVault() public {
        _addReward(admin, mockUSDC, USDC_10K);
        uint256 tokenId = _createLock(user, TOKEN_1K, MAXTIME);
        revenueReward.enableSelfRepayLoan(tokenId);
        address vault = revenueReward.tokenRewardReceiver(tokenId);
        assertTrue(vault != address(0), "self-repay vault set");

        skipToNextEpoch(1);

        // Burn during a hooks-disabled window: the burn hook is skipped, leaving the receiver and accrual stale.
        _earlyWithdrawWhileHooksDisabled(tokenId, user);

        address[] memory tokens = new address[](1);
        tokens[0] = address(mockUSDC);
        uint256 vaultBefore = mockUSDC.balanceOf(vault);

        // Pre-fix this reverted InvalidTokenId (permanent freeze); post-fix it salvages to the stored vault.
        vm.prank(vault);
        revenueReward.getReward(tokenId, tokens);

        assertGt(mockUSDC.balanceOf(vault), vaultBefore, "burned self-repay token rewards salvaged to the vault");
    }

    /**
     * @notice A stranger cannot claim a burned self-repay token's salvaged rewards; only the stored vault may.
     * @dev Negative pin for the resolver freeze fix: the claim gate resolves the receiver, then requires the caller
     *      to be the token's approver/owner or that receiver. A burned token has no owner, so an arbitrary caller
     *      that is not the stored vault reverts `NotOwner`.
     */
    function testBurnedSelfRepayFallbackRejectsStranger() public {
        _addReward(admin, mockUSDC, USDC_10K);
        uint256 tokenId = _createLock(user, TOKEN_1K, MAXTIME);
        revenueReward.enableSelfRepayLoan(tokenId);

        skipToNextEpoch(1);

        _earlyWithdrawWhileHooksDisabled(tokenId, user);

        address[] memory tokens = new address[](1);
        tokens[0] = address(mockUSDC);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IRevenueReward.NotOwner.selector));
        revenueReward.getReward(tokenId, tokens);
    }

    /**
     * @notice Claiming a burned self-repay token's salvaged rewards is idempotent; a re-claim pays nothing more.
     * @dev Pin that the fallback path advances `lastEarnTime` like the live path, so the stored vault cannot
     *      double-claim the same accrual.
     */
    function testBurnedSelfRepayFallbackClaimIsIdempotent() public {
        _addReward(admin, mockUSDC, USDC_10K);
        uint256 tokenId = _createLock(user, TOKEN_1K, MAXTIME);
        revenueReward.enableSelfRepayLoan(tokenId);
        address vault = revenueReward.tokenRewardReceiver(tokenId);

        skipToNextEpoch(1);

        _earlyWithdrawWhileHooksDisabled(tokenId, user);

        address[] memory tokens = new address[](1);
        tokens[0] = address(mockUSDC);

        vm.prank(vault);
        revenueReward.getReward(tokenId, tokens);
        uint256 vaultAfterFirst = mockUSDC.balanceOf(vault);
        assertGt(vaultAfterFirst, 0, "first claim salvaged rewards");

        vm.prank(vault);
        revenueReward.getReward(tokenId, tokens);
        assertEq(mockUSDC.balanceOf(vault), vaultAfterFirst, "re-claim pays nothing more");
    }

    /**
     * @notice A veNFT id that never had a receiver reverts `InvalidTokenId` through the resolver's catch path.
     * @dev Parity pin: the try/catch salvages a burned token with a stored receiver, but a never-configured id
     *      (no owner, no stored receiver) still reverts `InvalidTokenId` rather than resolving to `address(0)`.
     */
    function testNeverConfiguredTokenRevertsInvalidTokenId() public {
        _addReward(admin, mockUSDC, USDC_10K);

        address[] memory tokens = new address[](1);
        tokens[0] = address(mockUSDC);

        uint256 neverMinted = 999_999;
        vm.expectRevert(abi.encodeWithSelector(CommonChecksLibrary.InvalidTokenId.selector));
        revenueReward.getReward(neverMinted, tokens);
    }

    /**
     * @notice The merge closeout of a token with a stale self-repay receiver pays the current owner, not the stale vault.
     * @dev Regression pin for the merge/split closeout hardening: the source-token payout now resolves against the
     *      passed owner's canonical vault (via `_receiverForOwner`), so a receiver left stale by a hooks-disabled
     *      transfer no longer captures the current owner's accrued rewards on the merge path.
     */
    function testMergeCloseoutRoutesStaleReceiverToCurrentOwner() public {
        _addReward(admin, mockUSDC, USDC_10K);
        uint256 tokenId = _createLock(user, TOKEN_1K, MAXTIME);
        revenueReward.enableSelfRepayLoan(tokenId);
        address staleVault = revenueReward.tokenRewardReceiver(tokenId);

        _transferWhileHooksDisabled(tokenId, user, user1);
        assertEq(revenueReward.tokenRewardReceiver(tokenId), staleVault, "receiver remained stale");

        uint256 destId = _createLock(user1, TOKEN_1K, MAXTIME);
        skipToNextEpoch(1);

        uint256 ownerBefore = mockUSDC.balanceOf(user1);
        uint256 staleVaultBefore = mockUSDC.balanceOf(staleVault);

        vm.prank(user1);
        dustLock.merge(tokenId, destId);

        assertGt(mockUSDC.balanceOf(user1), ownerBefore, "merge closeout routes to the current owner");
        assertEq(mockUSDC.balanceOf(staleVault), staleVaultBefore, "stale prior vault receives nothing");
    }

    /**
     * @notice The split closeout of a token with a stale self-repay receiver pays the current owner, not the stale vault.
     * @dev Companion pin to the merge case, covering `notifyAfterTokenSplit`'s source-token payout.
     */
    function testSplitCloseoutRoutesStaleReceiverToCurrentOwner() public {
        _addReward(admin, mockUSDC, USDC_10K);
        uint256 tokenId = _createLock(user, TOKEN_1K, MAXTIME);
        revenueReward.enableSelfRepayLoan(tokenId);
        address staleVault = revenueReward.tokenRewardReceiver(tokenId);

        _transferWhileHooksDisabled(tokenId, user, user1);
        skipToNextEpoch(1);

        dustLock.toggleSplit(user1, true);
        uint256 ownerBefore = mockUSDC.balanceOf(user1);
        uint256 staleVaultBefore = mockUSDC.balanceOf(staleVault);

        vm.prank(user1);
        dustLock.split(tokenId, TOKEN_1K / 2);

        assertGt(mockUSDC.balanceOf(user1), ownerBefore, "split closeout routes to the current owner");
        assertEq(mockUSDC.balanceOf(staleVault), staleVaultBefore, "stale prior vault receives nothing");
    }

    /*//////////////////////////////////////////////////////////////
              enable/disable batch ARRAY-LENGTH REVERT ARMS
    //////////////////////////////////////////////////////////////*/

    /// @notice enableSelfRepayLoanBatch with an empty array reverts (InvalidArrayLengths).
    function testEnableSelfRepayLoanBatchRevertsOnEmptyArray() public {
        uint256[] memory ids = new uint256[](0);

        vm.expectRevert(abi.encodeWithSelector(IRevenueReward.InvalidArrayLengths.selector));
        revenueReward.enableSelfRepayLoanBatch(ids);
    }

    /// @notice disableSelfRepayLoanBatch with an empty array reverts (InvalidArrayLengths).
    function testDisableSelfRepayLoanBatchRevertsOnEmptyArray() public {
        uint256[] memory ids = new uint256[](0);

        vm.expectRevert(abi.encodeWithSelector(IRevenueReward.InvalidArrayLengths.selector));
        revenueReward.disableSelfRepayLoanBatch(ids);
    }

    /**
     * @notice enableSelfRepayLoanBatch above MAX_TOKENIDS (65 ids) reverts (InvalidArrayLengths).
     * @dev The length gate fires before any per-id ownership work, so dummy ids suffice.
     */
    function testEnableSelfRepayLoanBatchRevertsOnTooManyTokenIds() public {
        uint256[] memory ids = new uint256[](revenueReward.MAX_TOKENIDS() + 1);

        vm.expectRevert(abi.encodeWithSelector(IRevenueReward.InvalidArrayLengths.selector));
        revenueReward.enableSelfRepayLoanBatch(ids);
    }

    /**
     * @notice disableSelfRepayLoanBatch above MAX_TOKENIDS (65 ids) reverts (InvalidArrayLengths).
     * @dev The length gate fires before any per-id ownership work, so dummy ids suffice.
     */
    function testDisableSelfRepayLoanBatchRevertsOnTooManyTokenIds() public {
        uint256[] memory ids = new uint256[](revenueReward.MAX_TOKENIDS() + 1);

        vm.expectRevert(abi.encodeWithSelector(IRevenueReward.InvalidArrayLengths.selector));
        revenueReward.disableSelfRepayLoanBatch(ids);
    }

    /// @notice getRewardUntilTs with an empty tokens array reverts via _validateTokensArray.
    function testGetRewardUntilTsRevertsOnEmptyTokensArray() public {
        uint256 tokenId = _createLock(user, TOKEN_1, MAXTIME);

        address[] memory tokens = new address[](0);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IRevenueReward.InvalidArrayLengths.selector));
        revenueReward.getRewardUntilTs(tokenId, tokens, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
            _finalizedRewardPeriodEndTs FUTURE + ZERO ARMS
    //////////////////////////////////////////////////////////////*/

    /// @notice A future endTs reverts with EndTimestampMoreThanCurrent (the `endTs > block.timestamp` arm).
    function testGetRewardUntilTsRevertsOnFutureTimestamp() public {
        uint256 tokenId = _createLock(user, TOKEN_1, MAXTIME);

        address[] memory tokens = new address[](1);
        tokens[0] = address(mockUSDC);
        _addReward(admin, mockUSDC, USDC_10K);
        skipToNextEpoch(1);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IRevenueReward.EndTimestampMoreThanCurrent.selector));
        revenueReward.getRewardUntilTs(tokenId, tokens, block.timestamp + 1);
    }

    /// @notice endTs == 0 passes through the deferral guard unchanged (the `endTs != 0` short-circuit),
    ///         producing a no-op claim (nothing earned before genesis) without reverting.
    function testGetRewardUntilTsZeroTimestampPassesThroughNoOp() public {
        uint256 tokenId = _createLock(user, TOKEN_1, MAXTIME);
        _addReward(admin, mockUSDC, USDC_10K);
        skipToNextEpoch(1);

        address[] memory tokens = new address[](1);
        tokens[0] = address(mockUSDC);

        uint256 balBefore = mockUSDC.balanceOf(user);

        // endTs == 0 is not "in the future" and bypasses the boundary deferral; epochStart(0) == 0
        // so startTs > endTsEpoch and _earned returns false (no payout, no revert).
        vm.prank(user);
        revenueReward.getRewardUntilTs(tokenId, tokens, 0);

        assertEq(mockUSDC.balanceOf(user), balBefore, "endTs==0 yields no payout");
        assertEq(revenueReward.lastEarnTime(address(mockUSDC), tokenId), 0);
    }

    /// @notice The exact-boundary guard applies even when the requested claim end is already finalized.
    function testGetRewardUntilTsBackdatedAtExactBoundaryDefersUntilTPlusOne() public {
        uint256 tokenId = _createLock(user, TOKEN_1, MAXTIME);
        _addReward(admin, mockUSDC, USDC_10K);
        skipToNextEpoch(1);
        uint256 finalizedPastTs = block.timestamp;

        address[] memory tokens = new address[](1);
        tokens[0] = address(mockUSDC);
        uint256 expected = revenueReward.earnedRewards(address(mockUSDC), tokenId, finalizedPastTs);
        assertGt(expected, 0, "past timestamp should include finalized rewards");

        skipToNextEpoch(0);
        assertEq(block.timestamp % WEEK, 0, "test must align to exact epoch boundary");

        uint256 balanceBefore = mockUSDC.balanceOf(user);
        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        vm.prank(user);
        revenueReward.getRewardUntilTs(tokenId, tokens, finalizedPastTs);
        assertEq(mockUSDC.balanceOf(user), balanceBefore, "boundary claim must roll back");

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        vm.prank(user);
        revenueReward.getRewardUntilTs(tokenId, tokens, finalizedPastTs);

        assertEq(mockUSDC.balanceOf(user), expected, "backdated claim pays finalized rewards at the boundary");
    }

    /// @notice An exact-current-boundary preview defers epoch T until the following second.
    function testEarnedRewardsAtExactCurrentBoundaryDefersBoundaryEpoch() public {
        uint256 tokenId = _createLock(user, TOKEN_1, MAXTIME);
        _addReward(admin, mockUSDC, USDC_10K);
        skipToNextEpoch(0);
        assertEq(block.timestamp % WEEK, 0, "test must align to exact epoch boundary");

        uint256 boundary = block.timestamp;
        uint256 epochReward = revenueReward.tokenRewardsPerEpoch(address(mockUSDC), boundary);
        assertGt(epochReward, 0, "boundary epoch must be funded");

        uint256 boundaryPreview = revenueReward.earnedRewards(address(mockUSDC), tokenId, boundary);
        assertEq(boundaryPreview, 0, "boundary preview should defer epoch T");

        vm.warp(boundary + 1);
        vm.roll(block.number + 1);
        assertEq(
            revenueReward.earnedRewards(address(mockUSDC), tokenId, boundary),
            epochReward,
            "T+1 preview should include finalized epoch T"
        );
    }

    /// @notice Every state-changing claim entry point shares the exact-boundary retry guard.
    function testEveryClaimEntryPointDefersAtExactCurrentBoundary() public {
        uint256 tokenId = _createLock(user, TOKEN_1, MAXTIME);
        _addReward(admin, mockUSDC, USDC_10K);
        skipToNextEpoch(0);

        uint256 boundary = block.timestamp;
        address[] memory tokens = new address[](1);
        tokens[0] = address(mockUSDC);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;

        vm.startPrank(user);
        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        revenueReward.getReward(tokenId, tokens);
        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        revenueReward.getRewardUntilTs(tokenId, tokens, boundary - 1);
        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        revenueReward.getRewardBatch(tokenIds, tokens);
        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        revenueReward.getRewardUntilTsBatch(tokenIds, tokens, boundary - 1);
        vm.stopPrank();

        assertEq(mockUSDC.balanceOf(user), 0, "boundary claim matrix must not pay");
        assertEq(revenueReward.lastEarnTime(address(mockUSDC), tokenId), 0, "boundary claim matrix must not advance");

        vm.warp(boundary + 1);
        vm.roll(block.number + 1);
        vm.prank(user);
        revenueReward.getReward(tokenId, tokens);
        assertEq(mockUSDC.balanceOf(user), USDC_10K, "T+1 claim must settle epoch T exactly once");
    }

    /*//////////////////////////////////////////////////////////////
                          HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _createLock(address _user, uint256 _amount, uint256 _duration) private returns (uint256 tokenId) {
        mintErc20Token(address(DUST), _user, _amount);

        vm.startPrank(_user);
        DUST.approve(address(dustLock), _amount);
        tokenId = dustLock.createLock(_amount, _duration);
        vm.stopPrank();
    }

    function _addReward(address _user, IERC20 _token, uint256 _amount) private {
        mintErc20Token(address(_token), _user, _amount);

        vm.startPrank(_user);
        _token.approve(address(revenueReward), _amount);
        revenueReward.notifyRewardAmount(address(_token), _amount);
        vm.stopPrank();
    }
}
