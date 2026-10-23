// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPool} from "@neverland-money/lending-core/contracts/interfaces/IPool.sol";

/**
 * @title INeverlandPendleLeverager
 * @author Neverland
 * @notice Caller-owned PT positions with raw token units, WAD health factors and inclusive deadlines.
 */
interface INeverlandPendleLeverager {
    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Raw PT principal and optional purchase.
     * @param initialPtAmount Nonzero raw PT pulled from the caller.
     * @param borrowAmount Purchase budget; zero seeds without debt.
     * @param minPtOut Minimum purchased PT, excluding principal; zero for an unleveraged seed.
     * @param minHealthFactor Final account health minimum in WAD.
     * @param deadline Inclusive deadline.
     */
    struct CreateParams {
        uint256 initialPtAmount;
        uint256 borrowAmount;
        uint256 minPtOut;
        uint256 minHealthFactor;
        uint256 deadline;
    }

    /**
     * @notice Single position-pool mode-2 purchase.
     * @param borrowAmount Nonzero debt asset borrowed on behalf of the caller.
     * @param minPtOut Minimum purchased PT, also subject to oracle and par floors.
     * @param minHealthFactor Final account health minimum in WAD.
     * @param deadline Inclusive deadline.
     */
    struct IncreaseParams {
        uint256 borrowAmount;
        uint256 minPtOut;
        uint256 minHealthFactor;
        uint256 deadline;
    }

    /**
     * @notice Independent collateral and cash budgets.
     * @param ptAmount Total PT withdrawn and converted; max uses min(aPT balance, allowance).
     * @param repayAmount Required initial cash repayment capped at entry debt; max clears freshly observed debt.
     * @param maxCashRepaid Strict cap on total debt-asset cash repaid; max opts out and zero is invalid.
     * @param minDebtAssetOut Minimum aggregate conversion output, including residual PT.
     * @param minHealthFactor Final WAD health minimum, also bounded by the entry health factor.
     * @param maxRounds Maximum external flash rounds; direct repayment does not count.
     * @param deadline Inclusive deadline.
     */
    struct DecreaseParams {
        uint256 ptAmount;
        uint256 repayAmount;
        uint256 maxCashRepaid;
        uint256 minDebtAssetOut;
        uint256 minHealthFactor;
        uint256 maxRounds;
        uint256 deadline;
    }

    /**
     * @notice Observed operation amounts and settled account state.
     * @param principalSupplied Raw PT principal supplied by creation.
     * @param ptSupplied Purchased PT supplied, excluding principal.
     * @param ptWithdrawn Caller PT withdrawn and converted.
     * @param debtBefore Caller variable debt at entry.
     * @param debtAfter Caller variable debt after pool settlement.
     * @param cashBorrowed Debt asset borrowed for purchases; zero for decreases.
     * @param cashRepaid Cash spent repaying caller debt; rounding may differ from debt reduction.
     * @param surplus Operation cash returned to caller.
     * @param healthFactorAfter Final full-account health factor in WAD.
     * @param flashSource Selected lender, zero for a seed without borrowing.
     * @param flashCash Lender's available per-round capacity, rather than the flash amount.
     * @param rounds Actual flash rounds.
     */
    struct PositionResult {
        uint256 principalSupplied;
        uint256 ptSupplied;
        uint256 ptWithdrawn;
        uint256 debtBefore;
        uint256 debtAfter;
        uint256 cashBorrowed;
        uint256 cashRepaid;
        uint256 surplus;
        uint256 healthFactorAfter;
        address flashSource;
        uint256 flashCash;
        uint256 rounds;
    }

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice A token balance or scaled aPT balance violates operation accounting.
     * @param token Token whose balance was checked.
     * @param expected Required raw or scaled token balance.
     * @param actual Observed balance in the same units.
     */
    error BalanceMismatch(address token, uint256 expected, uint256 actual);

    /**
     * @notice The repayment target exceeds the unused debt-asset cash ceiling.
     * @param required Raw debt-asset repayment target for the next payment.
     * @param remaining Unused part of the caller's maxCashRepaid cap, in the same units.
     */
    error CashRepaymentLimitExceeded(uint256 required, uint256 remaining);

    /// @notice Supplied PT was not enabled as caller collateral.
    error CollateralNotEnabled();

    /// @notice The inclusive deadline has passed.
    error DeadlineExpired();

    /**
     * @notice Settled caller debt violates borrowing, reduction or full-repayment invariants.
     * @param beforeDebt Caller variable debt at entry, in raw debt-asset units.
     * @param afterDebt Caller variable debt after settlement, in the same units.
     */
    error DebtMismatch(uint256 beforeDebt, uint256 afterDebt);

    /// @notice A callback is missing, replayed, malformed, outside an action or fails context binding.
    error FlashCallbackUnauthorized();

    /**
     * @notice Final full-account health fails the applicable minimum.
     * @param actual Observed final health factor in WAD.
     * @param minimum Required health factor in WAD.
     */
    error HealthFactorBelowMinimum(uint256 actual, uint256 minimum);

