// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IPool} from "@neverland-money/lending-core/contracts/interfaces/IPool.sol";
import {AaveOracle} from "@neverland-money/lending-core/contracts/misc/AaveOracle.sol";
import {ACLManager} from "@neverland-money/lending-core/contracts/protocol/configuration/ACLManager.sol";
import {
    PoolAddressesProvider
} from "@neverland-money/lending-core/contracts/protocol/configuration/PoolAddressesProvider.sol";
import {
    ReserveConfiguration
} from "@neverland-money/lending-core/contracts/protocol/libraries/configuration/ReserveConfiguration.sol";
import {Errors} from "@neverland-money/lending-core/contracts/protocol/libraries/helpers/Errors.sol";
import {DataTypes} from "@neverland-money/lending-core/contracts/protocol/libraries/types/DataTypes.sol";
import {
    DefaultReserveInterestRateStrategy
} from "@neverland-money/lending-core/contracts/protocol/pool/DefaultReserveInterestRateStrategy.sol";
import {Pool} from "@neverland-money/lending-core/contracts/protocol/pool/Pool.sol";

import {MarketHoursPriceAdapter} from "../../../src/oracles/MarketHoursPriceAdapter.sol";
import {SessionCalendar} from "../../../src/oracles/SessionCalendar.sol";
import {MarketHoursSentinel} from "../../../src/risk/MarketHoursSentinel.sol";
import {SessionWindowTestBase} from "../../_utils/SessionWindowTestBase.sol";

import {MockChainlinkAggregator} from "../../_utils/MockChainlinkAggregator.sol";
import {MockERC20} from "../../_utils/MockERC20.sol";
import {TestPoolConfigurator} from "../mocks/TestPoolConfigurator.sol";

/**
 * @title MarketSafetyLendingCoreTest
 * @author Neverland
 * @notice Exercises stock-market safety through the actual Neverland lending core
 * @dev The pool, aTokens, debt tokens, oracle, adapters, calendar, and sentinel are real contracts; the
 *      configurator is a test harness that drives the real pool through the core's own entry points, because
 *      the core's PoolConfigurator cannot compile with the optimizer disabled. External prices are the only
 *      controlled fixture: nothing else feeds the market-safety contracts. The pool profile is the launch one:
 *      two borrowable stocks at conservative parameters, USDG and USDC as stable debt, and one E-Mode category
 *      holding every stock against the stables at boosted parameters with no price override.
 */
