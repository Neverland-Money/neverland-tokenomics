// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {INeverlandDustHelper} from "../../../src/interfaces/INeverlandDustHelper.sol";
import {IReClammPool} from "../../../src/interfaces/IReClammPool.sol";
import {NeverlandDustHelper} from "../../../src/utils/NeverlandDustHelper.sol";

import {Test} from "forge-std/Test.sol";

contract CoverageERC20 is ERC20 {
    uint8 internal immutable tokenDecimals;
    bool internal immutable shouldRevertDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, bool shouldRevertDecimals_)
        ERC20(name_, symbol_)
    {
        tokenDecimals = decimals_;
        shouldRevertDecimals = shouldRevertDecimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        if (shouldRevertDecimals) revert("decimals");
        return tokenDecimals;
    }
}

contract CoverageOracle {
    int256 internal answer;
    uint8 internal oracleDecimals;
    address internal oracleToken0;
    address internal oracleToken1;
    bool internal revertLatest;
    bool internal revertDecimals;
    bool internal revertToken0;
    bool internal revertToken1;
    uint256 internal startedAt = 111;
    uint256 internal updatedAt = 222;

    constructor(int256 answer_, uint8 decimals_, address token0_, address token1_) {
        answer = answer_;
        oracleDecimals = decimals_;
        oracleToken0 = token0_;
        oracleToken1 = token1_;
    }

    function setAnswer(int256 value) external {
        answer = value;
    }

    function setTimestamps(uint256 startedAt_, uint256 updatedAt_) external {
        startedAt = startedAt_;
        updatedAt = updatedAt_;
    }

    function setReverts(bool latest, bool decimals_, bool token0_, bool token1_) external {
        revertLatest = latest;
        revertDecimals = decimals_;
        revertToken0 = token0_;
        revertToken1 = token1_;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer_, uint256 startedAt_, uint256 updatedAt_, uint80 answeredInRound)
    {
        if (revertLatest) revert("latest");
        return (1, answer, startedAt, updatedAt, 1);
    }

    function decimals() external view returns (uint8) {
        if (revertDecimals) revert("decimals");
        return oracleDecimals;
    }

    function token0() external view returns (address) {
        if (revertToken0) revert("token0");
        return oracleToken0;
    }

    function token1() external view returns (address) {
        if (revertToken1) revert("token1");
        return oracleToken1;
    }
}

contract CoverageV2Pool {
    uint112 internal reserve0;
    uint112 internal reserve1;
    address internal poolToken0;
    address internal poolToken1;
    bool internal revertReserves;

    constructor(uint112 reserve0_, uint112 reserve1_, address token0_, address token1_) {
        reserve0 = reserve0_;
        reserve1 = reserve1_;
        poolToken0 = token0_;
        poolToken1 = token1_;
    }

    function setReserves(uint112 reserve0_, uint112 reserve1_) external {
        reserve0 = reserve0_;
        reserve1 = reserve1_;
    }

    function setRevertReserves(bool value) external {
        revertReserves = value;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        if (revertReserves) revert("reserves");
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function token0() external view returns (address) {
        return poolToken0;
    }

    function token1() external view returns (address) {
        return poolToken1;
    }
}

contract CoverageV3Pool {
    uint160 internal sqrtPriceX96;
    address internal poolToken0;
    address internal poolToken1;
    bool internal revertSlot0;

    constructor(uint160 sqrtPriceX96_, address token0_, address token1_) {
        sqrtPriceX96 = sqrtPriceX96_;
        poolToken0 = token0_;
        poolToken1 = token1_;
    }

    function setSqrtPrice(uint160 value) external {
        sqrtPriceX96 = value;
    }

    function setRevertSlot0(bool value) external {
        revertSlot0 = value;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        if (revertSlot0) revert("slot0");
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function token0() external view returns (address) {
        return poolToken0;
    }

    function token1() external view returns (address) {
        return poolToken1;
    }
}

contract CoverageBrokenPair {
    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        revert("slot0");
    }

    function getReserves() external pure returns (uint112, uint112, uint32) {
        revert("reserves");
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert("latest");
    }
}

contract CoverageFallbackOnlyPair {
    fallback() external {}
}

contract CoverageShortToken1Pair {
    address internal immutable poolToken0;

    constructor(address token0_) {
        poolToken0 = token0_;
    }

    function token0() external view returns (address) {
        return poolToken0;
    }

    fallback() external {}
}

contract CoverageShortTokensV2Pool {
    function getReserves() external pure returns (uint112, uint112, uint32) {
        return (1 ether, 1 ether, 1);
    }

    fallback() external {}
}

contract CoverageShortToken1V2Pool {
    address internal immutable poolToken0;

    constructor(address token0_) {
        poolToken0 = token0_;
    }

    function getReserves() external pure returns (uint112, uint112, uint32) {
        return (1 ether, 1 ether, 1);
    }

    function token0() external view returns (address) {
        return poolToken0;
    }

    fallback() external {}
}

contract CoverageV4PoolManager {
    mapping(bytes32 => bytes32) internal slots;

    function setSlot0(bytes32 poolId, uint160 sqrtPriceX96) external {
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, bytes32(uint256(6))));
        slots[stateSlot] = bytes32(uint256(sqrtPriceX96));
    }

    function extsload(bytes32 slot) external view returns (bytes32 value) {
        return slots[slot];
    }
}

