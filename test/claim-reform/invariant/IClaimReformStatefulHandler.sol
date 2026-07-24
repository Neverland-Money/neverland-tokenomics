// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/**
 * @title IClaimReformStatefulHandler
 * @author Neverland
 * @notice Test-only API for the bounded NGV-05 lifecycle invariant machine
 */
interface IClaimReformStatefulHandler {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Bundles modeled claim outputs with the pre-call accounting snapshot
     * @param expectedPenalty Modeled burn-wallet allocation
     * @param expectedNet Modeled principal added to the selected lock
     * @param supplyBefore DustLock principal supply before the claim
     * @param vaultBalanceBefore Reward-vault DUST balance before the claim
     * @param burnBalanceBefore Burn-wallet DUST balance before the claim
     */
    struct ClaimSnapshot {
        uint256 expectedPenalty;
        uint256 expectedNet;
        uint256 supplyBefore;
        uint256 vaultBalanceBefore;
        uint256 burnBalanceBefore;
    }

    /**
     * @notice Classifies the lifecycle state required by a token-selection helper
     * @dev Variant order has no numeric meaning outside this test handler.
     */
    enum CandidateKind {
        ANY,
        TIMED_ACTIVE,
        TIMED,
        PERMANENT
    }

    /*//////////////////////////////////////////////////////////////
                              ACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a timed lock for one bounded actor
     * @param actorSeed Selects the owner
     * @param rawAmount Fuzzed principal seed
     * @param rawDuration Fuzzed requested-duration seed
     */
    function actionCreateTimed(uint256 actorSeed, uint256 rawAmount, uint256 rawDuration) external;

    /**
     * @notice Creates a permanent lock for one bounded actor
     * @param actorSeed Selects the owner
     * @param rawAmount Fuzzed principal seed
     */
    function actionCreatePermanent(uint256 actorSeed, uint256 rawAmount) external;

    /**
     * @notice Deposits permissionlessly into a selected live lock
     * @param tokenSeed Selects a live or deliberately invalid token id
     * @param actorSeed Selects the depositing actor
     * @param rawAmount Fuzzed increase seed
     */
    function actionDepositFor(uint256 tokenSeed, uint256 actorSeed, uint256 rawAmount) external;

    /**
     * @notice Increases a selected live lock through its owner-gated route
     * @param tokenSeed Selects a live or deliberately invalid token id
     * @param rawAmount Fuzzed increase seed
     */
    function actionIncreaseAmount(uint256 tokenSeed, uint256 rawAmount) external;

    /**
     * @notice Extends one active timed lock and proves its penalty cannot fall
     * @param tokenSeed Selects an active timed or deliberately invalid token id
     * @param rawDuration Fuzzed requested-duration seed
     */
    function actionExtend(uint256 tokenSeed, uint256 rawDuration) external;

    /**
     * @notice Transfers a live veNFT within the bounded actor set and proves quote neutrality
     * @param tokenSeed Selects a live or deliberately invalid token id
     * @param recipientSeed Selects a recipient distinct from the current owner
     */
    function actionTransfer(uint256 tokenSeed, uint256 recipientSeed) external;

    /**
     * @notice Splits one eligible timed lock and pins the one-wei ceiling-rounding envelope
     * @param tokenSeed Selects a splittable or deliberately invalid token id
     * @param rawAmount Fuzzed second-child principal seed
     */
    function actionSplit(uint256 tokenSeed, uint256 rawAmount) external;

    /**
     * @notice Merges a compatible same-owner pair and pins principal plus rounding conservation
     * @param tokenSeed Selects the source side of a compatible pair
     * @param pairSeed Selects the destination side of a compatible pair
     */
    function actionMerge(uint256 tokenSeed, uint256 pairSeed) external;

    /**
     * @notice Converts one active timed lock to permanent state
     * @param tokenSeed Selects an active timed or deliberately invalid token id
     */
    function actionLockPermanent(uint256 tokenSeed) external;

    /**
     * @notice Converts one permanent lock back to a maximum-duration timed lock
     * @param tokenSeed Selects a permanent or deliberately invalid token id
     */
    function actionUnlockPermanent(uint256 tokenSeed) external;

