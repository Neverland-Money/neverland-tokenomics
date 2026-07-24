// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {AaveOracle} from "@aave/core-v3/contracts/misc/AaveOracle.sol";
import {PoolAddressesProvider} from "@aave/core-v3/contracts/protocol/configuration/PoolAddressesProvider.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";

import {PendlePtDiscountOracleAdapter} from "../../../src/oracles/PendlePtDiscountOracleAdapter.sol";

/**
 * @title PendlePtDiscountOracleFork
 * @author Neverland
 * @notice Monad-mainnet fork test for the PT-AUSD-8OCT2026 discount oracle against the REAL Pendle PT and the
 *         REAL Chainlink AUSD/USD feed. Validates on-chain identity, conservative pricing, staleness fail-safe,
 *         par-at-maturity, and the AaveOracle fallback semantics (including the no-fallback brick path the audit
 *         flagged as a medium operational risk).
 *
 * Run:
 *   RUN_MAINNET_FORK_TESTS=true MAINNET_RPC=<rpc-url> \
 *     forge test --match-contract PendlePtDiscountOracleFork -vvv
 *
 * @dev Risk params (maxDelay / ceiling / active rate) below are the locked PT-AUSD-8OCT2026 deployment values.
 *      Edit the constants only when deliberately validating a new deployment profile.
 */
