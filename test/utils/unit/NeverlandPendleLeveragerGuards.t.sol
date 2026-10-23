// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {ICreditDelegationToken} from "@neverland-money/lending-core/contracts/interfaces/ICreditDelegationToken.sol";
import {IPool} from "@neverland-money/lending-core/contracts/interfaces/IPool.sol";
import {IScaledBalanceToken} from "@neverland-money/lending-core/contracts/interfaces/IScaledBalanceToken.sol";
import {DataTypes} from "@neverland-money/lending-core/contracts/protocol/libraries/types/DataTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {INeverlandPendleLeverager as ILeverager} from "../../../src/interfaces/INeverlandPendleLeverager.sol";
import {IMorphoFlashLoanCallback} from "../../../src/interfaces/IMorphoFlashLoanCallback.sol";
import {IPendlePtLeverageRouter} from "../../../src/interfaces/IPendlePtLeverageRouter.sol";
import {IPendleRouterV4} from "../../../src/interfaces/IPendleRouterV4.sol";
import {NeverlandPendleLeverager} from "../../../src/utils/NeverlandPendleLeverager.sol";
import {PendleLeveragerUnitBase} from "../helpers/PendleLeveragerLendingBase.sol";
import {
    DishonestPendlePurchaseRouter,
    MaliciousPendleFlashPool,
    MaliciousPendleMorpho,
    MaliciousPendlePositionPool
} from "../mocks/PendleLeveragerMocks.sol";
import {
    MockAclManager,
    MockGatewayToken,
    MockPendleMarket,
    MockPendleRouter
} from "../mocks/PendleMaturityGatewayMocks.sol";

// Third party that repays a borrower's whole debt once, from inside a router call.
contract OneShotRepayer {
    bool public done;

    function repayOnce(IPool pool_, address asset, address onBehalfOf) external {
        if (done) return;
        done = true;
        IERC20(asset).approve(address(pool_), type(uint256).max);
        // An explicit amount above the debt: the pool rejects max when repaying for another account.
        pool_.repay(asset, 1_000e6, 2, onBehalfOf);
    }
}

// Lender that reports the requested amount but delivers one unit less.
contract ShortDeliveryMorpho {
    function flashLoan(address token, uint256 amount, bytes calldata data) external {
        IERC20(token).transfer(msg.sender, amount - 1);
        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(amount, data);
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }
}

// Forwards an arbitrary call so the callee observes a non-lender caller.
contract CallRelay {
    function forward(address target, bytes calldata data) external {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") { revert(add(ret, 0x20), mload(ret)) }
        }
    }
}

// Par Pendle router that pulls its input first, then makes a one-shot hook call before paying out.
contract HookAfterPullRouter {
    address public hookTarget;
    bytes public hookData;

    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
    }

    function swapExactTokenForPt(
        address receiver,
        address market,
        uint256 minPtOut,
        IPendleRouterV4.ApproxParams calldata,
        IPendleRouterV4.TokenInput calldata input,
        IPendleRouterV4.LimitOrderData calldata
    ) external returns (uint256, uint256, uint256) {
        IERC20(input.tokenIn).transferFrom(msg.sender, address(this), input.netTokenIn);
        callHook();
        (, address pt,) = MockPendleMarket(market).readTokens();
        require(input.netTokenIn >= minPtOut, "router: min out");
        MockGatewayToken(pt).mint(receiver, input.netTokenIn);

        return (input.netTokenIn, 0, 0);
    }

    function swapExactPtForToken(
        address receiver,
        address market,
        uint256 exactPtIn,
        IPendlePtLeverageRouter.TokenOutput calldata output,
        IPendleRouterV4.LimitOrderData calldata
    ) external returns (uint256, uint256, uint256) {
        (, address pt,) = MockPendleMarket(market).readTokens();
        IERC20(pt).transferFrom(msg.sender, address(this), exactPtIn);
        callHook();
        MockGatewayToken(output.tokenOut).mint(receiver, exactPtIn);

        return (exactPtIn, 0, 0);
    }

    function callHook() public {
        address target = hookTarget;
        if (target == address(0)) return;
        hookTarget = address(0);
        (bool ok, bytes memory ret) = target.call(hookData);
        if (!ok) {
            assembly ("memory-safe") { revert(add(ret, 0x20), mload(ret)) }
        }
    }
}

// Preserves ERC20 storage when etched over the cash token, and invokes a one-shot hook during approval.
contract HookOnApprovalToken is MockGatewayToken {
    HookAfterPullRouter internal immutable HOOK;
    address internal immutable CALLER;

    constructor(HookAfterPullRouter hook, address caller) MockGatewayToken("Approval hook", "HOOK") {
        HOOK = hook;
        CALLER = caller;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        if (msg.sender == CALLER && amount != 0) HOOK.callHook();

        return super.approve(spender, amount);
    }
}

// Replays one exact flash callback from the lender address after sending the receiver `funding`, and records the
// outcome; anything but a FlashCallbackUnauthorized rejection reverts, so a hook can never hide an accepted replay.
contract LenderCallbackReplayer {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error ReplayNotRejected(bytes outcome);

    bool public accepted;
    bytes public reason;

    function replay(address lender, address receiver, bytes calldata callback, address cash, uint256 funding) external {
        if (funding != 0) MockGatewayToken(cash).mint(receiver, funding);
        VM.prank(lender);
        (accepted, reason) = receiver.call(callback);
        if (
            accepted
                || keccak256(reason) != keccak256(abi.encodeWithSelector(ILeverager.FlashCallbackUnauthorized.selector))
        ) {
            revert ReplayNotRejected(reason);
        }
    }
}

