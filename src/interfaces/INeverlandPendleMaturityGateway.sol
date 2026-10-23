// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPool} from "@neverland-money/lending-core/contracts/interfaces/IPool.sol";

/**
 * @title INeverlandPendleMaturityGateway
 * @author Neverland
 * @notice Closes or migrates a levered position in a matured Pendle PT, in one transaction
 * @dev Every user action acts only on the caller's own position in `POOL`. The matured PT redeems at par through
 *      its YT and SY; fee-free flash liquidity from Morpho or `FLASH_POOL` funds the repayment or the purchase
 *      before the source collateral leaves the position.
 */
interface INeverlandPendleMaturityGateway {
    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Parameters of a close
     * @param ptOld The matured source PT
     * @param ptAmount Source PT to use, `type(uint256).max` for the lesser of aToken balance and allowance
     * @param minSurplusOut Minimum debt asset paid to `to`
     * @param to Recipient of the surplus debt asset
     * @param maxRounds Maximum flash rounds
     */
    struct CloseParams {
        address ptOld;
        uint256 ptAmount;
        uint256 minSurplusOut;
        address to;
        uint256 maxRounds;
    }

    /**
     * @notice Observed result of a close or its reverted simulation
     * @param ptAmount Source PT consumed
     * @param debt Variable debt before the call
     * @param debtRepaid Actual decrease in variable debt
     * @param debtAfter Variable debt after the call
     * @param surplus Debt asset paid to the recipient
     * @param flashSource Lender used, or zero without a flash loan
     * @param flashCash Lender cash used to size each round
     * @param rounds Flash rounds executed
     * @param healthFactorAfter Pool health factor, WAD; zero when unavailable
     * @param healthFactorAvailable Whether the pool health factor could be read
     */
    struct CloseResult {
        uint256 ptAmount;
        uint256 debt;
        uint256 debtRepaid;
        uint256 debtAfter;
        uint256 surplus;
        address flashSource;
        uint256 flashCash;
        uint256 rounds;
        uint256 healthFactorAfter;
        bool healthFactorAvailable;
    }

    /**
     * @notice Parameters of a migration
     * @param ptOld The matured source PT
     * @param ptAmount Source PT to migrate, `type(uint256).max` for the lesser of aToken balance and allowance
     * @param ptNew The registered target PT
     * @param repayAmount Source PT value used to repay debt first; max repays up to the debt or migrated amount
     * @param minPtOut Minimum target PT supplied across all rounds; the mandatory oracle and par floors also apply
     * @param minHealthFactor WAD; zero leaves only the pool's own `HF >= 1`
     * @param maxRounds Maximum flash rounds
     */
    struct MigrateParams {
        address ptOld;
        uint256 ptAmount;
        address ptNew;
        uint256 repayAmount;
        uint256 minPtOut;
        uint256 minHealthFactor;
        uint256 maxRounds;
    }

    /**
     * @notice Observed result of a migration or its reverted simulation
     * @param ptAmount Source PT consumed
     * @param debt Variable debt before the call
     * @param repay Actual decrease in variable debt
     * @param spent Debt asset spent buying target PT
     * @param ptOut Target PT bought and supplied
     * @param debtAfter Variable debt after the call
     * @param surplus Excess debt asset paid to the caller
     * @param flashSource Lender used
     * @param flashCash Lender cash used to size each round
     * @param rounds Flash rounds executed
     * @param oracleMinimumPtOut Oracle floor enforced on the actual purchase spending
     * @param healthFactorAfter Pool health factor, WAD; zero when unavailable
     * @param healthFactorAvailable Whether the pool health factor could be read
     */
    struct MigrateResult {
        uint256 ptAmount;
        uint256 debt;
        uint256 repay;
        uint256 spent;
        uint256 ptOut;
        uint256 debtAfter;
        uint256 surplus;
        address flashSource;
        uint256 flashCash;
        uint256 rounds;
        uint256 oracleMinimumPtOut;
        uint256 healthFactorAfter;
        bool healthFactorAvailable;
    }

    /**
     * @notice An enabled migration target
     * @param pt The target PT
     * @param market Its registered Pendle market
     */
    struct MigrationTarget {
        address pt;
        address market;
    }

