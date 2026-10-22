// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {ILeverager, PendleLeveragerLendingBase} from "../helpers/PendleLeveragerLendingBase.sol";

/// @notice Decrease action-entry funding, cash cap, direct settlement and failure precedence on the real lending core.
contract NeverlandPendleLeveragerImprovementsTest is PendleLeveragerLendingBase {
    address internal alice = makeAddr("improvements alice");

    // Catches callback funding pinned to round entry instead of action entry.
    function test_sharedFundingDecliningPricesBothLenders() public {
        for (uint256 i; i < 2; ++i) {
            uint256 state = vm.snapshotState();
            _create(alice, 100e6, 100e6);
            _lender(i == 1, 40e6);
            uint256[] memory prices = new uint256[](3);
            prices[0] = 1.25e18;
            prices[1] = 1e18;
            prices[2] = 0.75e18;
            tradeRouter.setSalePrices(prices);
            ausd.mint(address(leverager), 7);
            ILeverager.PositionResult memory result = _decrease(alice, 120e6, type(uint256).max, 3);
            assertEq(result.rounds, 3);
            assertEq(morpho.flashLoanCount() + flashPool.flashLoanCount(), 3);
            assertEq(ausd.balanceOf(i == 0 ? address(morpho) : address(flashPool.A_TOKEN())), 40e6);
            assertEq(result.cashRepaid, 100e6);
            assertEq(result.debtAfter, 0);
            assertEq(result.ptWithdrawn, 120e6);
            assertEq(result.surplus, 20e6);
            assertEq(ausd.balanceOf(alice), 20e6);
            assertEq(aNew.balanceOf(alice), 80e6);
            _assertCustody(7, 0, 0, 0);
            assertTrue(vm.revertToState(state));
        }
    }

    // Catches the obsolete up-front flash count and missing direct settlement.
    function test_directSettlementAfterLastAllowedFlashBothLenders() public {
        for (uint256 i; i < 2; ++i) {
            uint256 state = vm.snapshotState();
            _create(alice, 200e6, 100e6);
            _lender(i == 1, 40e6);
            ILeverager.PositionResult memory result = _decrease(alice, 300e6, type(uint256).max, 1);
            assertEq(result.rounds, 1);
            assertEq(result.cashRepaid, 100e6);
            assertEq(result.debtAfter, 0);
            assertEq(result.ptWithdrawn, 300e6);
            assertEq(result.surplus, 200e6);
            assertEq(ausd.balanceOf(alice), 200e6);
            assertEq(aNew.balanceOf(alice), 0);
            assertEq(tradeRouter.saleCount(), 2, "remaining selected PT converted after direct repayment");
            _assertCustody(0, 0, 0, 0);
            assertTrue(vm.revertToState(state));
        }
    }

    // Catches an ignored cap and silent shrinking of the finite repayment request.
    function test_cashCapBoundaryFullAndFinite() public {
        _create(alice, 100e6, 100e6);
        _setMorphoCash(100e6);
        _approveCollateral(alice, 120e6);
        uint256 state = vm.snapshotState();
        for (uint256 i; i < 2; ++i) {
            ILeverager.DecreaseParams memory params = _decreaseParams(120e6, i == 0 ? 100e6 : type(uint256).max, 1);
            params.maxCashRepaid = 100e6 - 1;
            bytes32 beforeState = _stateDigest(alice);
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(ILeverager.CashRepaymentLimitExceeded.selector, 100e6, 100e6 - 1));
            leverager.decreaseLeverage(params);
            assertEq(_stateDigest(alice), beforeState);
            params.maxCashRepaid = 100e6;
            vm.prank(alice);
            ILeverager.PositionResult memory result = leverager.decreaseLeverage(params);
            assertEq(result.cashRepaid, params.maxCashRepaid);
            assertEq(result.debtAfter, 0);
            assertTrue(vm.revertToState(state));
        }
    }

    function test_zeroCapInvalid() public {
        _create(alice, 100e6, 100e6);
        ILeverager.DecreaseParams memory params = _decreaseParams(120e6, 100e6, 1);
        params.maxCashRepaid = 0;
        vm.prank(alice);
        vm.expectRevert(ILeverager.InvalidAmount.selector);
        leverager.decreaseLeverage(params);
    }

    // Catches conflating cap, PT, round, liquidity and proportional-allocation failures.
    function test_distinctFailurePrecedenceAndArguments() public {
        _create(alice, 100e6, 100e6);
        _approveCollateral(alice, 120e6);
        _setMorphoCash(0);
        ILeverager.DecreaseParams memory params = _decreaseParams(120e6, 100e6, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.RoundLimitExceeded.selector, 100e6, 0));
        leverager.decreaseLeverage(params);
        params.maxRounds = 3;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.InsufficientFlashLiquidity.selector, 100e6, 0));
        leverager.decreaseLeverage(params);
        _setMorphoCash(20e6);
        params.ptAmount = 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.InsufficientPtBudget.selector, 100e6, 1));
        leverager.decreaseLeverage(params);
        params.ptAmount = 100e6;
        params.maxRounds = 5;
        tradeRouter.setSalePrice(0.5e18);
        ausd.mint(address(leverager), 100e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.InsufficientRepaymentProceeds.selector, 20e6, 10e6));
        leverager.decreaseLeverage(params);
        _assertCustody(100e6, 0, 0, 0);
    }

    // Equal cash closes directly; a one-unit shortfall must request a full flash, never a partial cash repayment.
    function test_directCashEqualGreaterAndOneUnitShortFullFiniteBothLenders() public {
        for (uint256 mode; mode < 12; ++mode) {
            uint256 state = vm.snapshotState();
            bool full = mode % 2 == 0;
            bool externalPool = mode % 4 >= 2;
            uint256 funding = mode / 4;
            _create(alice, 200e6, 100e6);
            _lender(externalPool, 40e6);
            uint256 repayment = full ? 100e6 : 60e6;
            uint256 collateral = full ? (funding == 0 ? 299_999_995 : 300e6) : 120e6;
            if (!full && funding == 2) collateral += 2;
            if (full && funding == 2) tradeRouter.setSalePrice(1e18 + 10_000_000_000);
            if (funding == 1) tradeRouter.setSalePrice(1e18 - (full ? 20_000_000_000 : 10_000_000_000));
            _approveCollateral(alice, collateral);
            ILeverager.DecreaseParams memory params =
                _decreaseParams(collateral, full ? type(uint256).max : repayment, 3);
            params.maxCashRepaid = repayment;
            bytes32 beforeState = _stateDigest(alice);
            vm.prank(alice);
            ILeverager.PositionResult memory preview = leverager.previewDecreaseLeverage(params);
            assertEq(_stateDigest(alice), beforeState);
            vm.recordLogs();
            vm.prank(alice);
            ILeverager.PositionResult memory result = leverager.decreaseLeverage(params);
            assertEq(keccak256(abi.encode(preview)), keccak256(abi.encode(result)));
            assertEq(result.cashRepaid, repayment);
            assertEq(result.debtAfter, 100e6 - repayment);
            assertEq(result.ptWithdrawn, collateral);
            assertEq(aNew.balanceOf(alice), 300e6 - collateral);
            assertEq(result.rounds, funding == 1 ? 2 : 1);
            if (funding == 1) _assertSecondFlashPrincipal(full, externalPool);
            assertEq(morpho.flashLoanCount() + flashPool.flashLoanCount(), result.rounds);
            _assertCustody(0, 0, 0, 0);
            assertTrue(vm.revertToState(state));
        }
    }

    // Index rounding can require cash beyond entry debt; a later cap failure must roll back the first flash.
    function test_indexedFullCapRejectsLaterIterationAndHeadroomPasses() public {
        _create(alice, 100_000e6, 80_000e6);
        vm.warp(block.timestamp + 365 days);
        uint256 debt = vDebt.balanceOf(alice);
        _setMorphoCash(debt / 3);
        _approveCollateral(alice, 180_000e6);
        ILeverager.DecreaseParams memory params = _decreaseParams(180_000e6, type(uint256).max, 8);
        params.maxCashRepaid = debt;
        bytes32 beforeState = _stateDigest(alice);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ILeverager.CashRepaymentLimitExceeded.selector, 66_309_722_570, 66_309_722_569)
        );
        leverager.decreaseLeverage(params);
        assertEq(_stateDigest(alice), beforeState);
        params.maxCashRepaid = debt + 8;
        vm.prank(alice);
        ILeverager.PositionResult memory result = leverager.decreaseLeverage(params);
        assertGt(result.cashRepaid, debt);
        assertLe(result.cashRepaid, params.maxCashRepaid);
        assertEq(result.debtAfter, 0);
        assertEq(_debtShares(alice), 0);
        _assertCustody(0, 0, 0, 0);
    }

    // Future profitable sales cannot fund an earlier callback; entry cash never rescues total underfunding.
    function test_prefixAndTotalUnderfundingPreserveAllDonations() public {
        _create(alice, 100e6, 100e6);
        _setMorphoCash(40e6);
        _approveCollateral(alice, 120e6);
        ausd.mint(address(leverager), 1_000e6);
        ptNew.mint(address(leverager), 11);
        syNew.mint(address(leverager), 12);
        address donor = makeAddr("improvements donor");
        _supply(address(ptNew), donor, 13);
        vm.prank(donor);
        aNew.transfer(address(leverager), 13);
        uint256[] memory prices = new uint256[](3);
        prices[0] = 0.75e18;
        prices[1] = 1e18;
        prices[2] = 1.25e18;
        tradeRouter.setSalePrices(prices);
        bytes32 beforeState = _stateDigest(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.InsufficientRepaymentProceeds.selector, 33_333_334, 30e6));
        leverager.decreaseLeverage(_decreaseParams(120e6, type(uint256).max, 3));
        assertEq(_stateDigest(alice), beforeState);
        prices[0] = 1.25e18;
        prices[1] = 1e18;
        prices[2] = 0.2e18;
        tradeRouter.setSalePrices(prices);
        beforeState = _stateDigest(alice);
        vm.prank(alice);
        vm.expectPartialRevert(ILeverager.InsufficientRepaymentProceeds.selector);
        leverager.decreaseLeverage(_decreaseParams(120e6, type(uint256).max, 3));
        assertEq(_stateDigest(alice), beforeState);
        _assertCustody(1_000e6, 11, 12, 13);
    }

    // Each action binds a fresh entry cash floor, even after previews and another caller in the same transaction.
    function test_sequentialCallersPreviewsAndActionsDoNotShareCash() public {
        address bob = makeAddr("improvements bob");
        _create(alice, 200e6, 100e6);
        _create(bob, 200e6, 100e6);
        _setMorphoCash(40e6);
        ausd.mint(address(leverager), 31);
        _approveCollateral(alice, 300e6);
        _approveCollateral(bob, 300e6);
        ILeverager.DecreaseParams memory params = _decreaseParams(300e6, type(uint256).max, 1);
        params.maxCashRepaid = 100e6;
        vm.prank(alice);
        leverager.previewDecreaseLeverage(params);
        vm.prank(alice);
        leverager.decreaseLeverage(params);
        vm.prank(bob);
        ILeverager.PositionResult memory result = leverager.previewDecreaseLeverage(params);
        assertEq(vDebt.balanceOf(bob), 100e6);
        vm.prank(bob);
        ILeverager.PositionResult memory executed = leverager.decreaseLeverage(params);
        assertEq(keccak256(abi.encode(result)), keccak256(abi.encode(executed)));
        assertEq(vDebt.balanceOf(alice), 0);
        assertEq(vDebt.balanceOf(bob), 0);
        assertEq(ausd.balanceOf(alice), 200e6);
        assertEq(ausd.balanceOf(bob), 200e6);
        _assertCustody(31, 0, 0, 0);
    }

    // A stale/reinflated debt read after spending the selected PT must route PT exhaustion before round exhaustion.
    function test_exhaustedPtPrecedesExhaustedRounds() public {
        _create(alice, 100e6, 100e6);
        _supply(address(ptOld), alice, 1_000e6);
        _setMorphoCash(100e6);
        _approveCollateral(alice, 100e6);
        bytes[] memory balances = new bytes[](1);
        balances[0] = abi.encode(uint256(100e6));
        vm.mockCalls(address(vDebt), abi.encodeWithSignature("balanceOf(address)", alice), balances);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.InsufficientPtBudget.selector, 100e6, 0));
        leverager.decreaseLeverage(_decreaseParams(100e6, type(uint256).max, 1));
        vm.clearMockedCalls();
        assertEq(vDebt.balanceOf(alice), 100e6);
        assertEq(aNew.balanceOf(alice), 200e6);
    }

    function testFuzz_boundedFiniteCashCapAtomicBelowBoundary(uint256 rawRepay, uint256 rawDonation) public {
        _create(alice, 1_000_000e6, 500_000e6);
        uint256 repayment = _bound(rawRepay, 100e6, 250_000e6);
        uint256 donation = _bound(rawDonation, 0, 1_000_000e6);
        ausd.mint(address(leverager), donation);
        _approveCollateral(alice, repayment * 12 / 10);
        _setMorphoCash(repayment / 3);
        ILeverager.DecreaseParams memory params = _decreaseParams(repayment * 12 / 10, repayment, 4);
        params.maxCashRepaid = repayment - 1;
        bytes32 beforeState = _stateDigest(alice);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ILeverager.CashRepaymentLimitExceeded.selector, repayment, repayment - 1)
        );
        leverager.decreaseLeverage(params);
        assertEq(_stateDigest(alice), beforeState);
        params.maxCashRepaid = repayment;
        uint256 poolCashBefore = ausd.balanceOf(pool.getReserveData(address(ausd)).aTokenAddress);
        vm.prank(alice);
        ILeverager.PositionResult memory result = leverager.decreaseLeverage(params);
        assertEq(result.cashRepaid, repayment);
        assertEq(result.cashRepaid, ausd.balanceOf(pool.getReserveData(address(ausd)).aTokenAddress) - poolCashBefore);
        assertEq(result.rounds, morpho.flashLoanCount());
        _assertCustody(donation, 0, 0, 0);
    }

    function test_roundLimitAfterActualFlashRollsBackWithFreshTarget() public {
        _create(alice, 100e6, 100e6);
        _setMorphoCash(40e6);
        _approveCollateral(alice, 120e6);
        ILeverager.DecreaseParams memory params = _decreaseParams(120e6, type(uint256).max, 1);
        params.maxCashRepaid = 100e6;
        bytes32 beforeState = _stateDigest(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.RoundLimitExceeded.selector, 66_666_666, 1));
        leverager.decreaseLeverage(params);
        assertEq(_stateDigest(alice), beforeState);
        assertEq(morpho.flashLoanCount(), 0, "failed action rolls back its flash count");
    }

    // Catches direct settlement ahead of the cap check, which pays an indexed remainder past maxCashRepaid.
    function test_capCheckPrecedesAvailableDirectSettlement() public {
        _create(alice, 100_000e6, 80_000e6);
        vm.warp(block.timestamp + 365 days);
        uint256 debt = vDebt.balanceOf(alice);
        _setMorphoCash(debt / 3);
        _approveCollateral(alice, 180_000e6);
        tradeRouter.setSalePrice(2e18);
        // One allowed flash: success needs its sale surplus to settle the indexed remainder directly.
        ILeverager.DecreaseParams memory params = _decreaseParams(180_000e6, type(uint256).max, 1);
        params.maxCashRepaid = debt;
        bytes32 beforeState = _stateDigest(alice);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ILeverager.CashRepaymentLimitExceeded.selector, 66_309_722_570, 66_309_722_569)
        );
        leverager.decreaseLeverage(params);
        assertEq(_stateDigest(alice), beforeState);
        params.maxCashRepaid = debt + 1;
        vm.prank(alice);
        ILeverager.PositionResult memory result = leverager.decreaseLeverage(params);
        assertEq(result.rounds, 1);
        assertEq(result.cashRepaid, debt + 1);
        assertEq(result.debtAfter, 0);
        assertEq(tradeRouter.saleCount(), 2, "remaining selected PT converted after direct repayment");
        _assertCustody(0, 0, 0, 0);
    }

    // Catches a round-limit, liquidity or proportional-PT failure outranking the cash cap.
    function test_capOutranksFlashSideFailures() public {
        _create(alice, 100e6, 100e6);
        _approveCollateral(alice, 120e6);
        _setMorphoCash(0);
        ILeverager.DecreaseParams memory params = _decreaseParams(120e6, 100e6, 0);
        params.maxCashRepaid = 100e6 - 1;
        bytes memory expected = abi.encodeWithSelector(ILeverager.CashRepaymentLimitExceeded.selector, 100e6, 100e6 - 1);
        bytes32 beforeState = _stateDigest(alice);
        vm.prank(alice);
        vm.expectRevert(expected);
        leverager.decreaseLeverage(params);
        assertEq(_stateDigest(alice), beforeState);
        params.maxRounds = 3;
        vm.prank(alice);
        vm.expectRevert(expected);
        leverager.decreaseLeverage(params);
        assertEq(_stateDigest(alice), beforeState);
        _setMorphoCash(20e6);
        params.ptAmount = 1;
        beforeState = _stateDigest(alice);
        vm.prank(alice);
        vm.expectRevert(expected);
        leverager.decreaseLeverage(params);
        assertEq(_stateDigest(alice), beforeState);
    }

    // Catches a strict cash check or a round limit ahead of direct settlement, and a partial payment one unit short.
    function test_equalCashAtTheRoundLimitSettlesDirectly() public {
        _create(alice, 200e6, 100e6);
        _setMorphoCash(40e6);
        _approveCollateral(alice, type(uint256).max);
        uint256 state = vm.snapshotState();
        vm.prank(alice);
        ILeverager.PositionResult memory result =
            leverager.decreaseLeverage(_decreaseParams(299_999_995, type(uint256).max, 1));
        assertEq(result.rounds, 1);
        assertEq(result.debtAfter, 0);
        assertEq(
            tradeRouter.soldAmounts(0), 100e6, "first sale covers its own principal plus the remaining target exactly"
        );
        assertTrue(vm.revertToState(state));
        bytes32 beforeState = _stateDigest(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.RoundLimitExceeded.selector, 66_666_666, 1));
        leverager.decreaseLeverage(_decreaseParams(299_999_994, type(uint256).max, 1));
        assertEq(_stateDigest(alice), beforeState);
    }

    function _assertSecondFlashPrincipal(bool full, bool externalPool) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address lenderCash = externalPool ? address(flashPool.A_TOKEN()) : address(morpho);
        uint256 receipts;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(ausd) || logs[i].topics.length != 3
                    || logs[i].topics[0] != keccak256("Transfer(address,address,uint256)")
                    || logs[i].topics[1] != bytes32(uint256(uint160(lenderCash)))
                    || logs[i].topics[2] != bytes32(uint256(uint160(address(leverager))))
            ) continue;
            if (receipts == 1) {
                assertEq(abi.decode(logs[i].data, (uint256)), full ? 33_333_333 : 30e6, "full second flash principal");
            }
            ++receipts;
        }
        assertEq(receipts, 2, "two measured flash receipts");
    }
}
