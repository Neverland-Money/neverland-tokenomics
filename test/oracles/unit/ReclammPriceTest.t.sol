// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {NeverlandDustHelper} from "../../../src/utils/NeverlandDustHelper.sol";
import {INeverlandDustHelper} from "../../../src/interfaces/INeverlandDustHelper.sol";
import {IReClammPool} from "../../../src/interfaces/IReClammPool.sol";

/*//////////////////////////////////////////////////////////////
                         MOCK CONTRACTS
//////////////////////////////////////////////////////////////*/

/// @dev Mock ERC20 token for DUST (18 decimals)
contract MockDust {
    string public name = "Dust";
    string public symbol = "DUST";
    uint8 public decimals = 18;
    uint256 public totalSupply = 100_000_000e18; // 100M

    mapping(address => uint256) public balanceOf;

    constructor() {
        balanceOf[msg.sender] = totalSupply;
    }
}

/// @dev Mock reCLAMM pool that returns configurable dynamic data
contract MockReClammPool {
    uint256[] public virtualBalances;
    uint256[] public liveBalances;
    bool public poolInitialized = true;
    bool public poolPaused;

    function setVirtualBalances(uint256 virtualBal0, uint256 virtualBal1) external {
        delete virtualBalances;
        virtualBalances.push(virtualBal0);
        virtualBalances.push(virtualBal1);
    }

    function setLiveBalances(uint256 liveBal0, uint256 liveBal1) external {
        delete liveBalances;
        liveBalances.push(liveBal0);
        liveBalances.push(liveBal1);
    }

    function setPoolState(bool initialized, bool paused) external {
        poolInitialized = initialized;
        poolPaused = paused;
    }

    function getReClammPoolDynamicData() external view returns (IReClammPool.ReClammPoolDynamicData memory data) {
        uint256[] memory balancesLive = new uint256[](2);
        if (liveBalances.length >= 2) {
            balancesLive[0] = liveBalances[0];
            balancesLive[1] = liveBalances[1];
        }

        uint256[] memory tokenRates = new uint256[](2);
        tokenRates[0] = 1e18;
        tokenRates[1] = 1e18;

        data = IReClammPool.ReClammPoolDynamicData({
            balancesLiveScaled18: balancesLive,
            tokenRates: tokenRates,
            staticSwapFeePercentage: 3e15, // 0.3%
            totalSupply: 1000e18,
            lastTimestamp: block.timestamp,
            lastVirtualBalances: virtualBalances,
            dailyPriceShiftExponent: 1e18,
            dailyPriceShiftBase: 1e18,
            centerednessMargin: 5e16,
            currentPriceRatio: 4e18,
            currentFourthRootPriceRatio: 1414213562373095048, // sqrt(sqrt(4))
            startFourthRootPriceRatio: 1414213562373095048,
            endFourthRootPriceRatio: 1414213562373095048,
            priceRatioUpdateStartTime: uint32(block.timestamp),
            priceRatioUpdateEndTime: uint32(block.timestamp),
            isPoolInitialized: poolInitialized,
            isPoolPaused: poolPaused,
            isPoolInRecoveryMode: false
        });
    }
}