    /**
     * @notice An EIP-2612 permit over the source aToken
     * @param value The permitted amount
     * @param deadline The permit deadline
     * @param v The V component of the signature
     * @param r The R component of the signature
     * @param s The S component of the signature
     */
    struct PermitParams {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Thrown when the gateway does not end a call on its entry balance of a token
     * @param token The token
     * @param expected The entry balance
     * @param actual The balance at the end of the call
     */
    error BalanceMismatch(address token, uint256 expected, uint256 actual);

    /**
     * @notice Thrown when the caller's collateral flag for the target PT is off after the first supply
     * @param pt The target PT
     */
    error CollateralNotEnabled(address pt);

    /// @notice Thrown when a flash callback fails its sender, initiator, asset, premium, flag, amount, or data-hash guard
    error FlashCallbackUnauthorized();

    /**
     * @notice Thrown when a migration leaves the caller below the requested health factor
     * @param healthFactor The health factor after the migration
     * @param minimum The requested minimum
     */
    error HealthFactorBelowMinimum(uint256 healthFactor, uint256 minimum);

    /**
     * @notice Thrown when the flash liquidity cannot cover the amount within the round limit
     * @param required The amount still to flash-borrow
     * @param perRound The lender's cash per round
     * @param maxRounds The caller's round limit
     */
    error InsufficientFlashLiquidity(uint256 required, uint256 perRound, uint256 maxRounds);

    /// @notice Thrown on a zero amount, or a repayment above the migrated amount
    error InvalidAmount();

    /**
     * @notice Thrown when a market's SY or YT does not match its PT
     * @param market The market
     */
    error InvalidMarket(address market);

    /**
     * @notice Thrown when the pool oracle returns a zero price for a purchase asset
     * @param asset The unpriced asset
     */
    error InvalidOraclePrice(address asset);

    /// @notice Thrown when a simulation targets anything other than a user action
    error InvalidSimulationCall();

    /**
     * @notice Thrown when a PT is not an enabled migration target
     * @param pt The PT
     */
    error MigrationTargetNotEnabled(address pt);

    /**
     * @notice Thrown when a listed reserve fails the PT reads
     * @param asset The reserve asset
     */
    error NotPrincipalToken(address asset);

    /**
     * @notice Thrown when an output falls below the caller's minimum or either mandatory output floor
     * @param output The output
     * @param minimum The enforced minimum
     */
    error OutputBelowMinimum(uint256 output, uint256 minimum);

    /// @notice Thrown when ownership renouncement is attempted; the gateway must stay owned
    error OwnershipRequired();

    /**
     * @notice Thrown when the source PT has not matured
     * @param pt The source PT
     */
    error PrincipalTokenNotMatured(address pt);

    /**
     * @notice Thrown when a par redemption returns less than one debt asset per PT
     * @param expected The PT redeemed
     * @param received The debt asset received
     */
    error RedemptionShortfall(uint256 expected, uint256 received);

    /**
     * @notice Thrown when a PT reserve's normalized income is not exactly 1e27
     * @param pt The PT reserve asset
     */
    error ReserveIndexNotPar(address pt);

    /**
     * @notice Thrown when an asset is not a listed reserve of `POOL`
     * @param asset The asset
     */
    error ReserveNotListed(address asset);

    /**
     * @notice Thrown when a target's Pendle market has expired
     * @param market The market
     */
    error TargetMarketExpired(address market);

