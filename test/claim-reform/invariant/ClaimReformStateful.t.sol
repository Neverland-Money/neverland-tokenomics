// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {StdInvariant} from "forge-std/StdInvariant.sol";

import {IDustLock} from "../../../src/interfaces/IDustLock.sol";

import {ClaimReformModel} from "../_utils/ClaimReformModel.sol";

import {ClaimReformTestBase} from "../_utils/ClaimReformTestBase.sol";
import {ClaimReformStatefulHandler} from "./ClaimReformStatefulHandler.sol";

/**
 * @title ClaimReformStatefulFixture
 * @author Neverland
 * @notice Shared bounded-actor fixture for NGV-05 stateful tests
 */
abstract contract ClaimReformStatefulFixture is ClaimReformTestBase {
    ClaimReformStatefulHandler internal handler;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    /// @notice Adds bounded actors and deterministic seed locks to the shared claim-reform fixture
    function _setUp() internal virtual override {
        super._setUp();

        address[3] memory actors = [user1, user2, user3];
        for (uint256 i = 0; i < actors.length; ++i) {
            mintErc20Token(address(DUST), actors[i], TOKEN_10M);
        }
        dustLock.toggleSplit(address(0), true);

        handler = new ClaimReformStatefulHandler(
            DUST, dustLock, claimStrategy, DUST_VAULT, CLAIM_CONTROLLER, BURN_WALLET, address(this), actors
        );
    }
}

/**
 * @title ClaimReformStatefulInvariantTest
 * @author Neverland
 * @notice Stateful conservation and quote invariants across the complete NGV-05 lifecycle
 */
