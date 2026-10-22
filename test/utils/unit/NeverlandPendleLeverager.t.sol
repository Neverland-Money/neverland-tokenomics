// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICreditDelegationToken} from "@neverland-money/lending-core/contracts/interfaces/ICreditDelegationToken.sol";
import {IPool} from "@neverland-money/lending-core/contracts/interfaces/IPool.sol";
import {IPriceOracleGetter} from "@neverland-money/lending-core/contracts/interfaces/IPriceOracleGetter.sol";
import {DataTypes} from "@neverland-money/lending-core/contracts/protocol/libraries/types/DataTypes.sol";
import {Ownable} from "@openzeppelin-v5/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin-v5/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin-v5/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {INeverlandPendleLeverager as ILeverager} from "../../../src/interfaces/INeverlandPendleLeverager.sol";
import {NeverlandPendleLeverager} from "../../../src/utils/NeverlandPendleLeverager.sol";
import {PendleLeveragerUnitBase} from "../helpers/PendleLeveragerLendingBase.sol";
import {
    MaliciousPendleMorpho,
    MaliciousPendleFlashPool,
    MaliciousPendlePositionPool,
    DishonestPendlePurchaseRouter,
    PendleLeveragerNestedFlashReceiver
} from "../mocks/PendleLeveragerMocks.sol";
import {MockPendleRouter} from "../mocks/PendleMaturityGatewayMocks.sol";