contract MarketSafetyLendingCoreTest is SessionWindowTestBase {
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Session timing, independent of wall-clock test execution
    uint256 private constant START = 366 days;
    uint256 private constant END = START + 5 days;
    uint256 private constant NEXT_START = END + 2 days;

    /// @dev Launch settings; zero interest isolates the liquidation boundary from elapsed time in this fixture
    uint8 private constant STOCKS_EMODE = 1;
    uint256 private constant GRACE = 1 hours;
    uint256 private constant MAX_SESSION_AGE = 2 days;
    uint256 private constant MAX_CLOSURE_AGE = 5 days;
    uint256 private constant DEBT = 5_600e6;

    /*//////////////////////////////////////////////////////////////
                                 FIXTURE
    //////////////////////////////////////////////////////////////*/

    /// @dev Actors holding independent positions and liquidation funds
    address private borrower = makeAddr("borrower");
    address private otherBorrower = makeAddr("otherBorrower");
    address private supplier = makeAddr("supplier");
    address private liquidator = makeAddr("liquidator");

    /// @dev Real lending and risk components
    PoolAddressesProvider private provider;
    IPool private pool;
    TestPoolConfigurator private configurator;
    AaveOracle private oracle;
    SessionCalendar private calendar;
    MarketHoursSentinel private sentinel;

    /// @dev Controlled external data and assets
    MockERC20 private stock;
    MockERC20 private otherStock;
    MockERC20 private usdg;
    MockERC20 private usdc;
    MockChainlinkAggregator private stockFeed;
    MockChainlinkAggregator private otherFeed;
    MockChainlinkAggregator private debtFeed;

    /// @dev Token balances used to verify actual liquidation and withdrawal outcomes
    IERC20 private aStock;
    IERC20 private variableDebt;
    IERC20 private variableStockDebt;

    /// @notice Deploys an isolated two-stock pool with USDG and USDC as its debt assets
    function setUp() public {
        vm.warp(START - 1 days);
        provider = new PoolAddressesProvider("Stock integration", address(this));
        provider.setACLAdmin(address(this));
        ACLManager acl = new ACLManager(provider);
        provider.setACLManager(address(acl));
        acl.addPoolAdmin(address(this));
        provider.setPoolImpl(address(new Pool(provider)));
        pool = IPool(provider.getPool());
        configurator = new TestPoolConfigurator(provider);
        provider.setAddress(bytes32("POOL_CONFIGURATOR"), address(configurator));

        stock = new MockERC20("Stock A", "STKA", 18);
        otherStock = new MockERC20("Stock B", "STKB", 18);
        usdg = new MockERC20("USDG", "USDG", 6);
        usdc = new MockERC20("USDC", "USDC", 6);
        _initReserves();
        configurator.configureReserveAsCollateral(address(stock), 6000, 7000, 10500);
        configurator.configureReserveAsCollateral(address(otherStock), 6000, 7000, 10500);
        configurator.setReserveBorrowing(address(usdg), true);
        configurator.setReserveBorrowing(address(usdc), true);
        configurator.setReserveBorrowing(address(stock), true);
        configurator.setReserveBorrowing(address(otherStock), true);
        configurator.setEModeCategory(STOCKS_EMODE, 8000, 8500, 10300, address(0), "Stocks vs stables");
        configurator.setAssetEModeCategory(address(stock), STOCKS_EMODE);
        configurator.setAssetEModeCategory(address(otherStock), STOCKS_EMODE);
        configurator.setAssetEModeCategory(address(usdg), STOCKS_EMODE);
        configurator.setAssetEModeCategory(address(usdc), STOCKS_EMODE);
        aStock = IERC20(pool.getReserveData(address(stock)).aTokenAddress);
        variableDebt = IERC20(pool.getReserveData(address(usdg)).variableDebtTokenAddress);
        variableStockDebt = IERC20(pool.getReserveData(address(otherStock)).variableDebtTokenAddress);

        calendar = new SessionCalendar();
        calendar.appendWindows(_single(START, END));
        calendar.appendWindows(_single(NEXT_START, NEXT_START + 5 days));
        stockFeed = new MockChainlinkAggregator(100e8, 8, "Stock A / USD");
        otherFeed = new MockChainlinkAggregator(100e8, 8, "Stock B / USD");
        debtFeed = new MockChainlinkAggregator(1e8, 8, "USDG / USD");
        _initOracle();
        sentinel = new MarketHoursSentinel(provider, calendar, GRACE);
        provider.setPriceOracleSentinel(address(sentinel));

        vm.warp(START + GRACE + 1);
        _postPrices(100e8);
        _supply(address(usdg), supplier, 1_000_000e6);
        _supply(address(usdc), supplier, 1_000_000e6);
        _openPosition(stock, borrower);
        _openPosition(otherStock, otherBorrower);
        _supply(address(stock), supplier, 10e18);
        deal(address(usdg), liquidator, 100_000e6);
        vm.prank(liquidator);
        usdg.approve(address(pool), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                              LENDING FLOWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice A closure changes nothing: the last print prices every stock and every action runs
     * @dev The weekend is an outage in reverse. The pool keeps operating on Friday's close; supply, borrow,
     *      withdraw, repay, and liquidation all go through, and no grace is running.
     */
    function test_closureKeepsThePoolOpenAtTheLastPrint() public {
        _closeMarket();
        assertEq(oracle.getAssetPrice(address(stock)), 100e8);
        assertTrue(sentinel.isBorrowAllowed());
        assertTrue(sentinel.isLiquidationAllowed());
        assertEq(sentinel.liquidationGraceUntil(), 0);

        _supply(address(stock), supplier, 1e18);
        vm.startPrank(borrower);
        pool.borrow(address(usdg), 100e6, 2, 0, borrower);
        pool.withdraw(address(stock), 1e18, borrower);
        pool.repay(address(usdg), 1_100e6, 2, borrower);
        vm.stopPrank();

        assertEq(variableDebt.balanceOf(borrower), DEBT - 1_000e6);
        assertEq(stock.balanceOf(borrower), 1e18);
    }

    /**
     * @notice A position that turned liquidatable at the close can be liquidated through the closure
     * @param severe Whether the fixture health factor is below 0.95
     * @param receiveAToken Whether the liquidator requests aTokens
     */
    function testFuzz_closureKeepsLiquidationOpen(bool severe, bool receiveAToken) public {
        vm.warp(END - 1);
        _postPrices(severe ? int256(72e8) : int256(78_40000000));
        _assertLiquidatableBand(severe);
        vm.warp(END + 1 days);

        assertTrue(sentinel.isLiquidationAllowed());
        _liquidateAndAssert(receiveAToken);
    }

    /// @notice A debt-free supplier can redeem stock during a calendar closure
    function test_debtFreeSupplierCanWithdrawWhileClosed() public {
        _closeMarket();
        uint256 beforeBalance = stock.balanceOf(supplier);

        vm.prank(supplier);
        pool.withdraw(address(stock), 10e18, supplier);

        assertEq(stock.balanceOf(supplier), beforeBalance + 10e18);
    }

    /*//////////////////////////////////////////////////////////////
                              REOPEN GRACE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The hour after a reopen holds liquidations in the [0.95, 1) band and nothing else
     * @dev The gap lands with the first print after the open. Borrowers get the hour to repay or add
     *      collateral; borrowing, repayment, withdrawal, and supply run throughout; the view reports the hold's
     *      end; after the hour the band is liquidatable.
     */
    function test_reopenGraceHoldsTheUpperBandAndNothingElse() public {
        _enterUpperBandReopenGrace();
        assertEq(sentinel.liquidationGraceUntil(), NEXT_START + GRACE);
        assertFalse(sentinel.isLiquidationAllowed());
        assertTrue(sentinel.isBorrowAllowed());

        _expectUpperBandLiquidationHeld();

        vm.startPrank(otherBorrower);
        pool.borrow(address(usdg), 1e6, 2, 0, otherBorrower);
        pool.repay(address(usdg), 1_000e6, 2, otherBorrower);
        pool.withdraw(address(otherStock), 1e18, otherBorrower);
        vm.stopPrank();
        _supply(address(stock), supplier, 1e18);
        assertEq(variableDebt.balanceOf(otherBorrower), DEBT + 1e6 - 1_000e6);
        assertEq(otherStock.balanceOf(otherBorrower), 1e18);

        vm.warp(NEXT_START + GRACE);
        assertEq(sentinel.liquidationGraceUntil(), 0);
        assertTrue(sentinel.isLiquidationAllowed());
        _assertLiquidatableBand(false);
        _liquidateAndAssert(true);
    }

    /// @notice Disabling the opening grace immediately permits a real liquidation in the held band
    function test_disabledGraceAllowsUpperBandLiquidationAtTheOpen() public {
        _enterUpperBandReopenGrace();

        _expectUpperBandLiquidationHeld();

        sentinel.setOpeningGrace(0);
        assertEq(sentinel.liquidationGraceUntil(), 0);
        assertTrue(sentinel.isBorrowAllowed());
        _liquidateAndAssert(true);
    }

    /**
     * @notice A gap below the core's 0.95 bypass is liquidated during the opening grace
     * @param receiveAToken Whether the liquidator requests aTokens
     */
    function testFuzz_reopenGraceStillLiquidatesBelowTheBypass(bool receiveAToken) public {
        _closeMarket();
        vm.warp(NEXT_START + 1);
        _postPrices(72e8);
        _assertLiquidatableBand(true);
        assertFalse(sentinel.isLiquidationAllowed());

        _liquidateAndAssert(receiveAToken);
    }

    /// @notice Exactly 0.95 consults the sentinel: held during the grace, liquidatable once it ends
    function test_exactBypassBoundaryUsesTheSentinel() public {
        _closeMarket();
        vm.warp(NEXT_START + 1);
        _postPrices(76e8);
        (,,,,, uint256 hf) = pool.getUserAccountData(borrower);
        assertEq(hf, 0.95e18);
        _expectUpperBandLiquidationHeld();

        vm.warp(NEXT_START + GRACE);
        _liquidateAndAssert(true);
    }

    /// @notice A feed that has not printed after the open keeps serving the last print, without a time limit inside the closure bound
    function test_lateFirstRoundKeepsTheLastPrint() public {
        _closeMarket();
        vm.warp(NEXT_START + GRACE + 1);
        assertEq(oracle.getAssetPrice(address(stock)), 100e8);
        assertTrue(sentinel.isBorrowAllowed());
        assertTrue(sentinel.isLiquidationAllowed());

        vm.prank(borrower);
        pool.withdraw(address(stock), 1e18, borrower);
        vm.prank(borrower);
        pool.borrow(address(usdg), 100e6, 2, 0, borrower);

        _postPrices(90e8);
        assertEq(oracle.getAssetPrice(address(stock)), 90e8);
    }

    /*//////////////////////////////////////////////////////////////
                               AGE BOUNDS
    //////////////////////////////////////////////////////////////*/

    /// @notice A closure that outlasts the closure bound unprices the stock until the feed prints again
    function test_closurePriceExpiresAfterMaxClosureAge() public {
        _closeMarket();
        vm.warp(END - 1 + MAX_CLOSURE_AGE);
        assertEq(oracle.getAssetPrice(address(stock)), 100e8);

        vm.warp(END - 1 + MAX_CLOSURE_AGE + 1);
        vm.expectRevert();
        oracle.getAssetPrice(address(stock));
        _assertCollateralExitRejected();
        vm.expectRevert();
        vm.prank(liquidator);
        pool.liquidationCall(address(stock), address(usdg), borrower, 1_000e6, true);

        vm.prank(borrower);
        pool.repay(address(usdg), 1_000e6, 2, borrower);
        assertEq(variableDebt.balanceOf(borrower), DEBT - 1_000e6);
    }

    /// @notice A feed silent for longer than the session bound during live trading unprices the stock
    function test_sessionPriceExpiresAfterMaxSessionAge() public {
        vm.warp(block.timestamp + MAX_SESSION_AGE);
        assertEq(oracle.getAssetPrice(address(stock)), 100e8);

        vm.warp(block.timestamp + 1);
        vm.expectRevert();
        oracle.getAssetPrice(address(stock));
        _assertCollateralExitRejected();
    }

    /// @notice Truncating the live session keeps the price and leaves both verdicts open
    function test_truncationChangesNothingForTheLastPrint() public {
        calendar.truncateCurrentWindow(uint64(block.timestamp));
        assertEq(oracle.getAssetPrice(address(stock)), 100e8);
        assertTrue(sentinel.isBorrowAllowed());
        assertTrue(sentinel.isLiquidationAllowed());
        assertEq(sentinel.liquidationGraceUntil(), 0);

        vm.prank(borrower);
        pool.withdraw(address(stock), 1e18, borrower);

        assertEq(stock.balanceOf(borrower), 1e18);
    }

    /// @notice A positive fallback would price an expired stock and must remain unset
    function test_fallbackIsASecurityCriticalDeploymentInvariant() public {
        vm.warp(block.timestamp + MAX_SESSION_AGE + 1);
        _assertCollateralExitRejected();
        oracle.setFallbackOracle(address(new FixedFallbackForMarketSafety()));
        vm.prank(borrower);
        pool.withdraw(address(stock), 1e18, borrower);

        assertEq(stock.balanceOf(borrower), 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                       BORROWABLE STOCKS AND E-MODE
    //////////////////////////////////////////////////////////////*/

    /// @notice Stock debt is repayable through a closure and borrowable through the opening grace
    function test_stockDebtIsRepayableWhileClosedAndBorrowableThroughTheGrace() public {
        _borrowStock(supplier, 5e18);
        assertEq(variableStockDebt.balanceOf(supplier), 5e18);

        _closeMarket();
        vm.prank(supplier);
        pool.repay(address(otherStock), 1e18, 2, supplier);
        assertEq(variableStockDebt.balanceOf(supplier), 4e18);

        vm.warp(NEXT_START + 1);
        _postPrices(100e8);
        assertFalse(sentinel.isLiquidationAllowed());
        vm.prank(supplier);
        pool.borrow(address(otherStock), 1e18, 2, 0, supplier);
        assertEq(variableStockDebt.balanceOf(supplier), 5e18);
    }

    /**
     * @notice Understating a borrowable stock price reduces debt valuation and permits more stock debt
     * @dev This characterizes the accepted last-print policy through the actual pool and oracle. It does not
     *      change the pricing policy or claim that the illustrated difference alone creates bad debt.
     */
    function test_understatedBorrowableStockPriceIncreasesDebtCapacity() public {
        _borrowStock(supplier, 5e18);
        (, uint256 referenceDebt, uint256 referenceAvailable,,,) = pool.getUserAccountData(supplier);
        assertEq(referenceDebt, 500e8);
        assertEq(referenceAvailable, 100e8);

        vm.expectRevert(bytes(Errors.COLLATERAL_CANNOT_COVER_NEW_BORROW));
        vm.prank(supplier);
        pool.borrow(address(otherStock), 1.05e18, 2, 0, supplier);

        otherFeed.set(99e8, 3, block.timestamp, block.timestamp, 3);
        (, uint256 understatedDebt, uint256 understatedAvailable,,,) = pool.getUserAccountData(supplier);
        assertEq(understatedDebt, 495e8);
        assertEq(understatedAvailable, 105e8);

        vm.prank(supplier);
        pool.borrow(address(otherStock), 1.05e18, 2, 0, supplier);

        assertEq(variableStockDebt.balanceOf(supplier), 6.05e18);
    }

    /// @notice A governance freeze of a stock reserve refuses new debt in that stock and nothing pool-wide
    function test_frozenStockRefusesNewStockDebtOnly() public {
        _borrowStock(supplier, 5e18);
        configurator.setReserveFreeze(address(otherStock), true);
        assertTrue(pool.getConfiguration(address(otherStock)).getFrozen());

        vm.expectRevert(bytes(Errors.RESERVE_FROZEN));
        vm.prank(supplier);
        pool.borrow(address(otherStock), 1e18, 2, 0, supplier);
        vm.prank(borrower);
        pool.borrow(address(usdg), 1e6, 2, 0, borrower);
        assertEq(variableDebt.balanceOf(borrower), DEBT + 1e6);
    }

    /// @notice E-Mode raises the stock collateral parameters against the stables without touching the adapters
    function test_eModeBoostsStockCollateralWithoutAPriceOverride() public {
        vm.prank(borrower);
        pool.setUserEMode(STOCKS_EMODE);
        vm.expectRevert(bytes(Errors.COLLATERAL_CANNOT_COVER_NEW_BORROW));
        vm.prank(otherBorrower);
        pool.borrow(address(usdc), 2_000e6, 2, 0, otherBorrower);

        vm.prank(borrower);
        pool.borrow(address(usdc), 2_000e6, 2, 0, borrower);
        assertEq(usdc.balanceOf(borrower), 2_000e6);

        vm.warp(block.timestamp + MAX_SESSION_AGE + 1);
        _assertCollateralExitRejected();

        _closeMarket();
        vm.prank(borrower);
        pool.withdraw(address(stock), 1e18, borrower);
        assertEq(stock.balanceOf(borrower), 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates the four reserves with fresh tokens and a zero-rate strategy through the harness configurator
     */
    function _initReserves() private {
        address strategy =
            address(new DefaultReserveInterestRateStrategy(provider, 0.8e27, 0, 0, 0, 0, 0, 0, 0, 0.2e27));

        configurator.initReserve(address(stock), 18, strategy, address(this));
        configurator.initReserve(address(otherStock), 18, strategy, address(this));
        configurator.initReserve(address(usdg), 6, strategy, address(this));
        configurator.initReserve(address(usdc), 6, strategy, address(this));
    }

    /**
     * @notice Installs stock adapters with no fallback or E-mode price overrides
     */
    function _initOracle() private {
        address[] memory assets = new address[](4);
        address[] memory sources = new address[](4);
        assets[0] = address(stock);
        assets[1] = address(otherStock);
        assets[2] = address(usdg);
        assets[3] = address(usdc);
        sources[0] = address(
            new MarketHoursPriceAdapter(
                AggregatorV3Interface(address(stockFeed)), calendar, MAX_SESSION_AGE, MAX_CLOSURE_AGE, "Stock A"
            )
        );
        sources[1] = address(
            new MarketHoursPriceAdapter(
                AggregatorV3Interface(address(otherFeed)), calendar, MAX_SESSION_AGE, MAX_CLOSURE_AGE, "Stock B"
            )
        );
        sources[2] = address(debtFeed);
        sources[3] = address(debtFeed);
        oracle = new AaveOracle(provider, assets, sources, address(0), address(0), 1e8);
        provider.setPriceOracle(address(oracle));
    }

    /**
     * @notice Supplies newly allocated test tokens through the pool
     * @param asset The underlying asset
     * @param user The supplier
     * @param amount The supplied amount
     */
    function _supply(address asset, address user, uint256 amount) private {
        deal(asset, user, amount);
        vm.startPrank(user);
        IERC20(asset).approve(address(pool), type(uint256).max);
        pool.supply(asset, amount, user, 0);
        vm.stopPrank();
    }

    /**
     * @notice Opens a position with $10,000 collateral and $5,600 variable debt
     * @param token The stock collateral
     * @param user The borrower
     */
    function _openPosition(MockERC20 token, address user) private {
        _supply(address(token), user, 100e18);
        vm.startPrank(user);
        pool.borrow(address(usdg), DEBT, 2, 0, user);
        usdg.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    /**
     * @notice Borrows stock B against the user's existing collateral
     * @param user The borrower
     * @param amount The stock B amount
     */
    function _borrowStock(address user, uint256 amount) private {
        vm.startPrank(user);
        pool.borrow(address(otherStock), amount, 2, 0, user);
        otherStock.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    /**
     * @notice Publishes both stocks in the current block
     * @param stockPrice The price of stock A, with stock B fixed at $100
     */
    function _postPrices(int256 stockPrice) private {
        stockFeed.set(stockPrice, 2, block.timestamp, block.timestamp, 2);
        otherFeed.set(100e8, 2, block.timestamp, block.timestamp, 2);
    }

    /**
     * @notice Closes with a fresh final print, the price that carries the pool through the closure
     */
    function _closeMarket() private {
        vm.warp(END - 1);
        _postPrices(100e8);
        vm.warp(END);
    }

    /**
     * @notice Reopens with the fixture borrower in the sentinel-controlled liquidation band
     */
    function _enterUpperBandReopenGrace() private {
        _closeMarket();
        vm.warp(NEXT_START + 1);
        _postPrices(78_40000000);
        _assertLiquidatableBand(false);
    }

    /**
     * @notice Asserts a real upper-band liquidation is rejected by the sentinel
     */
    function _expectUpperBandLiquidationHeld() private {
        vm.expectRevert(bytes(Errors.PRICE_ORACLE_SENTINEL_CHECK_FAILED));
        vm.prank(liquidator);
        pool.liquidationCall(address(stock), address(usdg), borrower, 1_000e6, true);
    }

    /**
     * @notice Checks both collateral-removal paths leave the borrower's receipts unchanged
     */
    function _assertCollateralExitRejected() private {
        uint256 beforeBalance = aStock.balanceOf(borrower);

        vm.expectRevert();
        vm.prank(borrower);
        pool.withdraw(address(stock), 1e18, borrower);
        vm.expectRevert();
        vm.prank(borrower);
        aStock.transfer(supplier, 1e18);
        vm.expectRevert();
        vm.prank(borrower);
        pool.withdraw(address(stock), type(uint256).max, borrower);
        vm.expectRevert();
        vm.prank(borrower);
        pool.setUserUseReserveAsCollateral(address(stock), false);

        assertEq(aStock.balanceOf(borrower), beforeBalance);
    }

    /**
     * @notice Verifies which side of the core's sentinel bypass the fixture occupies
     * @param severe Whether health factor must be below 0.95
     */
    function _assertLiquidatableBand(bool severe) private view {
        (,,,,, uint256 hf) = pool.getUserAccountData(borrower);
        assertLt(hf, 1e18);
        if (severe) assertLt(hf, 0.95e18);
        else assertGe(hf, 0.95e18);
    }

    /**
     * @notice Liquidates real debt and checks the liquidator receives the selected collateral form
     * @param receiveAToken Whether the liquidator requests receipt tokens
     */
    function _liquidateAndAssert(bool receiveAToken) private {
        IERC20 received = receiveAToken ? aStock : IERC20(address(stock));
        uint256 beforeBalance = received.balanceOf(liquidator);
        uint256 beforeDebt = variableDebt.balanceOf(borrower);

        vm.prank(liquidator);
        pool.liquidationCall(address(stock), address(usdg), borrower, 1_000e6, receiveAToken);

        assertEq(variableDebt.balanceOf(borrower), beforeDebt - 1_000e6);
        assertGt(received.balanceOf(liquidator), beforeBalance);
    }
}

/**
 * @title IFixedFallbackForMarketSafety
 * @author Neverland
 * @notice Interface for the counterexample fallback price source
 */
interface IFixedFallbackForMarketSafety {
    /**
     * @notice Prices every asset at $100, intentionally bypassing the session rules
     * @param asset The asset, intentionally ignored by this counterexample
     * @return The fixed price at 8 decimals
     */
    function getAssetPrice(address asset) external view returns (uint256);
}

/**
 * @title FixedFallbackForMarketSafety
 * @author Neverland
 * @notice Counterexample oracle demonstrating why stock-pool fallback pricing is forbidden
 */
contract FixedFallbackForMarketSafety is IFixedFallbackForMarketSafety {
    /// @inheritdoc IFixedFallbackForMarketSafety
    function getAssetPrice(address asset) external pure returns (uint256) {
        asset;

        return 100e8;
    }
}
