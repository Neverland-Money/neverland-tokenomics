// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ILeverager, PendleLeveragerLendingBase} from "../helpers/PendleLeveragerLendingBase.sol";

/**
 * @title NeverlandPendleLeveragerIntegratorTest
 * @notice Quote-derived budgets and stale-preview protections against the real lending core.
 */
contract NeverlandPendleLeveragerIntegratorTest is PendleLeveragerLendingBase {
    address internal alice = makeAddr("integrator alice");

    /// @dev Catches fills changing the explicit repayment or PT budget instead of the wallet surplus.
    function test_quoteBoundsPreserveFiniteBudgetsAcrossFillsAndBothLenders() public {
        uint256[3] memory prices = [uint256(1e18), 0.995e18, 1.01e18];
        uint256[3] memory gross = [uint256(120e6), 119.4e6, 121.2e6];
        for (uint256 lender; lender < 2; ++lender) {
            for (uint256 fill; fill < prices.length; ++fill) {
                uint256 state = vm.snapshotState();
                _open(lender == 1);
                ILeverager.DecreaseParams memory params = _quotedParams();
                bytes32 beforeState = _stateDigest(alice);
                vm.prank(alice);
                ILeverager.PositionResult memory preview = leverager.previewDecreaseLeverage(params);
                assertEq(_stateDigest(alice), beforeState, "preview rolls back the entire action");
                assertEq(preview.cashRepaid + preview.surplus, 120e6, "gross quote at preview time");

                tradeRouter.setSalePrice(prices[fill]);
                vm.prank(alice);
                ILeverager.PositionResult memory actual = leverager.decreaseLeverage(params);
                assertEq(actual.ptWithdrawn, 120e6);
                assertEq(actual.cashRepaid, 80e6);
                assertEq(actual.debtAfter, 20e6);
                assertEq(actual.cashRepaid + actual.surplus, gross[fill]);
                assertEq(ausd.balanceOf(alice), gross[fill] - 80e6);
                assertEq(aNew.balanceOf(alice), 80e6);
                _assertCustody(0, 0, 0, 0);
                assertTrue(vm.revertToState(state));
            }
        }
    }

    /// @dev Catches a gross conversion floor incorrectly being applied only to wallet surplus.
    function test_saleBelowQuoteFloorRevertsAtomically() public {
        _open(false);
        ILeverager.DecreaseParams memory params = _quotedParams();
        tradeRouter.setSalePrice(0.994e18);
        bytes32 beforeState = _stateDigest(alice);
        bytes memory failure = abi.encodeWithSelector(ILeverager.OutputBelowMinimum.selector, 119.28e6, 119.4e6);
        vm.prank(alice);
        vm.expectRevert(failure);
        leverager.previewDecreaseLeverage(params);
        vm.prank(alice);
        vm.expectRevert(failure);
        leverager.decreaseLeverage(params);
        assertEq(_stateDigest(alice), beforeState);
    }

    /// @dev Catches ignoring cash-cap headroom when a better fill funds additional repayment.
    function test_betterExecutionRepaysMoreWithinCashCap() public {
        _open(false);
        ILeverager.DecreaseParams memory params = _quotedParams();
        params.ptAmount = 90e6;
        params.minDebtAssetOut = 89.55e6;
        params.maxCashRepaid = 95e6;
        vm.prank(alice);
        ILeverager.PositionResult memory preview = leverager.previewDecreaseLeverage(params);
        assertEq(preview.cashRepaid, 90e6);
        tradeRouter.setSalePrice(1.01e18);
        vm.prank(alice);
        ILeverager.PositionResult memory actual = leverager.decreaseLeverage(params);
        assertEq(actual.cashRepaid, 90.9e6);
        assertEq(actual.debtAfter, 9.1e6);
        assertEq(actual.surplus, 0);
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Catches stale full-debt caps being ignored or max repayment leaving accrued debt behind.
    function test_fullRepaymentRefreshesAccruedDebtAndRespectsTheQuoteCap() public {
        _open(false);
        ILeverager.DecreaseParams memory params = _quotedParams();
        params.repayAmount = type(uint256).max;
        params.maxCashRepaid = 100e6;
        vm.prank(alice);
        ILeverager.PositionResult memory preview = leverager.previewDecreaseLeverage(params);
        assertEq(preview.debtAfter, 0);
        assertEq(preview.cashRepaid, 100e6);

        vm.warp(block.timestamp + 1 days);
        uint256 currentDebt = vDebt.balanceOf(alice);
        assertGt(currentDebt, preview.cashRepaid);
        bytes32 beforeState = _stateDigest(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.CashRepaymentLimitExceeded.selector, currentDebt, 100e6));
        leverager.decreaseLeverage(params);
        assertEq(_stateDigest(alice), beforeState);

        params.maxCashRepaid = 109.4e6;
        vm.prank(alice);
        ILeverager.PositionResult memory refreshed = leverager.previewDecreaseLeverage(params);
        assertEq(_stateDigest(alice), beforeState);
        vm.prank(alice);
        ILeverager.PositionResult memory actual = leverager.decreaseLeverage(params);
        assertEq(keccak256(abi.encode(actual)), keccak256(abi.encode(refreshed)));
        assertEq(actual.debtAfter, 0);
        assertEq(vDebt.balanceOf(alice), 0);
        assertGt(actual.cashRepaid, preview.cashRepaid);
        assertLe(actual.cashRepaid, params.maxCashRepaid);
        assertEq(actual.cashRepaid + actual.surplus, 120e6);
        assertEq(aNew.balanceOf(alice), 80e6, "zero debt does not mean all collateral was sold");
        _assertCustody(0, 0, 0, 0);
    }

    /// @dev Pins the EVM STATICCALL restriction separately from off-chain eth_call simulation.
    function test_evmStaticcallCannotExecuteTheStatefulPreview() public {
        _open(false);
        ILeverager.DecreaseParams memory params = _quotedParams();
        bytes32 beforeState = _stateDigest(alice);
        vm.prank(alice);
        (bool success, bytes memory data) =
            address(leverager).staticcall{gas: 3_000_000}(abi.encodeCall(leverager.previewDecreaseLeverage, (params)));
        assertFalse(success);
        assertEq(data.length, 0);
        assertEq(_stateDigest(alice), beforeState);
        vm.prank(alice);
        ILeverager.PositionResult memory preview = leverager.previewDecreaseLeverage(params);
        assertEq(preview.cashRepaid, 80e6);
        assertEq(_stateDigest(alice), beforeState);
    }

    /// @dev Opens a fixed collateral/debt fixture with limited cash at either repayment lender.
    function _open(bool externalPool) internal {
        _create(alice, 100e6, 100e6);
        _approveCollateral(alice, 120e6);
        _lender(externalPool, 40e6);
    }

    /// @dev 120 AUSD quoted gross, 50 bps slippage, 80 AUSD repayment with an exact cash cap.
    function _quotedParams() internal view returns (ILeverager.DecreaseParams memory) {
        return ILeverager.DecreaseParams(120e6, 80e6, 80e6, 119.4e6, 0, 4, block.timestamp + 2 days);
    }
}
