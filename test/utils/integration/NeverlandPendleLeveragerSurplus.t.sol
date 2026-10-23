// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ILeverager, PendleLeveragerLendingBase} from "../helpers/PendleLeveragerLendingBase.sol";

/**
 * @title NeverlandPendleLeveragerSurplusTest
 * @author Neverland
 * @notice Final surplus payments, cash limits and debt-share dust against the real lending core.
 */
contract NeverlandPendleLeveragerSurplusTest is PendleLeveragerLendingBase {
    address internal alice = makeAddr("surplus alice");

    /*//////////////////////////////////////////////////////////////
                                 TESTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Catches refunding usable cash, spending donations or adding a flash for the final repayment.
    function test_surplusRepaysRemainingDebtBothLenders() public {
        for (uint256 lender; lender < 2; ++lender) {
            uint256 state = vm.snapshotState();
            _create(alice, 100e6, 100e6);
            _lender(lender == 1, 25e6);
            ausd.mint(address(leverager), 19);
            ILeverager.PositionResult memory result = _execute(60e6, 50e6, 70e6, 2);
            assertEq(result.cashRepaid, 60e6);
            assertEq(result.debtAfter, 40e6);
            assertEq(result.surplus, 0);
            assertEq(result.rounds, 2);
            assertEq(ausd.balanceOf(alice), 0);
            assertEq(aNew.balanceOf(alice), 140e6);
            _assertCustody(19, 0, 0, 0);
            assertTrue(vm.revertToState(state));
        }
    }

    /// @dev Catches exceeding the total cash cap while sweeping a larger surplus.
    function test_surplusStopsAtCashCapAndRefundsTheRest() public {
        _create(alice, 100e6, 100e6);
        ILeverager.PositionResult memory result = _execute(60e6, 50e6, 55e6, 1);
        assertEq(result.cashRepaid, 55e6);
        assertEq(result.debtAfter, 45e6);
        assertEq(result.surplus, 5e6);
        assertEq(ausd.balanceOf(alice), 5e6);
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Catches sweeping before the residual PT sale following direct initial settlement.
    function test_surplusIncludesResidualConversionAfterDirectRepayment() public {
        _create(alice, 200e6, 100e6);
        _setMorphoCash(30e6);
        ILeverager.PositionResult memory result = _execute(120e6, 60e6, 80e6, 1);
        assertEq(result.cashRepaid, 80e6);
        assertEq(result.debtAfter, 20e6);
        assertEq(result.surplus, 40e6);
        assertEq(result.rounds, 1);
        assertEq(result.ptWithdrawn, 120e6);
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Catches a zero-amount pool call after the mandatory repayment exhausts the cap.
    function test_noCapHeadroomRefundsAllSurplus() public {
        _create(alice, 100e6, 100e6);
        ILeverager.PositionResult memory result = _execute(60e6, 50e6, 50e6, 1);
        assertEq(result.cashRepaid, 50e6);
        assertEq(result.debtAfter, 50e6);
        assertEq(result.surplus, 10e6);
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Catches paying beyond outstanding debt or failing to report the additional full-balance payment.
    function test_surplusCanClearDebtAndRefundRemainingEquity() public {
        _create(alice, 100e6, 100e6);
        ILeverager.PositionResult memory result = _execute(120e6, 80e6, 120e6, 1);
        assertEq(result.cashRepaid, 100e6);
        assertEq(result.debtAfter, 0);
        assertEq(_debtShares(alice), 0);
        assertEq(result.surplus, 20e6);
        assertEq(ausd.balanceOf(alice), 20e6);
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Catches a hardcoded one-unit exclusion when the reserve index is exactly par.
    function test_oneUnitSurplusRepaysAtParIndex() public {
        _create(alice, 100e6, 100e6);
        assertEq(pool.getReserveNormalizedVariableDebt(address(ausd)), 1e27);
        ILeverager.PositionResult memory result = _execute(50e6 + 1, 50e6, 60e6, 1);
        assertEq(result.cashRepaid, 50e6 + 1);
        assertEq(result.debtAfter, 50e6 - 1);
        assertEq(result.surplus, 0);
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Catches an unconditional dust repayment that reverts after an otherwise successful decrease.
    function test_oneUnitSurplusRefundsAboveParIndex() public {
        _create(alice, 100e6, 100e6);
        vm.warp(block.timestamp + 1 days);
        assertGt(pool.getReserveNormalizedVariableDebt(address(ausd)), 1e27);
        ILeverager.PositionResult memory result = _execute(50e6 + 1, 50e6, 60e6, 1);
        assertEq(result.cashRepaid, 50e6);
        assertEq(result.surplus, 1);
        assertEq(ausd.balanceOf(alice), 1);
        assertGt(result.debtAfter, 0);
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Catches testing all surplus for share granularity before applying the smaller cash cap.
    function test_oneUnitCapHeadroomRefundsLargerSurplusAboveParIndex() public {
        _create(alice, 100e6, 100e6);
        vm.warp(block.timestamp + 1 days);
        ILeverager.PositionResult memory result = _execute(60e6, 50e6, 50e6 + 1, 1);
        assertEq(result.cashRepaid, 50e6);
        assertEq(result.surplus, 10e6);
        assertEq(ausd.balanceOf(alice), 10e6);
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Catches treating one raw unit as the only possible zero-share repayment.
    function test_twoUnitSurplusRefundsAboveTwoRayIndex() public {
        _createAtTwoRayIndex();
        ILeverager.PositionResult memory result = _execute(50e6 + 2, 50e6, 60e6, 1);
        assertEq(result.cashRepaid, 50e6);
        assertEq(result.surplus, 2);
        assertEq(ausd.balanceOf(alice), 2);
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Catches rounding the minimum repayable cash upward by an extra raw unit.
    function test_threeUnitSurplusRepaysAboveTwoRayIndex() public {
        uint256 index = _createAtTwoRayIndex();
        uint256 sharesBefore = _debtShares(alice);
        ILeverager.PositionResult memory result = _execute(50e6 + 3, 50e6, 60e6, 1);
        assertEq(result.cashRepaid, 50e6 + 3);
        assertEq(_debtShares(alice), sharesBefore - (50e6 * 1e27 / index) - 1);
        assertEq(result.surplus, 0);
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Catches preview-only sweeping or failure to roll back the final repayment and its approvals.
    function test_surplusPreviewMatchesExecutionAndRollsBack() public {
        _create(alice, 100e6, 100e6);
        _approveCollateral(alice, 60e6);
        ILeverager.DecreaseParams memory params = _decreaseParams(60e6, 50e6, 1);
        params.maxCashRepaid = 70e6;
        bytes32 beforeState = _stateDigest(alice);
        vm.prank(alice);
        ILeverager.PositionResult memory preview = leverager.previewDecreaseLeverage(params);
        assertEq(_stateDigest(alice), beforeState);
        assertEq(preview.cashRepaid, 60e6);
        assertEq(preview.surplus, 0);
        vm.prank(alice);
        ILeverager.PositionResult memory result = leverager.decreaseLeverage(params);
        assertEq(keccak256(abi.encode(result)), keccak256(abi.encode(preview)));
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Catches an event that drops the surplus payment from the cash repaid or reports it as a refund.
    function test_surplusRepaymentIsReportedInTheDecreaseEvent() public {
        _create(alice, 100e6, 100e6);
        _approveCollateral(alice, 60e6);
        ILeverager.DecreaseParams memory params = _decreaseParams(60e6, 50e6, 1);
        params.maxCashRepaid = 70e6;
        vm.expectEmit(true, false, false, true, address(leverager));
        emit ILeverager.LeverageDecreased(alice, 60e6, 60e6, 40e6, 0, 1);
        vm.prank(alice);
        leverager.decreaseLeverage(params);
    }

    /// @dev Catches a fixed dust cutoff: below ceil(index / RAY) the surplus is refunded, from it upward it is repaid.
    function testFuzz_surplusDustCutoffFollowsTheBorrowIndex(uint256 rawElapsed, uint256 rawExtra) public {
        _create(alice, 500e6, 100e6);
        vm.warp(block.timestamp + bound(rawElapsed, 1 days, 8 * 365 days));
        uint256 unit = _minimumPartialCash();
        uint256 extra = bound(rawExtra, 1, 2 * unit);
        ILeverager.PositionResult memory result = _execute(50e6 + extra, 50e6, 60e6, 1);
        assertEq(result.cashRepaid, extra < unit ? 50e6 : 50e6 + extra);
        assertEq(result.surplus, extra < unit ? extra : 0);
        assertEq(ausd.balanceOf(alice), result.surplus);
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Catches cap overflow, missed usable cash and cash/debt accounting divergence over partial repayments.
    function testFuzz_surplusCashConservationAndCap(uint256 rawTarget, uint256 rawExtra, uint256 rawHeadroom) public {
        uint256 target = bound(rawTarget, 10e6, 60e6);
        uint256 extra = bound(rawExtra, 0, 10e6);
        uint256 headroom = bound(rawHeadroom, 0, 10e6);
        _create(alice, 200e6, 100e6);
        ILeverager.PositionResult memory result = _execute(target + extra, target, target + headroom, 1);
        assertGe(result.cashRepaid, target);
        assertLe(result.cashRepaid, target + headroom);
        assertEq(result.cashRepaid + result.surplus, target + extra);
        assertEq(result.debtAfter + result.cashRepaid, 100e6);
        if (result.cashRepaid < target + headroom) assertEq(result.surplus, 0);
        assertEq(ausd.balanceOf(alice), result.surplus);
        _assertCustody(0, 0, 0, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Execute the selected sale with an independently bounded total cash repayment.
     * @param pt Raw PT sold.
     * @param repayment Required initial cash repayment.
     * @param cap Maximum aggregate debt-asset cash spent.
     * @param rounds Maximum flash rounds.
     * @return result Measured settled position and cash outcome.
     */
    function _execute(uint256 pt, uint256 repayment, uint256 cap, uint256 rounds)
        private
        returns (ILeverager.PositionResult memory result)
    {
        _approveCollateral(alice, pt);
        ILeverager.DecreaseParams memory params = _decreaseParams(pt, repayment, rounds);
        params.maxCashRepaid = cap;
        vm.prank(alice);

        return leverager.decreaseLeverage(params);
    }

    /**
     * @notice Open a 500 PT position and accrue eight years so the borrow index lies between two and three RAY.
     * @return index Current normalized variable-debt index.
     */
    function _createAtTwoRayIndex() private returns (uint256 index) {
        _create(alice, 500e6, 100e6);
        vm.warp(block.timestamp + 8 * 365 days);
        index = pool.getReserveNormalizedVariableDebt(address(ausd));
        assertGt(index, 2e27);
        assertLt(index, 3e27);
    }
}
