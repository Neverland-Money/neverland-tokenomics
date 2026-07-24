// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IDustLock} from "../../../src/interfaces/IDustLock.sol";

import {DustLockTransferStrategy} from "../../../src/emissions/DustLockTransferStrategy.sol";
import {BaseTestLocal} from "../../BaseTestLocal.sol";

/**
 * @title ClaimReformTestBase
 * @author Neverland
 * @notice Shared local fixture and delta assertions for NGV-05 validation
 */
abstract contract ClaimReformTestBase is BaseTestLocal {
    struct ExitSnapshot {
        uint256 dustLockBalance;
        uint256 lockedSupply;
        uint256 ownerBalance;
        uint256 totalSupply;
        uint256 treasuryBalance;
    }

    address internal constant BURN_WALLET = address(0xb007);
    address internal constant CLAIM_CONTROLLER = address(0xc017);
    address internal constant DUST_VAULT = address(0xd057);

    DustLockTransferStrategy internal claimStrategy;

    function _setUp() internal virtual override {
        mintErc20Token(address(DUST), user, TOKEN_10M);
        mintErc20Token(address(DUST), user2, TOKEN_10M);
        mintErc20Token(address(DUST), DUST_VAULT, TOKEN_100M);
        DUST.approve(address(dustLock), type(uint256).max);
        vm.prank(user2);
        DUST.approve(address(dustLock), type(uint256).max);

        claimStrategy = new DustLockTransferStrategy(CLAIM_CONTROLLER, admin, DUST_VAULT, address(dustLock));
        vm.prank(DUST_VAULT);
        DUST.approve(address(claimStrategy), type(uint256).max);
        dustLock.setEarlyWithdrawTreasury(BURN_WALLET);
    }

    /**
     * @notice Executes a reward claim through the candidate transfer strategy
     * @param to Reward recipient or existing veNFT owner
     * @param gross Gross DUST reward amount
     * @param lockTime Requested duration or permanent sentinel
     * @param tokenId Existing veNFT identifier, or zero for a new route
     */
    function _claim(address to, uint256 gross, uint256 lockTime, uint256 tokenId) internal {
        vm.prank(CLAIM_CONTROLLER);
        assertTrue(claimStrategy.performTransfer(to, address(DUST), gross, lockTime, tokenId));
    }

    /**
     * @notice Creates a timed lock owned by the secondary test user
     * @param amount DUST principal
     * @param duration Requested lock duration
     * @return tokenId Newly minted veNFT identifier
     */
    function _createUser2TimedLock(uint256 amount, uint256 duration) internal returns (uint256 tokenId) {
        vm.prank(user2);
        tokenId = dustLock.createLock(amount, duration);
    }

    /**
     * @notice Returns the nonnegative remaining duration of a lock
     * @param lock Lock record being measured
     * @return remaining Nonnegative remaining seconds
     */
    function _remaining(IDustLock.LockedBalance memory lock) internal view returns (uint256 remaining) {
        return lock.end > block.timestamp ? lock.end - block.timestamp : 0;
    }

    /**
     * @notice Captures balances and supply immediately before an exit
     * @param owner VeNFT owner receiving exit proceeds
     * @return snapshot Captured accounting state
     */
    function _snapshotExit(address owner) internal view returns (ExitSnapshot memory snapshot) {
        snapshot = ExitSnapshot({
            dustLockBalance: DUST.balanceOf(address(dustLock)),
            lockedSupply: dustLock.supply(),
            ownerBalance: DUST.balanceOf(owner),
            totalSupply: DUST.totalSupply(),
            treasuryBalance: DUST.balanceOf(BURN_WALLET)
        });
    }

    /**
     * @notice Reconciles a completed early exit against its independent model
     * @param beforeExit Captured pre-exit accounting state
     * @param owner VeNFT owner receiving proceeds
     * @param principal Principal removed from DustLock
     * @param expectedPenalty Expected burn-wallet allocation
     * @param expectedNet Expected owner proceeds
     */
    function _assertExitDeltas(
        ExitSnapshot memory beforeExit,
        address owner,
        uint256 principal,
        uint256 expectedPenalty,
        uint256 expectedNet
    ) internal view {
        assertEq(DUST.balanceOf(owner) - beforeExit.ownerBalance, expectedNet);
        assertEq(DUST.balanceOf(BURN_WALLET) - beforeExit.treasuryBalance, expectedPenalty);
        assertEq(beforeExit.dustLockBalance - DUST.balanceOf(address(dustLock)), principal);
        assertEq(beforeExit.lockedSupply - dustLock.supply(), principal);
        assertEq(DUST.totalSupply(), beforeExit.totalSupply);
        assertEq(expectedPenalty + expectedNet, principal);
    }

    /**
     * @notice Moves the test timestamp to a selected offset within a week
     * @param phase Seconds elapsed since the selected week's start
     */
    function _warpToWeekPhase(uint256 phase) internal {
        vm.warp(10 * WEEK + phase);
        vm.roll(block.number + 1);
    }
}
