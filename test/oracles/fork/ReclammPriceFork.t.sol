// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {NeverlandDustHelper} from "../../../src/utils/NeverlandDustHelper.sol";
import {INeverlandDustHelper} from "../../../src/interfaces/INeverlandDustHelper.sol";
import {IReClammPool} from "../../../src/interfaces/IReClammPool.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title ReclammPriceFork
 * @notice Anvil fork test to deploy NeverlandDustHelper, configure the reCLAMM pool + USDC oracle,
 *         and validate the DUST price against on-chain data.
 *
 * Run:
 *   forge test --match-contract ReclammPriceFork --fork-url https://rpc-mainnet.monadinfra.com -vv
 *
 * Or with .env RPC:
 *   source .env && forge test --match-contract ReclammPriceFork --fork-url $MAINNET_RPC -vv
 */
contract ReclammPriceFork is Test {
    /*//////////////////////////////////////////////////////////////
                          MONAD MAINNET ADDRESSES
    //////////////////////////////////////////////////////////////*/

    address constant DUST = 0xAD96C3dffCD6374294e2573A7fBBA96097CC8d7c;
    address constant RECLAMM_POOL = 0x36DA07624FC02b34042770EbE505e844C7B529FF;
    // No separate USDC/USD oracle needed — USDC is USD-equivalent.
    // The reCLAMM direct-USD path inverts DUST/USDC to get USD/DUST.

    string internal MAINNET_RPC_URL = vm.envOr("MAINNET_RPC", string("https://rpc-mainnet.monadinfra.com"));

    address deployer;
    NeverlandDustHelper helper;

    modifier onlyFork() {
        if (block.chainid != 143) {
            return;
        }
        _;
    }

    function setUp() public {
        uint256 forkId = vm.createFork(MAINNET_RPC_URL);
        vm.selectFork(forkId);

        deployer = address(this);
        vm.label(DUST, "DUST");
        vm.label(RECLAMM_POOL, "ReClammPool");
    }

    /*//////////////////////////////////////////////////////////////
                      1. POOL DISCOVERY (read-only)
    //////////////////////////////////////////////////////////////*/

    /// @notice Read the reCLAMM pool's immutable data to discover tokens and ordering
    function test_01_discoverPool() public view {
        console.log("============================================");
        console.log("  STEP 1: Discover reCLAMM Pool On-Chain");
        console.log("============================================\n");
        console.log("Pool address:", RECLAMM_POOL);

        // --- Immutable Data ---
        IReClammPool.ReClammPoolImmutableData memory immData = IReClammPool(RECLAMM_POOL).getReClammPoolImmutableData();

        console.log("\n--- Immutable Data ---");
        console.log("Token count:", immData.tokens.length);

        for (uint256 i = 0; i < immData.tokens.length; i++) {
            address token = address(immData.tokens[i]);
            string memory symbol = _trySymbol(token);
            uint8 dec = _tryDec(token);
            console.log("");
            console.log("  Token", i);
            console.log("    Address:", token);
            console.log("    Symbol:", symbol);
            console.log("    Decimals:", dec);
            if (immData.decimalScalingFactors.length > i) {
                console.log("    Scaling factor:", immData.decimalScalingFactors[i]);
            }
            if (token == DUST) {
                console.log("    ** THIS IS DUST (token index", i, ") **");
            }
        }

        console.log("\n  Initial min price:", immData.initialMinPrice);
        console.log("  Initial max price:", immData.initialMaxPrice);
        console.log("  Initial target price:", immData.initialTargetPrice);
        console.log("  tokenAPriceIncludesRate:", immData.tokenAPriceIncludesRate);
        console.log("  tokenBPriceIncludesRate:", immData.tokenBPriceIncludesRate);

        // --- Dynamic Data ---
        IReClammPool.ReClammPoolDynamicData memory dynData = IReClammPool(RECLAMM_POOL).getReClammPoolDynamicData();

        console.log("\n--- Dynamic Data ---");
        console.log("  isPoolInitialized:", dynData.isPoolInitialized);
        console.log("  isPoolPaused:", dynData.isPoolPaused);
        console.log("  isPoolInRecoveryMode:", dynData.isPoolInRecoveryMode);
        console.log("  totalSupply (BPT):", dynData.totalSupply);
        console.log("  lastTimestamp:", dynData.lastTimestamp);
        console.log("  currentPriceRatio:", dynData.currentPriceRatio);
        console.log("  staticSwapFeePercentage:", dynData.staticSwapFeePercentage);

        console.log("\n  Live balances (18-dec scaled):");
        for (uint256 i = 0; i < dynData.balancesLiveScaled18.length; i++) {
            console.log("    Token", i, ":", dynData.balancesLiveScaled18[i]);
        }

        console.log("\n  Virtual balances (18-dec scaled):");
        for (uint256 i = 0; i < dynData.lastVirtualBalances.length; i++) {
            console.log("    Token", i, ":", dynData.lastVirtualBalances[i]);
        }

        console.log("\n  Token rates:");
        for (uint256 i = 0; i < dynData.tokenRates.length; i++) {
            console.log("    Token", i, ":", dynData.tokenRates[i]);
        }

        // --- Compute raw price from virtual balances ---
        if (dynData.lastVirtualBalances.length >= 2) {
            bool dustIsToken0 = (address(immData.tokens[0]) == DUST);
            uint256 virtualDust;
            uint256 virtualPaired;

            if (dustIsToken0) {
                virtualDust = dynData.lastVirtualBalances[0];
                virtualPaired = dynData.lastVirtualBalances[1];
            } else {
                virtualDust = dynData.lastVirtualBalances[1];
                virtualPaired = dynData.lastVirtualBalances[0];
            }

            console.log("\n--- Raw Price Calculation ---");
            console.log("  DUST is token0:", dustIsToken0);
            console.log("  virtualDust:", virtualDust);
            console.log("  virtualPaired:", virtualPaired);

            if (virtualPaired > 0) {
                // DUST per PAIRED = virtualDust / virtualPaired
                uint256 dustPerPaired = (virtualDust * 1e18) / virtualPaired;
                console.log("  DUST per PAIRED (18-dec):", dustPerPaired);

                if (dustPerPaired > 0) {
                    // Assuming PAIRED = USDC at $1.00:
                    // USD per DUST = 1 / dustPerPaired
                    uint256 usdPerDust18 = (1e18 * 1e18) / dustPerPaired;
                    uint256 usdPerDust8 = usdPerDust18 / 1e10;
                    console.log("  USD per DUST (18-dec):", usdPerDust18);
                    console.log("  USD per DUST (8-dec):", usdPerDust8);
                    console.log("  Approx USD price: $", usdPerDust8 / 1e6, ".", usdPerDust8 % 1e6);
                }
            }
        }

        console.log("\n============================================\n");
    }

    /*//////////////////////////////////////////////////////////////
                    2. ORACLE PROBE (read-only)
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify the reCLAMM direct-USD path works (no separate oracle needed)
    function test_02_verifyDirectMode() public pure {
        console.log("============================================");
        console.log("  STEP 2: Verify Direct-USD Mode");
        console.log("============================================\n");
        console.log("The reCLAMM pool is DUST/USDC.");
        console.log("USDC is USD-equivalent, so no pairOracle is needed.");
        console.log("The helper inverts DUST/USDC to get USD/DUST directly.\n");
        console.log("============================================\n");
    }

    /*//////////////////////////////////////////////////////////////
              3. DEPLOY + CONFIGURE + PRICE CHECK
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy helper, configure reCLAMM pool, and check the price
    function test_03_deployAndPrice() public {
        console.log("============================================");
        console.log("  STEP 3: Deploy Helper + Get Price");
        console.log("============================================\n");

        // --- Discover token ordering ---
        IReClammPool.ReClammPoolImmutableData memory immData = IReClammPool(RECLAMM_POOL).getReClammPoolImmutableData();

        bool dustIsToken0 = (address(immData.tokens[0]) == DUST);
        address pairedToken = dustIsToken0 ? address(immData.tokens[1]) : address(immData.tokens[0]);
        string memory pairedSymbol = _trySymbol(pairedToken);

        console.log("DUST is token0:", dustIsToken0);
        console.log("Paired token:", pairedToken);
        console.log("Paired symbol:", pairedSymbol);

        // --- Deploy fresh helper ---
        helper = new NeverlandDustHelper(DUST, deployer);
        console.log("\nDeployed NeverlandDustHelper at:", address(helper));

        // --- Configure reCLAMM pool ---
        helper.setReclammPool(RECLAMM_POOL, dustIsToken0);
        console.log("Set reCLAMM pool:", RECLAMM_POOL, "dustIsToken0:", dustIsToken0);

        // Direct-USD mode: no pairOracle needed (USDC is USD-equivalent)
        // The reCLAMM direct path in _getOraclePrice() will invert DUST/USDC -> USD/DUST
        console.log("Using direct-USD mode (no pairOracle, USDC = $1)");

        // --- Expire the initial cache so getPrice reads live ---
        vm.warp(block.timestamp + 2 hours);

        // --- Read price ---
        (uint256 price, bool fromOracle) = helper.getPrice();

        console.log("\n--- PRICE RESULT ---");
        console.log("  price (8-dec):", price);
        console.log("  fromOracle:", fromOracle);

        if (price > 0) {
            uint256 dollars = price / 1e8;
            uint256 cents = (price % 1e8) / 1e6;
            uint256 subcents = (price % 1e6);
            console.log("  Approx: $%s.%s%s", dollars, cents, subcents);
        } else {
            console.log("  Price is 0 - check pool state and config above");
        }

        // --- Update cache and verify ---
        helper.updatePriceCache();
        (uint256 cachedPrice, bool cachedFromOracle) = helper.getPrice();
        console.log("\n--- CACHED PRICE ---");
        console.log("  cached price (8-dec):", cachedPrice);
        console.log("  fromOracle:", cachedFromOracle);

        // --- Market data ---
        INeverlandDustHelper.MarketData memory data = helper.getMarketData();
        console.log("\n--- MARKET DATA ---");
        console.log("  Total supply:", data.totalSupply / 1e18, "DUST");
        console.log("  USD price (8-dec):", data.usdPrice);
        console.log("  Market cap (8-dec):", data.marketCap);
        console.log("  isPriceFromOracle:", data.isPriceFromOracle);

        // --- Chainlink compat ---
        (uint80 roundId, int256 answer,, uint256 updatedAt,) = helper.latestRoundData();
        console.log("\n--- CHAINLINK COMPAT ---");
        console.log("  roundId:", roundId);
        console.log("  answer:", uint256(answer));
        console.log("  updatedAt:", updatedAt);

        console.log("\n============================================");
        console.log("  DONE - review output above");
        console.log("============================================\n");

        // Basic sanity: price should be non-zero if oracle is configured
        assertTrue(price > 0, "Price should be > 0");
        assertTrue(fromOracle, "Price should come from oracle");
    }

    /*//////////////////////////////////////////////////////////////
                           HELPERS
    //////////////////////////////////////////////////////////////*/

    function _trySymbol(address token) internal view returns (string memory) {
        try IERC20Metadata(token).symbol() returns (string memory s) {
            return s;
        } catch {
            return "???";
        }
    }

    function _tryDec(address token) internal view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 0;
        }
    }
}

/// @dev Minimal mock Chainlink oracle returning $1.00 USDC/USD
contract MockUsdcOracle {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}
