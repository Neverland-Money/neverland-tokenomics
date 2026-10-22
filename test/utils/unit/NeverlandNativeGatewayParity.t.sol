// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPool as IUpstreamPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {WrappedTokenGatewayV3} from "@aave-v3-periphery/contracts/misc/WrappedTokenGatewayV3.sol";
import {IPool} from "@neverland-money/lending-core/contracts/interfaces/IPool.sol";
import {IWETH} from "@neverland-money/lending-core/contracts/misc/interfaces/IWETH.sol";
import {Test} from "forge-std/Test.sol";

import {INeverlandNativeGateway} from "../../../src/interfaces/INeverlandNativeGateway.sol";

import {NeverlandNativeGateway} from "../../../src/utils/NeverlandNativeGateway.sol";

import {MockLendingPool, MockScaledToken, MockWrappedNative} from "../mocks/NativeGatewayMocks.sol";

/**
 * @title NeverlandNativeGatewayParityTest
 * @author Neverland
 * @notice Differential tests pinning the gateway against the upstream contract it was derived from
 * @dev Each gateway runs in its own world — its own wrapped token, pool, reserve tokens, and actor —
 *      so an identical operation on both can be compared state-for-state. Renaming, the dropped
 *      leading pool parameter, the newer compiler, and the different ownership library are all
 *      required to be invisible in the resulting state. Intended divergences are pinned as explicit
 *      expectations rather than allowed to pass silently.
 */