    /**
     * @notice A required flash has insufficient eligible debt-asset liquidity.
     * @param required Raw debt-asset cash the flash must supply: the purchase amount,
     *        or the remaining repayment target.
     * @param available Eligible flash cash in the same units: position-pool capacity for a purchase,
     *        zero for a decrease.
     */
    error InsufficientFlashLiquidity(uint256 required, uint256 available);

    /**
     * @notice A required flash has no usable remaining proportional PT allocation.
     * @param remainingRepayment Raw debt-asset repayment target still outstanding.
     * @param remainingPt Raw PT left to allocate.
     */
    error InsufficientPtBudget(uint256 remainingRepayment, uint256 remainingPt);

    /**
     * @notice Action-generated cash cannot settle the callback's flash principal.
     * @param required Flash principal to settle, in raw debt-asset units.
     * @param available Action-generated cash above the action-entry balance, in the same units.
     */
    error InsufficientRepaymentProceeds(uint256 required, uint256 available);

    /// @notice A zero amount or token movement violates its budget.
    error InvalidAmount();

    /**
     * @notice A dependency lacks code, a receiver is zero, or the two pools are identical.
     * @param dependency Invalid dependency or recipient address.
     */
    error InvalidDependency(address dependency);

    /**
     * @notice Market relationships or pinned reserve identities are inconsistent.
     * @param market Configured Pendle market.
     */
    error InvalidMarket(address market);

    /**
     * @notice An oracle price is zero.
     * @param asset Asset with an invalid oracle price.
     */
    error InvalidOraclePrice(address asset);

    /// @notice Simulation calldata does not select one supported action.
    error InvalidSimulationCall();

    /// @notice Construction or any action is attempted at or after market or PT expiry.
    error MarketExpired();

    /**
     * @notice Measured output fails the strictest applicable minimum.
     * @param output Observed output in raw token units.
     * @param minimum Required output in the same units.
     */
    error OutputBelowMinimum(uint256 output, uint256 minimum);

    /// @notice Ownership renunciation is disabled.
    error OwnershipRequired();

    /**
     * @notice PT reserve normalized income is not one ray.
     * @param pt Principal token whose reserve index changed.
     */
    error ReserveIndexNotPar(address pt);

    /**
     * @notice The position pool does not list the asset.
     * @param asset Asset whose reserve has no receipt token.
     */
    error ReserveNotListed(address asset);

    /**
     * @notice Another flash is necessary after exhausting the caller's flash-round limit.
     * @param remainingRepayment Raw debt-asset repayment target still outstanding.
     * @param maxRounds Caller's external flash-round limit.
     */
    error RoundLimitExceeded(uint256 remainingRepayment, uint256 maxRounds);