/// @dev Mock Chainlink oracle that returns a configurable USDC/USD price
contract MockChainlinkOracle {
    int256 public answer;
    uint8 public decimals = 8;

    constructor(int256 _answer) {
        answer = _answer;
    }

    function setAnswer(int256 _answer) external {
        answer = _answer;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 _answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

/*//////////////////////////////////////////////////////////////
                           TEST CONTRACT
//////////////////////////////////////////////////////////////*/

contract ReclammPriceTest is Test {
    NeverlandDustHelper helper;
    MockDust dust;
    MockReClammPool reclammPool;
    MockChainlinkOracle usdcOracle;

    address owner = address(this);

    function setUp() public {
        dust = new MockDust();
        reclammPool = new MockReClammPool();
        // USDC/USD oracle: $1.00 (8 decimals)
        usdcOracle = new MockChainlinkOracle(1e8);

        helper = new NeverlandDustHelper(address(dust), owner);

        // Label for traces
        vm.label(address(dust), "DUST");
        vm.label(address(reclammPool), "ReClammPool");
        vm.label(address(usdcOracle), "USDC/USD Oracle");
        vm.label(address(helper), "DustHelper");
    }

    /*//////////////////////////////////////////////////////////////
                          CORE PRICE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: DUST at $0.25 — pool has 4x more DUST than USDC (virtual)
    function test_reclammPrice_dustAt25Cents() public {
        console.log("=== Test: DUST at $0.25 (4 DUST per 1 USDC) ===");

        // Virtual balances: 4M DUST, 1M USDC (both 18-decimal scaled)
        // Spot price: 4M / 1M = 4 DUST per USDC → $0.25 per DUST
        reclammPool.setVirtualBalances(4_000_000e18, 1_000_000e18);

        // Configure: reCLAMM pool (DUST=token0) + USDC/USD oracle
        helper.setReclammPool(address(reclammPool), true);
        helper.setPairOracle(address(usdcOracle));

        // Force cache stale so getPrice() reads live
        vm.warp(block.timestamp + 2 hours);

        (uint256 price, bool fromOracle) = helper.getPrice();

        console.log("Price (8 dec):", price);
        console.log("From oracle:", fromOracle);
        console.log("Expected:    ", uint256(25_000_000)); // $0.25
        console.log("");

        assertTrue(fromOracle, "Should come from oracle");
        assertEq(price, 25_000_000, "DUST should be $0.25");
    }

    /// @notice Test: DUST at $0.50
    function test_reclammPrice_dustAt50Cents() public {
        console.log("=== Test: DUST at $0.50 (2 DUST per 1 USDC) ===");

        // 2M DUST, 1M USDC → 2 DUST per USDC → $0.50
        reclammPool.setVirtualBalances(2_000_000e18, 1_000_000e18);

        helper.setReclammPool(address(reclammPool), true);
        helper.setPairOracle(address(usdcOracle));
        vm.warp(block.timestamp + 2 hours);

        (uint256 price, bool fromOracle) = helper.getPrice();

        console.log("Price (8 dec):", price);
        console.log("Expected:    ", uint256(50_000_000));
        console.log("");

        assertTrue(fromOracle);
        assertEq(price, 50_000_000, "DUST should be $0.50");
    }

    /// @notice Test: DUST at $1.00
    function test_reclammPrice_dustAt1Dollar() public {
        console.log("=== Test: DUST at $1.00 (1 DUST per 1 USDC) ===");

        // 1M DUST, 1M USDC → 1:1 → $1.00
        reclammPool.setVirtualBalances(1_000_000e18, 1_000_000e18);

        helper.setReclammPool(address(reclammPool), true);
        helper.setPairOracle(address(usdcOracle));
        vm.warp(block.timestamp + 2 hours);

        (uint256 price, bool fromOracle) = helper.getPrice();

        console.log("Price (8 dec):", price);
        console.log("Expected:    ", uint256(100_000_000));
        console.log("");

        assertTrue(fromOracle);
        assertEq(price, 100_000_000, "DUST should be $1.00");
    }

    /// @notice Test: DUST is token1 (not token0) in the pool
    function test_reclammPrice_dustIsToken1() public {
        console.log("=== Test: DUST is token1 (reversed ordering) ===");

        // token0=USDC, token1=DUST
        // Virtual: [1M USDC, 4M DUST] → DUST per USDC = 4M/1M = 4 → $0.25
        reclammPool.setVirtualBalances(1_000_000e18, 4_000_000e18);

        helper.setReclammPool(address(reclammPool), false); // DUST is NOT token0
        helper.setPairOracle(address(usdcOracle));
        vm.warp(block.timestamp + 2 hours);

        (uint256 price, bool fromOracle) = helper.getPrice();

        console.log("Price (8 dec):", price);
        console.log("Expected:    ", uint256(25_000_000));
        console.log("");

        assertTrue(fromOracle);
        assertEq(price, 25_000_000, "DUST should be $0.25 with reversed token order");
    }

    /// @notice Test: USDC oracle reports $0.999 (slight depeg)
    function test_reclammPrice_usdcDepeg() public {
        console.log("=== Test: USDC slight depeg ($0.999) ===");

        // 4 DUST per USDC, but USDC = $0.999
        reclammPool.setVirtualBalances(4_000_000e18, 1_000_000e18);
        usdcOracle.setAnswer(99_900_000); // $0.999

        helper.setReclammPool(address(reclammPool), true);
        helper.setPairOracle(address(usdcOracle));
        vm.warp(block.timestamp + 2 hours);

        (uint256 price, bool fromOracle) = helper.getPrice();

        // $0.999 / 4 = $0.24975 → 24_975_000 in 8 dec
        console.log("Price (8 dec):", price);
        console.log("Expected:    ", uint256(24_975_000));
        console.log("");

        assertTrue(fromOracle);
        assertEq(price, 24_975_000, "Should reflect USDC depeg");
    }

    /*//////////////////////////////////////////////////////////////
                          EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: Pool is paused -> still returns price for UI/informational purposes
    function test_reclammPrice_poolPaused() public {
        console.log("=== Test: Pool paused -> should still return price ===");

        reclammPool.setVirtualBalances(4_000_000e18, 1_000_000e18);
        reclammPool.setPoolState(true, true); // initialized but paused

        // Only set reCLAMM (no dustPair) so fallback V3/V2 paths don't call address(0)
        helper.setReclammPool(address(reclammPool), true);
        // Use pairOracle to keep two-step path, but no dustPair set
        helper.setPairOracle(address(usdcOracle));
        vm.warp(block.timestamp + 2 hours);

        (uint256 price, bool fromOracle) = helper.getPrice();

        console.log("Price (8 dec):", price);
        console.log("From oracle:", fromOracle);
        console.log("(Paused pool should still return price for UI purposes)");
        console.log("");

        // Even paused pools return prices for UI/informational purposes
        assertEq(price, 25_000_000, "Should return $0.25 even when paused");
        assertTrue(fromOracle, "Should come from oracle even when paused");
    }

    /// @notice Test: Pool not initialized -> graceful failure
    function test_reclammPrice_poolNotInitialized() public {
        console.log("=== Test: Pool not initialized ===");

        reclammPool.setVirtualBalances(4_000_000e18, 1_000_000e18);
        reclammPool.setPoolState(false, false); // not initialized

        helper.setReclammPool(address(reclammPool), true);
        helper.setPairOracle(address(usdcOracle));
        vm.warp(block.timestamp + 2 hours);

        (uint256 price, bool fromOracle) = helper.getPrice();

        console.log("Price (8 dec):", price);
        console.log("From oracle:", fromOracle);
        console.log("");

        assertEq(price, 0);
        assertFalse(fromOracle, "Not-initialized pool should fail gracefully");
    }

    /// @notice Test: Zero virtual balances -> graceful failure
    function test_reclammPrice_zeroVirtualBalances() public {
        console.log("=== Test: Zero virtual balances ===");

        reclammPool.setVirtualBalances(0, 0);

        helper.setReclammPool(address(reclammPool), true);
        helper.setPairOracle(address(usdcOracle));
        vm.warp(block.timestamp + 2 hours);

        (uint256 price, bool fromOracle) = helper.getPrice();

        console.log("Price (8 dec):", price);
        console.log("From oracle:", fromOracle);
        console.log("");

        assertEq(price, 0);
        assertFalse(fromOracle, "Zero balances should fail gracefully");
    }

    /// @notice Test: removeReclammPool clears config and falls back to hardcoded
    function test_removeReclammPool() public {
        console.log("=== Test: removeReclammPool falls back to hardcoded ===");

        reclammPool.setVirtualBalances(4_000_000e18, 1_000_000e18);
        helper.setReclammPool(address(reclammPool), true);
        helper.setPairOracle(address(usdcOracle));
        vm.warp(block.timestamp + 2 hours);

        // Should have oracle price first
        (uint256 priceBefore,) = helper.getPrice();
        console.log("Before remove:", priceBefore);

        // Remove reCLAMM pool and pair oracle
        helper.removeReclammPool();
        helper.removePairOracle();
        vm.warp(block.timestamp + 2 hours);

        (uint256 priceAfter, bool fromOracle) = helper.getPrice();
        console.log("After remove: ", priceAfter);
        console.log("From oracle:", fromOracle);
        console.log("");

        assertFalse(fromOracle);
        assertEq(priceAfter, helper.DEFAULT_DUST_PRICE(), "Should fall back to hardcoded");
    }

    /// @notice Test: updatePriceCache with reCLAMM source
    function test_updatePriceCache_withReclamm() public {
        console.log("=== Test: updatePriceCache with reCLAMM ===");

        reclammPool.setVirtualBalances(4_000_000e18, 1_000_000e18);
        helper.setReclammPool(address(reclammPool), true);
        helper.setPairOracle(address(usdcOracle));

        // Update cache
        helper.updatePriceCache();

        // Now getPrice should return cached value even without time passing
        (uint256 price, bool fromOracle) = helper.getPrice();

        console.log("Cached price:", price);
        console.log("From oracle:", fromOracle);
        console.log("");

        assertTrue(fromOracle);
        assertEq(price, 25_000_000);
    }

    /// @notice Test: Price changes when virtual balances shift (simulating pool rebalance)
    function test_reclammPrice_rebalance() public {
        console.log("=== Test: Price shifts as pool rebalances ===");

        // Start: $0.25
        reclammPool.setVirtualBalances(4_000_000e18, 1_000_000e18);
        helper.setReclammPool(address(reclammPool), true);
        helper.setPairOracle(address(usdcOracle));
        vm.warp(block.timestamp + 2 hours);

        (uint256 price1,) = helper.getPrice();
        console.log("Price 1 ($0.25):", price1);

        // Simulate rebalance: price doubles to $0.50
        reclammPool.setVirtualBalances(2_000_000e18, 1_000_000e18);
        vm.warp(block.timestamp + 2 hours);

        (uint256 price2,) = helper.getPrice();
        console.log("Price 2 ($0.50):", price2);

        // Simulate further: $1.00
        reclammPool.setVirtualBalances(1_000_000e18, 1_000_000e18);
        vm.warp(block.timestamp + 2 hours);

        (uint256 price3,) = helper.getPrice();
        console.log("Price 3 ($1.00):", price3);
        console.log("");

        assertEq(price1, 25_000_000);
        assertEq(price2, 50_000_000);
        assertEq(price3, 100_000_000);
    }

    /*//////////////////////////////////////////////////////////////
                        MARKET DATA INTEGRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: Full market data works with reCLAMM price source
    function test_marketData_withReclamm() public {
        console.log("=== Test: getMarketData() with reCLAMM ===");

        reclammPool.setVirtualBalances(4_000_000e18, 1_000_000e18);
        helper.setReclammPool(address(reclammPool), true);
        helper.setPairOracle(address(usdcOracle));
        helper.updatePriceCache();

        INeverlandDustHelper.MarketData memory data = helper.getMarketData();

        console.log("Total Supply:     ", data.totalSupply / 1e18, "DUST");
        console.log("Circulating:      ", data.circulatingSupply / 1e18, "DUST");
        console.log("USD Price (8dec): ", data.usdPrice);
        console.log("Market Cap (8dec):", data.marketCap);
        console.log("FDV (8dec):       ", data.fullyDilutedMarketCap);
        console.log("From Oracle:      ", data.isPriceFromOracle);
        console.log("");

        assertEq(data.usdPrice, 25_000_000);
        assertTrue(data.isPriceFromOracle);
        assertTrue(data.totalSupply > 0);
    }

    /// @notice Test: getDustValueInUSD with reCLAMM source
    function test_dustValueInUSD_withReclamm() public {
        console.log("=== Test: getDustValueInUSD() ===");

        reclammPool.setVirtualBalances(4_000_000e18, 1_000_000e18);
        helper.setReclammPool(address(reclammPool), true);
        helper.setPairOracle(address(usdcOracle));
        helper.updatePriceCache();

        // 100 DUST at $0.25 = $25
        uint256 usdValue = helper.getDustValueInUSD(100e18);
        console.log("100 DUST in USD (8dec):", usdValue);
        console.log("Expected:             ", uint256(25_00000000)); // $25.00
        console.log("");

        assertEq(usdValue, 25_00000000, "100 DUST @ $0.25 = $25");
    }

    /*//////////////////////////////////////////////////////////////
                          EVENTS / CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: setReclammPool emits event
    function test_setReclammPool_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit INeverlandDustHelper.ReclammPoolUpdated(address(reclammPool), true);
        helper.setReclammPool(address(reclammPool), true);
    }

    /// @notice Test: removeReclammPool emits event
    function test_removeReclammPool_emitsEvent() public {
        helper.setReclammPool(address(reclammPool), true);

        vm.expectEmit(false, false, false, true);
        emit INeverlandDustHelper.ReclammPoolRemoved();
        helper.removeReclammPool();
    }

    /// @notice Test: setReclammPool reverts on zero address
    function test_setReclammPool_revertsOnZero() public {
        vm.expectRevert();
        helper.setReclammPool(address(0), true);
    }

    /// @notice Test: non-owner cannot setReclammPool
    function test_setReclammPool_onlyOwner() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        helper.setReclammPool(address(reclammPool), true);
    }
}
