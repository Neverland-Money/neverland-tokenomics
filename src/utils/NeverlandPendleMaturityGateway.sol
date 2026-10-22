// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFlashLoanReceiver} from "@neverland-money/lending-core/contracts/flashloan/interfaces/IFlashLoanReceiver.sol";
import {IACLManager} from "@neverland-money/lending-core/contracts/interfaces/IACLManager.sol";
import {IPool} from "@neverland-money/lending-core/contracts/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@neverland-money/lending-core/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPriceOracleGetter} from "@neverland-money/lending-core/contracts/interfaces/IPriceOracleGetter.sol";
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
import {IERC20Permit} from "@openzeppelin-v5/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin-v5/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin-v5/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin-v5/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin-v5/contracts/utils/structs/EnumerableSet.sol";

import {IMorphoFlashLoan} from "../interfaces/IMorphoFlashLoan.sol";
import {IMorphoFlashLoanCallback} from "../interfaces/IMorphoFlashLoanCallback.sol";
import {INeverlandPendleMaturityGateway} from "../interfaces/INeverlandPendleMaturityGateway.sol";
import {IPendleMarket} from "../interfaces/IPendleMarket.sol";
import {IPendleMaturityPrincipalToken} from "../interfaces/IPendleMaturityPrincipalToken.sol";
import {IPendleRouterV4} from "../interfaces/IPendleRouterV4.sol";
import {IPendleStandardizedYield} from "../interfaces/IPendleStandardizedYield.sol";
import {IPendleYieldToken} from "../interfaces/IPendleYieldToken.sol";

import {CommonChecksLibrary} from "../libraries/CommonChecksLibrary.sol";

/**
 * @title NeverlandPendleMaturityGateway
 * @author Neverland
 * @notice Closes or migrates a levered position in a matured Pendle PT, in one transaction
 * @dev Non-upgradeable and holds no user state between calls: flash liquidity from Morpho or `FLASH_POOL` funds each
 *      round, the matured PT redeems at par through its YT and SY, and every approval is exact and reset.
 */
