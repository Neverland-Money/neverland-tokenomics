// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IDustLock} from "../../../src/interfaces/IDustLock.sol";
import {IDustLockTransferStrategy} from "../../../src/interfaces/IDustLockTransferStrategy.sol";
import {IDustTransferStrategy} from "../../../src/interfaces/IDustTransferStrategy.sol";

import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";

import {DustLockTransferStrategy} from "../../../src/emissions/DustLockTransferStrategy.sol";
import {BaseTestLocal} from "../../BaseTestLocal.sol";

contract PredecessorDustLockMock {
    address public token;
    string public constant version = "2.0.0";

    constructor(address token_) {
        token = token_;
    }

    function setToken(address token_) external {
        token = token_;
    }

    function earlyWithdrawTreasury() external view returns (address) {
        return address(this);
    }
}

contract ClaimReformDustLockMock {
    address public immutable token;
    string public constant version = "tracking-only";

    constructor(address token_) {
        token = token_;
    }

    function earlyWithdrawPenaltyAmount(uint256) external pure returns (uint256) {
        return 0;
    }

    function earlyWithdrawTreasury() external view returns (address) {
        return address(this);
    }
}

contract ReturnDataBombDustLockMock {
    address public immutable token;

    constructor(address token_) {
        token = token_;
    }

    fallback() external {
        assembly ("memory-safe") {
            return(0, 0x10000)
        }
    }
}

contract VaultPullRevertingTokenMock {
    error UnexpectedVaultPull();

    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert UnexpectedVaultPull();
    }
}

contract NonZeroCapabilityWordDustLockMock {
    address public immutable token;

    constructor(address token_) {
        token = token_;
    }

    function earlyWithdrawPenaltyAmount(uint256) external pure returns (uint256) {
        return 2;
    }

    function earlyWithdrawTreasury() external pure returns (address) {
        return address(0xbeef);
    }
}

contract TransferStrategyControllerMock {
    address internal strategy;

    function setStrategy(address strategy_) external {
        strategy = strategy_;
    }

    function getTransferStrategy(address) external view returns (address) {
        return strategy;
    }

    function perform(address to, address reward, uint256 amount, uint256 lockTime, uint256 tokenId)
        external
        returns (bool)
    {
        return IDustTransferStrategy(strategy).performTransfer(to, reward, amount, lockTime, tokenId);
    }
}