contract NeverlandNativeGatewayParityTest is Test {
    /// @dev Wrapped liquidity seeded into each world's pool.
    uint256 internal constant POOL_LIQUIDITY = 1_000 ether;

    /// @dev Starting native balance for each world's actor.
    uint256 internal constant ACTOR_FUNDING = 100 ether;

    /// @dev `DataTypes.InterestRateMode.STABLE`.
    uint256 internal constant STABLE_MODE = 1;

    /// @dev `DataTypes.InterestRateMode.VARIABLE`.
    uint256 internal constant VARIABLE_MODE = 2;

    struct World {
        MockWrappedNative wrapped;
        MockScaledToken nToken;
        MockScaledToken stableDebt;
        MockScaledToken variableDebt;
        MockLendingPool pool;
        address gateway;
        address actor;
        address beneficiary;
        bool upstream;
    }

    /// @dev The Neverland gateway and its isolated world.
    World internal ours;

    /// @dev The upstream gateway and its isolated world.
    World internal theirs;

    address internal owner = makeAddr("owner");

    function setUp() public {
        ours = _deployWorld("ours", false);
        theirs = _deployWorld("theirs", true);
    }

    /*//////////////////////////////////////////////////////////////
                            SHARED BEHAVIOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Supplying the native asset produces identical state on both gateways
    function test_parity_supply() public {
        _supply(ours, 3 ether, 7);
        _supply(theirs, 3 ether, 7);

        _assertParity();
    }

    /// @notice Our gateway reaches the same state through the pool's current entry point
    function test_parity_supply_usesDifferentPoolEntryPointForSameEffect() public {
        _supply(ours, 3 ether, 0);
        _supply(theirs, 3 ether, 0);

        assertEq(ours.pool.supplyCallCount(), 1);
        assertEq(ours.pool.depositCallCount(), 0);
        assertEq(theirs.pool.supplyCallCount(), 0);
        assertEq(theirs.pool.depositCallCount(), 1);

        _assertParity();
    }

    /// @notice An exact withdrawal produces identical state on both gateways
    function test_parity_withdraw_exactAmount() public {
        _seedWithdrawable(ours, 5 ether);
        _seedWithdrawable(theirs, 5 ether);

        _withdraw(ours, 2 ether);
        _withdraw(theirs, 2 ether);

        _assertParity();
    }

    /// @notice The maximum sentinel resolves identically on both gateways
    function test_parity_withdraw_maximumSentinel() public {
        _seedWithdrawable(ours, 5 ether);
        _seedWithdrawable(theirs, 5 ether);

        _withdraw(ours, type(uint256).max);
        _withdraw(theirs, type(uint256).max);

        _assertParity();
    }

    /// @notice An exact repayment produces identical state on both gateways
    function test_parity_repay_exactValue() public {
        _mintDebt(ours, VARIABLE_MODE, 4 ether);
        _mintDebt(theirs, VARIABLE_MODE, 4 ether);

        _repay(ours, 4 ether, VARIABLE_MODE, 4 ether);
        _repay(theirs, 4 ether, VARIABLE_MODE, 4 ether);

        _assertParity();
    }

    /// @notice A request above the outstanding debt caps identically on both gateways
    function test_parity_repay_cappedAtDebt() public {
        _mintDebt(ours, VARIABLE_MODE, 3 ether);
        _mintDebt(theirs, VARIABLE_MODE, 3 ether);

        _repay(ours, 5 ether, VARIABLE_MODE, 3 ether);
        _repay(theirs, 5 ether, VARIABLE_MODE, 3 ether);

        _assertParity();
    }

    /**
     * @notice A full repayment carrying surplus reaches identical state despite unequal pool arguments
     * @dev Upstream forwards `msg.value` and this gateway forwards the resolved amount. The pool caps
     *      at the outstanding debt, so the surplus is absorbed and both refund the same remainder.
     */
    function test_parity_repay_fullDebtWithSurplus() public {
        _mintDebt(ours, VARIABLE_MODE, 3 ether);
        _mintDebt(theirs, VARIABLE_MODE, 3 ether);

        _repay(ours, type(uint256).max, VARIABLE_MODE, 5 ether);
        _repay(theirs, type(uint256).max, VARIABLE_MODE, 5 ether);

        _assertStateParity();

        assertEq(ours.pool.lastAmount(), 3 ether, "we forward the resolved amount");
        assertEq(theirs.pool.lastAmount(), 5 ether, "upstream forwards the attached value");
    }

    /// @notice Stable-mode repayment resolves against the same debt token on both gateways
    function test_parity_repay_stableMode() public {
        _mintDebt(ours, STABLE_MODE, 6 ether);
        _mintDebt(theirs, STABLE_MODE, 6 ether);

        _repay(ours, type(uint256).max, STABLE_MODE, 6 ether);
        _repay(theirs, type(uint256).max, STABLE_MODE, 6 ether);

        _assertParity();
    }

    /// @notice Borrowing produces identical state on both gateways
    function test_parity_borrow() public {
        _borrow(ours, 3 ether, VARIABLE_MODE, 11);
        _borrow(theirs, 3 ether, VARIABLE_MODE, 11);

        _assertParity();
    }

    /// @notice The permit withdrawal path produces identical state on both gateways
    function test_parity_withdrawWithPermit() public {
        ours.nToken.mint(ours.actor, 5 ether);
        theirs.nToken.mint(theirs.actor, 5 ether);

        _withdrawWithPermit(ours, 2 ether);
        _withdrawWithPermit(theirs, 2 ether);

        _assertParity();
    }

    /// @notice Both gateways sign the permit over the requested amount, not the resolved balance
    function test_parity_withdrawWithPermit_signsOverRequestedAmount() public {
        ours.nToken.mint(ours.actor, 5 ether);
        theirs.nToken.mint(theirs.actor, 5 ether);

        _withdrawWithPermit(ours, type(uint256).max);
        _withdrawWithPermit(theirs, type(uint256).max);

        assertEq(ours.nToken.lastPermitValue(), type(uint256).max);
        assertEq(theirs.nToken.lastPermitValue(), type(uint256).max);

        _assertParity();
    }

    /// @notice Both gateways refuse the native asset from any sender but the wrapped token
    function test_parity_receive_refusesForeignSender() public {
        vm.deal(ours.actor, ACTOR_FUNDING);
        vm.deal(theirs.actor, ACTOR_FUNDING);

        vm.prank(ours.actor);
        (bool oursAccepted,) = ours.gateway.call{value: 1 ether}("");

        vm.prank(theirs.actor);
        (bool theirsAccepted,) = theirs.gateway.call{value: 1 ether}("");

        assertFalse(oursAccepted);
        assertFalse(theirsAccepted);
    }

    /// @notice Both gateways accept the native asset from their wrapped token
    function test_parity_receive_acceptsWrappedToken() public {
        vm.deal(address(ours.wrapped), 1 ether);
        vm.deal(address(theirs.wrapped), 1 ether);

        vm.prank(address(ours.wrapped));
        (bool oursAccepted,) = ours.gateway.call{value: 1 ether}("");

        vm.prank(address(theirs.wrapped));
        (bool theirsAccepted,) = theirs.gateway.call{value: 1 ether}("");

        assertTrue(oursAccepted);
        assertTrue(theirsAccepted);
        assertEq(ours.gateway.balance, theirs.gateway.balance);
    }

    /// @notice Both gateways reject unknown selectors
    function test_parity_fallback_rejectsUnknownSelector() public {
        (bool oursAccepted,) = ours.gateway.call(abi.encodeWithSignature("noSuchFunction()"));
        (bool theirsAccepted,) = theirs.gateway.call(abi.encodeWithSignature("noSuchFunction()"));

        assertFalse(oursAccepted);
        assertFalse(theirsAccepted);
    }

    /// @notice Owner-only native recovery behaves identically on both gateways
    function test_parity_emergencyNativeTransfer() public {
        vm.deal(ours.gateway, 4 ether);
        vm.deal(theirs.gateway, 4 ether);

        vm.prank(owner);
        INeverlandNativeGateway(ours.gateway).emergencyNativeTransfer(ours.beneficiary, 4 ether);

        vm.prank(owner);
        WrappedTokenGatewayV3(payable(theirs.gateway)).emergencyEtherTransfer(theirs.beneficiary, 4 ether);

        assertEq(ours.beneficiary.balance, theirs.beneficiary.balance);
        assertEq(ours.gateway.balance, theirs.gateway.balance);
    }

    /// @notice Native recovery is owner-gated on both gateways
    function test_parity_emergencyNativeTransfer_isOwnerGated() public {
        vm.deal(ours.gateway, 1 ether);
        vm.deal(theirs.gateway, 1 ether);

        vm.prank(ours.actor);
        (bool oursAccepted,) =
            ours.gateway.call(abi.encodeCall(INeverlandNativeGateway.emergencyNativeTransfer, (ours.actor, 1 ether)));

        vm.prank(theirs.actor);
        (bool theirsAccepted,) =
            theirs.gateway.call(abi.encodeCall(WrappedTokenGatewayV3.emergencyEtherTransfer, (theirs.actor, 1 ether)));

        assertFalse(oursAccepted);
        assertFalse(theirsAccepted);
    }

    /// @notice Both gateways expose the same wrapped token address, through differently named accessors
    function test_parity_wrappedTokenAccessor() public view {
        assertEq(address(INeverlandNativeGateway(ours.gateway).WRAPPED_NATIVE()), address(ours.wrapped));
        assertEq(WrappedTokenGatewayV3(payable(theirs.gateway)).getWETHAddress(), address(theirs.wrapped));
    }

    /*//////////////////////////////////////////////////////////////
                         INTENDED DIVERGENCES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice A partial repayment carrying surplus succeeds here and reverts upstream
     * @dev Upstream wraps only the resolved amount but asks the pool for `msg.value`, so the pool tries
     *      to pull more than the gateway holds. This is the sole state-visible behavioral divergence.
     */
    function test_divergence_repay_partialOverpayment() public {
        _mintDebt(ours, VARIABLE_MODE, 10 ether);
        _mintDebt(theirs, VARIABLE_MODE, 10 ether);

        _repay(ours, 4 ether, VARIABLE_MODE, 6 ether);

        assertEq(ours.variableDebt.balanceOf(ours.actor), 6 ether);
        assertEq(ours.actor.balance, ACTOR_FUNDING - 4 ether);

        vm.prank(theirs.actor);
        (bool upstreamSucceeded,) = theirs.gateway.call{value: 6 ether}(
            abi.encodeCall(
                WrappedTokenGatewayV3.repayETH, (address(theirs.pool), uint256(4 ether), VARIABLE_MODE, theirs.actor)
            )
        );

        assertFalse(upstreamSucceeded);
        assertEq(theirs.variableDebt.balanceOf(theirs.actor), 10 ether);
    }

    /// @notice Renouncing ownership is disabled here and permitted upstream
    function test_divergence_renounceOwnership() public {
        vm.prank(owner);
        (bool oursAccepted,) = ours.gateway.call(abi.encodeCall(INeverlandNativeGateway.renounceOwnership, ()));

        vm.prank(owner);
        WrappedTokenGatewayV3(payable(theirs.gateway)).renounceOwnership();

        assertFalse(oursAccepted);
        assertEq(NeverlandNativeGateway(payable(ours.gateway)).owner(), owner);
        assertEq(WrappedTokenGatewayV3(payable(theirs.gateway)).owner(), address(0));
    }

    /**
     * @notice A permit already consumed elsewhere is tolerated here and aborts the withdrawal upstream
     * @dev Upstream repeats the permit unconditionally, so a front-run that spends the nonce kills the
     *      call even though the allowance it would have set is already in place.
     */
    function test_divergence_withdrawWithPermit_consumedPermit() public {
        _seedWithdrawable(ours, 5 ether);
        _seedWithdrawable(theirs, 5 ether);
        ours.nToken.setRevertOnPermit(true);
        theirs.nToken.setRevertOnPermit(true);

        _withdrawWithPermit(ours, 2 ether);

        vm.prank(theirs.actor);
        (bool upstreamSucceeded,) = theirs.gateway
            .call(
                abi.encodeCall(
                    WrappedTokenGatewayV3.withdrawETHWithPermit,
                    (
                        address(theirs.pool),
                        2 ether,
                        theirs.actor,
                        block.timestamp + 1 days,
                        27,
                        bytes32("r"),
                        bytes32("s")
                    )
                )
            );

        assertEq(ours.nToken.balanceOf(ours.actor), 3 ether);
        assertFalse(upstreamSucceeded);
        assertEq(theirs.nToken.balanceOf(theirs.actor), 5 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice Any supply amount lands identically on both gateways
    function testFuzz_parity_supply(uint96 amount) public {
        amount = uint96(bound(amount, 0, ACTOR_FUNDING));

        _supply(ours, amount, 0);
        _supply(theirs, amount, 0);

        _assertParity();
    }

    /// @notice Any withdrawal lands identically on both gateways
    function testFuzz_parity_withdraw(uint96 balance, uint96 request) public {
        balance = uint96(bound(balance, 1, POOL_LIQUIDITY));
        request = uint96(bound(request, 0, balance));

        _seedWithdrawable(ours, balance);
        _seedWithdrawable(theirs, balance);

        _withdraw(ours, request);
        _withdraw(theirs, request);

        _assertParity();
    }

    /// @notice Any borrow lands identically on both gateways
    function testFuzz_parity_borrow(uint96 amount, uint16 referralCode) public {
        amount = uint96(bound(amount, 0, POOL_LIQUIDITY));

        _borrow(ours, amount, VARIABLE_MODE, referralCode);
        _borrow(theirs, amount, VARIABLE_MODE, referralCode);

        _assertParity();
    }

    /**
     * @notice Repayment matches upstream everywhere except a partially-requested overpayment
     * @dev The divergence condition is exactly `request < debt && value > request`: only then does
     *      upstream ask the pool for more than it wrapped. Everywhere else both must agree.
     */
    function testFuzz_parity_repay(uint96 debt, uint96 request, uint96 surplus) public {
        debt = uint96(bound(debt, 1, 500 ether));
        request = uint96(bound(request, 1, 500 ether));
        surplus = uint96(bound(surplus, 0, 50 ether));

        uint256 payback = request < debt ? request : debt;
        uint256 value = payback + surplus;
        vm.assume(value <= ACTOR_FUNDING);

        _mintDebt(ours, VARIABLE_MODE, debt);
        _mintDebt(theirs, VARIABLE_MODE, debt);

        bool oursSucceeded = _tryRepay(ours, request, VARIABLE_MODE, value);
        bool theirsSucceeded = _tryRepay(theirs, request, VARIABLE_MODE, value);

        assertTrue(oursSucceeded, "our repayment must always succeed");

        if (request < debt && value > request) {
            assertFalse(theirsSucceeded, "upstream must fail an overpaid partial repayment");
        } else {
            assertTrue(theirsSucceeded, "upstream must succeed everywhere else");
            _assertStateParity();

            if (value == payback) _assertPoolArgumentParity();
        }
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Builds one isolated world with its own tokens, pool, gateway, and actor
     * @param label Prefix for the generated actor addresses
     * @param upstream Whether the world's gateway is the upstream contract
     * @return world The assembled world
     */
    function _deployWorld(string memory label, bool upstream) internal returns (World memory world) {
        world.wrapped = new MockWrappedNative();
        world.nToken = new MockScaledToken();
        world.stableDebt = new MockScaledToken();
        world.variableDebt = new MockScaledToken();
        world.pool = new MockLendingPool(world.wrapped, world.nToken, world.stableDebt, world.variableDebt);
        world.upstream = upstream;

        world.gateway = upstream
            ? address(new WrappedTokenGatewayV3(address(world.wrapped), owner, IUpstreamPool(address(world.pool))))
            : address(new NeverlandNativeGateway(IWETH(address(world.wrapped)), IPool(address(world.pool)), owner));

        world.actor = makeAddr(string.concat(label, "-actor"));
        world.beneficiary = makeAddr(string.concat(label, "-beneficiary"));

        vm.deal(address(this), POOL_LIQUIDITY);
        world.wrapped.deposit{value: POOL_LIQUIDITY}();
        world.wrapped.transfer(address(world.pool), POOL_LIQUIDITY);

        vm.deal(world.actor, ACTOR_FUNDING);
    }

    /**
     * @notice Supplies the native asset through whichever gateway the world holds
     * @param world The world to act in
     * @param amount The native value to attach
     * @param referralCode The referral code to forward
     */
    function _supply(World storage world, uint256 amount, uint16 referralCode) internal {
        vm.prank(world.actor);

        if (world.upstream) {
            WrappedTokenGatewayV3(payable(world.gateway)).depositETH{value: amount}(
                address(world.pool), world.beneficiary, referralCode
            );
        } else {
            INeverlandNativeGateway(world.gateway).supply{value: amount}(world.beneficiary, referralCode);
        }
    }

    /**
     * @notice Withdraws to the world's actor through whichever gateway the world holds
     * @param world The world to act in
     * @param amount The requested amount, or the maximum sentinel
     */
    function _withdraw(World storage world, uint256 amount) internal {
        vm.prank(world.actor);

        if (world.upstream) {
            WrappedTokenGatewayV3(payable(world.gateway)).withdrawETH(address(world.pool), amount, world.actor);
        } else {
            INeverlandNativeGateway(world.gateway).withdraw(amount, world.actor);
        }
    }

    /**
     * @notice Withdraws through the permit path of whichever gateway the world holds
     * @param world The world to act in
     * @param amount The requested amount, or the maximum sentinel
     */
    function _withdrawWithPermit(World storage world, uint256 amount) internal {
        uint256 deadline = block.timestamp + 1 days;

        vm.prank(world.actor);

        if (world.upstream) {
            WrappedTokenGatewayV3(payable(world.gateway))
                .withdrawETHWithPermit(
                    address(world.pool), amount, world.actor, deadline, 27, bytes32("r"), bytes32("s")
                );
        } else {
            INeverlandNativeGateway(world.gateway)
                .withdrawWithPermit(amount, world.actor, deadline, 27, bytes32("r"), bytes32("s"));
        }
    }

    /**
     * @notice Borrows through whichever gateway the world holds
     * @param world The world to act in
     * @param amount The amount to borrow
     * @param rateMode The interest rate mode
     * @param referralCode The referral code to forward
     */
    function _borrow(World storage world, uint256 amount, uint256 rateMode, uint16 referralCode) internal {
        vm.prank(world.actor);

        if (world.upstream) {
            WrappedTokenGatewayV3(payable(world.gateway)).borrowETH(address(world.pool), amount, rateMode, referralCode);
        } else {
            INeverlandNativeGateway(world.gateway).borrow(amount, rateMode, referralCode);
        }
    }

    /**
     * @notice Repays through whichever gateway the world holds, bubbling any failure
     * @param world The world to act in
     * @param amount The requested repayment
     * @param rateMode The interest rate mode
     * @param value The native value to attach
     */
    function _repay(World storage world, uint256 amount, uint256 rateMode, uint256 value) internal {
        assertTrue(_tryRepay(world, amount, rateMode, value));
    }

    /**
     * @notice Repays through whichever gateway the world holds without bubbling a failure
     * @param world The world to act in
     * @param amount The requested repayment
     * @param rateMode The interest rate mode
     * @param value The native value to attach
     * @return succeeded Whether the call completed
     */
    function _tryRepay(World storage world, uint256 amount, uint256 rateMode, uint256 value)
        internal
        returns (bool succeeded)
    {
        bytes memory payload = world.upstream
            ? abi.encodeCall(WrappedTokenGatewayV3.repayETH, (address(world.pool), amount, rateMode, world.actor))
            : abi.encodeCall(INeverlandNativeGateway.repay, (amount, rateMode, world.actor));

        vm.prank(world.actor);
        (succeeded,) = world.gateway.call{value: value}(payload);
    }

    /**
     * @notice Gives the world's actor nTokens and the allowance a withdrawal needs
     * @param world The world to seed
     * @param amount The nToken amount to mint
     */
    function _seedWithdrawable(World storage world, uint256 amount) internal {
        world.nToken.mint(world.actor, amount);

        vm.prank(world.actor);
        world.nToken.approve(world.gateway, type(uint256).max);
    }

    /**
     * @notice Mints debt of the given mode to the world's actor
     * @param world The world to seed
     * @param rateMode The interest rate mode to mint against
     * @param amount The debt amount
     */
    function _mintDebt(World storage world, uint256 rateMode, uint256 amount) internal {
        if (rateMode == STABLE_MODE) {
            world.stableDebt.mint(world.actor, amount);
        } else {
            world.variableDebt.mint(world.actor, amount);
        }
    }

    /**
     * @notice Asserts both worlds hold identical state and received identical pool arguments
     * @dev Repayment paths that carry surplus value must use `_assertStateParity` instead, since
     *      upstream forwards `msg.value` where this gateway forwards the resolved amount.
     */
    function _assertParity() internal view {
        _assertStateParity();
        _assertPoolArgumentParity();
    }

    /// @notice Asserts the pool recorded the same arguments in both worlds
    function _assertPoolArgumentParity() internal view {
        assertEq(ours.pool.lastAmount(), theirs.pool.lastAmount(), "pool last amount");
        assertEq(ours.pool.lastRateMode(), theirs.pool.lastRateMode(), "pool last rate mode");
        assertEq(ours.pool.lastReferralCode(), theirs.pool.lastReferralCode(), "pool last referral code");
    }

    /// @notice Asserts both worlds hold structurally identical balances
    function _assertStateParity() internal view {
        assertEq(ours.actor.balance, theirs.actor.balance, "actor native");
        assertEq(ours.beneficiary.balance, theirs.beneficiary.balance, "beneficiary native");
        assertEq(ours.gateway.balance, theirs.gateway.balance, "gateway native");
        assertEq(ours.wrapped.balanceOf(ours.gateway), theirs.wrapped.balanceOf(theirs.gateway), "gateway wrapped");
        assertEq(
            ours.wrapped.balanceOf(address(ours.pool)), theirs.wrapped.balanceOf(address(theirs.pool)), "pool wrapped"
        );
        assertEq(ours.nToken.balanceOf(ours.actor), theirs.nToken.balanceOf(theirs.actor), "actor nToken");
        assertEq(
            ours.nToken.balanceOf(ours.beneficiary), theirs.nToken.balanceOf(theirs.beneficiary), "beneficiary nToken"
        );
        assertEq(ours.stableDebt.balanceOf(ours.actor), theirs.stableDebt.balanceOf(theirs.actor), "actor stable debt");
        assertEq(
            ours.variableDebt.balanceOf(ours.actor), theirs.variableDebt.balanceOf(theirs.actor), "actor variable debt"
        );
        assertEq(ours.pool.lastAsset(), address(ours.wrapped), "our pool asset");
        assertEq(theirs.pool.lastAsset(), address(theirs.wrapped), "their pool asset");
    }
}
