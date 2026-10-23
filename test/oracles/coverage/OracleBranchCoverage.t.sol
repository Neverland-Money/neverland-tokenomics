// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {RatioOracleAggregator} from "../../../src/oracles/RatioOracleAggregator.sol";
import {YieldBearingOracleAdapter} from "../../../src/oracles/YieldBearingOracleAdapter.sol";
import {IYieldBearingOracleAdapter} from "../../../src/interfaces/IYieldBearingOracleAdapter.sol";

/// @notice Minimal configurable Chainlink-style aggregator for branch targeting.
contract MockAgg is AggregatorV3Interface {
    int256 private _answer;
    uint8 private _decimals;
    uint256 private _timestamp;
    uint80 private _roundId;

    constructor(int256 answer_, uint8 decimals_) {
        _answer = answer_;
        _decimals = decimals_;
        _timestamp = block.timestamp;
        _roundId = 1;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "MockAgg";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, _timestamp, _timestamp, _roundId);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, _timestamp, _timestamp, _roundId);
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

/// @notice Minimal ERC20 metadata token with configurable decimals.
contract MockToken is IERC20Metadata {
    uint8 private _decimals;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function name() external pure returns (string memory) {
        return "MockToken";
    }

    function symbol() external pure returns (string memory) {
        return "MTK";
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
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
}

/// @notice Minimal ERC4626 with a settable assets-per-share ratio.
contract MockVault is IERC4626 {
    address private _asset;
    uint8 private _decimals;
    uint256 private _ratio;

    constructor(address asset_, uint8 decimals_) {
        _asset = asset_;
        _decimals = decimals_;
        _ratio = 1e18;
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
        // ratio is expressed as assets per 1e18 shares.
        return (shares * _ratio) / 1e18;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return (assets * 1e18) / _ratio;
    }

    function totalAssets() external pure returns (uint256) {
        return 0;
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
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
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
        return "MockVault";
    }

    function symbol() external pure returns (string memory) {
        return "mVLT";
    }
}

/**
 * @notice Targets the last uncovered branches across the two ratio oracles:
 *         - RatioOracleAggregator: the `!scaleOk` (scale-up overflow) arm in `_computePriceSafe`,
 *           reached only when mulDiv succeeds but up-scaling to TARGET_DECIMALS overflows
 *           (base decimals < 8). Exercised on both the strict and lenient paths.
 *         - YieldBearingOracleAdapter: the `getAnswer` / `getTimestamp` "valid data but the
 *           requested round is not the latest round" arm, and the same `!scaleOk` scale-up
 *           overflow arm in `_computeSharesPriceSafe`.
 */
contract OracleBranchCoverageTest is Test {
    function setUp() public {
        vm.warp(100 days);
    }

    /*//////////////////////////////////////////////////////////////
                       RatioOracleAggregator
    //////////////////////////////////////////////////////////////*/

    /// @dev ratio decimals = 6 -> denominator 1e6; ratio=1e6 cancels it so scaled == basePrice.
    ///      basePrice = max/50 (a valid positive int256) makes mulDiv succeed (result fits) but the
    ///      subsequent up-scale to TARGET_DECIMALS (base decimals = 6, factor 100) overflows -> !scaleOk.
    function _deployRatioScaleOverflow() internal returns (RatioOracleAggregator) {
        int256 hugePrice = int256(type(uint256).max / 50);
        MockAgg ratioAgg = new MockAgg(int256(1e6), 6);
        MockAgg baseAgg = new MockAgg(hugePrice, 6);
        return new RatioOracleAggregator(address(ratioAgg), address(baseAgg), 1 hours);
    }

    function testRatioLatestRoundDataRevertsOnScaleUpOverflow() public {
        RatioOracleAggregator oracle = _deployRatioScaleOverflow();
        vm.expectRevert();
        oracle.latestRoundData();
    }

    function testRatioLatestAnswerReturnsZeroOnScaleUpOverflow() public {
        RatioOracleAggregator oracle = _deployRatioScaleOverflow();
        assertEq(oracle.latestAnswer(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                     YieldBearingOracleAdapter
    //////////////////////////////////////////////////////////////*/

    function _deployYbValid() internal returns (YieldBearingOracleAdapter) {
        MockToken asset = new MockToken(18);
        MockVault vault = new MockVault(address(asset), 18);
        MockAgg baseAgg = new MockAgg(2000e8, 8);
        return new YieldBearingOracleAdapter(address(baseAgg), address(vault), 1 hours, 1 hours, 30 days, 0, "sMON/USD");
    }

    /// @notice getAnswer with a valid feed but a non-latest round id hits the `roundId != latest` arm.
    function testYbGetAnswerValidDataButWrongRoundReturnsZero() public {
        YieldBearingOracleAdapter oracle = _deployYbValid();

        // latestRound() == 1; querying a different (in-range) round must return 0 even though data is valid.
        assertEq(oracle.getAnswer(2), 0);
    }

    /// @notice getTimestamp with a valid feed but a non-latest round id hits the `roundId != latest` arm.
    function testYbGetTimestampValidDataButWrongRoundReturnsZero() public {
        YieldBearingOracleAdapter oracle = _deployYbValid();

        assertEq(oracle.getTimestamp(2), 0);
    }

    /// @dev base/asset decimals = 6 (assetUnit 1e6, scale-up factor 100). basePrice = 1e6 cancels the
    ///      assetUnit divisor so the mulDiv result equals the (mocked) currentRatio. A currentRatio of
    ///      max/50 keeps mulDiv within uint256 (ok=true) but makes the up-scale (* 100) overflow -> !scaleOk.
    function _deployYbScaleOverflow() internal returns (YieldBearingOracleAdapter, MockVault) {
        MockToken asset = new MockToken(6);
        MockVault vault = new MockVault(address(asset), 6);
        MockAgg baseAgg = new MockAgg(int256(1e6), 6);
        YieldBearingOracleAdapter oracle =
            new YieldBearingOracleAdapter(address(baseAgg), address(vault), 1 hours, 1 hours, 30 days, 0, "Test");

        // shareUnit = 1e6 (sharesDecimals 6). Force convertToAssets(1e6) to return max/50 exactly.
        vm.mockCall(
            address(vault),
            abi.encodeWithSelector(IERC4626.convertToAssets.selector, uint256(1e6)),
            abi.encode(type(uint256).max / 50)
        );
        return (oracle, vault);
    }

    /// @notice scale-up overflow on the lenient path returns 0.
    function testYbLatestAnswerReturnsZeroOnScaleUpOverflow() public {
        (YieldBearingOracleAdapter oracle,) = _deployYbScaleOverflow();
        assertEq(oracle.latestAnswer(), 0);
    }

    /// @notice scale-up overflow on the strict path reverts with InvalidSharesConversion.
    function testYbLatestRoundDataRevertsOnScaleUpOverflow() public {
        (YieldBearingOracleAdapter oracle,) = _deployYbScaleOverflow();
        vm.expectRevert(IYieldBearingOracleAdapter.InvalidSharesConversion.selector);
        oracle.latestRoundData();
    }
}
