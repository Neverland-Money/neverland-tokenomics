// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPool} from "@neverland-money/lending-core/contracts/interfaces/IPool.sol";
import {IWETH} from "@neverland-money/lending-core/contracts/misc/interfaces/IWETH.sol";
import {Ownable} from "@openzeppelin-v5/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin-v5/contracts/utils/ReentrancyGuard.sol";
import {Test} from "forge-std/Test.sol";

import {INeverlandNativeGateway} from "../../../src/interfaces/INeverlandNativeGateway.sol";

import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";

import {NeverlandNativeGateway} from "../../../src/utils/NeverlandNativeGateway.sol";

import {MockERC20} from "../../_utils/MockERC20.sol";
import {
    MockLendingPool,
    MockNativeRejector,
    MockReentrantReceiver,
    MockScaledToken,
    MockWrappedNative,
    ReentryTarget
} from "../mocks/NativeGatewayMocks.sol";

/**
 * @title NeverlandNativeGatewayTest
 * @author Neverland
 * @notice Unit tests for the native-asset lending gateway
 * @dev Covers construction and the pool allowance, every user action including the maximum-sentinel
 *      resolution and the overpaid-repayment refund, the owner-only recovery paths, the disabled
 *      ownership renouncement, the reentrancy guard, and the native-receipt restrictions.
 */
