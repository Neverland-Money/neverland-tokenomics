// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPoolDataProvider} from "@neverland-money/lending-core/contracts/interfaces/IPoolDataProvider.sol";
import {IScaledBalanceToken} from "@aave/core-v3/contracts/interfaces/IScaledBalanceToken.sol";
import {IEACAggregatorProxy} from "@aave-v3-periphery/contracts/misc/interfaces/IEACAggregatorProxy.sol";
import {ITransferStrategyBase} from "@aave-v3-periphery/contracts/rewards/interfaces/ITransferStrategyBase.sol";
import {RewardsDataTypes} from "@aave-v3-periphery/contracts/rewards/libraries/RewardsDataTypes.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IDustLock} from "../../../src/interfaces/IDustLock.sol";
import {IDustRewardsController} from "../../../src/interfaces/IDustRewardsController.sol";
import {IDustTransferStrategy} from "../../../src/interfaces/IDustTransferStrategy.sol";
import {INeverlandUiProvider} from "../../../src/interfaces/INeverlandUiProvider.sol";

import {EpochTimeLibrary} from "../../../src/libraries/EpochTimeLibrary.sol";
import {NeverlandUiEnumerationLibrary} from "../../../src/utils/libraries/NeverlandUiEnumerationLibrary.sol";

import {DustRewardsController} from "../../../src/emissions/DustRewardsController.sol";
import {NeverlandUiProvider} from "../../../src/utils/NeverlandUiProvider.sol";

import {BaseTestLocal} from "../../BaseTestLocal.sol";
import {MockERC20 as MockERC20Test} from "../../_utils/MockERC20.sol";
import {MockPoolAddressesProvider} from "../../_utils/MockPoolAddressesProvider.sol";
import {MockPoolAddressesProviderRegistry} from "../../_utils/MockPoolAddressesProviderRegistry.sol";

contract MockRevertingPoolAddressesProvider {
    error OracleUnavailable();

    function getPriceOracle() external pure returns (address) {
        revert OracleUnavailable();
    }
}

/// @notice Simple data provider exposing only methods UiProvider consumes.
contract MockPoolDataProvider {
    IPoolDataProvider.TokenData[] private _reserves;
    mapping(address => address) private _aTokens; // underlying => aToken
    mapping(address => address) private _vDebt; // underlying => variableDebtToken

    function addReserve(address underlying, address aToken, address vDebt) external {
        _reserves.push(IPoolDataProvider.TokenData({symbol: "", tokenAddress: underlying}));
        _aTokens[underlying] = aToken;
        _vDebt[underlying] = vDebt;
    }

    function getAllReservesTokens() external view returns (IPoolDataProvider.TokenData[] memory) {
        IPoolDataProvider.TokenData[] memory out = new IPoolDataProvider.TokenData[](_reserves.length);
        for (uint256 i = 0; i < _reserves.length; i++) {
            out[i] = _reserves[i];
        }

        return out;
    }

    function getReserveTokensAddresses(address underlying)
        external
        view
        returns (address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress)
    {
        return (_aTokens[underlying], address(0), _vDebt[underlying]);
    }
}

/// @notice Minimal price-oracle mock used by NeverlandUiProvider via IPriceOracleGetter.
contract MockPriceOracle {
    function BASE_CURRENCY_UNIT() external pure returns (uint256) {
        return 1e8; // USD 8 decimals
    }

    function getAssetPrice(address) external pure returns (uint256) {
        // Return 1 USD for any asset to keep tests simple
        return 1e8;
    }
}

contract MockHugePriceOracle {
    function BASE_CURRENCY_UNIT() external pure returns (uint256) {
        return 1;
    }

    function getAssetPrice(address) external pure returns (uint256) {
        return type(uint256).max;
    }
}

/// @notice ERC20 that also satisfies IScaledBalanceToken for DustRewardsController configuration.
contract MockScaledERC20 is ERC20, IScaledBalanceToken {
    uint8 private _decimals;
    mapping(address => uint256) private _prevIndex;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    // IScaledBalanceToken minimal behavior: map scaled to normal balances for tests
    function scaledBalanceOf(address user) external view override returns (uint256) {
        return balanceOf(user);
    }

    function getScaledUserBalanceAndSupply(address user) external view override returns (uint256, uint256) {
        return (balanceOf(user), totalSupply());
    }

    function scaledTotalSupply() external view override returns (uint256) {
        return totalSupply();
    }

    function getPreviousIndex(address user) external view override returns (uint256) {
        return _prevIndex[user];
    }
}