// Guard, rounding, entry-binding, event and preview-envelope pins that the first suites leave to defense-in-depth.
contract NeverlandPendleLeveragerGuardsTest is PendleLeveragerUnitBase {
    // Selects no rewritten word in _roundContext.
    uint256 internal constant NO_REWRITE = type(uint256).max;

    // Grants aPT and debt delegation to another leverager; principal PT stays approved to the setUp leverager only.
    function _deployApproved(address lender, IPool flashPool_, address router_, address market_)
        internal
        returns (NeverlandPendleLeverager other)
    {
        other = _deploy(pool, lender, flashPool_, router_, market_);
        vm.startPrank(user);
        aNew.approve(address(other), type(uint256).max);
        ICreditDelegationToken(address(vDebt)).approveDelegation(address(other), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ debt and receipt exactness

    function test_positionPoolThatNeverOpensModeTwoDebtRejectsWithDebtMismatch() public {
        MaliciousPendlePositionPool evil = new MaliciousPendlePositionPool(address(pool));
        // Default mode 0 is a well-formed callback that never opens the mode-2 debt.
        NeverlandPendleLeverager viaEvil = _deploy(
            IPool(address(evil)), address(morpho), IPool(address(flashPool)), address(saleRouter), address(marketNew)
        );
        _create(100e6, 0);
        ausd.mint(address(evil), 50e6);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.DebtMismatch.selector, 0, 0));
        viaEvil.increaseLeverage(ILeverager.IncreaseParams(10e6, 0, 0, block.timestamp));
        assertEq(vDebt.balanceOf(user), 0);
        assertEq(aNew.balanceOf(user), 100e6);
        assertEq(ausd.balanceOf(address(evil)), 50e6);
        assertEq(ausd.balanceOf(address(viaEvil)), 0);
    }

    function test_repayThatMovesNoCashRejectsTheRound() public {
        _create(100e6, 100e6);
        _setMorphoCash(20e6);
        vm.mockCall(address(pool), abi.encodeWithSelector(IPool.repay.selector), abi.encode(uint256(0)));
        vm.prank(user);
        vm.expectRevert(ILeverager.InvalidAmount.selector);
        leverager.decreaseLeverage(_decrease(30e6, 20e6, 1));
        vm.clearMockedCalls();
        assertEq(vDebt.balanceOf(user), 100e6);
        assertEq(aNew.balanceOf(user), 200e6);
        assertEq(ausd.balanceOf(address(morpho)), 20e6);
    }

    function test_supplyThatDoesNotRaiseTheScaledBalanceByTheExactAmountRejects() public {
        ptNew.mint(user, 100e6);
        vm.mockCall(
            address(aNew),
            abi.encodeWithSelector(IScaledBalanceToken.scaledBalanceOf.selector, user),
            abi.encode(uint256(0))
        );
        vm.prank(user);
        vm.expectRevert(ILeverager.InvalidAmount.selector);
        leverager.createPosition(ILeverager.CreateParams(100e6, 0, 0, 0, block.timestamp));
        vm.clearMockedCalls();
        assertEq(ptNew.balanceOf(user), 100e6);
        assertEq(aNew.balanceOf(user), 0);
    }

    function test_receiptPullThatDoesNotRaiseTheScaledBalanceByTheExactAmountRejects() public {
        _create(100e6, 100e6);
        _setMorphoCash(20e6);
        vm.mockCall(
            address(aNew),
            abi.encodeWithSelector(IScaledBalanceToken.scaledBalanceOf.selector, address(leverager)),
            abi.encode(uint256(0))
        );
        vm.prank(user);
        vm.expectRevert(ILeverager.InvalidAmount.selector);
        leverager.decreaseLeverage(_decrease(30e6, 20e6, 1));
        vm.clearMockedCalls();
        assertEq(vDebt.balanceOf(user), 100e6);
        assertEq(aNew.balanceOf(user), 200e6);
    }

    function test_withdrawalThatLeavesTheScaledBalanceBehindRejects() public {
        _create(100e6, 100e6);
        _setMorphoCash(20e6);
        bytes[] memory reads = new bytes[](4);
        reads[0] = abi.encode(uint256(0)); // action entry snapshot
        reads[1] = abi.encode(uint256(0)); // before the receipt pull
        reads[2] = abi.encode(uint256(30e6)); // after the pull, exact
        // The last entry repeats: it answers the pool's own withdraw reads, then the post-withdrawal check sees the
        // receipt balance unreduced.
        reads[3] = abi.encode(uint256(30e6));
        vm.mockCalls(
            address(aNew),
            abi.encodeWithSelector(IScaledBalanceToken.scaledBalanceOf.selector, address(leverager)),
            reads
        );
        vm.prank(user);
        vm.expectRevert(ILeverager.InvalidAmount.selector);
        leverager.decreaseLeverage(_decrease(30e6, 20e6, 1));
        vm.clearMockedCalls();
        assertEq(vDebt.balanceOf(user), 100e6);
        assertEq(aNew.balanceOf(user), 200e6);
    }

    function test_debtClearedByAThirdPartyMidActionStillConvertsEveryAuthorizedPt() public {
        _create(100e6, 100e6);
        _setMorphoCash(40e6);
        OneShotRepayer repayer = new OneShotRepayer();
        ausd.mint(address(repayer), 1_000e6);
        saleRouter.setHook(address(repayer), abi.encodeCall(OneShotRepayer.repayOnce, (pool, address(ausd), user)));
        saleRouter.setMode(MockPendleRouter.Mode.REENTER_CLOSE);
        vm.prank(user);
        ILeverager.PositionResult memory result =
            leverager.decreaseLeverage(_decrease(type(uint256).max, type(uint256).max, 3));
        assertEq(result.rounds, 1, "debt cleared after the first non-final round");
        assertEq(result.cashRepaid, 33_333_334);
        assertEq(result.ptWithdrawn, 200e6);
        assertEq(result.debtAfter, 0);
        assertEq(aNew.balanceOf(user), 0, "every authorized PT converted");
        assertEq(result.surplus, 200e6 - 33_333_334);
        assertEq(ausd.balanceOf(user), 200e6 - 33_333_334);
        assertEq(ausd.balanceOf(address(leverager)), 0);
        assertEq(ausd.balanceOf(address(morpho)), 40e6);
    }

    // ------------------------------------------------------------------ events

    // A discounted PT price and elapsed interest keep every event word distinct, so a transposed argument fails.
    function _distinctFixture() internal {
        saleRouter.setPriceWad(0.8e18);
        _create(100e6, 40e6);
        vm.warp(block.timestamp + 30 days);
    }

    // Fails when two same-typed event words coincide, which would let a transposed argument still match.
    function _assertDistinct(uint256[] memory words) internal pure {
        for (uint256 i; i < words.length; ++i) {
            for (uint256 j = i + 1; j < words.length; ++j) {
                assertTrue(words[i] != words[j], "event words must differ");
            }
        }
    }

    function _assertSingleEvent(bytes32 signature) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(leverager) && logs[i].topics.length != 0 && logs[i].topics[0] == signature) {
                ++count;
            }
        }
        assertEq(count, 1, "summary event emitted exactly once");
    }

    function test_createEmitsPositionCreatedWithTheSettledDebt() public {
        _distinctFixture();
        ptNew.mint(user, 50e6);
        ILeverager.CreateParams memory params = ILeverager.CreateParams(50e6, 60e6, 0, 0, block.timestamp);
        vm.prank(user);
        ILeverager.PositionResult memory preview = leverager.previewCreatePosition(params);
        uint256[] memory words = new uint256[](4);
        (words[0], words[1], words[2], words[3]) = (50e6, preview.ptSupplied, 60e6, preview.debtAfter);
        _assertDistinct(words);
        vm.expectEmit(true, false, false, true, address(leverager));
        emit ILeverager.PositionCreated(user, 50e6, preview.ptSupplied, 60e6, preview.debtAfter);
        vm.recordLogs();
        vm.prank(user);
        leverager.createPosition(params);
        _assertSingleEvent(ILeverager.PositionCreated.selector);
    }

    function test_increaseEmitsLeverageIncreased() public {
        _distinctFixture();
        ILeverager.IncreaseParams memory params = ILeverager.IncreaseParams(30e6, 0, 0, block.timestamp);
        vm.prank(user);
        ILeverager.PositionResult memory preview = leverager.previewIncreaseLeverage(params);
        uint256[] memory words = new uint256[](3);
        (words[0], words[1], words[2]) = (preview.ptSupplied, 30e6, preview.debtAfter);
        _assertDistinct(words);
        vm.expectEmit(true, false, false, true, address(leverager));
        emit ILeverager.LeverageIncreased(user, preview.ptSupplied, 30e6, preview.debtAfter);
        vm.recordLogs();
        vm.prank(user);
        leverager.increaseLeverage(params);
        _assertSingleEvent(ILeverager.LeverageIncreased.selector);
    }

    function test_decreaseEmitsLeverageDecreased() public {
        _distinctFixture();
        saleRouter.setSalePriceWad(1.05e18);
        _setMorphoCash(10e6);
        ILeverager.DecreaseParams memory params = _decrease(30e6, 20e6, 3);
        vm.prank(user);
        ILeverager.PositionResult memory preview = leverager.previewDecreaseLeverage(params);
        assertEq(preview.rounds, 2);
        assertEq(preview.surplus, 11.5e6);
        uint256[] memory words = new uint256[](5);
        (words[0], words[1], words[2], words[3], words[4]) = (30e6, 20e6, preview.debtAfter, 11.5e6, 2);
        _assertDistinct(words);
        vm.expectEmit(true, false, false, true, address(leverager));
        emit ILeverager.LeverageDecreased(user, 30e6, 20e6, preview.debtAfter, 11.5e6, 2);
        vm.recordLogs();
        vm.prank(user);
        leverager.decreaseLeverage(params);
        _assertSingleEvent(ILeverager.LeverageDecreased.selector);
    }

    function test_recoveryEmitsERC20Recovered() public {
        ausd.mint(address(leverager), 100);
        // Distinct token and recipient topics, so swapping them cannot match.
        assertNotEq(address(ausd), user);
        vm.expectEmit(true, true, false, true, address(leverager));
        emit ILeverager.ERC20Recovered(address(ausd), user, 100);
        vm.recordLogs();
        vm.prank(owner);
        leverager.emergencyTokenTransfer(address(ausd), user, 100);
        _assertSingleEvent(ILeverager.ERC20Recovered.selector);
    }

    // ------------------------------------------------------------------ health factor

    function test_implicitUnitHealthFloorRejectsAnUnderwaterTopUpWithAZeroMinimum() public {
        _create(100e6, 100e6);
        ptNewFeed.setAnswer(0.5e8);
        ptNew.mint(user, 1e6);
        vm.prank(user);
        // 201e6 PT at 0.5 with a 96% threshold against 100e6 debt is 0.9648, below the implicit unit floor.
        vm.expectRevert(abi.encodeWithSelector(ILeverager.HealthFactorBelowMinimum.selector, 0.9648e18, 1e18));
        leverager.createPosition(ILeverager.CreateParams(1e6, 0, 0, 0, block.timestamp));
        assertEq(ptNew.balanceOf(user), 1e6);
    }

    function test_createHonorsTheCallerMinimumHealthFactor() public {
        ptNew.mint(user, 100e6);
        vm.prank(user);
        // 200e6 PT at 0.988 with a 96% threshold against 100e6 debt is 1.89696, below the 5.0 caller minimum.
        vm.expectRevert(abi.encodeWithSelector(ILeverager.HealthFactorBelowMinimum.selector, 1.89696e18, 5e18));
        leverager.createPosition(ILeverager.CreateParams(100e6, 100e6, 0, 5e18, block.timestamp));
        assertEq(ptNew.balanceOf(user), 100e6);
        assertEq(vDebt.balanceOf(user), 0);
    }

    function test_finalHealthFactorExactlyAtTheCallerMinimumPasses() public {
        _create(100e6, 0);
        vm.prank(user);
        uint256 exact =
            leverager.previewIncreaseLeverage(ILeverager.IncreaseParams(100e6, 0, 0, block.timestamp)).healthFactorAfter;
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.HealthFactorBelowMinimum.selector, exact, exact + 1));
        leverager.increaseLeverage(ILeverager.IncreaseParams(100e6, 0, exact + 1, block.timestamp));
        vm.prank(user);
        assertEq(
            leverager.increaseLeverage(ILeverager.IncreaseParams(100e6, 0, exact, block.timestamp)).healthFactorAfter,
            exact
        );
    }

    // ------------------------------------------------------------------ oracle floor rounding (ceil)

    function test_purchaseOracleFloorRoundsUpAtANonDivisibleBoundary() public {
        DishonestPendlePurchaseRouter dishonest = new DishonestPendlePurchaseRouter();
        NeverlandPendleLeverager other =
            _deployApproved(address(morpho), IPool(address(flashPool)), address(dishonest), address(marketNew));
        _create(100e6, 0);
        ptNewFeed.setAnswer(0.8e8);
        vm.prank(user);
        ICreditDelegationToken(address(vDebt)).approveDelegation(address(other), 100_000_001);
        // 100_000_001 * 1.125 = 112_500_001.125, so the rounded-up minimum is 112_500_002.
        dishonest.setOutput(112_500_001);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.OutputBelowMinimum.selector, 112_500_001, 112_500_002));
        other.increaseLeverage(ILeverager.IncreaseParams(100_000_001, 0, 0, block.timestamp));
        dishonest.setOutput(112_500_002);
        vm.prank(user);
        assertEq(
            other.increaseLeverage(ILeverager.IncreaseParams(100_000_001, 0, 0, block.timestamp)).ptSupplied,
            112_500_002
        );
    }

    function test_saleOracleFloorRoundsUpAtANonDivisibleBoundary() public {
        _create(100e6, 100e6);
        _setMorphoCash(20e6);
        // 30_000_001 * 0.988 * 0.9 = 26_676_000.8892, so the rounded-up minimum is 26_676_001.
        uint256 pt = 30_000_001;
        uint256 minimum = 26_676_001;
        uint256 price = ((minimum - 1) * 1e18 + pt - 1) / pt;
        assertEq(pt * price / 1e18, minimum - 1, "fixture lands one below the floor");
        saleRouter.setSalePriceWad(price);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.OutputBelowMinimum.selector, minimum - 1, minimum));
        leverager.decreaseLeverage(_decrease(pt, 20e6, 1));
        price = (minimum * 1e18 + pt - 1) / pt;
        assertEq(pt * price / 1e18, minimum, "fixture lands on the floor");
        saleRouter.setSalePriceWad(price);
        vm.prank(user);
        assertEq(leverager.decreaseLeverage(_decrease(pt, 20e6, 1)).surplus, minimum - 20e6);
    }

    // ------------------------------------------------------------------ bounded work

    function test_optionalExternalPoolReadIsCappedAtItsGasAllowance() public {
        // A single INVALID opcode burns every unit of gas it is forwarded.
        address burner = makeAddr("gas burning external pool");
        vm.etch(burner, hex"fe");
        NeverlandPendleLeverager other =
            _deployApproved(address(morpho), IPool(burner), address(saleRouter), address(marketNew));
        _setMorphoCash(10e6);
        uint256 before = gasleft();
        (address source, uint256 cash) = other.flashCapacity{gas: 5_000_000}();
        uint256 used = before - gasleft();
        assertEq(source, address(morpho));
        assertEq(cash, 10e6);
        assertLt(used, 1_000_000, "the optional read is capped at 500k gas, not the 5M forwarded");
    }

    function test_everyOptionalExternalPoolReadFailsSoftToMorphoWhileTheStrictGetterReverts() public {
        _setMorphoCash(10e6);
        flashPool.seed(supplier, 30e6);
        MockAclManager acl_ = flashPool.ACL();
        acl_.setFlashBorrower(address(leverager), true);
        (address source, uint256 cash) = leverager.flashCapacity();
        assertEq(source, address(flashPool), "the pool is the larger eligible lender before any read fails");
        assertEq(cash, 30e6);
        address aToken = address(flashPool.A_TOKEN());
        address flashProvider = flashPool.ADDRESSES_PROVIDER();
        address[6] memory targets =
            [address(flashPool), address(flashPool), flashProvider, address(acl_), address(ausd), aToken];
        bytes[6] memory calls = [
            abi.encodeWithSelector(IPool.getReserveData.selector, address(ausd)),
            abi.encodeWithSignature("ADDRESSES_PROVIDER()"),
            abi.encodeWithSignature("getACLManager()"),
            abi.encodeWithSignature("isFlashBorrower(address)", address(leverager)),
            abi.encodeWithSignature("balanceOf(address)", aToken),
            abi.encodeWithSignature("totalSupply()")
        ];
        for (uint256 i; i < targets.length; ++i) {
            vm.mockCallRevert(targets[i], calls[i], bytes("offline"));
            (source, cash) = leverager.flashCapacity();
            assertEq(source, address(morpho), "a failing optional read excludes the pool");
            assertEq(cash, 10e6);
            vm.expectRevert(bytes("offline"));
            leverager.flashPoolCapacity();
            vm.clearMockedCalls();
        }
    }

    function test_decreaseWithoutExternalCashRejectsWithTheCustomErrorBeforeAnyMovement() public {
        _create(100e6, 100e6);
        _setMorphoCash(0);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.InsufficientFlashLiquidity.selector, 100e6, 0));
        leverager.decreaseLeverage(_decrease(200e6, type(uint256).max, 3));
        assertEq(morpho.flashLoanCount(), 0);
        assertEq(flashPool.flashLoanCount(), 0);
        assertEq(vDebt.balanceOf(user), 100e6);
        assertEq(aNew.balanceOf(user), 200e6);
    }

    function test_twoFlashesCanCompleteWithDirectSettlement() public {
        _create(100e6, 100e6);
        _setMorphoCash(40e6);
        vm.prank(user);
        ILeverager.PositionResult memory result = leverager.decreaseLeverage(_decrease(200e6, type(uint256).max, 2));
        assertEq(result.rounds, 2);
        assertEq(morpho.flashLoanCount(), 2);
        assertEq(vDebt.balanceOf(user), 0);
    }

    function test_repayBudgetAboveLiveDebtIsCappedBeforeTheRoundLimit() public {
        _create(100e6, 100e6);
        _setMorphoCash(40e6);
        vm.prank(user);
        ILeverager.PositionResult memory result = leverager.decreaseLeverage(_decrease(200e6, 1_000e6, 3));
        assertEq(result.cashRepaid, 100e6);
        assertEq(result.debtAfter, 0);
        assertEq(result.rounds, 2);
    }

    // ------------------------------------------------------------------ entry bindings and expiry

    function test_marketThatRebindsItsTokensAfterDeploymentRejectsEntry() public {
        ptNew.mint(user, 100e6);
        for (uint256 i; i < 3; ++i) {
            address sy_ = i == 0 ? makeAddr("other sy") : address(syNew);
            address pt_ = i == 1 ? makeAddr("other pt") : address(ptNew);
            address yt_ = i == 2 ? makeAddr("other yt") : address(ytNew);
            vm.mockCall(address(marketNew), abi.encodeWithSignature("readTokens()"), abi.encode(sy_, pt_, yt_));
            vm.prank(user);
            vm.expectRevert(abi.encodeWithSelector(ILeverager.InvalidMarket.selector, address(marketNew)));
            leverager.createPosition(ILeverager.CreateParams(100e6, 0, 0, 0, block.timestamp));
            vm.clearMockedCalls();
        }
        assertEq(ptNew.balanceOf(user), 100e6);
    }

    function test_reserveRelistedWithAnotherReceiptTokenRejectsEntry() public {
        ptNew.mint(user, 100e6);
        DataTypes.ReserveData memory reserve = pool.getReserveData(address(ptNew));
        reserve.aTokenAddress = makeAddr("other aPT");
        vm.mockCall(
            address(pool), abi.encodeWithSelector(IPool.getReserveData.selector, address(ptNew)), abi.encode(reserve)
        );
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.InvalidMarket.selector, address(marketNew)));
        leverager.createPosition(ILeverager.CreateParams(100e6, 0, 0, 0, block.timestamp));
        vm.clearMockedCalls();
        assertEq(ptNew.balanceOf(user), 100e6);
    }

    function test_unleveragedCreateAtExpiryRejectsAtomically() public {
        ptNew.mint(user, 100e6);
        ptNew.setExpired(true);
        vm.prank(user);
        vm.expectRevert(ILeverager.MarketExpired.selector);
        leverager.createPosition(ILeverager.CreateParams(100e6, 0, 0, 0, block.timestamp));
        assertEq(ptNew.balanceOf(user), 100e6);
        assertEq(aNew.balanceOf(user), 0);
    }

    function test_eitherExpiryFlagAloneRejectsTheDecrease() public {
        _create(100e6, 100e6);
        _setMorphoCash(100e6);
        for (uint256 flag; flag < 2; ++flag) {
            uint256 snapshot = vm.snapshotState();
            // Only one of the PT and market flags is set.
            if (flag == 0) ptNew.setExpired(true);
            else marketNew.setExpired(true);
            vm.prank(user);
            vm.expectRevert(ILeverager.MarketExpired.selector);
            leverager.decreaseLeverage(_decrease(200e6, type(uint256).max, 1));
            assertEq(vDebt.balanceOf(user), 100e6);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    // ------------------------------------------------------------------ counterparties and custody

    function test_lenderThatDeliversLessThanItReportedRejects() public {
        ShortDeliveryMorpho shortLender = new ShortDeliveryMorpho();
        NeverlandPendleLeverager other =
            _deployApproved(address(shortLender), IPool(address(flashPool)), address(saleRouter), address(marketNew));
        _create(100e6, 100e6);
        ausd.mint(address(shortLender), 50e6);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.BalanceMismatch.selector, address(ausd), 20e6, 20e6 - 1));
        other.decreaseLeverage(_decrease(30e6, 20e6, 1));
        assertEq(vDebt.balanceOf(user), 100e6);
        assertEq(aNew.balanceOf(user), 200e6);
    }

    // Context a one-round 20e6 cash, 30e6 PT decrease commits from an empty balance; `word` 0 rewrites the user to
    // `victim`, 2 the PT amount, 3 the entry balance and 4 the PT minimum, and any other value rewrites nothing.
    function _roundContext(uint256 word, address victim) internal view returns (bytes memory) {
        return abi.encode(
            word == 0 ? victim : user,
            uint256(20e6),
            word == 2 ? uint256(30e6) + 1 : uint256(30e6),
            word == 3 ? uint256(1) : uint256(0),
            word == 4 ? uint256(1) : uint256(0)
        );
    }

    // Pool flash callback, exactly as the lending core sends it, for a round of `cash` carrying `ctx`.
    function _poolCallback(NeverlandPendleLeverager other, uint256 cash, bytes memory ctx)
        internal
        view
        returns (bytes memory)
    {
        address[] memory assets = new address[](1);
        assets[0] = address(ausd);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = cash;

        return abi.encodeCall(other.executeOperation, (assets, amounts, new uint256[](1), address(other), ctx));
    }

    function _victimWithPosition() internal returns (address victim) {
        victim = makeAddr("victim with an open position");
        ptNew.mint(victim, 100e6);
        vm.startPrank(victim);
        IERC20(address(ptNew)).approve(address(leverager), type(uint256).max);
        ICreditDelegationToken(address(vDebt)).approveDelegation(address(leverager), type(uint256).max);
        leverager.createPosition(ILeverager.CreateParams(100e6, 100e6, 0, 0, block.timestamp));
        vm.stopPrank();
    }

    function test_nonLenderCannotRunTheMorphoCallbackDuringAnActiveRound() public {
        MaliciousPendleMorpho evil = new MaliciousPendleMorpho();
        NeverlandPendleLeverager other =
            _deployApproved(address(evil), IPool(address(flashPool)), address(saleRouter), address(marketNew));
        _create(100e6, 100e6);
        ausd.mint(address(evil), 20e6);
        CallRelay relay = new CallRelay();
        bytes memory callback = abi.encodeCall(other.onMorphoFlashLoan, (20e6, _roundContext(NO_REWRITE, user)));
        evil.setMode(1); // the lender never calls back itself
        evil.setHook(address(relay), abi.encodeCall(relay.forward, (address(other), callback)));
        vm.prank(user);
        vm.expectRevert(ILeverager.FlashCallbackUnauthorized.selector);
        other.decreaseLeverage(_decrease(30e6, 20e6, 1));
        assertEq(vDebt.balanceOf(user), 100e6);
        assertEq(aNew.balanceOf(user), 200e6);
    }

    function test_nonLenderCannotRunThePoolCallbackDuringAnActiveRound() public {
        MaliciousPendleFlashPool hooked = new MaliciousPendleFlashPool(address(ausd));
        NeverlandPendleLeverager other =
            _deployApproved(address(morpho), IPool(address(hooked)), address(saleRouter), address(marketNew));
        hooked.seed(50e6);
        hooked.ACL().setFlashBorrower(address(other), true);
        _setMorphoCash(0);
        _create(100e6, 100e6);
        CallRelay relay = new CallRelay();
        bytes memory callback = _poolCallback(other, 20e6, _roundContext(NO_REWRITE, user));
        hooked.setMode(7); // the pool never calls back itself
        hooked.setHook(address(relay), abi.encodeCall(relay.forward, (address(other), callback)));
        vm.prank(user);
        vm.expectRevert(ILeverager.FlashCallbackUnauthorized.selector);
        other.decreaseLeverage(_decrease(30e6, 20e6, 1));
        assertEq(vDebt.balanceOf(user), 100e6);
        assertEq(aNew.balanceOf(user), 200e6);
    }

    function test_lenderThatRewritesAnyRoundWordIsRejectedThroughMorpho() public {
        address victim = _victimWithPosition();
        _create(100e6, 100e6);
        for (uint256 word; word < 5; ++word) {
            if (word == 1) continue; // the cash word is also bound to the reported amount
            MaliciousPendleMorpho evil = new MaliciousPendleMorpho();
            NeverlandPendleLeverager other =
                _deployApproved(address(evil), IPool(address(flashPool)), address(saleRouter), address(marketNew));
            vm.prank(victim);
            aNew.approve(address(other), type(uint256).max);
            ausd.mint(address(evil), 20e6);
            evil.setMode(1); // the lender never calls back itself
            evil.setHook(address(other), abi.encodeCall(other.onMorphoFlashLoan, (20e6, _roundContext(word, victim))));
            vm.prank(user);
            vm.expectRevert(ILeverager.FlashCallbackUnauthorized.selector);
            other.decreaseLeverage(_decrease(30e6, 20e6, 1));
            assertEq(vDebt.balanceOf(victim), 100e6);
            assertEq(aNew.balanceOf(victim), 200e6);
        }
    }

    function test_lenderThatRewritesAnyRoundWordIsRejectedThroughTheExternalPool() public {
        address victim = _victimWithPosition();
        _create(100e6, 100e6);
        _setMorphoCash(0);
        for (uint256 word; word < 5; ++word) {
            if (word == 1) continue; // the cash word is also bound to the reported amount
            MaliciousPendleFlashPool hooked = new MaliciousPendleFlashPool(address(ausd));
            NeverlandPendleLeverager other =
                _deployApproved(address(morpho), IPool(address(hooked)), address(saleRouter), address(marketNew));
            hooked.seed(50e6);
            hooked.ACL().setFlashBorrower(address(other), true);
            vm.prank(victim);
            aNew.approve(address(other), type(uint256).max);
            hooked.setMode(7); // the pool never calls back itself
            hooked.setHook(address(other), _poolCallback(other, 20e6, _roundContext(word, victim)));
            vm.prank(user);
            vm.expectRevert(ILeverager.FlashCallbackUnauthorized.selector);
            other.decreaseLeverage(_decrease(30e6, 20e6, 1));
            assertEq(vDebt.balanceOf(victim), 100e6);
            assertEq(aNew.balanceOf(victim), 200e6);
        }
    }

    function test_ownerControlledRouterCannotReenterRecoveryMidAction() public {
        // The router is the owner here, so only the reentrancy guard stands between a hooked purchase and recovery.
        NeverlandPendleLeverager other = new NeverlandPendleLeverager(
            pool,
            address(ausd),
            address(morpho),
            IPool(address(flashPool)),
            address(saleRouter),
            address(marketNew),
            address(saleRouter)
        );
        vm.startPrank(user);
        IERC20(address(ptNew)).approve(address(other), type(uint256).max);
        ICreditDelegationToken(address(vDebt)).approveDelegation(address(other), type(uint256).max);
        vm.stopPrank();
        ptNew.mint(user, 100e6);
        vm.prank(user);
        other.createPosition(ILeverager.CreateParams(100e6, 0, 0, 0, block.timestamp));
        ausd.mint(address(other), 5);
        saleRouter.setHook(address(other), abi.encodeCall(other.emergencyTokenTransfer, (address(ausd), user, 5)));
        saleRouter.setMode(MockPendleRouter.Mode.REENTER_CLOSE);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        other.increaseLeverage(ILeverager.IncreaseParams(10e6, 0, 0, block.timestamp));
        assertEq(ausd.balanceOf(address(other)), 5);
        assertEq(vDebt.balanceOf(user), 0);
    }

    function test_purchaseRouterCannotPullBeyondTheExactApproval() public {
        _create(100e6, 0);
        saleRouter.setMode(MockPendleRouter.Mode.PULL_EXTRA);
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientAllowance(address,uint256,uint256)", address(saleRouter), 10e6, 10e6 + 1
            )
        );
        leverager.increaseLeverage(ILeverager.IncreaseParams(10e6, 0, 0, block.timestamp));
        assertEq(vDebt.balanceOf(user), 0);
    }

    function test_syDonatedDuringAPurchaseFailsTheFinalCustodyCheck() public {
        _create(100e6, 0);
        saleRouter.setHook(address(syNew), abi.encodeCall(MockGatewayToken.mint, (address(leverager), 1)));
        saleRouter.setMode(MockPendleRouter.Mode.REENTER_CLOSE);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ILeverager.BalanceMismatch.selector, address(syNew), 0, 1));
        leverager.increaseLeverage(ILeverager.IncreaseParams(10e6, 0, 0, block.timestamp));
        assertEq(vDebt.balanceOf(user), 0);
        assertEq(aNew.balanceOf(user), 100e6);
    }

    function test_purchaseUsesTheTypedDirectRouteWithFixedApproximationConstants() public {
        _create(100e6, 0);
        vm.prank(user);
        leverager.increaseLeverage(ILeverager.IncreaseParams(40e6, 0, 0, block.timestamp));
        assertEq(saleRouter.swapCount(), 1);
        assertEq(saleRouter.lastReceiver(), address(leverager));
        assertEq(saleRouter.lastMarket(), address(marketNew));
        assertEq(saleRouter.lastTokenIn(), address(ausd));
        assertEq(saleRouter.lastNetTokenIn(), 40e6);
        assertEq(saleRouter.lastTokenMintSy(), address(ausd));
        assertEq(saleRouter.lastPendleSwap(), address(0));
        assertEq(uint8(saleRouter.lastSwapType()), uint8(IPendleRouterV4.SwapType.NONE));
        IPendleRouterV4.ApproxParams memory approx = saleRouter.lastApprox();
        assertEq(approx.guessMin, 0);
        assertEq(approx.guessMax, type(uint256).max);
        assertEq(approx.guessOffchain, 0);
        assertEq(approx.maxIteration, 256);
        assertEq(approx.eps, 5e13);
    }

    // ------------------------------------------------------------------ consume-once ordering

    // A leverager whose router lets `replayer` replay a flash callback after the router has pulled its input.
    function _replayFixture()
        internal
        returns (NeverlandPendleLeverager other, HookAfterPullRouter router_, LenderCallbackReplayer replayer)
    {
        router_ = new HookAfterPullRouter();
        other = _deployApproved(address(morpho), IPool(address(flashPool)), address(router_), address(marketNew));
        replayer = new LenderCallbackReplayer();
    }

    // Mode-2 callback of a 10e6 purchase from an empty balance, committing the contract's purchase minimum: the larger
    // of the rounded-up 90% oracle floor and the par floor, so the replayed payload stays exact if fixture prices move.
    function _purchaseCallback(NeverlandPendleLeverager other) internal view returns (bytes memory) {
        uint256 ptPrice = oracle.getAssetPrice(address(ptNew)) * 10_000;
        uint256 oracleFloor = (10e6 * oracle.getAssetPrice(address(ausd)) * 9_000 + ptPrice - 1) / ptPrice;
        uint256 parFloor = 10e6 - 10e6 / 10_000;
        uint256 minimum = oracleFloor > parFloor ? oracleFloor : parFloor;

        return _poolCallback(other, 10e6, abi.encode(user, uint256(10e6), uint256(0), uint256(0), minimum));
    }

    // Leverager custody and allowances are empty after an action.
    function _assertNoCustody(NeverlandPendleLeverager other, address router_) internal view {
        assertEq(ausd.balanceOf(address(other)), 0);
        assertEq(ptNew.balanceOf(address(other)), 0);
        assertEq(syNew.balanceOf(address(other)), 0);
        assertEq(aNew.balanceOf(address(other)), 0);
        assertEq(ausd.allowance(address(other), address(pool)), 0);
        assertEq(ausd.allowance(address(other), router_), 0);
        assertEq(ausd.allowance(address(other), address(morpho)), 0);
        assertEq(ptNew.allowance(address(other), address(pool)), 0);
        assertEq(ptNew.allowance(address(other), router_), 0);
    }

    function test_positionPoolReplayDuringThePurchaseIsRejectedAndTheIncreaseRunsOnce() public {
        (NeverlandPendleLeverager other, HookAfterPullRouter router_, LenderCallbackReplayer replayer) =
            _replayFixture();
        _create(100e6, 0);
        bytes memory callback = _purchaseCallback(other);
        router_.setHook(
            address(replayer),
            abi.encodeCall(replayer.replay, (address(pool), address(other), callback, address(ausd), 0))
        );
        vm.prank(user);
        ILeverager.PositionResult memory result =
            other.increaseLeverage(ILeverager.IncreaseParams(10e6, 0, 0, block.timestamp));
        // The callback consumed its authorization before calling the router, so the exact pool replay is rejected.
        assertFalse(replayer.accepted());
        assertEq(replayer.reason(), abi.encodeWithSelector(ILeverager.FlashCallbackUnauthorized.selector));
        assertEq(result.ptSupplied, 10e6);
        assertEq(result.debtAfter, 10e6);
        assertEq(aNew.balanceOf(user), 110e6, "collateral supplied once");
        assertEq(vDebt.balanceOf(user), 10e6);
        _assertNoCustody(other, address(router_));
    }

    function test_morphoReplayDuringRepaymentApprovalIsRejectedAndTheRoundRunsOnce() public {
        (NeverlandPendleLeverager other, HookAfterPullRouter router_, LenderCallbackReplayer replayer) =
            _replayFixture();
        _create(100e6, 100e6);
        _setMorphoCash(20e6);
        bytes memory callback = abi.encodeCall(other.onMorphoFlashLoan, (20e6, _roundContext(NO_REWRITE, user)));
        router_.setHook(
            address(replayer),
            abi.encodeCall(replayer.replay, (address(morpho), address(other), callback, address(ausd), 0))
        );
        HookOnApprovalToken hooked = new HookOnApprovalToken(router_, address(other));
        vm.etch(address(ausd), address(hooked).code);
        vm.prank(user);
        ILeverager.PositionResult memory result = other.decreaseLeverage(_decrease(30e6, 20e6, 1));
        assertFalse(replayer.accepted());
        assertEq(replayer.reason(), abi.encodeWithSelector(ILeverager.FlashCallbackUnauthorized.selector));
        assertEq(result.rounds, 1);
        assertEq(result.cashRepaid, 20e6);
        assertEq(result.debtAfter, 80e6);
        assertEq(result.surplus, 10e6);
        assertEq(aNew.balanceOf(user), 170e6);
        assertEq(morpho.flashLoanCount(), 1);
        _assertNoCustody(other, address(router_));
    }

    function test_morphoReplayDuringTheSaleIsRejectedAndTheRoundRunsOnce() public {
        (NeverlandPendleLeverager other, HookAfterPullRouter router_, LenderCallbackReplayer replayer) =
            _replayFixture();
        _create(100e6, 100e6);
        _setMorphoCash(20e6);
        bytes memory callback = abi.encodeCall(other.onMorphoFlashLoan, (20e6, _roundContext(NO_REWRITE, user)));
        router_.setHook(
            address(replayer),
            abi.encodeCall(replayer.replay, (address(morpho), address(other), callback, address(ausd), 0))
        );
        vm.prank(user);
        ILeverager.PositionResult memory result = other.decreaseLeverage(_decrease(30e6, 20e6, 1));
        // The exact Morpho replay is rejected at the sale boundary.
        assertFalse(replayer.accepted());
        assertEq(replayer.reason(), abi.encodeWithSelector(ILeverager.FlashCallbackUnauthorized.selector));
        assertEq(result.rounds, 1);
        assertEq(result.ptWithdrawn, 30e6);
        assertEq(result.cashRepaid, 20e6);
        assertEq(result.debtAfter, 80e6);
        assertEq(result.surplus, 10e6);
        assertEq(aNew.balanceOf(user), 170e6, "collateral withdrawn once");
        assertEq(vDebt.balanceOf(user), 80e6, "debt repaid once");
        assertEq(ausd.balanceOf(user), 10e6);
        assertEq(ausd.balanceOf(address(morpho)), 20e6, "lender repaid exactly once");
        assertEq(morpho.flashLoanCount(), 1);
        _assertNoCustody(other, address(router_));
    }

    function test_fundedPoolReplayDuringThePurchaseRevertsTheIncreaseAtomically() public {
        (NeverlandPendleLeverager other, HookAfterPullRouter router_, LenderCallbackReplayer replayer) =
            _replayFixture();
        _create(100e6, 0);
        bytes memory callback = _purchaseCallback(other);
        // The replayer first sends the round's cash, so only the consumed authorization stops a second purchase; the
        // replayer itself reverts unless the replay is rejected as unauthorized.
        router_.setHook(
            address(replayer),
            abi.encodeCall(replayer.replay, (address(pool), address(other), callback, address(ausd), 10e6))
        );
        vm.prank(user);
        // The rejected replay leaves its 10e6 behind, so the purchase's exact-spend check reverts the whole action.
        vm.expectRevert(abi.encodeWithSelector(ILeverager.BalanceMismatch.selector, address(ausd), 0, 10e6));
        other.increaseLeverage(ILeverager.IncreaseParams(10e6, 0, 0, block.timestamp));
        assertEq(aNew.balanceOf(user), 100e6);
        assertEq(vDebt.balanceOf(user), 0);
        assertEq(ICreditDelegationToken(address(vDebt)).borrowAllowance(user, address(other)), type(uint256).max);
        _assertNoCustody(other, address(router_));
    }

    // ------------------------------------------------------------------ preview envelope

    function test_previewCreateRejectsNormallyReturningSimulator() public {
        ILeverager.CreateParams memory params = ILeverager.CreateParams(1e6, 0, 0, 0, block.timestamp);
        bytes memory simulation =
            abi.encodeCall(leverager.simulate, (abi.encodeCall(leverager.createPosition, (params))));
        // Only a mocked self-call returns normally; simulate always reverts with its envelope.
        vm.mockCall(address(leverager), simulation, abi.encode(true, bytes("forged")));
        vm.prank(user);
        vm.expectRevert(ILeverager.InvalidSimulationCall.selector);
        leverager.previewCreatePosition(params);
    }

    function test_previewCreateBubblesEmptySimulatorFailure() public {
        ILeverager.CreateParams memory params = ILeverager.CreateParams(1e6, 0, 0, 0, block.timestamp);
        bytes memory simulation =
            abi.encodeCall(leverager.simulate, (abi.encodeCall(leverager.createPosition, (params))));
        // An empty failure, such as an out-of-gas inner frame, is rethrown without decoding an absent envelope.
        vm.mockCallRevert(address(leverager), simulation, bytes(""));
        vm.prank(user);
        (bool success, bytes memory reason) =
            address(leverager).call(abi.encodeCall(leverager.previewCreatePosition, (params)));
        assertFalse(success);
        assertEq(reason, bytes(""));
    }
}