contract NeverlandPendleMaturityGateway is
    INeverlandPendleMaturityGateway,
    IFlashLoanReceiver,
    IMorphoFlashLoanCallback,
    Ownable2Step,
    ReentrancyGuardTransient
{
    using EnumerableSet for EnumerableSet.AddressSet;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
    using SafeERC20 for IERC20;
    using UserConfiguration for DataTypes.UserConfigurationMap;

    /**
     * @notice Binds the dependencies, registers the initial migration target, and assigns the owner
     * @param pool_ The pool holding the positions
     * @param debtAsset_ The debt asset each matured PT redeems into
     * @param morpho_ The Morpho lender
     * @param flashPool_ The pool lending fee-free to flash borrowers
     * @param pendleRouter_ The Pendle router
     * @param initialMarket_ The Pendle market whose PT is enabled at deployment
     * @param initialOwner_ The governance owner
     */
    constructor(
        IPool pool_,
        address debtAsset_,
        address morpho_,
        IPool flashPool_,
        address pendleRouter_,
        address initialMarket_,
        address initialOwner_
    ) Ownable(initialOwner_) {
        CommonChecksLibrary.revertIfZeroAddress(address(pool_));
        CommonChecksLibrary.revertIfZeroAddress(debtAsset_);
        CommonChecksLibrary.revertIfZeroAddress(morpho_);
        CommonChecksLibrary.revertIfZeroAddress(address(flashPool_));
        CommonChecksLibrary.revertIfZeroAddress(pendleRouter_);
        CommonChecksLibrary.revertIfSameAddress(address(pool_), address(flashPool_));

        _pool = pool_;
        DEBT_ASSET = debtAsset_;
        MORPHO = morpho_;
        FLASH_POOL = flashPool_;
        PENDLE_ROUTER = pendleRouter_;

        _setMigrationTarget(initialMarket_);
    }

    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    /// @dev Flash lender of a round.
    enum FlashSource {
        NONE,
        MORPHO,
        POOL
    }

    /// @dev Action a flash round performs.
    enum Operation {
        CLOSE,
        MIGRATE
    }

    /**
     * @notice A matured source PT, resolved once per call
     * @param pt The PT
     * @param aToken Its aToken in `POOL`
     * @param yt Its YT
     * @param sy Its SY
     */
    struct SourceToken {
        address pt;
        address aToken;
        address yt;
        address sy;
    }

    /**
     * @notice A registered migration target, resolved once per call
     * @param pt The target PT
     * @param market Its registered Pendle market
     * @param reserveId Its reserve id in `POOL`
     */
    struct TargetToken {
        address pt;
        address market;
        uint256 reserveId;
    }

    /**
     * @notice Everything one flash round needs; encoded into the flash data by the gateway
     * @param operation Close or migrate
     * @param user The position owner, always the entry caller
     * @param source The matured PT
     * @param target The migration target, empty for a close
     * @param amount Flash amount and source aTokens pulled this round
     * @param repay Debt repaid this round
     */
    struct RoundContext {
        Operation operation;
        address user;
        SourceToken source;
        TargetToken target;
        uint256 amount;
        uint256 repay;
    }

    /**
     * @notice Gateway balances at entry; every call must end on them
     * @param debtAsset Debt-asset balance
     * @param ptOld Source PT balance
     * @param ptNew Target PT balance, zero for a close
     */
    struct BalanceSnapshot {
        uint256 debtAsset;
        uint256 ptOld;
        uint256 ptNew;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandPendleMaturityGateway
    uint256 public constant MAX_ORACLE_DEVIATION_BPS = 1_000;

    /// @dev Basis-points denominator.
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @dev Pool rate mode of variable debt.
    uint256 private constant VARIABLE_RATE_MODE = 2;

    /// @dev Pool rate mode that opens no debt, so the flash loan is repaid in the same call.
    uint256 private constant NO_DEBT_MODE = 0;

    /// @dev Iterations of the router's parameterized PT search; the simple search ignores them.
    uint256 private constant DEFAULT_MAX_ITERATION = 256;

    /// @dev Precision of the router's parameterized PT search, 1e18 = 100%; the simple search ignores it.
    uint256 private constant DEFAULT_EPS = 5e13;

    /// @dev Gas cap for optional external reads.
    uint256 private constant OPTIONAL_READ_GAS = 500_000;

    /// @dev ABI length of one pool configuration word.
    uint256 private constant CONFIGURATION_BYTES = 32;

    /// @dev ABI length of the pool's six account-data words.
    uint256 private constant ACCOUNT_DATA_BYTES = 192;

    /// @dev Fixed SY and PY index supported by par settlement.
    uint256 private constant PAR_INDEX = 1e18;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandPendleMaturityGateway
    address public immutable DEBT_ASSET;

    /// @inheritdoc INeverlandPendleMaturityGateway
    address public immutable MORPHO;

    /// @inheritdoc INeverlandPendleMaturityGateway
    IPool public immutable FLASH_POOL;

    /// @inheritdoc INeverlandPendleMaturityGateway
    address public immutable PENDLE_ROUTER;

    /// @dev The pool holding the positions, exposed through `POOL()`.
    IPool private immutable _pool;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Enabled migration-target PTs.
    EnumerableSet.AddressSet private _targets;

    /// @dev Registered Pendle market of each enabled target PT.
    mapping(address pt => address market) private _markets;

    /// @dev Lender of the in-flight round; its callback clears it.
    FlashSource internal transient _inFlight;

    /// @dev Hash of the exact round data the active lender must return.
    bytes32 private transient _roundHash;

    /// @dev Target PT supplied to the caller across a migration's rounds.
    uint256 private transient _supplied;

    /*//////////////////////////////////////////////////////////////
                                  ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandPendleMaturityGateway
    function emergencyTokenTransfer(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        CommonChecksLibrary.revertIfZeroAddress(to);

        IERC20(token).safeTransfer(to, amount);

        emit ERC20Recovered(token, to, amount);
    }

    /// @inheritdoc INeverlandPendleMaturityGateway
    function removeMigrationTarget(address pt) external onlyOwner {
        address market = _markets[pt];
        if (market == address(0)) revert MigrationTargetNotEnabled(pt);

        _targets.remove(pt);
        delete _markets[pt];

        emit MigrationTargetRemoved(pt, market);
    }

    /// @inheritdoc INeverlandPendleMaturityGateway
    function setMigrationTarget(address market) external onlyOwner {
        _setMigrationTarget(market);
    }

    /// @dev Construction and owner updates enforce the same target checks.
    function _setMigrationTarget(address market) private {
        (address sy, address pt, address yt) = IPendleMarket(market).readTokens();
        _requireListed(pt);
        if (IPendleMaturityPrincipalToken(pt).SY() != sy || IPendleMaturityPrincipalToken(pt).YT() != yt) {
            revert InvalidMarket(market);
        }
        if (IPendleMarket(market).isExpired()) revert TargetMarketExpired(market);
        if (
            !IPendleStandardizedYield(sy).isValidTokenIn(DEBT_ASSET)
                || !IPendleStandardizedYield(sy).isValidTokenOut(DEBT_ASSET)
        ) revert UnsupportedSy(sy);
        _requirePar(pt, sy, yt);

        _targets.add(pt);
        _markets[pt] = market;

        emit MigrationTargetSet(pt, market);
    }

    /// @inheritdoc INeverlandPendleMaturityGateway
    function renounceOwnership() public view override(INeverlandPendleMaturityGateway, Ownable) onlyOwner {
        revert OwnershipRequired();
    }

    /*//////////////////////////////////////////////////////////////
                              USER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandPendleMaturityGateway
    function close(CloseParams calldata params) external nonReentrant returns (CloseResult memory) {
        return _close(params);
    }

    /// @inheritdoc INeverlandPendleMaturityGateway
    function closeWithPermit(CloseParams calldata params, PermitParams calldata permit)
        external
        nonReentrant
        returns (CloseResult memory)
    {
        _permitSource(params.ptOld, permit);

        return _close(params);
    }

    /// @inheritdoc INeverlandPendleMaturityGateway
    function migrate(MigrateParams calldata params) external nonReentrant returns (MigrateResult memory) {
        return _migrate(params);
    }

    /// @inheritdoc INeverlandPendleMaturityGateway
    function migrateWithPermit(MigrateParams calldata params, PermitParams calldata permit)
        external
        nonReentrant
        returns (MigrateResult memory)
    {
        _permitSource(params.ptOld, permit);

        return _migrate(params);
    }

    /*//////////////////////////////////////////////////////////////
                                PREVIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INeverlandPendleMaturityGateway
    function previewClose(CloseParams calldata params) external returns (CloseResult memory) {
        _preview(abi.encodeCall(this.close, (params)));
    }

    /// @inheritdoc INeverlandPendleMaturityGateway
    function previewCloseWithPermit(CloseParams calldata params, PermitParams calldata permit)
        external
        returns (CloseResult memory)
    {
        _preview(abi.encodeCall(this.closeWithPermit, (params, permit)));
    }

    /// @inheritdoc INeverlandPendleMaturityGateway
    function previewMigrate(MigrateParams calldata params) external returns (MigrateResult memory) {
        _preview(abi.encodeCall(this.migrate, (params)));
    }

    /// @inheritdoc INeverlandPendleMaturityGateway
    function previewMigrateWithPermit(MigrateParams calldata params, PermitParams calldata permit)
        external
        returns (MigrateResult memory)
    {
        _preview(abi.encodeCall(this.migrateWithPermit, (params, permit)));
    }

    /// @inheritdoc INeverlandPendleMaturityGateway
    function simulate(bytes calldata callData) external {
        if (callData.length < 4) revert InvalidSimulationCall();
        bytes4 selector = bytes4(callData[:4]);
        if (
            selector != this.close.selector && selector != this.closeWithPermit.selector
                && selector != this.migrate.selector && selector != this.migrateWithPermit.selector
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
        bytes calldata params
    ) external returns (bool) {
        if (
            msg.sender != address(FLASH_POOL) || initiator != address(this) || assets.length != 1 || amounts.length != 1
                || premiums.length != 1 || assets[0] != DEBT_ASSET || premiums[0] != 0
        ) revert FlashCallbackUnauthorized();

        _runFlashRound(FlashSource.POOL, address(FLASH_POOL), amounts[0], params);

        return true;
    }

    /// @inheritdoc IMorphoFlashLoanCallback
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        if (msg.sender != MORPHO) revert FlashCallbackUnauthorized();

        _runFlashRound(FlashSource.MORPHO, MORPHO, assets, data);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IFlashLoanReceiver
    function ADDRESSES_PROVIDER() external view returns (IPoolAddressesProvider) {
        return _pool.ADDRESSES_PROVIDER();
    }

    /// @inheritdoc INeverlandPendleMaturityGateway
    function flashCapacity() external view returns (address source, uint256 cash) {
        FlashSource lender;
        (lender, cash) = _flashCapacity();

        return (_lenderOf(lender), cash);
    }

    /// @inheritdoc INeverlandPendleMaturityGateway
    function flashPoolCapacity() external view returns (uint256) {
        return _flashPoolCash();
    }

    /// @inheritdoc INeverlandPendleMaturityGateway
    function migrationMarket(address pt) external view returns (address market) {
        return _markets[pt];
    }

    /// @inheritdoc INeverlandPendleMaturityGateway
    function migrationTargets() external view returns (MigrationTarget[] memory targets) {
        uint256 length = _targets.length();
        targets = new MigrationTarget[](length);

        for (uint256 i; i < length; ++i) {
            address pt = _targets.at(i);
            targets[i] = MigrationTarget({pt: pt, market: _markets[pt]});
        }
    }

    /// @inheritdoc INeverlandPendleMaturityGateway
    function POOL() external view override(INeverlandPendleMaturityGateway, IFlashLoanReceiver) returns (IPool) {
        return _pool;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Repays the caller's debt from its matured PT at par and pays the surplus to `to`
     * @param params The close parameters
     * @return result The observed amounts, rounds, and final account state
     */
    function _close(CloseParams calldata params) internal returns (CloseResult memory result) {
        CommonChecksLibrary.revertIfInvalidToAddress(params.to);

        SourceToken memory source = _resolveSource(params.ptOld);
        result.ptAmount = _resolveAmount(msg.sender, source.aToken, params.ptAmount);
        BalanceSnapshot memory entry = _snapshot(source.pt, address(0));
        address debtToken = _variableDebtToken();
        result.debt = IERC20(debtToken).balanceOf(msg.sender);
        uint256 ptLeft = _runCloseRounds(source, debtToken, params.maxRounds, result);
        if (ptLeft != 0) _pullAndRedeem(msg.sender, source, ptLeft);
        result.debtAfter = IERC20(debtToken).balanceOf(msg.sender);
        result.debtRepaid = result.debt - result.debtAfter;
        result.surplus = _sendExcess(entry.debtAsset, params.to);
        if (result.surplus < params.minSurplusOut) revert OutputBelowMinimum(result.surplus, params.minSurplusOut);
        _assertSnapshot(entry, source.pt, address(0));
        (result.healthFactorAfter, result.healthFactorAvailable) = _readHealthFactor();

        emit PositionClosed(
            msg.sender, source.pt, result.ptAmount, result.debtRepaid, result.surplus, params.to, result.rounds
        );
    }

    /**
     * @notice Runs close rounds, recording the selected liquidity and actual round count
     * @dev Fresh debt reads absorb repay rounding; exceeding the caller's round budget reverts.
     * @param source The matured PT
     * @param debtToken The variable-debt token
     * @param maxRounds The caller's round limit
     * @param result The observed result, populated in place
     * @return ptLeft PT not consumed by the rounds
     */
    function _runCloseRounds(SourceToken memory source, address debtToken, uint256 maxRounds, CloseResult memory result)
        internal
        returns (uint256 ptLeft)
    {
        (FlashSource lender, uint256 cash) = _selectFlashSource(Math.min(result.debt, result.ptAmount), maxRounds);
        result.flashSource = _lenderOf(lender);
        result.flashCash = cash;
        RoundContext memory ctx;
        ctx.operation = Operation.CLOSE;
        ctx.user = msg.sender;
        ctx.source = source;
        ptLeft = result.ptAmount;

        for (
            uint256 target = Math.min(result.debt, ptLeft);
            target != 0;
            target = Math.min(IERC20(debtToken).balanceOf(msg.sender), ptLeft)
        ) {
            if (result.rounds == maxRounds) revert InsufficientFlashLiquidity(target, cash, maxRounds);

            ctx.amount = target < ptLeft ? Math.min(target, cash) : _roundAmount(target, cash);
            ctx.repay = ctx.amount;
            _flash(lender, ctx);
            ptLeft -= ctx.amount;
            ++result.rounds;
        }
    }

    /**
     * @notice Migrates the caller's matured PT, recording actual repayment, purchase, and final account state
     * @param params The migration parameters
     * @return result The observed result
     */
    function _migrate(MigrateParams calldata params) internal returns (MigrateResult memory result) {
        RoundContext memory ctx;
        ctx.operation = Operation.MIGRATE;
        ctx.user = msg.sender;
        ctx.source = _resolveSource(params.ptOld);
        ctx.target = _resolveTarget(params.ptNew);
        result.ptAmount = _resolveAmount(msg.sender, ctx.source.aToken, params.ptAmount);
        address debtToken = _variableDebtToken();
        result.debt = IERC20(debtToken).balanceOf(msg.sender);
        uint256 repayTotal = _clampRepay(params.repayAmount, result.debt, result.ptAmount);

        BalanceSnapshot memory entry = _snapshot(ctx.source.pt, ctx.target.pt);
        _supplied = 0;
        uint256 repayBudget = params.repayAmount < result.debt ? repayTotal : type(uint256).max;
        _runMigrateRounds(ctx, debtToken, repayBudget, params.maxRounds, result);
        result.ptOut = _supplied;
        _supplied = 0;
        result.oracleMinimumPtOut = _requireMigrationOutput(ctx.target.pt, result.spent, result.ptOut, params.minPtOut);
        result.debtAfter = IERC20(debtToken).balanceOf(msg.sender);
        result.repay = result.debt - result.debtAfter;
        result.surplus = _sendExcess(entry.debtAsset, msg.sender);
        _assertSnapshot(entry, ctx.source.pt, ctx.target.pt);
        if (params.minHealthFactor != 0 && _pool.getUserConfiguration(msg.sender).isBorrowingAny()) {
            result.healthFactorAfter = _requireHealthFactor(params.minHealthFactor);
            result.healthFactorAvailable = true;
        } else {
            (result.healthFactorAfter, result.healthFactorAvailable) = _readHealthFactor();
        }

        emit PositionMigrated(
            msg.sender, ctx.source.pt, ctx.target.pt, result.ptAmount, result.ptOut, result.repay, result.rounds
        );
    }

    /**
     * @notice Runs migration rounds, consuming repayment first and recording actual purchase spending
     * @dev An unlimited repayment budget prioritizes fresh debt up to the remaining source value.
     * @param ctx The round template
     * @param debtToken The variable-debt token
     * @param repayBudget The repayment budget, or `type(uint256).max` to prioritize current debt
     * @param maxRounds The caller's round limit
     * @param result The observed result, populated in place
     */
    function _runMigrateRounds(
        RoundContext memory ctx,
        address debtToken,
        uint256 repayBudget,
        uint256 maxRounds,
        MigrateResult memory result
    ) internal {
        (FlashSource lender, uint256 cash) = _selectFlashSource(result.ptAmount, maxRounds);
        result.flashSource = _lenderOf(lender);
        result.flashCash = cash;
        uint256 repayLeft = repayBudget;

        for (uint256 ptLeft = result.ptAmount; ptLeft != 0; ptLeft -= ctx.amount) {
            ctx.amount = _roundAmount(ptLeft, cash);
            ctx.repay = Math.min(Math.min(repayLeft, ctx.amount), IERC20(debtToken).balanceOf(ctx.user));
            _flash(lender, ctx);
            result.spent += ctx.amount - ctx.repay;
            repayLeft -= ctx.repay;
            ++result.rounds;
        }
    }

    /**
     * @notice Simulates an action while preserving the caller and discarding all execution effects
     * @dev Returns directly from the external preview with the action's ABI-encoded result, or rethrows its error.
     *      Assembly return skips modifier cleanup: preview entrypoints must not acquire a reentrancy lock.
     * @param callData The encoded user action
     */
    function _preview(bytes memory callData) internal {
        (bool completed, bytes memory envelope) = address(this).delegatecall(abi.encodeCall(this.simulate, (callData)));
        if (completed) revert InvalidSimulationCall();
        if (envelope.length == 0) _revert(envelope);

        (bool success, bytes memory result) = abi.decode(envelope, (bool, bytes));
        if (!success) _revert(result);

        assembly ("memory-safe") {
            return(add(result, 0x20), mload(result))
        }
    }

    /**
     * @notice Flash-borrows one round's amount from `lender` and runs the round in its callback
     * @dev The callback consumes the in-flight flag; a flag still set afterwards means no callback ran.
     * @param lender The lender
     * @param ctx The round
     */
    function _flash(FlashSource lender, RoundContext memory ctx) internal {
        bytes memory data = abi.encode(ctx);
        _inFlight = lender;
        _roundHash = keccak256(data);

        if (lender == FlashSource.MORPHO) {
            IMorphoFlashLoan(MORPHO).flashLoan(DEBT_ASSET, ctx.amount, data);
        } else {
            address[] memory assets = new address[](1);
            uint256[] memory amounts = new uint256[](1);
            uint256[] memory modes = new uint256[](1);
            assets[0] = DEBT_ASSET;
            amounts[0] = ctx.amount;
            modes[0] = NO_DEBT_MODE;
            FLASH_POOL.flashLoan(address(this), assets, amounts, modes, address(this), data, 0);
        }
        if (_inFlight != FlashSource.NONE) revert FlashCallbackUnauthorized();

        IERC20(DEBT_ASSET).forceApprove(_lenderOf(lender), 0);
    }

    /**
     * @notice One flash round: repay, buy and supply the target (migrate only), then pull and redeem the source
     * @param ctx The round
     */
    function _executeRound(RoundContext memory ctx) internal {
        if (ctx.repay != 0) _repay(ctx.user, ctx.repay);
        if (ctx.operation == Operation.MIGRATE && ctx.amount != ctx.repay) _buyAndSupply(ctx, ctx.amount - ctx.repay);
        _pullAndRedeem(ctx.user, ctx.source, ctx.amount);
    }

    /**
     * @notice Repays `amount` of `user`'s variable debt with the gateway's debt asset
     * @param user The borrower
     * @param amount At most the borrower's current debt
     */
    function _repay(address user, uint256 amount) internal {
        IERC20(DEBT_ASSET).forceApprove(address(_pool), amount);
        _pool.repay(DEBT_ASSET, amount, VARIABLE_RATE_MODE, user);
        IERC20(DEBT_ASSET).forceApprove(address(_pool), 0);
    }

    /**
     * @notice Buys the target PT with `spend` of the debt asset and supplies it for the user
     * @dev The first supply of a call must leave the target enabled as the user's collateral.
     * @param ctx The round
     * @param spend Debt asset to spend
     */
    function _buyAndSupply(RoundContext memory ctx, uint256 spend) internal {
        uint256 ptBefore = IERC20(ctx.target.pt).balanceOf(address(this));
        IPendleRouterV4.LimitOrderData memory noLimitOrders;

        IERC20(DEBT_ASSET).forceApprove(PENDLE_ROUTER, spend);
        IPendleRouterV4(PENDLE_ROUTER)
            .swapExactTokenForPt(
                address(this), ctx.target.market, 0, _defaultApprox(), _tokenInput(spend), noLimitOrders
            );
        IERC20(DEBT_ASSET).forceApprove(PENDLE_ROUTER, 0);
        uint256 bought = IERC20(ctx.target.pt).balanceOf(address(this)) - ptBefore;
        IERC20(ctx.target.pt).forceApprove(address(_pool), bought);
        _pool.supply(ctx.target.pt, bought, ctx.user, 0);
        IERC20(ctx.target.pt).forceApprove(address(_pool), 0);
        if (_supplied == 0 && !_pool.getUserConfiguration(ctx.user).isUsingAsCollateral(ctx.target.reserveId)) {
            revert CollateralNotEnabled(ctx.target.pt);
        }

        _supplied += bought;
    }

    /**
     * @notice Pulls source aTokens from `user`, withdraws the PT, and redeems it at par
     * @dev The pull is the pool's health-factor check on `user`.
     * @param user The position owner
     * @param source The matured PT
     * @param amount The amount
     */
    function _pullAndRedeem(address user, SourceToken memory source, uint256 amount) internal {
        IERC20(source.aToken).safeTransferFrom(user, address(this), amount);
        _pool.withdraw(source.pt, amount, address(this));
        _redeemAtPar(source, amount);
    }

    /**
     * @notice Redeems matured PT through its YT and SY, requiring at least one debt asset per PT
     * @dev The YT redeems its whole PT balance, so outputs are measured, not assumed.
     * @param source The matured PT
     * @param amount PT to redeem
     */
    function _redeemAtPar(SourceToken memory source, uint256 amount) internal {
        uint256 syBefore = IERC20(source.sy).balanceOf(address(this));
        uint256 debtAssetBefore = IERC20(DEBT_ASSET).balanceOf(address(this));

        IERC20(source.pt).safeTransfer(source.yt, amount);
        IPendleYieldToken(source.yt).redeemPY(address(this));
        uint256 shares = IERC20(source.sy).balanceOf(address(this)) - syBefore;
        IPendleStandardizedYield(source.sy).redeem(address(this), shares, DEBT_ASSET, amount, false);
        uint256 received = IERC20(DEBT_ASSET).balanceOf(address(this)) - debtAssetBefore;
        if (received < amount) revert RedemptionShortfall(amount, received);
    }

    /**
     * @notice Tries the caller's EIP-2612 permit on the source aToken; a consumed permit leaves the pull to gate
     * @param pt The source PT
     * @param permit The signed permit
     */
    function _permitSource(address pt, PermitParams calldata permit) internal {
        address aToken = _requireListed(pt);

        try IERC20Permit(aToken)
            .permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s) {}
            catch {}
    }

    /**
     * @notice Pays the gateway's debt-asset balance above `entryBalance` to `to`
     * @param entryBalance The debt-asset balance at entry
     * @param to The recipient
     * @return excess The amount paid
     */
    function _sendExcess(uint256 entryBalance, address to) internal returns (uint256 excess) {
        uint256 balance = IERC20(DEBT_ASSET).balanceOf(address(this));
        if (balance <= entryBalance) return 0;

        excess = balance - entryBalance;
        IERC20(DEBT_ASSET).safeTransfer(to, excess);
    }

    /**
     * @notice Enforces the strictest of the caller's minimum, oracle floor and par floor
     * @param pt The target PT
     * @param spent Debt asset spent buying PT, excluding debt repayment
     * @param output Target PT supplied across all rounds
     * @param userMinimum The caller's minimum
     * @return oracleMinimum The oracle floor enforced on this purchase
     */
    function _requireMigrationOutput(address pt, uint256 spent, uint256 output, uint256 userMinimum)
        internal
        view
        returns (uint256 oracleMinimum)
    {
        oracleMinimum = _oracleMinimum(pt, spent);
        uint256 minimum = Math.max(Math.max(userMinimum, oracleMinimum), spent - spent / BPS_DENOMINATOR);
        if (output < minimum) revert OutputBelowMinimum(output, minimum);
    }

    /**
     * @notice Converts purchase spending to 90% of the pool oracle's PT equivalent, rounded up once
     * @dev Supported PTs share the debt asset's reserve decimals. Zero spending needs no price read.
     * @param pt The target PT
     * @param spent Debt asset spent buying PT across all rounds
     * @return The mandatory minimum in raw target PT units
     */
    function _oracleMinimum(address pt, uint256 spent) internal view returns (uint256) {
        if (spent == 0) return 0;

        IPriceOracleGetter oracle = _priceOracle();
        uint256 debtPrice = oracle.getAssetPrice(DEBT_ASSET);
        uint256 ptPrice = oracle.getAssetPrice(pt);
        if (debtPrice == 0) revert InvalidOraclePrice(DEBT_ASSET);
        if (ptPrice == 0) revert InvalidOraclePrice(pt);

        uint256 numerator = debtPrice * (BPS_DENOMINATOR - MAX_ORACLE_DEVIATION_BPS);
        uint256 denominator = ptPrice * BPS_DENOMINATOR;

        return Math.mulDiv(spent, numerator, denominator, Math.Rounding.Ceil);
    }

    /**
     * @notice Reads the final health factor without making optional reporting a condition of execution
     * @return healthFactor The pool's health factor, or zero if its account read fails
     * @return available Whether the health factor is available
     */
    function _readHealthFactor() internal view returns (uint256 healthFactor, bool available) {
        (bool success, uint256 configuration) =
            _readPoolValue(abi.encodeCall(_pool.getUserConfiguration, (msg.sender)), CONFIGURATION_BYTES);
        if (!success) return (0, false);
        if (!DataTypes.UserConfigurationMap(configuration).isBorrowingAny()) return (type(uint256).max, true);

        (success, healthFactor) =
            _readPoolValue(abi.encodeCall(_pool.getUserAccountData, (msg.sender)), ACCOUNT_DATA_BYTES);

        return success ? (healthFactor, true) : (0, false);
    }

    /**
     * @notice Reads the last word of a fixed-size pool response with bounded gas and copying
     * @param callData The encoded pool getter
     * @param size Expected response length in bytes
     * @return success Whether the getter returned exactly the expected data
     * @return value The final response word
     */
    function _readPoolValue(bytes memory callData, uint256 size) internal view returns (bool success, uint256 value) {
        bytes memory response = new bytes(size);
        address pool = address(_pool);
        uint256 gasLimit = Math.min(OPTIONAL_READ_GAS, gasleft() / 2);

        assembly ("memory-safe") {
            success := staticcall(gasLimit, pool, add(callData, 0x20), mload(callData), add(response, 0x20), size)
            success := and(success, eq(returndatasize(), size))
            value := mload(add(response, size))
        }
    }

    /**
     * @notice The pool's current price oracle
     * @return The oracle
     */
    function _priceOracle() internal view returns (IPriceOracleGetter) {
        return IPriceOracleGetter(_pool.ADDRESSES_PROVIDER().getPriceOracle());
    }

    /**
     * @notice Requires the caller's health factor to be at least `minimum`
     * @param minimum The caller's minimum, in WAD
     * @return healthFactor The checked health factor
     */
    function _requireHealthFactor(uint256 minimum) internal view returns (uint256 healthFactor) {
        (,,,,, healthFactor) = _pool.getUserAccountData(msg.sender);

        if (healthFactor < minimum) revert HealthFactorBelowMinimum(healthFactor, minimum);
    }

    /**
     * @notice Captures the gateway's balances at entry
     * @param ptOld The source PT
     * @param ptNew The target PT, zero for a close
     * @return entry The balances
     */
    function _snapshot(address ptOld, address ptNew) internal view returns (BalanceSnapshot memory entry) {
        entry.debtAsset = IERC20(DEBT_ASSET).balanceOf(address(this));
        entry.ptOld = IERC20(ptOld).balanceOf(address(this));
        if (ptNew != address(0)) entry.ptNew = IERC20(ptNew).balanceOf(address(this));
    }

    /**
     * @notice Requires the gateway to end a call on its entry balances
     * @param entry The entry balances
     * @param ptOld The source PT
     * @param ptNew The target PT, zero for a close
     */
    function _assertSnapshot(BalanceSnapshot memory entry, address ptOld, address ptNew) internal view {
        _assertBalance(DEBT_ASSET, entry.debtAsset);
        _assertBalance(ptOld, entry.ptOld);
        if (ptNew != address(0)) _assertBalance(ptNew, entry.ptNew);
    }

    /**
     * @notice Reverts unless the gateway holds exactly `expected` of `token`
     * @param token The token
     * @param expected The expected balance
     */
    function _assertBalance(address token, uint256 expected) internal view {
        uint256 actual = IERC20(token).balanceOf(address(this));

        if (actual != expected) revert BalanceMismatch(token, expected, actual);
    }

    /**
     * @notice A direct debt-asset input with no aggregator swap
     * @param amount The debt asset spent
     * @return input The router token input
     */
    function _tokenInput(uint256 amount) internal view returns (IPendleRouterV4.TokenInput memory input) {
        input.tokenIn = DEBT_ASSET;
        input.netTokenIn = amount;
        input.tokenMintSy = DEBT_ASSET;
    }

    /**
     * @notice Validates a matured source PT and resolves its tokens
     * @dev A listed reserve whose PT reads fail is not a PT.
     * @param pt The source PT
     * @return source The PT, its aToken, YT, and SY
     */
    function _resolveSource(address pt) internal view returns (SourceToken memory source) {
        address aToken = _requireListed(pt);
        (bool expired, address sy, address yt) = _readPrincipalToken(pt);
        if (!expired) revert PrincipalTokenNotMatured(pt);
        if (!IPendleStandardizedYield(sy).isValidTokenOut(DEBT_ASSET)) revert UnsupportedSy(sy);
        _requirePar(pt, sy, yt);

        return SourceToken({pt: pt, aToken: aToken, yt: yt, sy: sy});
    }

    /**
     * @notice Reads a PT's expiry flag, SY, and YT, reverting `NotPrincipalToken` if any read fails
     * @param pt The candidate PT
     * @return expired Whether the PT has matured
     * @return sy Its SY
     * @return yt Its YT
     */
    function _readPrincipalToken(address pt) internal view returns (bool expired, address sy, address yt) {
        try IPendleMaturityPrincipalToken(pt).isExpired() returns (bool isExpired_) {
            expired = isExpired_;
        } catch {
            revert NotPrincipalToken(pt);
        }
        try IPendleMaturityPrincipalToken(pt).SY() returns (address sy_) {
            sy = sy_;
        } catch {
            revert NotPrincipalToken(pt);
        }
        try IPendleMaturityPrincipalToken(pt).YT() returns (address yt_) {
            yt = yt_;
        } catch {
            revert NotPrincipalToken(pt);
        }
    }

    /**
     * @notice Resolves an enabled migration target
     * @param pt The target PT
     * @return target The PT, its market, and its reserve id
     */
    function _resolveTarget(address pt) internal view returns (TargetToken memory target) {
        address market = _markets[pt];
        if (market == address(0)) revert MigrationTargetNotEnabled(pt);
        if (IPendleMarket(market).isExpired()) revert TargetMarketExpired(market);
        _requirePar(pt, IPendleMaturityPrincipalToken(pt).SY(), IPendleMaturityPrincipalToken(pt).YT());

        return TargetToken({pt: pt, market: market, reserveId: _reserveId(pt)});
    }

    /**
     * @notice Restricts settlement to equal-unit PTs with fixed one-to-one SY, PY, and reserve indices
     * @dev A current par redemption quote is required; execution also enforces actual par proceeds.
     * @param pt The listed principal token
     * @param sy Its standardized yield token
     * @param yt Its yield token
     */
    function _requirePar(address pt, address sy, address yt) internal view {
        if (_pool.getReserveNormalizedIncome(pt) != WadRayMath.RAY) revert ReserveIndexNotPar(pt);

        uint256 decimals = _pool.getConfiguration(pt).getDecimals();
        if (
            decimals != _pool.getConfiguration(DEBT_ASSET).getDecimals()
                || IPendleStandardizedYield(sy).exchangeRate() != PAR_INDEX
                || IPendleYieldToken(yt).pyIndexStored() != PAR_INDEX
                || IPendleStandardizedYield(sy).previewRedeem(DEBT_ASSET, 10 ** decimals) < 10 ** decimals
        ) revert UnsupportedSy(sy);
    }

    /**
     * @notice Resolves max against both the user's source balance and approval
     * @param user The position owner
     * @param aToken The source aToken
     * @param requested The amount, or `type(uint256).max` for the lesser of balance and allowance
     * @return amount The non-zero amount
     */
    function _resolveAmount(address user, address aToken, uint256 requested) internal view returns (uint256 amount) {
        amount = requested == type(uint256).max
            ? Math.min(IERC20(aToken).balanceOf(user), IERC20(aToken).allowance(user, address(this)))
            : requested;
        if (amount == 0) revert InvalidAmount();
    }

    /**
     * @notice Picks the flash lender for a call and enforces the round budget
     * @param flashTotal Total to flash-borrow across rounds; zero skips the check
     * @param maxRounds The caller's round limit
     * @return lender The lender, `NONE` when nothing is borrowed
     * @return cash Per-round cash of the lender
     */
    function _selectFlashSource(uint256 flashTotal, uint256 maxRounds)
        internal
        view
        returns (FlashSource lender, uint256 cash)
    {
        if (flashTotal == 0) return (FlashSource.NONE, 0);

        (lender, cash) = _flashCapacity();
        if (cash == 0 || Math.ceilDiv(flashTotal, cash) > maxRounds) {
            revert InsufficientFlashLiquidity(flashTotal, cash, maxRounds);
        }
    }

    /**
     * @notice The eligible lender with the most cash, Morpho on a tie
     * @return lender The lender, `NONE` when neither has cash
     * @return cash Its cash
     */
    function _flashCapacity() internal view returns (FlashSource lender, uint256 cash) {
        uint256 morphoCash = IERC20(DEBT_ASSET).balanceOf(MORPHO);
        uint256 poolCash;
        try this.flashPoolCapacity{gas: OPTIONAL_READ_GAS}() returns (uint256 available) {
            poolCash = available;
        } catch {}

        if (poolCash > morphoCash) return (FlashSource.POOL, poolCash);
        if (morphoCash != 0) return (FlashSource.MORPHO, morphoCash);

        return (FlashSource.NONE, 0);
    }

    /**
     * @notice Fee-free cash of `FLASH_POOL`
     * @dev Zero unless the gateway holds the flash-borrower role and the reserve is active, unpaused, and
     *      flash-enabled; capped at the aToken supply, above which the pool rejects the loan.
     * @return cash The lendable debt asset
     */
    function _flashPoolCash() internal view returns (uint256 cash) {
        DataTypes.ReserveData memory reserve = FLASH_POOL.getReserveData(DEBT_ASSET);
        if (reserve.aTokenAddress == address(0)) return 0;

        (bool active,,,, bool paused) = reserve.configuration.getFlags();
        if (!active || paused || !reserve.configuration.getFlashLoanEnabled()) return 0;
        if (!IACLManager(FLASH_POOL.ADDRESSES_PROVIDER().getACLManager()).isFlashBorrower(address(this))) return 0;

        return
            Math.min(IERC20(DEBT_ASSET).balanceOf(reserve.aTokenAddress), IERC20(reserve.aTokenAddress).totalSupply());
    }

    /**
     * @notice The address of a flash lender
     * @param lender The lender
     * @return The lender's address, zero for `NONE`
     */
    function _lenderOf(FlashSource lender) internal view returns (address) {
        if (lender == FlashSource.MORPHO) return MORPHO;
        if (lender == FlashSource.POOL) return address(FLASH_POOL);

        return address(0);
    }

    /**
     * @notice The debt asset's variable-debt token in `POOL`
     * @return The variable-debt token
     */
    function _variableDebtToken() internal view returns (address) {
        return _reserveData(DEBT_ASSET).variableDebtTokenAddress;
    }

    /**
     * @notice An asset's reserve id in `POOL`
     * @param asset The reserve asset
     * @return The reserve id
     */
    function _reserveId(address asset) internal view returns (uint256) {
        return _reserveData(asset).id;
    }

    /**
     * @notice Reads a reserve's data from the position pool
     * @param asset The reserve asset
     * @return The reserve data
     */
    function _reserveData(address asset) internal view returns (DataTypes.ReserveData memory) {
        return _pool.getReserveData(asset);
    }

    /**
     * @notice Returns an asset's aToken in `POOL`, reverting when the asset is not listed
     * @param asset The reserve asset
     * @return aToken The aToken
     */
    function _requireListed(address asset) internal view returns (address aToken) {
        aToken = _reserveData(asset).aTokenAddress;
        if (aToken == address(0)) revert ReserveNotListed(asset);
    }

    /**
     * @notice Reverts with exactly the supplied bytes
     * @param data The revert data
     */
    function _revert(bytes memory data) internal pure {
        assembly ("memory-safe") {
            revert(add(data, 0x20), mload(data))
        }
    }

    /**
     * @notice Splits `remaining` into equal rounds of at most `cash`, returning the next round's size
     * @dev Same round count as `cash`-sized rounds, without a wei-scale tail.
     * @param remaining The amount still to flash-borrow
     * @param cash The lender's cash per round
     * @return The next round's amount
     */
    function _roundAmount(uint256 remaining, uint256 cash) internal pure returns (uint256) {
        return Math.ceilDiv(remaining, Math.ceilDiv(remaining, cash));
    }

    /**
     * @notice Router search bounds whose zero off-chain guess, with no limit orders, selects the simple on-chain search
     * @dev The simple search applies its own settings; the other bounds act only if the router stops selecting it.
     * @return The default bounds
     */
    function _defaultApprox() internal pure returns (IPendleRouterV4.ApproxParams memory) {
        return IPendleRouterV4.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: DEFAULT_MAX_ITERATION,
            eps: DEFAULT_EPS
        });
    }

    /**
     * @notice Clamps max to both debt and source value; rejects an explicit repayment above the migrated amount
     * @param requested The requested repayment
     * @param debt The user's debt
     * @param ptAmount The migrated amount
     * @return repay The clamped repayment
     */
    function _clampRepay(uint256 requested, uint256 debt, uint256 ptAmount) internal pure returns (uint256 repay) {
        repay = requested == type(uint256).max ? Math.min(debt, ptAmount) : Math.min(requested, debt);
        if (repay > ptAmount) revert InvalidAmount();
    }

    /*//////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Shared callback body: consumes the in-flight flag, runs the round, approves the lender's pull
     * @param expected The lender this callback belongs to
     * @param lender Its address
     * @param amount The amount lent
     * @param data The gateway-encoded round
     */
    function _runFlashRound(FlashSource expected, address lender, uint256 amount, bytes calldata data) private {
        if (_inFlight != expected || keccak256(data) != _roundHash) revert FlashCallbackUnauthorized();
        RoundContext memory ctx = abi.decode(data, (RoundContext));
        if (ctx.amount != amount) revert FlashCallbackUnauthorized();

        _inFlight = FlashSource.NONE;
        _roundHash = bytes32(0);
        _executeRound(ctx);
        IERC20(DEBT_ASSET).forceApprove(lender, amount);
    }
}