    /**
     * @notice SY routes, equal decimals, par indices or redemption quote are unsupported.
     * @param sy Unsupported standardized yield token.
     */
    error UnsupportedSy(address sy);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Owner recovered an ERC20 balance.
     * @param token Recovered ERC20 token.
     * @param to Recipient of the recovered tokens.
     * @param amount Raw token amount transferred.
     */
    event ERC20Recovered(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice Caller withdrew PT, repaid cash and received the reported surplus and round outcome.
     * @param user Caller whose lending position changed.
     * @param ptWithdrawn Raw PT withdrawn and converted.
     * @param cashRepaid Raw debt asset spent repaying caller debt.
     * @param debtAfter Caller variable debt after settlement.
     * @param surplus Raw debt asset returned to the caller.
     * @param rounds Flash rounds executed.
     */
    event LeverageDecreased(
        address indexed user,
        uint256 ptWithdrawn,
        uint256 cashRepaid,
        uint256 debtAfter,
        uint256 surplus,
        uint256 rounds
    );

    /**
     * @notice Caller purchased collateral and opened variable debt.
     * @param user Caller whose lending position changed.
     * @param ptSupplied Raw purchased PT supplied as collateral.
     * @param cashBorrowed Raw debt asset borrowed for the purchase.
     * @param debtAfter Caller variable debt after settlement.
     */
    event LeverageIncreased(address indexed user, uint256 ptSupplied, uint256 cashBorrowed, uint256 debtAfter);

    /**
     * @notice Caller principal and purchased PT were supplied, with the reported settled debt.
     * @param user Caller whose lending position changed.
     * @param principalSupplied Raw PT principal supplied by the caller.
     * @param ptSupplied Purchased PT supplied, excluding principal.
     * @param cashBorrowed Raw debt asset borrowed for the purchase.
     * @param debtAfter Caller variable debt after settlement.
     */
    event PositionCreated(
        address indexed user, uint256 principalSupplied, uint256 ptSupplied, uint256 cashBorrowed, uint256 debtAfter
    );

    /*//////////////////////////////////////////////////////////////
                                  ADMIN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Owner-only non-reentrant token recovery.
     * @param token ERC20 to recover.
     * @param to Nonzero recipient.
     * @param amount Raw amount.
     */
    function emergencyTokenTransfer(address token, address to, uint256 amount) external;

    /**
     * @notice Ownership renunciation is disabled.
     * @dev Reverts on every call: non-owners fail the owner check first, the owner gets OwnershipRequired.
     */
    function renounceOwnership() external view;

    /*//////////////////////////////////////////////////////////////
                              USER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Supply raw PT and optionally buy more through one delegated mode-2 flash loan.
     * @param params Principal, purchase and protection parameters; requires PT approval and debt delegation.
     * @return result Observed operation amounts and settled state.
     */
    function createPosition(CreateParams calldata params) external returns (PositionResult memory result);

    /**
     * @notice Buy and supply PT using caller variable-debt delegation.
     * @param params Purchase and protection parameters.
     * @return result Observed operation amounts and settled state.
     */
    function increaseLeverage(IncreaseParams calldata params) external returns (PositionResult memory result);

    /**
     * @notice Repay caller debt and convert approved aPT; settled surplus repays more debt up to the cash cap.
     * @dev Cash left after debt clearance, cap exhaustion or a partial payment too small to burn a share is refunded.
     * @param params Independent PT/cash budgets and protections; requires aPT approval.
     * @return result Observed operation amounts and settled state.
     */
    function decreaseLeverage(DecreaseParams calldata params) external returns (PositionResult memory result);

    /*//////////////////////////////////////////////////////////////
                                PREVIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Execute creation as the caller and roll back all effects; rethrow action errors.
     * @param params Creation parameters.
     * @return result Simulated operation result.
     */
    function previewCreatePosition(CreateParams calldata params) external returns (PositionResult memory result);

    /**
     * @notice Execute an increase as the caller and roll back all effects; rethrow action errors.
     * @param params Increase parameters.
     * @return result Simulated operation result.
     */
    function previewIncreaseLeverage(IncreaseParams calldata params) external returns (PositionResult memory result);

    /**
     * @notice Execute a decrease as the caller and roll back all effects; rethrow action errors.
     * @param params Decrease parameters.
     * @return result Simulated operation result.
     */
    function previewDecreaseLeverage(DecreaseParams calldata params) external returns (PositionResult memory result);

    /**
     * @notice Revert with an ABI (bool success, bytes result) envelope for a supported action.
     * @param callData Encoded createPosition, increaseLeverage or decreaseLeverage calldata.
     */
    function simulate(bytes calldata callData) external;

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Maximum oracle discount accepted by conversion output floors, in basis points.
     * @return Maximum oracle deviation in basis points.
     */
    function MAX_ORACLE_DEVIATION_BPS() external view returns (uint256);

    /**
     * @notice Position pool; caller positions remain on their lending accounts.
     * @return Pool holding caller collateral and variable debt.
     */
    function POOL() external view returns (IPool);

    /**
     * @notice Pinned debt asset used for SY input and output.
     * @return Debt asset address.
     */
    function DEBT_ASSET() external view returns (address);

    /**
     * @notice Pinned external Morpho repayment lender.
     * @return Morpho lender address.
     */
    function MORPHO() external view returns (address);

    /**
     * @notice Pinned external pool repayment lender, distinct from POOL.
     * @return External pool used for repayment flash loans.
     */
    function FLASH_POOL() external view returns (IPool);

    /**
     * @notice Pinned typed Pendle router.
     * @return Pendle router address.
     */
    function PENDLE_ROUTER() external view returns (address);

    /**
     * @notice Pinned Pendle market.
     * @return Pendle market address.
     */
    function MARKET() external view returns (address);

    /**
     * @notice Pinned principal token.
     * @return Principal token address.
     */
    function PT() external view returns (address);

    /**
     * @notice Pinned standardized yield token.
     * @return Standardized yield token address.
     */
    function SY() external view returns (address);

    /**
     * @notice Pinned yield token checked against the market and PT bindings.
     * @return Yield token address.
     */
    function YT() external view returns (address);

    /**
     * @notice PT receipt token in the position pool.
     * @return PT receipt token address.
     */
    function A_PT() external view returns (address);

    /**
     * @notice Active, unpaused, flash-enabled position-pool cash capped at aToken supply.
     * @dev Informational liquidity only; caller borrow power and delegation remain separately enforced.
     * @return Available purchase cash in raw debt-asset units.
     */
    function leverageCapacity() external view returns (uint256);

    /**
     * @notice Eligible external lender and capacity; Morpho wins ties, failed optional pool reads count as zero.
     * @return source Lender address or zero.
     * @return cash Available per-round liquidity.
     */
    function flashCapacity() external view returns (address source, uint256 cash);

    /**
     * @notice Role-authorized, active, unpaused, flash-enabled external pool capacity capped at aToken supply.
     * @dev Strict getter; read failures revert. flashCapacity catches optional failures.
     * @return Available external pool cash in raw debt-asset units.
     */
    function flashPoolCapacity() external view returns (uint256);
}