contract NeverlandPendleLeveragerTest is PendleLeveragerUnitBase {
    // Catches raw PT principal not supplied or mode-2 debt owned by the leverager.
    function test_createSuppliesRawPrincipalAndMintsCallerDebtAfterCallback() public {
        ILeverager.PositionResult memory result = _create(100e6, 100e6);
        assertEq(aNew.balanceOf(user), 200e6);
        assertEq(vDebt.balanceOf(user), 100e6);
        assertEq(vDebt.balanceOf(address(leverager)), 0);
        assertEq(result.principalSupplied, 100e6);
        assertEq(result.ptSupplied, 100e6);
        assertEq(result.cashBorrowed, 100e6);
        assertEq(result.debtBefore, 0);
        assertEq(result.debtAfter, 100e6);
        assertEq(result.flashSource, address(pool));
        assertEq(result.rounds, 1);
        assertEq(ausd.allowance(address(leverager), address(pool)), 0);
        assertEq(ptNew.allowance(address(leverager), address(pool)), 0);
        assertEq(ausd.allowance(address(leverager), address(saleRouter)), 0);
    }

    function test_createWithoutBorrowAndIncrease() public {
        _create(100e6, 0);
        vm.prank(user);
        ILeverager.PositionResult memory result =
            leverager.increaseLeverage(ILeverager.IncreaseParams(100e6, 100e6, 1e18, block.timestamp));
        assertEq(result.ptSupplied, 100e6);
        assertEq(result.debtAfter, 100e6);
        assertEq(aNew.balanceOf(user), 200e6);
    }

    function test_decreaseUsesIndependentPtAndCashBudgets() public {
        _create(100e6, 100e6);
        _setMorphoCash(20e6);
        vm.prank(user);
        ILeverager.PositionResult memory result = leverager.decreaseLeverage(_decrease(30e6, 20e6, 1));
        assertEq(result.ptWithdrawn, 30e6);
        assertEq(result.cashRepaid, 20e6);
        assertEq(result.debtAfter, 80e6);
        assertEq(result.surplus, 10e6);
        assertEq(aNew.balanceOf(user), 170e6);
        assertEq(ausd.balanceOf(user), 10e6);
    }

    function test_fullCloseBalancesChunksAndReturnsSurplus() public {
        _create(100e6, 100e6);
        _setMorphoCash(40e6);
        vm.prank(user);
        ILeverager.PositionResult memory result =
            leverager.decreaseLeverage(_decrease(type(uint256).max, type(uint256).max, 3));
        assertEq(result.debtAfter, 0);
        assertEq(result.cashRepaid, 100e6);
        assertEq(result.ptWithdrawn, 200e6);
        assertEq(result.rounds, 2);
        assertEq(morpho.flashLoanCount(), 2);
        assertEq(result.surplus, 100e6);
        assertEq(aNew.balanceOf(user), 0);
    }

    function test_previewPreservesCallerBalancesAndDebt() public {
        ptNew.mint(user, 100e6);
        vm.prank(user);
        ILeverager.PositionResult memory result =
            leverager.previewCreatePosition(ILeverager.CreateParams(100e6, 100e6, 0, 0, block.timestamp));
        assertEq(result.debtAfter, 100e6);
        assertEq(aNew.balanceOf(user), 0);
        assertEq(vDebt.balanceOf(user), 0);
        assertEq(ptNew.balanceOf(user), 100e6);
        assertEq(ausd.balanceOf(address(leverager)), 0);
        vm.prank(user);
        leverager.createPosition(ILeverager.CreateParams(100e6, 100e6, 0, 0, block.timestamp));
        assertEq(vDebt.balanceOf(user), 100e6);
    }

    function test_donationsRemainAcrossBothDirections() public {
        ptNew.mint(address(leverager), 11);
        syNew.mint(address(leverager), 12);
        ausd.mint(address(leverager), 13);
        _supply(address(ptNew), address(this), 14);
        aNew.transfer(address(leverager), 14);
        _create(100e6, 100e6);
        _setMorphoCash(40e6);
        vm.prank(user);
        leverager.decreaseLeverage(_decrease(200e6, type(uint256).max, 3));
        assertEq(ptNew.balanceOf(address(leverager)), 11);
        assertEq(syNew.balanceOf(address(leverager)), 12);
        assertEq(ausd.balanceOf(address(leverager)), 13);
        assertEq(aNew.balanceOf(address(leverager)), 14);
    }

    function test_underfundedRoundCannotConsumeDonation() public {
        _create(100e6, 100e6);
        ausd.mint(address(leverager), 100e6);
        saleRouter.setSalePriceWad(0.5e18);
        _setMorphoCash(20e6);
        // Selling 20e6 PT at 0.5 yields 10e6, short of the 20e6 flash principal; the donation cannot cover it.
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.InsufficientRepaymentProceeds.selector, 20e6, 10e6));
        leverager.decreaseLeverage(_decrease(20e6, 20e6, 1));
        assertEq(vDebt.balanceOf(user), 100e6);
        assertEq(aNew.balanceOf(user), 200e6);
        assertEq(ausd.balanceOf(address(leverager)), 100e6);
    }

    function test_externalPoolDecreaseAndTiePreference() public {
        _create(100e6, 100e6);
        flashPool.seed(supplier, 30e6);
        flashPool.ACL().setFlashBorrower(address(leverager), true);
        _setMorphoCash(30e6);
        (address lender, uint256 cash) = leverager.flashCapacity();
        assertEq(lender, address(morpho));
        assertEq(cash, 30e6);
        _setMorphoCash(0);
        vm.prank(user);
        ILeverager.PositionResult memory result = leverager.decreaseLeverage(_decrease(30e6, 20e6, 1));
        assertEq(result.flashSource, address(flashPool));
        assertEq(ausd.allowance(address(leverager), address(flashPool)), 0);
    }

    function test_matureDecreaseAndItsPreviewRejectAtomically() public {
        _create(100e6, 100e6);
        ptNew.setExpired(true);
        marketNew.setExpired(true);
        _setMorphoCash(100e6);
        vm.prank(user);
        vm.expectRevert(ILeverager.MarketExpired.selector);
        leverager.previewDecreaseLeverage(_decrease(200e6, type(uint256).max, 1));
        vm.prank(user);
        vm.expectRevert(ILeverager.MarketExpired.selector);
        leverager.decreaseLeverage(_decrease(200e6, type(uint256).max, 1));
        assertEq(aNew.balanceOf(user), 200e6);
        assertEq(vDebt.balanceOf(user), 100e6);
        assertEq(ausd.balanceOf(address(morpho)), 100e6);
    }

    function test_deadlineAndExpiredIncreaseRejectAtomically() public {
        _create(100e6, 0);
        vm.prank(user);
        vm.expectRevert(ILeverager.DeadlineExpired.selector);
        leverager.increaseLeverage(ILeverager.IncreaseParams(10e6, 0, 0, block.timestamp - 1));
        ptNew.setExpired(true);
        vm.prank(user);
        vm.expectRevert(ILeverager.MarketExpired.selector);
        leverager.increaseLeverage(ILeverager.IncreaseParams(10e6, 0, 0, block.timestamp));
    }

    function test_userOutputAndFinalHealthFloors() public {
        _create(100e6, 0);
        // The caller minimum reaches the router, whose unit-price output of 100e6 misses it.
        vm.prank(user);
        vm.expectRevert(bytes("router: min out"));
        leverager.increaseLeverage(ILeverager.IncreaseParams(100e6, 100e6 + 1, 0, block.timestamp));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.HealthFactorBelowMinimum.selector, 1896960000000000000, 2e18));
        leverager.increaseLeverage(ILeverager.IncreaseParams(100e6, 0, 2e18, block.timestamp));
        assertEq(vDebt.balanceOf(user), 0);
    }

    function test_decreaseAggregateOutputAndCashCapDetermineSurplus() public {
        _create(100e6, 100e6);
        _setMorphoCash(20e6);
        ILeverager.DecreaseParams memory params = _decrease(30e6, 20e6, 1);
        params.minDebtAssetOut = 30e6;
        vm.prank(user);
        ILeverager.PositionResult memory result = leverager.decreaseLeverage(params);
        assertEq(result.surplus, 10e6);
    }

    function test_missingTamperedAmountAndReplayCallbacksReject() public {
        MaliciousPendleMorpho evil = new MaliciousPendleMorpho();
        NeverlandPendleLeverager other =
            _deploy(pool, address(evil), IPool(address(flashPool)), address(saleRouter), address(marketNew));
        _create(100e6, 100e6);
        ausd.mint(address(evil), 50e6);
        vm.prank(user);
        aNew.approve(address(other), type(uint256).max);
        for (uint256 mode = 1; mode <= 5; mode++) {
            evil.setMode(mode);
            vm.prank(user);
            vm.expectRevert(ILeverager.FlashCallbackUnauthorized.selector);
            other.decreaseLeverage(_decrease(30e6, 20e6, 1));
            assertEq(vDebt.balanceOf(user), 100e6);
        }
    }

    function test_externalPoolRejectsMalformedCallbacksWithoutMutatingPosition() public {
        MaliciousPendleFlashPool evil = new MaliciousPendleFlashPool(address(ausd));
        NeverlandPendleLeverager other =
            _deploy(pool, address(morpho), IPool(address(evil)), address(saleRouter), address(marketNew));
        evil.seed(50e6);
        evil.ACL().setFlashBorrower(address(other), true);
        _create(100e6, 100e6);
        vm.prank(user);
        aNew.approve(address(other), type(uint256).max);
        for (uint256 mode = 1; mode <= 10; mode++) {
            evil.setMode(mode);
            vm.prank(user);
            vm.expectRevert(ILeverager.FlashCallbackUnauthorized.selector);
            other.decreaseLeverage(_decrease(30e6, 20e6, 1));
            assertEq(vDebt.balanceOf(user), 100e6);
            assertEq(aNew.balanceOf(user), 200e6);
            assertEq(ausd.balanceOf(address(evil.A_TOKEN())), 50e6);
        }
    }

    function test_callbacksRequireActiveActionEvenFromPinnedLenders() public {
        address[] memory assets = new address[](1);
        assets[0] = address(ausd);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;
        uint256[] memory premiums = new uint256[](1);
        vm.prank(address(pool));
        vm.expectRevert(ILeverager.FlashCallbackUnauthorized.selector);
        leverager.executeOperation(assets, amounts, premiums, address(leverager), bytes(""));
        vm.prank(address(morpho));
        vm.expectRevert(ILeverager.FlashCallbackUnauthorized.selector);
        leverager.onMorphoFlashLoan(1, bytes(""));
        vm.expectRevert(ILeverager.FlashCallbackUnauthorized.selector);
        leverager.onMorphoFlashLoan(1, bytes(""));
    }

    function test_routerReentryRejectsAndRollsBack() public {
        _create(100e6, 0);
        saleRouter.setHook(
            address(leverager),
            abi.encodeCall(leverager.increaseLeverage, (ILeverager.IncreaseParams(1e6, 0, 0, block.timestamp)))
        );
        saleRouter.setMode(MockPendleRouter.Mode.REENTER_CLOSE);
        vm.prank(user);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        leverager.increaseLeverage(ILeverager.IncreaseParams(10e6, 0, 0, block.timestamp));
        assertEq(vDebt.balanceOf(user), 0);
        assertEq(aNew.balanceOf(user), 100e6);
    }

    function test_falseRouterReturnCannotMeetOutputMinimum() public {
        _create(100e6, 100e6);
        _setMorphoCash(20e6);
        saleRouter.setLieAboutOutput(true);
        ILeverager.DecreaseParams memory params = _decrease(30e6, 20e6, 1);
        params.minDebtAssetOut = 30e6 + 1;
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.OutputBelowMinimum.selector, 30e6, 30e6 + 1));
        leverager.decreaseLeverage(params);
        assertEq(vDebt.balanceOf(user), 100e6);
    }

    function test_ownerRecoveryAndDisabledRenunciation() public {
        ausd.mint(address(leverager), 100);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        leverager.emergencyTokenTransfer(address(ausd), user, 100);
        vm.prank(owner);
        leverager.emergencyTokenTransfer(address(ausd), user, 100);
        assertEq(ausd.balanceOf(user), 100);
        vm.prank(owner);
        vm.expectRevert(ILeverager.OwnershipRequired.selector);
        leverager.renounceOwnership();
        vm.prank(owner);
        leverager.transferOwnership(user);
        vm.prank(user);
        leverager.acceptOwnership();
        assertEq(leverager.owner(), user);
    }

    function test_twoStepOwnershipTransferEmitsStartedThenTransferred() public {
        vm.expectEmit(true, true, false, true, address(leverager));
        emit Ownable2Step.OwnershipTransferStarted(owner, user);
        vm.prank(owner);
        leverager.transferOwnership(user);
        assertEq(leverager.owner(), owner);
        assertEq(leverager.pendingOwner(), user);
        vm.expectEmit(true, true, false, true, address(leverager));
        emit Ownable.OwnershipTransferred(owner, user);
        vm.prank(user);
        leverager.acceptOwnership();
        assertEq(leverager.owner(), user);
        assertEq(leverager.pendingOwner(), address(0));
    }

    function test_fixedParAndMarketIdentityRecheckedAtEntry() public {
        ptNew.mint(user, 100e6);
        syNew.setExchangeRate(1e18 + 1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.UnsupportedSy.selector, address(syNew)));
        leverager.createPosition(ILeverager.CreateParams(100e6, 0, 0, 0, block.timestamp));
        syNew.setExchangeRate(1e18);
        ytNew.setPyIndexStored(1e18 + 1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.UnsupportedSy.selector, address(syNew)));
        leverager.createPosition(ILeverager.CreateParams(100e6, 0, 0, 0, block.timestamp));
        ytNew.setPyIndexStored(1e18);
        ptNew.setSy(address(syOld));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.InvalidMarket.selector, address(marketNew)));
        leverager.createPosition(ILeverager.CreateParams(100e6, 0, 0, 0, block.timestamp));
        assertEq(ptNew.balanceOf(user), 100e6);
    }

    function test_decreasePreviewRollsBackLendersAllowancesAndPosition() public {
        _create(100e6, 100e6);
        _setMorphoCash(20e6);
        vm.prank(user);
        ILeverager.PositionResult memory result = leverager.previewDecreaseLeverage(_decrease(30e6, 20e6, 1));
        assertEq(result.surplus, 10e6);
        assertEq(result.debtAfter, 80e6);
        assertEq(ausd.balanceOf(address(morpho)), 20e6);
        assertEq(ausd.balanceOf(user), 0);
        assertEq(aNew.balanceOf(user), 200e6);
        assertEq(vDebt.balanceOf(user), 100e6);
        assertEq(ausd.allowance(address(leverager), address(morpho)), 0);
        vm.prank(user);
        leverager.decreaseLeverage(_decrease(30e6, 20e6, 1));
        assertEq(vDebt.balanceOf(user), 80e6);
    }

    function test_simulateAcceptsOnlyThreeActions() public {
        vm.expectRevert(ILeverager.InvalidSimulationCall.selector);
        leverager.simulate(bytes(""));
        vm.expectRevert(ILeverager.InvalidSimulationCall.selector);
        leverager.simulate(abi.encodeCall(leverager.leverageCapacity, ()));
    }

    function test_positionPoolRejectsMalformedMissingAndReplayedMode2Callbacks() public {
        MaliciousPendlePositionPool evil = new MaliciousPendlePositionPool(address(pool));
        NeverlandPendleLeverager other = _deploy(
            IPool(address(evil)), address(morpho), IPool(address(flashPool)), address(saleRouter), address(marketNew)
        );
        _create(100e6, 0);
        ausd.mint(address(evil), 50e6);
        for (uint256 mode = 1; mode <= 10; ++mode) {
            evil.setMode(mode);
            vm.prank(user);
            vm.expectRevert(ILeverager.FlashCallbackUnauthorized.selector);
            other.increaseLeverage(ILeverager.IncreaseParams(10e6, 0, 0, block.timestamp));
            assertEq(vDebt.balanceOf(user), 0);
            assertEq(aNew.balanceOf(user), 100e6);
            assertEq(ausd.balanceOf(address(evil)), 50e6);
            assertEq(ausd.balanceOf(address(other)), 0);
            assertEq(saleRouter.swapCount(), 0);
        }
    }

    function test_noBorrowCreateRejectsNonzeroPurchaseMinimumWithoutTakingPrincipal() public {
        ptNew.mint(user, 100e6);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.OutputBelowMinimum.selector, 0, 1));
        leverager.createPosition(ILeverager.CreateParams(100e6, 0, 1, 0, block.timestamp));
        assertEq(ptNew.balanceOf(user), 100e6);
        assertEq(aNew.balanceOf(user), 0);
    }

    function test_globalPoolEligibilityExcludesMissingRoleInactivePausedDisabledAndUnlisted() public {
        _setMorphoCash(0);
        flashPool.seed(supplier, 100e6);
        assertEq(leverager.flashPoolCapacity(), 0);
        flashPool.ACL().setFlashBorrower(address(leverager), true);
        assertEq(leverager.flashPoolCapacity(), 100e6);
        flashPool.setActive(false);
        assertEq(leverager.flashPoolCapacity(), 0);
        flashPool.setActive(true);
        flashPool.setPaused(true);
        assertEq(leverager.flashPoolCapacity(), 0);
        flashPool.setPaused(false);
        flashPool.setFlashEnabled(false);
        assertEq(leverager.flashPoolCapacity(), 0);
        flashPool.setFlashEnabled(true);
        flashPool.setListed(false);
        (address source, uint256 cash) = leverager.flashCapacity();
        assertEq(source, address(0));
        assertEq(cash, 0);
    }

    function test_selectedLenderFailureDoesNotFallBackToSmallerEligiblePool() public {
        MaliciousPendleMorpho evil = new MaliciousPendleMorpho();
        NeverlandPendleLeverager other =
            _deploy(pool, address(evil), IPool(address(flashPool)), address(saleRouter), address(marketNew));
        evil.setMode(1);
        ausd.mint(address(evil), 30e6);
        flashPool.seed(supplier, 20e6);
        flashPool.ACL().setFlashBorrower(address(other), true);
        _create(100e6, 100e6);
        vm.prank(user);
        aNew.approve(address(other), 30e6);
        vm.prank(user);
        vm.expectRevert(ILeverager.FlashCallbackUnauthorized.selector);
        other.decreaseLeverage(_decrease(30e6, 20e6, 1));
        assertEq(flashPool.flashLoanCount(), 0);
        assertEq(ausd.balanceOf(address(evil)), 30e6);
        assertEq(aNew.allowance(user, address(other)), 30e6);
        assertEq(vDebt.balanceOf(user), 100e6);
    }

    function test_purchaseParAndOracleFloorsUseMeasuredOutputAtExactBoundary() public {
        (DishonestPendlePurchaseRouter dishonest, NeverlandPendleLeverager other) = _dishonestPurchaseFixture();
        for (uint256 protection; protection < 2; ++protection) {
            if (protection == 1) ptNewFeed.setAnswer(0.8e8);
            uint256 minimum = protection == 0 ? 99_990_000 : 112_500_000;
            uint256 snapshot = vm.snapshotState();
            dishonest.setOutput(minimum - 1);
            vm.prank(user);
            vm.expectRevert(abi.encodeWithSelector(ILeverager.OutputBelowMinimum.selector, minimum - 1, minimum));
            other.increaseLeverage(ILeverager.IncreaseParams(100e6, 0, 0, block.timestamp));
            assertEq(aNew.balanceOf(user), 100e6);
            assertEq(vDebt.balanceOf(user), 0);
            for (uint256 increment; increment < 2; ++increment) {
                dishonest.setOutput(minimum + increment);
                vm.prank(user);
                assertEq(
                    other.increaseLeverage(ILeverager.IncreaseParams(100e6, 0, 0, block.timestamp)).ptSupplied,
                    minimum + increment
                );
                assertTrue(vm.revertToState(snapshot));
            }
        }
    }

    function test_saleOracleFloorUsesRoundedMeasuredAggregateAtExactBoundary() public {
        _create(100e6, 100e6);
        _setMorphoCash(20e6);
        uint256 minimum = 26_676_000;
        uint256 snapshot = vm.snapshotState();
        for (uint256 offset; offset < 3; ++offset) {
            uint256 proceeds = minimum - 1 + offset;
            saleRouter.setSalePriceWad((proceeds * 1e18 + 30e6 - 1) / 30e6);
            saleRouter.setLieAboutOutput(true);
            if (offset == 0) {
                vm.prank(user);
                vm.expectRevert(abi.encodeWithSelector(ILeverager.OutputBelowMinimum.selector, proceeds, minimum));
                leverager.decreaseLeverage(_decrease(30e6, 20e6, 1));
                assertEq(aNew.balanceOf(user), 200e6);
                assertEq(vDebt.balanceOf(user), 100e6);
            } else {
                vm.prank(user);
                assertEq(leverager.decreaseLeverage(_decrease(30e6, 20e6, 1)).surplus, proceeds - 20e6);
            }
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_nonParPtIndexAndChangedDebtIdentityRejectBeforeAssetMovement() public {
        _create(100e6, 100e6);
        vm.mockCall(
            address(pool),
            abi.encodeWithSelector(IPool.getReserveNormalizedIncome.selector, address(ptNew)),
            abi.encode(uint256(1e27 + 1))
        );
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.ReserveIndexNotPar.selector, address(ptNew)));
        leverager.decreaseLeverage(_decrease(30e6, 20e6, 1));
        vm.clearMockedCalls();
        DataTypes.ReserveData memory reserve = pool.getReserveData(address(ausd));
        reserve.variableDebtTokenAddress = address(aNew);
        vm.mockCall(
            address(pool), abi.encodeWithSelector(IPool.getReserveData.selector, address(ausd)), abi.encode(reserve)
        );
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.InvalidMarket.selector, address(marketNew)));
        leverager.decreaseLeverage(_decrease(30e6, 20e6, 1));
        vm.clearMockedCalls();
        assertEq(aNew.balanceOf(user), 200e6);
        assertEq(vDebt.balanceOf(user), 100e6);
    }

    function test_constructorRejectsEachNoCodeDependencyAndIdenticalPools() public {
        address[6] memory dependencies = [
            address(pool), address(ausd), address(morpho), address(flashPool), address(saleRouter), address(marketNew)
        ];
        address noCode = makeAddr("no dependency code");
        for (uint256 i; i < dependencies.length; ++i) {
            address original = dependencies[i];
            dependencies[i] = noCode;
            vm.expectRevert(abi.encodeWithSelector(ILeverager.InvalidDependency.selector, noCode));
            new NeverlandPendleLeverager(
                IPool(dependencies[0]),
                dependencies[1],
                dependencies[2],
                IPool(dependencies[3]),
                dependencies[4],
                dependencies[5],
                owner
            );
            dependencies[i] = original;
        }
        vm.expectRevert(abi.encodeWithSelector(ILeverager.InvalidDependency.selector, address(pool)));
        _deploy(pool, address(morpho), pool, address(saleRouter), address(marketNew));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new NeverlandPendleLeverager(
            pool,
            address(ausd),
            address(morpho),
            IPool(address(flashPool)),
            address(saleRouter),
            address(marketNew),
            address(0)
        );
    }

    function test_constructorRejectsUnlistedReservesAndAbsentDebtToken() public {
        for (uint256 i; i < 3; ++i) {
            address asset = i == 0 ? address(ptNew) : address(ausd);
            DataTypes.ReserveData memory reserve;
            if (i == 2) {
                reserve = pool.getReserveData(asset);
                reserve.variableDebtTokenAddress = address(0);
            }
            vm.mockCall(
                address(pool), abi.encodeWithSelector(IPool.getReserveData.selector, asset), abi.encode(reserve)
            );
            vm.expectRevert(
                i == 2
                    ? abi.encodeWithSelector(ILeverager.InvalidDependency.selector, address(0))
                    : abi.encodeWithSelector(ILeverager.ReserveNotListed.selector, asset)
            );
            _deploy(pool, address(morpho), IPool(address(flashPool)), address(saleRouter), address(marketNew));
            vm.clearMockedCalls();
        }
    }

    function test_constructorRejectsSameTokenAndMismatchedTokenBindings() public {
        vm.mockCall(
            address(marketNew),
            abi.encodeWithSignature("readTokens()"),
            abi.encode(address(syNew), address(ausd), address(ytNew))
        );
        vm.expectRevert(abi.encodeWithSelector(ILeverager.InvalidMarket.selector, address(marketNew)));
        _deploy(pool, address(morpho), IPool(address(flashPool)), address(saleRouter), address(marketNew));
        vm.clearMockedCalls();
        ptNew.setYt(address(ytOld));
        vm.expectRevert(abi.encodeWithSelector(ILeverager.InvalidMarket.selector, address(marketNew)));
        _deploy(pool, address(morpho), IPool(address(flashPool)), address(saleRouter), address(marketNew));
        ptNew.setYt(address(ytNew));
        marketNew.setExpired(true);
        vm.expectRevert(ILeverager.MarketExpired.selector);
        _deploy(pool, address(morpho), IPool(address(flashPool)), address(saleRouter), address(marketNew));
    }

    function test_unsupportedSyInputsOutputsQuoteAndDecimalsRejectAtEntry() public {
        ptNew.mint(user, 100e6);
        for (uint256 restriction; restriction < 4; ++restriction) {
            uint256 snapshot = vm.snapshotState();
            if (restriction == 0) syNew.setValidTokenIn(address(ausd), false);
            if (restriction == 1) syNew.setValidTokenOut(address(ausd), false);
            if (restriction == 2) syNew.setRateBps(9_999);
            if (restriction == 3) {
                DataTypes.ReserveConfigurationMap memory config = pool.getConfiguration(address(ptNew));
                config.data = (config.data & ~(uint256(0xff) << 48)) | (uint256(18) << 48);
                vm.mockCall(
                    address(pool),
                    abi.encodeWithSelector(IPool.getConfiguration.selector, address(ptNew)),
                    abi.encode(config)
                );
            }
            vm.prank(user);
            vm.expectRevert(abi.encodeWithSelector(ILeverager.UnsupportedSy.selector, address(syNew)));
            leverager.createPosition(ILeverager.CreateParams(100e6, 0, 0, 0, block.timestamp));
            assertEq(ptNew.balanceOf(user), 100e6);
            assertEq(aNew.balanceOf(user), 0);
            vm.clearMockedCalls();
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_zeroOraclePriceRejectsBothAssetsAndStrictAccountReadBubbles() public {
        _create(100e6, 0);
        for (uint256 i; i < 2; ++i) {
            address asset = i == 0 ? address(ptNew) : address(ausd);
            vm.mockCall(
                address(oracle), abi.encodeWithSelector(IPriceOracleGetter.getAssetPrice.selector, asset), abi.encode(0)
            );
            vm.prank(user);
            vm.expectRevert(abi.encodeWithSelector(ILeverager.InvalidOraclePrice.selector, asset));
            leverager.increaseLeverage(ILeverager.IncreaseParams(10e6, 0, 0, block.timestamp));
            assertEq(aNew.balanceOf(user), 100e6);
            assertEq(vDebt.balanceOf(user), 0);
            vm.clearMockedCalls();
        }
        ptNew.mint(user, 1e6);
        vm.mockCallRevert(
            address(pool), abi.encodeWithSelector(IPool.getUserAccountData.selector, user), bytes("account unavailable")
        );
        vm.prank(user);
        vm.expectRevert(bytes("account unavailable"));
        leverager.createPosition(ILeverager.CreateParams(1e6, 0, 0, 0, block.timestamp));
        assertEq(ptNew.balanceOf(user), 1e6);
        assertEq(aNew.balanceOf(user), 100e6);
        vm.clearMockedCalls();
    }

    function test_publicDependencyGettersMatchConstructorAndDerivedBindings() public view {
        assertEq(address(leverager.POOL()), address(pool));
        assertEq(address(leverager.ADDRESSES_PROVIDER()), address(provider));
        assertEq(leverager.DEBT_ASSET(), address(ausd));
        assertEq(leverager.MORPHO(), address(morpho));
        assertEq(address(leverager.FLASH_POOL()), address(flashPool));
        assertEq(leverager.PENDLE_ROUTER(), address(saleRouter));
        assertEq(leverager.MARKET(), address(marketNew));
        assertEq(leverager.PT(), address(ptNew));
        assertEq(leverager.SY(), address(syNew));
        assertEq(leverager.YT(), address(ytNew));
        assertEq(leverager.A_PT(), address(aNew));
        assertEq(leverager.MAX_ORACLE_DEVIATION_BPS(), 1_000);
        assertEq(leverager.owner(), owner);
        assertEq(leverager.pendingOwner(), address(0));
    }

    function test_maxPtWithoutApprovalAndZeroRoundAllocationRejectBeforeFlash() public {
        _create(100e6, 100e6);
        _setMorphoCash(20e6);
        vm.prank(user);
        aNew.approve(address(leverager), 0);
        vm.prank(user);
        vm.expectRevert(ILeverager.InvalidAmount.selector);
        leverager.decreaseLeverage(_decrease(type(uint256).max, 20e6, 1));
        vm.prank(user);
        aNew.approve(address(leverager), 1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.InsufficientPtBudget.selector, 100e6, 1));
        leverager.decreaseLeverage(_decrease(1, 100e6, 5));
        assertEq(aNew.balanceOf(user), 200e6);
        assertEq(vDebt.balanceOf(user), 100e6);
        assertEq(ausd.balanceOf(address(morpho)), 20e6);
        assertEq(aNew.allowance(user, address(leverager)), 1);
    }

    function test_increaseOverCapacityAndZeroRecoveryRecipientRejectBeforeMovement() public {
        _create(100e6, 0);
        uint256 cash = leverager.leverageCapacity();
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.InsufficientFlashLiquidity.selector, cash + 1, cash));
        leverager.increaseLeverage(ILeverager.IncreaseParams(cash + 1, 0, 0, block.timestamp));
        assertEq(aNew.balanceOf(user), 100e6);
        assertEq(vDebt.balanceOf(user), 0);
        ausd.mint(address(leverager), 10);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.InvalidDependency.selector, address(0)));
        leverager.emergencyTokenTransfer(address(ausd), address(0), 10);
        assertEq(ausd.balanceOf(address(leverager)), 10);
    }

    function test_purchaseMustSpendExactCashEvenWhenRouterReportsSuccessfulOutput() public {
        (DishonestPendlePurchaseRouter dishonest, NeverlandPendleLeverager other) = _dishonestPurchaseFixture();
        dishonest.setOutput(100e6);
        dishonest.setUnspent(1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.BalanceMismatch.selector, address(ausd), 0, 1));
        other.increaseLeverage(ILeverager.IncreaseParams(100e6, 0, 0, block.timestamp));
        assertEq(aNew.balanceOf(user), 100e6);
        assertEq(vDebt.balanceOf(user), 0);
        assertEq(ICreditDelegationToken(address(vDebt)).borrowAllowance(user, address(other)), 100e6);
        assertEq(ausd.balanceOf(address(dishonest)), 0);
    }

    function test_receiptDonationDuringRouterCallFailsFinalCustodyAndRollsBack() public {
        _create(100e6, 0);
        _supply(address(ptNew), address(saleRouter), 17);
        saleRouter.setHook(address(aNew), abi.encodeWithSelector(IERC20.transfer.selector, address(leverager), 1));
        saleRouter.setMode(MockPendleRouter.Mode.REENTER_CLOSE);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.BalanceMismatch.selector, address(aNew), 0, 1));
        leverager.increaseLeverage(ILeverager.IncreaseParams(100e6, 0, 0, block.timestamp));
        assertEq(aNew.balanceOf(user), 100e6);
        assertEq(vDebt.balanceOf(user), 0);
        assertEq(aNew.balanceOf(address(saleRouter)), 17);
        assertEq(aNew.balanceOf(address(leverager)), 0);
    }

    function test_mode2PurchasePreservesParIndexAcrossNestedPtFlashPremium() public {
        _create(100e6, 0);
        PendleLeveragerNestedFlashReceiver receiver = _nestedPtFlashFixture();
        saleRouter.setHook(address(receiver), abi.encodeCall(receiver.takeLoan, (address(ptNew), 10e6)));
        saleRouter.setMode(MockPendleRouter.Mode.REENTER_CLOSE);
        vm.prank(user);
        ILeverager.PositionResult memory result =
            leverager.increaseLeverage(ILeverager.IncreaseParams(100e6, 0, 0, block.timestamp));
        assertEq(pool.getReserveNormalizedIncome(address(ptNew)), 1e27);
        assertEq(pool.getReserveData(address(ptNew)).accruedToTreasury, 9_000);
        assertEq(aNew.balanceOf(user), 200e6);
        assertEq(vDebt.balanceOf(user), 100e6);
        assertEq(result.ptSupplied, 100e6);
        assertEq(ptNew.balanceOf(address(receiver)), 1e6 - 9_000);
        assertEq(ptNew.allowance(address(receiver), address(pool)), 0);
    }

    function test_decreasePreservesParIndexAcrossNestedPtFlashPremium() public {
        _create(100e6, 100e6);
        PendleLeveragerNestedFlashReceiver receiver = _nestedPtFlashFixture();
        MaliciousPendleMorpho hookedLender = new MaliciousPendleMorpho();
        NeverlandPendleLeverager other =
            _deploy(pool, address(hookedLender), IPool(address(flashPool)), address(saleRouter), address(marketNew));
        ausd.mint(address(hookedLender), 20e6);
        hookedLender.setHook(address(receiver), abi.encodeCall(receiver.takeLoan, (address(ptNew), 10e6)));
        vm.prank(user);
        aNew.approve(address(other), 30e6);
        vm.prank(user);
        ILeverager.PositionResult memory result = other.decreaseLeverage(_decrease(30e6, 20e6, 1));
        assertEq(pool.getReserveNormalizedIncome(address(ptNew)), 1e27);
        assertEq(pool.getReserveData(address(ptNew)).accruedToTreasury, 9_000);
        assertEq(aNew.balanceOf(user), 170e6);
        assertEq(vDebt.balanceOf(user), 80e6);
        assertEq(result.surplus, 10e6);
        assertEq(ausd.balanceOf(user), 10e6);
        assertEq(aNew.allowance(user, address(other)), 0);
        assertEq(ausd.balanceOf(address(hookedLender)), 20e6);
        assertEq(ptNew.balanceOf(address(receiver)), 1e6 - 9_000);
        assertEq(ptNew.allowance(address(receiver), address(pool)), 0);
    }

    function _nestedPtFlashFixture() internal returns (PendleLeveragerNestedFlashReceiver receiver) {
        DataTypes.ReserveConfigurationMap memory config = pool.getConfiguration(address(ptNew));
        config.data |= 1 << 63;
        vm.startPrank(address(configurator));
        pool.setConfiguration(address(ptNew), config);
        pool.updateFlashloanPremiums(9, 0);
        vm.stopPrank();
        receiver = new PendleLeveragerNestedFlashReceiver(pool);
        ptNew.mint(address(receiver), 1e6);
    }

    // Leverager buying through the dishonest router, after an unleveraged create and a 100e6 debt delegation.
    function _dishonestPurchaseFixture()
        internal
        returns (DishonestPendlePurchaseRouter dishonest, NeverlandPendleLeverager other)
    {
        dishonest = new DishonestPendlePurchaseRouter();
        other = _deploy(pool, address(morpho), IPool(address(flashPool)), address(dishonest), address(marketNew));
        _create(100e6, 0);
        vm.prank(user);
        ICreditDelegationToken(address(vDebt)).approveDelegation(address(other), 100e6);
    }
}