contract DustLockTransferStrategyPricingTest is BaseTestLocal {
    DustLockTransferStrategy internal strategy;
    address internal dustVault = address(0xd057);
    address internal incentivesController = address(0xc017);

    function _setUp() internal override {
        mintErc20Token(address(DUST), dustVault, TOKEN_10M);
        mintErc20Token(address(DUST), user2, TOKEN_100K);

        strategy = new DustLockTransferStrategy(incentivesController, admin, dustVault, address(dustLock));
        vm.prank(dustVault);
        DUST.approve(address(strategy), type(uint256).max);
    }

    /**
     * @notice Calculates the independent expected timed-claim penalty and proceeds
     * @param amount Gross DUST reward amount
     * @param commitment Realized commitment duration in seconds
     * @return penalty Exact expected penalty remainder
     * @return net Exact expected locked proceeds
     */
    function _expectedTimedClaim(uint256 amount, uint256 commitment)
        internal
        pure
        returns (uint256 penalty, uint256 net)
    {
        // Commitments in the top week band are untolled, matching the strategy's ZERO_TOLL_COMMITMENT.
        if (commitment >= MAXTIME - 1 weeks) return (0, amount);

        net = Math.mulDiv(amount, 3 * MAXTIME - 5 * MINTIME + 2 * commitment, 5 * (MAXTIME - MINTIME));
        penalty = amount - net;
    }

    /**
     * @notice Applies DustLock weekly end rounding to a requested duration
     * @param lockTime Requested commitment duration in seconds
     * @return commitment Realized commitment duration in seconds
     */
    function _realizedCommitment(uint256 lockTime) internal view returns (uint256 commitment) {
        return ((block.timestamp + lockTime) / WEEK) * WEEK - block.timestamp;
    }

    function testPreviewInstantPreservesOddWeiConvention() public view {
        assertEq(strategy.version(), 3);
        (uint256 evenPenalty, uint256 evenNet) = strategy.previewClaim(TOKEN_1, 0, 0);
        assertEq(evenPenalty, TOKEN_1 / 2);
        assertEq(evenNet, TOKEN_1 / 2);

        (uint256 oddPenalty, uint256 oddNet) = strategy.previewClaim(TOKEN_1 + 1, 0, 0);
        assertEq(oddPenalty, (TOKEN_1 + 1) / 2);
        assertEq(oddNet, TOKEN_1 + 1 - oddPenalty);
        (uint256 zeroPenalty, uint256 zeroNet) = strategy.previewClaim(0, type(uint256).max, type(uint256).max);
        assertEq(zeroPenalty, 0);
        assertEq(zeroNet, 0);
    }

    function testPreviewNewTimedUsesRealizedWeeklyCommitment() public view {
        uint256 amount = TOKEN_10K;
        uint256 lockTime = MINTIME + WEEK;
        uint256 commitment = _realizedCommitment(lockTime);
        (uint256 expectedPenalty, uint256 expectedNet) = _expectedTimedClaim(amount, commitment);

        (uint256 penalty, uint256 net) = strategy.previewClaim(amount, lockTime, 0);
        assertEq(penalty, expectedPenalty);
        assertEq(net, expectedNet);
        assertEq(penalty + net, amount);
    }

    function testPreviewRejectsExactMinDurationAtBoundaryPlusOne() public {
        uint256 amount = TOKEN_10K;
        /*
         * Accepted behavior: exact week-multiple durations are unpurchasable. One second after a weekly
         * boundary an exact-MINTIME request rounds to a 1-second-short commitment and reverts.
         */
        vm.warp(2 weeks + 1);
        vm.expectRevert(IDustLock.LockDurationTooShort.selector);
        strategy.previewClaim(amount, MINTIME, 0);

        // It also reverts one second before the boundary, where the floor pulls the end down a full week.
        vm.warp(3 weeks - 1);
        vm.expectRevert(IDustLock.LockDurationTooShort.selector);
        strategy.previewClaim(amount, MINTIME, 0);

        // A request with slack over the grid survives: MINTIME + 1 second rounds onto the boundary.
        (uint256 penalty, uint256 net) = strategy.previewClaim(amount, MINTIME + 1, 0);
        (uint256 expectedPenalty, uint256 expectedNet) = _expectedTimedClaim(amount, _realizedCommitment(MINTIME + 1));
        assertEq(penalty, expectedPenalty);
        assertEq(net, expectedNet);
        assertEq(penalty + net, amount);
    }

    function testPreviewValidatesMaxDurationAfterWeeklyRounding() public view {
        uint256 amount = TOKEN_10K;
        // Slightly over MAX but rounds down to <= now + MAX: DustLock accepts, so the strategy must not pre-reject it.
        (uint256 penalty, uint256 net) = strategy.previewClaim(amount, MAXTIME + 1, 0);
        (uint256 expectedPenalty, uint256 expectedNet) = _expectedTimedClaim(amount, _realizedCommitment(MAXTIME + 1));
        assertEq(penalty, expectedPenalty);
        assertEq(net, expectedNet);
    }

    function testPerformTransferEmitsRewardClaimPricedForEveryRoute() public {
        vm.warp(2 weeks + 1);
        uint256 amount = TOKEN_10K;

        // Instant liquid route: no lock, fixed half penalty, destination token id zero.
        uint256 instantPenalty = amount / 2;

        vm.expectEmit(true, true, false, true, address(strategy));
        emit IDustLockTransferStrategy.RewardClaimPriced(user2, 0, 0, amount, instantPenalty, amount - instantPenalty);
        vm.prank(incentivesController);
        strategy.performTransfer(user2, address(DUST), amount, 0, 0);

        // New timed lock route: destination token id is the freshly minted veNFT.
        uint256 lockTime = MINTIME + WEEK;
        (uint256 timedPenalty, uint256 timedNet) = _expectedTimedClaim(amount, _realizedCommitment(lockTime));
        uint256 newTimedId = dustLock.tokenId() + 1;

        vm.expectEmit(true, true, false, true, address(strategy));
        emit IDustLockTransferStrategy.RewardClaimPriced(user2, newTimedId, lockTime, amount, timedPenalty, timedNet);
        vm.prank(incentivesController);
        strategy.performTransfer(user2, address(DUST), amount, lockTime, 0);

        assertEq(dustLock.ownerOf(newTimedId), user2);

        // Permanent lock route: zero penalty, destination token id is the new permanent veNFT.
        uint256 permanentId = dustLock.tokenId() + 1;

        vm.expectEmit(true, true, false, true, address(strategy));
        emit IDustLockTransferStrategy.RewardClaimPriced(user2, permanentId, type(uint256).max, amount, 0, amount);
        vm.prank(incentivesController);
        strategy.performTransfer(user2, address(DUST), amount, type(uint256).max, 0);

        assertTrue(dustLock.locked(permanentId).isPermanent);

        // Existing timed lock route: destination token id is the supplied veNFT, priced by its remaining commitment.
        vm.startPrank(user2);
        DUST.approve(address(dustLock), type(uint256).max);
        uint256 existingId = dustLock.createLock(TOKEN_1K, 90 days);
        vm.stopPrank();
        uint256 remaining = dustLock.locked(existingId).end - block.timestamp;
        (uint256 existingPenalty, uint256 existingNet) = _expectedTimedClaim(amount, remaining);

        vm.expectEmit(true, true, false, true, address(strategy));
        emit IDustLockTransferStrategy.RewardClaimPriced(user2, existingId, 0, amount, existingPenalty, existingNet);
        vm.prank(incentivesController);
        strategy.performTransfer(user2, address(DUST), amount, 0, existingId);
    }

    function testNewLockRouteRevertsWhenNetFallsBelowMinimumLockAmount() public {
        uint256 gross = TOKEN_1 + TOKEN_1 / 2;
        uint256 vaultBefore = DUST.balanceOf(dustVault);
        (, uint256 net) = strategy.previewClaim(gross, MINTIME + WEEK, 0);

        // Net prices below DustLock's minimum: the lock route must revert atomically with no vault funds moved.
        assertLt(net, dustLock.minLockAmount());

        vm.prank(incentivesController);
        vm.expectRevert(IDustLock.AmountTooSmall.selector);
        strategy.performTransfer(user2, address(DUST), gross, MINTIME + WEEK, 0);

        assertEq(DUST.balanceOf(dustVault), vaultBefore);
    }

    function testPreviewTimedClaimExplicitCommitmentBoundaries() public {
        uint256 amount = TOKEN_10K;

        vm.warp(2 weeks);
        (uint256 minPenalty, uint256 minNet) = strategy.previewClaim(amount, MINTIME, 0);
        (uint256 expectedMinPenalty, uint256 expectedMinNet) = _expectedTimedClaim(amount, MINTIME);
        assertEq(minPenalty, expectedMinPenalty);
        assertEq(minNet, expectedMinNet);

        (uint256 day364Penalty, uint256 day364Net) = strategy.previewClaim(amount, 364 days, 0);
        (uint256 expected364Penalty, uint256 expected364Net) = _expectedTimedClaim(amount, 364 days);
        assertEq(day364Penalty, expected364Penalty);
        assertEq(day364Net, expected364Net);

        vm.warp(20 days);
        assertEq(block.timestamp % WEEK, 6 days);
        (uint256 maxPenalty, uint256 maxNet) = strategy.previewClaim(amount, MAXTIME, 0);
        (uint256 expectedMaxPenalty, uint256 expectedMaxNet) = _expectedTimedClaim(amount, MAXTIME);
        assertEq(maxPenalty, expectedMaxPenalty);
        assertEq(maxNet, expectedMaxNet);
        assertEq(maxPenalty, 0);
        assertEq(maxNet, amount);
    }

    function testPreviewZeroTollBandStartsExactlyAtMaxMinusWeek() public {
        uint256 amount = TOKEN_10K;
        vm.warp(20 days);

        // At MAXTIME - WEEK the toll vanishes; one second below it the linear toll still applies.
        (uint256 bandPenalty, uint256 bandNet) = strategy.previewClaim(amount, MAXTIME - WEEK, 0);
        assertEq(bandPenalty, 0);
        assertEq(bandNet, amount);

        (uint256 belowPenalty, uint256 belowNet) = strategy.previewClaim(amount, MAXTIME - WEEK - 1, 0);
        (uint256 expectedBelowPenalty, uint256 expectedBelowNet) =
            _expectedTimedClaim(amount, _realizedCommitment(MAXTIME - WEEK - 1));
        assertEq(belowPenalty, expectedBelowPenalty);
        assertEq(belowNet, expectedBelowNet);
        assertGt(belowPenalty, 0);
    }

    function testPreviewExistingTimedAcceptsExactlyMinimumRemaining() public {
        vm.warp(2 weeks + 1);
        vm.startPrank(user2);
        DUST.approve(address(dustLock), type(uint256).max);
        uint256 tokenId = dustLock.createLock(TOKEN_1K, MINTIME + WEEK);
        vm.stopPrank();
        IDustLock.LockedBalance memory lock = dustLock.locked(tokenId);
        vm.warp(lock.end - MINTIME);

        (uint256 penalty, uint256 net) = strategy.previewClaim(TOKEN_10K, 0, tokenId);
        (uint256 expectedPenalty, uint256 expectedNet) = _expectedTimedClaim(TOKEN_10K, MINTIME);
        assertEq(penalty, expectedPenalty);
        assertEq(net, expectedNet);
    }

    function testPreviewExistingTimedRejectsExpiredLock() public {
        vm.startPrank(user2);
        DUST.approve(address(dustLock), type(uint256).max);
        uint256 tokenId = dustLock.createLock(TOKEN_1K, MINTIME + WEEK);
        vm.stopPrank();
        vm.warp(dustLock.locked(tokenId).end);

        vm.expectRevert(IDustLock.LockExpired.selector);
        strategy.previewClaim(TOKEN_10K, 0, tokenId);
    }

    function testPreviewExistingTimedRejectsRemainingAboveMaximum() public {
        uint256 tokenId = 1;
        IDustLock.LockedBalance memory impossibleLock = IDustLock.LockedBalance({
            amount: int256(TOKEN_1K),
            effectiveStart: block.timestamp,
            end: block.timestamp + MAXTIME + 1,
            isPermanent: false
        });
        vm.mockCall(
            address(dustLock), abi.encodeWithSelector(IDustLock.locked.selector, tokenId), abi.encode(impossibleLock)
        );

        vm.expectRevert(IDustLock.LockDurationTooLong.selector);
        strategy.previewClaim(TOKEN_10K, 0, tokenId);
    }

    function testPreviewRejectsRealizedCommitmentBelowMinimum() public {
        // Off the weekly boundary, an exact-MINTIME request rounds to a below-min commitment and reverts.
        vm.warp(2 weeks + 1 days);

        vm.expectRevert(IDustLock.LockDurationTooShort.selector);
        strategy.previewClaim(TOKEN_10K, MINTIME, 0);
    }

    function testTinyPositiveNewLockDurationFailsWithCustomErrorBeforeVaultPull() public {
        vm.warp(((block.timestamp / WEEK) + 1) * WEEK + 1);
        uint256 vaultBefore = DUST.balanceOf(dustVault);

        vm.expectRevert(IDustLock.LockDurationTooShort.selector);
        strategy.previewClaim(TOKEN_10K, 1, 0);

        vm.prank(incentivesController);
        vm.expectRevert(IDustLock.LockDurationTooShort.selector);
        strategy.performTransfer(user2, address(DUST), TOKEN_10K, 1, 0);
        assertEq(DUST.balanceOf(dustVault), vaultBefore);
    }

    function testPreviewRejectsRequestedDurationAboveMaximum() public {
        // A duration whose realized (week-rounded) unlockTime exceeds now + MAX still reverts.
        vm.expectRevert(IDustLock.LockDurationTooLong.selector);
        strategy.previewClaim(TOKEN_10K, 400 days, 0);
    }

    function testInstantActionRoutesPenaltyToEarlyWithdrawTreasury() public {
        dustLock.setEarlyWithdrawTreasury(user3);
        uint256 amount = TOKEN_1 + 1;
        (uint256 penalty, uint256 net) = strategy.previewClaim(amount, 0, 0);
        uint256 vaultBefore = DUST.balanceOf(dustVault);
        uint256 userBefore = DUST.balanceOf(user2);
        uint256 treasuryBefore = DUST.balanceOf(user3);
        uint256 supplyBefore = DUST.totalSupply();

        vm.prank(incentivesController);
        assertTrue(strategy.performTransfer(user2, address(DUST), amount, 0, 0));

        assertEq(vaultBefore - DUST.balanceOf(dustVault), amount);
        assertEq(DUST.balanceOf(user2) - userBefore, net);
        assertEq(DUST.balanceOf(user3) - treasuryBefore, penalty);
        assertEq(DUST.totalSupply(), supplyBefore);
    }

    function testExactEpochInstantActionRemainsExecutable() public {
        dustLock.setEarlyWithdrawTreasury(user3);
        uint256 boundary = ((block.timestamp / WEEK) + 1) * WEEK;
        vm.warp(boundary);
        vm.roll(block.number + 1);

        uint256 amount = TOKEN_1 + 1;
        (uint256 penalty, uint256 net) = strategy.previewClaim(amount, 0, 0);
        uint256 vaultBefore = DUST.balanceOf(dustVault);
        uint256 userBefore = DUST.balanceOf(user2);
        uint256 treasuryBefore = DUST.balanceOf(user3);

        vm.prank(incentivesController);
        assertTrue(strategy.performTransfer(user2, address(DUST), amount, 0, 0));

        assertEq(vaultBefore - DUST.balanceOf(dustVault), amount);
        assertEq(DUST.balanceOf(user2) - userBefore, net);
        assertEq(DUST.balanceOf(user3) - treasuryBefore, penalty);
    }

    function testExactEpochLockModesRollbackAtomically() public {
        vm.startPrank(user2);
        DUST.approve(address(dustLock), type(uint256).max);
        uint256 existingTokenId = dustLock.createLock(TOKEN_1K, MAXTIME);
        vm.stopPrank();

        uint256 boundary = ((block.timestamp / WEEK) + 1) * WEEK;
        vm.warp(boundary);
        vm.roll(block.number + 1);

        uint256 vaultBefore = DUST.balanceOf(dustVault);
        uint256 treasuryBefore = DUST.balanceOf(dustLock.earlyWithdrawTreasury());
        uint256 dustLockSupplyBefore = dustLock.supply();
        uint256 tokenIdBefore = dustLock.tokenId();
        uint256 totalSupplyBefore = DUST.totalSupply();
        bytes32 existingLockBefore = keccak256(abi.encode(dustLock.locked(existingTokenId)));

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        vm.prank(incentivesController);
        strategy.performTransfer(user2, address(DUST), TOKEN_10K, MINTIME + WEEK, 0);

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        vm.prank(incentivesController);
        strategy.performTransfer(user2, address(DUST), TOKEN_10K, type(uint256).max, 0);

        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        vm.prank(incentivesController);
        strategy.performTransfer(user2, address(DUST), TOKEN_10K, 0, existingTokenId);

        assertEq(DUST.balanceOf(dustVault), vaultBefore);
        assertEq(DUST.balanceOf(dustLock.earlyWithdrawTreasury()), treasuryBefore);
        assertEq(DUST.balanceOf(address(strategy)), 0);
        assertEq(DUST.allowance(address(strategy), address(dustLock)), 0);
        assertEq(dustLock.supply(), dustLockSupplyBefore);
        assertEq(dustLock.tokenId(), tokenIdBefore);
        assertEq(keccak256(abi.encode(dustLock.locked(existingTokenId))), existingLockBefore);
        assertEq(DUST.totalSupply(), totalSupplyBefore);
    }

    function testPenaltyRouteRejectsZeroTreasuryBeforeVaultPull() public {
        vm.mockCall(
            address(dustLock), abi.encodeWithSelector(IDustLock.earlyWithdrawTreasury.selector), abi.encode(address(0))
        );
        uint256 vaultBefore = DUST.balanceOf(dustVault);

        vm.prank(incentivesController);
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        strategy.performTransfer(user2, address(DUST), TOKEN_1, 0, 0);

        assertEq(DUST.balanceOf(dustVault), vaultBefore);
        assertEq(DUST.balanceOf(address(strategy)), 0);
    }

    function testNewTimedActionLocksNetAndRoutesPenalty() public {
        uint256 amount = 10 * TOKEN_1;
        uint256 lockTime = MINTIME + WEEK;
        (uint256 penalty, uint256 net) = strategy.previewClaim(amount, lockTime, 0);
        uint256 treasuryBefore = DUST.balanceOf(dustLock.earlyWithdrawTreasury());
        uint256 supplyBefore = DUST.totalSupply();

        vm.prank(incentivesController);
        strategy.performTransfer(user2, address(DUST), amount, lockTime, 0);

        uint256 tokenId = dustLock.tokenId();
        assertEq(dustLock.ownerOf(tokenId), user2);
        assertEq(uint256(dustLock.locked(tokenId).amount), net);
        assertEq(DUST.balanceOf(dustLock.earlyWithdrawTreasury()) - treasuryBefore, penalty);
        assertEq(DUST.totalSupply(), supplyBefore);
        assertEq(DUST.allowance(address(strategy), address(dustLock)), 0);
    }

    function testPermanentClaimLocksGrossWithNoPenalty() public {
        uint256 amount = 10 * TOKEN_1;
        (uint256 penalty, uint256 net) = strategy.previewClaim(amount, type(uint256).max, 0);
        assertEq(penalty, 0);
        assertEq(net, amount);
        uint256 supplyBefore = DUST.totalSupply();

        vm.prank(incentivesController);
        strategy.performTransfer(user2, address(DUST), amount, type(uint256).max, 0);

        IDustLock.LockedBalance memory lock = dustLock.locked(dustLock.tokenId());
        assertEq(uint256(lock.amount), amount);
        assertTrue(lock.isPermanent);
        assertEq(DUST.totalSupply(), supplyBefore);
    }

    function testExistingTimedClaimUsesRemainingDuration() public {
        vm.startPrank(user2);
        DUST.approve(address(dustLock), type(uint256).max);
        uint256 tokenId = dustLock.createLock(TOKEN_1K, MAXTIME);
        vm.stopPrank();
        skipAndRoll(13 weeks);

        IDustLock.LockedBalance memory beforeLock = dustLock.locked(tokenId);
        uint256 remaining = beforeLock.end - block.timestamp;
        (uint256 expectedPenalty, uint256 expectedNet) = _expectedTimedClaim(TOKEN_10K, remaining);
        (uint256 penalty, uint256 net) = strategy.previewClaim(TOKEN_10K, 0, tokenId);
        assertEq(penalty, expectedPenalty);
        assertEq(net, expectedNet);
        uint256 treasuryBefore = DUST.balanceOf(dustLock.earlyWithdrawTreasury());
        uint256 supplyBefore = DUST.totalSupply();

        vm.prank(incentivesController);
        strategy.performTransfer(user2, address(DUST), TOKEN_10K, 0, tokenId);

        assertEq(uint256(dustLock.locked(tokenId).amount), uint256(beforeLock.amount) + expectedNet);
        assertEq(DUST.balanceOf(dustLock.earlyWithdrawTreasury()) - treasuryBefore, expectedPenalty);
        assertEq(DUST.totalSupply(), supplyBefore);
    }

    function testExistingPermanentClaimReceivesGross() public {
        vm.startPrank(user2);
        DUST.approve(address(dustLock), type(uint256).max);
        uint256 tokenId = dustLock.createLockPermanent(TOKEN_1K, MAXTIME);
        vm.stopPrank();

        (uint256 penalty, uint256 net) = strategy.previewClaim(TOKEN_10K, 0, tokenId);
        assertEq(penalty, 0);
        assertEq(net, TOKEN_10K);
        vm.prank(incentivesController);
        strategy.performTransfer(user2, address(DUST), TOKEN_10K, 0, tokenId);
        assertEq(uint256(dustLock.locked(tokenId).amount), TOKEN_1K + TOKEN_10K);
    }

    function testExistingTimedClaimBelowMinimumFailsBeforeVaultPull() public {
        vm.startPrank(user2);
        DUST.approve(address(dustLock), type(uint256).max);
        uint256 tokenId = dustLock.createLock(TOKEN_1K, MINTIME + WEEK);
        vm.stopPrank();
        skipAndRoll(WEEK + 1);

        uint256 vaultBefore = DUST.balanceOf(dustVault);
        vm.expectRevert(IDustLock.DepositForLockDurationTooShort.selector);
        strategy.previewClaim(TOKEN_10K, 0, tokenId);
        vm.prank(incentivesController);
        vm.expectRevert(IDustLock.DepositForLockDurationTooShort.selector);
        strategy.performTransfer(user2, address(DUST), TOKEN_10K, 0, tokenId);
        assertEq(DUST.balanceOf(dustVault), vaultBefore);
    }

    function testNonOwnerFailsBeforeVaultPull() public {
        vm.startPrank(user2);
        DUST.approve(address(dustLock), type(uint256).max);
        uint256 tokenId = dustLock.createLock(TOKEN_1K, MAXTIME);
        vm.stopPrank();

        uint256 vaultBefore = DUST.balanceOf(dustVault);
        vm.prank(incentivesController);
        vm.expectRevert(IDustLockTransferStrategy.NotTokenOwner.selector);
        strategy.performTransfer(user3, address(DUST), TOKEN_10K, 0, tokenId);
        assertEq(DUST.balanceOf(dustVault), vaultBefore);
    }

    function testMappedV3FailsClosedAgainstPredecessorBeforeVaultPull() public {
        PredecessorDustLockMock predecessor = new PredecessorDustLockMock(address(DUST));
        DustLockTransferStrategy candidate =
            new DustLockTransferStrategy(incentivesController, admin, dustVault, address(predecessor));
        vm.prank(dustVault);
        DUST.approve(address(candidate), type(uint256).max);
        uint256 vaultBefore = DUST.balanceOf(dustVault);

        vm.prank(incentivesController);
        vm.expectRevert(IDustLockTransferStrategy.DustLockClaimReformInactive.selector);
        candidate.performTransfer(user2, address(DUST), TOKEN_1, 0, 0);

        assertEq(DUST.balanceOf(dustVault), vaultBefore);
        assertEq(DUST.balanceOf(address(candidate)), 0);
    }

    function testMalformedCapabilityReturnFailsClosedWithinBoundedGas() public {
        ReturnDataBombDustLockMock malformed = new ReturnDataBombDustLockMock(address(DUST));
        DustLockTransferStrategy candidate =
            new DustLockTransferStrategy(incentivesController, admin, dustVault, address(malformed));
        vm.prank(dustVault);
        DUST.approve(address(candidate), type(uint256).max);
        uint256 vaultBefore = DUST.balanceOf(dustVault);

        bytes memory callData = abi.encodeCall(candidate.performTransfer, (user2, address(DUST), TOKEN_1, 0, 0));
        vm.prank(incentivesController);
        (bool success, bytes memory result) = address(candidate).call{gas: 20_000}(callData);

        assertFalse(success);
        assertEq(bytes4(result), IDustLockTransferStrategy.DustLockClaimReformInactive.selector);
        assertEq(DUST.balanceOf(dustVault), vaultBefore);
    }

    function testNonZeroCapabilityWordFailsClosedBeforeVaultPull() public {
        VaultPullRevertingTokenMock reward = new VaultPullRevertingTokenMock();
        NonZeroCapabilityWordDustLockMock malformed = new NonZeroCapabilityWordDustLockMock(address(reward));
        DustLockTransferStrategy candidate =
            new DustLockTransferStrategy(incentivesController, admin, dustVault, address(malformed));

        vm.prank(incentivesController);
        vm.expectRevert(IDustLockTransferStrategy.DustLockClaimReformInactive.selector);
        candidate.performTransfer(user2, address(reward), TOKEN_1, 0, 0);
    }

    function testPostPullFailureRollsBackVaultPullAndPenaltyRoute() public {
        uint256 amount = TOKEN_1;
        uint256 supplyBefore = DUST.totalSupply();
        uint256 vaultBefore = DUST.balanceOf(dustVault);

        vm.prank(incentivesController);
        vm.expectRevert(IDustLock.AmountTooSmall.selector);
        strategy.performTransfer(user2, address(DUST), amount, MINTIME + WEEK, 0);

        assertEq(DUST.balanceOf(dustVault), vaultBefore);
        assertEq(DUST.totalSupply(), supplyBefore);
        assertEq(DUST.balanceOf(address(strategy)), 0);
    }

    function testActivationAssertionsBindControllerAllowanceTokenAndCapability() public {
        TransferStrategyControllerMock controller = new TransferStrategyControllerMock();
        DustLockTransferStrategy active =
            new DustLockTransferStrategy(address(controller), admin, dustVault, address(dustLock));
        controller.setStrategy(address(active));
        vm.prank(dustVault);
        DUST.approve(address(active), type(uint256).max);

        active.assertActivationState(true);
        vm.expectRevert(IDustLockTransferStrategy.InvalidActivationState.selector);
        active.assertActivationState(false);

        PredecessorDustLockMock predecessor = new PredecessorDustLockMock(address(DUST));
        DustLockTransferStrategy inactive =
            new DustLockTransferStrategy(address(controller), admin, dustVault, address(predecessor));
        controller.setStrategy(address(inactive));
        vm.prank(dustVault);
        DUST.approve(address(inactive), type(uint256).max);

        inactive.assertActivationState(false);
        vm.expectRevert(IDustLockTransferStrategy.InvalidActivationState.selector);
        inactive.assertActivationState(true);
    }

    function testActivationAssertionUsesCapabilityNotVersionMetadata() public {
        TransferStrategyControllerMock controller = new TransferStrategyControllerMock();
        ClaimReformDustLockMock capabilityLock = new ClaimReformDustLockMock(address(DUST));
        DustLockTransferStrategy candidate =
            new DustLockTransferStrategy(address(controller), admin, dustVault, address(capabilityLock));
        controller.setStrategy(address(candidate));
        vm.prank(dustVault);
        DUST.approve(address(candidate), type(uint256).max);

        candidate.assertActivationState(true);
    }

    function testActivationAssertionRejectsControllerMismatch() public {
        TransferStrategyControllerMock controller = new TransferStrategyControllerMock();
        DustLockTransferStrategy candidate =
            new DustLockTransferStrategy(address(controller), admin, dustVault, address(dustLock));
        controller.setStrategy(user2);
        vm.prank(dustVault);
        DUST.approve(address(candidate), type(uint256).max);

        vm.expectRevert(IDustLockTransferStrategy.InvalidActivationState.selector);
        candidate.assertActivationState(true);
    }

    function testActivationAssertionRejectsNonMaxAllowance() public {
        TransferStrategyControllerMock controller = new TransferStrategyControllerMock();
        DustLockTransferStrategy candidate =
            new DustLockTransferStrategy(address(controller), admin, dustVault, address(dustLock));
        controller.setStrategy(address(candidate));

        vm.expectRevert(IDustLockTransferStrategy.InvalidActivationState.selector);
        candidate.assertActivationState(true);
    }

    function testActivationAssertionRejectsWrongDustLockToken() public {
        TransferStrategyControllerMock controller = new TransferStrategyControllerMock();
        PredecessorDustLockMock wrongTokenLock = new PredecessorDustLockMock(address(DUST));
        DustLockTransferStrategy candidate =
            new DustLockTransferStrategy(address(controller), admin, dustVault, address(wrongTokenLock));
        controller.setStrategy(address(candidate));
        vm.prank(dustVault);
        DUST.approve(address(candidate), type(uint256).max);
        wrongTokenLock.setToken(user2);

        vm.expectRevert(IDustLockTransferStrategy.InvalidActivationState.selector);
        candidate.assertActivationState(false);
    }

    function testFuzzPreviewConservesGrossAndUsesFullPrecision(uint128 rawAmount, uint32 rawLockTime) public view {
        uint256 amount = bound(uint256(rawAmount), 7, TOKEN_100M);
        uint256 lockTime = bound(uint256(rawLockTime), MINTIME + WEEK, MAXTIME);
        uint256 commitment = _realizedCommitment(lockTime);
        (uint256 expectedPenalty, uint256 expectedNet) = _expectedTimedClaim(amount, commitment);

        (uint256 penalty, uint256 net) = strategy.previewClaim(amount, lockTime, 0);
        assertEq(penalty, expectedPenalty);
        assertEq(net, expectedNet);
        assertEq(penalty + net, amount);
    }
}
