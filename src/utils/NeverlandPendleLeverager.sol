// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFlashLoanReceiver} from "@neverland-money/lending-core/contracts/flashloan/interfaces/IFlashLoanReceiver.sol";
import {IACLManager} from "@neverland-money/lending-core/contracts/interfaces/IACLManager.sol";
import {IPool} from "@neverland-money/lending-core/contracts/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@neverland-money/lending-core/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPriceOracleGetter} from "@neverland-money/lending-core/contracts/interfaces/IPriceOracleGetter.sol";
import {IScaledBalanceToken} from "@neverland-money/lending-core/contracts/interfaces/IScaledBalanceToken.sol";
import {
    ReserveConfiguration
} from "@neverland-money/lending-core/contracts/protocol/libraries/configuration/ReserveConfiguration.sol";
import {
    UserConfiguration
} from "@neverland-money/lending-core/contracts/protocol/libraries/configuration/UserConfiguration.sol";
import {WadRayMath} from "@neverland-money/lending-core/contracts/protocol/libraries/math/WadRayMath.sol";
import {DataTypes} from "@neverland-money/lending-core/contracts/protocol/libraries/types/DataTypes.sol";
import {Ownable} from "@openzeppelin-v5/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin-v5/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin-v5/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin-v5/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin-v5/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin-v5/contracts/utils/math/Math.sol";

import {IMorphoFlashLoan} from "../interfaces/IMorphoFlashLoan.sol";
import {IMorphoFlashLoanCallback} from "../interfaces/IMorphoFlashLoanCallback.sol";
import {INeverlandPendleLeverager} from "../interfaces/INeverlandPendleLeverager.sol";
import {IPendleMarket} from "../interfaces/IPendleMarket.sol";
import {IPendleMaturityPrincipalToken} from "../interfaces/IPendleMaturityPrincipalToken.sol";
import {IPendlePtLeverageRouter} from "../interfaces/IPendlePtLeverageRouter.sol";
import {IPendleRouterV4} from "../interfaces/IPendleRouterV4.sol";
import {IPendleStandardizedYield} from "../interfaces/IPendleStandardizedYield.sol";
import {IPendleYieldToken} from "../interfaces/IPendleYieldToken.sol";

/**
 * @title NeverlandPendleLeverager
 * @author Neverland
 * @notice Creates and adjusts caller-owned positions in one fixed Pendle PT market.
 * @dev Non-upgradeable. Mode-2 position-pool flash loans open caller debt after supplying purchased PT.
 *      Decreases use fee-free external liquidity and repay before transferring collateral.
 */