contract CoverageReClammPool {
    IReClammPool.ReClammPoolDynamicData internal data;
    bool internal shouldRevert;

    function setData(uint256 dustBalance, uint256 pairedBalance, bool initialized, bool dustToken0) external {
        data.balancesLiveScaled18 = new uint256[](2);
        data.lastVirtualBalances = new uint256[](2);
        if (dustToken0) {
            data.balancesLiveScaled18[0] = dustBalance;
            data.balancesLiveScaled18[1] = pairedBalance;
        } else {
            data.balancesLiveScaled18[0] = pairedBalance;
            data.balancesLiveScaled18[1] = dustBalance;
        }
        data.isPoolInitialized = initialized;
    }

    function setShortArrays() external {
        data.balancesLiveScaled18 = new uint256[](1);
        data.lastVirtualBalances = new uint256[](1);
        data.isPoolInitialized = true;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function getReClammPoolDynamicData() external view returns (IReClammPool.ReClammPoolDynamicData memory) {
        if (shouldRevert) revert("reclamm");
        return data;
    }

    function getReClammPoolImmutableData() external pure returns (IReClammPool.ReClammPoolImmutableData memory) {}
}

contract NeverlandDustHelperHarness is NeverlandDustHelper {
    constructor(address dustToken, address initialOwner) NeverlandDustHelper(dustToken, initialOwner) {}

    function exposedGetOraclePrice() external view returns (uint256, bool) {
        return _getOraclePrice();
    }

    function exposedGetDustPairPrice() external view returns (uint256, bool) {
        return _getDustPairPrice();
    }

    function exposedGetReclammPrice() external view returns (uint256, bool) {
        return _getReclammPrice();
    }

    function exposedScalePriceTo18(uint256 rawPrice, uint8 decimalsValue) external pure returns (uint256, bool) {
        return _scalePriceTo18(rawPrice, decimalsValue);
    }

    function exposedGetPriceFromSqrtPriceX96(uint160 sqrtPriceX96, uint8 decimals0, uint8 decimals1)
        external
        pure
        returns (uint256)
    {
        return _getPriceFromSqrtPriceX96(sqrtPriceX96, decimals0, decimals1);
    }

    function exposedGetUniswapV4Price() external view returns (uint256, bool) {
        return _getUniswapV4Price();
    }

    function exposedGetUniswapV3PriceFromSqrtPriceX96(uint160 sqrtPriceX96) external view returns (uint256, bool) {
        return _getUniswapV3PriceFromSqrtPriceX96(sqrtPriceX96);
    }

    function exposedGetUniswapV2Price() external view returns (uint256, bool) {
        return _getUniswapV2Price();
    }

    function exposedGetChainlinkPrice() external view returns (uint256, bool) {
        return _getChainlinkPrice();
    }

    function exposedGetDustUsdPrice() external view returns (uint256, bool) {
        return _getDustUsdPrice();
    }

    function exposedGetPairUsdPrice() external view returns (uint256, bool) {
        return _getPairUsdPrice();
    }
}

contract NeverlandDustHelperCoverageTest is Test {
    uint256 internal constant CURRENT_ROUND_ID_SLOT = 13;

    CoverageERC20 internal dust;
    NeverlandDustHelperHarness internal helper;

    function setUp() public {
        dust = new CoverageERC20("DUST", "DUST", 18, false);
        helper = new NeverlandDustHelperHarness(address(dust), address(this));
    }

    function testTeamSupplyAndMarketViews() public {
        address team1 = makeAddr("team1");
        address team2 = makeAddr("team2");
        dust.mint(address(this), 1000 ether);
        dust.mint(team1, 100 ether);
        dust.mint(team2, 200 ether);

        helper.addTeamAddress(team1);
        assertTrue(helper.isTeamAddress(team1));
        assertEq(helper.getTeamAddressCount(), 1);

        vm.expectRevert(abi.encodeWithSelector(INeverlandDustHelper.TeamAddressAlreadyExists.selector, team1));
        helper.addTeamAddress(team1);

        address[] memory batch = new address[](1);
        batch[0] = team2;
        helper.addTeamAddresses(batch);
        assertEq(helper.getTeamAddresses().length, 2);

        assertEq(helper.getTotalSupply(), 1300 ether);
        assertEq(helper.getTeamTotalBalance(), 300 ether);
        assertEq(helper.getCirculatingSupply(), 1000 ether);

        INeverlandDustHelper.MarketData memory data = helper.getMarketData();
        assertEq(data.totalSupply, 1300 ether);
        assertEq(data.circulatingSupply, 1000 ether);
        assertEq(data.usdPrice, helper.DEFAULT_DUST_PRICE());

        (uint256 circulating, uint256 total, uint256 price, uint256 marketCap) = helper.getMarketMetrics();
        assertEq(circulating, 1000 ether);
        assertEq(total, 1300 ether);
        assertEq(price, helper.DEFAULT_DUST_PRICE());
        assertEq(marketCap, (1000 ether * helper.DEFAULT_DUST_PRICE()) / 1e18);

        assertEq(helper.getDustValueInUSD(4 ether), 100_000_000);
        assertEq(helper.getUSDValueInDust(100_000_000), 4 ether);
        assertFalse(helper.isPriceCacheStale());
    }

    function testPriceInfoAndAggregatorCompatibilityViews() public {
        skip(helper.priceUpdateInterval() + 1);
        assertTrue(helper.isPriceCacheStale());
        (uint256 infoPrice, bool fromOracle, uint256 lastUpdate, bool stale) = helper.getPriceInfo();
        assertEq(infoPrice, helper.DEFAULT_DUST_PRICE());
        assertFalse(fromOracle);
        assertGt(lastUpdate, 0);
        assertTrue(stale);

        helper.updatePriceCache();
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = helper.getRoundData(1);
        assertEq(roundId, 1);
        assertEq(uint256(answer), helper.DEFAULT_DUST_PRICE());
        assertGt(updatedAt, 0);
        assertEq(answeredInRound, 1);
        assertEq(helper.getAnswer(1), int256(helper.DEFAULT_DUST_PRICE()));
        assertGt(helper.getTimestamp(1), 0);
        assertEq(helper.decimals(), 8);
        assertEq(helper.description(), "DUST / USD");
        assertEq(helper.version(), 13);

        vm.expectRevert(INeverlandDustHelper.NoDataPresent.selector);
        helper.getRoundData(99);
        vm.expectRevert(INeverlandDustHelper.NoDataPresent.selector);
        helper.getAnswer(99);
        vm.expectRevert(INeverlandDustHelper.NoDataPresent.selector);
        helper.getTimestamp(99);

        NeverlandDustHelperHarness zeroPriceHelper = new NeverlandDustHelperHarness(address(dust), address(this));
        skip(zeroPriceHelper.priceUpdateInterval() + 1);
        zeroPriceHelper.setPair(address(new CoverageBrokenPair()));
        assertEq(zeroPriceHelper.getUSDValueInDust(100_000_000), 0);

        vm.store(address(zeroPriceHelper), bytes32(CURRENT_ROUND_ID_SLOT), bytes32(0));
        vm.expectRevert(INeverlandDustHelper.NoRoundsRecorded.selector);
        zeroPriceHelper.latestRoundData();
        vm.expectRevert(INeverlandDustHelper.NoRoundsRecorded.selector);
        zeroPriceHelper.latestAnswer();
        vm.expectRevert(INeverlandDustHelper.NoRoundsRecorded.selector);
        zeroPriceHelper.latestTimestamp();
        vm.expectRevert(INeverlandDustHelper.NoRoundsRecorded.selector);
        zeroPriceHelper.latestRound();
    }

    function testTeamRemovalAndValidationReverts() public {
        address team1 = makeAddr("team1");
        address team2 = makeAddr("team2");
        helper.addTeamAddress(team1);

        address[] memory batch = new address[](1);
        batch[0] = team2;
        helper.addTeamAddresses(batch);

        helper.removeTeamAddress(team2);
        assertFalse(helper.isTeamAddress(team2));
        vm.expectRevert(abi.encodeWithSelector(INeverlandDustHelper.TeamAddressNotFound.selector, team2));
        helper.removeTeamAddress(team2);

        helper.addTeamAddress(team2);

        address[] memory duplicateBatch = new address[](1);
        duplicateBatch[0] = team2;
        vm.expectRevert(abi.encodeWithSelector(INeverlandDustHelper.TeamAddressAlreadyExists.selector, team2));
        helper.addTeamAddresses(duplicateBatch);

        helper.removeTeamAddresses(batch);
        vm.expectRevert(abi.encodeWithSelector(INeverlandDustHelper.TeamAddressNotFound.selector, team2));
        helper.removeTeamAddresses(batch);

        vm.expectRevert(INeverlandDustHelper.EmptyArray.selector);
        helper.addTeamAddresses(new address[](0));
        vm.expectRevert(INeverlandDustHelper.EmptyArray.selector);
        helper.removeTeamAddresses(new address[](0));

        vm.expectRevert();
        helper.addTeamAddress(address(0));
        vm.expectRevert();
        helper.renounceOwnership();
    }

    function testTeamAddressLimitAndBatchValidation() public {
        address[] memory tooMany = new address[](helper.MAX_TEAM_ADDRESSES() + 1);
        for (uint256 i; i < tooMany.length; ++i) {
            tooMany[i] = address(uint160(1000 + i));
        }
        vm.expectRevert(INeverlandDustHelper.TooManyTeamAddresses.selector);
        helper.addTeamAddresses(tooMany);

        for (uint256 i; i < helper.MAX_TEAM_ADDRESSES(); ++i) {
            helper.addTeamAddress(address(uint160(2000 + i)));
        }
        vm.expectRevert(INeverlandDustHelper.TooManyTeamAddresses.selector);
        helper.addTeamAddress(address(uint160(9999)));
    }

    function testPriceAdminAndCacheBranches() public {
        vm.expectRevert(abi.encodeWithSelector(INeverlandDustHelper.InvalidPrice.selector, 1));
        helper.updateHardcodedPrice(1);

        helper.setPriceLimits(50_000_000, 100_000_000);
        vm.expectRevert(abi.encodeWithSelector(INeverlandDustHelper.InvalidPrice.selector, helper.DEFAULT_DUST_PRICE()));
        helper.updatePriceCache();
        helper.setPriceLimits(1, 1e12);

        helper.updateHardcodedPrice(50_000_000);
        (uint256 price, bool fromOracle) = helper.getPrice();
        assertEq(price, 50_000_000);
        assertFalse(fromOracle);

        vm.expectRevert(abi.encodeWithSelector(INeverlandDustHelper.InvalidPriceUpdateInterval.selector, 59));
        helper.setPriceUpdateInterval(59);
        vm.expectRevert(abi.encodeWithSelector(INeverlandDustHelper.InvalidPriceUpdateInterval.selector, 24 hours + 1));
        helper.setPriceUpdateInterval(24 hours + 1);
        helper.setPriceUpdateInterval(2 hours);
        assertEq(helper.priceUpdateInterval(), 2 hours);

        vm.expectRevert(abi.encodeWithSelector(INeverlandDustHelper.InvalidPriceLimits.selector, 0, 1));
        helper.setPriceLimits(0, 1);
        vm.expectRevert(abi.encodeWithSelector(INeverlandDustHelper.InvalidPriceLimits.selector, 2, 2));
        helper.setPriceLimits(2, 2);
        helper.setPriceLimits(1, 1e12);

        CoverageOracle direct = new CoverageOracle(25_000_000, 8, address(dust), makeAddr("usd"));
        helper.setPair(address(direct));
        assertEq(helper.pair(), address(direct));
        helper.updateHardcodedPrice(60_000_000);
        assertEq(helper.hardcodedPrice(), 60_000_000);

        helper.removePair();
        assertEq(helper.pair(), address(0));

        CoverageOracle pairOracle = new CoverageOracle(100_000_000, 8, makeAddr("usd"), address(0));
        helper.setPairOracle(address(pairOracle));
        assertEq(helper.pairOracle(), address(pairOracle));
        helper.removePairOracle();
        assertEq(helper.pairOracle(), address(0));

        CoverageERC20 pairedToken = new CoverageERC20("PAIR", "PAIR", 18, false);
        CoverageV2Pool pair = new CoverageV2Pool(1 ether, 4 ether, address(dust), address(pairedToken));
        CoverageOracle pairUsd = new CoverageOracle(100_000_000, 8, makeAddr("usd"), address(0));
        helper.setPair(address(pair));
        helper.setPairOracle(address(pairUsd));
        pairUsd.setTimestamps(500, 600);
        helper.updatePriceCache();
        pairUsd.setAnswer(125_000_000);
        pairUsd.setTimestamps(400, 500);
        helper.updatePriceCache();
        (, int256 answer, uint256 startedAt, uint256 updatedAt,) = helper.latestRoundData();
        assertEq(uint256(answer), 500_000_000);
        assertEq(startedAt, 500);
        assertEq(updatedAt, 600);
    }

    function testV4AndReclammAdminAndPriceBranches() public {
        CoverageERC20 paired = new CoverageERC20("PAIR", "PAIR", 18, false);
        bytes32 poolId = keccak256("pool");
        CoverageV4PoolManager manager = new CoverageV4PoolManager();
        manager.setSlot0(poolId, 158456325028528675187087900672);

        vm.expectRevert();
        helper.setV4Pool(address(0), poolId, true, address(paired));
        vm.expectRevert();
        helper.setV4Pool(address(manager), bytes32(0), true, address(paired));
        vm.expectRevert(INeverlandDustHelper.InvalidV4PoolConfig.selector);
        helper.setV4Pool(address(manager), poolId, true, address(dust));

        helper.setV4Pool(address(manager), poolId, true, address(paired));
        (uint256 price, bool success) = helper.exposedGetUniswapV4Price();
        assertEq(price, 250000000000000000);
        assertTrue(success);

        helper.removeV4Pool();
        (price, success) = helper.exposedGetUniswapV4Price();
        assertEq(price, 0);
        assertFalse(success);

        helper.setV4Pool(address(manager), poolId, false, address(paired));
        (price, success) = helper.exposedGetUniswapV4Price();
        assertEq(price, 4 ether);
        assertTrue(success);
        helper.removeV4Pool();

        helper.setV4Pool(makeAddr("emptyManager"), poolId, true, address(paired));
        (price, success) = helper.exposedGetUniswapV4Price();
        assertEq(price, 0);
        assertFalse(success);
        helper.removeV4Pool();

        bytes32 zeroPoolId = keccak256("zeroPool");
        manager.setSlot0(zeroPoolId, 0);
        helper.setV4Pool(address(manager), zeroPoolId, true, address(paired));
        (price, success) = helper.exposedGetUniswapV4Price();
        assertEq(price, 0);
        assertFalse(success);
        helper.removeV4Pool();

        CoverageERC20 paired0 = new CoverageERC20("PAIR0", "P0", 0, false);
        manager.setSlot0(poolId, 1);
        helper.setV4Pool(address(manager), poolId, false, address(paired0));
        (price, success) = helper.exposedGetUniswapV4Price();
        assertEq(price, 0);
        assertFalse(success);
        helper.removeV4Pool();

        manager.setSlot0(poolId, type(uint160).max);
        helper.setV4Pool(address(manager), poolId, true, address(paired));
        (price, success) = helper.exposedGetUniswapV4Price();
        assertEq(price, 0);
        assertFalse(success);
        helper.removeV4Pool();

        CoverageERC20 revertingDecimals = new CoverageERC20("REV", "REV", 18, true);
        helper.setV4Pool(address(manager), poolId, true, address(revertingDecimals));
        (price, success) = helper.exposedGetUniswapV4Price();
        assertEq(price, 0);
        assertFalse(success);
        helper.removeV4Pool();

        CoverageReClammPool reclamm = new CoverageReClammPool();
        helper.setReclammPool(address(reclamm), true);
        reclamm.setShortArrays();
        (price, success) = helper.exposedGetReclammPrice();
        assertEq(price, 0);
        assertFalse(success);

        reclamm.setData(0, 1 ether, true, true);
        (price, success) = helper.exposedGetReclammPrice();
        assertEq(price, 0);
        assertFalse(success);

        reclamm.setData(2 ether, 1 ether, true, true);
        (price, success) = helper.exposedGetReclammPrice();
        assertEq(price, 2 ether);
        assertTrue(success);

        (price, success) = helper.exposedGetDustPairPrice();
        assertEq(price, 2 ether);
        assertTrue(success);

        reclamm.setData(4 ether, 1 ether, true, true);
        (price, success) = helper.exposedGetOraclePrice();
        assertEq(price, 25_000_000);
        assertTrue(success);

        helper.setPair(address(new CoverageBrokenPair()));
        reclamm.setData(0, 1 ether, true, true);
        (price, success) = helper.exposedGetOraclePrice();
        assertEq(price, 0);
        assertFalse(success);

        helper.setReclammPool(address(reclamm), false);
        reclamm.setData(3 ether, 1 ether, true, false);
        (price, success) = helper.exposedGetReclammPrice();
        assertEq(price, 3 ether);
        assertTrue(success);

        reclamm.setData(1 ether, 1 ether, false, false);
        (price, success) = helper.exposedGetReclammPrice();
        assertEq(price, 0);
        assertFalse(success);

        reclamm.setShouldRevert(true);
        (price, success) = helper.exposedGetReclammPrice();
        assertEq(price, 0);
        assertFalse(success);

        helper.removeReclammPool();
        (price, success) = helper.exposedGetReclammPrice();
        assertEq(price, 0);
        assertFalse(success);
    }

    function testInternalScalingBranches() public view {
        (uint256 scaled, bool ok) = helper.exposedScalePriceTo18(2, 18);
        assertEq(scaled, 2);
        assertTrue(ok);

        (scaled, ok) = helper.exposedScalePriceTo18(2, 6);
        assertEq(scaled, 2e12);
        assertTrue(ok);

        (scaled, ok) = helper.exposedScalePriceTo18(2e20, 20);
        assertEq(scaled, 2e18);
        assertTrue(ok);

        (scaled, ok) = helper.exposedScalePriceTo18(1, 25);
        assertEq(scaled, 0);
        assertFalse(ok);

        (scaled, ok) = helper.exposedScalePriceTo18(type(uint256).max, 0);
        assertEq(scaled, 0);
        assertFalse(ok);

        assertEq(helper.exposedGetPriceFromSqrtPriceX96(0, 18, 18), 0);
        assertEq(helper.exposedGetPriceFromSqrtPriceX96(158456325028528675187087900672, 6, 18), 4_000_000);
        assertEq(helper.exposedGetPriceFromSqrtPriceX96(type(uint160).max, 25, 0), 0);
    }

    function testMalformedV3Branches() public {
        CoverageERC20 paired = new CoverageERC20("PAIR", "PAIR", 18, false);
        CoverageV3Pool validV3 = new CoverageV3Pool(1, address(dust), address(paired));
        helper.setPair(address(validV3));
        (uint256 price, bool success) = helper.exposedGetUniswapV3PriceFromSqrtPriceX96(0);
        assertEq(price, 0);
        assertFalse(success);

        CoverageERC20 badDecimals = new CoverageERC20("BAD", "BAD", 25, false);
        CoverageV3Pool v3 = new CoverageV3Pool(158456325028528675187087900672, address(dust), address(badDecimals));
        helper.setPair(address(v3));
        (price, success) = helper.exposedGetUniswapV3PriceFromSqrtPriceX96(158456325028528675187087900672);
        assertEq(price, 0);
        assertFalse(success);

        helper.setPair(address(new CoverageFallbackOnlyPair()));
        (price, success) = helper.exposedGetUniswapV3PriceFromSqrtPriceX96(158456325028528675187087900672);
        assertEq(price, 0);
        assertFalse(success);

        helper.setPair(address(new CoverageShortToken1Pair(address(dust))));
        (price, success) = helper.exposedGetUniswapV3PriceFromSqrtPriceX96(158456325028528675187087900672);
        assertEq(price, 0);
        assertFalse(success);

        CoverageERC20 tinyDecimals = new CoverageERC20("TINY", "TINY", 0, false);
        CoverageV3Pool v3ZeroPrice = new CoverageV3Pool(1, address(tinyDecimals), address(dust));
        helper.setPair(address(v3ZeroPrice));
        (price, success) = helper.exposedGetUniswapV3PriceFromSqrtPriceX96(1);
        assertEq(price, 0);
        assertFalse(success);
    }

    function testMalformedV2Branches() public {
        CoverageERC20 badDecimals = new CoverageERC20("BAD", "BAD", 25, false);
        CoverageV2Pool zeroReserve = new CoverageV2Pool(0, 1, address(dust), address(badDecimals));
        helper.setPair(address(zeroReserve));
        (uint256 price, bool success) = helper.exposedGetUniswapV2Price();
        assertEq(price, 0);
        assertFalse(success);

        helper.setPair(address(new CoverageShortTokensV2Pool()));
        (price, success) = helper.exposedGetUniswapV2Price();
        assertEq(price, 0);
        assertFalse(success);

        helper.setPair(address(new CoverageShortToken1V2Pool(address(dust))));
        (price, success) = helper.exposedGetUniswapV2Price();
        assertEq(price, 0);
        assertFalse(success);
    }

    function testValidV2DecimalBranchesAndFallbackSourceBranches() public {
        CoverageERC20 otherToken = new CoverageERC20("OTHER", "OTHER", 18, false);
        CoverageERC20 badDecimals = new CoverageERC20("BAD", "BAD", 25, false);
        CoverageV2Pool noDust = new CoverageV2Pool(1 ether, 1 ether, address(otherToken), address(badDecimals));
        helper.setPair(address(noDust));
        (uint256 price, bool success) = helper.exposedGetUniswapV2Price();
        assertEq(price, 0);
        assertFalse(success);

        CoverageV3Pool v3NoDust = new CoverageV3Pool(
            158456325028528675187087900672,
            address(otherToken),
            address(new CoverageERC20("OTHER3", "OTHER3", 18, false))
        );
        helper.setPair(address(v3NoDust));
        (price, success) = helper.exposedGetUniswapV3PriceFromSqrtPriceX96(158456325028528675187087900672);
        assertEq(price, 0);
        assertFalse(success);

        CoverageV2Pool v2NoDust = new CoverageV2Pool(
            1 ether, 1 ether, address(otherToken), address(new CoverageERC20("OTHER2", "OTHER2", 18, false))
        );
        helper.setPair(address(v2NoDust));
        (price, success) = helper.exposedGetUniswapV2Price();
        assertEq(price, 0);
        assertFalse(success);

        CoverageERC20 dust6 = new CoverageERC20("DUST6", "D6", 6, false);
        NeverlandDustHelperHarness helper6 = new NeverlandDustHelperHarness(address(dust6), address(this));
        CoverageV2Pool v2Dust0DecimalsUp = new CoverageV2Pool(1_000_000, 1 ether, address(dust6), address(otherToken));
        helper6.setPair(address(v2Dust0DecimalsUp));
        (price, success) = helper6.exposedGetUniswapV2Price();
        assertEq(price, 1e18);
        assertTrue(success);

        CoverageV2Pool v2Dust1DecimalsDown =
            new CoverageV2Pool(1_000_000, 1 ether, address(new CoverageERC20("USDC", "USDC", 6, false)), address(dust));
        helper.setPair(address(v2Dust1DecimalsDown));
        (price, success) = helper.exposedGetUniswapV2Price();
        assertEq(price, 1e18);
        assertTrue(success);

        CoverageV2Pool v2Dust1DecimalsUp = new CoverageV2Pool(1 ether, 1_000_000, address(otherToken), address(dust6));
        helper6.setPair(address(v2Dust1DecimalsUp));
        (price, success) = helper6.exposedGetUniswapV2Price();
        assertEq(price, 1e18);
        assertTrue(success);

        noDust.setRevertReserves(true);
        helper.setPair(address(noDust));
        (price, success) = helper.exposedGetUniswapV2Price();
        assertEq(price, 0);
        assertFalse(success);

        helper.setPair(address(new CoverageBrokenPair()));
        (price, success) = helper.exposedGetDustPairPrice();
        assertEq(price, 0);
        assertFalse(success);

        CoverageOracle zeroDirect = new CoverageOracle(1, 20, makeAddr("usd"), address(dust));
        helper.setPair(address(zeroDirect));
        (price, success) = helper.exposedGetOraclePrice();
        assertEq(price, 0);
        assertFalse(success);

        NeverlandDustHelperHarness helperNoSources = new NeverlandDustHelperHarness(address(dust6), address(this));
        (price, success) = helperNoSources.exposedGetOraclePrice();
        assertEq(price, helperNoSources.DEFAULT_DUST_PRICE());
        assertFalse(success);
    }

    function testOraclePriceTwoStepFailureBranches() public {
        CoverageERC20 paired = new CoverageERC20("PAIR", "PAIR", 18, false);
        CoverageV2Pool pair = new CoverageV2Pool(1 ether, 4 ether, address(dust), address(paired));
        CoverageOracle pairUsd = new CoverageOracle(100_000_000, 8, makeAddr("usd"), address(0));

        helper.setPair(address(pair));
        helper.setPairOracle(address(pairUsd));
        (uint256 price, bool success) = helper.exposedGetOraclePrice();
        assertEq(price, 400_000_000);
        assertTrue(success);

        helper.setPair(address(new CoverageBrokenPair()));
        (price, success) = helper.exposedGetOraclePrice();
        assertEq(price, 0);
        assertFalse(success);

        helper.setPair(address(pair));
        CoverageOracle badPairUsd = new CoverageOracle(-1, 8, makeAddr("usd"), address(0));
        helper.setPairOracle(address(badPairUsd));
        (price, success) = helper.exposedGetOraclePrice();
        assertEq(price, 0);
        assertFalse(success);

        CoverageReClammPool tinyReclamm = new CoverageReClammPool();
        tinyReclamm.setData(1, 2 ether, true, true);
        helper.removePair();
        helper.setReclammPool(address(tinyReclamm), true);
        helper.setPairOracle(address(pairUsd));
        (price, success) = helper.exposedGetOraclePrice();
        assertEq(price, 0);
        assertFalse(success);
    }

    function testChainlinkAndDirectOracleFailureBranches() public {
        CoverageOracle oracle = new CoverageOracle(1e8, 8, address(dust), makeAddr("pair"));
        helper.setPair(address(oracle));
        (uint256 price, bool success) = helper.exposedGetChainlinkPrice();
        assertEq(price, 1e18);
        assertTrue(success);

        oracle.setReverts(false, false, false, true);
        (price, success) = helper.exposedGetChainlinkPrice();
        assertEq(price, 1e18);
        assertTrue(success);

        oracle.setReverts(false, false, true, false);
        (price, success) = helper.exposedGetChainlinkPrice();
        assertEq(price, 1e18);
        assertTrue(success);

        oracle = new CoverageOracle(2e8, 8, makeAddr("pair"), address(dust));
        helper.setPair(address(oracle));
        (price, success) = helper.exposedGetDustUsdPrice();
        assertEq(price, 0.5e18);
        assertTrue(success);

        oracle = new CoverageOracle(1e8, 8, makeAddr("notDust0"), makeAddr("notDust1"));
        helper.setPair(address(oracle));
        (price, success) = helper.exposedGetChainlinkPrice();
        assertEq(price, 1e18);
        assertTrue(success);

        (price, success) = helper.exposedGetDustUsdPrice();
        assertEq(price, 1e18);
        assertTrue(success);

        oracle.setReverts(false, true, false, false);
        (price, success) = helper.exposedGetChainlinkPrice();
        assertEq(price, 0);
        assertFalse(success);
        oracle.setReverts(false, false, false, false);

        oracle.setReverts(false, false, false, true);
        (price, success) = helper.exposedGetDustUsdPrice();
        assertEq(price, 1e18);
        assertTrue(success);

        oracle.setReverts(false, false, true, false);
        (price, success) = helper.exposedGetDustUsdPrice();
        assertEq(price, 1e18);
        assertTrue(success);

        oracle.setReverts(true, false, false, false);
        (price, success) = helper.exposedGetDustUsdPrice();
        assertEq(price, 0);
        assertFalse(success);

        oracle = new CoverageOracle(0, 8, address(dust), makeAddr("pair"));
        helper.setPair(address(oracle));
        (price, success) = helper.exposedGetChainlinkPrice();
        assertEq(price, 0);
        assertFalse(success);

        oracle = new CoverageOracle(type(int256).max, 0, address(dust), makeAddr("pair"));
        helper.setPair(address(oracle));
        (price, success) = helper.exposedGetChainlinkPrice();
        assertEq(price, 0);
        assertFalse(success);

        oracle = new CoverageOracle(1, 20, makeAddr("pair"), address(dust));
        helper.setPair(address(oracle));
        (price, success) = helper.exposedGetChainlinkPrice();
        assertEq(price, 0);
        assertFalse(success);

        oracle = new CoverageOracle(0, 8, address(dust), makeAddr("usd"));
        helper.setPair(address(oracle));
        (price, success) = helper.exposedGetDustUsdPrice();
        assertEq(price, 0);
        assertFalse(success);

        oracle = new CoverageOracle(1e8, 8, address(dust), makeAddr("usd"));
        oracle.setReverts(false, true, false, false);
        helper.setPair(address(oracle));
        (price, success) = helper.exposedGetDustUsdPrice();
        assertEq(price, 0);
        assertFalse(success);

        oracle = new CoverageOracle(type(int256).max, 0, address(dust), makeAddr("usd"));
        helper.setPair(address(oracle));
        (price, success) = helper.exposedGetDustUsdPrice();
        assertEq(price, 0);
        assertFalse(success);

        oracle = new CoverageOracle(1, 20, makeAddr("usd"), address(dust));
        helper.setPair(address(oracle));
        (price, success) = helper.exposedGetDustUsdPrice();
        assertEq(price, 0);
        assertFalse(success);

        CoverageOracle badPairUsd = new CoverageOracle(-1, 8, makeAddr("usd"), address(0));
        helper.setPairOracle(address(badPairUsd));
        (price, success) = helper.exposedGetPairUsdPrice();
        assertEq(price, 0);
        assertFalse(success);

        badPairUsd = new CoverageOracle(1e8, 25, makeAddr("usd"), address(0));
        helper.setPairOracle(address(badPairUsd));
        (price, success) = helper.exposedGetPairUsdPrice();
        assertEq(price, 0);
        assertFalse(success);

        badPairUsd = new CoverageOracle(type(int256).max, 0, makeAddr("usd"), address(0));
        helper.setPairOracle(address(badPairUsd));
        (price, success) = helper.exposedGetPairUsdPrice();
        assertEq(price, 0);
        assertFalse(success);

        badPairUsd.setReverts(true, false, false, false);
        (price, success) = helper.exposedGetPairUsdPrice();
        assertEq(price, 0);
        assertFalse(success);
    }
}
