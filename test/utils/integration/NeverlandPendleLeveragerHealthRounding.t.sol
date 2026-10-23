// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ILeverager, PendleLeveragerLendingBase} from "../helpers/PendleLeveragerLendingBase.sol";

// Documented decrease limits on the real lending core: entry-health rounding of a proportional split, health below one
// across balanced rounds, par-priced PT headroom, explicit repayment budgets and a donation-raised max-PT entry floor.
contract NeverlandPendleLeveragerHealthRoundingTest is PendleLeveragerLendingBase {
    address internal alice = makeAddr("health rounding alice");

    // ------------------------------------------------------------------ proportional split at a non-unit index

    function test_proportionalSplitAtANonUnitIndexRevertsOnTheEntryHealthRounding() public {
        uint256 entryHealth = _openAtNonUnitIndex();
        assertEq(vDebt.balanceOf(alice), 103_427_263);
        // 10_000_000 / 103_427_263 of the 200_000_000 collateral rounds to 19_337_261 PT.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ILeverager.HealthFactorBelowMinimum.selector, 1_834_100_532_846_600_324, entryHealth)
        );
        leverager.decreaseLeverage(_decreaseParams(19_337_261, 10_000_000, 4));
    }

    function test_trimmingTheCollateralByTwoUnitsRestoresTheEntryHealthFloor() public {
        uint256 entryHealth = _openAtNonUnitIndex();
        // Trimming a single unit still rounds below the entry health.
        vm.prank(alice);
        vm.expectPartialRevert(ILeverager.HealthFactorBelowMinimum.selector);
        leverager.decreaseLeverage(_decreaseParams(19_337_260, 10_000_000, 4));
        vm.prank(alice);
        ILeverager.PositionResult memory result = leverager.decreaseLeverage(_decreaseParams(19_337_259, 10_000_000, 4));
        assertGe(result.healthFactorAfter, entryHealth);
        assertEq(result.cashRepaid, 10_000_000);
        assertEq(result.debtAfter, 93_427_264, "10_000_000 of cash retires only 9_999_999 of debt");
    }

    // ------------------------------------------------------------------ health factor below one

    function test_belowUnitHealthMultiRoundCloseOfAllPtRevertsAtTheFirstReceiptPull() public {
        _openBelowUnitHealth();
        _setMorphoCash(100_000e6);
        ILeverager.DecreaseParams memory params = _decreaseParams(type(uint256).max, type(uint256).max, 40);
        bytes32 beforeState = _stateDigest(alice);
        // Balanced rounds repay and withdraw the same fraction, so the first pull keeps health below one: error 35.
        vm.prank(alice);
        vm.expectRevert(bytes("35"));
        leverager.previewDecreaseLeverage(params);
        vm.prank(alice);
        vm.expectRevert(bytes("35"));
        leverager.decreaseLeverage(params);
        assertEq(_stateDigest(alice), beforeState);
    }

    function test_belowUnitHealthCloseClearsInOneRoundWhenLenderCashCoversTheDebt() public {
        _openBelowUnitHealth();
        _setMorphoCash(2_000_000e6);
        vm.prank(alice);
        ILeverager.PositionResult memory result =
            leverager.decreaseLeverage(_decreaseParams(type(uint256).max, type(uint256).max, 40));
        // One round repays all debt before its pull, so the pool has no health to check.
        assertEq(result.rounds, 1);
        assertEq(result.debtAfter, 0);
        assertEq(result.cashRepaid, 1_500_000e6);
        assertEq(result.ptWithdrawn, 1_600_000e6);
        assertEq(result.surplus, 68_000e6);
        assertEq(ausd.balanceOf(alice), 68_000e6);
        assertEq(aNew.balanceOf(alice), 0);
        assertEq(ausd.balanceOf(address(morpho)), 2_000_000e6);
        _assertCustody(0, 0, 0, 0);
    }

    function test_belowUnitHealthPreviewSizedPtLetsTheFirstRoundRestoreHealth() public {
        _openBelowUnitHealth();
        // PT that funds the whole repayment at the 0.98 sale price plus a 0.1% margin, checked by a same-state preview.
        uint256 debt = vDebt.balanceOf(alice);
        uint256 needed = (debt * 1e18 + 0.98e18 - 1) / 0.98e18;
        uint256 ptAmount = needed + needed / 1_000;
        ILeverager.DecreaseParams memory params = _decreaseParams(ptAmount, type(uint256).max, 40);
        // At 100k per round the first round is too small to lift health to one: error 35.
        _setMorphoCash(100_000e6);
        vm.prank(alice);
        vm.expectRevert(bytes("35"));
        leverager.previewDecreaseLeverage(params);
        // At 300k per round the first pull already leaves health above one, and each later round raises it.
        _setMorphoCash(300_000e6);
        vm.prank(alice);
        ILeverager.PositionResult memory preview = leverager.previewDecreaseLeverage(params);
        vm.prank(alice);
        ILeverager.PositionResult memory result = leverager.decreaseLeverage(params);
        assertEq(keccak256(abi.encode(result)), keccak256(abi.encode(preview)));
        assertEq(result.rounds, 5);
        assertEq(result.debtAfter, 0);
        assertEq(result.ptWithdrawn, ptAmount);
        assertEq(aNew.balanceOf(alice), 1_600_000e6 - ptAmount, "the PT the repayment did not need stays supplied");
        _assertCustody(0, 0, 0, 0);
    }

    function test_belowUnitHealthUndersizedPtFailsTheCallbackFundingCheck() public {
        _openBelowUnitHealth();
        _setMorphoCash(300_000e6);
        uint256 debt = vDebt.balanceOf(alice);
        uint256 needed = (debt * 1e18 + 0.98e18 - 1) / 0.98e18;
        // 0.1% below the PT the repayment needs: the first round's 0.98 sale falls 300_000_001 short of its flash.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ILeverager.InsufficientRepaymentProceeds.selector, 300_000e6, 299_699_999_999)
        );
        leverager.decreaseLeverage(_decreaseParams(needed - needed / 1_000, type(uint256).max, 40));
    }

    // ------------------------------------------------------------------ par-priced multi-round close

    function test_parMultiRoundCloseWithPtEqualToTheDebtRevertsOnCallbackFunding() public {
        uint256 debtBefore = _openParMultiRound();
        bytes32 beforeState = _stateDigest(alice);
        // Round one sells exactly its repayment; its floor-rounded share burn leaves one more unit of debt than PT,
        // so round two sells one unit less than it repays with no action surplus available.
        bytes memory shortfall =
            abi.encodeWithSelector(ILeverager.InsufficientRepaymentProceeds.selector, 22_103_240_857, 22_103_240_856);
        ILeverager.DecreaseParams memory params = _decreaseParams(debtBefore, type(uint256).max, 8);
        vm.prank(alice);
        vm.expectRevert(shortfall);
        leverager.previewDecreaseLeverage(params);
        vm.prank(alice);
        vm.expectRevert(shortfall);
        leverager.decreaseLeverage(params);
        // One PT unit above the debt funds three rounds exactly but still leaves round four a unit short.
        vm.prank(alice);
        vm.expectRevert(shortfall);
        leverager.decreaseLeverage(_decreaseParams(debtBefore + 1, type(uint256).max, 8));
        // Max PT capped by an aPT allowance equal to the debt is the same request.
        _approveCollateral(alice, debtBefore);
        vm.prank(alice);
        vm.expectRevert(shortfall);
        leverager.decreaseLeverage(_decreaseParams(type(uint256).max, type(uint256).max, 8));
        // Restore the max approval, which the state digest includes.
        _approveCollateral(alice, type(uint256).max);
        assertEq(_stateDigest(alice), beforeState);
    }

    function test_parMultiRoundCloseWithMaxPtClearsTheDebt() public {
        uint256 debtBefore = _openParMultiRound();
        vm.prank(alice);
        ILeverager.PositionResult memory result =
            leverager.decreaseLeverage(_decreaseParams(type(uint256).max, type(uint256).max, 8));
        assertEq(result.rounds, 2);
        assertEq(result.debtAfter, 0);
        assertEq(vDebt.balanceOf(alice), 0);
        assertEq(result.ptWithdrawn, 180_000e6);
        // Clearing fresh debt over several rounds spends more cash than the observed debt; the PT headroom funds it.
        assertEq(result.cashRepaid, debtBefore + 1);
        assertEq(result.cashRepaid + result.surplus, result.ptWithdrawn, "par: cash repaid plus surplus equals PT");
        assertEq(ausd.balanceOf(alice), result.surplus);
        assertEq(aNew.balanceOf(alice), 0);
        _assertCustody(0, 0, 0, 0);
    }

    // ------------------------------------------------------------------ explicit repayment budgets

    function test_explicitRepaymentClearsIndexedDustOnlyWithCapHeadroom() public {
        uint256 debtBefore = _openExplicitBudget();
        uint256[2] memory budgets = [debtBefore, type(uint256).max - 1];
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < budgets.length; ++i) {
            // 99% of the PT, so collateral stays behind whatever debt the budget leaves.
            vm.prank(alice);
            ILeverager.PositionResult memory result =
                leverager.decreaseLeverage(_decreaseParams(178_200e6, budgets[i], 40));
            assertEq(result.rounds, 5);
            assertEq(result.cashRepaid, debtBefore + (i == 0 ? 0 : 3), "surplus repayment uses only cap headroom");
            // Each partial burn floors its debt shares, so debt falls by up to two units less than the cash paid.
            assertEq(result.debtAfter, i == 0 ? 3 : 0);
            assertLe(result.debtAfter, 2 * (result.rounds + 1));
            assertEq(vDebt.balanceOf(alice), result.debtAfter);
            assertEq(aNew.balanceOf(alice), 1_800e6);
            _assertCustody(0, 0, 0, 0);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_explicitRepaymentAtLiveDebtWithAllPtRevertsAtTheFinalReceiptPullWithAnyCap() public {
        uint256 debtBefore = _openExplicitBudget();
        uint256[2] memory caps = [debtBefore, type(uint256).max];
        bytes32 beforeState = _stateDigest(alice);
        for (uint256 i; i < caps.length; ++i) {
            ILeverager.DecreaseParams memory params = _decreaseParams(type(uint256).max, debtBefore, 40);
            params.maxCashRepaid = caps[i];
            // The final round pulls the last collateral over the rounding dust, before any surplus payment can run.
            vm.prank(alice);
            vm.expectRevert(bytes("35"));
            leverager.previewDecreaseLeverage(params);
            vm.prank(alice);
            vm.expectRevert(bytes("35"));
            leverager.decreaseLeverage(params);
            assertEq(_stateDigest(alice), beforeState);
        }
    }

    function test_maxRepaymentClearsTheSameNonUnitDebtAcrossRounds() public {
        uint256 debtBefore = _openExplicitBudget();
        vm.prank(alice);
        ILeverager.PositionResult memory result =
            leverager.decreaseLeverage(_decreaseParams(type(uint256).max, type(uint256).max, 40));
        assertEq(result.rounds, 5);
        assertEq(result.debtAfter, 0);
        assertEq(vDebt.balanceOf(alice), 0);
        assertEq(_debtShares(alice), 0);
        assertEq(result.cashRepaid, debtBefore + 2, "clearing fresh debt also pays the rounding dust");
        assertEq(result.cashRepaid + result.surplus, 180_000e6);
        assertEq(aNew.balanceOf(alice), 0);
        _assertCustody(0, 0, 0, 0);
    }

    // ------------------------------------------------------------------ donated collateral with max PT

    function test_donatedAptRaisesTheEntryFloorOfAMaxPtDecreaseUnderAnExactCap() public {
        _openWithOtherCollateral();
        ILeverager.DecreaseParams memory params = _decreaseParams(type(uint256).max, 150e6, 4);
        uint256 snapshot = vm.snapshotState();
        // Without a donation the max-PT decrease sells all 500 PT, repays 150 and refunds 350.
        vm.prank(alice);
        ILeverager.PositionResult memory result = leverager.decreaseLeverage(params);
        assertEq(result.ptWithdrawn, 500e6);
        assertEq(result.surplus, 350e6);
        assertTrue(vm.revertToState(snapshot));
        // A donation raises the entry health factor and is sold and refunded too, so the same call reverts.
        address donor = makeAddr("health rounding donor");
        _supply(address(ptNew), donor, 600e6);
        vm.prank(donor);
        aNew.transfer(alice, 600e6);
        bytes32 beforeState = _stateDigest(alice);
        vm.prank(alice);
        vm.expectPartialRevert(ILeverager.HealthFactorBelowMinimum.selector);
        leverager.decreaseLeverage(params);
        assertEq(_stateDigest(alice), beforeState);
        // An explicit PT amount keeps the donation out of the selection.
        params.ptAmount = 500e6;
        vm.prank(alice);
        result = leverager.decreaseLeverage(params);
        assertEq(result.ptWithdrawn, 500e6);
        assertEq(aNew.balanceOf(alice), 600e6);
    }

    // ------------------------------------------------------------------ helpers

    // 500 PT-NEW against 300 debt, plus 1,000 PT-OLD collateral that the decrease never touches.
    function _openWithOtherCollateral() internal {
        _supply(address(ptOld), alice, 1_000e6);
        _create(alice, 200e6, 300e6);
        _approveCollateral(alice, type(uint256).max);
    }

    // A position at a non-unit debt index after 123 days of interest, with 10 AUSD of lender cash.
    function _openAtNonUnitIndex() internal returns (uint256 entryHealth) {
        _create(alice, 100e6, 100e6);
        vm.warp(block.timestamp + 123 days);
        entryHealth = _hf(alice);
        _approveCollateral(alice, 200e6);
        _setMorphoCash(10e6);
    }

    // Solvent but below health factor one: 1.6M PT priced at 0.97 against 1.5M debt, sold at 0.98.
    function _openBelowUnitHealth() internal {
        _create(alice, 100_000e6, 1_500_000e6);
        ptNewFeed.setAnswer(0.97e8);
        tradeRouter.setSalePrice(0.98e18);
        (uint256 collateralBase, uint256 debtBase,,,, uint256 health) = pool.getUserAccountData(alice);
        assertGt(collateralBase, debtBase, "solvent");
        assertEq(health, 0.99328e18, "below health factor one");
        _approveCollateral(alice, type(uint256).max);
    }

    // A year of interest lifts the debt index above one ray; lender cash is the debt divided by `cashDivisor`.
    function _openAfterAYearOfInterest(uint256 cashDivisor) internal returns (uint256 debtBefore) {
        _create(alice, 100_000e6, 80_000e6);
        vm.warp(block.timestamp + 365 days);
        debtBefore = vDebt.balanceOf(alice);
        assertEq(debtBefore, 88_412_963_426);
        assertGt(pool.getReserveNormalizedVariableDebt(address(ausd)), 1e27);
        _approveCollateral(alice, type(uint256).max);
        _setMorphoCash(debtBefore / cashDivisor);
    }

    // Unmatured PT sold at par, and lender cash is a third of the debt.
    function _openParMultiRound() internal returns (uint256 debtBefore) {
        debtBefore = _openAfterAYearOfInterest(3);
    }

    // Unmatured PT sold at par, and lender cash is a ninth of the debt.
    function _openExplicitBudget() internal returns (uint256 debtBefore) {
        debtBefore = _openAfterAYearOfInterest(9);
    }
}
