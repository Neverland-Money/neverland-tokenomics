// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICreditDelegationToken} from "@neverland-money/lending-core/contracts/interfaces/ICreditDelegationToken.sol";
import {DataTypes} from "@neverland-money/lending-core/contracts/protocol/libraries/types/DataTypes.sol";
import {
    ReserveConfiguration
} from "@neverland-money/lending-core/contracts/protocol/libraries/configuration/ReserveConfiguration.sol";

import {ILeverager, PendleLeveragerLendingBase} from "../helpers/PendleLeveragerLendingBase.sol";

/// @notice Independent leverager integration with actual Pool, AToken, variable debt rounding and risk validation.
contract NeverlandPendleLeveragerLendingTest is PendleLeveragerLendingBase {
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
    address internal alice = makeAddr("leverager alice");
    address internal bob = makeAddr("leverager bob");

    /// @dev Catches an explicit second borrow or repayment approval in a mode-2 increase.
    function test_createFiniteDelegationConsumedExactlyOnceWithoutFlashRole() public {
        assertFalse(acl.isFlashBorrower(address(leverager)));
        ILeverager.PositionResult memory result = _create(alice, 100_000e6, 80_000e6);
        assertEq(result.principalSupplied, 100_000e6);
        assertEq(result.ptSupplied, 80_000e6);
        assertEq(result.cashBorrowed, 80_000e6);
        assertEq(result.debtBefore, 0);
        assertEq(result.debtAfter, 80_000e6);
        assertEq(vDebt.balanceOf(alice), 80_000e6);
        assertEq(aNew.balanceOf(alice), 180_000e6);
        assertEq(ICreditDelegationToken(address(vDebt)).borrowAllowance(alice, address(leverager)), 0);
        assertEq(result.flashSource, address(pool));
        assertEq(result.rounds, 1);
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Catches delayed debt omitted from the result or checking health only inside the callback.
    function test_increaseFinalHealthFailureRollsBackDebtDelegationAndPurchase() public {
        _create(alice, 100_000e6, 80_000e6);
        _approveDebt(alice, 10_000e6);
        uint256 shares = _debtShares(alice);
        uint256 swaps = tradeRouter.swapCount();
        uint256 poolCash = ausd.balanceOf(pool.getReserveData(address(ausd)).aTokenAddress);
        ILeverager.IncreaseParams memory params = _increaseParams(10_000e6);
        params.minHealthFactor = 3e18;
        vm.prank(alice);
        vm.expectPartialRevert(ILeverager.HealthFactorBelowMinimum.selector);
        leverager.increaseLeverage(params);
        assertEq(_debtShares(alice), shares);
        assertEq(aNew.balanceOf(alice), 180_000e6);
        assertEq(tradeRouter.swapCount(), swaps);
        assertEq(ausd.balanceOf(pool.getReserveData(address(ausd)).aTokenAddress), poolCash);
        assertEq(ICreditDelegationToken(address(vDebt)).borrowAllowance(alice, address(leverager)), 10_000e6);
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Catches supply silently treating an existing disabled reserve as active collateral.
    function test_increaseRejectsUserDisabledCollateralAtomically() public {
        _create(alice, 100_000e6, 0);
        vm.prank(alice);
        pool.setUserUseReserveAsCollateral(address(ptNew), false);
        _approveDebt(alice, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(ILeverager.CollateralNotEnabled.selector);
        leverager.increaseLeverage(_increaseParams(1_000e6));
        assertEq(aNew.balanceOf(alice), 100_000e6);
        assertEq(vDebt.balanceOf(alice), 0);
        assertEq(ICreditDelegationToken(address(vDebt)).borrowAllowance(alice, address(leverager)), 1_000e6);
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Catches passing max on behalf to repay, stale debt sizing and zero-scaled-burn rounding tails.
    function test_decreaseMaxClearsAccruedScaledDebtAcrossChunks() public {
        _create(alice, 100_000e6, 80_000e6);
        vm.warp(block.timestamp + 365 days);
        uint256 debt = vDebt.balanceOf(alice);
        assertGt(pool.getReserveNormalizedVariableDebt(address(ausd)), 1e27);
        assertGt(debt, 80_000e6);
        _setMorphoCash(25_000e6);
        uint256 lenderCash = ausd.balanceOf(address(morpho));
        ILeverager.PositionResult memory result = _decrease(alice, 180_000e6, type(uint256).max, 5);
        assertEq(result.debtBefore, debt);
        assertEq(result.debtAfter, 0);
        assertEq(vDebt.balanceOf(alice), 0);
        assertEq(_debtShares(alice), 0);
        assertEq(aNew.balanceOf(alice), 0);
        assertEq(result.ptWithdrawn, 180_000e6);
        assertEq(result.cashRepaid + result.surplus, 180_000e6);
        assertEq(ausd.balanceOf(alice), result.surplus);
        assertGt(result.rounds, 1);
        assertLe(result.rounds, 5);
        assertEq(ausd.balanceOf(address(morpho)), lenderCash);
        assertEq(aNew.allowance(alice, address(leverager)), 0);
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Catches using realized debt reduction as a cash budget and rounding PT independently each round.
    function test_decreasePartialCashBudgetWithRemainderConsumesExactPt() public {
        _create(alice, 100_000e6, 80_000e6);
        vm.warp(block.timestamp + 123 days);
        _setMorphoCash(9_000e6);
        uint256 debt = vDebt.balanceOf(alice);
        uint256 beforeHf = _hf(alice);
        ILeverager.PositionResult memory result = _decrease(alice, 30_000e6 + 1, 25_000e6 + 1, 4);
        assertEq(result.cashRepaid, 25_000e6 + 1);
        assertEq(result.surplus, 5_000e6);
        assertEq(result.ptWithdrawn, 30_000e6 + 1);
        assertEq(aNew.balanceOf(alice), 150_000e6 - 1);
        assertEq(result.debtBefore, debt);
        assertEq(result.debtAfter, vDebt.balanceOf(alice));
        assertApproxEqAbs(debt - result.debtAfter, result.cashRepaid, result.rounds * 2);
        assertGe(_hf(alice), beforeHf);
        assertEq(result.rounds, 3);
        uint256 sold;
        for (uint256 i; i < tradeRouter.saleCount(); ++i) {
            sold += tradeRouter.soldAmounts(i);
        }
        assertEq(sold, 30_000e6 + 1, "no per-round PT dust loss");
        assertEq(tradeRouter.saleCount(), 3);
        assertEq(tradeRouter.soldAmounts(0), 10_000e6);
        assertEq(tradeRouter.soldAmounts(1), 10_000e6 + 1);
        assertEq(tradeRouter.soldAmounts(2), 10_000e6);
        assertEq(aNew.allowance(alice, address(leverager)), 0);
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Catches conditioning external-lender repayment on position-pool mode-2 flash availability.
    function test_decreaseWorksWhenPositionPoolFlashDisabled() public {
        _create(alice, 100_000e6, 80_000e6);
        _flashEnabled(false);
        assertEq(leverager.leverageCapacity(), 0);
        ILeverager.PositionResult memory result = _decrease(alice, 180_000e6, type(uint256).max, 1);
        assertEq(result.debtAfter, 0);
        assertEq(result.cashRepaid, 80_000e6);
        assertEq(result.surplus, 100_000e6);
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Catches spending another borrowers collateral or gateway donations in a multi-round decrease.
    function test_decreasePreservesOtherUserAndAllGatewayDonations() public {
        _create(alice, 100_000e6, 80_000e6);
        _create(bob, 70_000e6, 20_000e6);
        uint256 bobShares = _debtShares(bob);
        ptNew.mint(address(leverager), 13);
        ausd.mint(address(leverager), 17);
        syNew.mint(address(leverager), 19);
        address donor = makeAddr("leverager donor");
        _supply(address(ptNew), donor, 23);
        vm.prank(donor);
        aNew.transfer(address(leverager), 23);
        _setMorphoCash(30_000e6);
        ILeverager.PositionResult memory result = _decrease(alice, 180_000e6, type(uint256).max, 3);
        assertEq(result.cashRepaid, 80_000e6);
        assertEq(result.surplus, 100_000e6);
        assertEq(aNew.balanceOf(bob), 90_000e6);
        assertEq(_debtShares(bob), bobShares);
        assertEq(ptNew.balanceOf(bob), 0);
        assertEq(ausd.balanceOf(bob), 0);
        _assertCustody(17, 13, 19, 23);
    }

    /// @dev Catches intermediate flash rounds borrowing against a donation to hide a sale shortfall.
    function test_underfundedSaleCannotSpendDonation() public {
        _create(alice, 100_000e6, 80_000e6);
        ausd.mint(address(leverager), 100_000e6);
        tradeRouter.setSalePrice(0.9e18);
        _approveCollateral(alice, 80_000e6);
        uint256 lenderCash = ausd.balanceOf(address(morpho));
        // Selling 80,000e6 PT at 0.9 returns 72,000e6, short of the 80,000e6 flash principal; donations do not count.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.InsufficientRepaymentProceeds.selector, 80_000e6, 72_000e6));
        leverager.decreaseLeverage(_decreaseParams(80_000e6, 80_000e6, 1));
        assertEq(aNew.balanceOf(alice), 180_000e6);
        assertEq(vDebt.balanceOf(alice), 80_000e6);
        assertEq(ausd.balanceOf(address(morpho)), lenderCash);
        assertEq(aNew.allowance(alice, address(leverager)), 80_000e6);
        _assertCustody(100_000e6, 0, 0, 0);
    }

    /// @dev Catches ignoring the caller aPT allowance when resolving max PT.
    function test_maxPtHonorsFiniteAllowance() public {
        _create(alice, 100_000e6, 80_000e6);
        _approveCollateral(alice, 30_000e6);
        vm.prank(alice);
        ILeverager.PositionResult memory result =
            leverager.decreaseLeverage(_decreaseParams(type(uint256).max, 25_000e6, 1));
        assertEq(result.ptWithdrawn, 30_000e6);
        assertEq(aNew.balanceOf(alice), 150_000e6);
        assertEq(result.cashRepaid, 25_000e6);
        assertEq(result.surplus, 5_000e6);
        assertEq(aNew.allowance(alice, address(leverager)), 0);
    }

    /// @dev Catches previews retaining delayed pool debt mint or consumed finite delegation.
    function test_previewIncreaseRollsBackRealDelayedDebtAndDelegation() public {
        _create(alice, 100_000e6, 80_000e6);
        _approveDebt(alice, 10_000e6);
        uint256 shares = _debtShares(alice);
        vm.prank(alice);
        ILeverager.PositionResult memory preview = leverager.previewIncreaseLeverage(_increaseParams(10_000e6));
        assertEq(_debtShares(alice), shares);
        assertEq(aNew.balanceOf(alice), 180_000e6);
        assertEq(ICreditDelegationToken(address(vDebt)).borrowAllowance(alice, address(leverager)), 10_000e6);
        vm.prank(alice);
        ILeverager.PositionResult memory result = leverager.increaseLeverage(_increaseParams(10_000e6));
        assertEq(keccak256(abi.encode(preview)), keccak256(abi.encode(result)));
        assertEq(vDebt.balanceOf(alice), 90_000e6);
        assertEq(ICreditDelegationToken(address(vDebt)).borrowAllowance(alice, address(leverager)), 0);
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Catches non-unit-index dust: partial burns lose cash/debt precision, final live-debt repayment must clear shares.
    function testFuzz_maxRepaymentClearsTinyNonUnitDebt(uint256 rawDebt, uint256 rawCash) public {
        uint256 borrowing = _bound(rawDebt, 17, 257);
        uint256 cash = _bound(rawCash, 2, 31);
        _create(alice, 1_000_000, borrowing);
        // Independent untouched collateral isolates debt rounding from pool transfer health constraints.
        _supply(address(ptOld), alice, 1e6);
        vm.warp(block.timestamp + 365 days);
        _setMorphoCash(cash);
        uint256 beforeDebt = vDebt.balanceOf(alice);
        uint256 collateral = 1_000_000 + borrowing;
        ILeverager.PositionResult memory result = _decrease(alice, collateral, type(uint256).max, 512);
        assertGt(beforeDebt, borrowing);
        assertEq(_debtShares(alice), 0);
        assertEq(result.debtAfter, 0);
        assertEq(result.ptWithdrawn, collateral);
        assertEq(result.cashRepaid + result.surplus, collateral);
        assertEq(ausd.balanceOf(address(morpho)), cash);
        assertLe(result.rounds, 512);
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Catches counting direct settlement as an external flash round at an accrued debt index.
    function test_nonUnitDebtSettlesDirectlyWithinTheFlashLimit() public {
        _create(alice, 102, 17);
        vm.warp(block.timestamp + 365 days);
        _setMorphoCash(2);
        uint256 debt = vDebt.balanceOf(alice);
        ILeverager.PositionResult memory result = _decrease(alice, 119, type(uint256).max, (debt + 1) / 2);
        assertEq(result.debtAfter, 0);
        assertEq(_debtShares(alice), 0);
        assertEq(aNew.balanceOf(alice), 0);
        assertEq(result.cashRepaid + result.surplus, 119);
        assertEq(result.rounds, morpho.flashLoanCount());
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Catches mistaking mode-2 liquidity capacity for permission to exceed the lending-core borrow cap.
    function test_mode2BorrowCapFailureRollsBackPrincipalAndDelegation() public {
        DataTypes.ReserveConfigurationMap memory config = pool.getConfiguration(address(ausd));
        config.setBorrowCap(10_000);
        vm.prank(address(configurator));
        pool.setConfiguration(address(ausd), config);
        ptNew.mint(alice, 100_000e6);
        vm.prank(alice);
        ptNew.approve(address(leverager), 100_000e6);
        _approveDebt(alice, 20_000e6);
        vm.prank(alice);
        vm.expectRevert(bytes("50"));
        leverager.createPosition(_createParams(100_000e6, 20_000e6));
        assertEq(ptNew.balanceOf(alice), 100_000e6);
        assertEq(aNew.balanceOf(alice), 0);
        assertEq(vDebt.balanceOf(alice), 0);
        assertEq(ICreditDelegationToken(address(vDebt)).borrowAllowance(alice, address(leverager)), 20_000e6);
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Catches bypassing fee-free external-pool routing or leaving its repayment allowance live.
    function test_decreaseUsesAuthorizedGlobalPoolWhenItHasMoreCash() public {
        _create(alice, 100_000e6, 80_000e6);
        _setMorphoCash(20_000e6);
        flashPool.seed(supplier, 40_000e6);
        flashPool.ACL().setFlashBorrower(address(leverager), true);
        ILeverager.PositionResult memory result = _decrease(alice, 180_000e6, type(uint256).max, 2);
        assertEq(result.flashSource, address(flashPool));
        assertEq(result.rounds, 1);
        assertEq(flashPool.flashLoanCount(), 1);
        assertEq(result.debtAfter, 0);
        assertEq(result.cashRepaid, 80_000e6);
        assertEq(result.surplus, 100_000e6);
        assertEq(ausd.balanceOf(address(flashPool.A_TOKEN())), 40_000e6);
        assertEq(ausd.balanceOf(address(morpho)), 20_000e6);
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Catches missing direct settlement when tiny indexed burns would otherwise exhaust collateral.
    function test_tinyIndexedFullClosePreservesHealthAndSettlesDebt() public {
        _create(alice, 120, 20);
        vm.warp(block.timestamp + 365 days);
        _setMorphoCash(2);
        ILeverager.PositionResult memory result = _decrease(alice, 140, type(uint256).max, 512);
        assertEq(result.debtAfter, 0);
        assertEq(_debtShares(alice), 0);
        assertEq(aNew.balanceOf(alice), 0);
        assertEq(result.cashRepaid + result.surplus, 140);
        assertEq(result.rounds, morpho.flashLoanCount());
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Catches losing independent caller collateral when accumulated proceeds settle a tiny indexed close.
    function test_tinyIndexedClosePreservesOtherCollateral() public {
        _create(alice, 120, 20);
        _supply(address(ptOld), alice, 1e6);
        vm.warp(block.timestamp + 365 days);
        _setMorphoCash(2);
        ILeverager.PositionResult memory result = _decrease(alice, 140, type(uint256).max, 512);
        assertEq(result.debtAfter, 0);
        assertEq(_debtShares(alice), 0);
        assertEq(aNew.balanceOf(alice), 0);
        assertEq(aOld.balanceOf(alice), 1e6);
        assertEq(result.cashRepaid + result.surplus, 140);
        _assertCustody(0, 0, 0, 0);
    }

    function test_decreaseCannotLowerHealthyEntryHealthFactor() public {
        _create(alice, 100e6, 100e6);
        _approveCollateral(alice, 100e6);
        bytes32 beforeState = _stateDigest(alice);
        // The resulting 100 PT / 70 AUSD would remain solvent, but its health is below entry health.
        vm.prank(alice);
        vm.expectPartialRevert(ILeverager.HealthFactorBelowMinimum.selector);
        leverager.decreaseLeverage(_decreaseParams(100e6, 30e6, 1));
        assertEq(_stateDigest(alice), beforeState);
    }

    function test_debtFreeDecreaseRejectsAndPreviewBubblesIdenticalError() public {
        _create(alice, 100e6, 0);
        _approveCollateral(alice, 100e6);
        bytes32 beforeState = _stateDigest(alice);
        vm.prank(alice);
        vm.expectRevert(ILeverager.InvalidAmount.selector);
        leverager.previewDecreaseLeverage(_decreaseParams(100e6, type(uint256).max, 1));
        vm.prank(alice);
        vm.expectRevert(ILeverager.InvalidAmount.selector);
        leverager.decreaseLeverage(_decreaseParams(100e6, type(uint256).max, 1));
        assertEq(_stateDigest(alice), beforeState);
    }

    function test_supplyCapFrozenBorrowDisabledAndZeroLtvRejectAtomically() public {
        _create(alice, 100e6, 0);
        _approveDebt(alice, 50e6);
        for (uint256 restriction; restriction < 4; ++restriction) {
            uint256 snapshot = vm.snapshotState();
            if (restriction < 2) {
                DataTypes.ReserveConfigurationMap memory config = pool.getConfiguration(address(ptNew));
                if (restriction == 0) config.setSupplyCap(101);
                else config.setFrozen(true);
                vm.prank(address(configurator));
                pool.setConfiguration(address(ptNew), config);
            } else if (restriction == 2) {
                configurator.setReserveBorrowing(address(ausd), false);
            } else {
                configurator.configureReserveAsCollateral(address(ptNew), 0, 9600, 10150);
            }
            bytes32 beforeState = _stateDigest(alice);
            vm.prank(alice);
            (bool success, bytes memory reason) =
                address(leverager).call(abi.encodeCall(leverager.increaseLeverage, (_increaseParams(50e6))));
            assertFalse(success);
            assertGt(reason.length, 0);
            assertEq(_stateDigest(alice), beforeState);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_positionLiquidityCapacityIsCappedBySupplyNotDonatedCash() public {
        address debtAToken = pool.getReserveData(address(ausd)).aTokenAddress;
        uint256 capacity = leverager.leverageCapacity();
        ausd.mint(debtAToken, 1_000e6);
        assertEq(leverager.leverageCapacity(), capacity);
        _flashEnabled(false);
        assertEq(leverager.leverageCapacity(), 0);
    }

    function test_fullClosePreservesNonTargetCollateral() public {
        _create(alice, 100e6, 100e6);
        _supply(address(ptOld), alice, 500e6);
        uint256 beforeOther = aOld.balanceOf(alice);
        _decrease(alice, 200e6, type(uint256).max, 1);
        assertEq(aOld.balanceOf(alice), beforeOther);
        assertEq(aNew.balanceOf(alice), 0);
        assertEq(vDebt.balanceOf(alice), 0);
        assertEq(ausd.balanceOf(alice), 100e6);
    }

    // Pins every word of a max-repayment close event; the event word values are pairwise distinct, so a transposed
    // or substituted argument fails.
    function test_maxRepaymentCloseEmitsLeverageDecreasedWithZeroSettledDebt() public {
        _distinctEventFixture();
        _setMorphoCash(30_000e6);
        uint256 collateral = aNew.balanceOf(alice);
        uint256 debt = vDebt.balanceOf(alice);
        _approveCollateral(alice, type(uint256).max);
        ILeverager.DecreaseParams memory params = _decreaseParams(type(uint256).max, type(uint256).max, 5);
        vm.prank(alice);
        ILeverager.PositionResult memory preview = leverager.previewDecreaseLeverage(params);
        assertEq(preview.ptWithdrawn, collateral);
        assertEq(preview.debtAfter, 0);
        assertEq(preview.rounds, 2);
        // Partial burns at the accrued index never retire more debt than the cash they spend.
        assertGe(preview.cashRepaid, debt);
        assertLe(preview.cashRepaid, debt + preview.rounds * 2);
        _assertDistinctWords([collateral, preview.cashRepaid, 0, preview.surplus, 2]);
        vm.expectEmit(true, false, false, true, address(leverager));
        emit ILeverager.LeverageDecreased(alice, collateral, preview.cashRepaid, 0, preview.surplus, 2);
        vm.prank(alice);
        ILeverager.PositionResult memory result = leverager.decreaseLeverage(params);
        assertEq(keccak256(abi.encode(result)), keccak256(abi.encode(preview)));
        assertEq(result.debtBefore, debt);
        assertEq(result.surplus, _soldProceeds(0.985e18) - result.cashRepaid);
        assertEq(ausd.balanceOf(alice), result.surplus);
        assertEq(aNew.balanceOf(alice), 0);
        assertEq(_debtShares(alice), 0);
        _assertCustody(0, 0, 0, 0);
    }

    // Pins a three-round partial decrease whose max PT resolves to the finite allowance; the remaining debt, cash
    // budget and surplus all differ.
    function test_multiRoundPartialDecreaseEmitsLeverageDecreasedWithRemainingDebt() public {
        _distinctEventFixture();
        _setMorphoCash(9_000e6);
        uint256 debt = vDebt.balanceOf(alice);
        _approveCollateral(alice, 30_000e6 + 1);
        ILeverager.DecreaseParams memory params = _decreaseParams(type(uint256).max, 25_000e6 + 1, 4);
        vm.prank(alice);
        ILeverager.PositionResult memory preview = leverager.previewDecreaseLeverage(params);
        assertEq(preview.ptWithdrawn, 30_000e6 + 1);
        assertEq(preview.cashRepaid, 25_000e6 + 1);
        assertEq(preview.rounds, 3);
        assertGe(preview.debtAfter, debt - (25_000e6 + 1));
        assertLe(preview.debtAfter, debt - (25_000e6 + 1) + preview.rounds * 2);
        _assertDistinctWords([uint256(30_000e6 + 1), 25_000e6 + 1, preview.debtAfter, preview.surplus, 3]);
        vm.expectEmit(true, false, false, true, address(leverager));
        emit ILeverager.LeverageDecreased(alice, 30_000e6 + 1, 25_000e6 + 1, preview.debtAfter, preview.surplus, 3);
        vm.prank(alice);
        ILeverager.PositionResult memory result = leverager.decreaseLeverage(params);
        assertEq(keccak256(abi.encode(result)), keccak256(abi.encode(preview)));
        assertEq(result.debtAfter, vDebt.balanceOf(alice));
        assertEq(result.surplus, _soldProceeds(0.985e18) - (25_000e6 + 1));
        assertEq(ausd.balanceOf(alice), result.surplus);
        assertEq(aNew.allowance(alice, address(leverager)), 0);
        _assertCustody(0, 0, 0, 0);
    }

    // A discounted purchase, 123 days of interest and a non-unit sale price separate every event word.
    function _distinctEventFixture() internal {
        tradeRouter.setPriceWad(0.97e18);
        _create(alice, 100_000e6, 80_000e6);
        vm.warp(block.timestamp + 123 days);
        tradeRouter.setSalePrice(0.985e18);
        assertGt(pool.getReserveNormalizedVariableDebt(address(ausd)), 1e27);
    }

    function _assertDistinctWords(uint256[5] memory words) internal pure {
        for (uint256 i; i < words.length; ++i) {
            for (uint256 j = i + 1; j < words.length; ++j) {
                assertTrue(words[i] != words[j], "event words must be pairwise distinct");
            }
        }
    }

    function _soldProceeds(uint256 price) internal view returns (uint256 proceeds) {
        for (uint256 i; i < tradeRouter.saleCount(); ++i) {
            proceeds += tradeRouter.soldAmounts(i) * price / 1e18;
        }
    }
}