contract ClaimReformStatefulInvariantTest is StdInvariant, ClaimReformStatefulFixture {
    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    /// @notice Registers every lifecycle action as an invariant target selector
    function _setUp() internal override {
        super._setUp();

        bytes4[] memory selectors = new bytes4[](17);
        selectors[0] = handler.actionCreateTimed.selector;
        selectors[1] = handler.actionCreatePermanent.selector;
        selectors[2] = handler.actionDepositFor.selector;
        selectors[3] = handler.actionIncreaseAmount.selector;
        selectors[4] = handler.actionExtend.selector;
        selectors[5] = handler.actionTransfer.selector;
        selectors[6] = handler.actionSplit.selector;
        selectors[7] = handler.actionMerge.selector;
        selectors[8] = handler.actionLockPermanent.selector;
        selectors[9] = handler.actionUnlockPermanent.selector;
        selectors[10] = handler.actionEarlyWithdraw.selector;
        selectors[11] = handler.actionMatureWithdraw.selector;
        selectors[12] = handler.actionClaimInstant.selector;
        selectors[13] = handler.actionClaimNewTimed.selector;
        selectors[14] = handler.actionClaimPermanent.selector;
        selectors[15] = handler.actionClaimExisting.selector;
        selectors[16] = handler.actionAdvanceTime.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                              INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.fail-on-revert = true
    function invariantPrincipalAndPermanentAccountingConserveExactly() public view {
        (uint256 livePrincipal, uint256 permanentPrincipal, uint256 liveCount, uint256[3] memory ownerCounts) =
            _summarizeLocks();

        assertEq(livePrincipal, dustLock.supply());
        assertEq(livePrincipal, DUST.balanceOf(address(dustLock)));
        assertEq(livePrincipal, handler.expectedLockedSupply());
        assertEq(permanentPrincipal, dustLock.permanentLockBalance());
        assertEq(liveCount, ownerCounts[0] + ownerCounts[1] + ownerCounts[2]);
        for (uint256 i = 0; i < ownerCounts.length; ++i) {
            assertEq(ownerCounts[i], dustLock.balanceOf(handler.actorAt(i)));
        }
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariantEveryLiveQuoteMatchesIndependentModel() public view {
        uint256 lastTokenId = dustLock.tokenId();
        for (uint256 tokenId = 1; tokenId <= lastTokenId; ++tokenId) {
            IDustLock.LockedBalance memory lock = dustLock.locked(tokenId);
            if (lock.amount == 0) {
                assertEq(dustLock.earlyWithdrawPenaltyAmount(tokenId), 0);
                continue;
            }

            uint256 amount = uint256(lock.amount);
            uint256 remaining = lock.end > block.timestamp ? lock.end - block.timestamp : 0;
            (uint256 expectedPenalty,) = lock.isPermanent
                ? ClaimReformModel.permanentExit(amount, block.timestamp)
                : ClaimReformModel.timedExit(amount, remaining);
            uint256 actualPenalty = dustLock.earlyWithdrawPenaltyAmount(tokenId);

            assertLe(actualPenalty, amount);
            assertEq(actualPenalty, expectedPenalty);
        }
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariantDustSupplyAndPenaltyRoutingConserveExactly() public view {
        assertEq(DUST.totalSupply(), handler.initialTotalSupply());
        assertEq(handler.trackedBalance() + handler.untrackedBalance(), handler.initialTotalSupply());
        assertEq(DUST.balanceOf(BURN_WALLET), handler.initialBurnWalletBalance() + handler.ghostPenaltyRouted());
        assertEq(DUST.balanceOf(address(claimStrategy)), 0);
        assertEq(DUST.allowance(address(claimStrategy), address(dustLock)), 0);
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariantNftExistenceMatchesLockExistence() public view {
        uint256 lastTokenId = dustLock.tokenId();
        for (uint256 tokenId = 1; tokenId <= lastTokenId; ++tokenId) {
            IDustLock.LockedBalance memory lock = dustLock.locked(tokenId);
            (bool exists, address owner) = _ownerOf(tokenId);

            if (lock.amount == 0) {
                assertFalse(exists);
                assertEq(owner, address(0));
            } else {
                assertTrue(exists);
                assertTrue(_isActor(owner));
                if (lock.isPermanent) assertEq(lock.end, 0);
            }
        }
    }

    /**
     * @notice Bookkeeping-only post-campaign check
     * @dev Absolute coverage counters and action masks must not be asserted in afterInvariant:
     *      foundry's shrinker replays short prefixes of a failing sequence, and such asserts would
     *      collapse genuine invariant failures into 1-call replay artifacts. Anti-vacuity is pinned
     *      by ClaimReformStatefulReachabilityTest.testEveryActionClassHasExecutablePath instead. The
     *      call partition equality below holds on any prefix, so it is shrinker-safe.
     */
    function afterInvariant() public view {
        assertEq(handler.totalCalls(), handler.successfulCalls() + handler.failedCalls());
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNAL
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Reconciles every minted token id into live principal, permanence, and bounded owners
     * @return livePrincipal Sum of every nonzero lock amount
     * @return permanentPrincipal Sum of every permanent lock amount
     * @return liveCount Number of live veNFTs
     * @return ownerCounts Live veNFT count held by each bounded actor
     */
    function _summarizeLocks()
        internal
        view
        returns (uint256 livePrincipal, uint256 permanentPrincipal, uint256 liveCount, uint256[3] memory ownerCounts)
    {
        uint256 lastTokenId = dustLock.tokenId();
        for (uint256 tokenId = 1; tokenId <= lastTokenId; ++tokenId) {
            IDustLock.LockedBalance memory lock = dustLock.locked(tokenId);
            if (lock.amount == 0) continue;

            uint256 amount = uint256(lock.amount);
            livePrincipal += amount;
            if (lock.isPermanent) permanentPrincipal += amount;
            ++liveCount;

            (bool exists, address owner) = _ownerOf(tokenId);
            assertTrue(exists);
            bool matched;
            for (uint256 i = 0; i < ownerCounts.length; ++i) {
                if (owner == handler.actorAt(i)) {
                    ++ownerCounts[i];
                    matched = true;
                    break;
                }
            }
            assertTrue(matched);
        }
    }

    /**
     * @notice Resolves an owner without letting a burned-token revert escape the invariant
     * @param tokenId Candidate veNFT identifier
     * @return exists True when the NFT exists
     * @return owner Current owner, or zero for a burned token
     */
    function _ownerOf(uint256 tokenId) internal view returns (bool exists, address owner) {
        try dustLock.ownerOf(tokenId) returns (address currentOwner) {
            return (true, currentOwner);
        } catch {
            return (false, address(0));
        }
    }

    /**
     * @notice Checks whether an address belongs to the bounded actor set
     * @param account Candidate owner
     * @return True when the account is one of the three actors
     */
    function _isActor(address account) internal view returns (bool) {
        return account == handler.actorAt(0) || account == handler.actorAt(1) || account == handler.actorAt(2);
    }
}

/**
 * @title ClaimReformStatefulReachabilityTest
 * @author Neverland
 * @notice Deterministic anti-vacuity proof that every registered handler action can succeed
 */
contract ClaimReformStatefulReachabilityTest is ClaimReformStatefulFixture {
    function testEveryActionClassHasExecutablePath() public {
        handler.actionCreateTimed(1, 4 * TOKEN_1, 180 days);
        handler.actionCreatePermanent(1, 4 * TOKEN_1);
        handler.actionDepositFor(1, 1, TOKEN_1);
        handler.actionIncreaseAmount(1, TOKEN_1);
        handler.actionExtend(1, MAXTIME);
        handler.actionTransfer(1, 1);
        handler.actionSplit(1, TOKEN_1);
        handler.actionMerge(1, 1);
        handler.actionLockPermanent(1);
        handler.actionUnlockPermanent(1);
        handler.actionClaimInstant(1, 10 * TOKEN_1);
        handler.actionClaimNewTimed(1, 10 * TOKEN_1, 180 days);
        handler.actionClaimPermanent(1, 10 * TOKEN_1);
        handler.actionClaimExisting(1, 10 * TOKEN_1);
        handler.actionEarlyWithdraw(1);
        handler.actionAdvanceTime(1, WEEK);
        handler.actionMatureWithdraw(1);

        assertEq(handler.successMask(), handler.allActionsMask());
        assertEq(handler.totalCalls(), 17);
        assertEq(handler.successfulCalls(), 17);
        assertEq(handler.failedCalls(), 0);
    }

    function testInvalidIdActionsAreCaughtWithoutProtocolStateDelta() public {
        uint256 supplyBefore = dustLock.supply();
        uint256 permanentBefore = dustLock.permanentLockBalance();
        uint256 tokenIdBefore = dustLock.tokenId();
        uint256 lockBalanceBefore = DUST.balanceOf(address(dustLock));
        uint256 burnBalanceBefore = DUST.balanceOf(BURN_WALLET);
        uint256 totalSupplyBefore = DUST.totalSupply();

        handler.actionDepositFor(13, 1, TOKEN_1);
        handler.actionIncreaseAmount(13, TOKEN_1);
        handler.actionExtend(13, MAXTIME);
        handler.actionTransfer(13, 1);
        handler.actionSplit(13, TOKEN_1);
        handler.actionMerge(13, 1);
        handler.actionLockPermanent(13);
        handler.actionUnlockPermanent(13);
        handler.actionEarlyWithdraw(13);
        handler.actionMatureWithdraw(13);
        handler.actionClaimExisting(13, 10 * TOKEN_1);

        assertEq(handler.totalCalls(), 11);
        assertEq(handler.successfulCalls(), 0);
        assertEq(handler.failedCalls(), 11);
        assertEq(handler.successMask(), 0);
        assertEq(dustLock.supply(), supplyBefore);
        assertEq(dustLock.permanentLockBalance(), permanentBefore);
        assertEq(dustLock.tokenId(), tokenIdBefore);
        assertEq(DUST.balanceOf(address(dustLock)), lockBalanceBefore);
        assertEq(DUST.balanceOf(BURN_WALLET), burnBalanceBefore);
        assertEq(DUST.totalSupply(), totalSupplyBefore);
    }

    function testMaxRecipientSeedCannotOverflowTransferSelection() public {
        handler.actionTransfer(1, type(uint256).max);

        assertEq(handler.totalCalls(), 1);
        assertEq(handler.successfulCalls(), 1);
        assertEq(handler.failedCalls(), 0);
    }
}
