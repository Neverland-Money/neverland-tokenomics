// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolDataProvider} from "@neverland-money/lending-core/contracts/interfaces/IPoolDataProvider.sol";

import {IDustLock} from "../../../src/interfaces/IDustLock.sol";
import {IDustRewardsController} from "../../../src/interfaces/IDustRewardsController.sol";
import {INeverlandUiProvider} from "../../../src/interfaces/INeverlandUiProvider.sol";

import {DustRewardsController} from "../../../src/emissions/DustRewardsController.sol";
import {NeverlandUiProvider} from "../../../src/utils/NeverlandUiProvider.sol";

import {BaseTestLocal} from "../../BaseTestLocal.sol";
import {MockPoolAddressesProvider} from "../../_utils/MockPoolAddressesProvider.sol";
import {MockPoolAddressesProviderRegistry} from "../../_utils/MockPoolAddressesProviderRegistry.sol";

/// @notice Configurable Aave price oracle used to drive each branch of `getTokenPriceInUSDResolved`.
contract ConfigurablePriceOracle {
    error AssetPriceReadReverted();
    error BaseCurrencyUnitReadReverted();

    uint256 private _unit = 1e8;
    uint256 private _price = 1e8;
    bool private _revertUnit;
    bool private _revertPrice;

    function setUnit(uint256 unit_) external {
        _unit = unit_;
    }

    function setPrice(uint256 price_) external {
        _price = price_;
    }

    function setRevertUnit(bool v) external {
        _revertUnit = v;
    }

    function setRevertPrice(bool v) external {
        _revertPrice = v;
    }

    function BASE_CURRENCY_UNIT() external view returns (uint256) {
        if (_revertUnit) revert BaseCurrencyUnitReadReverted();

        return _unit;
    }

    function getAssetPrice(address) external view returns (uint256) {
        if (_revertPrice) revert AssetPriceReadReverted();

        return _price;
    }
}

/// @notice Minimal data provider with no reserves (drives the empty-asset paths cheaply).
contract EmptyDataProvider {
    function getAllReservesTokens() external pure returns (IPoolDataProvider.TokenData[] memory) {
        return new IPoolDataProvider.TokenData[](0);
    }

    function getReserveTokensAddresses(address)
        external
        pure
        returns (address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress)
    {
        return (address(0), address(0), address(0));
    }
}

/**
 * @notice Covers the non-DUST oracle paths in `NeverlandUiPriceMarketLibrary` and the unset data
 *         provider path in `NeverlandUiEmissionLibrary` through the provider's public surface.
 */
