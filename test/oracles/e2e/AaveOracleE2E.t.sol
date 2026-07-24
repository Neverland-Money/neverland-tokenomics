// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IPriceOracleGetter} from "@aave/core-v3/contracts/interfaces/IPriceOracleGetter.sol";
import {AaveOracle} from "@aave/core-v3/contracts/misc/AaveOracle.sol";
import {PoolAddressesProvider} from "@aave/core-v3/contracts/protocol/configuration/PoolAddressesProvider.sol";
import {ACLManager} from "@aave/core-v3/contracts/protocol/configuration/ACLManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {MockERC20} from "../../_utils/MockERC20.sol";
import {RatioOracleAggregator} from "../../../src/oracles/RatioOracleAggregator.sol";
import {YieldBearingOracleAdapter} from "../../../src/oracles/YieldBearingOracleAdapter.sol";

contract MockAggregator is AggregatorV3Interface {
    int256 private _answer;
    uint8 private _decimals;
    uint256 private _timestamp;
    uint80 private _roundId;
    uint80 private _answeredInRound;
    bool private _useAnsweredInRoundOverride;

    constructor(int256 answer_, uint8 decimals_) {
        _answer = answer_;
        _decimals = decimals_;
        _timestamp = block.timestamp;
        _roundId = 1;
    }

    function setAnswer(int256 answer_) external {
        _answer = answer_;
        _roundId++;
        _timestamp = block.timestamp;
    }

    function setTimestamp(uint256 timestamp_) external {
        _timestamp = timestamp_;
    }

    function setAnsweredInRound(uint80 answeredInRound_) external {
        _answeredInRound = answeredInRound_;
        _useAnsweredInRoundOverride = true;
    }

    function clearAnsweredInRoundOverride() external {
        _useAnsweredInRoundOverride = false;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "Mock Aggregator";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 requestedRoundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint80 answeredIn = _useAnsweredInRoundOverride
            ? _answeredInRound
            : (requestedRoundId < _roundId ? requestedRoundId : _roundId);
        return (_roundId, _answer, _timestamp, _timestamp, answeredIn);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint80 answeredIn = _useAnsweredInRoundOverride ? _answeredInRound : _roundId;
        return (_roundId, _answer, _timestamp, _timestamp, answeredIn);
    }

    function latestAnswer() external view returns (int256) {
        return _answer;
    }

    function latestTimestamp() external view returns (uint256) {
        return _timestamp;
    }

    function latestRound() external view returns (uint256) {
        return _roundId;
    }

    function getAnswer(uint256) external view returns (int256) {
        return _answer;
    }

    function getTimestamp(uint256) external view returns (uint256) {
        return _timestamp;
    }
}

contract MockFallbackOracle is IPriceOracleGetter {
    address public immutable BASE_CURRENCY;
    uint256 public immutable BASE_CURRENCY_UNIT;
    mapping(address => uint256) private _prices;

    constructor(address baseCurrency, uint256 baseCurrencyUnit) {
        BASE_CURRENCY = baseCurrency;
        BASE_CURRENCY_UNIT = baseCurrencyUnit;
    }

    function setAssetPrice(address asset, uint256 price) external {
        _prices[asset] = price;
    }

    function getAssetPrice(address asset) external view returns (uint256) {
        return _prices[asset];
    }
}

