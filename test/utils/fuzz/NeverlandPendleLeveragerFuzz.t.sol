// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICreditDelegationToken} from "@neverland-money/lending-core/contracts/interfaces/ICreditDelegationToken.sol";

import {ILeverager, PendleLeveragerLendingBase} from "../helpers/PendleLeveragerLendingBase.sol";

/// @notice Price, amount, approval and rounding properties against the real lending core.
contract NeverlandPendleLeveragerFuzzTest is PendleLeveragerLendingBase {
    address internal alice = makeAddr("fuzz leverager alice");

    function testFuzz_createPreviewAndExecutionMatchWithFiniteDelegation(
        uint256 rawPrincipal,
        uint256 rawBorrow,
        uint256 rawPrice,
        uint256 rawElapsed
    ) public {
        uint256 principal = _bound(rawPrincipal, 100e6, 1_000_000e6);
        uint256 borrowing = _bound(rawBorrow, 2, principal * 3);
        uint256 price = _bound(rawPrice, 0.92e18, 1e18);
        tradeRouter.setPriceWad(price);
        // Accrue an independent borrow so the first actor is also tested against a non-unit variable index.
        _open(makeAddr("index borrower"), 10_000e6, 1_000e6);
        vm.warp(block.timestamp + _bound(rawElapsed, 1, 365 days));
        ptNew.mint(alice, principal);
        vm.prank(alice);
        ptNew.approve(address(leverager), principal);
        _approveDebt(alice, borrowing);
        ILeverager.CreateParams memory params = _createParams(principal, borrowing);
        params.minPtOut = borrowing * 1e18 / price;
        bytes32 beforeState = _stateDigest(alice);
        vm.prank(alice);
        ILeverager.PositionResult memory preview = leverager.previewCreatePosition(params);
        assertEq(_stateDigest(alice), beforeState, "preview must roll back all real-core effects");
        vm.prank(alice);
        ILeverager.PositionResult memory result = leverager.createPosition(params);
        assertEq(keccak256(abi.encode(preview)), keccak256(abi.encode(result)));
        assertEq(result.ptSupplied, borrowing * 1e18 / price);
        assertEq(result.principalSupplied, principal);
        assertEq(aNew.balanceOf(alice), principal + result.ptSupplied);
        assertEq(result.cashBorrowed, borrowing);
        assertGe(result.debtAfter, borrowing);
        assertLe(result.debtAfter, borrowing + 2);
        assertEq(ICreditDelegationToken(address(vDebt)).borrowAllowance(alice, address(leverager)), 0);
        assertEq(ptNew.allowance(alice, address(leverager)), 0);
        assertEq(result.healthFactorAfter, _hf(alice));
        _assertCustody(0, 0, 0, 0);
    }

    function testFuzz_partialDecreaseAccountsForPerRoundSaleRounding(
        uint256 rawRepay,
        uint256 rawPrice,
        uint256 rawRounds,
        uint256 rawElapsed,
        bool maxPt
    ) public {
        _create(alice, 1_000_000e6, 500_000e6);
        vm.warp(block.timestamp + _bound(rawElapsed, 1, 180 days));
        uint256 repayment = _bound(rawRepay, 100e6, 250_000e6);
        uint256 collateral = repayment * 12 / 10;
        uint256 price = _bound(rawPrice, 0.9e18, 1.05e18);
        tradeRouter.setSalePrice(price);
        uint256 desiredRounds = _bound(rawRounds, 1, 16);
        uint256 cash = (repayment + desiredRounds - 1) / desiredRounds;
        _setMorphoCash(cash);
        _approveCollateral(alice, collateral);
        ILeverager.DecreaseParams memory params =
            _decreaseParams(maxPt ? type(uint256).max : collateral, repayment, desiredRounds + 2);
        params.maxCashRepaid = repayment;
        bytes32 beforeState = _stateDigest(alice);
        vm.prank(alice);
        ILeverager.PositionResult memory preview = leverager.previewDecreaseLeverage(params);
        assertEq(_stateDigest(alice), beforeState);
        vm.prank(alice);
        ILeverager.PositionResult memory result = leverager.decreaseLeverage(params);
        assertEq(keccak256(abi.encode(preview)), keccak256(abi.encode(result)));
        uint256 proceeds;
        uint256 sold;
        for (uint256 i; i < tradeRouter.saleCount(); ++i) {
            uint256 amount = tradeRouter.soldAmounts(i);
            sold += amount;
            proceeds += amount * price / 1e18;
        }
        assertEq(sold, collateral);
        assertLe(result.cashRepaid, params.maxCashRepaid);
        assertEq(result.cashRepaid, repayment, "finite budget is exact cash spend");
        assertEq(result.ptWithdrawn, collateral);
        assertEq(result.surplus, proceeds - repayment);
        assertEq(ausd.balanceOf(alice), result.surplus);
        assertEq(aNew.balanceOf(alice), 1_500_000e6 - collateral);
        assertApproxEqAbs(result.debtBefore - result.debtAfter, repayment, (result.rounds + 1) * 2);
        assertGe(result.rounds, 1);
        assertLe(result.rounds, desiredRounds);
        assertEq(result.rounds, morpho.flashLoanCount());
        assertLe(collateral * price / 1e18 - proceeds, tradeRouter.saleCount() - 1);
        assertEq(aNew.allowance(alice, address(leverager)), 0);
        assertEq(ausd.balanceOf(address(morpho)), cash);
        _assertCustody(0, 0, 0, 0);
    }

    function testFuzz_fullRepaymentClearsSharesAtVariablePrices(
        uint256 rawPrincipal,
        uint256 rawPrice,
        uint256 rawRounds,
        uint256 rawElapsed,
        bool externalPool
    ) public {
        uint256 principal = _bound(rawPrincipal, 1_000e6, 500_000e6);
        _create(alice, principal, principal);
        vm.warp(block.timestamp + _bound(rawElapsed, 1, 180 days));
        uint256 price = _bound(rawPrice, 0.9e18, 1.03e18);
        tradeRouter.setSalePrice(price);
        uint256 rounds = _bound(rawRounds, 1, 12);
        uint256 debt = vDebt.balanceOf(alice);
        uint256 cash = (debt + rounds - 1) / rounds;
        _lender(externalPool, cash);
        _approveCollateral(alice, principal * 2);
        ILeverager.DecreaseParams memory params = _decreaseParams(principal * 2, type(uint256).max, rounds + 3);
        params.maxCashRepaid = debt + 2 * (rounds + 4);
        vm.prank(alice);
        ILeverager.PositionResult memory result = leverager.decreaseLeverage(params);
        assertLe(result.cashRepaid, params.maxCashRepaid);
        uint256 proceeds;
        for (uint256 i; i < tradeRouter.saleCount(); ++i) {
            proceeds += tradeRouter.soldAmounts(i) * price / 1e18;
        }
        assertEq(result.debtAfter, 0);
        assertEq(_debtShares(alice), 0);
        assertEq(aNew.balanceOf(alice), 0);
        assertEq(result.ptWithdrawn, principal * 2);
        assertEq(result.cashRepaid + result.surplus, proceeds);
        assertEq(ausd.balanceOf(alice), result.surplus);
        assertEq(result.flashSource, externalPool ? address(flashPool) : address(morpho));
        assertEq(ausd.balanceOf(externalPool ? address(flashPool.A_TOKEN()) : address(morpho)), cash);
        assertGe(result.rounds, 1);
        assertEq(result.rounds, morpho.flashLoanCount() + flashPool.flashLoanCount());
        assertLe(result.rounds, rounds + 3);
        _assertCustody(0, 0, 0, 0);
    }

    function testFuzz_underfundedConversionCannotUseDonations(
        uint256 rawRepayment,
        uint256 rawDonation,
        uint256 rawSalePrice
    ) public {
        _create(alice, 1_000_000e6, 500_000e6);
        uint256 repayment = _bound(rawRepayment, 10e6, 100_000e6);
        uint256 donation = _bound(rawDonation, repayment, 5_000_000e6);
        ausd.mint(address(leverager), donation);
        tradeRouter.setSalePrice(_bound(rawSalePrice, 1, 0.899e18));
        _setMorphoCash(repayment);
        _approveCollateral(alice, repayment);
        bytes32 beforeState = _stateDigest(alice);
        vm.prank(alice);
        vm.expectPartialRevert(ILeverager.InsufficientRepaymentProceeds.selector);
        leverager.decreaseLeverage(_decreaseParams(repayment, repayment, 1));
        assertEq(_stateDigest(alice), beforeState);
        _assertCustody(donation, 0, 0, 0);
    }

    function testFuzz_outputAndHealthFailuresRollBackAllEffects(uint256 rawAmount, uint8 rawFailure) public {
        _create(alice, 1_000_000e6, 500_000e6);
        uint256 amount = _bound(rawAmount, 10e6, 100_000e6);
        uint256 failure = rawFailure % 6;
        _approveDebt(alice, amount);
        _approveCollateral(alice, amount * 12 / 10);
        ILeverager.IncreaseParams memory increase = _increaseParams(amount);
        ILeverager.DecreaseParams memory decrease = _decreaseParams(amount * 12 / 10, amount, 1);
        bytes memory callData;
        if (failure == 0) {
            increase.minPtOut = amount + 1;
            callData = abi.encodeCall(leverager.increaseLeverage, (increase));
        } else if (failure == 1) {
            increase.minHealthFactor = type(uint256).max;
            callData = abi.encodeCall(leverager.increaseLeverage, (increase));
        } else {
            if (failure == 2) decrease.minDebtAssetOut = decrease.ptAmount + 1;
            if (failure == 3) decrease.maxCashRepaid = amount - 1;
            if (failure == 4) decrease.minHealthFactor = type(uint256).max;
            if (failure == 5) decrease.maxRounds = 0;
            callData = abi.encodeCall(leverager.decreaseLeverage, (decrease));
        }
        bytes32 beforeState = _stateDigest(alice);
        vm.prank(alice);
        (bool success, bytes memory reason) = address(leverager).call(callData);
        assertFalse(success);
        bytes4 expected = failure == 0
            ? bytes4(keccak256("Error(string)"))
            : failure == 1 || failure == 4
                ? ILeverager.HealthFactorBelowMinimum.selector
                : failure == 3
                    ? ILeverager.CashRepaymentLimitExceeded.selector
                    : failure == 5 ? ILeverager.RoundLimitExceeded.selector : ILeverager.OutputBelowMinimum.selector;
        assertGe(reason.length, 4);
        assertEq(bytes4(reason), expected, "each branch must reach its intended guard");
        if (failure == 0) assertEq(reason, abi.encodeWithSignature("Error(string)", "router: min out"));
        assertEq(_stateDigest(alice), beforeState);
        _assertCustody(0, 0, 0, 0);
    }

    function testFuzz_missingAuthorizationRollsBackPrincipalOrDelayedBorrow(uint256 rawAmount, bool collateral) public {
        uint256 amount = _bound(rawAmount, 100e6, 100_000e6);
        _create(alice, amount * 2, amount);
        if (collateral) {
            _approveCollateral(alice, amount - 1);
        } else {
            _approveDebt(alice, amount - 1);
        }
        bytes32 beforeState = _stateDigest(alice);
        vm.prank(alice);
        (bool success,) = collateral
            ? address(leverager).call(abi.encodeCall(leverager.decreaseLeverage, (_decreaseParams(amount, amount, 1))))
            : address(leverager).call(abi.encodeCall(leverager.increaseLeverage, (_increaseParams(amount))));
        assertFalse(success);
        assertEq(_stateDigest(alice), beforeState);
        _assertCustody(0, 0, 0, 0);
    }

    function testFuzz_finiteOneWeiRemainderRejectsWithoutUnderRepaying(uint256 rawElapsed, uint256 rawCash) public {
        _create(alice, 10_000e6, 1_000e6);
        vm.warp(block.timestamp + _bound(rawElapsed, 1 days, 365 days));
        uint256 cash = _bound(rawCash, 2, 31);
        _setMorphoCash(cash);
        // For budget 2 * cash + 1 the balanced final round is one wei only when cash == 2.
        uint256 budget = cash == 2 ? 5 : 1;
        _approveCollateral(alice, budget * 2);
        bytes32 beforeState = _stateDigest(alice);
        vm.prank(alice);
        vm.expectRevert(bytes("25"));
        leverager.decreaseLeverage(_decreaseParams(budget * 2, budget, 4));
        assertEq(_stateDigest(alice), beforeState);
    }

    function testFuzz_inclusiveDeadlineThenExpiryIsAtomic(uint256 rawAmount, uint256 rawLate) public {
        uint256 amount = _bound(rawAmount, 100e6, 100_000e6);
        _create(alice, amount, 0);
        _approveDebt(alice, amount);
        ILeverager.IncreaseParams memory params = _increaseParams(amount);
        uint256 snapshot = vm.snapshotState();
        vm.prank(alice);
        assertEq(leverager.increaseLeverage(params).cashBorrowed, amount);
        assertTrue(vm.revertToState(snapshot));
        vm.warp(block.timestamp + _bound(rawLate, 1, 30 days));
        bytes32 beforeState = _stateDigest(alice);
        vm.prank(alice);
        vm.expectRevert(ILeverager.DeadlineExpired.selector);
        leverager.increaseLeverage(params);
        assertEq(_stateDigest(alice), beforeState);
    }
}