contract NeverlandNativeGatewayTest is Test {
    /// @dev Wrapped liquidity seeded into the pool so withdrawals and borrows can be paid out.
    uint256 internal constant POOL_LIQUIDITY = 1_000 ether;

    /// @dev `DataTypes.InterestRateMode.STABLE`, the only value the gateway treats as stable debt.
    uint256 internal constant STABLE_MODE = 1;

    /// @dev `DataTypes.InterestRateMode.VARIABLE`.
    uint256 internal constant VARIABLE_MODE = 2;

    NeverlandNativeGateway internal gateway;
    MockWrappedNative internal wrapped;
    MockLendingPool internal pool;
    MockScaledToken internal nToken;
    MockScaledToken internal stableDebt;
    MockScaledToken internal variableDebt;

    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");
    address internal beneficiary = makeAddr("beneficiary");

    function setUp() public {
        wrapped = new MockWrappedNative();
        nToken = new MockScaledToken();
        stableDebt = new MockScaledToken();
        variableDebt = new MockScaledToken();
        pool = new MockLendingPool(wrapped, nToken, stableDebt, variableDebt);

        gateway = new NeverlandNativeGateway(IWETH(address(wrapped)), IPool(address(pool)), owner);

        vm.deal(address(this), POOL_LIQUIDITY);
        wrapped.deposit{value: POOL_LIQUIDITY}();
        wrapped.transfer(address(pool), POOL_LIQUIDITY);

        vm.deal(user, 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Construction binds both immutables and assigns the governance owner
    function test_constructor_bindsImmutablesAndOwner() public view {
        assertEq(address(gateway.WRAPPED_NATIVE()), address(wrapped));
        assertEq(address(gateway.POOL()), address(pool));
        assertEq(gateway.owner(), owner);
    }

    /// @notice Construction grants the pool an unlimited wrapped allowance
    function test_constructor_grantsInfinitePoolAllowance() public view {
        assertEq(wrapped.allowance(address(gateway), address(pool)), type(uint256).max);
    }

    /// @notice The deployer never holds authority and no acceptance is left pending
    function test_constructor_assignsOwnerWithoutDeployerCustody() public {
        address deployer = makeAddr("deployer");

        vm.prank(deployer);
        NeverlandNativeGateway fresh = new NeverlandNativeGateway(IWETH(address(wrapped)), IPool(address(pool)), owner);

        assertEq(fresh.owner(), owner);
        assertEq(fresh.pendingOwner(), address(0));
    }

    /// @notice A zero wrapped native token is rejected
    function test_constructor_revertsOnZeroWrappedNative() public {
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        new NeverlandNativeGateway(IWETH(address(0)), IPool(address(pool)), owner);
    }

    /// @notice A zero pool is rejected
    function test_constructor_revertsOnZeroPool() public {
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        new NeverlandNativeGateway(IWETH(address(wrapped)), IPool(address(0)), owner);
    }

    /// @notice A zero owner is rejected by the base constructor before the address checks run
    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new NeverlandNativeGateway(IWETH(address(wrapped)), IPool(address(pool)), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                                SUPPLY
    //////////////////////////////////////////////////////////////*/

    /// @notice Supply wraps the attached value and mints nTokens to the beneficiary
    function test_supply_wrapsAndMintsToBeneficiary() public {
        vm.prank(user);
        gateway.supply{value: 3 ether}(beneficiary, 7);

        assertEq(nToken.balanceOf(beneficiary), 3 ether);
        assertEq(wrapped.balanceOf(address(pool)), POOL_LIQUIDITY + 3 ether);
        assertEq(pool.lastAsset(), address(wrapped));
        assertEq(pool.lastAmount(), 3 ether);
        assertEq(pool.lastOnBehalfOf(), beneficiary);
        assertEq(pool.lastReferralCode(), 7);
    }

    /// @notice Supply leaves no native or wrapped balance resting on the gateway
    function test_supply_leavesNoResidualBalance() public {
        vm.prank(user);
        gateway.supply{value: 3 ether}(beneficiary, 0);

        assertEq(address(gateway).balance, 0);
        assertEq(wrapped.balanceOf(address(gateway)), 0);
    }

    /// @notice Supply routes through the pool's current entry point, not its deprecated alias
    function test_supply_usesCurrentPoolEntryPoint() public {
        vm.prank(user);
        gateway.supply{value: 1 ether}(user, 0);

        assertEq(pool.supplyCallCount(), 1);
        assertEq(pool.depositCallCount(), 0);
    }

    /**
     * @notice A zero-value supply forwards to the pool rather than being rejected by the gateway
     * @dev Mock-only outcome: the gateway adds no zero guard, so the real pool's `INVALID_AMOUNT`
     *      is what rejects this on chain.
     */
    function test_supply_zeroValueMintsNothing() public {
        vm.prank(user);
        gateway.supply{value: 0}(beneficiary, 0);

        assertEq(nToken.balanceOf(beneficiary), 0);
        assertEq(pool.supplyCallCount(), 1);
    }

    /// @notice A zero beneficiary is rejected before any value is wrapped
    function test_supply_revertsForZeroBeneficiary() public {
        vm.expectRevert(CommonChecksLibrary.InvalidUserAddress.selector);

        vm.prank(user);
        gateway.supply{value: 1 ether}(address(0), 0);
    }

    /*//////////////////////////////////////////////////////////////
                               WITHDRAW
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw pulls the exact nToken amount and pays the caller in the native asset
    function test_withdraw_exactAmount() public {
        _seedWithdrawable(user, 5 ether);
        uint256 balanceBefore = user.balance;

        vm.prank(user);
        gateway.withdraw(2 ether, user);

        assertEq(user.balance, balanceBefore + 2 ether);
        assertEq(nToken.balanceOf(user), 3 ether);
        assertEq(pool.lastAmount(), 2 ether);
        assertEq(pool.lastTo(), address(gateway), "wrapped must route through the gateway to be unwrapped");
    }

    /// @notice The maximum sentinel resolves to the caller's whole nToken balance
    function test_withdraw_maximumSentinelDrainsBalance() public {
        _seedWithdrawable(user, 5 ether);
        uint256 balanceBefore = user.balance;

        vm.prank(user);
        gateway.withdraw(type(uint256).max, user);

        assertEq(user.balance, balanceBefore + 5 ether);
        assertEq(nToken.balanceOf(user), 0);
        assertEq(pool.lastAmount(), 5 ether);
    }

    /// @notice The native payout can be directed to an address other than the caller
    function test_withdraw_sendsToDistinctRecipient() public {
        _seedWithdrawable(user, 5 ether);
        uint256 recipientBefore = beneficiary.balance;

        vm.prank(user);
        gateway.withdraw(4 ether, beneficiary);

        assertEq(beneficiary.balance, recipientBefore + 4 ether);
        assertEq(user.balance, 100 ether);
    }

    /// @notice Withdraw leaves nothing resting on the gateway
    function test_withdraw_leavesNoResidualBalance() public {
        _seedWithdrawable(user, 5 ether);

        vm.prank(user);
        gateway.withdraw(5 ether, user);

        assertEq(address(gateway).balance, 0);
        assertEq(wrapped.balanceOf(address(gateway)), 0);
        assertEq(nToken.balanceOf(address(gateway)), 0);
    }

    /// @notice A recipient that refuses the native asset reverts the whole withdrawal
    function test_withdraw_revertsWhenRecipientRejectsNative() public {
        _seedWithdrawable(user, 5 ether);
        MockNativeRejector rejector = new MockNativeRejector();

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandNativeGateway.NativeTransferFailed.selector, address(rejector), 2 ether)
        );

        vm.prank(user);
        gateway.withdraw(2 ether, address(rejector));
    }

    /// @notice A recipient re-entering during its payout is rejected while the outer call completes
    function test_withdraw_guardRejectsReentrantWithdraw() public {
        _assertReentryRejected(ReentryTarget.Withdraw);
    }

    /// @notice The guard is shared, so a recipient re-entering supply during its payout is also rejected
    function test_withdraw_guardRejectsReentrantSupply() public {
        _assertReentryRejected(ReentryTarget.Supply);
    }

    /// @notice The guard is shared, so a recipient re-entering borrow during its payout is also rejected
    function test_withdraw_guardRejectsReentrantBorrow() public {
        _assertReentryRejected(ReentryTarget.Borrow);
    }

    /// @notice The guard is shared, so a recipient re-entering repay during its payout is also rejected
    function test_withdraw_guardRejectsReentrantRepay() public {
        _assertReentryRejected(ReentryTarget.Repay);
    }

    /// @notice A zero recipient is rejected rather than burned by the raw native transfer
    function test_withdraw_revertsForZeroRecipient() public {
        _seedWithdrawable(user, 5 ether);

        vm.expectRevert(CommonChecksLibrary.InvalidToAddress.selector);

        vm.prank(user);
        gateway.withdraw(2 ether, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                                 REPAY
    //////////////////////////////////////////////////////////////*/

    /// @notice An exact repayment clears the debt and refunds nothing
    function test_repay_exactValueClearsDebt() public {
        variableDebt.mint(user, 4 ether);
        uint256 balanceBefore = user.balance;

        vm.prank(user);
        gateway.repay{value: 4 ether}(4 ether, VARIABLE_MODE, user);

        assertEq(variableDebt.balanceOf(user), 0);
        assertEq(user.balance, balanceBefore - 4 ether);
        assertEq(pool.lastAmount(), 4 ether);
    }

    /**
     * @notice Stable mode reads the stable debt balance and leaves variable debt untouched
     * @dev Pins the gateway's branch selection only; the real pool rejects stable-mode repayment.
     */
    function test_repay_stableModeReadsStableDebt() public {
        stableDebt.mint(user, 6 ether);
        variableDebt.mint(user, 9 ether);

        vm.prank(user);
        gateway.repay{value: 6 ether}(type(uint256).max, STABLE_MODE, user);

        assertEq(stableDebt.balanceOf(user), 0);
        assertEq(variableDebt.balanceOf(user), 9 ether);
        assertEq(pool.lastRateMode(), STABLE_MODE);
    }

    /// @notice Any mode other than stable resolves against variable debt
    function test_repay_noneModeResolvesAgainstVariableDebt() public {
        variableDebt.mint(user, 2 ether);

        vm.prank(user);
        gateway.repay{value: 2 ether}(type(uint256).max, 0, user);

        assertEq(variableDebt.balanceOf(user), 0);
    }

    /// @notice A request above the outstanding debt is capped at the debt
    function test_repay_cappedAtOutstandingDebt() public {
        variableDebt.mint(user, 3 ether);
        uint256 balanceBefore = user.balance;

        vm.prank(user);
        gateway.repay{value: 5 ether}(5 ether, VARIABLE_MODE, user);

        assertEq(variableDebt.balanceOf(user), 0);
        assertEq(pool.lastAmount(), 3 ether);
        assertEq(user.balance, balanceBefore - 3 ether);
    }

    /// @notice The maximum sentinel repays the whole debt
    function test_repay_maximumSentinelRepaysFullDebt() public {
        variableDebt.mint(user, 7 ether);

        vm.prank(user);
        gateway.repay{value: 7 ether}(type(uint256).max, VARIABLE_MODE, user);

        assertEq(variableDebt.balanceOf(user), 0);
        assertEq(pool.lastAmount(), 7 ether);
    }

    /// @notice A partial repayment sent with surplus value forwards only the resolved amount and refunds the rest
    function test_repay_partialOverpaymentRefundsSurplus() public {
        variableDebt.mint(user, 10 ether);
        uint256 balanceBefore = user.balance;

        vm.prank(user);
        gateway.repay{value: 6 ether}(4 ether, VARIABLE_MODE, user);

        assertEq(variableDebt.balanceOf(user), 6 ether);
        assertEq(pool.lastAmount(), 4 ether);
        assertEq(user.balance, balanceBefore - 4 ether);
        assertEq(address(gateway).balance, 0);
        assertEq(wrapped.balanceOf(address(gateway)), 0);
    }

    /// @notice Value below the resolved repayment is rejected before anything is wrapped
    function test_repay_revertsWhenValueBelowPayback() public {
        variableDebt.mint(user, 5 ether);

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandNativeGateway.InsufficientRepaymentValue.selector, 3 ether, 5 ether)
        );

        vm.prank(user);
        gateway.repay{value: 3 ether}(type(uint256).max, VARIABLE_MODE, user);
    }

    /// @notice A repayer that refuses its refund reverts the whole repayment
    function test_repay_revertsWhenRefundRejected() public {
        MockNativeRejector rejector = new MockNativeRejector();
        variableDebt.mint(address(rejector), 10 ether);
        vm.deal(address(rejector), 10 ether);

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandNativeGateway.NativeTransferFailed.selector, address(rejector), 2 ether)
        );

        vm.prank(address(rejector));
        gateway.repay{value: 6 ether}(4 ether, VARIABLE_MODE, address(rejector));
    }

    /// @notice Repaying on another account's behalf clears that account's debt
    function test_repay_onBehalfOfAnotherAccount() public {
        variableDebt.mint(beneficiary, 5 ether);

        vm.prank(user);
        gateway.repay{value: 5 ether}(type(uint256).max, VARIABLE_MODE, beneficiary);

        assertEq(variableDebt.balanceOf(beneficiary), 0);
        assertEq(pool.lastOnBehalfOf(), beneficiary);
    }

    /*//////////////////////////////////////////////////////////////
                                BORROW
    //////////////////////////////////////////////////////////////*/

    /// @notice Borrow mints debt to the caller and pays out the native asset
    function test_borrow_sendsNativeToCaller() public {
        uint256 balanceBefore = user.balance;

        vm.prank(user);
        gateway.borrow(3 ether, VARIABLE_MODE, 11);

        assertEq(user.balance, balanceBefore + 3 ether);
        assertEq(variableDebt.balanceOf(user), 3 ether);
        assertEq(pool.lastReferralCode(), 11);
        assertEq(pool.lastOnBehalfOf(), user);
    }

    /// @notice Stable-mode borrows accrue against the stable debt token
    function test_borrow_stableModeMintsStableDebt() public {
        vm.prank(user);
        gateway.borrow(2 ether, STABLE_MODE, 0);

        assertEq(stableDebt.balanceOf(user), 2 ether);
        assertEq(variableDebt.balanceOf(user), 0);
    }

    /// @notice Borrow leaves nothing resting on the gateway
    function test_borrow_leavesNoResidualBalance() public {
        vm.prank(user);
        gateway.borrow(3 ether, VARIABLE_MODE, 0);

        assertEq(address(gateway).balance, 0);
        assertEq(wrapped.balanceOf(address(gateway)), 0);
    }

    /// @notice A caller that refuses the native asset reverts the borrow
    function test_borrow_revertsWhenCallerRejectsNative() public {
        MockNativeRejector rejector = new MockNativeRejector();

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandNativeGateway.NativeTransferFailed.selector, address(rejector), 1 ether)
        );

        vm.prank(address(rejector));
        gateway.borrow(1 ether, VARIABLE_MODE, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        WITHDRAW WITH PERMIT
    //////////////////////////////////////////////////////////////*/

    /// @notice The permit path withdraws without a prior approval transaction
    function test_withdrawWithPermit_withdrawsExactAmount() public {
        nToken.mint(user, 5 ether);
        uint256 balanceBefore = user.balance;

        vm.prank(user);
        gateway.withdrawWithPermit(2 ether, user, block.timestamp + 1 days, 27, bytes32("r"), bytes32("s"));

        assertEq(user.balance, balanceBefore + 2 ether);
        assertEq(nToken.balanceOf(user), 3 ether);
    }

    /// @notice The signature is taken over the requested amount, not the resolved balance
    function test_withdrawWithPermit_signsOverRequestedAmount() public {
        nToken.mint(user, 5 ether);

        vm.prank(user);
        gateway.withdrawWithPermit(type(uint256).max, user, block.timestamp + 1 days, 27, bytes32("r"), bytes32("s"));

        assertEq(nToken.lastPermitValue(), type(uint256).max);
        assertEq(nToken.balanceOf(user), 0);
        assertEq(pool.lastAmount(), 5 ether);
    }

    /// @notice Permit arguments are forwarded to the nToken unchanged
    function test_withdrawWithPermit_forwardsSignatureComponents() public {
        nToken.mint(user, 5 ether);
        uint256 deadline = block.timestamp + 3 days;

        vm.prank(user);
        gateway.withdrawWithPermit(2 ether, beneficiary, deadline, 28, bytes32("rr"), bytes32("ss"));

        assertEq(nToken.permitCallCount(), 1);
        assertEq(nToken.lastPermitOwner(), user);
        assertEq(nToken.lastPermitSpender(), address(gateway));
        assertEq(nToken.lastPermitDeadline(), deadline);
        assertEq(nToken.lastPermitV(), 28);
        assertEq(nToken.lastPermitR(), bytes32("rr"));
        assertEq(nToken.lastPermitS(), bytes32("ss"));
    }

    /// @notice The permit path rejects a zero recipient on the same guard as the plain path
    function test_withdrawWithPermit_revertsForZeroRecipient() public {
        nToken.mint(user, 5 ether);

        vm.expectRevert(CommonChecksLibrary.InvalidToAddress.selector);

        vm.prank(user);
        gateway.withdrawWithPermit(2 ether, address(0), block.timestamp + 1 days, 27, bytes32("r"), bytes32("s"));
    }

    /// @notice A permit another transaction already consumed does not abort the withdrawal
    function test_withdrawWithPermit_toleratesConsumedPermit() public {
        _seedWithdrawable(user, 5 ether);
        nToken.setRevertOnPermit(true);
        uint256 balanceBefore = user.balance;

        vm.prank(user);
        gateway.withdrawWithPermit(2 ether, user, block.timestamp + 1 days, 27, bytes32("r"), bytes32("s"));

        assertEq(user.balance, balanceBefore + 2 ether);
        assertEq(nToken.permitCallCount(), 0);
    }

    /// @notice Tolerating the permit does not waive the allowance the pull still needs
    function test_withdrawWithPermit_stillRequiresAllowanceWhenPermitFails() public {
        nToken.mint(user, 5 ether);
        nToken.setRevertOnPermit(true);

        vm.expectRevert(MockScaledToken.InsufficientAllowance.selector);

        vm.prank(user);
        gateway.withdrawWithPermit(2 ether, user, block.timestamp + 1 days, 27, bytes32("r"), bytes32("s"));
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice The owner can recover tokens transferred to the gateway by mistake
    function test_emergencyTokenTransfer_recoversStrandedTokens() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        deal(address(stray), address(gateway), 500e18);

        vm.expectEmit(true, true, false, true, address(gateway));
        emit INeverlandNativeGateway.ERC20Recovered(address(stray), beneficiary, 500e18);

        vm.prank(owner);
        gateway.emergencyTokenTransfer(address(stray), beneficiary, 500e18);

        assertEq(stray.balanceOf(beneficiary), 500e18);
        assertEq(stray.balanceOf(address(gateway)), 0);
    }

    /// @notice Token recovery rejects a zero recipient rather than relying on the token to catch it
    function test_emergencyTokenTransfer_revertsForZeroRecipient() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        deal(address(stray), address(gateway), 1e18);

        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);

        vm.prank(owner);
        gateway.emergencyTokenTransfer(address(stray), address(0), 1e18);
    }

    /// @notice Native recovery rejects a zero recipient, which a raw call would otherwise burn
    function test_emergencyNativeTransfer_revertsForZeroRecipient() public {
        vm.deal(address(gateway), 1 ether);

        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);

        vm.prank(owner);
        gateway.emergencyNativeTransfer(address(0), 1 ether);
    }

    /// @notice Token recovery is owner-only
    function test_emergencyTokenTransfer_revertsForNonOwner() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));

        vm.prank(user);
        gateway.emergencyTokenTransfer(address(stray), user, 1);
    }

    /// @notice The owner can recover native funds that reached the gateway outside a call
    function test_emergencyNativeTransfer_recoversStrandedNative() public {
        vm.deal(address(gateway), 4 ether);
        uint256 balanceBefore = beneficiary.balance;

        vm.expectEmit(true, false, false, true, address(gateway));
        emit INeverlandNativeGateway.NativeRecovered(beneficiary, 4 ether);

        vm.prank(owner);
        gateway.emergencyNativeTransfer(beneficiary, 4 ether);

        assertEq(beneficiary.balance, balanceBefore + 4 ether);
        assertEq(address(gateway).balance, 0);
    }

    /// @notice Native recovery is owner-only
    function test_emergencyNativeTransfer_revertsForNonOwner() public {
        vm.deal(address(gateway), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));

        vm.prank(user);
        gateway.emergencyNativeTransfer(user, 1 ether);
    }

    /// @notice Native recovery surfaces a failing recipient rather than silently succeeding
    function test_emergencyNativeTransfer_revertsWhenRecipientRejects() public {
        MockNativeRejector rejector = new MockNativeRejector();
        vm.deal(address(gateway), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandNativeGateway.NativeTransferFailed.selector, address(rejector), 1 ether)
        );

        vm.prank(owner);
        gateway.emergencyNativeTransfer(address(rejector), 1 ether);
    }

    /// @notice Renouncing ownership is disabled for the owner
    function test_renounceOwnership_revertsForOwner() public {
        vm.expectRevert(INeverlandNativeGateway.OwnershipRequired.selector);

        vm.prank(owner);
        gateway.renounceOwnership();
    }

    /// @notice Renouncing ownership fails the authorization check before the disabling revert
    function test_renounceOwnership_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));

        vm.prank(user);
        gateway.renounceOwnership();
    }

    /// @notice Ownership transfer requires the recipient to accept
    function test_transferOwnership_requiresAcceptance() public {
        address successor = makeAddr("successor");

        vm.prank(owner);
        gateway.transferOwnership(successor);

        assertEq(gateway.owner(), owner);
        assertEq(gateway.pendingOwner(), successor);

        vm.prank(successor);
        gateway.acceptOwnership();

        assertEq(gateway.owner(), successor);
        assertEq(gateway.pendingOwner(), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                         NATIVE ASSET HANDLING
    //////////////////////////////////////////////////////////////*/

    /// @notice The wrapped token may send the native asset while unwrapping
    function test_receive_acceptsFromWrappedNative() public {
        vm.deal(address(wrapped), 1 ether);

        vm.prank(address(wrapped));
        (bool success,) = address(gateway).call{value: 1 ether}("");

        assertTrue(success);
        assertEq(address(gateway).balance, 1 ether);
    }

    /// @notice Every other sender is refused
    function test_receive_revertsForAnyOtherSender() public {
        vm.prank(user);
        (bool success, bytes memory reason) = address(gateway).call{value: 1 ether}("");

        assertFalse(success);
        assertEq(reason, abi.encodeWithSelector(INeverlandNativeGateway.DirectNativeTransferNotAllowed.selector, user));
        assertEq(address(gateway).balance, 0);
    }

    /// @notice An unknown selector reverts rather than being absorbed
    function test_fallback_revertsOnUnknownSelector() public {
        vm.prank(user);
        (bool success, bytes memory reason) = address(gateway).call(abi.encodeWithSignature("noSuchFunction()"));

        assertFalse(success);
        assertEq(reason, abi.encodeWithSelector(INeverlandNativeGateway.FallbackNotAllowed.selector));
    }

    /// @notice An unknown selector carrying value also reverts
    function test_fallback_revertsWithAttachedValue() public {
        vm.prank(user);
        (bool success, bytes memory reason) =
            address(gateway).call{value: 1 ether}(abi.encodeWithSignature("noSuchFunction()"));

        assertFalse(success);
        assertEq(reason, abi.encodeWithSelector(INeverlandNativeGateway.FallbackNotAllowed.selector));
        assertEq(address(gateway).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice Any supplied value is credited in full to the beneficiary
    function testFuzz_supply_creditsFullValue(uint96 amount, address recipient) public {
        vm.assume(recipient != address(0));
        vm.deal(user, amount);

        vm.prank(user);
        gateway.supply{value: amount}(recipient, 0);

        assertEq(nToken.balanceOf(recipient), amount);
        assertEq(address(gateway).balance, 0);
    }

    /// @notice The caller is charged exactly the resolved repayment and refunded the rest
    function testFuzz_repay_chargesResolvedAmountOnly(uint96 debt, uint96 request, uint96 surplus) public {
        debt = uint96(bound(debt, 1, 1_000 ether));
        request = uint96(bound(request, 1, 1_000 ether));
        surplus = uint96(bound(surplus, 0, 100 ether));

        uint256 payback = request < debt ? request : debt;
        uint256 value = payback + surplus;

        variableDebt.mint(user, debt);
        vm.deal(user, value);

        vm.prank(user);
        gateway.repay{value: value}(request, VARIABLE_MODE, user);

        assertEq(user.balance, surplus);
        assertEq(variableDebt.balanceOf(user), debt - payback);
        assertEq(address(gateway).balance, 0);
        assertEq(wrapped.balanceOf(address(gateway)), 0);
    }

    /// @notice The maximum sentinel always drains the caller's whole nToken balance
    function testFuzz_withdraw_sentinelAlwaysDrains(uint96 balance) public {
        balance = uint96(bound(balance, 0, POOL_LIQUIDITY));
        _seedWithdrawable(user, balance);
        uint256 balanceBefore = user.balance;

        vm.prank(user);
        gateway.withdraw(type(uint256).max, user);

        assertEq(nToken.balanceOf(user), 0);
        assertEq(user.balance, balanceBefore + balance);
    }

    /// @notice Any value below the resolved repayment is rejected
    function testFuzz_repay_rejectsInsufficientValue(uint96 debt, uint96 shortfall) public {
        debt = uint96(bound(debt, 2, 1_000 ether));
        shortfall = uint96(bound(shortfall, 1, debt));
        uint256 value = debt - shortfall;

        variableDebt.mint(user, debt);
        vm.deal(user, value);

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandNativeGateway.InsufficientRepaymentValue.selector, value, debt)
        );

        vm.prank(user);
        gateway.repay{value: value}(type(uint256).max, VARIABLE_MODE, user);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gives an account nTokens and the gateway allowance a withdrawal needs
     * @param account The account to credit
     * @param amount The nToken amount to mint
     */
    function _seedWithdrawable(address account, uint256 amount) internal {
        nToken.mint(account, amount);

        vm.prank(account);
        nToken.approve(address(gateway), type(uint256).max);
    }

    /**
     * @notice Pays a recipient that re-enters the given entry point and asserts the guard rejected it
     * @dev The outer withdrawal must still complete, so the recipient keeps its payout.
     * @param target The gateway function the recipient attempts on the way back in
     */
    function _assertReentryRejected(ReentryTarget target) internal {
        MockReentrantReceiver receiver = new MockReentrantReceiver(INeverlandNativeGateway(payable(address(gateway))));
        _seedWithdrawable(user, 5 ether);
        receiver.arm(target);

        vm.prank(user);
        gateway.withdraw(2 ether, address(receiver));

        assertFalse(receiver.reentered());
        assertEq(bytes4(receiver.lastRevertReason()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(address(receiver).balance, 2 ether);
    }
}