contract MockERC4626 is IERC4626 {
    address private _asset;
    uint8 private _decimals;
    uint256 private _ratio;

    constructor(address asset_, uint8 decimals_) {
        _asset = asset_;
        _decimals = decimals_;
        _ratio = 1.05e18;
    }

    function setRatio(uint256 ratio_) external {
        _ratio = ratio_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        if (_ratio == 0) return 0;
        return (shares * _ratio) / 1e18;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        if (_ratio == 0) return 0;
        return (assets * 1e18) / _ratio;
    }

    function totalAssets() external pure returns (uint256) {
        return 1000e18;
    }

    function deposit(uint256, address) external pure returns (uint256) {
        return 0;
    }

    function mint(uint256, address) external pure returns (uint256) {
        return 0;
    }

    function withdraw(uint256, address, address) external pure returns (uint256) {
        return 0;
    }

    function redeem(uint256, address, address) external pure returns (uint256) {
        return 0;
    }

    function totalSupply() external pure returns (uint256) {
        return 1000e18;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 100e18;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxRedeem(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function previewDeposit(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function previewMint(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function previewWithdraw(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function previewRedeem(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function name() external pure returns (string memory) {
        return "Mock Shares";
    }

    function symbol() external pure returns (string memory) {
        return "mSHR";
    }
}

contract AaveOracleE2ETest is Test {
    address private constant BASE_CURRENCY = address(0);
    uint256 private constant BASE_CURRENCY_UNIT = 1e8;
    uint256 private constant PRICE_DECIMALS = 8;
    uint256 private constant RATIO_FEED_DECIMALS = 18;
    uint256 private constant BASE_FEED_DECIMALS = 8;
    uint256 private constant SHARE_DECIMALS = 18;

    PoolAddressesProvider private provider;
    ACLManager private aclManager;
    AaveOracle private aaveOracle;
    MockFallbackOracle private fallbackOracle;

    MockERC20 private ratioAsset;
    MockERC20 private noSourceAsset;

    MockAggregator private ratioAgg;
    MockAggregator private baseAgg;
    RatioOracleAggregator private ratioOracle;

    MockAggregator private yieldBaseAgg;
    MockERC20 private underlyingAsset;
    MockERC4626 private shares;
    YieldBearingOracleAdapter private yieldOracle;

    address private yieldAsset;

    function setUp() public {
        provider = new PoolAddressesProvider("TestMarket", address(this));
        provider.setACLAdmin(address(this));
        aclManager = new ACLManager(provider);
        provider.setACLManager(address(aclManager));
        aclManager.addAssetListingAdmin(address(this));

        fallbackOracle = new MockFallbackOracle(BASE_CURRENCY, BASE_CURRENCY_UNIT);
        aaveOracle = new AaveOracle(
            provider, new address[](0), new address[](0), address(fallbackOracle), BASE_CURRENCY, BASE_CURRENCY_UNIT
        );

        ratioAsset = new MockERC20("RatioAsset", "RAT", 18);
        noSourceAsset = new MockERC20("NoSourceAsset", "NOS", 18);

        ratioAgg = new MockAggregator(1.05e18, 18);
        baseAgg = new MockAggregator(2000e8, 8);
        ratioOracle = new RatioOracleAggregator(address(ratioAgg), address(baseAgg), 1 hours);

        yieldBaseAgg = new MockAggregator(2000e8, 8);
        underlyingAsset = new MockERC20("Underlying", "UND", 18);
        shares = new MockERC4626(address(underlyingAsset), 18);
        yieldOracle = new YieldBearingOracleAdapter(
            address(yieldBaseAgg), address(shares), 1 hours, 1 hours, 30 days, 0, "Yield"
        );
        yieldAsset = address(shares);

        fallbackOracle.setAssetPrice(address(ratioAsset), 1900e8);
        fallbackOracle.setAssetPrice(yieldAsset, 1800e8);
        fallbackOracle.setAssetPrice(address(noSourceAsset), 1700e8);

        address[] memory assets = new address[](2);
        assets[0] = address(ratioAsset);
        assets[1] = yieldAsset;

        address[] memory sources = new address[](2);
        sources[0] = address(ratioOracle);
        sources[1] = address(yieldOracle);

        aaveOracle.setAssetSources(assets, sources);
    }

    function testAaveOracleUsesSourcesWhenValid() public {
        uint256 ratioPrice = aaveOracle.getAssetPrice(address(ratioAsset));
        uint256 yieldPrice = aaveOracle.getAssetPrice(yieldAsset);

        emit log_named_string("scenario", "valid sources");
        emit log_named_string("expect", "AaveOracle uses source prices");
        emit log_named_decimal_int("ratio source latestAnswer", ratioOracle.latestAnswer(), PRICE_DECIMALS);
        emit log_named_decimal_int("yield source latestAnswer", yieldOracle.latestAnswer(), PRICE_DECIMALS);
        emit log_named_decimal_uint("aave ratio price", ratioPrice, PRICE_DECIMALS);
        emit log_named_decimal_uint("aave yield price", yieldPrice, PRICE_DECIMALS);

        assertEq(ratioPrice, 2100e8);
        assertEq(yieldPrice, 2100e8);
    }

    function testAaveOracleFallsBackWhenRatioOracleInvalid() public {
        ratioAgg.setAnswer(-1e18);
        uint256 price = aaveOracle.getAssetPrice(address(ratioAsset));
        uint256 fallbackPrice = fallbackOracle.getAssetPrice(address(ratioAsset));

        emit log_named_string("scenario", "ratio feed invalid");
        emit log_named_string("expect", "fallback price");
        emit log_named_decimal_int("ratio feed raw", ratioAgg.latestAnswer(), RATIO_FEED_DECIMALS);
        emit log_named_decimal_int("ratio source latestAnswer", ratioOracle.latestAnswer(), PRICE_DECIMALS);
        emit log_named_decimal_uint("aave price", price, PRICE_DECIMALS);
        emit log_named_decimal_uint("fallback price", fallbackPrice, PRICE_DECIMALS);

        assertEq(price, fallbackPrice);
    }

    function testAaveOracleFallsBackWhenRatioOracleZero() public {
        ratioAgg.setAnswer(0);
        uint256 price = aaveOracle.getAssetPrice(address(ratioAsset));
        uint256 fallbackPrice = fallbackOracle.getAssetPrice(address(ratioAsset));

        emit log_named_string("scenario", "ratio source returns 0");
        emit log_named_string("expect", "fallback price");
        emit log_named_decimal_int("ratio feed raw", ratioAgg.latestAnswer(), RATIO_FEED_DECIMALS);
        emit log_named_decimal_int("ratio source latestAnswer", ratioOracle.latestAnswer(), PRICE_DECIMALS);
        emit log_named_decimal_uint("aave price", price, PRICE_DECIMALS);
        emit log_named_decimal_uint("fallback price", fallbackPrice, PRICE_DECIMALS);

        assertEq(ratioOracle.latestAnswer(), 0);
        assertEq(price, fallbackPrice);
    }

    function testAaveOracleReturnsZeroWhenSourceAndFallbackZero() public {
        ratioAgg.setAnswer(0);
        fallbackOracle.setAssetPrice(address(ratioAsset), 0);

        uint256 price = aaveOracle.getAssetPrice(address(ratioAsset));

        emit log_named_string("scenario", "source and fallback both return 0");
        emit log_named_string("expect", "AaveOracle returns the fallback value as-is");
        emit log_named_decimal_int("ratio source latestAnswer", ratioOracle.latestAnswer(), PRICE_DECIMALS);
        emit log_named_decimal_uint("aave price", price, PRICE_DECIMALS);
        emit log_named_decimal_uint("fallback price", fallbackOracle.getAssetPrice(address(ratioAsset)), PRICE_DECIMALS);

        assertEq(ratioOracle.latestAnswer(), 0);
        assertEq(price, 0);
    }

    function testAaveOracleFallsBackWhenRatioBaseInvalid() public {
        baseAgg.setAnswer(-1000e8);
        uint256 price = aaveOracle.getAssetPrice(address(ratioAsset));
        uint256 fallbackPrice = fallbackOracle.getAssetPrice(address(ratioAsset));

        emit log_named_string("scenario", "ratio base feed invalid");
        emit log_named_string("expect", "fallback price");
        emit log_named_decimal_int("base feed raw", baseAgg.latestAnswer(), BASE_FEED_DECIMALS);
        emit log_named_decimal_int("ratio source latestAnswer", ratioOracle.latestAnswer(), PRICE_DECIMALS);
        emit log_named_decimal_uint("aave price", price, PRICE_DECIMALS);
        emit log_named_decimal_uint("fallback price", fallbackPrice, PRICE_DECIMALS);

        assertEq(price, fallbackPrice);
    }

    function testAaveOracleFallsBackWhenRatioFeedStale() public {
        vm.warp(3 hours);
        ratioAgg.setTimestamp(block.timestamp - 2 hours);
        baseAgg.setTimestamp(block.timestamp);

        uint256 price = aaveOracle.getAssetPrice(address(ratioAsset));
        uint256 fallbackPrice = fallbackOracle.getAssetPrice(address(ratioAsset));

        emit log_named_string("scenario", "ratio feed stale");
        emit log_named_string("expect", "fallback price");
        emit log_named_uint("ratio updatedAt", ratioAgg.latestTimestamp());
        emit log_named_uint("base updatedAt", baseAgg.latestTimestamp());
        emit log_named_uint("maxDelay", ratioOracle.maxDelay());
        emit log_named_decimal_int("ratio source latestAnswer", ratioOracle.latestAnswer(), PRICE_DECIMALS);
        emit log_named_decimal_uint("aave price", price, PRICE_DECIMALS);
        emit log_named_decimal_uint("fallback price", fallbackPrice, PRICE_DECIMALS);

        assertEq(price, fallbackPrice);
    }

    function testAaveOracleFallsBackWhenRatioOverflow() public {
        ratioAgg.setAnswer(int256(1) << 200);
        baseAgg.setAnswer(int256(1) << 200);

        uint256 price = aaveOracle.getAssetPrice(address(ratioAsset));
        uint256 fallbackPrice = fallbackOracle.getAssetPrice(address(ratioAsset));

        emit log_named_string("scenario", "ratio overflow");
        emit log_named_string("expect", "fallback price");
        emit log_named_string("inputs", "ratio/base set to 2^200");
        emit log_named_decimal_int("ratio source latestAnswer", ratioOracle.latestAnswer(), PRICE_DECIMALS);
        emit log_named_decimal_uint("aave price", price, PRICE_DECIMALS);
        emit log_named_decimal_uint("fallback price", fallbackPrice, PRICE_DECIMALS);

        assertEq(price, fallbackPrice);
    }

    function testAaveOracleFallsBackWhenYieldOracleInvalid() public {
        yieldBaseAgg.setAnswer(-1000e8);
        uint256 price = aaveOracle.getAssetPrice(yieldAsset);
        uint256 fallbackPrice = fallbackOracle.getAssetPrice(yieldAsset);

        emit log_named_string("scenario", "yield base feed invalid");
        emit log_named_string("expect", "fallback price");
        emit log_named_decimal_int("yield base feed raw", yieldBaseAgg.latestAnswer(), BASE_FEED_DECIMALS);
        emit log_named_decimal_int("yield source latestAnswer", yieldOracle.latestAnswer(), PRICE_DECIMALS);
        emit log_named_decimal_uint("aave price", price, PRICE_DECIMALS);
        emit log_named_decimal_uint("fallback price", fallbackPrice, PRICE_DECIMALS);

        assertEq(price, fallbackPrice);
    }

    function testAaveOracleFallsBackWhenYieldOracleZero() public {
        yieldBaseAgg.setAnswer(0);
        uint256 price = aaveOracle.getAssetPrice(yieldAsset);
        uint256 fallbackPrice = fallbackOracle.getAssetPrice(yieldAsset);

        emit log_named_string("scenario", "yield source returns 0");
        emit log_named_string("expect", "fallback price");
        emit log_named_decimal_int("yield base feed raw", yieldBaseAgg.latestAnswer(), BASE_FEED_DECIMALS);
        emit log_named_decimal_int("yield source latestAnswer", yieldOracle.latestAnswer(), PRICE_DECIMALS);
        emit log_named_decimal_uint("aave price", price, PRICE_DECIMALS);
        emit log_named_decimal_uint("fallback price", fallbackPrice, PRICE_DECIMALS);

        assertEq(yieldOracle.latestAnswer(), 0);
        assertEq(price, fallbackPrice);
    }

    function testAaveOracleFallsBackWhenYieldCapped() public {
        vm.warp(40 days);
        yieldBaseAgg.setTimestamp(block.timestamp);
        yieldOracle.setGrowthCapBounds(100);
        shares.setRatio(1e18);
        yieldOracle.updateSnapshot();
        vm.warp(block.timestamp + 3600);
        yieldBaseAgg.setTimestamp(block.timestamp);
        vm.warp(block.timestamp + 7 days);
        yieldBaseAgg.setTimestamp(block.timestamp);
        shares.setRatio(10e18);

        uint256 price = aaveOracle.getAssetPrice(yieldAsset);
        int256 sourceAnswer = yieldOracle.latestAnswer();
        uint256 uncappedPrice = (2000e8 * 10e18) / 1e18;
        uint256 fallbackPrice = fallbackOracle.getAssetPrice(yieldAsset);

        emit log_named_string("scenario", "yield growth cap clamps");
        emit log_named_string("expect", "fallback price");
        emit log_named_uint("maxAnnualGrowthBps", yieldOracle.getMaxAnnualGrowthBps());
        emit log_named_decimal_uint("convertToAssets(1e18)", shares.convertToAssets(1e18), SHARE_DECIMALS);
        emit log_named_decimal_uint("uncapped price", uncappedPrice, PRICE_DECIMALS);
        emit log_named_decimal_int("yield source latestAnswer", sourceAnswer, PRICE_DECIMALS);
        emit log_named_decimal_uint("aave price", price, PRICE_DECIMALS);
        emit log_named_decimal_uint("fallback price", fallbackPrice, PRICE_DECIMALS);

        assertEq(sourceAnswer, 0);
        assertEq(price, fallbackPrice);
        assertLt(price, uncappedPrice);
    }

    function testAaveOracleFallsBackWhenYieldSharesZero() public {
        shares.setRatio(0);
        uint256 price = aaveOracle.getAssetPrice(yieldAsset);
        uint256 fallbackPrice = fallbackOracle.getAssetPrice(yieldAsset);

        emit log_named_string("scenario", "yield shares conversion = 0");
        emit log_named_string("expect", "fallback price");
        emit log_named_decimal_uint("convertToAssets(1e18)", shares.convertToAssets(1e18), SHARE_DECIMALS);
        emit log_named_decimal_int("yield source latestAnswer", yieldOracle.latestAnswer(), PRICE_DECIMALS);
        emit log_named_decimal_uint("aave price", price, PRICE_DECIMALS);
        emit log_named_decimal_uint("fallback price", fallbackPrice, PRICE_DECIMALS);

        assertEq(price, fallbackPrice);
    }

    function testAaveOracleFallsBackWhenYieldBaseStale() public {
        vm.warp(3 hours);
        yieldBaseAgg.setTimestamp(block.timestamp - 2 hours);

        uint256 price = aaveOracle.getAssetPrice(yieldAsset);
        uint256 fallbackPrice = fallbackOracle.getAssetPrice(yieldAsset);

        emit log_named_string("scenario", "yield base feed stale");
        emit log_named_string("expect", "fallback price");
        emit log_named_uint("yield updatedAt", yieldBaseAgg.latestTimestamp());
        emit log_named_uint("maxDelay", yieldOracle.maxDelay());
        emit log_named_decimal_int("yield source latestAnswer", yieldOracle.latestAnswer(), PRICE_DECIMALS);
        emit log_named_decimal_uint("aave price", price, PRICE_DECIMALS);
        emit log_named_decimal_uint("fallback price", fallbackPrice, PRICE_DECIMALS);

        assertEq(price, fallbackPrice);
    }

    function testAaveOracleRevertsWhenFallbackMissing() public {
        ratioAgg.setAnswer(-1e18);

        address[] memory assets = new address[](1);
        assets[0] = address(ratioAsset);

        address[] memory sources = new address[](1);
        sources[0] = address(ratioOracle);

        AaveOracle oracleNoFallback =
            new AaveOracle(provider, assets, sources, address(0), BASE_CURRENCY, BASE_CURRENCY_UNIT);

        emit log_named_string("scenario", "primary invalid + fallback missing");
        emit log_named_string("expect", "revert");
        emit log_named_address("fallback oracle", address(0));
        emit log_named_decimal_int("ratio feed raw", ratioAgg.latestAnswer(), RATIO_FEED_DECIMALS);
        emit log_named_decimal_int("ratio source latestAnswer", ratioOracle.latestAnswer(), PRICE_DECIMALS);

        vm.expectRevert();
        oracleNoFallback.getAssetPrice(address(ratioAsset));
    }

    function testAaveOracleRevertsWhenRatioZeroAndFallbackMissing() public {
        ratioAgg.setAnswer(0);

        address[] memory assets = new address[](1);
        assets[0] = address(ratioAsset);

        address[] memory sources = new address[](1);
        sources[0] = address(ratioOracle);

        AaveOracle oracleNoFallback =
            new AaveOracle(provider, assets, sources, address(0), BASE_CURRENCY, BASE_CURRENCY_UNIT);

        emit log_named_string("scenario", "primary = 0 + fallback missing");
        emit log_named_string("expect", "revert");
        emit log_named_address("fallback oracle", address(0));
        emit log_named_decimal_int("ratio source latestAnswer", ratioOracle.latestAnswer(), PRICE_DECIMALS);

        vm.expectRevert();
        oracleNoFallback.getAssetPrice(address(ratioAsset));
    }

    function testAaveOracleRevertsWhenRatioNoReportAndFallbackMissing() public {
        baseAgg.setTimestamp(0);

        address[] memory assets = new address[](1);
        assets[0] = address(ratioAsset);

        address[] memory sources = new address[](1);
        sources[0] = address(ratioOracle);

        AaveOracle oracleNoFallback =
            new AaveOracle(provider, assets, sources, address(0), BASE_CURRENCY, BASE_CURRENCY_UNIT);

        emit log_named_string("scenario", "ratio base no report + fallback missing");
        emit log_named_string("expect", "revert");
        emit log_named_address("fallback oracle", address(0));
        emit log_named_uint("base updatedAt", baseAgg.latestTimestamp());
        emit log_named_decimal_int("ratio source latestAnswer", ratioOracle.latestAnswer(), PRICE_DECIMALS);

        vm.expectRevert();
        oracleNoFallback.getAssetPrice(address(ratioAsset));
    }

    function testAaveOracleFallsBackWhenSourceMissing() public {
        uint256 price = aaveOracle.getAssetPrice(address(noSourceAsset));
        uint256 fallbackPrice = fallbackOracle.getAssetPrice(address(noSourceAsset));

        emit log_named_string("scenario", "source missing");
        emit log_named_string("expect", "fallback price");
        emit log_named_address("source oracle", aaveOracle.getSourceOfAsset(address(noSourceAsset)));
        emit log_named_decimal_uint("aave price", price, PRICE_DECIMALS);
        emit log_named_decimal_uint("fallback price", fallbackPrice, PRICE_DECIMALS);

        assertEq(price, fallbackPrice);
    }

    function testAaveOracleGetAssetsPrices() public {
        address[] memory assets = new address[](3);
        assets[0] = address(ratioAsset);
        assets[1] = yieldAsset;
        assets[2] = address(noSourceAsset);

        uint256[] memory prices = aaveOracle.getAssetsPrices(assets);
        emit log_named_string("scenario", "batch prices");
        emit log_named_string("expect", "ratio/yield from source, missing from fallback");
        emit log_named_decimal_uint("ratio price", prices[0], PRICE_DECIMALS);
        emit log_named_decimal_uint("yield price", prices[1], PRICE_DECIMALS);
        emit log_named_decimal_uint("missing source price", prices[2], PRICE_DECIMALS);

        assertEq(prices.length, 3);
        assertEq(prices[0], 2100e8);
        assertEq(prices[1], 2100e8);
        assertEq(prices[2], fallbackOracle.getAssetPrice(address(noSourceAsset)));
    }

    function testAaveOracleBaseCurrencyUnit() public {
        uint256 price = aaveOracle.getAssetPrice(BASE_CURRENCY);
        emit log_named_string("scenario", "base currency");
        emit log_named_string("expect", "BASE_CURRENCY_UNIT");
        emit log_named_decimal_uint("base currency price", price, PRICE_DECIMALS);
        assertEq(price, BASE_CURRENCY_UNIT);
    }
}