    /**
     * @notice Exits one live lock and reconciles owner proceeds plus burn-wallet penalty
     * @param tokenSeed Selects a live or deliberately invalid token id
     */
    function actionEarlyWithdraw(uint256 tokenSeed) external;

    /**
     * @notice Warps one timed lock to maturity and withdraws it without penalty
     * @param tokenSeed Selects a timed or deliberately invalid token id
     */
    function actionMatureWithdraw(uint256 tokenSeed) external;

    /**
     * @notice Releases an instant reward claim and reconciles its fixed penalty
     * @param actorSeed Selects the reward recipient
     * @param rawGross Fuzzed gross reward seed
     */
    function actionClaimInstant(uint256 actorSeed, uint256 rawGross) external;

    /**
     * @notice Releases a reward claim into a new timed lock
     * @param actorSeed Selects the reward recipient
     * @param rawGross Fuzzed gross reward seed
     * @param rawDuration Fuzzed requested-duration seed
     */
    function actionClaimNewTimed(uint256 actorSeed, uint256 rawGross, uint256 rawDuration) external;

    /**
     * @notice Releases a reward claim into a new permanent lock
     * @param actorSeed Selects the reward recipient
     * @param rawGross Fuzzed gross reward seed
     */
    function actionClaimPermanent(uint256 actorSeed, uint256 rawGross) external;

    /**
     * @notice Releases a reward claim into one selected existing lock
     * @param tokenSeed Selects a live or deliberately invalid token id
     * @param rawGross Fuzzed gross reward seed
     */
    function actionClaimExisting(uint256 tokenSeed, uint256 rawGross) external;

    /**
     * @notice Moves time across second, week, minimum-duration, and maximum-duration boundaries
     * @param rawMode Selects the boundary class
     * @param rawDelta Fuzzed forward-delta seed
     */
    function actionAdvanceTime(uint256 rawMode, uint256 rawDelta) external;

    /*//////////////////////////////////////////////////////////////
                               VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns one bounded actor
     * @param index Actor index from zero through two
     * @return Actor address
     */
    function actorAt(uint256 index) external view returns (address);

    /**
     * @notice Returns the bit mask containing every registered action
     * @return Complete action mask
     */
    function allActionsMask() external pure returns (uint256);

    /**
     * @notice Returns seed supply plus modeled inflows minus modeled outflows
     * @return Independently expected locked supply
     */
    function expectedLockedSupply() external view returns (uint256);

    /**
     * @notice Sums DUST across every address intentionally reachable by this machine
     * @return balance Aggregate tracked balance
     */
    function trackedBalance() external view returns (uint256 balance);

    /// @notice Returns DUST supply captured after actor funding and seed-lock creation
    function initialTotalSupply() external view returns (uint256);

    /// @notice Returns the burn-wallet balance captured before randomized actions
    function initialBurnWalletBalance() external view returns (uint256);

    /// @notice Returns baseline DUST held outside the explicitly tracked address set
    function untrackedBalance() external view returns (uint256);

    /// @notice Returns locked supply captured after deterministic seed-lock creation
    function initialLockedSupply() external view returns (uint256);

    /// @notice Returns the gross number of handler actions invoked by the invariant runner
    function totalCalls() external view returns (uint256);

    /// @notice Returns the number of handler actions whose protocol call succeeded
    function successfulCalls() external view returns (uint256);

    /// @notice Returns the number of caught protocol reverts proven atomic by a state fingerprint
    function failedCalls() external view returns (uint256);

    /// @notice Returns the bit set for every action selector invoked at least once
    function attemptedMask() external view returns (uint256);

    /// @notice Returns the bit set for every action selector completed successfully at least once
    function successMask() external view returns (uint256);

    /// @notice Returns independently modeled principal added to DustLock after seeding
    function ghostPrincipalIn() external view returns (uint256);

    /// @notice Returns independently modeled principal removed from DustLock after seeding
    function ghostPrincipalOut() external view returns (uint256);

    /// @notice Returns independently modeled cumulative DUST routed to the burn wallet
    function ghostPenaltyRouted() external view returns (uint256);
}
