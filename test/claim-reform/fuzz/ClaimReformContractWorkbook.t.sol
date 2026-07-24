// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IDustLock} from "../../../src/interfaces/IDustLock.sol";

import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";
import {ClaimReformModel} from "../_utils/ClaimReformModel.sol";

import {DustLock} from "../../../src/tokens/DustLock.sol";
import {ClaimReformTestBase} from "../_utils/ClaimReformTestBase.sol";

/**
 * @title ClaimReformDustLockPricingHarness
 * @author Neverland
 * @notice Test-only state loader that executes the unmodified production exit quote
 */
contract ClaimReformDustLockPricingHarness is DustLock {
    constructor() DustLock(address(0x1)) {
        earlyWithdrawPenalty = DEFAULT_EARLY_WITHDRAW_PENALTY_BP;
    }

    /**
     * @notice Loads a valid pricing state without paying lifecycle gas for every workbook row
     * @param tokenId Test position identifier
     * @param amount Locked principal
     * @param end Timed-lock end, or zero for a permanent lock
     * @param isPermanent Whether the loaded position is permanent
     */
    function setPricingLock(uint256 tokenId, uint256 amount, uint256 end, bool isPermanent) external {
        _locked[tokenId] = LockedBalance({
            amount: int256(amount), effectiveStart: block.timestamp, end: end, isPermanent: isPermanent
        });
    }
}

/**
 * @title ClaimReformContractWorkbookTest
 * @author Neverland
 * @notice Contract-backed execution of every whole-day row in the approved economic workbook
 * @dev The independent model supplies expectations. The candidate strategy quotes all 338
 *      timed-claim commitments, executes the 289 nonboundary cases, and proves atomic deferral
 *      for the 49 exact-week-boundary cases. The unmodified DustLock quote executes 66,417 strict
 *      exits plus 338 maturities. The exhaustive gate is intentionally explicit because it is a
 *      pre-deployment proof, not part of every routine local run.
 */