contract PendlePtDiscountOracleFork is Test {
    /*//////////////////////////////////////////////////////////////
                       MONAD MAINNET ADDRESSES (REAL)
    //////////////////////////////////////////////////////////////*/

    /// @dev Pendle PT-AUSD-8OCT2026 principal token.
    address internal constant PT_AUSD = 0x9FC74f8Ed616B5BaF52a170caa97d6d3898602d1;
    /// @dev Chainlink AUSD/USD aggregator (8 decimals, ~1h heartbeat).
    address internal constant AUSD_USD_FEED = 0xE20751C7B5867bCBef815ffc1b284c3f412a9e13;
    /// @dev AUSD underlying accounting asset (6 decimals).
    address internal constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;

    /// @dev Cached PT maturity (8 Oct 2026 00:00:00 UTC); asserted against the live PT's expiry() below.
    uint256 internal constant EXPECTED_MATURITY = 1791417600;
    uint8 internal constant EXPECTED_PT_DECIMALS = 6;
    uint8 internal constant EXPECTED_FEED_DECIMALS = 8;

    /*//////////////////////////////////////////////////////////////
                        LOCKED RISK PARAMS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev 30h: deliberately above the 24h Governance Timelock so a stale feed can be detected and replaced
     *      through the timelock with ~6h headroom. The no-fallback path is intentionally fail-closed:
     *      stale/invalid AUSD data bricks PT price reads instead of serving a stale fallback price.
     */
    uint256 internal constant MAX_DELAY = 30 hours;
    /// @dev 40%/yr immutable ceiling: generous headroom so risk admin can crank the discount if launch APY spikes.
    uint16 internal constant MAX_RATE_BPS = 4000;
    /**
     * @dev 12%/yr active rate: above the historical plain-stablecoin implied-APY band (~10.5% worst) so the oracle
     *      stays conservative without relying on retunes; planned review toward 10% once AUSD-PT yield proves stable.
     */
    uint16 internal constant RATE_BPS = 1200;

    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS_TO_WAD = 1e14;

    PendlePtDiscountOracleAdapter internal adapter;

    function setUp() public {
        vm.skip(!vm.envOr("RUN_MAINNET_FORK_TESTS", false), "set RUN_MAINNET_FORK_TESTS=true to enable mainnet RPC");

        string memory mainnetRpcUrl = vm.envString("MAINNET_RPC");
        uint256 forkId = vm.createFork(mainnetRpcUrl);
        vm.selectFork(forkId);
        assertEq(block.chainid, 143, "MAINNET_RPC must be Monad mainnet");

        vm.label(PT_AUSD, "PT-AUSD-8OCT2026");
        vm.label(AUSD_USD_FEED, "AUSD/USD");
        vm.label(AUSD, "AUSD");

        adapter = new PendlePtDiscountOracleAdapter(
            AUSD_USD_FEED, PT_AUSD, MAX_DELAY, MAX_RATE_BPS, RATE_BPS, "PT-AUSD-8OCT2026 / USD"
        );
        vm.label(address(adapter), "PendlePtDiscountOracleAdapter");
    }

    /*//////////////////////////////////////////////////////////////
                          1. ON-CHAIN IDENTITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Every value baked into the config must match what the chain actually reports.
    function test_fork_identity_matchesConfig() public view {
        // PT identity.
        assertEq(IExpiry(PT_AUSD).expiry(), EXPECTED_MATURITY, "PT expiry != config maturity");
        assertEq(IDecimals(PT_AUSD).decimals(), EXPECTED_PT_DECIMALS, "PT decimals != 6");
        assertEq(IExpiry(PT_AUSD).SY(), 0xBA3d60f5000f472aef947FB8020a3E6319F9a0B7, "PT.SY != descriptor SY");

        // Base feed identity + liveness.
        assertEq(AggregatorV3Interface(AUSD_USD_FEED).decimals(), EXPECTED_FEED_DECIMALS, "feed decimals != 8");
        (uint80 rid, int256 price,, uint256 updatedAt, uint80 air) =
            AggregatorV3Interface(AUSD_USD_FEED).latestRoundData();
        assertGt(price, 0, "AUSD price must be positive");
        assertLe(updatedAt, block.timestamp, "feed updatedAt in future");
        assertLt(block.timestamp - updatedAt, MAX_DELAY, "feed already stale vs MAX_DELAY at fork head");

        // Underlying accounting asset identity.
        assertEq(IDecimals(AUSD).decimals(), EXPECTED_PT_DECIMALS, "AUSD decimals != 6");

        console.log("PT maturity           :", EXPECTED_MATURITY);
        console.log("fork block.timestamp  :", block.timestamp);
        console.log("seconds to maturity   :", EXPECTED_MATURITY - block.timestamp);
        console.log("AUSD/USD price (8dp)  :", uint256(price));
        console.log("feed roundId          :", rid);
        console.log("feed answeredInRound  :", air);
        console.log("feed age (s)          :", block.timestamp - updatedAt);
    }

    /*//////////////////////////////////////////////////////////////
                       2. DEPLOY + PRICE (CONSERVATIVE)
    //////////////////////////////////////////////////////////////*/

    /// @notice Adapter prices the PT below par, exactly per the documented linear-discount formula.
    function test_fork_deployAndPrice() public view {
        (, int256 basePrice,,,) = AggregatorV3Interface(AUSD_USD_FEED).latestRoundData();

        uint256 ttm = EXPECTED_MATURITY - block.timestamp;
        uint256 discountWad = (ttm * (uint256(RATE_BPS) * BPS_TO_WAD)) / SECONDS_PER_YEAR;
        // Feed is 8 decimals == TARGET, so no decimal rescale: expected = base * (WAD - discount) / WAD.
        int256 expected = int256((uint256(basePrice) * (WAD - discountWad)) / WAD);

        int256 answer = adapter.latestAnswer();

        assertEq(answer, expected, "adapter answer != independent linear-discount reference");
        assertGt(answer, 0, "answer must be positive");
        assertLt(answer, basePrice, "PT must be priced strictly below par pre-maturity");
        assertEq(adapter.getCurrentDiscount(), discountWad, "getCurrentDiscount mismatch");
        assertEq(adapter.decimals(), 8, "output decimals must be 8");
        assertEq(adapter.version(), 1);

        // Strict path agrees with the lenient path and forwards the real base round metadata.
        (uint80 rid, int256 rdAnswer, uint256 startedAt, uint256 updatedAt, uint80 air) = adapter.latestRoundData();
        (uint80 brid,, uint256 bStarted, uint256 bUpdated, uint80 bAir) =
            AggregatorV3Interface(AUSD_USD_FEED).latestRoundData();
        assertEq(rdAnswer, expected, "latestRoundData answer != latestAnswer");
        assertEq(rid, brid, "roundId not forwarded from base feed");
        assertEq(startedAt, bStarted, "startedAt not forwarded");
        assertEq(updatedAt, bUpdated, "updatedAt not forwarded");
        assertEq(air, bAir, "answeredInRound not forwarded");

        console.log("base AUSD/USD (8dp)   :", uint256(basePrice));
        console.log("discountWad (1e18)    :", discountWad);
        console.log("PT/USD answer (8dp)   :", uint256(answer));
        console.log("implied discount bps  :", (discountWad * 10000) / WAD);
    }

    /*//////////////////////////////////////////////////////////////
                        3. STALENESS FAIL-SAFE
    //////////////////////////////////////////////////////////////*/

    /// @notice Once the real feed ages past maxDelay, lenient reads return 0 and strict reads revert.
    function test_fork_staleness_failsafe() public {
        (,,, uint256 updatedAt,) = AggregatorV3Interface(AUSD_USD_FEED).latestRoundData();

        // Warp just past the freshness window relative to the feed's last update (still well before maturity).
        vm.warp(updatedAt + MAX_DELAY + 1);

        assertEq(adapter.latestAnswer(), 0, "stale feed must lenient-return 0");
        assertEq(adapter.latestTimestamp(), 0, "stale feed must lenient-return 0 timestamp");
        assertEq(adapter.latestRound(), 0, "stale feed must lenient-return 0 round");

        vm.expectRevert(
            abi.encodeWithSelector(
                CommonChecksLibrary.PriceTooOld.selector, block.timestamp, updatedAt, updatedAt + MAX_DELAY
            )
        );
        adapter.latestRoundData();
    }

    /// @notice Exactly at the maxDelay boundary the price is still served (inclusive bound).
    function test_fork_staleness_exactBoundaryAccepted() public {
        (,,, uint256 updatedAt,) = AggregatorV3Interface(AUSD_USD_FEED).latestRoundData();
        vm.warp(updatedAt + MAX_DELAY);
        assertGt(adapter.latestAnswer(), 0, "exact maxDelay boundary must be accepted");
    }

    /*//////////////////////////////////////////////////////////////
                          4. PAR AT MATURITY
    //////////////////////////////////////////////////////////////*/

    /// @notice At/after maturity the PT prices at par with a fresh AUSD feed (discount decays to 0).
    function test_fork_parAtMaturity() public {
        int256 parPrice = 100_000_000; // $1.00 at 8dp
        // Warp to maturity and present a fresh AUSD round at par (the live feed would be stale this far out).
        vm.warp(EXPECTED_MATURITY + 1 days);
        _mockFeed(parPrice, block.timestamp);

        assertEq(adapter.getCurrentDiscount(), 0, "discount must be 0 at/after maturity");
        assertEq(adapter.latestAnswer(), parPrice, "PT must price at par at maturity");

        // A depegged-but-fresh feed flows straight through at par (no discount left to apply).
        _mockFeed(97_000_000, block.timestamp);
        assertEq(adapter.latestAnswer(), 97_000_000, "post-maturity PT tracks base feed 1:1");
    }

    /*//////////////////////////////////////////////////////////////
              5. AAVE ORACLE INTEGRATION + FALLBACK SEMANTICS
    //////////////////////////////////////////////////////////////*/

    /// @notice Through a real AaveOracle, a healthy feed yields the discounted PT price.
    function test_fork_aaveOracle_servesDiscountedPrice() public {
        AaveOracle oracle = _deployAaveOracle(address(0));
        assertEq(oracle.getAssetPrice(PT_AUSD), uint256(adapter.latestAnswer()), "AaveOracle != adapter answer");
    }

    /// @notice AUDIT MEDIUM (aave-int-1): with NO fallback, a stale feed makes getAssetPrice REVERT (pool brick).
    function test_fork_aaveOracle_noFallback_bricksOnOutage() public {
        AaveOracle oracle = _deployAaveOracle(address(0));
        (,,, uint256 updatedAt,) = AggregatorV3Interface(AUSD_USD_FEED).latestRoundData();
        vm.warp(updatedAt + MAX_DELAY + 1); // feed now stale -> adapter.latestAnswer() == 0

        assertEq(adapter.latestAnswer(), 0, "precondition: adapter returns 0 on stale feed");
        // _fallbackOracle == address(0): the call to getAssetPrice on empty code reverts (fail-CLOSED).
        vm.expectRevert();
        oracle.getAssetPrice(PT_AUSD);
    }

    /// @notice With a fallback configured, the same outage fails OVER to the fallback price instead of bricking.
    function test_fork_aaveOracle_withFallback_failsOver() public {
        uint256 fallbackPrice = 95_000_000;
        AaveOracle oracle = _deployAaveOracle(address(new MockFallbackOracle(fallbackPrice)));
        (,,, uint256 updatedAt,) = AggregatorV3Interface(AUSD_USD_FEED).latestRoundData();
        vm.warp(updatedAt + MAX_DELAY + 1);

        assertEq(adapter.latestAnswer(), 0, "precondition: adapter returns 0 on stale feed");
        assertEq(oracle.getAssetPrice(PT_AUSD), fallbackPrice, "must fail over to fallback price");
    }

    /*//////////////////////////////////////////////////////////////
            6. CAPS DO NOT DISCONNECT FROM MATURITY (SYNC CONCERN)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Maturity convergence is independent of the discount-rate cap: even pinned at the immutable
     *         ceiling, the PT prices at exact par at/after maturity (discount decays to 0 unconditionally).
     */
    function test_fork_maturityConvergence_independentOfCap() public {
        int256 par = 100_000_000; // $1.00 at 8dp
        // Crank the active rate to the immutable ceiling: maximum pre-maturity under-pricing.
        adapter.setDiscountRatePerYear(MAX_RATE_BPS);

        // Pre-maturity: the cap bites on the DISCOUNT LINE (price is below par), not on convergence.
        _mockFeed(par, block.timestamp);
        assertLt(adapter.latestAnswer(), par, "ceiling rate should discount pre-maturity");
        assertGt(adapter.latestAnswer(), 0, "still positive");

        // At maturity: discount is EXACTLY 0 regardless of the rate/ceiling => exact par.
        vm.warp(EXPECTED_MATURITY);
        _mockFeed(par, block.timestamp);
        assertEq(adapter.getCurrentDiscount(), 0, "discount must be 0 at maturity for any rate");
        assertEq(adapter.latestAnswer(), par, "exact par at maturity at the ceiling rate");

        // After maturity: still par.
        vm.warp(EXPECTED_MATURITY + 90 days);
        _mockFeed(par, block.timestamp);
        assertEq(adapter.latestAnswer(), par, "par persists post-maturity at the ceiling rate");
    }

    /**
     * @notice There is no growth-rate limiter: the reported price may swing arbitrarily between consecutive
     *         reads with no smoothing/cap (proving this adapter has none of YieldBearingOracleAdapter's
     *         snapshot/growth-cap machinery that could lag the true value).
     */
    function test_fork_noGrowthRateLimiter() public {
        int256 par = 100_000_000;

        adapter.setDiscountRatePerYear(1); // ~par this block
        _mockFeed(par, block.timestamp);
        int256 high = adapter.latestAnswer();

        adapter.setDiscountRatePerYear(MAX_RATE_BPS); // big instant drop next read, no dampening
        _mockFeed(par, block.timestamp);
        int256 low = adapter.latestAnswer();

        assertGt(high, low, "price must move");
        // The full swing lands in a single read: no growth/ratio cap dampens it => no rate-limiter exists.
        uint256 swingBps = (uint256(high - low) * 10000) / uint256(high);
        assertGt(swingBps, 100, "swing applied instantly and unbounded by any growth cap");
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys a minimal AaveOracle wired to the fork adapter for PT-AUSD.
     * @param fallbackOracle Fallback oracle address used when the adapter returns a non-positive price
     * @return The deployed AaveOracle instance
     */
    function _deployAaveOracle(address fallbackOracle) internal returns (AaveOracle) {
        PoolAddressesProvider provider = new PoolAddressesProvider("PT-AUSD Fork Market", address(this));
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = PT_AUSD;
        sources[0] = address(adapter);

        return
            new AaveOracle(IPoolAddressesProvider(address(provider)), assets, sources, fallbackOracle, address(0), 1e8);
    }

    /**
     * @notice Overrides the real feed's latestRoundData so par/maturity scenarios can present a fresh round.
     * @param price Mock base-feed price answer
     * @param ts Mock round timestamp
     */
    function _mockFeed(int256 price, uint256 ts) internal {
        vm.mockCall(
            AUSD_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), price, ts, ts, uint80(1))
        );
    }
}

/**
 * @title IExpiry
 * @notice Minimal Pendle PT expiry and SY interface used by the fork test.
 */
interface IExpiry {
    /// @notice Returns the PT maturity timestamp.
    function expiry() external view returns (uint256);

    /// @notice Returns the PT's standardized yield token.
    function SY() external view returns (address);
}

/**
 * @title IDecimals
 * @notice Minimal ERC20 decimals interface used by the fork test.
 */
interface IDecimals {
    /// @notice Returns token decimals.
    function decimals() external view returns (uint8);
}

/**
 * @title MockFallbackOracle
 * @notice Minimal Aave fallback price oracle returning a fixed price.
 */
contract MockFallbackOracle {
    /// @notice Fixed fallback price returned by the mock.
    uint256 public price;

    /**
     * @notice Initializes the fallback mock.
     * @param price_ Fixed price returned by getAssetPrice
     */
    constructor(uint256 price_) {
        price = price_;
    }

    /**
     * @notice Returns the fixed mock price for any asset.
     * @return The fixed fallback price
     */
    function getAssetPrice(address) external view returns (uint256) {
        return price;
    }
}