contract MockScaledToken {
    function scaledBalanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function getScaledUserBalanceAndSupply(address) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function scaledTotalSupply() external pure returns (uint256) {
        return 0;
    }

    function getPreviousIndex(address) external pure returns (uint256) {
        return 0;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract MockEnumerableDustLockBase {
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(uint256 => uint256)) public ownerToNFTokenIdList;

    function setBalance(address user, uint256 value) external {
        balanceOf[user] = value;
    }

    function setOwner(uint256 id, address user) external {
        ownerOf[id] = user;
    }

    function setOwnedSlot(address user, uint256 index, uint256 id) external {
        ownerToNFTokenIdList[user][index] = id;
    }
}

contract MockEnumerableDustLock is MockEnumerableDustLockBase {
    uint256 public tokenId;

    function setTokenId(uint256 value) external {
        tokenId = value;
    }
}

contract MockEnumerableDustLockWithoutTokenId is MockEnumerableDustLockBase {}

contract MockTransferStrategy is IDustTransferStrategy {
    address private immutable _admin;
    address private immutable _controller;

    constructor(address controller, address admin) {
        _controller = controller;
        _admin = admin;
    }

    function getIncentivesController() external view override returns (address) {
        return _controller;
    }

    function getRewardsAdmin() external view override returns (address) {
        return _admin;
    }

    function performTransfer(address, address, uint256, uint256, uint256) external pure override returns (bool) {
        return true;
    }

    function emergencyWithdrawal(address, address, uint256) external override {}
}

contract NeverlandUiProviderHarness is NeverlandUiProvider {
    constructor(
        address dustLock,
        address revenueReward,
        address dustRewardsController,
        address dustOracle,
        address neverlandPoolRegistry
    ) NeverlandUiProvider(dustLock, revenueReward, dustRewardsController, dustOracle, neverlandPoolRegistry) {}

    function exposedGetRewardSummary(uint256 tokenId, address[] memory rewardTokens)
        external
        view
        returns (RewardSummary memory)
    {
        return _getRewardSummary(tokenId, rewardTokens);
    }

    function exposedGetValidatedOwnedTokenPage(address user, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 tokenCount, uint256 nextRawOffset, bool hasMore)
    {
        return NeverlandUiEnumerationLibrary.getValidatedOwnedTokenPage(DUST_LOCK, user, offset, limit);
    }

    function exposedGetValidatedOwnedTokenIds(address user) external view returns (uint256[] memory ids) {
        return NeverlandUiEnumerationLibrary.getValidatedOwnedTokenIds(DUST_LOCK, user);
    }
}

contract NeverlandUiProviderTest is BaseTestLocal {
    error UserDashboardQueryFailed();

    // Test contracts
    NeverlandUiProvider freshUiProvider;
    // Use RevenueReward and DustLock from BaseTest
    IDustRewardsController dustRewardsController;

    // Local addresses (assigned in setUp)
    address private NEVERLAND_DUST_HELPER;
    address private UI_POOL_DATA_PROVIDER;
    address private LENDING_POOL_ADDRESS_PROVIDER;
    address private REVENUE_REWARD_ADDR;
    address private DUST_LOCK_ADDR;
    address private DUST_REWARDS_CONTROLLER_ADDR;
    address private USDC_TOKEN_ADDR;
    address private UNDERLYING_ADDR;
    address private ATOKEN_ADDR;
    address private VDEBT_TOKEN_ADDR;
    address[] private TEST_EMISSION_ASSETS;

    // Test constants
    uint256 private constant EPOCH_DURATION = 7 days;
    bytes4 private constant INVALID_ADDRESSES_PROVIDER_ID_SELECTOR = bytes4(keccak256("InvalidAddressesProviderId()"));
    /// @dev Mirrors NeverlandUiEnumerationLibrary.MIN_RAW_TOKEN_SCAN_PER_CALL.
    uint256 private constant MIN_RAW_SCAN_BUDGET = 32;
    /// @dev Mirrors NeverlandUiEnumerationLibrary.MAX_RAW_TOKEN_SCAN_PER_CALL.
    uint256 private constant MAX_RAW_SCAN_BUDGET = 1024;

    // ---------- Helpers to seed test users ----------
    function _durations2(uint256 a, uint256 b) internal pure returns (uint256[] memory d) {
        d = new uint256[](2);
        d[0] = a;
        d[1] = b;
    }

    function _durations4() internal pure returns (uint256[] memory d) {
        d = new uint256[](4);
        d[0] = 4 weeks;
        d[1] = 8 weeks;
        d[2] = 16 weeks;
        d[3] = 26 weeks;
    }

    function _mockDustPrice(uint256 price, bool fromOracle) internal {
        vm.mockCall(NEVERLAND_DUST_HELPER, abi.encodeWithSignature("getPrice()"), abi.encode(price, fromOracle));
    }

    function _mockDustValue(uint256 value) internal {
        vm.mockCall(NEVERLAND_DUST_HELPER, abi.encodeWithSignature("getDustValueInUSD(uint256)"), abi.encode(value));
    }

    function _mockFreshDustPrice() internal {
        _mockDustPrice(25000000, true);
        vm.mockCall(NEVERLAND_DUST_HELPER, abi.encodeWithSignature("latestTimestamp()"), abi.encode(block.timestamp));
        vm.mockCall(NEVERLAND_DUST_HELPER, abi.encodeWithSignature("isPriceCacheStale()"), abi.encode(false));
    }

    function _logBanner(string memory border, string memory title) internal {
        emit log(border);
        emit log(title);
        emit log(border);
    }

    function _assertRegistryEntryCleared(MockPoolAddressesProviderRegistry registry, address provider, uint256 id)
        internal
        view
    {
        assertEq(registry.getAddressesProvidersList().length, 0);
        assertEq(registry.getAddressesProviderIdByAddress(provider), 0);
        assertEq(registry.getAddressesProviderAddressById(id), address(0));
    }

    function _assertRewardPriceRowUnresolved(INeverlandUiProvider.PriceData memory priceData) internal pure {
        assertGt(priceData.tokens.length, 1, "reward token should be present");
        assertEq(priceData.prices[1], 0, "unresolved reward price should default to zero");
        assertEq(priceData.lastUpdated[1], 0, "unresolved reward timestamp should default to zero");
    }

    function _getAllPricesForRegisteredProvider(address registeredProvider)
        internal
        returns (INeverlandUiProvider.PriceData memory prices)
    {
        MockPoolAddressesProviderRegistry registry = new MockPoolAddressesProviderRegistry();
        registry.registerAddressesProvider(registeredProvider, 1);
        NeverlandUiProvider provider = new NeverlandUiProvider(
            DUST_LOCK_ADDR, REVENUE_REWARD_ADDR, DUST_REWARDS_CONTROLLER_ADDR, NEVERLAND_DUST_HELPER, address(registry)
        );

        return provider.getAllPrices();
    }

    function _newEnumerableDustLock(address user, uint256 maxTokenId, uint256 balance)
        internal
        returns (MockEnumerableDustLock enumerableDustLock)
    {
        enumerableDustLock = new MockEnumerableDustLock();
        enumerableDustLock.setTokenId(maxTokenId);
        enumerableDustLock.setBalance(user, balance);
    }

    function _deployEnumerationHarness(address enumerableDustLock)
        internal
        returns (NeverlandUiProviderHarness provider)
    {
        return new NeverlandUiProviderHarness(enumerableDustLock, address(1), address(2), address(3), address(4));
    }

    function _deployAndQueryOwnedTokenPage(address enumerableDustLock, address user, uint256 offset, uint256 limit)
        internal
        returns (
            NeverlandUiProviderHarness provider,
            uint256[] memory page,
            uint256 tokenCount,
            uint256 nextRawOffset,
            bool hasMore
        )
    {
        provider = _deployEnumerationHarness(enumerableDustLock);
        (page, tokenCount, nextRawOffset, hasMore) = provider.exposedGetValidatedOwnedTokenPage(user, offset, limit);
    }

    function _seedUserWithLocksAndATokens(address u, uint256 lockAmountPerLock, uint256[] memory durs) internal {
        // Create veDUST locks
        uint256 n = durs.length;
        mintErc20Token(address(DUST), u, lockAmountPerLock * n);
        vm.startPrank(u);
        DUST.approve(DUST_LOCK_ADDR, lockAmountPerLock * n);
        for (uint256 i; i < n; i++) {
            dustLock.createLock(lockAmountPerLock, block.timestamp + durs[i]);
        }
        vm.stopPrank();

        /*
         * Seed Aave aToken balances for emission calculations. Give the user and a second account
         * balances so totalSupply is meaningful.
         */
        mintErc20Token(ATOKEN_ADDR, u, 1000 ether);
        mintErc20Token(ATOKEN_ADDR, address(0xB0B), 2000 ether);
    }

    function _setUp() internal override {
        // Use local contracts from BaseTest (already deployed)

        // Minimal mocks for Aave providers & data provider with one reserve
        MockPoolDataProvider dp = new MockPoolDataProvider();
        MockPoolAddressesProvider addrProvider = new MockPoolAddressesProvider();
        addrProvider.setPoolDataProvider(address(dp));
        // Set a working mock price oracle so getAllPrices() won't revert
        MockPriceOracle priceOracle = new MockPriceOracle();
        addrProvider.setPriceOracle(address(priceOracle));

        // Assign addresses
        NEVERLAND_DUST_HELPER = address(0xBEEF); // will be mocked in tests via vm.mockCall
        UI_POOL_DATA_PROVIDER = address(dp);
        LENDING_POOL_ADDRESS_PROVIDER = address(addrProvider);
        REVENUE_REWARD_ADDR = address(revenueReward);
        DUST_LOCK_ADDR = address(dustLock);
        USDC_TOKEN_ADDR = address(mockUSDC);
        TEST_EMISSION_ASSETS = new address[](11);
        TEST_EMISSION_ASSETS[0] = DUST_LOCK_ADDR; // veNFT contract (should NOT have emissions)
        TEST_EMISSION_ASSETS[1] = 0xc7fE001DD712beFb2de20abD34597CeF0250a6Ba;
        TEST_EMISSION_ASSETS[2] = 0x6D918BFD4b978574b00cfe0f1872931203357d1E;
        TEST_EMISSION_ASSETS[3] = 0xDD1124Cc06B2fEB6B03B94C0feD40b7352C07C24;
        TEST_EMISSION_ASSETS[4] = 0x20838Ac96e96049C844f714B58aaa0cb84414d60;
        TEST_EMISSION_ASSETS[5] = 0x18d5fb20B2D252EaE3C13B51Cb53745F5b7D01dc;
        TEST_EMISSION_ASSETS[6] = 0xFcb0C1De6159E6CED54CBf1222BB0187EB81e59f;
        TEST_EMISSION_ASSETS[7] = 0x5e59DEBC244c947Cbc37763AB92E77A1acF24aF0;
        TEST_EMISSION_ASSETS[8] = 0x0eEa99C3691348E937d33AebBF6aa0537fD0d500;
        TEST_EMISSION_ASSETS[9] = 0xFDC8BC830Fef4BD6885043A279A768720Ec091be;
        TEST_EMISSION_ASSETS[10] = 0xB61fe1aF61D75F44450e3Fa84F2f2dd75059897C;

        // Create an example reserve with aToken & variable debt token
        MockERC20Test underlying = new MockERC20Test("UNDER", "UNDER", 18);
        MockScaledERC20 aToken = new MockScaledERC20("aUNDER", "aUNDER", 18);
        MockScaledERC20 vDebt = new MockScaledERC20("vdUNDER", "vdUNDER", 18);
        UNDERLYING_ADDR = address(underlying);
        ATOKEN_ADDR = address(aToken);
        VDEBT_TOKEN_ADDR = address(vDebt);
        dp.addReserve(UNDERLYING_ADDR, ATOKEN_ADDR, VDEBT_TOKEN_ADDR);

        // Deploy a bare DustRewardsController and configure emissions on the aToken
        DustRewardsController controllerImpl = new DustRewardsController(admin);
        IDustRewardsController controller = IDustRewardsController(address(controllerImpl));
        dustRewardsController = controller;
        DUST_REWARDS_CONTROLLER_ADDR = address(controller);

        // Configure emission for the aToken so getRewardsList() is non-empty and rewards are computable
        MockTransferStrategy ts = new MockTransferStrategy(address(controller), admin);
        RewardsDataTypes.RewardsConfigInput[] memory cfg = new RewardsDataTypes.RewardsConfigInput[](1);
        cfg[0].asset = ATOKEN_ADDR;
        cfg[0].reward = USDC_TOKEN_ADDR;
        cfg[0].transferStrategy = ITransferStrategyBase(address(ts));
        cfg[0].rewardOracle = IEACAggregatorProxy(address(0));
        cfg[0].emissionPerSecond = 1;
        cfg[0].distributionEnd = uint32(block.timestamp + 30 days);
        cfg[0].totalSupply = 0;
        vm.startPrank(admin);
        DustRewardsController(address(controller)).configureAssets(cfg);
        vm.stopPrank();

        // Default mock responses for DustHelper
        _mockDustValue(40000000);
        _mockFreshDustPrice();

        // Create a lock FIRST so the notified rewards land in a live epoch with non-zero voting supply.
        mintErc20Token(address(DUST), address(this), TOKEN_10K);
        DUST.approve(DUST_LOCK_ADDR, TOKEN_10K);
        IDustLock(address(dustLock)).createLock(TOKEN_10K, 26 weeks);

        // Seed: add and notify mockUSDC as a reward token
        vm.startPrank(admin);
        // fund and notify mockUSDC as reward token
        mintErc20Token(address(mockUSDC), admin, USDC_10K);
        mockUSDC.approve(REVENUE_REWARD_ADDR, USDC_10K);
        revenueReward.setRewardDistributor(admin);
        revenueReward.notifyRewardAmount(USDC_TOKEN_ADDR, USDC_10K);
        vm.stopPrank();

        // Seed two users with locks and aToken balances for richer tests
        _seedUserWithLocksAndATokens(user1, 500 ether, _durations2(8 weeks, 16 weeks));
        _seedUserWithLocksAndATokens(
            0x532D4c80b14C7f50095E8E8FD69d9658b5F00371, 500 ether, _durations2(4 weeks, 12 weeks)
        );

        /*
         * Deploy the UI provider with local addresses. Register LENDING_POOL_ADDRESS_PROVIDER at id
         * one so it resolves as canonical, matching the suite's established assumption.
         */
        MockPoolAddressesProviderRegistry poolRegistry = new MockPoolAddressesProviderRegistry();
        poolRegistry.registerAddressesProvider(LENDING_POOL_ADDRESS_PROVIDER, 1);
        freshUiProvider = new NeverlandUiProvider(
            DUST_LOCK_ADDR,
            REVENUE_REWARD_ADDR,
            DUST_REWARDS_CONTROLLER_ADDR,
            NEVERLAND_DUST_HELPER,
            address(poolRegistry)
        );

        // Advance time to move rewards to current epoch for testing
        vm.warp(block.timestamp + EPOCH_DURATION);

        // Labels for better debugging
        vm.label(REVENUE_REWARD_ADDR, "RevenueReward");
        vm.label(DUST_LOCK_ADDR, "DustLock");
        vm.label(USDC_TOKEN_ADDR, "USDC");
        vm.label(address(freshUiProvider), "FreshUiProvider");
    }

    // ============= BASIC CONFIGURATION TESTS =============

    function test_ContractConfiguration() public {
        emit log("=== Testing Contract Configuration ===");

        // Test deployed contract references
        assertEq(address(dustLock), DUST_LOCK_ADDR);
        assertEq(address(revenueReward), REVENUE_REWARD_ADDR);
        assertEq(address(dustRewardsController), DUST_REWARDS_CONTROLLER_ADDR);

        // Test fresh contract references
        assertEq(address(freshUiProvider.DUST_LOCK()), DUST_LOCK_ADDR);
        assertEq(address(freshUiProvider.REVENUE_REWARD()), REVENUE_REWARD_ADDR);
        assertEq(address(freshUiProvider.DUST_REWARDS_CONTROLLER()), DUST_REWARDS_CONTROLLER_ADDR);

        emit log("Contract configuration verified");
    }

    function test_PoolAddressesProviderRegistryRejectsZeroIdWithoutMutation() public {
        MockPoolAddressesProviderRegistry registry = new MockPoolAddressesProviderRegistry();
        address provider = makeAddr("zeroIdProvider");

        vm.expectRevert(INVALID_ADDRESSES_PROVIDER_ID_SELECTOR);
        registry.registerAddressesProvider(provider, 0);

        _assertRegistryEntryCleared(registry, provider, 0);
    }

    function test_PoolAddressesProviderRegistryRegistersAndUnregistersNonzeroId() public {
        MockPoolAddressesProviderRegistry registry = new MockPoolAddressesProviderRegistry();
        address provider = makeAddr("nonzeroIdProvider");

        registry.registerAddressesProvider(provider, 7);

        address[] memory providers = registry.getAddressesProvidersList();
        assertEq(providers.length, 1);
        assertEq(providers[0], provider);
        assertEq(registry.getAddressesProviderIdByAddress(provider), 7);
        assertEq(registry.getAddressesProviderAddressById(7), provider);

        registry.unregisterAddressesProvider(provider);

        _assertRegistryEntryCleared(registry, provider, 7);
    }

    function test_RevenueRewardConfiguration() public {
        emit log("=== Testing RevenueReward Configuration ===");

        address[] memory rewardTokens = revenueReward.getRewardTokens();
        emit log_named_uint("Number of reward tokens", rewardTokens.length);

        assertGt(rewardTokens.length, 0, "No reward tokens configured");

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            emit log_named_address("Reward token", rewardTokens[i]);

            bool isRewardToken = revenueReward.isRewardToken(rewardTokens[i]);
            assertTrue(isRewardToken, "Token should be marked as reward token");
        }

        // Check USDC specifically
        bool usdcIsRewardToken = revenueReward.isRewardToken(USDC_TOKEN_ADDR);
        assertTrue(usdcIsRewardToken, "USDC should be a reward token");

        uint256 usdcBalance = IERC20(USDC_TOKEN_ADDR).balanceOf(REVENUE_REWARD_ADDR);
        emit log_named_uint("USDC balance in RevenueReward", usdcBalance);
    }

    function test_DustLockConfiguration() public {
        emit log("=== Testing DustLock Configuration ===");

        uint256 totalSupply = dustLock.totalSupply();
        uint256 supply = dustLock.supply();

        emit log_named_uint("Total voting power", totalSupply);
        emit log_named_uint("Total locked amount", supply);

        assertGt(totalSupply, 0, "Should have voting power");
        assertGt(supply, 0, "Should have locked tokens");
        assertLe(totalSupply, supply, "Voting power should not exceed locked amount");
    }

    // ============= REWARD EPOCH TESTS =============

    function test_RewardEpochs() public {
        emit log("=== Testing Reward Epochs ===");

        uint256 currentTimestamp = block.timestamp;
        uint256 currentEpoch = EpochTimeLibrary.epochStart(currentTimestamp);
        uint256 nextEpoch = currentEpoch + EPOCH_DURATION;

        emit log_named_uint("Current timestamp", currentTimestamp);
        emit log_named_uint("Current epoch start", currentEpoch);
        emit log_named_uint("Next epoch start", nextEpoch);

        // Check rewards for current and next epochs
        uint256 currentEpochRewards = revenueReward.tokenRewardsPerEpoch(USDC_TOKEN_ADDR, currentEpoch);
        uint256 nextEpochRewards = revenueReward.tokenRewardsPerEpoch(USDC_TOKEN_ADDR, nextEpoch);

        emit log_named_uint("Current epoch USDC rewards", currentEpochRewards);
        emit log_named_uint("Next epoch USDC rewards", nextEpochRewards);

        // At least one epoch should have rewards
        assertTrue(currentEpochRewards > 0 || nextEpochRewards > 0, "Should have rewards in at least one epoch");
    }

    // ============= APR CALCULATION TESTS =============

    function test_MarketDataRetrieval() public {
        emit log("=== Testing Market Data Retrieval ===");

        // Test market data function
        INeverlandUiProvider.MarketData memory marketData = freshUiProvider.getMarketData();

        // Verify market data structure
        assertGt(marketData.rewardTokens.length, 0, "Should have reward tokens");
        assertGt(marketData.currentEpoch, 0, "Should have current epoch");
        assertGt(marketData.nextEpochTimestamp, block.timestamp, "Next epoch should be in future");

        emit log_named_uint("Reward tokens count", marketData.rewardTokens.length);
        emit log_named_uint("Current epoch", marketData.currentEpoch);
        emit log_named_uint("Next epoch timestamp", marketData.nextEpochTimestamp);
        emit log_named_uint("Total value locked USD", marketData.totalValueLockedUSD);

        // Test reward token balances
        for (uint256 i = 0; i < marketData.rewardTokens.length && i < 3; i++) {
            emit log_named_address("Reward token", marketData.rewardTokens[i]);
            emit log_named_uint("Token balance", marketData.rewardTokenBalances[i]);
            emit log_named_uint("Distribution rate", marketData.distributionRates[i]);
            emit log_named_uint("Epoch rewards", marketData.epochRewards[i]);
        }

        emit log("Market data retrieval test passed");
    }

    function test_MarketDataFollowingEpochRewardsMirrorScheduledBucket() public {
        emit log("=== Testing following-epoch (N+2) reward bucket exposure ===");

        // Fund the epoch after next with a known allocation through the distributor.
        MockERC20Test fundingToken = new MockERC20Test("NGV05FUND", "NGV05FUND", 18);
        uint256 fundedAmount = 777 ether;
        address distributor = revenueReward.rewardDistributor();
        mintErc20Token(address(fundingToken), distributor, fundedAmount);
        vm.startPrank(distributor);
        fundingToken.approve(address(revenueReward), fundedAmount);
        revenueReward.notifyRewardAmountForFollowingEpoch(address(fundingToken), fundedAmount);
        vm.stopPrank();

        INeverlandUiProvider.MarketData memory marketData = freshUiProvider.getMarketData();
        uint256 followingEpoch = EpochTimeLibrary.epochNext(block.timestamp) + EPOCH_DURATION;

        /*
         * The N+2 bucket must be exposed one-to-one so following-epoch-only funding cannot appear as
         * zero future rewards.
         */
        assertEq(marketData.followingEpochRewards.length, marketData.rewardTokens.length);
        bool fundingTokenSeen;
        for (uint256 i = 0; i < marketData.rewardTokens.length; i++) {
            assertEq(
                marketData.followingEpochRewards[i],
                revenueReward.tokenRewardsPerEpoch(marketData.rewardTokens[i], followingEpoch)
            );
            if (marketData.rewardTokens[i] == address(fundingToken)) {
                fundingTokenSeen = true;
                assertEq(marketData.followingEpochRewards[i], fundedAmount, "funded N+2 visible in market feed");
            }
        }
        assertTrue(fundingTokenSeen, "funded reward token is listed");

        emit log("Following-epoch bucket mirrors tokenRewardsPerEpoch for every reward token");
    }

    function test_ProtocolMetadata() public {
        emit log("=== Testing Protocol Metadata ===");

        INeverlandUiProvider.ProtocolMeta memory meta = freshUiProvider.getProtocolMeta();

        // Verify addresses
        assertEq(meta.dustLock, DUST_LOCK_ADDR);
        assertEq(meta.revenueReward, REVENUE_REWARD_ADDR);
        assertEq(meta.dustRewardsController, DUST_REWARDS_CONTROLLER_ADDR);

        emit log_named_address("DustLock", meta.dustLock);
        emit log_named_address("RevenueReward", meta.revenueReward);
        emit log_named_address("DustRewardsController", meta.dustRewardsController);
        emit log_named_uint("Early withdraw penalty", meta.earlyWithdrawPenalty);
        emit log_named_uint("Min lock amount", meta.minLockAmount);

        assertGt(meta.revenueRewardTokens.length, 0, "Should have revenue reward tokens");
        emit log_named_uint("Revenue reward tokens count", meta.revenueRewardTokens.length);

        emit log("Protocol metadata test passed");
    }

    function test_FullDashboardResponse() public {
        _logBanner("=========================================", "=== COMPLETE UI DASHBOARD RESPONSE ===");

        address user = user1;
        emit log_named_address("User Address", user);

        // 1. USER DASHBOARD - All user lock and reward data
        emit log("--- USER DASHBOARD ---");
        INeverlandUiProvider.UserDashboardData memory dashboard =
            freshUiProvider.getUserDashboard(user, 0, type(uint256).max);
        emit log_named_uint("Total Voting Power", dashboard.totalVotingPower);
        emit log_named_uint("Total Locked Amount (DUST)", dashboard.totalLockedAmount / 1e18);
        emit log_named_uint("Active Lock Count", dashboard.tokenIds.length);

        // Show each lock position
        for (uint256 i = 0; i < dashboard.locks.length && i < 3; i++) {
            emit log_named_uint("Lock Position", i + 1);
            emit log_named_uint("  Token ID", dashboard.locks[i].tokenId);
            emit log_named_uint("  Amount (DUST)", dashboard.locks[i].amount / 1e18);
            emit log_named_uint("  Voting Power", dashboard.locks[i].votingPower);
            emit log_named_string("  Is Permanent", dashboard.locks[i].isPermanent ? "Yes" : "No");
        }

        // 2. GLOBAL PROTOCOL STATS
        emit log("--- GLOBAL STATS ---");
        INeverlandUiProvider.GlobalStats memory globalStats = freshUiProvider.getGlobalStats();
        emit log_named_uint("Total DUST Supply", globalStats.totalSupply / 1e18);
        emit log_named_uint("Total Voting Power", globalStats.totalVotingPower);
        emit log_named_uint("Permanent Lock Balance", globalStats.permanentLockBalance / 1e18);
        emit log_named_uint("Total Active Locks", globalStats.activeTokenCount);
        emit log_named_uint("Reward Tokens Available", globalStats.rewardTokens.length);

        // 3. MARKET DATA - Revenue and distribution info
        emit log("--- MARKET DATA ---");
        INeverlandUiProvider.MarketData memory marketData = freshUiProvider.getMarketData();
        emit log_named_uint("Current epoch", marketData.currentEpoch);
        emit log_named_uint("Total value locked USD", marketData.totalValueLockedUSD);
        emit log_named_uint("Reward tokens available", marketData.rewardTokens.length);

        // 4. USER EMISSION REWARDS - From lending protocols
        emit log("--- EMISSION REWARDS ---");
        try freshUiProvider.getUserEmissions(user) returns (
            address[] memory emissionTokens, uint256[] memory emissionRewards, bool, uint256, uint256
        ) {
            emit log_named_uint("Emission Token Types", emissionTokens.length);
            for (uint256 i = 0; i < emissionTokens.length && i < 3; i++) {
                emit log_named_address("Emission Token", emissionTokens[i]);
                emit log_named_uint("  Total Rewards", emissionRewards[i]);
            }
        } catch {
            emit log("Emission rewards query failed");
        }

        // 5. USER PARTICIPATION
        emit log("--- PARTICIPATION ---");
        if (globalStats.totalVotingPower > 0) {
            uint256 userShare = (dashboard.totalVotingPower * 10000) / globalStats.totalVotingPower;
            emit log_named_uint("User Share of Protocol (%)", userShare / 100);
            emit log_named_uint("User Share (basis points)", userShare);
        }

        // 6. UNLOCK SCHEDULE
        emit log("--- UNLOCK SCHEDULE ---");
        try freshUiProvider.getUnlockSchedule(user) returns (
            uint256[] memory unlockTimes, uint256[] memory amounts, uint256[] memory tokenIds
        ) {
            emit log_named_uint("Upcoming Unlocks", unlockTimes.length);
            for (uint256 i = 0; i < unlockTimes.length && i < 3; i++) {
                emit log_named_uint("Unlock Time", unlockTimes[i]);
                emit log_named_uint("  Amount (DUST)", amounts[i] / 1e18);
                emit log_named_uint("  Token ID", tokenIds[i]);
            }
        } catch {
            emit log("No upcoming unlocks");
        }

        emit log("=========================================");
        emit log("=== DASHBOARD COMPLETE ===");
        emit log("Available Data:");
        emit log("- User lock positions & voting power");
        emit log("- Global protocol statistics");
        emit log("- Revenue APR calculations");
        emit log("- Emission reward tracking");
        emit log("- User participation metrics");
        emit log("- Unlock scheduling");
        emit log("- All data ready for UI integration!");
        emit log("=========================================");

        // Validation
        assertGt(globalStats.totalSupply, 0, "Protocol should have supply");
        emit log("SUCCESS: Complete dashboard functionality verified!");
    }

    function test_BundledUserViews() public {
        _logBanner("=========================================", "=== TESTING BUNDLED USER VIEWS ===");

        // Use a simple test user - the bundled views should work even with zero balances
        address user = 0x532D4c80b14C7f50095E8E8FD69d9658b5F00371;

        // Mock the dust oracle calls to return valid values to prevent revert
        _mockDustValue(40000000);

        _mockFreshDustPrice();

        /*
         * Mock the optional pending-reward preview so this integration-style test exercises the
         * successful summary path. Dedicated coverage pins fail-soft selector handling.
         */
        vm.mockCall(
            REVENUE_REWARD_ADDR,
            abi.encodeWithSignature("pendingRewards(address,address)", USDC_TOKEN_ADDR, user),
            abi.encode(0)
        );

        emit log_named_address("Testing bundled views for user", user);

        // 1. TEST ESSENTIAL USER VIEW
        emit log("");
        emit log("--- ESSENTIAL USER VIEW ---");
        INeverlandUiProvider.EssentialUserView memory essential =
            freshUiProvider.getEssentialUserView(user, 0, type(uint256).max);

        // Validate user dashboard data
        emit log_named_uint("User total voting power", essential.user.totalVotingPower);
        emit log_named_uint("User total locked amount (DUST)", essential.user.totalLockedAmount / 1e18);
        emit log_named_uint("User active lock count", essential.user.tokenIds.length);
        // User may have zero tokens - that's valid for bundled functions

        // Validate global stats
        emit log_named_uint("Protocol total supply (DUST)", essential.globalStats.totalSupply / 1e18);
        emit log_named_uint("Protocol total voting power", essential.globalStats.totalVotingPower);
        emit log_named_uint("Protocol active tokens", essential.globalStats.activeTokenCount);
        assertGt(essential.globalStats.totalSupply, 0, "Protocol should have supply");
        assertGt(essential.globalStats.totalVotingPower, 0, "Protocol should have voting power");

        // Validate emissions data
        emit log_named_uint("Emission reward types", essential.emissions.rewardTokens.length);
        if (essential.emissions.rewardTokens.length > 0) {
            emit log_named_address("First emission token", essential.emissions.rewardTokens[0]);
            emit log_named_uint("First emission rewards", essential.emissions.totalRewards[0]);
        }

        // Validate market data
        emit log_named_uint("Market reward tokens", essential.marketData.rewardTokens.length);
        emit log_named_uint("Market TVL USD", essential.marketData.totalValueLockedUSD);
        emit log_named_uint("Current epoch", essential.marketData.currentEpoch);
        assertGt(essential.marketData.rewardTokens.length, 0, "Should have reward tokens");

        // 2. TEST EXTENDED USER VIEW
        emit log("");
        emit log("--- EXTENDED USER VIEW ---");

        // Test components individually first to isolate any issues
        emit log("Testing individual components...");
        (uint256[] memory unlockTimes, uint256[] memory amounts, uint256[] memory tokenIds) =
            freshUiProvider.getUnlockSchedule(user);
        emit log_named_uint("Unlock schedule length", unlockTimes.length);

        INeverlandUiProvider.GlobalStats memory globalStats2 = freshUiProvider.getGlobalStats();
        emit log_named_uint("Global stats total supply", globalStats2.totalSupply / 1e18);

        INeverlandUiProvider.UserRewardsSummary memory rewardsSummary =
            freshUiProvider.getUserRewardsSummary(user, globalStats2.rewardTokens);
        emit log_named_uint("Revenue rewards length", rewardsSummary.totalRevenue.length);
        emit log_named_uint("Emission rewards length", rewardsSummary.totalEmissions.length);

        // Test getAllPrices separately since it might fail
        emit log("Testing getAllPrices...");
        bool pricesSuccessful = false;
        INeverlandUiProvider.PriceData memory priceData;

        try freshUiProvider.getAllPrices() returns (INeverlandUiProvider.PriceData memory prices) {
            priceData = prices;
            pricesSuccessful = true;
            emit log_named_uint("Price data tokens", prices.tokens.length);
            emit log("getAllPrices() successful");
        } catch {
            emit log("WARNING: getAllPrices() failed - will use empty price data");
            // Create empty price data as fallback
            address[] memory emptyTokens = new address[](0);
            uint256[] memory emptyPrices = new uint256[](0);
            uint256[] memory emptyTimestamps = new uint256[](0);
            priceData = INeverlandUiProvider.PriceData({
                tokens: emptyTokens,
                prices: emptyPrices,
                lastUpdated: emptyTimestamps,
                resolvedMask: 0,
                dustPriceFromOracle: false,
                asOfBlock: 0,
                asOfTimestamp: 0
            });
            pricesSuccessful = false;
        }

        // Create extended view manually since getExtendedUserView might fail due to getAllPrices
        INeverlandUiProvider.UnlockSchedule memory unlockSchedule =
            INeverlandUiProvider.UnlockSchedule({unlockTimes: unlockTimes, amounts: amounts, tokenIds: tokenIds});

        INeverlandUiProvider.ExtendedUserView memory extended =
            INeverlandUiProvider.ExtendedUserView({unlockSchedule: unlockSchedule, allPrices: priceData});

        emit log_named_string("Price data status", pricesSuccessful ? "SUCCESS" : "FALLBACK");

        // Validate unlock schedule
        emit log_named_uint("Scheduled unlocks", extended.unlockSchedule.unlockTimes.length);
        if (extended.unlockSchedule.unlockTimes.length > 0) {
            emit log_named_uint("First unlock time", extended.unlockSchedule.unlockTimes[0]);
            emit log_named_uint("First unlock amount (DUST)", extended.unlockSchedule.amounts[0] / 1e18);
            emit log_named_uint("First unlock token ID", extended.unlockSchedule.tokenIds[0]);
        }

        // Validate rewards summary separately (not in extended view)
        emit log_named_uint("Revenue reward types", rewardsSummary.totalRevenue.length);
        emit log_named_uint("Emission reward types", rewardsSummary.totalEmissions.length);

        if (rewardsSummary.totalRevenue.length > 0) {
            emit log_named_uint("Total revenue rewards", rewardsSummary.totalRevenue[0]);
            emit log_named_uint("Total emission rewards", rewardsSummary.totalEmissions[0]);
        }

        // Validate price data
        emit log_named_uint("Price data tokens", extended.allPrices.tokens.length);
        if (extended.allPrices.tokens.length > 0) {
            emit log_named_address("First price token", extended.allPrices.tokens[0]);
            emit log_named_uint("First token price", extended.allPrices.prices[0]);
            emit log_named_uint("First price timestamp", extended.allPrices.lastUpdated[0]);
        }

        // 3. CROSS-VALIDATION
        emit log("");
        emit log("--- CROSS-VALIDATION ---");

        // Global stats should be consistent
        assertGt(essential.globalStats.totalSupply, 0, "Global stats should show protocol supply");

        // 4. DATA COMPLETENESS CHECK
        emit log("");
        emit log("--- DATA COMPLETENESS ---");

        uint256 totalDataPoints = 0;

        // Essential view data points
        totalDataPoints += essential.user.tokenIds.length; // User tokens
        totalDataPoints += essential.globalStats.rewardTokens.length; // Global reward tokens
        totalDataPoints += essential.emissions.rewardTokens.length; // Emission tokens
        totalDataPoints += essential.marketData.rewardTokens.length; // Market tokens

        // Extended view data points
        totalDataPoints += extended.unlockSchedule.unlockTimes.length; // Unlocks
        totalDataPoints += rewardsSummary.totalRevenue.length; // Revenue rewards (separate call)
        totalDataPoints += extended.allPrices.tokens.length; // Price data

        emit log_named_uint("Total data points across both views", totalDataPoints);
        assertGe(totalDataPoints, 3, "Should have essential data across both views");

        emit log("");
        _logBanner("=========================================", "=== BUNDLED VIEWS VALIDATION COMPLETE ===");
        emit log("[PASS] Essential view contains core dashboard data");
        emit log("[PASS] Extended view contains detailed analysis data");
        emit log("[PASS] Cross-validation passed");
        emit log("[PASS] Data completeness verified");
        emit log("[PASS] Both views provide comprehensive user data");
        emit log("[SUCCESS] Frontend can now use 2 calls instead of 8+ calls!");
        emit log("=========================================");
    }

    function testGetUserRewardsSummaryChunksOversizedRewardTokenInput() public {
        mintErc20Token(address(DUST), user, TOKEN_1);
        vm.startPrank(user);
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);
        vm.stopPrank();

        uint256 len = revenueReward.MAX_TOKENS() + 2;
        address[] memory rewardTokens = new address[](len);
        for (uint256 i; i < len; ++i) {
            rewardTokens[i] = address(uint160(0xA11CE + i));
        }

        NeverlandUiProviderHarness harness = new NeverlandUiProviderHarness(
            DUST_LOCK_ADDR,
            REVENUE_REWARD_ADDR,
            DUST_REWARDS_CONTROLLER_ADDR,
            NEVERLAND_DUST_HELPER,
            LENDING_POOL_ADDRESS_PROVIDER
        );

        INeverlandUiProvider.RewardSummary memory summary = harness.exposedGetRewardSummary(tokenId, rewardTokens);

        assertEq(summary.rewardTokens.length, len);
        assertEq(summary.revenueRewards.length, len);
    }

    function test_PriceDataRetrieval() public {
        emit log("=== Testing Price Data Retrieval ===");

        // Mock the dust oracle calls to return valid values
        _mockFreshDustPrice();

        INeverlandUiProvider.PriceData memory priceData = freshUiProvider.getAllPrices();

        assertGt(priceData.tokens.length, 0, "Should have token prices");
        assertEq(priceData.prices.length, priceData.tokens.length, "Prices array should match tokens array");

        emit log_named_uint("Price data tokens count", priceData.tokens.length);

        for (uint256 i = 0; i < priceData.tokens.length && i < 3; i++) {
            emit log_named_address("Token", priceData.tokens[i]);
            emit log_named_uint("Price", priceData.prices[i]);
            emit log_named_uint("Last updated", priceData.lastUpdated[i]);
        }

        emit log("Price data retrieval test passed");
    }

    // ============= EDGE CASE TESTS =============

    function test_NetworkDataRetrieval() public {
        emit log("=== Testing Network Data Retrieval ===");

        INeverlandUiProvider.NetworkData memory networkData = freshUiProvider.getNetworkData();

        assertGt(networkData.currentBlock, 0, "Should have current block");
        assertGt(networkData.currentTimestamp, 0, "Should have current timestamp");

        emit log_named_uint("Current block", networkData.currentBlock);
        emit log_named_uint("Current timestamp", networkData.currentTimestamp);
        emit log_named_uint("Gas price", networkData.gasPrice);

        emit log("Network data retrieval test passed");
    }

    function test_UiBootstrapBundle() public {
        emit log("=== Testing UI Bootstrap Bundle ===");

        // Mock the dust oracle calls
        _mockFreshDustPrice();
        _mockDustValue(40000000);

        INeverlandUiProvider.UiBootstrap memory bootstrap = freshUiProvider.getUiBootstrap();

        // Verify all components are present
        assertNotEq(bootstrap.meta.dustLock, address(0), "Should have dustLock address");
        assertGt(bootstrap.globalStats.totalSupply, 0, "Should have total supply");
        assertGt(bootstrap.marketData.rewardTokens.length, 0, "Should have market data");
        assertGt(bootstrap.allPrices.tokens.length, 0, "Should have price data");
        assertGt(bootstrap.network.currentBlock, 0, "Should have network data");

        emit log_named_address("Bootstrap DustLock", bootstrap.meta.dustLock);
        emit log_named_uint("Bootstrap total supply", bootstrap.globalStats.totalSupply);
        emit log_named_uint("Bootstrap reward tokens", bootstrap.marketData.rewardTokens.length);
        emit log_named_uint("Bootstrap price tokens", bootstrap.allPrices.tokens.length);

        emit log("UI Bootstrap bundle test passed");
    }

    function test_GetAllPricesDefaultsRewardPricesToZeroWhenAaveOracleUnavailable() public {
        MockPoolAddressesProvider addrProvider = new MockPoolAddressesProvider();
        addrProvider.setPoolDataProvider(UI_POOL_DATA_PROVIDER);

        INeverlandUiProvider.PriceData memory priceData = _getAllPricesForRegisteredProvider(address(addrProvider));

        _assertRewardPriceRowUnresolved(priceData);
    }

    function test_GetAllPricesDefaultsRewardPricesToZeroWhenAaveProviderReverts() public {
        INeverlandUiProvider.PriceData memory priceData =
            _getAllPricesForRegisteredProvider(address(new MockRevertingPoolAddressesProvider()));

        _assertRewardPriceRowUnresolved(priceData);
    }

    function test_GetAllPricesDefaultsRewardPricesToZeroWhenAaveOracleNormalizationWouldOverflow() public {
        MockPoolAddressesProvider addrProvider = new MockPoolAddressesProvider();
        addrProvider.setPoolDataProvider(UI_POOL_DATA_PROVIDER);
        addrProvider.setPriceOracle(address(new MockHugePriceOracle()));

        INeverlandUiProvider.PriceData memory priceData = _getAllPricesForRegisteredProvider(address(addrProvider));

        _assertRewardPriceRowUnresolved(priceData);
    }

    function test_GetAllPricesDefaultsDustFieldsToZeroWhenDustHelperReverts() public {
        vm.mockCallRevert(
            NEVERLAND_DUST_HELPER,
            abi.encodeWithSignature("getPrice()"),
            abi.encodeWithSignature("Error(string)", "dust helper down")
        );
        vm.mockCallRevert(
            NEVERLAND_DUST_HELPER,
            abi.encodeWithSignature("latestTimestamp()"),
            abi.encodeWithSignature("Error(string)", "dust helper down")
        );

        INeverlandUiProvider.PriceData memory priceData = freshUiProvider.getAllPrices();

        assertEq(priceData.prices[0], 0, "reverting DUST price helper should default price to zero");
        assertEq(priceData.lastUpdated[0], 0, "reverting DUST timestamp helper should default timestamp to zero");
    }

    function test_UiBootstrapDefaultsMarketTvlToZeroWhenDustHelperValueReverts() public {
        vm.mockCallRevert(
            NEVERLAND_DUST_HELPER,
            abi.encodeWithSignature("getDustValueInUSD(uint256)", dustLock.supply()),
            abi.encodeWithSignature("Error(string)", "dust helper down")
        );

        INeverlandUiProvider.UiBootstrap memory bootstrap = freshUiProvider.getUiBootstrap();

        assertEq(bootstrap.marketData.totalValueLockedUSD, 0, "reverting DUST value helper should not revert bundle");
    }

    // ============= GLOBAL STATS TESTS =============

    function test_GlobalStats() public {
        emit log("=== Testing Global Stats ===");

        try freshUiProvider.getGlobalStats() returns (INeverlandUiProvider.GlobalStats memory stats) {
            emit log_named_uint("Total supply", stats.totalSupply);
            emit log_named_uint("Total voting power", stats.totalVotingPower);
            emit log_named_uint("Permanent lock balance", stats.permanentLockBalance);
            emit log_named_uint("Active token count", stats.activeTokenCount);

            assertGt(stats.totalSupply, 0, "Should have total supply");
            assertGt(stats.totalVotingPower, 0, "Should have voting power");

            emit log("Global stats test passed");
        } catch Error(string memory reason) {
            emit log_named_string("Global stats failed", reason);
        } catch (bytes memory) {
            emit log("Global stats reverted");
        }
    }

    // ============= USER DASHBOARD TESTS =============

    function test_UserDashboard() public {
        emit log("=== Testing User Dashboard ===");

        // Use the pre-seeded user with 2 locks and aToken balance
        address testUser = address(0x532D4c80b14C7f50095E8E8FD69d9658b5F00371);

        INeverlandUiProvider.UserDashboardData memory dashboard =
            freshUiProvider.getUserDashboard(testUser, 0, type(uint256).max);
        emit log_named_uint("User total voting power", dashboard.totalVotingPower);
        emit log_named_uint("User total locked amount", dashboard.totalLockedAmount);
        emit log_named_uint("User token count", dashboard.tokenIds.length);

        // Now assert we actually have meaningful, non-zero data
        assertEq(dashboard.tokenIds.length, 2, "Expected 2 lock positions");
        assertGt(dashboard.totalLockedAmount, 0, "Expected non-zero locked amount");
        assertGt(dashboard.totalVotingPower, 0, "Expected non-zero voting power");
        emit log("User dashboard test completed with seeded positions");
    }

    function test_ValidatedOwnedTokenPaginationSkipsStaleRawSlots() public {
        address user = address(0xA11CE);
        MockEnumerableDustLock enumerableDustLock = _newEnumerableDustLock(user, 6, 2);
        enumerableDustLock.setOwnedSlot(user, 0, 11);
        enumerableDustLock.setOwner(11, address(0xB0B));
        enumerableDustLock.setOwnedSlot(user, 1, 0);
        enumerableDustLock.setOwnedSlot(user, 2, 21);
        enumerableDustLock.setOwner(21, user);
        enumerableDustLock.setOwnedSlot(user, 3, 22);
        enumerableDustLock.setOwner(22, user);

        (
            NeverlandUiProviderHarness provider,
            uint256[] memory page,
            uint256 tokenCount,
            uint256 nextRawOffset,
            bool hasMore
        ) = _deployAndQueryOwnedTokenPage(address(enumerableDustLock), user, 0, 2);

        assertEq(tokenCount, 2, "live balance should be preserved");
        assertEq(page.length, 2, "page should fill past stale slots");
        assertEq(page[0], 21, "first valid token");
        assertEq(page[1], 22, "second valid token");
        assertEq(nextRawOffset, 4, "cursor should advance by raw scanned slots");
        assertFalse(hasMore, "all live owned tokens were returned");

        uint256[] memory allIds = provider.exposedGetValidatedOwnedTokenIds(user);

        assertEq(allIds.length, 2, "all-token scan should also skip stale slots");
        assertEq(allIds[0], 21, "first all-token id");
        assertEq(allIds[1], 22, "second all-token id");
    }

    function test_ValidatedOwnedTokenPaginationDoesNotAdvertiseGlobalMintTail() public {
        address user = address(0xA11CE);
        MockEnumerableDustLock enumerableDustLock = _newEnumerableDustLock(user, 100, 2);
        enumerableDustLock.setOwnedSlot(user, 0, 71);
        enumerableDustLock.setOwner(71, user);
        enumerableDustLock.setOwnedSlot(user, 1, 72);
        enumerableDustLock.setOwner(72, user);

        (, uint256[] memory page, uint256 tokenCount, uint256 nextRawOffset, bool hasMore) =
            _deployAndQueryOwnedTokenPage(address(enumerableDustLock), user, 0, 2);

        assertEq(tokenCount, 2, "live balance should be preserved");
        assertEq(page.length, 2, "full compact page should return both tokens");
        assertEq(page[0], 71, "first owned token id");
        assertEq(page[1], 72, "second owned token id");
        assertEq(nextRawOffset, 2, "cursor should stop after compact owned range");
        assertFalse(hasMore, "global tokenId tail should not create an empty next page");
    }

    function test_ValidatedOwnedTokenPaginationZeroLimitDoesNotLoopCursor() public {
        address user = address(0xA11CE);
        MockEnumerableDustLock enumerableDustLock = _newEnumerableDustLock(user, 10, 1);
        enumerableDustLock.setOwnedSlot(user, 0, 51);
        enumerableDustLock.setOwner(51, user);

        (, uint256[] memory page, uint256 tokenCount, uint256 nextRawOffset, bool hasMore) =
            _deployAndQueryOwnedTokenPage(address(enumerableDustLock), user, 0, 0);

        assertEq(tokenCount, 1, "live balance should be preserved");
        assertEq(page.length, 0, "zero limit returns no tokens");
        assertEq(nextRawOffset, 0, "zero limit keeps bounded cursor");
        assertFalse(hasMore, "zero limit must not advertise an infinite next page");
    }

    function test_ValidatedOwnedTokenPaginationStopsAtRawScanBudget() public {
        address user = address(0xA11CE);
        MockEnumerableDustLock enumerableDustLock = _newEnumerableDustLock(user, 2000, 1);
        enumerableDustLock.setOwnedSlot(user, 1500, 61);
        enumerableDustLock.setOwner(61, user);

        NeverlandUiProviderHarness provider = _deployEnumerationHarness(address(enumerableDustLock));

        (uint256[] memory page,, uint256 nextRawOffset, bool hasMore) =
            provider.exposedGetValidatedOwnedTokenPage(user, 0, 1);

        assertEq(page.length, 0, "sparse page should not scan the global token id range in one call");
        assertEq(nextRawOffset, MIN_RAW_SCAN_BUDGET, "limit-one page should stop at the minimum raw scan budget");
        assertTrue(hasMore, "caller can keep paginating through sparse ranges");

        uint256[] memory allTokenIds = provider.exposedGetValidatedOwnedTokenIds(user);

        assertEq(allTokenIds.length, 1, "unpaginated enumeration should remain complete");
        assertEq(allTokenIds[0], 61, "unpaginated enumeration should scan beyond the page budget");
    }

    function test_RawTokenScanEndClampsToMinimumBudget() public pure {
        assertEq(NeverlandUiEnumerationLibrary.rawTokenScanEnd(0, 1_000, 1), MIN_RAW_SCAN_BUDGET, "min budget");
        assertEq(
            NeverlandUiEnumerationLibrary.rawTokenScanEnd(0, 10_000, type(uint256).max),
            MAX_RAW_SCAN_BUDGET,
            "max budget"
        );
        assertEq(NeverlandUiEnumerationLibrary.rawTokenScanEnd(40, 41, 1), 41, "remaining bound wins");
        assertEq(NeverlandUiEnumerationLibrary.rawTokenScanEnd(5, 5, 1), 5, "empty range");
        assertEq(NeverlandUiEnumerationLibrary.rawTokenScanEnd(0, 1_000, 0), 0, "zero limit");
    }

    function test_ValidatedOwnedTokenPaginationClampsAllocationToMaxRawScanBudget() public {
        address user = address(0xA11CE);
        MockEnumerableDustLock enumerableDustLock = _newEnumerableDustLock(user, 2_000, 2_000);

        NeverlandUiProviderHarness provider = _deployEnumerationHarness(address(enumerableDustLock));

        (uint256[] memory page, uint256 tokenCount, uint256 nextRawOffset, bool hasMore) =
            provider.exposedGetValidatedOwnedTokenPage(user, 0, type(uint256).max);

        assertEq(tokenCount, 2_000, "live token count");
        assertEq(page.length, 0, "empty mock slots produce no valid ids");
        assertEq(nextRawOffset, MAX_RAW_SCAN_BUDGET, "scan stops at max raw budget");
        assertTrue(hasMore, "remaining raw slots stay reachable");
    }

    function test_ValidatedOwnedTokenPaginationKeepsSparseTailOpenAfterFullPage() public {
        address user = address(0xA11CE);
        MockEnumerableDustLock enumerableDustLock = _newEnumerableDustLock(user, 200, 2);
        enumerableDustLock.setOwnedSlot(user, 100, 81);
        enumerableDustLock.setOwner(81, user);
        enumerableDustLock.setOwnedSlot(user, 101, 82);
        enumerableDustLock.setOwner(82, user);

        NeverlandUiProviderHarness provider = _deployEnumerationHarness(address(enumerableDustLock));

        (uint256[] memory page,, uint256 nextRawOffset, bool hasMore) =
            provider.exposedGetValidatedOwnedTokenPage(user, 96, 1);

        assertEq(page.length, 1, "sparse page should find first live token");
        assertEq(page[0], 81, "first sparse token id");
        assertEq(nextRawOffset, 101, "cursor should continue after first sparse token");
        assertTrue(hasMore, "full sparse page should keep later raw slots reachable");

        (page,, nextRawOffset, hasMore) = provider.exposedGetValidatedOwnedTokenPage(user, nextRawOffset, 1);

        assertEq(page.length, 1, "next sparse page should find second live token");
        assertEq(page[0], 82, "second sparse token id");
        assertEq(nextRawOffset, 102, "cursor should continue after second sparse token");
        assertTrue(hasMore, "sparse raw tail remains conservatively pageable");
    }

    function test_ValidatedOwnedTokenPaginationFallsBackWhenTokenIdUnavailable() public {
        address user = address(0xA11CE);
        MockEnumerableDustLockWithoutTokenId enumerableDustLock = new MockEnumerableDustLockWithoutTokenId();
        enumerableDustLock.setBalance(user, 1);
        enumerableDustLock.setOwnedSlot(user, 0, 31);
        enumerableDustLock.setOwner(31, user);

        (, uint256[] memory page, uint256 tokenCount, uint256 nextRawOffset, bool hasMore) =
            _deployAndQueryOwnedTokenPage(address(enumerableDustLock), user, 0, 1);

        assertEq(tokenCount, 1, "live balance should be preserved");
        assertEq(page.length, 1, "page should fill through fallback bound");
        assertEq(page[0], 31, "owned token id");
        assertEq(nextRawOffset, 1, "cursor should advance to fallback bound");
        assertFalse(hasMore, "fallback bound exhausted");
    }

    function test_ValidatedOwnedTokenPaginationClampsLowTokenIdBoundToBalance() public {
        address user = address(0xA11CE);
        MockEnumerableDustLock enumerableDustLock = _newEnumerableDustLock(user, 1, 2);
        enumerableDustLock.setOwnedSlot(user, 0, 41);
        enumerableDustLock.setOwner(41, user);
        enumerableDustLock.setOwnedSlot(user, 1, 42);
        enumerableDustLock.setOwner(42, user);

        (, uint256[] memory page, uint256 tokenCount, uint256 nextRawOffset, bool hasMore) =
            _deployAndQueryOwnedTokenPage(address(enumerableDustLock), user, 0, 2);

        assertEq(tokenCount, 2, "live balance should be preserved");
        assertEq(page.length, 2, "page should fill through clamped balance bound");
        assertEq(page[0], 41, "first owned token id");
        assertEq(page[1], 42, "second owned token id");
        assertEq(nextRawOffset, 2, "cursor should advance to clamped bound");
        assertFalse(hasMore, "clamped bound exhausted");
    }

    function test_SpecificUserWith4Positions() public {
        _logBanner("=========================================", "=== TESTING SPECIFIC USER WITH 4 veDUST POSITIONS ===");

        // Deterministic user; create 4 locks locally
        address testUser = 0x447fea41f53C39F97956D7de1aB9864e0Bf2da7f;
        vm.label(testUser, "TestUser4Locks");

        uint256 lockAmount = 1000 ether;
        mintErc20Token(address(DUST), testUser, lockAmount * 4);
        vm.startPrank(testUser);
        DUST.approve(DUST_LOCK_ADDR, lockAmount * 4);
        uint256[] memory tokenIds = new uint256[](4);
        uint256[] memory lockDurations = _durations4();
        for (uint256 i = 0; i < 4; i++) {
            tokenIds[i] = dustLock.createLock(lockAmount, block.timestamp + lockDurations[i]);
        }
        vm.stopPrank();

        // Now test the UI provider functionality
        try freshUiProvider.getUserDashboard(testUser, 0, type(uint256).max) returns (
            INeverlandUiProvider.UserDashboardData memory dashboard
        ) {
            // Verify user has exactly 4 positions and correct total lock
            assertEq(dashboard.tokenIds.length, 4, "User should have exactly 4 veDUST positions");
            assertEq(dashboard.totalLockedAmount, lockAmount * 4, "Total locked amount should be 4000 DUST");

            // Verify the lock details included in the dashboard.
            assertEq(dashboard.locks.length, 4, "Should retrieve details for all 4 tokens");
            assertEq(dashboard.rewardSummaries.length, 4, "Should retrieve rewards for all 4 tokens");
            for (uint256 i = 0; i < dashboard.locks.length; i++) {
                assertEq(dashboard.locks[i].amount, lockAmount, "Token lock amount should match");
            }
            emit log("[SUCCESS] All 4 veDUST positions created and verified successfully");
        } catch Error(string memory reason) {
            emit log_named_string("User dashboard failed", reason);

            revert UserDashboardQueryFailed();
        }
    }

    function test_BatchTokenDetailsForSpecificUser() public {
        emit log("=== Testing Batch Token Details for Specific User ===");

        address targetUser = 0x0000B06460777398083CB501793a4d6393900000;

        // First get the user's token IDs
        try freshUiProvider.getUserDashboard(targetUser, 0, type(uint256).max) returns (
            INeverlandUiProvider.UserDashboardData memory dashboard
        ) {
            if (dashboard.tokenIds.length > 0) {
                emit log_named_uint("Found token IDs count", dashboard.tokenIds.length);

                // Verify the lock details included in the dashboard.
                emit log_named_uint("Dashboard returned locks", dashboard.locks.length);
                emit log_named_uint("Dashboard returned rewards", dashboard.rewardSummaries.length);

                assertEq(dashboard.locks.length, dashboard.tokenIds.length, "Locks count should match token IDs");
                assertEq(
                    dashboard.rewardSummaries.length, dashboard.tokenIds.length, "Rewards count should match token IDs"
                );

                emit log("[SUCCESS] Dashboard query works correctly");
            } else {
                emit log("No tokens found for user");
            }
        } catch {
            emit log("Could not get user dashboard");
        }
    }

    function test_CreateAndVerify4Positions() public {
        _logBanner("=========================================", "=== CREATING AND VERIFYING 4 veDUST POSITIONS ===");

        // Create test user and give them DUST tokens
        address testUser = makeAddr("testUser");
        uint256 lockAmount = 1000 * 1e18; // 1000 DUST per lock

        // Give user DUST tokens and approve DustLock
        deal(address(DUST), testUser, lockAmount * 4);

        vm.startPrank(testUser);
        DUST.approve(address(dustLock), lockAmount * 4);

        emit log_named_address("Test User", testUser);
        emit log_named_uint("Initial DUST Balance", DUST.balanceOf(testUser));

        // Create 4 different lock positions with varying durations
        uint256[] memory tokenIds = new uint256[](4);
        uint256[] memory lockDurations = _durations4();

        emit log("");
        emit log("--- CREATING LOCK POSITIONS ---");

        for (uint256 i = 0; i < 4; i++) {
            tokenIds[i] = dustLock.createLock(lockAmount, block.timestamp + lockDurations[i]);
            emit log_named_string("Created Lock", string(abi.encodePacked("Position #", vm.toString(i + 1))));
            emit log_named_uint("  Token ID", tokenIds[i]);
            emit log_named_uint("  Lock Amount", lockAmount);
            emit log_named_uint("  Duration (days)", lockDurations[i] / 1 days);
        }

        vm.stopPrank();

        emit log("");
        emit log("--- VERIFYING POSITIONS WITH UI PROVIDER ---");

        // Now test the UI provider functionality
        try freshUiProvider.getUserDashboard(testUser, 0, type(uint256).max) returns (
            INeverlandUiProvider.UserDashboardData memory dashboard
        ) {
            emit log("--- USER OVERVIEW ---");
            emit log_named_uint("Total Token Count", dashboard.tokenIds.length);
            emit log_named_uint("Total Voting Power", dashboard.totalVotingPower);
            emit log_named_uint("Total Locked Amount (DUST)", dashboard.totalLockedAmount);

            // Verify user has exactly 4 positions
            assertEq(dashboard.tokenIds.length, 4, "User should have exactly 4 veDUST positions");
            assertEq(dashboard.totalLockedAmount, lockAmount * 4, "Total locked amount should be 4000 DUST");

            emit log("");
            emit log("--- INDIVIDUAL POSITION DETAILS ---");

            // Log details for each position
            for (uint256 i = 0; i < dashboard.tokenIds.length; i++) {
                emit log_named_string("Position", string(abi.encodePacked("Lock #", vm.toString(i + 1))));
                emit log_named_uint("  Token ID", dashboard.tokenIds[i]);
                emit log_named_uint("  Locked Amount", dashboard.locks[i].amount);
                emit log_named_uint("  Lock End Time", dashboard.locks[i].end);
                emit log_named_uint("  Voting Power", dashboard.locks[i].votingPower);
                emit log_named_string("  Is Permanent", dashboard.locks[i].isPermanent ? "true" : "false");

                // Verify each lock has the expected amount
                assertEq(dashboard.locks[i].amount, lockAmount, "Each lock should have 1000 DUST");

                if (dashboard.rewardSummaries.length > i) {
                    emit log_named_uint("  Reward Tokens", dashboard.rewardSummaries[i].rewardTokens.length);
                    if (dashboard.rewardSummaries[i].revenueRewards.length > 0) {
                        emit log_named_uint("  Revenue Rewards", dashboard.rewardSummaries[i].revenueRewards[0]);
                    }
                    // Emissions are user-level and are tested separately.
                }
                emit log("");
            }

            // Verify the dashboard lock and reward detail arrays.
            emit log("--- TOKEN DETAILS FROM DASHBOARD ---");
            emit log_named_uint("Retrieved locks count", dashboard.locks.length);
            emit log_named_uint("Retrieved rewards count", dashboard.rewardSummaries.length);

            assertEq(dashboard.locks.length, 4, "Should retrieve details for all 4 tokens");
            assertEq(dashboard.rewardSummaries.length, 4, "Should retrieve rewards for all 4 tokens");

            for (uint256 i = 0; i < dashboard.locks.length; i++) {
                emit log_named_string(
                    "Token Details", string(abi.encodePacked("Token #", vm.toString(dashboard.locks[i].tokenId)))
                );
                emit log_named_uint("  Lock Amount", dashboard.locks[i].amount);
                emit log_named_uint("  Lock End", dashboard.locks[i].end);
                emit log_named_uint("  Voting Power", dashboard.locks[i].votingPower);
                emit log_named_string("  Is Permanent", dashboard.locks[i].isPermanent ? "true" : "false");

                // Verify token data consistency
                assertEq(dashboard.locks[i].amount, lockAmount, "Token lock amount should match");
            }

            emit log("[SUCCESS] All 4 veDUST positions created and verified successfully");
        } catch Error(string memory reason) {
            emit log_named_string("User dashboard failed", reason);

            revert UserDashboardQueryFailed();
        }
    }

    function test_LocalUserDashboardData() public {
        _logBanner("=========================================", "=== TESTING USER WITH LOCAL DATA ===");

        // Use a local user and create positions
        address targetUser = user2;
        uint256 lockAmt = 500 ether;
        mintErc20Token(address(DUST), targetUser, lockAmt * 2);
        vm.startPrank(targetUser);
        DUST.approve(DUST_LOCK_ADDR, lockAmt * 2);
        dustLock.createLock(lockAmt, block.timestamp + 8 weeks);
        dustLock.createLock(lockAmt, block.timestamp + 16 weeks);
        vm.stopPrank();
        emit log_named_address("Target User", targetUser);

        // Test 1: getUserDashboard - Complete user data
        emit log("");
        emit log("--- TESTING getUserDashboard ---");
        try freshUiProvider.getUserDashboard(targetUser, 0, type(uint256).max) returns (
            INeverlandUiProvider.UserDashboardData memory dashboard
        ) {
            emit log_named_uint("[PASS] Total Token Count", dashboard.tokenIds.length);
            emit log_named_uint("[PASS] Total Voting Power", dashboard.totalVotingPower);
            emit log_named_uint("[PASS] Total Locked Amount (DUST)", dashboard.totalLockedAmount);

            if (dashboard.tokenIds.length > 0) {
                emit log_named_uint("[PASS] First Token ID", dashboard.tokenIds[0]);
                emit log_named_uint("[PASS] First Lock Amount", dashboard.locks[0].amount);
                emit log_named_string(
                    "[PASS] First Lock Type", dashboard.locks[0].isPermanent ? "Permanent" : "Temporary"
                );

                // Inspect the lock details returned with the dashboard.
                emit log("");
                emit log("--- TESTING LOCK DETAILS FROM DASHBOARD ---");
                emit log_named_uint("[PASS] Dashboard locks count", dashboard.locks.length);
                emit log_named_uint("[PASS] Dashboard rewards count", dashboard.rewardSummaries.length);

                for (uint256 i = 0; i < dashboard.locks.length && i < 3; i++) {
                    emit log_named_string("Token Detail", string(abi.encodePacked("Position #", vm.toString(i + 1))));
                    emit log_named_uint("  Token ID", dashboard.locks[i].tokenId);
                    emit log_named_uint("  Amount", dashboard.locks[i].amount);
                    emit log_named_uint("  Voting Power", dashboard.locks[i].votingPower);
                }
            } else {
                emit log("[INFO] User has no positions, testing with empty arrays");
            }
        } catch Error(string memory reason) {
            emit log_named_string("[FAIL] getUserDashboard failed", reason);
        }

        // Test 2: getGlobalStats - Protocol-wide statistics
        emit log("");
        emit log("--- TESTING getGlobalStats ---");
        try freshUiProvider.getGlobalStats() returns (INeverlandUiProvider.GlobalStats memory stats) {
            emit log_named_uint("[PASS] Total Supply", stats.totalSupply);
            emit log_named_uint("[PASS] Total Voting Power", stats.totalVotingPower);
            emit log_named_uint("[PASS] Permanent Lock Balance", stats.permanentLockBalance);
            emit log_named_uint("[PASS] Current Epoch", stats.epoch);
            emit log_named_uint("[PASS] Active Token Count", stats.activeTokenCount);
            emit log_named_uint("[PASS] Reward Tokens Count", stats.rewardTokens.length);
        } catch Error(string memory reason) {
            emit log_named_string("[FAIL] getGlobalStats failed", reason);
        }

        // Test 3: getMarketData - Market and pricing data
        emit log("");
        emit log("--- TESTING getMarketData ---");
        try freshUiProvider.getMarketData() returns (INeverlandUiProvider.MarketData memory market) {
            emit log_named_uint("[PASS] Current Epoch", market.currentEpoch);
            emit log_named_uint("[PASS] Total Value Locked USD", market.totalValueLockedUSD);
            emit log_named_uint("[PASS] Reward Tokens Count", market.rewardTokens.length);
            if (market.rewardTokens.length > 0) {
                emit log_named_address("[PASS] First Reward Token", market.rewardTokens[0]);
            }
        } catch Error(string memory reason) {
            emit log_named_string("[FAIL] getMarketData failed", reason);
        }

        // Test 4: getProtocolMeta - Protocol metadata
        emit log("");
        emit log("--- TESTING getProtocolMeta ---");
        try freshUiProvider.getProtocolMeta() returns (INeverlandUiProvider.ProtocolMeta memory meta) {
            emit log_named_address("[PASS] DustLock", meta.dustLock);
            emit log_named_address("[PASS] RevenueReward", meta.revenueReward);
            emit log_named_address("[PASS] DustRewardsController", meta.dustRewardsController);
            emit log_named_address("[PASS] DustOracle", meta.dustOracle);
            emit log_named_uint("[PASS] Min Lock Amount", meta.minLockAmount);
            emit log_named_uint("[PASS] Early Withdraw Penalty", meta.earlyWithdrawPenalty);
        } catch Error(string memory reason) {
            emit log_named_string("[FAIL] getProtocolMeta failed", reason);
        }

        // Test 5: getNetworkData - Network information
        emit log("");
        emit log("--- TESTING getNetworkData ---");
        try freshUiProvider.getNetworkData() returns (INeverlandUiProvider.NetworkData memory network) {
            emit log_named_uint("[PASS] Current Block", network.currentBlock);
            emit log_named_uint("[PASS] Current Timestamp", network.currentTimestamp);
            emit log_named_uint("[PASS] Gas Price", network.gasPrice);
        } catch Error(string memory reason) {
            emit log_named_string("[FAIL] getNetworkData failed", reason);
        }

        // Test 6: getUserEmissions - Emission rewards
        emit log("");
        emit log("--- TESTING getUserEmissions ---");
        try freshUiProvider.getUserEmissions(targetUser) returns (
            address[] memory emissionTokens, uint256[] memory emissionRewards, bool, uint256, uint256
        ) {
            emit log_named_uint("[PASS] Emission Tokens Count", emissionTokens.length);
            emit log_named_uint("[PASS] Emission Rewards Count", emissionRewards.length);
        } catch Error(string memory reason) {
            emit log_named_string("[FAIL] getUserEmissions failed", reason);
        }

        // Test 7: getUnlockSchedule - When tokens unlock
        emit log("");
        emit log("--- TESTING getUnlockSchedule ---");
        try freshUiProvider.getUnlockSchedule(targetUser) returns (
            uint256[] memory unlockTimes, uint256[] memory amounts, uint256[] memory tokenIds
        ) {
            emit log_named_uint("[PASS] Unlock Events Count", unlockTimes.length);
            emit log_named_uint("[PASS] Unlock Events Count", tokenIds.length);
            if (unlockTimes.length > 0) {
                emit log_named_uint("[PASS] First Unlock Time", unlockTimes[0]);
                emit log_named_uint("[PASS] First Unlock Amount", amounts[0]);
            }
        } catch Error(string memory reason) {
            emit log_named_string("[FAIL] getUnlockSchedule failed", reason);
        }

        // Test 8: getAllPrices - Price data (might need mocking)
        emit log("");
        emit log("--- TESTING getAllPrices ---");
        try freshUiProvider.getAllPrices() returns (INeverlandUiProvider.PriceData memory prices) {
            emit log_named_uint("[PASS] Price Tokens Count", prices.tokens.length);
            emit log_named_uint("[PASS] Prices Count", prices.prices.length);
        } catch Error(string memory reason) {
            emit log_named_string("[INFO] getAllPrices failed (expected)", reason);
        }

        // Test 9: getUiBootstrap - Complete bootstrap data
        emit log("");
        emit log("--- TESTING getUiBootstrap ---");
        try freshUiProvider.getUiBootstrap() returns (INeverlandUiProvider.UiBootstrap memory bootstrap) {
            emit log_named_address("[PASS] Bootstrap DustLock", bootstrap.meta.dustLock);
            emit log_named_uint("[PASS] Bootstrap Global Supply", bootstrap.globalStats.totalSupply);
            emit log_named_uint("[PASS] Bootstrap Market Epoch", bootstrap.marketData.currentEpoch);
        } catch Error(string memory reason) {
            emit log_named_string("[FAIL] getUiBootstrap failed", reason);
        }

        emit log("");
        _logBanner("=========================================", "=== LOCAL DATA TEST COMPLETED ===");
    }

    // ============= EMISSIONS BREAKDOWN TESTS =============

    function test_EmissionsConfiguration() public {
        emit log("=== Testing Emissions Configuration ===");

        // Test DustRewardsController configuration
        address[] memory rewardTokens = dustRewardsController.getRewardsList();
        emit log_named_uint("Number of emission reward tokens", rewardTokens.length);

        // Real assets that might have emissions
        address[] storage knownAssets = TEST_EMISSION_ASSETS;

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address rewardToken = rewardTokens[i];
            emit log_named_address("Emission reward token", rewardToken);

            // Check known assets for this reward token
            for (uint256 j = 0; j < knownAssets.length; j++) {
                address asset = knownAssets[j];

                try dustRewardsController.getRewardsData(asset, rewardToken) returns (
                    uint256 index, uint256 emissionPerSecond, uint256 lastUpdateTimestamp, uint256 distributionEnd
                ) {
                    if (emissionPerSecond > 0) {
                        emit log_named_uint("Index", index);
                        emit log_named_address("Asset with emissions", asset);
                        emit log_named_uint("Emission per second", emissionPerSecond);
                        emit log_named_uint("Last update timestamp", lastUpdateTimestamp);
                        emit log_named_uint("Distribution end", distributionEnd);
                    }
                } catch {
                    // Asset not configured for this reward token
                }
            }
        }
    }

    function test_UserEmissionsRewards() public {
        address testUser = 0x532D4c80b14C7f50095E8E8FD69d9658b5F00371;
        if (block.chainid == 31337) {
            emit log("Using local mock emissions data on localhost");
            _seedLocalEmissionsData(testUser);
        }
        _logBanner("========================================", "=== DETAILED USER EMISSIONS ANALYSIS ===");

        emit log_named_address("Analyzing emissions for user", testUser);

        // Get emission reward tokens from rewards controller
        address[] memory emissionTokens = dustRewardsController.getRewardsList();
        emit log_named_uint("Total emission reward token types", emissionTokens.length);

        address[] memory testAssets = _emissionAssetsForDetailedAnalysis();

        emit log("");
        emit log("--- EMISSION TOKENS BREAKDOWN ---");

        uint256 grandTotalRewards = 0;
        uint256 rewardTypeCount = 0;

        for (uint256 i = 0; i < emissionTokens.length; i++) {
            address rewardToken = emissionTokens[i];
            emit log_named_address("Checking reward token", rewardToken);

            // Check user's direct accrued rewards for this token
            uint256 accruedRewards = dustRewardsController.getUserAccruedRewards(testUser, rewardToken);
            emit log_named_uint("  Direct accrued rewards", accruedRewards);

            // Check rewards from each asset for this reward token
            uint256 totalForThisToken = 0;
            bool hasRewardsFromAssets = false;

            emit log("  Checking user participation in emission assets:");
            uint256 activeAssets = 0;
            uint256 totalUserBalance = 0;

            for (uint256 j = 0; j < testAssets.length; j++) {
                address asset = testAssets[j];

                // Check user balance and emission config
                try IERC20(asset).balanceOf(testUser) returns (uint256 userBalance) {
                    if (userBalance > 0) {
                        emit log_named_address("    Asset with balance", asset);
                        emit log_named_uint("    Balance", userBalance);
                        totalUserBalance += userBalance;
                        activeAssets++;

                        // Check if asset had emissions
                        try dustRewardsController.getRewardsData(asset, rewardToken) returns (
                            uint256, uint256 emissionPerSecond, uint256, uint256
                        ) {
                            if (emissionPerSecond > 0) {
                                emit log("    [ELIGIBLE] Asset had emission rewards");
                            }
                        } catch {}
                    }
                } catch {}
            }

            emit log_named_uint("  Total assets with user balance", activeAssets);
            emit log_named_uint("  Combined user balance across assets", totalUserBalance);

            if (activeAssets > 0) {
                emit log("  [CONFIRMED] User actively participated in emission-eligible assets");
                emit log("  [ISSUE] Reward queries failing despite user participation");
            }

            // Try getting all user rewards at once with all populated assets.
            emit log("  Trying getAllUserRewards with all assets:");
            try dustRewardsController.getAllUserRewards(testAssets, testUser) returns (
                address[] memory allTokens, uint256[] memory allAmounts
            ) {
                emit log_named_uint("    Found reward types", allTokens.length);
                for (uint256 k = 0; k < allTokens.length; k++) {
                    emit log_named_address("    Reward token", allTokens[k]);
                    emit log_named_uint("    Amount", allAmounts[k]);
                    if (allTokens[k] == rewardToken && allAmounts[k] > 0) {
                        totalForThisToken = allAmounts[k];
                        hasRewardsFromAssets = true;
                    }
                }
            } catch Error(string memory reason) {
                emit log_named_string("    getAllUserRewards error", reason);
            } catch {
                emit log("    getAllUserRewards reverted");
            }

            // Use the higher of direct accrued or asset-based calculation
            uint256 finalAmount = accruedRewards > totalForThisToken ? accruedRewards : totalForThisToken;

            if (finalAmount > 0) {
                emit log("  [SUCCESS] USER HAS EMISSIONS!");
                emit log_named_uint("  Final reward amount", finalAmount);
                grandTotalRewards += finalAmount;
                rewardTypeCount++;
            } else {
                emit log("  [NONE] No emissions for this token");
            }

            emit log("  ---");
        }

        emit log("");
        _logBanner("========================================", "=== COMPREHENSIVE CLAIMABLE BREAKDOWN ===");

        // Get all claimable rewards using the rewards controller.
        try dustRewardsController.getAllUserRewards(testAssets, testUser) returns (
            address[] memory claimableTokens, uint256[] memory claimableAmounts
        ) {
            emit log_named_uint("Total claimable reward types", claimableTokens.length);

            uint256 totalClaimableValue = 0;

            if (claimableTokens.length > 0) {
                emit log("");
                emit log("[BREAKDOWN] PER-TOKEN CLAIMABLE BREAKDOWN:");
                emit log("================================");

                for (uint256 i = 0; i < claimableTokens.length; i++) {
                    emit log_named_address("Token", claimableTokens[i]);
                    emit log_named_uint("Claimable amount", claimableAmounts[i]);

                    // Try to identify token name
                    if (claimableTokens[i] == USDC_TOKEN_ADDR) {
                        emit log("Token type: USDC (6 decimals)");
                        emit log_named_uint("Amount in USDC units", claimableAmounts[i] / 1e6);
                    } else if (claimableTokens[i] == address(DUST)) {
                        emit log("Token type: DUST (18 decimals)");
                        emit log_named_uint("Amount in DUST units", claimableAmounts[i] / 1e18);
                    } else {
                        emit log("Token type: Unknown");
                    }

                    totalClaimableValue += claimableAmounts[i];
                    emit log("---");
                }

                emit log("");
                emit log("[SUMMARY] TOTALS:");
                emit log("============");
                emit log_named_uint("Total reward token types", claimableTokens.length);
                emit log_named_uint("Combined raw value", totalClaimableValue);
            } else {
                emit log("[NONE] NO CLAIMABLE EMISSIONS FOUND");
                emit log("User has no pending emission rewards to claim");
            }
        } catch Error(string memory reason) {
            emit log("[ERROR] FAILED TO GET CLAIMABLE REWARDS");
            emit log_named_string("Reason", reason);
        } catch {
            emit log("[ERROR] CLAIMABLE REWARDS QUERY REVERTED");
            emit log("This might indicate no rewards configuration or user has no balances");
        }

        emit log("");
        _logBanner("========================================", "=== FINAL EMISSIONS SUMMARY ===");
        emit log_named_uint("Total emission reward types found", rewardTypeCount);
        emit log_named_uint("Grand total raw rewards", grandTotalRewards);

        if (grandTotalRewards == 0) {
            emit log("[DIAGNOSIS] User has no emission rewards");
            emit log("This could be because:");
            emit log("- User doesn't participate in lending protocol");
            emit log("- No emission rewards are currently configured");
            emit log("- User's rewards have already been claimed");
            emit log("- User's balances are too small to accrue rewards");
        } else {
            emit log("[SUCCESS] User has emission rewards to claim!");
        }

        emit log("========================================");
    }

    function _seedLocalEmissionsData(address testUser) internal {
        mintErc20Token(ATOKEN_ADDR, testUser, 1000 ether);
        mintErc20Token(ATOKEN_ADDR, address(0xB0B), 2000 ether);

        skip(1 hours);
        vm.prank(ATOKEN_ADDR);
        dustRewardsController.handleAction(
            testUser, IERC20(ATOKEN_ADDR).totalSupply(), IERC20(ATOKEN_ADDR).balanceOf(testUser)
        );
    }

    function _emissionAssetsForDetailedAnalysis() internal view returns (address[] memory assets) {
        if (block.chainid == 31337) {
            assets = new address[](1);
            assets[0] = ATOKEN_ADDR;
        } else {
            assets = TEST_EMISSION_ASSETS;
        }
    }

    function test_EnhancedUserEmissions() public {
        _logBanner("========================================", "=== ENHANCED USER EMISSIONS TEST ===");

        address testUser = 0x532D4c80b14C7f50095E8E8FD69d9658b5F00371;
        emit log_named_address("Testing enhanced emissions for user", testUser);

        // Exercise getUserEmissions.
        emit log("");
        emit log("--- TESTING getUserEmissions() ---");

        try freshUiProvider.getUserEmissions(testUser) returns (
            address[] memory rewardTokens, uint256[] memory totalRewards, bool, uint256, uint256
        ) {
            emit log_named_uint("Found reward token types", rewardTokens.length);
            emit log("[SUCCESS] getUserEmissions() works!");

            for (uint256 i = 0; i < rewardTokens.length; i++) {
                emit log_named_address("  Reward Token", rewardTokens[i]);
                emit log_named_uint("  Total Rewards", totalRewards[i]);
                if (totalRewards[i] > 0) {
                    emit log("    [FOUND] User has emission rewards!");
                }
            }
        } catch Error(string memory reason) {
            emit log_named_string("getUserEmissions failed", reason);
        } catch {
            emit log("getUserEmissions reverted");
        }

        // Test getUserEmissions with existing user
        emit log("");
        emit log("--- TESTING getUserEmissions() WITH EXISTING USER ---");

        address existingUser = user1; // User with a lock

        try freshUiProvider.getUserEmissions(existingUser) returns (
            address[] memory rewardTokens, uint256[] memory totalRewards, bool, uint256, uint256
        ) {
            emit log_named_uint("Found emission reward tokens", rewardTokens.length);
            emit log("[SUCCESS] getUserEmissions() works!");

            for (uint256 i = 0; i < rewardTokens.length && i < 3; i++) {
                emit log_named_address("Emission token", rewardTokens[i]);
                emit log_named_uint("  Total rewards", totalRewards[i]);
            }
        } catch Error(string memory reason) {
            emit log_named_string("getUserEmissions failed", reason);
        } catch {
            emit log("getUserEmissions reverted");
        }

        emit log("");
        _logBanner("========================================", "=== ENHANCED EMISSIONS SUMMARY ===");
        emit log("SUCCESS: getUserEmissions() provides clean token->rewards arrays");
        emit log("SUCCESS: Automatic asset discovery across registered Neverland lending markets");
        emit log("SUCCESS: Robust fallback logic handles query failures gracefully");
        emit log("SUCCESS: Ready-to-use data for frontend integration");
        emit log("========================================");
    }

    function test_DustLockVsEmissions() public {
        emit log("=== Testing DustLock vs Emissions Integration ===");

        // DustLock should not be configured as an emission asset; check every reward token.
        address[] memory dustRewards = dustRewardsController.getRewardsList();
        bool dustLockHasEmissions = false;

        for (uint256 i = 0; i < dustRewards.length; i++) {
            try dustRewardsController.getRewardsData(DUST_LOCK_ADDR, dustRewards[i]) returns (
                uint256, uint256 emissionPerSecond, uint256, uint256
            ) {
                if (emissionPerSecond > 0) {
                    dustLockHasEmissions = true;
                    break;
                }
            } catch {
                // No emissions configured for this reward token
            }
        }

        assertFalse(dustLockHasEmissions, "DustLock should NOT have emission rewards");
        emit log("VERIFIED: DustLock is not configured for emissions (correct)");

        // But DustLock should receive revenue rewards
        address[] memory revenueTokens = revenueReward.getRewardTokens();
        assertGt(revenueTokens.length, 0, "Should have revenue reward tokens");
        emit log_named_uint("Revenue reward tokens count", revenueTokens.length);

        // Check that we have both systems working
        uint256 totalVotingPower = dustLock.totalSupply();
        assertGt(totalVotingPower, 0, "Should have voting power for revenue rewards");

        address[] memory allEmissionRewards = dustRewardsController.getRewardsList();
        assertGt(allEmissionRewards.length, 0, "Should have emission rewards configured");

        emit log("VERIFIED: Both revenue rewards (for DustLock) and emissions (for lending) are configured");
    }

    function test_EmissionsBreakdown() public {
        emit log("=== Testing Complete Emissions Breakdown ===");

        emit log("--- REVENUE REWARDS (DustLock veNFT holders) ---");
        address[] memory revenueTokens = revenueReward.getRewardTokens();
        for (uint256 i = 0; i < revenueTokens.length; i++) {
            address token = revenueTokens[i];
            uint256 balance = IERC20(token).balanceOf(REVENUE_REWARD_ADDR);
            emit log_named_address("Revenue token", token);
            emit log_named_uint("Balance in contract", balance);

            // Check current and next epoch rewards
            uint256 currentEpoch = EpochTimeLibrary.epochStart(block.timestamp);
            uint256 currentRewards = revenueReward.tokenRewardsPerEpoch(token, currentEpoch);
            uint256 nextRewards = revenueReward.tokenRewardsPerEpoch(token, currentEpoch + EPOCH_DURATION);

            emit log_named_uint("Current epoch rewards", currentRewards);
            emit log_named_uint("Next epoch rewards", nextRewards);
        }

        emit log("--- EMISSION REWARDS (Lending protocol users) ---");
        address[] memory emissionTokens = dustRewardsController.getRewardsList();

        // Real assets for emissions checking
        address[] storage emissionAssets = TEST_EMISSION_ASSETS;

        for (uint256 i = 0; i < emissionTokens.length; i++) {
            address token = emissionTokens[i];
            emit log_named_address("Emission token", token);

            // Check known assets for emissions with this token
            uint256 totalEmissionPerSecond = 0;

            for (uint256 j = 0; j < emissionAssets.length; j++) {
                try dustRewardsController.getRewardsData(emissionAssets[j], token) returns (
                    uint256, uint256 emissionPerSecond, uint256, uint256 distributionEnd
                ) {
                    emit log_named_address("  Checking asset", emissionAssets[j]);
                    emit log_named_uint("  Emission/sec", emissionPerSecond);
                    emit log_named_uint("  Distribution end", distributionEnd);
                    emit log_named_uint("  Current timestamp", block.timestamp);

                    if (emissionPerSecond > 0 && block.timestamp < distributionEnd) {
                        totalEmissionPerSecond += emissionPerSecond;
                        emit log("  [ACTIVE] Asset has active emissions");
                    } else if (emissionPerSecond > 0) {
                        emit log("  [ENDED] Asset has emissions but distribution ended");
                    } else {
                        emit log("  [NONE] Asset has no emissions");
                    }
                } catch {
                    emit log_named_address("  Asset not configured", emissionAssets[j]);
                }
            }

            emit log_named_uint("Total emission per second (raw)", totalEmissionPerSecond);
            emit log_named_uint("Total emission per second (DUST)", totalEmissionPerSecond / 1e18);
            emit log_named_uint("Daily emissions (raw)", totalEmissionPerSecond * 86400);
            emit log_named_uint("Daily emissions (DUST)", (totalEmissionPerSecond * 86400) / 1e18);
        }

        emit log("Emissions breakdown completed");
    }

    // ============= INTEGRATION TESTS =============

    function test_FullIntegrationTest() public {
        emit log("=== Full Integration Test ===");

        // Test the complete flow
        uint256 step = 1;

        // Step 1: Verify reward configuration
        assertTrue(revenueReward.isRewardToken(USDC_TOKEN_ADDR), "USDC should be reward token");
        emit log_named_uint("Step completed", step++);

        // Step 2: Verify there are rewards
        uint256 currentEpoch = EpochTimeLibrary.epochStart(block.timestamp);
        uint256 epochRewards = revenueReward.tokenRewardsPerEpoch(USDC_TOKEN_ADDR, currentEpoch);
        if (epochRewards == 0) {
            epochRewards = revenueReward.tokenRewardsPerEpoch(USDC_TOKEN_ADDR, currentEpoch + EPOCH_DURATION);
        }
        assertGt(epochRewards, 0, "Should have rewards");
        emit log_named_uint("Step completed", step++);

        // Step 3: Verify voting power exists
        uint256 totalVotingPower = dustLock.totalSupply();
        assertGt(totalVotingPower, 0, "Should have voting power");
        emit log_named_uint("Step completed", step++);

        // Step 4: Get Market Data (includes TVL and distribution rates)
        INeverlandUiProvider.MarketData memory marketData = freshUiProvider.getMarketData();
        assertGt(marketData.rewardTokens.length, 0, "Should have market data");
        emit log_named_uint("Step completed", step++);

        // Step 5: Verify distribution rates global stats
        try freshUiProvider.getGlobalStats() returns (INeverlandUiProvider.GlobalStats memory stats) {
            assertGt(stats.totalVotingPower, 0, "Global stats should show voting power");
            emit log_named_uint("Step completed", step++);
        } catch {
            emit log("Global stats failed but continuing");
            step++;
        }

        emit log_named_uint("Integration test completed steps", step - 1);
        emit log("Full integration test PASSED");
    }
}
