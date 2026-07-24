// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IDustLock} from "../../../src/interfaces/IDustLock.sol";
import {IClaimReformStatefulHandler} from "./IClaimReformStatefulHandler.sol";

import {DustLockTransferStrategy} from "../../../src/emissions/DustLockTransferStrategy.sol";
import {Dust} from "../../../src/tokens/Dust.sol";
import {ClaimReformModel} from "../_utils/ClaimReformModel.sol";

/**
 * @title ClaimReformStatefulHandler
 * @author Neverland
 * @notice Bounded state machine for DustLock lifecycle and NGV-05 reward-release invariants
 * @dev Failed low-level actions assert a core-state fingerprint before returning to the invariant runner.
 */
contract ClaimReformStatefulHandler is Test, IClaimReformStatefulHandler {
    /**
     * @notice Initializes the bounded state machine and creates timed/permanent seed locks for every actor
     * @param dust DUST token used for principal and reward release
     * @param dustLock DustLock proxy under test
     * @param claimStrategy Candidate NGV-05 transfer strategy
     * @param dustVault Strategy reward source
     * @param claimController Authorized strategy caller
     * @param burnWallet Configured early-exit burn wallet
     * @param residualHolder Pre-funded fixture holder outside the actor set
     * @param actorSet Three bounded actors that own every generated veNFT
     */
    constructor(
        Dust dust,
        IDustLock dustLock,
        DustLockTransferStrategy claimStrategy,
        address dustVault,
        address claimController,
        address burnWallet,
        address residualHolder,
        address[3] memory actorSet
    ) {
        DUST = dust;
        DUST_LOCK = dustLock;
        CLAIM_STRATEGY = claimStrategy;
        DUST_VAULT = dustVault;
        CLAIM_CONTROLLER = claimController;
        BURN_WALLET = burnWallet;
        RESIDUAL_HOLDER = residualHolder;

        for (uint256 i = 0; i < actorSet.length; ++i) {
            actors[i] = actorSet[i];
            vm.prank(actorSet[i]);
            dust.approve(address(dustLock), type(uint256).max);

            vm.prank(actorSet[i]);
            dustLock.createLock(4 ether, 180 days);
            vm.prank(actorSet[i]);
            dustLock.createLockPermanent(4 ether, MAX_LOCK_DURATION);
        }

        initialTotalSupply = dust.totalSupply();
        initialBurnWalletBalance = dust.balanceOf(burnWallet);
        initialLockedSupply = dustLock.supply();
        uint256 tracked = trackedBalance();
        assertLe(tracked, initialTotalSupply);
        untrackedBalance = initialTotalSupply - tracked;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Minimum principal accepted for a new DustLock position
    uint256 internal constant MIN_LOCK_AMOUNT = 1 ether;

    /// @dev Minimum amount accepted for an existing position increase
    uint256 internal constant MIN_INCREASE_AMOUNT = 0.1 ether;

    /// @dev Largest principal used by one handler action
    uint256 internal constant MAX_ACTION_AMOUNT = 1_000 ether;

    /// @dev Minimum timed commitment accepted by DustLock
    uint256 internal constant MIN_LOCK_DURATION = 28 days;

    /// @dev Maximum timed commitment accepted by DustLock
    uint256 internal constant MAX_LOCK_DURATION = 365 days;

    /// @dev DustLock unlock-time rounding unit
    uint256 internal constant WEEK = 1 weeks;

    uint256 internal constant ACTION_CREATE_TIMED = 1 << 0;
    uint256 internal constant ACTION_CREATE_PERMANENT = 1 << 1;
    uint256 internal constant ACTION_DEPOSIT_FOR = 1 << 2;
    uint256 internal constant ACTION_INCREASE_AMOUNT = 1 << 3;
    uint256 internal constant ACTION_EXTEND = 1 << 4;
    uint256 internal constant ACTION_TRANSFER = 1 << 5;
    uint256 internal constant ACTION_SPLIT = 1 << 6;
    uint256 internal constant ACTION_MERGE = 1 << 7;
    uint256 internal constant ACTION_LOCK_PERMANENT = 1 << 8;
    uint256 internal constant ACTION_UNLOCK_PERMANENT = 1 << 9;
    uint256 internal constant ACTION_EARLY_WITHDRAW = 1 << 10;
    uint256 internal constant ACTION_MATURE_WITHDRAW = 1 << 11;
    uint256 internal constant ACTION_CLAIM_INSTANT = 1 << 12;
    uint256 internal constant ACTION_CLAIM_NEW_TIMED = 1 << 13;
    uint256 internal constant ACTION_CLAIM_PERMANENT = 1 << 14;
    uint256 internal constant ACTION_CLAIM_EXISTING = 1 << 15;
    uint256 internal constant ACTION_ADVANCE_TIME = 1 << 16;
    uint256 internal constant ALL_ACTIONS_MASK = (1 << 17) - 1;

    /*//////////////////////////////////////////////////////////////
                          STORAGE VARIABLES
    //////////////////////////////////////////////////////////////*/

    Dust internal immutable DUST;
    IDustLock internal immutable DUST_LOCK;
    DustLockTransferStrategy internal immutable CLAIM_STRATEGY;

    address internal immutable BURN_WALLET;
    address internal immutable CLAIM_CONTROLLER;
    address internal immutable DUST_VAULT;
    address internal immutable RESIDUAL_HOLDER;

    address[3] internal actors;

    /// @inheritdoc IClaimReformStatefulHandler
    uint256 public immutable override initialTotalSupply;

    /// @inheritdoc IClaimReformStatefulHandler
    uint256 public immutable override initialBurnWalletBalance;

    /// @inheritdoc IClaimReformStatefulHandler
    uint256 public immutable override untrackedBalance;

    /// @inheritdoc IClaimReformStatefulHandler
    uint256 public immutable override initialLockedSupply;

    /// @inheritdoc IClaimReformStatefulHandler
    uint256 public override totalCalls;

    /// @inheritdoc IClaimReformStatefulHandler
    uint256 public override successfulCalls;

    /// @inheritdoc IClaimReformStatefulHandler
    uint256 public override failedCalls;

    /// @inheritdoc IClaimReformStatefulHandler
    uint256 public override attemptedMask;

    /// @inheritdoc IClaimReformStatefulHandler
    uint256 public override successMask;

    /// @inheritdoc IClaimReformStatefulHandler
    uint256 public override ghostPrincipalIn;

    /// @inheritdoc IClaimReformStatefulHandler
    uint256 public override ghostPrincipalOut;

    /// @inheritdoc IClaimReformStatefulHandler
    uint256 public override ghostPenaltyRouted;

    /*//////////////////////////////////////////////////////////////
                              ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IClaimReformStatefulHandler
    function actionCreateTimed(uint256 actorSeed, uint256 rawAmount, uint256 rawDuration) external override {
        _beginAction(ACTION_CREATE_TIMED);
        address actor = _actor(actorSeed);
        uint256 amount = bound(rawAmount, MIN_LOCK_AMOUNT, MAX_ACTION_AMOUNT);
        uint256 duration = bound(rawDuration, MIN_LOCK_DURATION + WEEK, MAX_LOCK_DURATION);
        uint256 supplyBefore = DUST_LOCK.supply();

        (bool success, bytes memory returnData) = _attempt(
            actor,
            address(DUST_LOCK),
            abi.encodeCall(IDustLock.createLock, (amount, duration)),
            0,
            0,
            ACTION_CREATE_TIMED
        );

        if (!success) return;

        uint256 tokenId = abi.decode(returnData, (uint256));
        IDustLock.LockedBalance memory created = DUST_LOCK.locked(tokenId);
        assertEq(DUST_LOCK.ownerOf(tokenId), actor);
        assertEq(uint256(created.amount), amount);
        assertFalse(created.isPermanent);
        _recordPrincipalIn(supplyBefore, amount);
    }

    /// @inheritdoc IClaimReformStatefulHandler
    function actionCreatePermanent(uint256 actorSeed, uint256 rawAmount) external override {
        _beginAction(ACTION_CREATE_PERMANENT);
        address actor = _actor(actorSeed);
        uint256 amount = bound(rawAmount, MIN_LOCK_AMOUNT, MAX_ACTION_AMOUNT);
        uint256 supplyBefore = DUST_LOCK.supply();

        (bool success, bytes memory returnData) = _attempt(
            actor,
            address(DUST_LOCK),
            abi.encodeCall(IDustLock.createLockPermanent, (amount, MAX_LOCK_DURATION)),
            0,
            0,
            ACTION_CREATE_PERMANENT
        );

        if (!success) return;

        uint256 tokenId = abi.decode(returnData, (uint256));
        IDustLock.LockedBalance memory created = DUST_LOCK.locked(tokenId);
        assertEq(DUST_LOCK.ownerOf(tokenId), actor);
        assertEq(uint256(created.amount), amount);
        assertTrue(created.isPermanent);
        assertEq(created.end, 0);
        _recordPrincipalIn(supplyBefore, amount);
    }

    /// @inheritdoc IClaimReformStatefulHandler
    function actionDepositFor(uint256 tokenSeed, uint256 actorSeed, uint256 rawAmount) external override {
        _beginAction(ACTION_DEPOSIT_FOR);
        uint256 tokenId = _candidateAny(tokenSeed);
        address depositor = _actor(actorSeed);
        uint256 amount = bound(rawAmount, MIN_INCREASE_AMOUNT, MAX_ACTION_AMOUNT);
        uint256 supplyBefore = DUST_LOCK.supply();

        (bool success,) = _attempt(
            depositor,
            address(DUST_LOCK),
            abi.encodeCall(IDustLock.depositFor, (tokenId, amount)),
            tokenId,
            0,
            ACTION_DEPOSIT_FOR
        );

        if (!success) return;

        _recordPrincipalIn(supplyBefore, amount);
    }

    /// @inheritdoc IClaimReformStatefulHandler
    function actionIncreaseAmount(uint256 tokenSeed, uint256 rawAmount) external override {
        _beginAction(ACTION_INCREASE_AMOUNT);
        uint256 tokenId = _candidateAny(tokenSeed);
        address owner = _ownerOrActor(tokenId, tokenSeed);
        uint256 amount = bound(rawAmount, MIN_INCREASE_AMOUNT, MAX_ACTION_AMOUNT);
        uint256 supplyBefore = DUST_LOCK.supply();

        (bool success,) = _attempt(
            owner,
            address(DUST_LOCK),
            abi.encodeCall(IDustLock.increaseAmount, (tokenId, amount)),
            tokenId,
            0,
            ACTION_INCREASE_AMOUNT
        );

        if (!success) return;

        _recordPrincipalIn(supplyBefore, amount);
    }

    /// @inheritdoc IClaimReformStatefulHandler
    function actionExtend(uint256 tokenSeed, uint256 rawDuration) external override {
        _beginAction(ACTION_EXTEND);
        uint256 tokenId = _candidateTimedActive(tokenSeed, false);
        IDustLock.LockedBalance memory beforeLock = DUST_LOCK.locked(tokenId);
        address owner = _ownerOrActor(tokenId, tokenSeed);
        uint256 quoteBefore = DUST_LOCK.earlyWithdrawPenaltyAmount(tokenId);
        uint256 remaining = beforeLock.end > block.timestamp ? beforeLock.end - block.timestamp : 0;
        uint256 minimumDuration = remaining + WEEK;
        uint256 duration = minimumDuration <= MAX_LOCK_DURATION
            ? bound(rawDuration, minimumDuration, MAX_LOCK_DURATION)
            : MAX_LOCK_DURATION;
        uint256 supplyBefore = DUST_LOCK.supply();

        (bool success,) = _attempt(
            owner,
            address(DUST_LOCK),
            abi.encodeCall(IDustLock.increaseUnlockTime, (tokenId, duration)),
            tokenId,
            0,
            ACTION_EXTEND
        );

        if (!success) return;

        assertEq(DUST_LOCK.supply(), supplyBefore);
        assertGe(DUST_LOCK.earlyWithdrawPenaltyAmount(tokenId), quoteBefore);
    }

    /// @inheritdoc IClaimReformStatefulHandler
    function actionTransfer(uint256 tokenSeed, uint256 recipientSeed) external override {
        _beginAction(ACTION_TRANSFER);
        uint256 tokenId = _candidateAny(tokenSeed);
        address owner = _ownerOrActor(tokenId, tokenSeed);
        address recipient = _differentActor(owner, recipientSeed);
        uint256 quoteBefore = DUST_LOCK.earlyWithdrawPenaltyAmount(tokenId);
        uint256 supplyBefore = DUST_LOCK.supply();

        (bool success,) = _attempt(
            owner,
            address(DUST_LOCK),
            abi.encodeCall(IDustLock.transferFrom, (owner, recipient, tokenId)),
            tokenId,
            0,
            ACTION_TRANSFER
        );

        if (!success) return;

        assertEq(DUST_LOCK.ownerOf(tokenId), recipient);
        assertEq(DUST_LOCK.supply(), supplyBefore);
        assertEq(DUST_LOCK.earlyWithdrawPenaltyAmount(tokenId), quoteBefore);
    }

    /// @inheritdoc IClaimReformStatefulHandler
    function actionSplit(uint256 tokenSeed, uint256 rawAmount) external override {
        _beginAction(ACTION_SPLIT);
        uint256 tokenId = _candidateTimedActive(tokenSeed, true);
        IDustLock.LockedBalance memory beforeLock = DUST_LOCK.locked(tokenId);
        address owner = _ownerOrActor(tokenId, tokenSeed);
        uint256 amount = beforeLock.amount >= int128(int256(2 * MIN_LOCK_AMOUNT))
            ? bound(rawAmount, MIN_LOCK_AMOUNT, uint256(beforeLock.amount) - MIN_LOCK_AMOUNT)
            : rawAmount;
        uint256 quoteBefore = DUST_LOCK.earlyWithdrawPenaltyAmount(tokenId);
        uint256 supplyBefore = DUST_LOCK.supply();

        (bool success, bytes memory returnData) = _attempt(
            owner, address(DUST_LOCK), abi.encodeCall(IDustLock.split, (tokenId, amount)), tokenId, 0, ACTION_SPLIT
        );

        if (!success) return;

        (uint256 first, uint256 second) = abi.decode(returnData, (uint256, uint256));
        uint256 firstAmount = uint256(DUST_LOCK.locked(first).amount);
        uint256 secondAmount = uint256(DUST_LOCK.locked(second).amount);
        uint256 splitPenalty =
            DUST_LOCK.earlyWithdrawPenaltyAmount(first) + DUST_LOCK.earlyWithdrawPenaltyAmount(second);
        assertEq(firstAmount + secondAmount, uint256(beforeLock.amount));
        assertEq(DUST_LOCK.supply(), supplyBefore);
        assertGe(splitPenalty, quoteBefore);
        assertLe(splitPenalty, quoteBefore + 1);
    }

    /// @inheritdoc IClaimReformStatefulHandler
    function actionMerge(uint256 tokenSeed, uint256 pairSeed) external override {
        _beginAction(ACTION_MERGE);
        (uint256 from, uint256 to) = _candidateMergePair(tokenSeed, pairSeed);
        IDustLock.LockedBalance memory fromLock = DUST_LOCK.locked(from);
        IDustLock.LockedBalance memory toLock = DUST_LOCK.locked(to);
        address owner = _ownerOrActor(from, tokenSeed);
        uint256 expectedAmount = uint256(fromLock.amount) + uint256(toLock.amount);
        uint256 separatePenalty = DUST_LOCK.earlyWithdrawPenaltyAmount(from) + DUST_LOCK.earlyWithdrawPenaltyAmount(to);
        uint256 supplyBefore = DUST_LOCK.supply();

        (bool success,) =
            _attempt(owner, address(DUST_LOCK), abi.encodeCall(IDustLock.merge, (from, to)), from, to, ACTION_MERGE);

        if (!success) return;

        assertEq(DUST_LOCK.locked(from).amount, 0);
        assertEq(uint256(DUST_LOCK.locked(to).amount), expectedAmount);
        assertEq(DUST_LOCK.supply(), supplyBefore);
        assertGe(DUST_LOCK.earlyWithdrawPenaltyAmount(to) + 1, separatePenalty);
    }

    /// @inheritdoc IClaimReformStatefulHandler
    function actionLockPermanent(uint256 tokenSeed) external override {
        _beginAction(ACTION_LOCK_PERMANENT);
        uint256 tokenId = _candidateTimedActive(tokenSeed, false);
        IDustLock.LockedBalance memory beforeLock = DUST_LOCK.locked(tokenId);
        address owner = _ownerOrActor(tokenId, tokenSeed);
        uint256 supplyBefore = DUST_LOCK.supply();

        (bool success,) = _attempt(
            owner,
            address(DUST_LOCK),
            abi.encodeCall(IDustLock.lockPermanent, (tokenId)),
            tokenId,
            0,
            ACTION_LOCK_PERMANENT
        );

        if (!success) return;

        IDustLock.LockedBalance memory afterLock = DUST_LOCK.locked(tokenId);
        (uint256 expectedPenalty,) = ClaimReformModel.permanentExit(uint256(beforeLock.amount), block.timestamp);
        assertTrue(afterLock.isPermanent);
        assertEq(afterLock.end, 0);
        assertEq(DUST_LOCK.supply(), supplyBefore);
        assertEq(DUST_LOCK.earlyWithdrawPenaltyAmount(tokenId), expectedPenalty);
    }

    /// @inheritdoc IClaimReformStatefulHandler
    function actionUnlockPermanent(uint256 tokenSeed) external override {
        _beginAction(ACTION_UNLOCK_PERMANENT);
        uint256 tokenId = _candidatePermanent(tokenSeed);
        address owner = _ownerOrActor(tokenId, tokenSeed);
        uint256 supplyBefore = DUST_LOCK.supply();

        (bool success,) = _attempt(
            owner,
            address(DUST_LOCK),
            abi.encodeCall(IDustLock.unlockPermanent, (tokenId)),
            tokenId,
            0,
            ACTION_UNLOCK_PERMANENT
        );

        if (!success) return;

        IDustLock.LockedBalance memory afterLock = DUST_LOCK.locked(tokenId);
        uint256 amount = uint256(afterLock.amount);
        uint256 remaining = afterLock.end - block.timestamp;
        (uint256 expectedPenalty,) = ClaimReformModel.timedExit(amount, remaining);
        assertFalse(afterLock.isPermanent);
        assertGt(afterLock.end, block.timestamp);
        assertEq(DUST_LOCK.supply(), supplyBefore);
        assertEq(DUST_LOCK.earlyWithdrawPenaltyAmount(tokenId), expectedPenalty);
    }

    /// @inheritdoc IClaimReformStatefulHandler
    function actionEarlyWithdraw(uint256 tokenSeed) external override {
        _beginAction(ACTION_EARLY_WITHDRAW);
        uint256 tokenId = _candidateAny(tokenSeed);
        IDustLock.LockedBalance memory beforeLock = DUST_LOCK.locked(tokenId);
        address owner = _ownerOrActor(tokenId, tokenSeed);
        uint256 amount = uint256(beforeLock.amount);
        uint256 remaining = beforeLock.end > block.timestamp ? beforeLock.end - block.timestamp : 0;
        (uint256 expectedPenalty, uint256 expectedNet) = beforeLock.isPermanent
            ? ClaimReformModel.permanentExit(amount, block.timestamp)
            : ClaimReformModel.timedExit(amount, remaining);
        uint256 supplyBefore = DUST_LOCK.supply();
        uint256 ownerBalanceBefore = DUST.balanceOf(owner);
        uint256 burnBalanceBefore = DUST.balanceOf(BURN_WALLET);

        (bool success,) = _attempt(
            owner,
            address(DUST_LOCK),
            abi.encodeWithSignature("earlyWithdraw(uint256)", tokenId),
            tokenId,
            0,
            ACTION_EARLY_WITHDRAW
        );

        if (!success) return;

        /*
         * Permanent exits auto-unlock internally and charge the fresh-end curve price, so the
         * two-step model expectation applies to the one-step call identically.
         */
        assertEq(DUST.balanceOf(owner) - ownerBalanceBefore, expectedNet);
        assertEq(DUST.balanceOf(BURN_WALLET) - burnBalanceBefore, expectedPenalty);
        _recordPrincipalOut(supplyBefore, amount);
        _recordPenalty(expectedPenalty);
    }

    /// @inheritdoc IClaimReformStatefulHandler
    function actionMatureWithdraw(uint256 tokenSeed) external override {
        _beginAction(ACTION_MATURE_WITHDRAW);
        uint256 tokenId = _candidateTimed(tokenSeed);
        IDustLock.LockedBalance memory beforeLock = DUST_LOCK.locked(tokenId);
        address owner = _ownerOrActor(tokenId, tokenSeed);
        if (beforeLock.amount > 0 && beforeLock.end > block.timestamp) {
            vm.warp(beforeLock.end + 1);
            vm.roll(block.number + 1);
        }
        uint256 amount = uint256(beforeLock.amount);
        uint256 supplyBefore = DUST_LOCK.supply();
        uint256 ownerBalanceBefore = DUST.balanceOf(owner);

        (bool success,) = _attempt(
            owner, address(DUST_LOCK), abi.encodeCall(IDustLock.withdraw, (tokenId)), tokenId, 0, ACTION_MATURE_WITHDRAW
        );

        if (!success) return;

        assertEq(DUST.balanceOf(owner) - ownerBalanceBefore, amount);
        assertEq(DUST_LOCK.earlyWithdrawPenaltyAmount(tokenId), 0);
        _recordPrincipalOut(supplyBefore, amount);
    }

    /// @inheritdoc IClaimReformStatefulHandler
    function actionClaimInstant(uint256 actorSeed, uint256 rawGross) external override {
        _beginAction(ACTION_CLAIM_INSTANT);
        address actor = _actor(actorSeed);
        uint256 gross = bound(rawGross, 1, MAX_ACTION_AMOUNT);
        (uint256 expectedPenalty, uint256 expectedNet) = ClaimReformModel.instantClaim(gross);
        uint256 supplyBefore = DUST_LOCK.supply();
        uint256 actorBalanceBefore = DUST.balanceOf(actor);
        uint256 vaultBalanceBefore = DUST.balanceOf(DUST_VAULT);
        uint256 burnBalanceBefore = DUST.balanceOf(BURN_WALLET);

        (bool success, bytes memory returnData) = _attempt(
            CLAIM_CONTROLLER,
            address(CLAIM_STRATEGY),
            abi.encodeCall(DustLockTransferStrategy.performTransfer, (actor, address(DUST), gross, 0, 0)),
            0,
            0,
            ACTION_CLAIM_INSTANT
        );

        if (!success) return;

        assertTrue(abi.decode(returnData, (bool)));
        assertEq(DUST_LOCK.supply(), supplyBefore);
        assertEq(DUST.balanceOf(actor) - actorBalanceBefore, expectedNet);
        assertEq(vaultBalanceBefore - DUST.balanceOf(DUST_VAULT), gross);
        assertEq(DUST.balanceOf(BURN_WALLET) - burnBalanceBefore, expectedPenalty);
        _recordPenalty(expectedPenalty);
    }

    /// @inheritdoc IClaimReformStatefulHandler
    function actionClaimNewTimed(uint256 actorSeed, uint256 rawGross, uint256 rawDuration) external override {
        _beginAction(ACTION_CLAIM_NEW_TIMED);
        address actor = _actor(actorSeed);
        uint256 gross = bound(rawGross, 2 * MIN_LOCK_AMOUNT, MAX_ACTION_AMOUNT);
        uint256 duration = bound(rawDuration, MIN_LOCK_DURATION + WEEK, MAX_LOCK_DURATION);
        uint256 commitment = ClaimReformModel.realizedCommitment(block.timestamp, duration);
        (uint256 expectedPenalty, uint256 expectedNet) = ClaimReformModel.timedClaim(gross, commitment);
        uint256 supplyBefore = DUST_LOCK.supply();
        uint256 tokenIdBefore = DUST_LOCK.tokenId();
        uint256 vaultBalanceBefore = DUST.balanceOf(DUST_VAULT);
        uint256 burnBalanceBefore = DUST.balanceOf(BURN_WALLET);

        (bool success, bytes memory returnData) = _attempt(
            CLAIM_CONTROLLER,
            address(CLAIM_STRATEGY),
            abi.encodeCall(DustLockTransferStrategy.performTransfer, (actor, address(DUST), gross, duration, 0)),
            0,
            0,
            ACTION_CLAIM_NEW_TIMED
        );

        if (!success) return;

        assertTrue(abi.decode(returnData, (bool)));
        uint256 tokenId = DUST_LOCK.tokenId();
        assertEq(tokenId, tokenIdBefore + 1);
        assertEq(DUST_LOCK.ownerOf(tokenId), actor);
        assertEq(uint256(DUST_LOCK.locked(tokenId).amount), expectedNet);
        assertEq(vaultBalanceBefore - DUST.balanceOf(DUST_VAULT), gross);
        assertEq(DUST.balanceOf(BURN_WALLET) - burnBalanceBefore, expectedPenalty);
        _recordPrincipalIn(supplyBefore, expectedNet);
        _recordPenalty(expectedPenalty);
    }

    /// @inheritdoc IClaimReformStatefulHandler
    function actionClaimPermanent(uint256 actorSeed, uint256 rawGross) external override {
        _beginAction(ACTION_CLAIM_PERMANENT);
        address actor = _actor(actorSeed);
        uint256 gross = bound(rawGross, MIN_LOCK_AMOUNT, MAX_ACTION_AMOUNT);
        uint256 supplyBefore = DUST_LOCK.supply();
        uint256 tokenIdBefore = DUST_LOCK.tokenId();
        uint256 vaultBalanceBefore = DUST.balanceOf(DUST_VAULT);

        (bool success, bytes memory returnData) = _attempt(
            CLAIM_CONTROLLER,
            address(CLAIM_STRATEGY),
            abi.encodeCall(
                DustLockTransferStrategy.performTransfer, (actor, address(DUST), gross, type(uint256).max, 0)
            ),
            0,
            0,
            ACTION_CLAIM_PERMANENT
        );

        if (!success) return;

        assertTrue(abi.decode(returnData, (bool)));
        uint256 tokenId = DUST_LOCK.tokenId();
        IDustLock.LockedBalance memory created = DUST_LOCK.locked(tokenId);
        assertEq(tokenId, tokenIdBefore + 1);
        assertEq(DUST_LOCK.ownerOf(tokenId), actor);
        assertEq(uint256(created.amount), gross);
        assertTrue(created.isPermanent);
        assertEq(vaultBalanceBefore - DUST.balanceOf(DUST_VAULT), gross);
        _recordPrincipalIn(supplyBefore, gross);
    }

    /// @inheritdoc IClaimReformStatefulHandler
    function actionClaimExisting(uint256 tokenSeed, uint256 rawGross) external override {
        _beginAction(ACTION_CLAIM_EXISTING);
        uint256 tokenId = _candidateAny(tokenSeed);
        IDustLock.LockedBalance memory beforeLock = DUST_LOCK.locked(tokenId);
        address owner = _ownerOrActor(tokenId, tokenSeed);
        uint256 gross = bound(rawGross, MIN_LOCK_AMOUNT, MAX_ACTION_AMOUNT);
        ClaimSnapshot memory snapshot;
        uint256 remaining = beforeLock.end > block.timestamp ? beforeLock.end - block.timestamp : 0;
        if (beforeLock.isPermanent) {
            snapshot.expectedNet = gross;
        } else if (remaining >= MIN_LOCK_DURATION) {
            // Executable deposits always price at the actual remaining commitment (no clamp, no grace).
            (snapshot.expectedPenalty, snapshot.expectedNet) = ClaimReformModel.timedClaim(gross, remaining);
        }
        // else: remaining below the 28-day minimum reverts in the strategy (accepted); asserted after the attempt.
        snapshot.supplyBefore = DUST_LOCK.supply();
        snapshot.vaultBalanceBefore = DUST.balanceOf(DUST_VAULT);
        snapshot.burnBalanceBefore = DUST.balanceOf(BURN_WALLET);

        (bool success, bytes memory returnData) = _attempt(
            CLAIM_CONTROLLER,
            address(CLAIM_STRATEGY),
            abi.encodeCall(DustLockTransferStrategy.performTransfer, (owner, address(DUST), gross, 0, tokenId)),
            tokenId,
            0,
            ACTION_CLAIM_EXISTING
        );

        if (!beforeLock.isPermanent && remaining < MIN_LOCK_DURATION) {
            // Accepted behavior: deposits into locks inside their final 28 days revert (no boundary grace).
            assertFalse(success, "deposit with remaining below MINTIME must revert");
            return;
        }

        if (!success) return;

        assertTrue(abi.decode(returnData, (bool)));
        assertEq(uint256(DUST_LOCK.locked(tokenId).amount), uint256(beforeLock.amount) + snapshot.expectedNet);
        assertEq(snapshot.vaultBalanceBefore - DUST.balanceOf(DUST_VAULT), gross);
        assertEq(DUST.balanceOf(BURN_WALLET) - snapshot.burnBalanceBefore, snapshot.expectedPenalty);
        _recordPrincipalIn(snapshot.supplyBefore, snapshot.expectedNet);
        _recordPenalty(snapshot.expectedPenalty);
    }

    /// @inheritdoc IClaimReformStatefulHandler
    function actionAdvanceTime(uint256 rawMode, uint256 rawDelta) external override {
        _beginAction(ACTION_ADVANCE_TIME);
        uint256 nextWeek = block.timestamp - (block.timestamp % WEEK) + WEEK;
        uint256 mode = rawMode % 6;
        uint256 target;
        if (mode == 0) target = block.timestamp + 1;
        else if (mode == 1) target = nextWeek - 1;
        else if (mode == 2) target = nextWeek;
        else if (mode == 3) target = nextWeek + 1;
        else if (mode == 4) target = block.timestamp + bound(rawDelta, 2, 2 * WEEK);
        else target = block.timestamp + bound(rawDelta, MIN_LOCK_DURATION, MAX_LOCK_DURATION);
        if (target <= block.timestamp) target = block.timestamp + 1;

        vm.warp(target);
        vm.roll(block.number + 1);
        ++successfulCalls;
        successMask |= ACTION_ADVANCE_TIME;
    }

    /*//////////////////////////////////////////////////////////////
                               VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IClaimReformStatefulHandler
    function actorAt(uint256 index) public view override returns (address) {
        return actors[index];
    }

    /// @inheritdoc IClaimReformStatefulHandler
    function allActionsMask() public pure override returns (uint256) {
        return ALL_ACTIONS_MASK;
    }

    /// @inheritdoc IClaimReformStatefulHandler
    function expectedLockedSupply() public view override returns (uint256) {
        return initialLockedSupply + ghostPrincipalIn - ghostPrincipalOut;
    }

    /// @inheritdoc IClaimReformStatefulHandler
    function trackedBalance() public view override returns (uint256 balance) {
        balance = DUST.balanceOf(address(DUST_LOCK)) + DUST.balanceOf(BURN_WALLET) + DUST.balanceOf(DUST_VAULT)
            + DUST.balanceOf(address(CLAIM_STRATEGY)) + DUST.balanceOf(RESIDUAL_HOLDER) + DUST.balanceOf(address(this));
        for (uint256 i = 0; i < actors.length; ++i) {
            balance += DUST.balanceOf(actors[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNAL
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Records one invoked selector before attempting its protocol call
     * @param actionBit Selector-specific bit
     */
    function _beginAction(uint256 actionBit) internal {
        ++totalCalls;
        attemptedMask |= actionBit;
    }

    /**
     * @notice Executes one low-level protocol call as a selected caller
     * @dev A caught revert must preserve the core fingerprint exactly.
     * @param caller Effective caller for the protocol call
     * @param target Protocol target
     * @param callData Encoded action calldata
     * @param tokenA First affected token id
     * @param tokenB Second affected token id
     * @param actionBit Selector-specific bit
     * @return success Whether the protocol call succeeded
     * @return returnData Raw call return data
     */
    function _attempt(
        address caller,
        address target,
        bytes memory callData,
        uint256 tokenA,
        uint256 tokenB,
        uint256 actionBit
    ) internal returns (bool success, bytes memory returnData) {
        bytes32 stateBefore = _coreStateHash(tokenA, tokenB);
        vm.prank(caller);
        (success, returnData) = target.call(callData);
        if (!success) {
            assertEq(_coreStateHash(tokenA, tokenB), stateBefore);
            ++failedCalls;

            return (false, returnData);
        }

        ++successfulCalls;
        successMask |= actionBit;

        return (true, returnData);
    }

    /**
     * @notice Records one independently known principal inflow
     * @param supplyBefore Locked supply before the action
     * @param amount Expected principal increase
     */
    function _recordPrincipalIn(uint256 supplyBefore, uint256 amount) internal {
        assertEq(DUST_LOCK.supply(), supplyBefore + amount);
        ghostPrincipalIn += amount;
        assertEq(DUST_LOCK.supply(), expectedLockedSupply());
    }

    /**
     * @notice Records one independently known principal outflow
     * @param supplyBefore Locked supply before the action
     * @param amount Expected principal decrease
     */
    function _recordPrincipalOut(uint256 supplyBefore, uint256 amount) internal {
        assertEq(DUST_LOCK.supply(), supplyBefore - amount);
        ghostPrincipalOut += amount;
        assertEq(DUST_LOCK.supply(), expectedLockedSupply());
    }

    /**
     * @notice Records one independently modeled burn-wallet allocation
     * @param penalty Expected penalty routed by the completed action
     */
    function _recordPenalty(uint256 penalty) internal {
        ghostPenaltyRouted += penalty;
        assertEq(DUST.balanceOf(BURN_WALLET), initialBurnWalletBalance + ghostPenaltyRouted);
    }

    /**
     * @notice Selects one actor deterministically from a fuzz seed
     * @param seed Fuzzed actor seed
     * @return Selected actor
     */
    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /**
     * @notice Selects an actor distinct from a specified owner
     * @param owner Current owner to exclude
     * @param seed Fuzzed actor seed
     * @return recipient Distinct bounded recipient
     */
    function _differentActor(address owner, uint256 seed) internal view returns (address recipient) {
        uint256 start = seed % actors.length;
        for (uint256 i = 0; i < actors.length; ++i) {
            recipient = actors[(start + i) % actors.length];

            if (recipient != owner) return recipient;
        }
    }

    /**
     * @notice Returns a live token or an out-of-range id reserved for revert probing
     * @param seed Fuzzed token seed
     * @return tokenId Selected token id
     */
    function _candidateAny(uint256 seed) internal view returns (uint256 tokenId) {
        return _candidate(seed, CandidateKind.ANY, false);
    }

    /**
     * @notice Returns an active timed token satisfying an optional split-size requirement
     * @param seed Fuzzed token seed
     * @param requireSplittable True when principal must support two minimum-size children
     * @return tokenId Selected token id
     */
    function _candidateTimedActive(uint256 seed, bool requireSplittable) internal view returns (uint256 tokenId) {
        return _candidate(seed, CandidateKind.TIMED_ACTIVE, requireSplittable);
    }

    /**
     * @notice Returns any live timed token, including a mature position
     * @param seed Fuzzed token seed
     * @return tokenId Selected token id
     */
    function _candidateTimed(uint256 seed) internal view returns (uint256 tokenId) {
        return _candidate(seed, CandidateKind.TIMED, false);
    }

    /**
     * @notice Returns one live permanent token or an invalid probe id
     * @param seed Fuzzed token seed
     * @return tokenId Selected token id
     */
    function _candidatePermanent(uint256 seed) internal view returns (uint256 tokenId) {
        return _candidate(seed, CandidateKind.PERMANENT, false);
    }

    /**
     * @notice Scans minted ids once for the requested lifecycle class
     * @param seed Fuzzed token seed and invalid-probe selector
     * @param kind Required lifecycle class
     * @param requireSplittable True when principal must support two minimum-size children
     * @return tokenId Matching token id or one out-of-range probe id
     */
    function _candidate(uint256 seed, CandidateKind kind, bool requireSplittable)
        internal
        view
        returns (uint256 tokenId)
    {
        uint256 lastTokenId = DUST_LOCK.tokenId();
        if (_probeInvalid(seed) || lastTokenId == 0) {
            return lastTokenId + 1;
        }

        uint256 start = seed % lastTokenId;
        for (uint256 i = 0; i < lastTokenId; ++i) {
            tokenId = ((start + i) % lastTokenId) + 1;
            IDustLock.LockedBalance memory lock = DUST_LOCK.locked(tokenId);

            if (_matchesCandidate(lock, kind, requireSplittable)) {
                return tokenId;
            }
        }

        return lastTokenId + 1;
    }

    /**
     * @notice Checks one lock against a requested candidate class
     * @param lock Candidate lock record
     * @param kind Required lifecycle class
     * @param requireSplittable True when principal must support two minimum-size children
     * @return matches True when the record satisfies the requested class
     */
    function _matchesCandidate(IDustLock.LockedBalance memory lock, CandidateKind kind, bool requireSplittable)
        internal
        view
        returns (bool matches)
    {
        if (lock.amount > 0) {
            if (kind == CandidateKind.ANY) {
                matches = true;
            } else if (kind == CandidateKind.PERMANENT) {
                matches = lock.isPermanent;
            } else if (!lock.isPermanent && kind == CandidateKind.TIMED) {
                matches = true;
            } else if (!lock.isPermanent) {
                matches = lock.end > block.timestamp
                    && (!requireSplittable || lock.amount >= int128(int256(2 * MIN_LOCK_AMOUNT)));
            }
        }
    }

    /**
     * @notice Returns a compatible, active, same-owner merge pair
     * @param firstSeed Fuzzed source seed
     * @param secondSeed Fuzzed destination seed
     * @return from Source token id
     * @return to Destination token id
     */
    function _candidateMergePair(uint256 firstSeed, uint256 secondSeed)
        internal
        view
        returns (uint256 from, uint256 to)
    {
        uint256 lastTokenId = DUST_LOCK.tokenId();
        if (_probeInvalid(firstSeed) || lastTokenId < 2) {
            return (lastTokenId + 1, lastTokenId + 2);
        }

        uint256 firstStart = firstSeed % lastTokenId;
        uint256 secondStart = secondSeed % lastTokenId;
        for (uint256 i = 0; i < lastTokenId; ++i) {
            uint256 candidateA = ((firstStart + i) % lastTokenId) + 1;
            IDustLock.LockedBalance memory lockA = DUST_LOCK.locked(candidateA);
            address ownerA = _ownerOf(candidateA);
            if (!_isActive(lockA) || ownerA == address(0)) continue;

            for (uint256 j = 0; j < lastTokenId; ++j) {
                uint256 candidateB = ((secondStart + j) % lastTokenId) + 1;
                if (candidateA == candidateB || _ownerOf(candidateB) != ownerA) continue;
                IDustLock.LockedBalance memory lockB = DUST_LOCK.locked(candidateB);
                if (!_isActive(lockB)) continue;

                if (!(lockA.isPermanent && !lockB.isPermanent)) return (candidateA, candidateB);
                if (!(lockB.isPermanent && !lockA.isPermanent)) return (candidateB, candidateA);
            }
        }

        return (lastTokenId + 1, lastTokenId + 2);
    }

    /**
     * @notice Resolves a token owner or falls back to a bounded actor for invalid-id calls
     * @param tokenId Candidate token id
     * @param seed Fuzzed actor seed
     * @return owner Live owner or fallback actor
     */
    function _ownerOrActor(uint256 tokenId, uint256 seed) internal view returns (address owner) {
        owner = _ownerOf(tokenId);
        if (owner == address(0)) owner = _actor(seed);
    }

    /**
     * @notice Resolves a token owner without propagating a burned-token revert
     * @param tokenId Candidate token id
     * @return owner Current owner or zero
     */
    function _ownerOf(uint256 tokenId) internal view returns (address owner) {
        try DUST_LOCK.ownerOf(tokenId) returns (address currentOwner) {
            return currentOwner;
        } catch {
            return address(0);
        }
    }

    /**
     * @notice Checks whether a lock is live and either permanent or unexpired
     * @param lock Candidate lock record
     * @return True when merge may consume the record
     */
    function _isActive(IDustLock.LockedBalance memory lock) internal view returns (bool) {
        return lock.amount > 0 && (lock.isPermanent || lock.end > block.timestamp);
    }

    /**
     * @notice Reserves a stable subset of seeds for invalid-id atomicity probes
     * @param seed Fuzzed token seed
     * @return True when the action should deliberately target an invalid id
     */
    function _probeInvalid(uint256 seed) internal pure returns (bool) {
        return seed % 13 == 0;
    }

    /**
     * @notice Hashes core accounting, bounded balances, and two affected lock records
     * @param tokenA First affected token id
     * @param tokenB Second affected token id
     * @return Core-state fingerprint
     */
    function _coreStateHash(uint256 tokenA, uint256 tokenB) internal view returns (bytes32) {
        bytes32 actorState;
        for (uint256 i = 0; i < actors.length; ++i) {
            actorState = keccak256(abi.encode(actorState, DUST.balanceOf(actors[i]), DUST_LOCK.balanceOf(actors[i])));
        }

        bytes32 accountingState = keccak256(
            abi.encode(
                block.timestamp,
                block.number,
                DUST.totalSupply(),
                DUST_LOCK.tokenId(),
                DUST_LOCK.supply(),
                DUST_LOCK.permanentLockBalance()
            )
        );
        bytes32 balanceState = keccak256(
            abi.encode(
                DUST.balanceOf(address(DUST_LOCK)),
                DUST.balanceOf(BURN_WALLET),
                DUST.balanceOf(DUST_VAULT),
                DUST.balanceOf(address(CLAIM_STRATEGY)),
                DUST.balanceOf(RESIDUAL_HOLDER),
                DUST.allowance(address(CLAIM_STRATEGY), address(DUST_LOCK))
            )
        );

        return keccak256(
            abi.encode(accountingState, balanceState, actorState, _lockStateHash(tokenA), _lockStateHash(tokenB))
        );
    }

    /**
     * @notice Hashes one lock record, owner, and approval without propagating NFT lookup reverts
     * @param tokenId Candidate token id
     * @return Lock-state fingerprint
     */
    function _lockStateHash(uint256 tokenId) internal view returns (bytes32) {
        IDustLock.LockedBalance memory lock = DUST_LOCK.locked(tokenId);
        address approved;
        try DUST_LOCK.getApproved(tokenId) returns (address currentApproval) {
            approved = currentApproval;
        } catch {}

        return keccak256(abi.encode(lock, _ownerOf(tokenId), approved));
    }
}