contract NeverlandPendleLeverager is
    INeverlandPendleLeverager,
    IFlashLoanReceiver,
    IMorphoFlashLoanCallback,
    Ownable2Step,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
    using UserConfiguration for DataTypes.UserConfigurationMap;

    /**
     * @notice Bind one fixed market, two distinct pools, a debt asset, lenders and owner.
     * @param pool_ Pool holding caller positions and issuing mode-2 debt.
     * @param debtAsset_ Borrowed token and SY input/output asset.
     * @param morpho_ External fee-free Morpho repayment lender.
     * @param flashPool_ Distinct external pool repayment lender.
     * @param pendleRouter_ Typed Pendle router.
     * @param market_ Unexpired fixed-par Pendle market.
     * @param initialOwner_ Initial recovery owner.
     */
    constructor(
        IPool pool_,
        address debtAsset_,
        address morpho_,
        IPool flashPool_,
        address pendleRouter_,
        address market_,
        address initialOwner_
    ) Ownable(initialOwner_) {
        _requireCode(address(pool_));
        _requireCode(debtAsset_);
        _requireCode(morpho_);
        _requireCode(address(flashPool_));
        _requireCode(pendleRouter_);
        _requireCode(market_);
        if (pool_ == flashPool_) revert InvalidDependency(address(flashPool_));

        _pool = pool_;
        DEBT_ASSET = debtAsset_;
        MORPHO = morpho_;
        FLASH_POOL = flashPool_;
        PENDLE_ROUTER = pendleRouter_;
        MARKET = market_;
        (address sy, address pt, address yt) = IPendleMarket(market_).readTokens();
        _requireCode(sy);
        _requireCode(pt);
        _requireCode(yt);
        if (pt == debtAsset_ || sy == pt || sy == debtAsset_) revert InvalidMarket(market_);

        SY = sy;
        PT = pt;
        YT = yt;
        A_PT = _listed(pt);
        _listed(debtAsset_);
        _debtToken = pool_.getReserveData(debtAsset_).variableDebtTokenAddress;
        _requireCode(_debtToken);
        _validateMarket();
        _requireUnexpired();
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandPendleLeverager
    uint256 public constant MAX_ORACLE_DEVIATION_BPS = 1_000;

    /// @dev Gas cap for the optional external-pool capacity read.
    uint256 private constant OPTIONAL_READ_GAS = 500_000;

    /// @dev Basis-points denominator for output floors.
    uint256 private constant BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandPendleLeverager
    address public immutable DEBT_ASSET;

    /// @inheritdoc INeverlandPendleLeverager
    address public immutable MORPHO;

    /// @inheritdoc INeverlandPendleLeverager
    IPool public immutable FLASH_POOL;

    /// @inheritdoc INeverlandPendleLeverager
    address public immutable PENDLE_ROUTER;

    /// @inheritdoc INeverlandPendleLeverager
    address public immutable MARKET;

    /// @inheritdoc INeverlandPendleLeverager
    address public immutable PT;

    /// @inheritdoc INeverlandPendleLeverager
    address public immutable SY;

    /// @inheritdoc INeverlandPendleLeverager
    address public immutable YT;

    /// @inheritdoc INeverlandPendleLeverager
    address public immutable A_PT;

    /// @dev Pool holding caller positions, exposed through POOL().
    IPool private immutable _pool;

    /// @dev Pinned variable-debt token used for settled borrower balances.
    address private immutable _debtToken;

    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    /// @dev NONE, position-pool mode 2, Morpho, external pool mode 0.
    enum Source {
        NONE,
        POSITION_POOL,
        MORPHO,
        FLASH_POOL
    }

    /**
     * @notice Exact round data committed before requesting a flash loan.
     * @param user Position owner, always the entry caller.
     * @param cash Raw debt asset borrowed for the round.
     * @param ptAmount Raw PT allocated to a repayment round.
     * @param debtEntry Leverager debt-asset cash balance before the flash loan.
     * @param minimumPt Minimum raw PT purchased by an increase round.
     */
    struct RoundContext {
        address user;
        uint256 cash;
        uint256 ptAmount;
        uint256 debtEntry;
        uint256 minimumPt;
    }

    /**
     * @notice Entry custody balances preserved by every completed operation.
     * @param cash Raw debt-asset balance.
     * @param pt Raw principal-token balance.
     * @param sy Raw standardized-yield share balance.
     * @param scaledAPt Scaled PT receipt-token balance.
     */
    struct Snapshot {
        uint256 cash;
        uint256 pt;
        uint256 sy;
        uint256 scaledAPt;
    }

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Expected callback source, consumed before external callback work.
    Source private transient _expected;

    /// @dev Hash of the active round data, binding its callback to the entry action.
    bytes32 private transient _contextHash;

    /// @dev Measured PT purchased by the active increase callback.
    uint256 private transient _purchased;

    /// @dev Raw debt-asset cash spent repaying debt across the active decrease.
    uint256 private transient _repaid;

    /// @dev Raw debt-asset proceeds from PT conversion across the active decrease.
    uint256 private transient _converted;

    /// @dev Debt-asset cash held before the active decrease, excluded from operation funding.
    uint256 private transient _actionEntryCash;

    /*//////////////////////////////////////////////////////////////
                                  ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandPendleLeverager
    function emergencyTokenTransfer(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidDependency(to);

        IERC20(token).safeTransfer(to, amount);

        emit ERC20Recovered(token, to, amount);
    }

    /// @inheritdoc INeverlandPendleLeverager
    function renounceOwnership() public view override(INeverlandPendleLeverager, Ownable) onlyOwner {
        revert OwnershipRequired();
    }

    /*//////////////////////////////////////////////////////////////
                              USER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandPendleLeverager
    function createPosition(CreateParams calldata params) external nonReentrant returns (PositionResult memory result) {
        _entry(params.deadline);
        if (params.initialPtAmount == 0) revert InvalidAmount();

        Snapshot memory entry = _snapshot();
        result.debtBefore = _debt(msg.sender);
        uint256 beforePt = _balance(PT);
        IERC20(PT).safeTransferFrom(msg.sender, address(this), params.initialPtAmount);
        _assertBalance(PT, beforePt + params.initialPtAmount);
        _supply(msg.sender, params.initialPtAmount);
        result.principalSupplied = params.initialPtAmount;
        _increase(params.borrowAmount, params.minPtOut, result);
        _finish(entry, params.minHealthFactor, result);

        emit PositionCreated(
            msg.sender, result.principalSupplied, result.ptSupplied, result.cashBorrowed, result.debtAfter
        );
    }

    /// @inheritdoc INeverlandPendleLeverager
    function increaseLeverage(IncreaseParams calldata params)
        external
        nonReentrant
        returns (PositionResult memory result)
    {
        _entry(params.deadline);
        if (params.borrowAmount == 0) revert InvalidAmount();

        Snapshot memory entry = _snapshot();
        result.debtBefore = _debt(msg.sender);
        _increase(params.borrowAmount, params.minPtOut, result);
        _finish(entry, params.minHealthFactor, result);

        emit LeverageIncreased(msg.sender, result.ptSupplied, result.cashBorrowed, result.debtAfter);
    }

    /// @inheritdoc INeverlandPendleLeverager
    function decreaseLeverage(DecreaseParams calldata params)
        external
        nonReentrant
        returns (PositionResult memory result)
    {
        _entry(params.deadline);
        if (params.ptAmount == 0 || params.repayAmount == 0 || params.maxCashRepaid == 0) revert InvalidAmount();

        Snapshot memory entry = _snapshot();
        result.debtBefore = _debt(msg.sender);
        if (result.debtBefore == 0) revert InvalidAmount();

        uint256 hfBefore = _health(msg.sender);
        uint256 ptLeft = params.ptAmount == type(uint256).max
            ? Math.min(IERC20(A_PT).balanceOf(msg.sender), IERC20(A_PT).allowance(msg.sender, address(this)))
            : params.ptAmount;
        if (ptLeft == 0) revert InvalidAmount();

        result.ptWithdrawn = ptLeft;
        bool full = params.repayAmount == type(uint256).max;
        uint256 repayLeft = full ? result.debtBefore : Math.min(params.repayAmount, result.debtBefore);
        (Source source, uint256 cash) = _flashCapacity();
        result.flashSource = _lender(source);
        result.flashCash = cash;
        _repaid = 0;
        _converted = 0;
        _actionEntryCash = entry.cash;
        while (true) {
            uint256 debtNow = _debt(msg.sender);
            uint256 target = full ? debtNow : Math.min(repayLeft, debtNow);
            if (target == 0) break;
            uint256 capLeft = params.maxCashRepaid - _repaid;
            if (target > capLeft) revert CashRepaymentLimitExceeded(target, capLeft);

            uint256 available = _operationCash();
            if (available >= target) {
                uint256 directPaid = _repay(msg.sender, target);
                if (!full) repayLeft -= directPaid;
                continue;
            }

            if (ptLeft == 0) revert InsufficientPtBudget(target, ptLeft);
            if (result.rounds == params.maxRounds) revert RoundLimitExceeded(target, params.maxRounds);
            if (cash == 0) revert InsufficientFlashLiquidity(target, cash);

            uint256 amount = Math.ceilDiv(target, Math.ceilDiv(target, cash));
            uint256 ptRound = amount == target ? ptLeft : Math.mulDiv(ptLeft, amount, target);
            if (ptRound == 0) revert InsufficientPtBudget(target, ptLeft);

            uint256 paidBefore = _repaid;
            _flash(source, RoundContext(msg.sender, amount, ptRound, _balance(DEBT_ASSET), 0));
            uint256 paid = _repaid - paidBefore;
            if (paid == 0) revert InvalidAmount();

            if (!full) repayLeft -= paid;
            ptLeft -= ptRound;
            ++result.rounds;
        }
        if (ptLeft != 0) _converted += _withdrawAndConvert(msg.sender, ptLeft);
        _repaySurplus(msg.sender, params.maxCashRepaid);
        result.cashRepaid = _repaid;
        uint256 proceeds = _converted;
        _actionEntryCash = 0;
        _repaid = 0;
        _converted = 0;
        uint256 minimum = Math.max(params.minDebtAssetOut, _oracleMinimum(result.ptWithdrawn, false));
        _minimum(proceeds, minimum);
        _finish(entry, Math.max(hfBefore, params.minHealthFactor), result);
        if (result.debtAfter > result.debtBefore || (full && result.debtAfter != 0)) {
            revert DebtMismatch(result.debtBefore, result.debtAfter);
        }

        emit LeverageDecreased(
            msg.sender, result.ptWithdrawn, result.cashRepaid, result.debtAfter, result.surplus, result.rounds
        );
    }

    /*//////////////////////////////////////////////////////////////
                                PREVIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandPendleLeverager
    function previewCreatePosition(CreateParams calldata params) external returns (PositionResult memory) {
        _preview(abi.encodeCall(this.createPosition, (params)));
    }

    /// @inheritdoc INeverlandPendleLeverager
    function previewIncreaseLeverage(IncreaseParams calldata params) external returns (PositionResult memory) {
        _preview(abi.encodeCall(this.increaseLeverage, (params)));
    }

    /// @inheritdoc INeverlandPendleLeverager
    function previewDecreaseLeverage(DecreaseParams calldata params) external returns (PositionResult memory) {
        _preview(abi.encodeCall(this.decreaseLeverage, (params)));
    }

    /// @inheritdoc INeverlandPendleLeverager
    function simulate(bytes calldata callData) external {
        if (callData.length < 4) revert InvalidSimulationCall();

        bytes4 selector = bytes4(callData[:4]);
        if (
            selector != this.createPosition.selector && selector != this.increaseLeverage.selector
                && selector != this.decreaseLeverage.selector
        ) revert InvalidSimulationCall();

        (bool success, bytes memory result) = address(this).delegatecall(callData);
        _revert(abi.encode(success, result));
    }

    /*//////////////////////////////////////////////////////////////
                             FLASH CALLBACKS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IFlashLoanReceiver
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata data
    ) external returns (bool) {
        Source source = _expected;
        if (source != Source.POSITION_POOL && source != Source.FLASH_POOL) revert FlashCallbackUnauthorized();
        if (
            msg.sender != _lender(source) || initiator != address(this) || assets.length != 1 || amounts.length != 1
                || premiums.length != 1 || assets[0] != DEBT_ASSET || premiums[0] != 0
        ) revert FlashCallbackUnauthorized();

        _callback(source, amounts[0], data);

        return true;
    }

    /// @inheritdoc IMorphoFlashLoanCallback
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        if (msg.sender != MORPHO || _expected != Source.MORPHO) revert FlashCallbackUnauthorized();

        _callback(Source.MORPHO, assets, data);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandPendleLeverager
    function POOL() external view override(INeverlandPendleLeverager, IFlashLoanReceiver) returns (IPool) {
        return _pool;
    }

    /// @inheritdoc IFlashLoanReceiver
    function ADDRESSES_PROVIDER() external view returns (IPoolAddressesProvider) {
        return _pool.ADDRESSES_PROVIDER();
    }

    /// @inheritdoc INeverlandPendleLeverager
    function flashCapacity() external view returns (address source, uint256 cash) {
        Source selected;
        (selected, cash) = _flashCapacity();

        source = _lender(selected);
    }

    /// @inheritdoc INeverlandPendleLeverager
    function flashPoolCapacity() external view returns (uint256) {
        return _poolCash(FLASH_POOL, true);
    }

    /// @inheritdoc INeverlandPendleLeverager
    function leverageCapacity() public view returns (uint256) {
        return _poolCash(_pool, false);
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL ENGINE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Purchase PT in one mode-2 round and verify debt after lending-core settlement.
     * @param amount Raw debt asset borrowed; zero only seeds principal.
     * @param userMinimum Minimum raw PT purchased, excluding principal.
     * @param result Operation result populated after the flash loan.
     */
    function _increase(uint256 amount, uint256 userMinimum, PositionResult memory result) private {
        if (amount == 0) {
            _minimum(0, userMinimum);

            return;
        }

        uint256 cash = leverageCapacity();
        if (amount > cash) revert InsufficientFlashLiquidity(amount, cash);

        uint256 minimum = Math.max(Math.max(userMinimum, _oracleMinimum(amount, true)), amount - amount / BPS);
        _purchased = 0;
        _flash(Source.POSITION_POOL, RoundContext(msg.sender, amount, 0, _balance(DEBT_ASSET), minimum));
        result.ptSupplied = _purchased;
        _purchased = 0;
        result.cashBorrowed = amount;
        result.flashSource = address(_pool);
        result.flashCash = cash;
        result.rounds = 1;
        // Mode-2 debt is minted by the lending core after executeOperation returns.
        if (_debt(msg.sender) < result.debtBefore + amount) revert DebtMismatch(result.debtBefore, _debt(msg.sender));
    }

    /**
     * @notice Bind a round, require its callback and clear the lender allowance after settlement.
     * @param source Lender and repayment mode.
     * @param ctx Exact round amounts and entry cash committed to the callback.
     */
    function _flash(Source source, RoundContext memory ctx) private {
        bytes memory data = abi.encode(ctx);
        _expected = source;
        _contextHash = keccak256(data);
        if (source == Source.MORPHO) {
            IMorphoFlashLoan(MORPHO).flashLoan(DEBT_ASSET, ctx.cash, data);
        } else {
            address[] memory assets = new address[](1);
            uint256[] memory amounts = new uint256[](1);
            uint256[] memory modes = new uint256[](1);
            assets[0] = DEBT_ASSET;
            amounts[0] = ctx.cash;
            bool increase = source == Source.POSITION_POOL;
            modes[0] = increase ? 2 : 0;
            (increase ? _pool : FLASH_POOL)
            .flashLoan(address(this), assets, amounts, modes, increase ? ctx.user : address(this), data, 0);
        }
        if (_expected != Source.NONE) revert FlashCallbackUnauthorized();

        // Repayment loans pull this allowance; mode 2 receives no repayment approval.
        IERC20(DEBT_ASSET).forceApprove(_lender(source), 0);
    }

    /**
     * @notice Consume callback authorization and preserve action-entry cash.
     * @param source Expected lender and repayment mode.
     * @param amount Raw debt asset received from the lender.
     * @param data ABI-encoded round context committed by the active action.
     */
    function _callback(Source source, uint256 amount, bytes calldata data) private {
        if (!_reentrancyGuardEntered() || _expected != source || _contextHash != keccak256(data)) {
            revert FlashCallbackUnauthorized();
        }

        RoundContext memory ctx = abi.decode(data, (RoundContext));
        if (ctx.cash != amount) revert FlashCallbackUnauthorized();

        _expected = Source.NONE;
        _contextHash = bytes32(0);
        _assertBalance(DEBT_ASSET, ctx.debtEntry + amount);
        if (source == Source.POSITION_POOL) {
            _purchased = _buyAndSupply(ctx.user, amount, ctx.minimumPt);
            _assertBalance(DEBT_ASSET, ctx.debtEntry);
        } else {
            _repay(ctx.user, amount);
            _converted += _withdrawAndConvert(ctx.user, ctx.ptAmount);
            uint256 available = _operationCash();
            if (available < amount) revert InsufficientRepaymentProceeds(amount, available);

            IERC20(DEBT_ASSET).forceApprove(_lender(source), amount);
        }
    }

    /**
     * @notice Repay with exact approval and account for actual debt-asset cash expenditure.
     * @param user Caller whose variable debt is repaid.
     * @param amount Exact finite cash approval.
     * @return paid Measured debt-asset expenditure, bounded by the approval.
     */
    function _repay(address user, uint256 amount) private returns (uint256 paid) {
        uint256 beforeRepay = _balance(DEBT_ASSET);
        IERC20(DEBT_ASSET).forceApprove(address(_pool), amount);
        _pool.repay(DEBT_ASSET, amount, 2, user);
        IERC20(DEBT_ASSET).forceApprove(address(_pool), 0);
        paid = beforeRepay - _balance(DEBT_ASSET);
        if (paid == 0 || paid > amount) revert InvalidAmount();

        _repaid += paid;
    }

    /**
     * @notice Apply settled operation cash to remaining debt within the total cash cap.
     * @dev A partial repayment must burn at least one debt share; unrepayable dust stays refundable.
     * @param user Caller whose remaining debt receives the surplus.
     * @param maxCashRepaid Maximum aggregate debt-asset cash spent repaying caller debt.
     */
    function _repaySurplus(address user, uint256 maxCashRepaid) private {
        uint256 debt = _debt(user);
        uint256 amount = Math.min(_operationCash(), Math.min(debt, maxCashRepaid - _repaid));
        if (amount == 0) return;
        if (amount < debt) {
            uint256 minimumPartial = Math.ceilDiv(_pool.getReserveNormalizedVariableDebt(DEBT_ASSET), WadRayMath.RAY);
            if (amount < minimumPartial) return;
        }

        _repay(user, amount);
    }

    /**
     * @notice Spend the exact flash budget and supply measured PT, ignoring router-reported output.
     * @param user Caller receiving the supplied collateral.
     * @param amount Raw debt asset spent on PT.
     * @param minimum Minimum raw PT purchased.
     * @return bought Measured raw PT supplied to the caller.
     */
    function _buyAndSupply(address user, uint256 amount, uint256 minimum) private returns (uint256 bought) {
        uint256 cashBefore = _balance(DEBT_ASSET);
        uint256 ptBefore = _balance(PT);
        IPendleRouterV4.TokenInput memory input;
        input.tokenIn = DEBT_ASSET;
        input.netTokenIn = amount;
        input.tokenMintSy = DEBT_ASSET;
        IPendleRouterV4.LimitOrderData memory orders;
        IPendleRouterV4.ApproxParams memory approx = IPendleRouterV4.ApproxParams(0, type(uint256).max, 0, 256, 5e13);
        IERC20(DEBT_ASSET).forceApprove(PENDLE_ROUTER, amount);
        IPendlePtLeverageRouter(PENDLE_ROUTER)
            .swapExactTokenForPt(address(this), MARKET, minimum, approx, input, orders);
        IERC20(DEBT_ASSET).forceApprove(PENDLE_ROUTER, 0);
        _assertBalance(DEBT_ASSET, cashBefore - amount);
        bought = _balance(PT) - ptBefore;
        _minimum(bought, minimum);
        _supply(user, bought);
    }

    /**
     * @notice Supply exact PT and require the caller receipt-token delta and collateral flag.
     * @param user Caller receiving the supplied collateral.
     * @param amount Raw PT supplied at the fixed reserve index.
     */
    function _supply(address user, uint256 amount) private {
        uint256 ptBefore = _balance(PT);
        uint256 userBefore = _scaledBalance(user);
        IERC20(PT).forceApprove(address(_pool), amount);
        _pool.supply(PT, amount, user, 0);
        IERC20(PT).forceApprove(address(_pool), 0);
        _assertBalance(PT, ptBefore - amount);
        if (_scaledBalance(user) != userBefore + amount) revert InvalidAmount();
        if (!_pool.getUserConfiguration(user).isUsingAsCollateral(_pool.getReserveData(PT).id)) {
            revert CollateralNotEnabled();
        }
    }

    /**
     * @notice Pull allocated aPT, withdraw exact PT and measure its sale.
     * @param user Caller whose approved receipt tokens are consumed.
     * @param amount Raw PT withdrawn and converted.
     * @return proceeds Measured raw debt asset received.
     */
    function _withdrawAndConvert(address user, uint256 amount) private returns (uint256 proceeds) {
        uint256 aBefore = _scaledBalance(address(this));
        uint256 ptBefore = _balance(PT);
        uint256 cashBefore = _balance(DEBT_ASSET);
        IERC20(A_PT).safeTransferFrom(user, address(this), amount);
        if (_scaledBalance(address(this)) != aBefore + amount) revert InvalidAmount();

        _pool.withdraw(PT, amount, address(this));
        if (_scaledBalance(address(this)) != aBefore) revert InvalidAmount();

        _assertBalance(PT, ptBefore + amount);
        IPendlePtLeverageRouter.TokenOutput memory output;
        output.tokenOut = DEBT_ASSET;
        output.tokenRedeemSy = DEBT_ASSET;
        IPendleRouterV4.LimitOrderData memory orders;
        IERC20(PT).forceApprove(PENDLE_ROUTER, amount);
        IPendlePtLeverageRouter(PENDLE_ROUTER).swapExactPtForToken(address(this), MARKET, amount, output, orders);
        IERC20(PT).forceApprove(PENDLE_ROUTER, 0);
        _assertBalance(PT, ptBefore);
        proceeds = _balance(DEBT_ASSET) - cashBefore;
    }

    /**
     * @notice Validate final account health, return operation surplus and preserve entry custody balances.
     * @param entry Token balances captured before the action.
     * @param healthMinimum Required final health factor in WAD.
     * @param result Operation result populated with settled debt, health and surplus.
     */
    function _finish(Snapshot memory entry, uint256 healthMinimum, PositionResult memory result) private {
        result.debtAfter = _debt(msg.sender);
        result.healthFactorAfter = _health(msg.sender);
        uint256 minimum = Math.max(1e18, healthMinimum);
        if (result.healthFactorAfter < minimum) revert HealthFactorBelowMinimum(result.healthFactorAfter, minimum);

        uint256 cash = _balance(DEBT_ASSET);
        if (cash < entry.cash) revert BalanceMismatch(DEBT_ASSET, entry.cash, cash);

        result.surplus = cash - entry.cash;
        if (result.surplus != 0) IERC20(DEBT_ASSET).safeTransfer(msg.sender, result.surplus);
        _assertBalance(DEBT_ASSET, entry.cash);
        _assertBalance(PT, entry.pt);
        _assertBalance(SY, entry.sy);
        uint256 scaled = _scaledBalance(address(this));
        if (scaled != entry.scaledAPt) revert BalanceMismatch(A_PT, entry.scaledAPt, scaled);
    }

    /**
     * @notice Return a rolled-back action result or rethrow its failure.
     * @dev Preview entrypoints must not acquire a reentrancy lock: the delegated action owns it, and assembly return
     *      skips modifier cleanup.
     * @param callData Encoded supported user action.
     */
    function _preview(bytes memory callData) private {
        (bool completed, bytes memory envelope) = address(this).delegatecall(abi.encodeCall(this.simulate, (callData)));
        if (completed) revert InvalidSimulationCall();
        if (envelope.length == 0) _revert(envelope);

        (bool success, bytes memory result) = abi.decode(envelope, (bool, bytes));
        if (!success) _revert(result);

        assembly ("memory-safe") { return(add(result, 0x20), mload(result)) }
    }

    /**
     * @notice Capture custody balances, using scaled aPT for fixed-index accounting.
     * @return Entry raw token and scaled receipt-token balances.
     */
    function _snapshot() private view returns (Snapshot memory) {
        return Snapshot(_balance(DEBT_ASSET), _balance(PT), _balance(SY), _scaledBalance(address(this)));
    }

    /**
     * @notice Debt-asset cash generated by the active decrease, excluding action-entry cash.
     * @dev Reverts with BalanceMismatch if the balance falls below the action-entry cash.
     * @return available Raw debt-asset cash above the action-entry balance.
     */
    function _operationCash() private view returns (uint256 available) {
        uint256 balance = _balance(DEBT_ASSET);
        if (balance < _actionEntryCash) revert BalanceMismatch(DEBT_ASSET, _actionEntryCash, balance);

        return balance - _actionEntryCash;
    }

    /**
     * @notice Validate the deadline, pinned market relationships and an unexpired market and PT.
     * @param deadline Inclusive block-timestamp deadline.
     */
    function _entry(uint256 deadline) private view {
        if (block.timestamp > deadline) revert DeadlineExpired();

        _validateMarket();
        _requireUnexpired();
    }

    /// @notice Recheck pinned relationships and equal-decimal, fixed-par restrictions at action entry.
    function _validateMarket() private view {
        (address sy, address pt, address yt) = IPendleMarket(MARKET).readTokens();
        if (
            sy != SY || pt != PT || yt != YT || IPendleMaturityPrincipalToken(PT).SY() != SY
                || IPendleMaturityPrincipalToken(PT).YT() != YT
        ) revert InvalidMarket(MARKET);
        if (_listed(PT) != A_PT || _pool.getReserveData(DEBT_ASSET).variableDebtTokenAddress != _debtToken) {
            revert InvalidMarket(MARKET);
        }
        if (_pool.getReserveNormalizedIncome(PT) != WadRayMath.RAY) revert ReserveIndexNotPar(PT);

        uint256 decimals = _pool.getConfiguration(PT).getDecimals();
        if (
            decimals != _pool.getConfiguration(DEBT_ASSET).getDecimals()
                || !IPendleStandardizedYield(SY).isValidTokenIn(DEBT_ASSET)
                || !IPendleStandardizedYield(SY).isValidTokenOut(DEBT_ASSET)
                || IPendleStandardizedYield(SY).exchangeRate() != 1e18 || IPendleYieldToken(YT).pyIndexStored() != 1e18
                || IPendleStandardizedYield(SY).previewRedeem(DEBT_ASSET, 10 ** decimals) < 10 ** decimals
        ) revert UnsupportedSy(SY);
    }

    /// @notice Reject construction and every action at or after market or PT expiry.
    function _requireUnexpired() private view {
        if (IPendleMarket(MARKET).isExpired() || IPendleMaturityPrincipalToken(PT).isExpired()) revert MarketExpired();
    }

    /**
     * @notice Resolve a listed asset receipt token from the position pool.
     * @param asset Reserve underlying token.
     * @return token Nonzero reserve receipt-token address.
     */
    function _listed(address asset) private view returns (address token) {
        token = _pool.getReserveData(asset).aTokenAddress;
        if (token == address(0)) revert ReserveNotListed(asset);
    }

    /**
     * @notice Apply one rounded-up 90% oracle conversion with equal reserve decimals.
     * @param amount Raw input amount in debt-asset units for a purchase, otherwise PT units.
     * @param purchase Whether the conversion buys PT instead of selling it.
     * @return Minimum raw output in the destination token.
     */
    function _oracleMinimum(uint256 amount, bool purchase) private view returns (uint256) {
        IPriceOracleGetter oracle = IPriceOracleGetter(_pool.ADDRESSES_PROVIDER().getPriceOracle());
        uint256 ptPrice = oracle.getAssetPrice(PT);
        uint256 cashPrice = oracle.getAssetPrice(DEBT_ASSET);
        if (ptPrice == 0) revert InvalidOraclePrice(PT);
        if (cashPrice == 0) revert InvalidOraclePrice(DEBT_ASSET);

        return purchase
            ? Math.mulDiv(amount, cashPrice * (BPS - MAX_ORACLE_DEVIATION_BPS), ptPrice * BPS, Math.Rounding.Ceil)
            : Math.mulDiv(amount, ptPrice * (BPS - MAX_ORACLE_DEVIATION_BPS), cashPrice * BPS, Math.Rounding.Ceil);
    }

    /**
     * @notice Cap flash cash by reserve supply and require a fee waiver for external repayment loans.
     * @param pool Lending pool whose debt-asset reserve is read.
     * @param needRole Whether this lender requires the FLASH_BORROWER role.
     * @return Eligible raw debt-asset cash, or zero for an unavailable reserve or role.
     */
    function _poolCash(IPool pool, bool needRole) private view returns (uint256) {
        DataTypes.ReserveData memory reserve = pool.getReserveData(DEBT_ASSET);
        if (reserve.aTokenAddress == address(0)) return 0;

        (bool active,,,, bool paused) = reserve.configuration.getFlags();
        if (!active || paused || !reserve.configuration.getFlashLoanEnabled()) return 0;
        if (needRole && !IACLManager(pool.ADDRESSES_PROVIDER().getACLManager()).isFlashBorrower(address(this))) {
            return 0;
        }

        return
            Math.min(IERC20(DEBT_ASSET).balanceOf(reserve.aTokenAddress), IERC20(reserve.aTokenAddress).totalSupply());
    }

    /**
     * @notice Select the largest eligible external lender, treating optional pool read failures as zero.
     * @return source Selected lender, with Morpho winning ties.
     * @return cash Available raw debt asset per round.
     */
    function _flashCapacity() private view returns (Source source, uint256 cash) {
        uint256 morphoCash = IERC20(DEBT_ASSET).balanceOf(MORPHO);
        uint256 poolCash;
        try this.flashPoolCapacity{gas: OPTIONAL_READ_GAS}() returns (uint256 available) {
            poolCash = available;
        } catch {}

        if (poolCash > morphoCash) return (Source.FLASH_POOL, poolCash);
        if (morphoCash != 0) return (Source.MORPHO, morphoCash);

        return (Source.NONE, 0);
    }

    /**
     * @notice Resolve a source to its lender address.
     * @param source Active lending route or NONE.
     * @return Lender address, or zero for NONE.
     */
    function _lender(Source source) private view returns (address) {
        if (source == Source.POSITION_POOL) return address(_pool);
        if (source == Source.MORPHO) return MORPHO;
        if (source == Source.FLASH_POOL) return address(FLASH_POOL);

        return address(0);
    }

    /**
     * @notice Read the leverager raw token balance for operation accounting.
     * @param token ERC20 whose custody balance is read.
     * @return Raw token balance held by this contract.
     */
    function _balance(address token) private view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /**
     * @notice Read scaled aPT for exact fixed-index receipt accounting.
     * @param account Receipt-token holder.
     * @return Scaled PT receipt-token balance.
     */
    function _scaledBalance(address account) private view returns (uint256) {
        return IScaledBalanceToken(A_PT).scaledBalanceOf(account);
    }

    /**
     * @notice Read full-account health from the position pool.
     * @param user Position owner.
     * @return health Health factor in WAD.
     */
    function _health(address user) private view returns (uint256 health) {
        (,,,,, health) = _pool.getUserAccountData(user);
    }

    /**
     * @notice Read settled variable debt from the pinned debt token.
     * @param user Borrower whose debt is read.
     * @return Raw debt-asset-denominated variable debt.
     */
    function _debt(address user) private view returns (uint256) {
        return IERC20(_debtToken).balanceOf(user);
    }

    /**
     * @notice Require an exact leverager token balance at an accounting boundary.
     * @param token ERC20 whose custody balance is checked.
     * @param expected Required raw token balance.
     */
    function _assertBalance(address token, uint256 expected) private view {
        uint256 actual = _balance(token);
        if (actual != expected) revert BalanceMismatch(token, expected, actual);
    }

    /**
     * @notice Enforce an output floor in the output token raw units.
     * @param output Observed output.
     * @param minimum Required output in the same units.
     */
    function _minimum(uint256 output, uint256 minimum) private pure {
        if (output < minimum) revert OutputBelowMinimum(output, minimum);
    }

    /**
     * @notice Reject dependencies with no deployed code.
     * @param dependency Required contract address.
     */
    function _requireCode(address dependency) private view {
        if (dependency.code.length == 0) revert InvalidDependency(dependency);
    }

    /**
     * @notice Revert with an exact byte payload, preserving action errors or the simulation envelope.
     * @param data Encoded revert payload.
     */
    function _revert(bytes memory data) private pure {
        assembly ("memory-safe") { revert(add(data, 0x20), mload(data)) }
    }
}