    /**
     * @notice Thrown when an SY fails the supported-token, matching-unit, unit-index, or par-quote checks
     * @param sy The SY
     */
    error UnsupportedSy(address sy);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when the owner recovers an ERC20 held by the gateway
     * @param token The token recovered
     * @param to The recipient
     * @param amount The amount recovered
     */
    event ERC20Recovered(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice Emitted when a migration target is removed
     * @param pt The target PT
     * @param market Its market at removal
     */
    event MigrationTargetRemoved(address indexed pt, address indexed market);

    /**
     * @notice Emitted when a migration target is added or re-pointed
     * @param pt The target PT
     * @param market Its registered market
     */
    event MigrationTargetSet(address indexed pt, address indexed market);

    /**
     * @notice Emitted after a close
     * @param user The position owner
     * @param ptOld The matured source PT
     * @param ptRedeemed Source PT redeemed
     * @param debtRepaid Decrease of the caller's debt; lending-core rounding can make it a few wei below the debt asset spent
     * @param surplus Debt asset paid to `to`
     * @param to The surplus recipient
     * @param rounds Flash rounds run
     */
    event PositionClosed(
        address indexed user,
        address indexed ptOld,
        uint256 ptRedeemed,
        uint256 debtRepaid,
        uint256 surplus,
        address indexed to,
        uint256 rounds
    );

    /**
     * @notice Emitted after a migration
     * @param user The position owner
     * @param ptOld The matured source PT
     * @param ptNew The target PT
     * @param ptOldAmount Source PT migrated
     * @param ptNewAmount Target PT supplied
     * @param debtRepaid Decrease of the caller's debt; lending-core rounding can make it a few wei below the debt asset spent
     * @param rounds Flash rounds run
     */
    event PositionMigrated(
        address indexed user,
        address indexed ptOld,
        address indexed ptNew,
        uint256 ptOldAmount,
        uint256 ptNewAmount,
        uint256 debtRepaid,
        uint256 rounds
    );

    /*//////////////////////////////////////////////////////////////
                                  ADMIN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Recovers ERC20 tokens held by the gateway (owner only)
     * @param token The token to recover
     * @param to The recipient
     * @param amount The amount to recover
     */
    function emergencyTokenTransfer(address token, address to, uint256 amount) external;

    /**
     * @notice Removes an enabled migration target (owner only)
     * @param pt The target PT
     */
    function removeMigrationTarget(address pt) external;

    /**
     * @notice Enables a market's PT as a migration target, or re-points an enabled one (owner only)
     * @dev The PT must be listed in `POOL`, match the market's SY and YT, and its SY must accept and return the
     *      debt asset. Reserve decimals must match, SY and PY indices must equal 1e18, reserve normalized income
     *      must equal 1e27, and the one-unit SY redemption quote must reach par. The market must not be expired.
     * @param market The Pendle market of the target PT
     */
    function setMigrationTarget(address market) external;

    /**
     * @notice Renouncing ownership is disabled; the gateway must stay able to recover stuck tokens
     * @dev Reverts on every call.
     */
    function renounceOwnership() external view;

    /*//////////////////////////////////////////////////////////////
                              USER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Repays the caller's debt from its matured PT at par and pays the surplus to `to`
     * @dev The caller must have approved the gateway on the source aToken.
     * @param params The close parameters
     * @return result The observed result
     */
    function close(CloseParams calldata params) external returns (CloseResult memory result);

    /**
     * @notice Close with an EIP-2612 permit on the source aToken
     * @dev A permit already consumed elsewhere is tolerated; the allowance then gates the pull.
     * @param params The close parameters
     * @param permit The signed permit
     * @return result The observed result
     */
    function closeWithPermit(CloseParams calldata params, PermitParams calldata permit)
        external
        returns (CloseResult memory result);

    /**
     * @notice Moves the caller's matured PT into a registered target PT, optionally repaying debt first
     * @dev The caller must have approved the gateway on the source aToken. The debt falls by the clamped
     *      `repayAmount`, up to lending-core rounding. Max repays the lesser of debt and migrated PT; an explicit
     *      amount is capped at debt and must fit within the migrated amount. Total PT supplied must meet
     *      `minPtOut`, 90% of the pool oracle's PT equivalent rounded up, and `spent - spent / 10_000`.
     *      Spending excludes debt repayment; supported PTs and the debt asset share the same reserve decimals.
     * @param params The migration parameters
     * @return result The observed result
     */
    function migrate(MigrateParams calldata params) external returns (MigrateResult memory result);

    /**
     * @notice Migrate with an EIP-2612 permit on the source aToken
     * @dev A permit already consumed elsewhere is tolerated; the allowance then gates the pull.
     * @param params The migration parameters
     * @param permit The signed permit
     * @return result The observed result
     */
    function migrateWithPermit(MigrateParams calldata params, PermitParams calldata permit)
        external
        returns (MigrateResult memory result);

    /*//////////////////////////////////////////////////////////////
                                PREVIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Simulates the caller's close and returns its observed result without retaining any state changes
     * @dev Uses the exact `close` entrypoint, including approvals, limits and every external call. Use `eth_call`
     *      with the position owner as the sender; this function cannot run under `STATICCALL`.
     * @param params The same parameters to pass to `close`
     * @return result The observed result at the simulated state
     */
    function previewClose(CloseParams calldata params) external returns (CloseResult memory result);

    /**
     * @notice Simulates `closeWithPermit`, rolling back the permit and the entire close
     * @param params The close parameters
     * @param permit The signed permit
     * @return result The observed result at the simulated state
     */
    function previewCloseWithPermit(CloseParams calldata params, PermitParams calldata permit)
        external
        returns (CloseResult memory result);

    /**
     * @notice Simulates the caller's migration and returns its observed result without retaining any state changes
     * @dev Uses the exact `migrate` entrypoint, including Pendle swaps, approvals, limits and every round. Use
     *      `eth_call` with the position owner as the sender; no caller-supplied output estimate is used.
     * @param params The same parameters to pass to `migrate`
     * @return result The observed result at the simulated state
     */
    function previewMigrate(MigrateParams calldata params) external returns (MigrateResult memory result);

    /**
     * @notice Simulates `migrateWithPermit`, rolling back the permit and the entire migration
     * @param params The migration parameters
     * @param permit The signed permit
     * @return result The observed result at the simulated state
     */
    function previewMigrateWithPermit(MigrateParams calldata params, PermitParams calldata permit)
        external
        returns (MigrateResult memory result);

    /**
     * @notice Executes a user action in a frame that always reverts
     * @dev The preview wrappers delegate-call this function to preserve the caller. Accepted user actions always
     *      revert with `abi.encode(bool success, bytes result)`, including direct calls. Other selectors reject
     *      with `InvalidSimulationCall`; an action failure is carried unchanged inside the envelope.
     * @param callData ABI-encoded close, migrate, or corresponding permit call
     */
    function simulate(bytes calldata callData) external;

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The debt asset of `POOL`, which each matured PT redeems into
     * @return The debt asset
     */
    function DEBT_ASSET() external view returns (address);

    /**
     * @notice The pool used for fee-free flash loans when the gateway holds its flash-borrower role
     * @return The flash pool
     */
    function FLASH_POOL() external view returns (IPool);

    /**
     * @notice Maximum output shortfall from the pool oracle's PT equivalent, in basis points
     * @return The fixed 1,000 bps (10%) cap
     */
    function MAX_ORACLE_DEVIATION_BPS() external view returns (uint256);

    /**
     * @notice The Morpho instance used for fee-free flash loans
     * @return The Morpho address
     */
    function MORPHO() external view returns (address);

    /**
     * @notice The Pendle router used to buy target PTs
     * @return The router address
     */
    function PENDLE_ROUTER() external view returns (address);

    /**
     * @notice The pool holding the positions
     * @return The pool
     */
    function POOL() external view returns (IPool);

    /**
     * @notice The flash lender a call would use and its per-round cash
     * @return source `MORPHO`, `FLASH_POOL`, or zero when neither has cash
     * @return cash The lender's cash per round
     */
    function flashCapacity() external view returns (address source, uint256 cash);

    /**
     * @notice Reads eligible global-pool liquidity; a failed dependency read reverts
     * @dev The combined flashCapacity view treats failure of this optional lender as zero capacity.
     * @return cash Fee-free global-pool cash available to the gateway
     */
    function flashPoolCapacity() external view returns (uint256 cash);

    /**
     * @notice The registered market of a migration target
     * @param pt The target PT
     * @return market The market, zero when not enabled
     */
    function migrationMarket(address pt) external view returns (address market);

    /**
     * @notice Every enabled migration target
     * @return targets The `(pt, market)` pairs
     */
    function migrationTargets() external view returns (MigrationTarget[] memory targets);
}
