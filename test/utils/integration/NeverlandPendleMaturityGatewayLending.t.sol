// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {
    ReserveConfiguration
} from "@neverland-money/lending-core/contracts/protocol/libraries/configuration/ReserveConfiguration.sol";
import {DataTypes} from "@neverland-money/lending-core/contracts/protocol/libraries/types/DataTypes.sol";
import {stdError} from "forge-std/StdError.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {INeverlandPendleMaturityGateway} from "../../../src/interfaces/INeverlandPendleMaturityGateway.sol";

import {GatewayLendingCoreBase} from "./GatewayLendingCoreBase.sol";

/**
 * @title NeverlandPendleMaturityGatewayLendingTest
 * @author Neverland
 * @notice Regression coverage against real lending-core balances, approvals, debt rounding and health checks
 */
contract NeverlandPendleMaturityGatewayLendingTest is GatewayLendingCoreBase {
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    /// @notice Max settlement preserves exact approval and permit intent despite a later aToken donation
    function testFuzz_maxAmountIgnoresUnapprovedDonation(bool migrate, bool withPermit) public {
        uint256 key = 0xB0B;
        address user = vm.addr(key);
        address donor = makeAddr("donor");
        _setMorphoCash(5_000_000e6);
        _open(user, 100_000e6, 90_000e6);
        _open(donor, 1e6, 0);
        _mature();
        vm.warp(block.timestamp + 1 days);
        uint256 balance = aOld.balanceOf(user);
        INeverlandPendleMaturityGateway.PermitParams memory permit = _permit(key, balance);
        if (!withPermit) {
            vm.prank(user);
            aOld.approve(address(gateway), balance);
        }
        vm.prank(donor);
        aOld.transfer(user, 1);

        vm.startPrank(user);
        if (migrate) {
            INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(type(uint256).max, 0, 4);
            INeverlandPendleMaturityGateway.MigrateResult memory result =
                withPermit ? gateway.migrateWithPermit(params, permit) : gateway.migrate(params);

            assertEq(result.ptAmount, balance);
            assertGt(result.ptOut, 0);
        } else {
            INeverlandPendleMaturityGateway.CloseParams memory params = _closeParams(type(uint256).max, user, 4);
            INeverlandPendleMaturityGateway.CloseResult memory result =
                withPermit ? gateway.closeWithPermit(params, permit) : gateway.close(params);

            assertEq(result.ptAmount, balance);
            assertEq(result.debtAfter, 0);
        }
        vm.stopPrank();

        assertEq(aOld.balanceOf(user), 1);
        assertEq(aOld.allowance(user, address(gateway)), 0);
    }

    /// @notice A cash-sized first round restores health where evenly split rounds previously failed
    function test_close_fullCashFirstRoundRestoresHealth() public {
        address user = makeAddr("user");
        _open(user, 1_000_000e6, 915_000e6);
        _mature();
        vm.warp(block.timestamp + 150 days);
        assertLt(_hf(user), 1e18);
        assertGt(aOld.balanceOf(user), vDebt.balanceOf(user));
        _setMorphoCash(300_000e6);
        vm.prank(user);
        aOld.approve(address(gateway), type(uint256).max);

        vm.prank(user);
        INeverlandPendleMaturityGateway.CloseResult memory result =
            gateway.close(_closeParams(type(uint256).max, user, 4));

        assertEq(result.debtAfter, 0);
        assertEq(result.rounds, 4);
        assertEq(aOld.balanceOf(user), 0);
        assertGt(result.surplus, 0);
    }

    /// @notice Partial migrations with max repayment consume at most their approved source value
    function test_migrate_maxRepaymentWithLargerDebt() public {
        address user = makeAddr("user");
        _open(user, 100_000e6, 90_000e6);
        _mature();
        vm.warp(block.timestamp + 1 days);
        _setMorphoCash(100_000e6);
        vm.prank(user);
        aOld.approve(address(gateway), 10_000e6);

        vm.prank(user);
        INeverlandPendleMaturityGateway.MigrateResult memory result =
            gateway.migrate(_migrateParams(10_000e6, type(uint256).max, 1));

        assertEq(result.spent, 0);
        assertApproxEqAbs(result.repay, 10_000e6, 1);
        assertEq(aOld.balanceOf(user), 90_000e6);
    }

    /// @notice Preview and execution preserve the real pool's zero-LTV collateral restriction
    function test_close_enabledZeroLtvCollateralReturnsError57() public {
        address user = makeAddr("user");
        _setMorphoCash(100_000e6);
        _open(user, 100_000e6, 80_000e6);
        _supply(address(ptNew), user, 1e6);
        configurator.configureReserveAsCollateral(address(ptNew), 0, 9600, 10150);
        _mature();
        vm.prank(user);
        aOld.approve(address(gateway), 1_000e6);
        INeverlandPendleMaturityGateway.CloseParams memory params = _closeParams(1_000e6, user, 1);

        vm.startPrank(user);
        vm.expectRevert(bytes("57"));
        gateway.previewClose(params);
        vm.expectRevert(bytes("57"));
        gateway.close(params);
        vm.stopPrank();

        assertEq(aOld.balanceOf(user), 100_000e6);
        assertEq(vDebt.balanceOf(user), 80_000e6);
        assertEq(aOld.allowance(user, address(gateway)), 1_000e6);
        assertEq(ausd.balanceOf(address(morpho)), 100_000e6);
        assertEq(ausd.balanceOf(address(gateway)), 0);
    }

    /// @notice A target supply cap fails identically in preview and execution and rolls back the purchase
    function test_migrate_targetSupplyCapReturnsError51() public {
        address user = makeAddr("user");
        _setMorphoCash(100_000e6);
        _open(user, 100_000e6, 80_000e6);
        _mature();
        DataTypes.ReserveConfigurationMap memory config = pool.getConfiguration(address(ptNew));
        config.setSupplyCap(1);
        vm.prank(address(configurator));
        pool.setConfiguration(address(ptNew), config);
        vm.prank(user);
        aOld.approve(address(gateway), type(uint256).max);
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(1_000e6, 0, 1);

        vm.startPrank(user);
        vm.expectRevert(bytes("51"));
        gateway.previewMigrate(params);
        vm.expectRevert(bytes("51"));
        gateway.migrate(params);
        vm.stopPrank();

        assertEq(aOld.balanceOf(user), 100_000e6);
        assertEq(aNew.balanceOf(user), 0);
        assertEq(vDebt.balanceOf(user), 80_000e6);
        assertEq(ausd.balanceOf(address(morpho)), 100_000e6);
        assertEq(ausd.balanceOf(address(gateway)), 0);
        assertEq(ausd.allowance(address(gateway), address(router)), 0);
        assertEq(ptNew.allowance(address(gateway), address(pool)), 0);
    }

    /// @notice Explicit amounts preserve real aToken allowance and balance errors in both entrypoints
    function test_close_realTokenErrorsMatchPreview() public {
        address user = makeAddr("user");
        _open(user, 100_000e6, 0);
        _mature();
        INeverlandPendleMaturityGateway.CloseParams memory params = _closeParams(100_000e6, user, 0);
        vm.startPrank(user);
        aOld.approve(address(gateway), params.ptAmount - 1);

        vm.expectRevert(bytes("100"));
        gateway.previewClose(params);
        vm.expectRevert(bytes("100"));
        gateway.close(params);

        aOld.approve(address(gateway), type(uint256).max);
        params.ptAmount += 1;

        vm.expectRevert(stdError.arithmeticError);
        gateway.previewClose(params);
        vm.expectRevert(stdError.arithmeticError);
        gateway.close(params);
        vm.stopPrank();

        assertEq(aOld.balanceOf(user), 100_000e6);
        assertEq(aOld.allowance(user, address(gateway)), type(uint256).max);
        assertEq(ausd.balanceOf(address(gateway)), 0);
    }

    /**
     * @notice Signs an exact source-token allowance against the real aToken's permit domain
     * @param key The caller's local fixture key
     * @param value The approved source amount
     * @return permit Signed permit parameters
     */
    function _permit(uint256 key, uint256 value)
        internal
        view
        returns (INeverlandPendleMaturityGateway.PermitParams memory permit)
    {
        address user = vm.addr(key);
        permit.value = value;
        permit.deadline = block.timestamp + 1 hours;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                IERC20Permit(address(aOld)).DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        user,
                        address(gateway),
                        value,
                        IERC20Permit(address(aOld)).nonces(user),
                        permit.deadline
                    )
                )
            )
        );

        (permit.v, permit.r, permit.s) = vm.sign(key, digest);
    }
}
