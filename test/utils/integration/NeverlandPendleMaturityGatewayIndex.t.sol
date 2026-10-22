// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IScaledBalanceToken} from "@neverland-money/lending-core/contracts/interfaces/IScaledBalanceToken.sol";
import {WadRayMath} from "@neverland-money/lending-core/contracts/protocol/libraries/math/WadRayMath.sol";
import {
    DefaultReserveInterestRateStrategy
} from "@neverland-money/lending-core/contracts/protocol/pool/DefaultReserveInterestRateStrategy.sol";

import {INeverlandPendleMaturityGateway} from "../../../src/interfaces/INeverlandPendleMaturityGateway.sol";

import {GatewayLendingCoreBase} from "./GatewayLendingCoreBase.sol";

/**
 * @title NeverlandPendleMaturityGatewayIndexTest
 * @author Neverland
 * @notice PT reserve-index checks and exact approvals against the real lending core
 */
contract NeverlandPendleMaturityGatewayIndexTest is GatewayLendingCoreBase {
    /*//////////////////////////////////////////////////////////////
                                  TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Registration rejects a PT reserve whose accrued index exceeds par
    function test_setMigrationTarget_revertsOnAccruedIndex() public {
        vm.prank(owner);
        gateway.removeMigrationTarget(address(ptNew));
        _drift(address(ptNew));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.ReserveIndexNotPar.selector, address(ptNew))
        );
        gateway.setMigrationTarget(address(marketNew));
    }

    /// @notice Close rejects source index drift before asking a lender for funds
    function test_close_revertsOnSourceIndexDrift() public {
        address user = _preparePosition();
        _drift(address(ptOld));
        _mature();
        _rejectLenderCalls();

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.ReserveIndexNotPar.selector, address(ptOld))
        );
        gateway.close(_closeParams(100_000e6, user, 4));
    }

    /// @notice Migration rejects source index drift before asking a lender for funds
    function test_migrate_revertsOnSourceIndexDrift() public {
        address user = _preparePosition();
        _drift(address(ptOld));
        _mature();
        _rejectLenderCalls();

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.ReserveIndexNotPar.selector, address(ptOld))
        );
        gateway.migrate(_migrateParams(100_000e6, 0, 4));
    }

    /// @notice Migration rechecks a registered target's index before asking a lender for funds
    function test_migrate_revertsOnTargetIndexDrift() public {
        address user = _preparePosition();
        _drift(address(ptNew));
        _mature();
        _rejectLenderCalls();

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.ReserveIndexNotPar.selector, address(ptNew))
        );
        gateway.migrate(_migrateParams(100_000e6, 0, 4));
    }

    /// @notice At par, three close rounds consume exactly the source approval and repay the observed debt
    function test_close_exactApprovalAcrossThreeRoundsAtPar() public {
        address user = _preparePosition();
        _mature();
        _setMorphoCash(30_000e6);
        uint256 debt = vDebt.balanceOf(user);

        vm.prank(user);
        INeverlandPendleMaturityGateway.CloseResult memory result = gateway.close(_closeParams(100_000e6, user, 3));

        assertEq(result.rounds, 3);
        assertEq(result.debtRepaid, debt);
        assertEq(result.debtAfter, 0);
        assertEq(result.surplus, 100_000e6 - debt);
        assertEq(aOld.allowance(user, address(gateway)), 0);
        assertEq(aOld.balanceOf(user), 0);
        assertEq(aOld.balanceOf(address(gateway)), 0);
        assertEq(aNew.balanceOf(address(gateway)), 0);
    }

    /// @notice At par, four migration rounds consume exactly the source approval and credit exact target PT
    function test_migrate_exactApprovalAcrossFourRoundsAtPar() public {
        address user = _preparePosition();
        _mature();
        _setMorphoCash(30_000e6);
        uint256 debt = vDebt.balanceOf(user);

        vm.prank(user);
        INeverlandPendleMaturityGateway.MigrateResult memory result =
            gateway.migrate(_migrateParams(100_000e6, type(uint256).max, 4));

        assertEq(result.rounds, 4);
        assertEq(result.repay, debt);
        assertEq(result.debtAfter, 0);
        assertEq(result.spent, 100_000e6 - debt);
        assertEq(result.ptOut, (100_000e6 - debt) * 1e18 / router.priceWad());
        assertEq(aNew.balanceOf(user), result.ptOut);
        assertEq(aOld.allowance(user, address(gateway)), 0);
        assertEq(aOld.balanceOf(user), 0);
        assertEq(aOld.balanceOf(address(gateway)), 0);
        assertEq(aNew.balanceOf(address(gateway)), 0);
    }

    /**
     * @notice Multiple rounds preserve donated source and target aToken shares and exact caller proceeds
     * @param migrate Whether to migrate instead of closing
     * @param sourceDonation Donated source aTokens
     * @param targetDonation Donated target aTokens
     */
    function testFuzz_multiroundPreservesDonatedATokens(bool migrate, uint256 sourceDonation, uint256 targetDonation)
        public
    {
        sourceDonation = bound(sourceDonation, 1, 1e6);
        targetDonation = bound(targetDonation, 1, 1e6);
        address user = _preparePosition();
        address donor = makeAddr("donor");
        _supply(address(ptOld), donor, sourceDonation);
        _supply(address(ptNew), donor, targetDonation);
        vm.startPrank(donor);
        aOld.transfer(address(gateway), sourceDonation);
        aNew.transfer(address(gateway), targetDonation);
        vm.stopPrank();
        uint256 sourceShares = IScaledBalanceToken(address(aOld)).scaledBalanceOf(address(gateway));
        uint256 targetShares = IScaledBalanceToken(address(aNew)).scaledBalanceOf(address(gateway));
        _mature();
        _setMorphoCash(30_000e6);
        uint256 debt = vDebt.balanceOf(user);
        uint256 cash = ausd.balanceOf(user);

        vm.prank(user);
        if (migrate) {
            INeverlandPendleMaturityGateway.MigrateResult memory result =
                gateway.migrate(_migrateParams(100_000e6, type(uint256).max, 4));

            assertEq(result.rounds, 4);
            assertEq(result.repay, debt - vDebt.balanceOf(user));
            assertEq(result.debtAfter, 0);
            assertEq(result.spent, 100_000e6 - debt);
            assertEq(result.ptOut, (100_000e6 - debt) * 1e18 / router.priceWad());
            assertEq(aNew.balanceOf(user), result.ptOut);
            assertEq(result.surplus, 0);
            assertEq(ausd.balanceOf(user), cash);
        } else {
            INeverlandPendleMaturityGateway.CloseResult memory result = gateway.close(_closeParams(100_000e6, user, 3));

            assertEq(result.rounds, 3);
            assertEq(result.debtRepaid, debt - vDebt.balanceOf(user));
            assertEq(result.debtAfter, 0);
            assertEq(result.surplus, 100_000e6 - debt);
            assertEq(ausd.balanceOf(user) - cash, result.surplus);
            assertEq(aNew.balanceOf(user), 0);
        }

        assertEq(aOld.allowance(user, address(gateway)), 0);
        assertEq(aOld.balanceOf(user), 0);
        assertEq(IScaledBalanceToken(address(aOld)).scaledBalanceOf(address(gateway)), sourceShares);
        assertEq(IScaledBalanceToken(address(aNew)).scaledBalanceOf(address(gateway)), targetShares);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Opens a position with an exact source approval and funded flash lender
     * @return user Position owner
     */
    function _preparePosition() internal returns (address user) {
        user = makeAddr("user");
        _open(user, 100_000e6, 80_000e6);
        _setMorphoCash(100_000e6);
        vm.prank(user);
        aOld.approve(address(gateway), 100_000e6);
    }

    /**
     * @notice Accrues a real reserve index through PT borrowing, then disables borrowing again
     * @param asset The PT reserve to drift
     */
    function _drift(address asset) internal {
        address borrower = makeAddr("pt borrower");
        address collateral = asset == address(ptOld) ? address(ptNew) : address(ptOld);
        address rate =
            address(new DefaultReserveInterestRateStrategy(provider, 0.8e27, 0.1e27, 0, 0, 0, 0, 0, 0, 0.2e27));
        vm.prank(address(configurator));
        pool.setReserveInterestRateStrategyAddress(asset, rate);
        configurator.setReserveBorrowing(asset, true);
        _supply(asset, supplier, 100_000e6);
        _supply(collateral, borrower, 100_000e6);
        vm.prank(borrower);
        pool.borrow(asset, 10_000e6, 2, 0, borrower);

        assertGt(pool.getReserveData(asset).currentLiquidityRate, 0);

        vm.warp(block.timestamp + 1 days);
        configurator.setReserveBorrowing(asset, false);

        assertEq(pool.getReserveData(asset).liquidityIndex, WadRayMath.RAY);
        assertGt(pool.getReserveNormalizedIncome(asset), WadRayMath.RAY);
    }

    /// @notice Makes a missing or late index check fail at the first lender call
    function _rejectLenderCalls() internal {
        vm.mockCallRevert(
            address(morpho), bytes4(keccak256("flashLoan(address,uint256,bytes)")), bytes("unexpected lender call")
        );
    }
}