contract ClaimReformContractWorkbookTest is ClaimReformTestBase {
    uint256 internal constant WORKBOOK_GROSS = 1_000 ether;
    uint256 internal constant MIN_COMMITMENT_DAYS = 28;
    uint256 internal constant MAX_COMMITMENT_DAYS = 365;
    uint256 internal constant EXPECTED_COMMITMENTS = 338;
    uint256 internal constant EXPECTED_EXECUTABLE_COMMITMENTS = 289;
    uint256 internal constant EXPECTED_BOUNDARY_DEFERRALS = 49;
    uint256 internal constant EXPECTED_STRICT_EXITS = 66_417;

    ClaimReformDustLockPricingHarness internal pricingHarness;

    function _setUp() internal override {
        super._setUp();
        pricingHarness = new ClaimReformDustLockPricingHarness();
    }

    function testContractBackedWorkbookExecutesEveryTimedClaimCommitment() public {
        _requireContractWorkbookGate();

        uint256 commitmentCount;
        uint256 executableCommitmentCount;
        uint256 boundaryDeferralCount;
        uint256 cursor = block.timestamp;
        for (uint256 commitmentDays = MIN_COMMITMENT_DAYS; commitmentDays <= MAX_COMMITMENT_DAYS; ++commitmentDays) {
            uint256 commitment = commitmentDays * 1 days;
            cursor = _nextTimestampRealizing(cursor, commitment);
            vm.warp(cursor);
            vm.roll(block.number + 1);

            (uint256 expectedPenalty, uint256 expectedNet) = ClaimReformModel.timedClaim(WORKBOOK_GROSS, commitment);
            (uint256 quotedPenalty, uint256 quotedNet) = claimStrategy.previewClaim(WORKBOOK_GROSS, commitment, 0);
            assertEq(quotedPenalty, expectedPenalty);
            assertEq(quotedNet, expectedNet);

            uint256 vaultBefore = DUST.balanceOf(DUST_VAULT);
            uint256 burnBefore = DUST.balanceOf(BURN_WALLET);
            uint256 tokenIdBefore = dustLock.tokenId();
            if (block.timestamp % WEEK == 0) {
                vm.prank(CLAIM_CONTROLLER);
                vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
                claimStrategy.performTransfer(user, address(DUST), WORKBOOK_GROSS, commitment, 0);

                assertEq(dustLock.tokenId(), tokenIdBefore);
                assertEq(DUST.balanceOf(DUST_VAULT), vaultBefore);
                assertEq(DUST.balanceOf(BURN_WALLET), burnBefore);
                assertEq(DUST.balanceOf(address(claimStrategy)), 0);
                assertEq(DUST.allowance(address(claimStrategy), address(dustLock)), 0);
                ++boundaryDeferralCount;
                ++commitmentCount;
                continue;
            }

            _claim(user, WORKBOOK_GROSS, commitment, 0);

            uint256 tokenId = dustLock.tokenId();
            IDustLock.LockedBalance memory lock = dustLock.locked(tokenId);
            assertEq(dustLock.ownerOf(tokenId), user);
            assertEq(uint256(lock.amount), expectedNet);
            assertEq(lock.end - block.timestamp, commitment);
            assertFalse(lock.isPermanent);
            assertEq(vaultBefore - DUST.balanceOf(DUST_VAULT), WORKBOOK_GROSS);
            assertEq(DUST.balanceOf(BURN_WALLET) - burnBefore, expectedPenalty);
            assertEq(DUST.balanceOf(address(claimStrategy)), 0);
            assertEq(DUST.allowance(address(claimStrategy), address(dustLock)), 0);
            ++executableCommitmentCount;
            ++commitmentCount;
        }

        assertEq(commitmentCount, EXPECTED_COMMITMENTS);
        assertEq(executableCommitmentCount, EXPECTED_EXECUTABLE_COMMITMENTS);
        assertEq(boundaryDeferralCount, EXPECTED_BOUNDARY_DEFERRALS);
    }

    function testContractBackedWorkbookExecutesEveryStrictExitAndMaturity() public {
        _requireContractWorkbookGate();

        uint256 strictExitCount;
        uint256 maturityCount;
        uint256 cursor = block.timestamp;
        for (uint256 commitmentDays = MIN_COMMITMENT_DAYS; commitmentDays <= MAX_COMMITMENT_DAYS; ++commitmentDays) {
            uint256 commitment = commitmentDays * 1 days;
            (, uint256 principal) = ClaimReformModel.timedClaim(WORKBOOK_GROSS, commitment);
            uint256 start = cursor + 1 days;
            pricingHarness.setPricingLock(1, principal, start + commitment, false);

            for (uint256 elapsedDays; elapsedDays < commitmentDays; ++elapsedDays) {
                vm.warp(start + elapsedDays * 1 days);
                uint256 remaining = (commitmentDays - elapsedDays) * 1 days;
                (uint256 expectedPenalty, uint256 expectedNet) = ClaimReformModel.timedExit(principal, remaining);
                uint256 actualPenalty = pricingHarness.earlyWithdrawPenaltyAmount(1);
                uint256 actualNet = principal - actualPenalty;

                assertEq(actualPenalty, expectedPenalty);
                assertEq(actualNet, expectedNet);
                assertEq(actualPenalty + actualNet, principal);
                assertLt(actualNet, ClaimReformModel.honestClaimNet(WORKBOOK_GROSS, elapsedDays * 1 days));
                ++strictExitCount;
            }

            vm.warp(start + commitment);
            assertEq(pricingHarness.earlyWithdrawPenaltyAmount(1), 0);
            ++maturityCount;
            cursor = block.timestamp;
        }

        assertEq(strictExitCount, EXPECTED_STRICT_EXITS);
        assertEq(maturityCount, EXPECTED_COMMITMENTS);
    }

    function testContractBackedWorkbookPermanentExitUsesFreshEndCurve() public {
        _requireContractWorkbookGate();

        pricingHarness.setPricingLock(1, WORKBOOK_GROSS, 0, true);
        (uint256 expectedPenalty, uint256 expectedNet) = ClaimReformModel.permanentExit(WORKBOOK_GROSS, block.timestamp);
        uint256 actualPenalty = pricingHarness.earlyWithdrawPenaltyAmount(1);

        assertEq(actualPenalty, expectedPenalty);
        assertEq(WORKBOOK_GROSS - actualPenalty, expectedNet);
        assertEq(actualPenalty + expectedNet, WORKBOOK_GROSS);
    }

    function _requireContractWorkbookGate() internal {
        vm.skip(
            !vm.envOr("RUN_CLAIM_REFORM_CONTRACT_WORKBOOK", false),
            "set RUN_CLAIM_REFORM_CONTRACT_WORKBOOK=true to execute the contract-backed workbook"
        );
    }

    function _nextTimestampRealizing(uint256 afterTimestamp, uint256 commitment)
        internal
        pure
        returns (uint256 timestamp)
    {
        uint256 requiredPhase = (WEEK - commitment % WEEK) % WEEK;
        uint256 futureWeek = (afterTimestamp / WEEK + 2) * WEEK;
        timestamp = futureWeek + requiredPhase;
    }
}
