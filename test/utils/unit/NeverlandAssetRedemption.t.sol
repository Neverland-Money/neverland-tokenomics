// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin-v5/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin-v5/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin-v5/contracts/utils/Pausable.sol";
import {Test} from "forge-std/Test.sol";

import {INeverlandAssetRedemption} from "../../../src/interfaces/INeverlandAssetRedemption.sol";

import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";

import {NeverlandAssetRedemption} from "../../../src/utils/NeverlandAssetRedemption.sol";

import {MockERC20} from "../../_utils/MockERC20.sol";

/**
 * @title NeverlandAssetRedemptionTest
 * @author Neverland
 * @notice Unit tests for the single-pair asset redemption
 * @dev Pins the floored rate arithmetic against fixtures from the loAZND settlement register, the dust
 *      and liquidity guards, supply and partial withdrawal, pause-state-preserving source recovery,
 *      explicit emergency pause/resume, paused rate updates, partial and maximum-sentinel withdrawals,
 *      and the disabled ownership renouncement.
 */
contract NeverlandAssetRedemptionTest is Test {
    /// @dev Settlement rate: USDC (6-decimal) payable per whole nLOAZND (18-decimal), from the loAZND register.
    uint256 internal constant RATE = 814_576;

    /// @dev The frozen nLOAZND total supply at the settlement snapshot; prices just under the funded liquidity.
    uint256 internal constant SNAPSHOT_SUPPLY = 144_486.103232324638220279e18;

    NeverlandAssetRedemption internal redemption;
    MockERC20 internal nloaznd;
    MockERC20 internal usdc;

    address internal owner = makeAddr("owner");
    address internal holder = makeAddr("holder");

    function setUp() public {
        nloaznd = new MockERC20("Neverland Interest Bearing LOAZND", "nLOAZND", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        redemption = new NeverlandAssetRedemption(IERC20(address(nloaznd)), IERC20(address(usdc)), RATE, owner);

        deal(address(usdc), address(this), 150_000e6);
        usdc.approve(address(redemption), type(uint256).max);
        redemption.supply(150_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Construction emits the initial rate transition from zero
    function test_constructor_emitsInitialExchangeRate() public {
        vm.expectEmit(false, false, false, true);
        emit INeverlandAssetRedemption.ExchangeRateChanged(0, RATE);

        new NeverlandAssetRedemption(IERC20(address(nloaznd)), IERC20(address(usdc)), RATE, owner);
    }

    /// @notice Construction assigns the explicit owner without granting the deployer temporary authority
    function test_constructor_assignsExplicitOwner() public {
        address deployer = makeAddr("deployer");

        vm.prank(deployer);
        NeverlandAssetRedemption target =
            new NeverlandAssetRedemption(IERC20(address(nloaznd)), IERC20(address(usdc)), RATE, owner);

        assertEq(target.owner(), owner);
        assertEq(target.pendingOwner(), address(0));

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        target.pause();
    }

    /// @notice Construction leaves redemption live while zero destination liquidity blocks payout
    function test_constructor_startsUnpaused() public {
        NeverlandAssetRedemption target =
            new NeverlandAssetRedemption(IERC20(address(nloaznd)), IERC20(address(usdc)), RATE, owner);

        assertFalse(target.paused());
        assertEq(target.availableLiquidity(), 0);

        deal(address(nloaznd), holder, 1e18);
        vm.startPrank(holder);
        nloaznd.approve(address(target), 1e18);
        vm.expectRevert(INeverlandAssetRedemption.InsufficientLiquidity.selector);
        target.redeem(1e18);
        vm.stopPrank();

        assertEq(nloaznd.balanceOf(holder), 1e18);
        assertEq(target.totalRedeemed(), 0);
        assertEq(target.totalPaid(), 0);
    }

    /// @notice Construction rejects zero tokens, identical token roles, a zero rate, and a zero owner
    function test_constructor_rejectsInvalidArguments() public {
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        new NeverlandAssetRedemption(IERC20(address(0)), IERC20(address(usdc)), RATE, owner);

        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        new NeverlandAssetRedemption(IERC20(address(nloaznd)), IERC20(address(0)), RATE, owner);

        vm.expectRevert(INeverlandAssetRedemption.InvalidExchangeRate.selector);
        new NeverlandAssetRedemption(IERC20(address(nloaznd)), IERC20(address(usdc)), 0, owner);

        vm.expectRevert(CommonChecksLibrary.SameAddress.selector);
        new NeverlandAssetRedemption(IERC20(address(nloaznd)), IERC20(address(nloaznd)), RATE, owner);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new NeverlandAssetRedemption(IERC20(address(nloaznd)), IERC20(address(usdc)), RATE, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                            ARITHMETIC
    //////////////////////////////////////////////////////////////*/

    /// @notice One whole token pays the rate directly, since the divisor is the source denominator
    function test_calculateRedeem_wholeToken() public view {
        assertEq(redemption.calculateRedeem(1e18), 814_576);
    }

    /// @notice A single wei floors to zero rather than rounding up
    function test_calculateRedeem_singleWeiFloorsToZero() public view {
        assertEq(redemption.calculateRedeem(1), 0);
    }

    /// @notice The full snapshot supply prices just under the settlement total, never over
    function test_calculateRedeem_entireSnapshotSupply() public view {
        assertEq(redemption.calculateRedeem(SNAPSHOT_SUPPLY), 117_694_912_026);
        assertLt(redemption.calculateRedeem(SNAPSHOT_SUPPLY), 117_695e6);
    }

    /// @notice Full-precision quoting supports an intermediate product larger than uint256
    function test_calculateRedeem_fullPrecisionProduct() public {
        NeverlandAssetRedemption fullPrecisionRedemption =
            new NeverlandAssetRedemption(IERC20(address(nloaznd)), IERC20(address(usdc)), 1e18, owner);

        assertEq(fullPrecisionRedemption.calculateRedeem(type(uint256).max), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            REDEMPTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Redeeming moves both legs and updates the redemption counters
    function test_redeem_paysAndAccounts() public {
        deal(address(nloaznd), holder, 10e18);

        vm.startPrank(holder);
        nloaznd.approve(address(redemption), 10e18);
        uint256 paid = redemption.redeem(10e18);
        vm.stopPrank();

        assertEq(paid, 8_145_760);
        assertEq(usdc.balanceOf(holder), 8_145_760);
        assertEq(nloaznd.balanceOf(address(redemption)), 10e18);
        assertEq(redemption.totalRedeemed(), 10e18);
        assertEq(redemption.totalPaid(), 8_145_760);
    }

    /// @notice A saturated payout counter remains observable without blocking later redemption cycles
    function test_redeem_totalPaidSaturatesWithoutBlockingLaterCycle() public {
        MockERC20 unitSource = new MockERC20("Source", "SRC", 0);
        MockERC20 payout = new MockERC20("Payout", "PAY", 0);

        NeverlandAssetRedemption target = new NeverlandAssetRedemption(
            IERC20(address(unitSource)), IERC20(address(payout)), type(uint256).max, owner
        );
        deal(address(payout), address(target), type(uint256).max);
        deal(address(unitSource), holder, 1);

        vm.startPrank(holder);
        unitSource.approve(address(target), type(uint256).max);
        target.redeem(1);
        vm.stopPrank();

        _recoverSourceSequesterAndRefill(target, unitSource, payout, type(uint256).max);
        deal(address(unitSource), holder, 1);

        vm.prank(holder);
        target.redeem(1);

        assertEq(target.totalRedeemed(), 2);
        assertEq(target.totalPaid(), type(uint256).max);
        assertEq(payout.balanceOf(holder), type(uint256).max);
    }

    /// @notice A saturated source counter remains observable without blocking later redemption cycles
    function test_redeem_totalRedeemedSaturatesWithoutBlockingLaterCycle() public {
        MockERC20 highDecimalSource = new MockERC20("Source", "SRC", 77);
        MockERC20 payout = new MockERC20("Payout", "PAY", 0);

        NeverlandAssetRedemption target =
            new NeverlandAssetRedemption(IERC20(address(highDecimalSource)), IERC20(address(payout)), 1, owner);
        uint256 firstPayout = target.calculateRedeem(type(uint256).max);
        deal(address(payout), address(target), firstPayout);
        deal(address(highDecimalSource), holder, type(uint256).max);

        vm.startPrank(holder);
        highDecimalSource.approve(address(target), type(uint256).max);
        target.redeem(type(uint256).max);
        vm.stopPrank();

        _recoverSourceSequesterAndRefill(target, highDecimalSource, payout, 1);
        uint256 minimumPayableSource = target.FROM_DENOMINATOR();
        deal(address(highDecimalSource), holder, minimumPayableSource);

        vm.prank(holder);
        target.redeem(minimumPayableSource);

        assertEq(target.totalRedeemed(), type(uint256).max);
        assertEq(target.totalPaid(), firstPayout + 1);
        assertEq(payout.balanceOf(holder), firstPayout);
    }

    /// @notice An amount too small to pay anything reverts instead of consuming the transfer
    function test_redeem_dustReverts() public {
        deal(address(nloaznd), holder, 1);

        vm.startPrank(holder);
        nloaznd.approve(address(redemption), 1);
        vm.expectRevert(CommonChecksLibrary.ZeroAmount.selector);
        redemption.redeem(1);
        vm.stopPrank();

        assertEq(nloaznd.balanceOf(holder), 1);
    }

    /// @notice Redeeming zero reverts before any transfer
    function test_redeem_zeroReverts() public {
        vm.prank(holder);
        vm.expectRevert(CommonChecksLibrary.ZeroAmount.selector);
        redemption.redeem(0);
    }

    /// @notice Redemption reverts when the contract cannot cover the payout
    function test_redeem_insufficientLiquidityReverts() public {
        deal(address(nloaznd), holder, 1_000_000e18);

        vm.startPrank(holder);
        nloaznd.approve(address(redemption), 1_000_000e18);
        vm.expectRevert(INeverlandAssetRedemption.InsufficientLiquidity.selector);
        redemption.redeem(1_000_000e18);
        vm.stopPrank();
    }

    /// @notice Redemption emits the accounting event
    function test_redeem_emitsRedeemed() public {
        deal(address(nloaznd), holder, 2e18);

        vm.startPrank(holder);
        nloaznd.approve(address(redemption), 2e18);
        vm.expectEmit(true, false, false, true, address(redemption));
        emit INeverlandAssetRedemption.Redeemed(holder, 2e18, 1_629_152);
        redemption.redeem(2e18);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Supplying credits liquidity and emits
    function test_supply_creditsAndAccounts() public {
        deal(address(usdc), address(this), 2_000e6);

        vm.expectEmit(true, false, false, true, address(redemption));
        emit INeverlandAssetRedemption.Supplied(address(this), 2_000e6);
        redemption.supply(2_000e6);

        assertEq(redemption.availableLiquidity(), 152_000e6);
    }

    /// @notice Supplying zero reverts
    function test_supply_zeroReverts() public {
        vm.expectRevert(CommonChecksLibrary.ZeroAmount.selector);
        redemption.supply(0);
    }

    /// @notice A partial withdrawal trims liquidity to a target without emptying the contract
    function test_withdraw_partialLeavesContractFunded() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true, address(redemption));
        emit INeverlandAssetRedemption.Withdrawn(address(usdc), owner, 148_000e6);
        redemption.withdraw(IERC20(address(usdc)), 148_000e6);

        assertEq(redemption.availableLiquidity(), 2_000e6);

        deal(address(nloaznd), holder, 1e18);
        _redeemAsHolder(1e18);

        assertEq(usdc.balanceOf(holder), 814_576);
    }

    /// @notice Withdrawing zero reverts
    function test_withdraw_zeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(CommonChecksLibrary.ZeroAmount.selector);
        redemption.withdraw(IERC20(address(usdc)), 0);
    }

    /// @notice A partial source recovery cannot begin while any payout liquidity remains
    function test_withdraw_sourceTokenWithPayoutLiquidityReverts() public {
        deal(address(nloaznd), address(redemption), 1e18);

        vm.prank(owner);
        vm.expectRevert(INeverlandAssetRedemption.SourceTokenRecoveryLocked.selector);
        redemption.withdraw(IERC20(address(nloaznd)), 1e18);

        assertEq(nloaznd.balanceOf(address(redemption)), 1e18);
        assertFalse(redemption.paused());
    }

    /// @notice A maximum-sentinel source recovery cannot begin while any payout liquidity remains
    function test_withdraw_maxSourceWithPayoutLiquidityReverts() public {
        deal(address(nloaznd), address(redemption), 1e18);

        vm.prank(owner);
        vm.expectRevert(INeverlandAssetRedemption.SourceTokenRecoveryLocked.selector);
        redemption.withdraw(IERC20(address(nloaznd)), type(uint256).max);

        assertEq(nloaznd.balanceOf(address(redemption)), 1e18);
        assertFalse(redemption.paused());
    }

    /// @notice A partial source recovery at zero payout liquidity preserves the live state
    function test_withdraw_sourceTokenAtZeroLiquidityRemainsUnpaused() public {
        deal(address(nloaznd), address(redemption), 2e18);

        vm.startPrank(owner);
        redemption.withdraw(IERC20(address(usdc)), type(uint256).max);
        redemption.withdraw(IERC20(address(nloaznd)), 1e18);
        vm.stopPrank();

        _assertPartialSourceRecoveryState(false);
    }

    /// @notice A maximum-sentinel source recovery emits and transfers the resolved full balance
    function test_withdraw_maxSourceAtZeroLiquidityRecoversFullBalance() public {
        deal(address(nloaznd), address(redemption), 2e18);

        vm.startPrank(owner);
        redemption.withdraw(IERC20(address(usdc)), type(uint256).max);
        vm.expectEmit(true, true, false, true, address(redemption));
        emit INeverlandAssetRedemption.Withdrawn(address(nloaznd), owner, 2e18);
        redemption.withdraw(IERC20(address(nloaznd)), type(uint256).max);
        vm.stopPrank();

        assertFalse(redemption.paused());
        assertEq(nloaznd.balanceOf(owner), 2e18);
        assertEq(nloaznd.balanceOf(address(redemption)), 0);
    }

    /// @notice One atomic maximum-sentinel batch can clear donated payout dust before source recovery
    function test_withdraw_maxClearsDonatedPayoutDustBeforeSourceRecovery() public {
        deal(address(nloaznd), address(redemption), 1e18);

        vm.prank(owner);
        redemption.withdraw(IERC20(address(usdc)), type(uint256).max);

        deal(address(usdc), holder, 1);
        vm.prank(holder);
        usdc.transfer(address(redemption), 1);

        vm.prank(owner);
        usdc.transfer(address(redemption), 1);

        vm.prank(owner);
        vm.expectRevert(INeverlandAssetRedemption.SourceTokenRecoveryLocked.selector);
        redemption.withdraw(IERC20(address(nloaznd)), type(uint256).max);

        _drainPayoutAndRecoverAllSource();

        assertFalse(redemption.paused());
        assertEq(redemption.availableLiquidity(), 0);
        assertEq(nloaznd.balanceOf(owner), 1e18);
    }

    /// @notice A later source recovery succeeds without changing an already-paused state
    function test_withdraw_sourceTokenWhilePausedStaysPaused() public {
        deal(address(nloaznd), address(redemption), 2e18);

        vm.startPrank(owner);
        redemption.withdraw(IERC20(address(usdc)), type(uint256).max);
        redemption.pause();
        redemption.withdraw(IERC20(address(nloaznd)), 1e18);
        vm.stopPrank();

        _assertPartialSourceRecoveryState(true);
    }

    /// @notice Source recovery stays live, so governance sequesters recovered units before refilling
    function test_withdraw_sourceTokenThenSequesterAndRefill() public {
        address sequesterSink = makeAddr("sequesterSink");

        deal(address(nloaznd), address(redemption), 1e18);
        deal(address(nloaznd), holder, 1e18);

        _drainPayoutAndRecoverAllSource();

        vm.prank(owner);
        nloaznd.transfer(sequesterSink, 1e18);

        assertFalse(redemption.paused());
        assertEq(nloaznd.balanceOf(owner), 0);
        assertEq(nloaznd.balanceOf(sequesterSink), 1e18);

        deal(address(usdc), address(this), RATE);
        redemption.supply(RATE);

        _redeemAsHolder(1e18);

        assertEq(usdc.balanceOf(holder), RATE);
        assertEq(redemption.availableLiquidity(), 0);
    }

    /// @notice A maximum-sentinel payout withdrawal sends the full balance and emits the resolved amount
    function test_withdraw_maxPayoutSendsFullBalanceToOwner() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true, address(redemption));
        emit INeverlandAssetRedemption.Withdrawn(address(usdc), owner, 150_000e6);
        redemption.withdraw(IERC20(address(usdc)), type(uint256).max);

        assertEq(usdc.balanceOf(owner), 150_000e6);
        assertEq(redemption.availableLiquidity(), 0);
    }

    /// @notice A maximum-sentinel stray-token withdrawal sends the full balance and emits the resolved amount
    function test_withdraw_maxStrayTokenSendsFullBalanceToOwner() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        deal(address(stray), address(redemption), 7e18);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true, address(redemption));
        emit INeverlandAssetRedemption.Withdrawn(address(stray), owner, 7e18);
        redemption.withdraw(IERC20(address(stray)), type(uint256).max);

        assertEq(stray.balanceOf(owner), 7e18);
        assertEq(stray.balanceOf(address(redemption)), 0);
    }

    /// @notice A maximum-sentinel withdrawal of a zero balance reverts
    function test_withdraw_maxZeroBalanceReverts() public {
        vm.startPrank(owner);
        redemption.withdraw(IERC20(address(usdc)), type(uint256).max);
        vm.expectRevert(CommonChecksLibrary.ZeroBalance.selector);
        redemption.withdraw(IERC20(address(usdc)), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice An empty source balance reports zero balance before evaluating the payout-liquidity lock
    function test_withdraw_maxEmptySourceRevertsZeroBalanceBeforeLiquidityLock() public {
        assertGt(redemption.availableLiquidity(), 0);

        vm.prank(owner);
        vm.expectRevert(CommonChecksLibrary.ZeroBalance.selector);
        redemption.withdraw(IERC20(address(nloaznd)), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Emergency pause and explicit unpause are separate state transitions
    function test_pauseAndUnpause_areExplicit() public {
        deal(address(nloaznd), holder, 1e18);

        vm.prank(owner);
        redemption.pause();
        assertTrue(redemption.paused());

        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        redemption.pause();

        vm.startPrank(holder);
        nloaznd.approve(address(redemption), 1e18);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        redemption.redeem(1e18);
        vm.stopPrank();

        vm.prank(owner);
        redemption.unpause();
        assertFalse(redemption.paused());

        vm.prank(owner);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        redemption.unpause();

        vm.prank(holder);
        redemption.redeem(1e18);

        assertEq(redemption.totalRedeemed(), 1e18);
    }

    /// @notice The owner cannot change the rate while redemptions are live
    function test_setExchangeRate_liveReverts() public {
        vm.prank(owner);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        redemption.setExchangeRate(900_000);
    }

    /// @notice The owner can pause, update the rate, and resume future redemptions
    function test_setExchangeRate_pausedUpdateAppliesToFutureRedemptions() public {
        uint256 newRate = 900_000;
        deal(address(nloaznd), holder, 2e18);

        _redeemAsHolder(1e18);

        vm.startPrank(owner);
        redemption.pause();
        vm.expectEmit(false, false, false, true, address(redemption));
        emit INeverlandAssetRedemption.ExchangeRateChanged(RATE, newRate);
        redemption.setExchangeRate(newRate);
        redemption.unpause();
        vm.stopPrank();

        _redeemAsHolder(1e18);

        assertFalse(redemption.paused());
        assertEq(redemption.exchangeRate(), newRate);
        assertEq(redemption.calculateRedeem(1e18), newRate);
        assertEq(usdc.balanceOf(holder), RATE + newRate);
        assertEq(redemption.totalPaid(), RATE + newRate);
    }

    /// @notice Source recovery does not implicitly authorize a paused-only rate update
    function test_setExchangeRate_afterSourceRecoveryRequiresExplicitPause() public {
        uint256 newRate = 900_000;
        address recoverySink = makeAddr("recoverySink");
        deal(address(nloaznd), holder, 2e18);

        _redeemAsHolder(1e18);

        _drainPayoutAndRecoverAllSource();
        assertFalse(redemption.paused());

        vm.startPrank(owner);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        redemption.setExchangeRate(newRate);
        redemption.pause();
        redemption.setExchangeRate(newRate);
        assertTrue(redemption.paused());
        nloaznd.transfer(recoverySink, 1e18);
        usdc.approve(address(redemption), newRate);
        redemption.supply(newRate);
        redemption.unpause();
        vm.stopPrank();

        _redeemAsHolder(1e18);

        assertFalse(redemption.paused());
        assertEq(usdc.balanceOf(holder), RATE + newRate);
        assertEq(redemption.totalRedeemed(), 2e18);
        assertEq(redemption.totalPaid(), RATE + newRate);
    }

    /// @notice A paused rate update rejects zero
    function test_setExchangeRate_zeroReverts() public {
        vm.startPrank(owner);
        redemption.pause();
        vm.expectRevert(INeverlandAssetRedemption.InvalidExchangeRate.selector);
        redemption.setExchangeRate(0);
        vm.stopPrank();

        assertEq(redemption.exchangeRate(), RATE);
    }

    /// @notice A non-owner cannot change the rate while paused
    function test_setExchangeRate_nonOwnerReverts() public {
        vm.prank(owner);
        redemption.pause();

        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder));
        redemption.setExchangeRate(900_000);

        assertEq(redemption.exchangeRate(), RATE);
    }

    /// @notice Renouncing ownership is disabled
    function test_renounceOwnership_reverts() public {
        vm.prank(owner);
        vm.expectRevert(INeverlandAssetRedemption.OwnershipRequired.selector);
        redemption.renounceOwnership();
    }

    /// @notice Admin functions are owner-gated
    function test_adminFunctions_ownerOnly() public {
        vm.startPrank(holder);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder));
        redemption.pause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder));
        redemption.unpause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder));
        redemption.withdraw(IERC20(address(usdc)), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder));
        redemption.setExchangeRate(900_000);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holder));
        redemption.renounceOwnership();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The views report liquidity, the current rate, and the wiring
    function test_views_reportLiquidityAndWiring() public view {
        assertEq(redemption.availableLiquidity(), 150_000e6);
        assertEq(redemption.FROM_DENOMINATOR(), 1e18);
        assertEq(address(redemption.FROM_TOKEN()), address(nloaznd));
        assertEq(address(redemption.TO_TOKEN()), address(usdc));
        assertEq(redemption.exchangeRate(), RATE);
        assertEq(redemption.owner(), owner);
    }

    /// @notice No source amount is redeemable when no destination liquidity remains
    function test_maxRedeemable_zeroLiquidityReturnsZero() public {
        vm.prank(owner);
        redemption.withdraw(IERC20(address(usdc)), type(uint256).max);

        assertEq(redemption.maxRedeemable(), 0);
    }

    /// @notice One destination base unit reports and executes the exact largest payable source amount
    function test_maxRedeemable_oneBaseUnitIsExactAndExecutable() public {
        vm.prank(owner);
        redemption.withdraw(IERC20(address(usdc)), 150_000e6 - 1);

        uint256 maximum = redemption.maxRedeemable();
        assertEq(maximum, 2_455_265_070_417);
        assertEq(redemption.calculateRedeem(maximum), 1);
        assertEq(redemption.calculateRedeem(maximum + 1), 2);

        deal(address(nloaznd), holder, maximum);
        _redeemAsHolder(maximum);

        assertEq(usdc.balanceOf(holder), 1);
        assertEq(redemption.availableLiquidity(), 0);
    }

    /// @notice Every positive ordinary liquidity value has an exact maximum/next-input boundary
    function testFuzz_maxRedeemable_isExactBoundary(uint96 liquidity) public {
        liquidity = uint96(bound(liquidity, 1, type(uint96).max));
        deal(address(usdc), address(redemption), liquidity);

        _assertExactMaximumBoundary(liquidity);
    }

    /// @notice The maximum saturates when full liquidity covers every representable source amount
    function test_maxRedeemable_saturatesAtUint256Max() public {
        MockERC20 zeroDecimalSource = new MockERC20("Source", "SRC", 0);

        NeverlandAssetRedemption saturatedRedemption =
            new NeverlandAssetRedemption(IERC20(address(zeroDecimalSource)), IERC20(address(usdc)), 1, owner);
        deal(address(usdc), address(saturatedRedemption), type(uint256).max);

        assertEq(saturatedRedemption.maxRedeemable(), type(uint256).max);
    }

    /// @notice Full liquidity with a rate above the denominator still returns the exact finite maximum
    function test_maxRedeemable_fullLiquidityWithRateAboveDenominator() public {
        MockERC20 zeroDecimalSource = new MockERC20("Source", "SRC", 0);

        NeverlandAssetRedemption finiteRedemption =
            new NeverlandAssetRedemption(IERC20(address(zeroDecimalSource)), IERC20(address(usdc)), 2, owner);
        deal(address(usdc), address(finiteRedemption), type(uint256).max);

        assertEq(finiteRedemption.maxRedeemable(), type(uint256).max / 2);
    }

    /// @notice The full-liquidity special branch rounds up when the remainder crosses its threshold
    function test_maxRedeemable_fullLiquidityRoundsSpecialBranchUp() public {
        MockERC20 oneDecimalSource = new MockERC20("Source", "SRC", 1);

        NeverlandAssetRedemption finiteRedemption =
            new NeverlandAssetRedemption(IERC20(address(oneDecimalSource)), IERC20(address(usdc)), 11, owner);
        deal(address(usdc), address(finiteRedemption), type(uint256).max);

        uint256 maximum = finiteRedemption.maxRedeemable();
        assertEq(
            maximum,
            105_265_535_670_287_450_385_064_531_826_079_916_230_245_440_605_127_785_490_415_985_461_739_208_763_578
        );
        assertEq(finiteRedemption.calculateRedeem(maximum), type(uint256).max);

        vm.expectRevert();
        finiteRedemption.calculateRedeem(maximum + 1);
    }

    /// @notice Positive liquidity can still be too small to fund any positive source input
    function test_maxRedeemable_positiveLiquidityBelowMinimumPayoutReturnsZero() public {
        MockERC20 zeroDecimalSource = new MockERC20("Source", "SRC", 0);

        NeverlandAssetRedemption highRateRedemption =
            new NeverlandAssetRedemption(IERC20(address(zeroDecimalSource)), IERC20(address(usdc)), 2, owner);
        deal(address(usdc), address(highRateRedemption), 1);

        assertEq(highRateRedemption.maxRedeemable(), 0);
        assertEq(highRateRedemption.calculateRedeem(1), 2);
    }

    /// @notice The exact maximum/next-input boundary holds across reusable rates
    function testFuzz_maxRedeemable_isExactAcrossRates(uint96 liquidity, uint96 newRate) public {
        liquidity = uint96(bound(liquidity, 1, type(uint96).max));
        newRate = uint96(bound(newRate, 1, type(uint96).max));

        vm.startPrank(owner);
        redemption.pause();
        redemption.setExchangeRate(newRate);
        vm.stopPrank();
        deal(address(usdc), address(redemption), liquidity);

        _assertExactMaximumBoundary(liquidity);
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Drains all payout liquidity and then recovers all source as the owner.
     */
    function _drainPayoutAndRecoverAllSource() private {
        vm.startPrank(owner);
        redemption.withdraw(IERC20(address(usdc)), type(uint256).max);
        redemption.withdraw(IERC20(address(nloaznd)), type(uint256).max);
        vm.stopPrank();
    }

    /**
     * @notice Recovers and sequesters all source, then recycles holder payout liquidity into a target.
     * @param target The redemption instance to cycle.
     * @param source The target's source token.
     * @param payout The target's payout token.
     * @param refillAmount The payout amount to refill.
     */
    function _recoverSourceSequesterAndRefill(
        NeverlandAssetRedemption target,
        MockERC20 source,
        MockERC20 payout,
        uint256 refillAmount
    ) private {
        vm.prank(owner);
        target.withdraw(IERC20(address(source)), type(uint256).max);

        uint256 recovered = source.balanceOf(owner);
        vm.prank(owner);
        source.transfer(makeAddr("counterRecoverySink"), recovered);
        vm.startPrank(holder);
        payout.approve(address(target), refillAmount);
        target.supply(refillAmount);
        vm.stopPrank();
    }

    /**
     * @notice Approves and redeems an amount from the configured holder.
     * @param amount The source-token amount to redeem.
     */
    function _redeemAsHolder(uint256 amount) private {
        vm.startPrank(holder);
        nloaznd.approve(address(redemption), amount);
        redemption.redeem(amount);
        vm.stopPrank();
    }

    /**
     * @notice Asserts that the current maximum is payable and its successor is not.
     * @param liquidity The current destination-token balance.
     */
    function _assertExactMaximumBoundary(uint256 liquidity) private view {
        uint256 maximum = redemption.maxRedeemable();

        assertLe(redemption.calculateRedeem(maximum), liquidity);
        assertGt(redemption.calculateRedeem(maximum + 1), liquidity);
    }

    /**
     * @notice Asserts the shared partial source-recovery state.
     * @param expectedPaused Expected administrative pause state after recovery.
     */
    function _assertPartialSourceRecoveryState(bool expectedPaused) private view {
        assertEq(redemption.paused(), expectedPaused);
        assertEq(nloaznd.balanceOf(owner), 1e18);
        assertEq(nloaznd.balanceOf(address(redemption)), 1e18);
    }
}