contract NeverlandUiProviderExtraCoverageTest is BaseTestLocal {
    MockPoolAddressesProvider internal addrProvider;
    ConfigurablePriceOracle internal priceOracle;
    EmptyDataProvider internal dataProvider;
    IDustRewardsController internal controller;
    MockPoolAddressesProviderRegistry internal poolRegistry;

    address internal constant DUST_HELPER = address(0xBEEF);

    function _setUp() internal override {
        // Controllable Aave plumbing.
        dataProvider = new EmptyDataProvider();
        priceOracle = new ConfigurablePriceOracle();
        addrProvider = new MockPoolAddressesProvider();
        addrProvider.setPoolDataProvider(address(dataProvider));
        addrProvider.setPriceOracle(address(priceOracle));
        /*
         * Register addrProvider at id 1 so it resolves as canonical, matching the test suite's
         * established assumption that this is the canonical pool provider.
         */
        poolRegistry = new MockPoolAddressesProviderRegistry();
        poolRegistry.registerAddressesProvider(address(addrProvider), 1);

        // Bare emission controller so getRewardsList() works.
        controller = IDustRewardsController(address(new DustRewardsController(admin)));

        // DustHelper mocks (DUST token price path stays valid).
        vm.mockCall(DUST_HELPER, abi.encodeWithSignature("getDustValueInUSD(uint256)"), abi.encode(uint256(40000000)));
        vm.mockCall(DUST_HELPER, abi.encodeWithSignature("getPrice()"), abi.encode(uint256(25000000), true));
        vm.mockCall(DUST_HELPER, abi.encodeWithSignature("latestTimestamp()"), abi.encode(block.timestamp));

        // Establish non-zero veDUST voting supply so the notified rewards land in a live, claimable epoch.
        mintErc20Token(address(DUST), address(this), TOKEN_10K);
        DUST.approve(address(dustLock), TOKEN_10K);
        IDustLock(address(dustLock)).createLock(TOKEN_10K, 26 weeks);

        // Register mockUSDC as a revenue reward token so getAllPrices() iterates a non-DUST token.
        vm.startPrank(admin);
        mintErc20Token(address(mockUSDC), admin, USDC_10K);
        mockUSDC.approve(address(revenueReward), USDC_10K);
        revenueReward.setRewardDistributor(admin);
        revenueReward.notifyRewardAmount(address(mockUSDC), USDC_10K);
        vm.stopPrank();
    }

    function _deployProvider() internal returns (NeverlandUiProvider) {
        return new NeverlandUiProvider(
            address(dustLock), address(revenueReward), address(controller), DUST_HELPER, address(poolRegistry)
        );
    }

    /// @notice Reads the non-DUST reward token price (index 1) from getAllPrices().
    function _rewardTokenPrice() internal returns (uint256) {
        NeverlandUiProvider provider = _deployProvider();
        INeverlandUiProvider.PriceData memory prices = provider.getAllPrices();
        // index 0 is the DUST token; the registered mockUSDC reward token follows.
        assertGt(prices.tokens.length, 1);
        assertEq(prices.tokens[1], address(mockUSDC));

        return prices.prices[1];
    }

    /*//////////////////////////////////////////////////////////////
                  TOKEN PRICE RESOLUTION BRANCHES
    //////////////////////////////////////////////////////////////*/

    /// @notice oracleAddr == address(0) -> price 0 for the non-DUST token.
    function testTokenPriceZeroWhenOracleUnset() public {
        addrProvider.setPriceOracle(address(0));

        uint256 price = _rewardTokenPrice();

        assertEq(price, 0);
    }

    /// @notice BASE_CURRENCY_UNIT() reverting -> caught -> price 0.
    function testTokenPriceZeroWhenUnitCallReverts() public {
        priceOracle.setRevertUnit(true);

        uint256 price = _rewardTokenPrice();

        assertEq(price, 0);
    }

    /// @notice unit < 1 -> price 0.
    function testTokenPriceZeroWhenUnitBelowOne() public {
        priceOracle.setUnit(0);

        uint256 price = _rewardTokenPrice();

        assertEq(price, 0);
    }

    /// @notice getAssetPrice() reverting -> caught -> price 0.
    function testTokenPriceZeroWhenPriceCallReverts() public {
        priceOracle.setRevertPrice(true);

        uint256 price = _rewardTokenPrice();

        assertEq(price, 0);
    }

    /// @notice price < 1 -> price 0.
    function testTokenPriceZeroWhenPriceBelowOne() public {
        priceOracle.setPrice(0);

        uint256 price = _rewardTokenPrice();

        assertEq(price, 0);
    }

    /// @notice unit == USD_PRICE_UNIT (1e8) -> price returned unscaled.
    function testTokenPriceUnscaledWhenUnitIsUsdUnit() public {
        priceOracle.setUnit(1e8);
        priceOracle.setPrice(1234e8);

        uint256 price = _rewardTokenPrice();

        assertEq(price, 1234e8);
    }

    /// @notice unit != USD_PRICE_UNIT -> scaled via (p * USD_PRICE_UNIT) / unit.
    function testTokenPriceScaledWhenUnitNotUsdUnit() public {
        // 18-decimal base unit; price 2e18 -> (2e18 * 1e8) / 1e18 = 2e8.
        priceOracle.setUnit(1e18);
        priceOracle.setPrice(2e18);

        uint256 price = _rewardTokenPrice();

        assertEq(price, 2e8);
    }

    /// @notice A non-zero raw price that scales below one USD-price unit is unavailable, not resolved zero.
    function testTokenPriceUnresolvedWhenScalingTruncatesToZero() public {
        priceOracle.setUnit(1e18);
        priceOracle.setPrice(1);
        NeverlandUiProvider provider = _deployProvider();

        INeverlandUiProvider.PriceData memory prices = provider.getAllPrices();

        assertEq(prices.prices[1], 0);
        assertEq(prices.resolvedMask & (uint256(1) << 1), 0);
        assertEq(prices.lastUpdated[1], 0);
    }

    /*//////////////////////////////////////////////////////////////
                 LENDING POOL ASSET ENUMERATION
    //////////////////////////////////////////////////////////////*/

    /// @notice dataProvider == address(0) -> empty asset list -> empty emissions.
    function testEmissionBreakdownEmptyWhenDataProviderUnset() public {
        addrProvider.setPoolDataProvider(address(0));
        NeverlandUiProvider provider = _deployProvider();

        (INeverlandUiProvider.UserEmissionAsset[] memory breakdown, bool enumerationResolved) =
            provider.getUserEmissionBreakdown(user1, address(mockUSDC));

        assertEq(breakdown.length, 0);
        assertFalse(enumerationResolved, "unset pool data provider is an enumeration failure, not a real empty");
    }
}
