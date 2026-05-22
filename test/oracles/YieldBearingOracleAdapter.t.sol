// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {YieldBearingOracleAdapter} from "../../src/oracles/YieldBearingOracleAdapter.sol";
import {IYieldBearingOracleAdapter} from "../../src/interfaces/IYieldBearingOracleAdapter.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract MockAggregator is AggregatorV3Interface {
    int256 private _answer;
    uint8 private _decimals;
    uint256 private _timestamp;
    uint80 private _roundId;
    uint80 private _answeredInRoundOverride;
    bool private _useAnsweredInRoundOverride;
    uint256 private _startedAtOverride;
    bool private _useStartedAtOverride;

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

    function setStale() external {
        _timestamp = block.timestamp - 2 hours;
    }

    function setIncompleteRound() external {
        uint80 currentRound = _roundId;
        _roundId = currentRound + 5;
    }

    function setTimestamp(uint256 timestamp_) external {
        _timestamp = timestamp_;
    }

    function setAnsweredInRound(uint80 answeredInRound_) external {
        _answeredInRoundOverride = answeredInRound_;
        _useAnsweredInRoundOverride = true;
    }

    function clearAnsweredInRoundOverride() external {
        _useAnsweredInRoundOverride = false;
    }

    function setStartedAt(uint256 startedAt_) external {
        _startedAtOverride = startedAt_;
        _useStartedAtOverride = true;
    }

    function clearStartedAtOverride() external {
        _useStartedAtOverride = false;
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
            ? _answeredInRoundOverride
            : (requestedRoundId < _roundId ? requestedRoundId : _roundId);
        uint256 startedAtValue = _useStartedAtOverride ? _startedAtOverride : _timestamp;
        return (_roundId, _answer, startedAtValue, _timestamp, answeredIn);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint80 answeredIn = _useAnsweredInRoundOverride ? _answeredInRoundOverride : _roundId;
        uint256 startedAtValue = _useStartedAtOverride ? _startedAtOverride : _timestamp;
        return (_roundId, _answer, startedAtValue, _timestamp, answeredIn);
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

contract MockAggregatorZeroRound is AggregatorV3Interface {
    int256 private _answer;
    uint8 private _decimals;
    uint256 private _timestamp;

    constructor(int256 answer_, uint8 decimals_) {
        _answer = answer_;
        _decimals = decimals_;
        _timestamp = block.timestamp;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "Mock Zero Round";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, _answer, _timestamp, _timestamp, 0);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, _answer, _timestamp, _timestamp, 0);
    }

    function latestAnswer() external view returns (int256) {
        return _answer;
    }

    function latestTimestamp() external view returns (uint256) {
        return _timestamp;
    }

    function latestRound() external pure returns (uint256) {
        return 0;
    }

    function getAnswer(uint256) external view returns (int256) {
        return _answer;
    }

    function getTimestamp(uint256) external view returns (uint256) {
        return _timestamp;
    }
}

contract MockAggregatorRevertDecimals is AggregatorV3Interface {
    int256 private _answer;
    uint256 private _timestamp;
    uint80 private _roundId;

    constructor(int256 answer_) {
        _answer = answer_;
        _timestamp = block.timestamp;
        _roundId = 1;
    }

    function decimals() external pure returns (uint8) {
        revert("DECIMALS_REVERT");
    }

    function description() external pure returns (string memory) {
        return "Mock Revert Decimals";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _timestamp, _timestamp, _roundId);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
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

contract MockAggregatorRevertRoundData is AggregatorV3Interface {
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
        return "Mock Revert RoundData";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert("ROUND_DATA_REVERT");
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
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

contract MockAggregatorRevertLatestRoundData is AggregatorV3Interface {
    uint8 private _decimals;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "Mock Revert LatestRoundData";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external pure returns (uint80, int256, uint256, uint256, uint80) {
        return (0, 0, 0, 0, 0);
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert("LATEST_ROUND_DATA_REVERT");
    }

    function latestAnswer() external pure returns (int256) {
        return 0;
    }

    function latestTimestamp() external pure returns (uint256) {
        return 0;
    }

    function latestRound() external pure returns (uint256) {
        return 0;
    }

    function getAnswer(uint256) external pure returns (int256) {
        return 0;
    }

    function getTimestamp(uint256) external pure returns (uint256) {
        return 0;
    }
}

contract MockERC20 is IERC20Metadata {
    uint8 private _decimals;
    string private _name;
    string private _symbol;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
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

contract MockERC4626ToggleConvertToAssets is IERC4626 {
    address private _asset;
    uint8 private _decimals;
    uint256 private _ratio;
    bool private _revertConvert;

    constructor(address asset_, uint8 decimals_) {
        _asset = asset_;
        _decimals = decimals_;
        _ratio = 1.05e18;
    }

    function setRatio(uint256 ratio_) external {
        _ratio = ratio_;
    }

    function setRevertConvert(bool shouldRevert) external {
        _revertConvert = shouldRevert;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        if (_revertConvert) revert("CONVERT_ASSETS_REVERT");
        if (_ratio == 0) return 0;
        return (shares * _ratio) / 1e18;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
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
        return "Mock Toggle Shares";
    }

    function symbol() external pure returns (string memory) {
        return "tSHR";
    }
}

contract MockERC4626RevertConvertToAssets is IERC4626 {
    address private _asset;
    uint8 private _decimals;
    uint256 private _ratio;

    constructor(address asset_, uint8 decimals_) {
        _asset = asset_;
        _decimals = decimals_;
        _ratio = 1e18;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function convertToAssets(uint256) external pure returns (uint256) {
        revert("CONVERT_ASSETS_REVERT");
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
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
        return "Mock Revert Shares";
    }

    function symbol() external pure returns (string memory) {
        return "rSHR";
    }
}

contract YieldBearingOracleAdapterHarness is YieldBearingOracleAdapter {
    constructor(
        address baseAggregator_,
        address sharesContract_,
        uint256 maxDelay_,
        uint48 minimumSnapshotDelay_,
        uint48 maximumSnapshotAge_,
        uint16 initialRejectionGraceBps_,
        string memory description_
    )
        YieldBearingOracleAdapter(
            baseAggregator_,
            sharesContract_,
            maxDelay_,
            minimumSnapshotDelay_,
            maximumSnapshotAge_,
            initialRejectionGraceBps_,
            description_
        )
    {}

    function isFresh(uint256 updatedAt) external view returns (bool) {
        return _isFresh(updatedAt);
    }

    function calculateMaxRatio() external view returns (uint256) {
        return _calculateMaxRatio();
    }

    function tryComputeGrowthRate(uint256 snapshotRatio, uint16 maxAnnualGrowthBps)
        external
        pure
        returns (uint104, bool)
    {
        return _tryComputeGrowthRate(snapshotRatio, maxAnnualGrowthBps);
    }
}

contract YieldBearingOracleAdapterTest is Test {
    event SnapshotQueued(uint256 snapshotRatio, uint256 effectiveAt);
    event SnapshotActivated(uint256 snapshotRatio, uint256 effectiveAt);
    event RejectionGraceUpdated(uint256 previousRejectionGraceBps, uint256 newRejectionGraceBps);

    YieldBearingOracleAdapter public oracle;
    YieldBearingOracleAdapterHarness public oracleHarness;
    MockAggregator public baseAgg;
    MockERC4626 public shares;
    MockERC20 public asset;

    address owner = address(this);
    address keeper = address(0x1);
    address user = address(0x2);

    function setUp() public {
        vm.warp(100 days);

        asset = new MockERC20("Asset", "ASSET", 18);
        shares = new MockERC4626(address(asset), 18);
        baseAgg = new MockAggregator(2000e8, 8);

        oracle =
            new YieldBearingOracleAdapter(address(baseAgg), address(shares), 1 hours, 1 hours, 30 days, 0, "sMON/USD");
        oracleHarness = new YieldBearingOracleAdapterHarness(
            address(baseAgg), address(shares), 1 hours, 1 hours, 30 days, 0, "sMON/USD"
        );
    }

    function _storeSlot4(address target, uint104 snapshotRatio, uint48 snapshotTimestamp, uint104 growthRate) internal {
        uint256 value = uint256(snapshotRatio) | (uint256(snapshotTimestamp) << 104) | (uint256(growthRate) << 152);
        vm.store(target, bytes32(uint256(4)), bytes32(value));
    }

    function _storeSlot5(
        address target,
        uint16 maxAnnualGrowthBps,
        uint104 pendingSnapshotRatio,
        uint48 pendingSnapshotEffectiveAt,
        uint16 rejectionGraceBps
    ) internal {
        uint256 value = uint256(maxAnnualGrowthBps) | (uint256(pendingSnapshotRatio) << 16)
            | (uint256(pendingSnapshotEffectiveAt) << 120) | (uint256(rejectionGraceBps) << 168);
        vm.store(target, bytes32(uint256(5)), bytes32(value));
    }

    function testConstructorSuccess() public view {
        assertEq(address(oracle.baseAggregator()), address(baseAgg));
        assertEq(address(oracle.sharesContract()), address(shares));
        assertEq(oracle.maxDelay(), 1 hours);
        assertEq(oracle.baseDecimals(), 8);
        assertEq(oracle.sharesDecimals(), 18);
        assertEq(oracle.assetDecimals(), 18);
        assertEq(oracle.minimumSnapshotDelay(), 1 hours);
        assertEq(oracle.maximumSnapshotAge(), 30 days);
        assertEq(oracle.description(), "sMON/USD");
        assertEq(oracle.getRejectionGraceBps(), 0);
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.version(), 1);
    }

    function testConstructorInitialRejectionGraceBps() public {
        YieldBearingOracleAdapter initializedOracle =
            new YieldBearingOracleAdapter(address(baseAgg), address(shares), 1 hours, 1 hours, 30 days, 100, "Test");
        assertEq(initializedOracle.getRejectionGraceBps(), 100);
    }

    function testConstructorRevertsOnInvalidInitialRejectionGraceBps() public {
        vm.expectRevert(IYieldBearingOracleAdapter.InvalidRejectionGrace.selector);
        new YieldBearingOracleAdapter(address(baseAgg), address(shares), 1 hours, 1 hours, 30 days, 10001, "Test");
    }

    function testConstructorZeroAddresses() public {
        vm.expectRevert();
        new YieldBearingOracleAdapter(address(0), address(shares), 1 hours, 1 hours, 30 days, 0, "Test");

        vm.expectRevert();
        new YieldBearingOracleAdapter(address(baseAgg), address(0), 1 hours, 1 hours, 30 days, 0, "Test");
    }

    function testConstructorInvalidSnapshotParameters() public {
        vm.expectRevert();
        new YieldBearingOracleAdapter(address(baseAgg), address(shares), 1 hours, 30 days, 1 hours, 0, "Test");

        vm.expectRevert();
        new YieldBearingOracleAdapter(address(baseAgg), address(shares), 1 hours, 1 hours, 0, 0, "Test");
    }

    function testConstructorInvalidDecimals() public {
        MockERC20 invalid = new MockERC20("Invalid", "INV", 5);
        MockERC4626 invalidShares = new MockERC4626(address(invalid), 18);

        vm.expectRevert();
        new YieldBearingOracleAdapter(address(baseAgg), address(invalidShares), 1 hours, 1 hours, 30 days, 0, "Test");

        MockAggregator invalidAgg = new MockAggregator(2000e8, 19);
        vm.expectRevert();
        new YieldBearingOracleAdapter(address(invalidAgg), address(shares), 1 hours, 1 hours, 30 days, 0, "Test");
    }

    function testConstructorInvalidBaseDecimalsLow() public {
        MockAggregator invalidAgg = new MockAggregator(2000e5, 5);
        vm.expectRevert();
        new YieldBearingOracleAdapter(address(invalidAgg), address(shares), 1 hours, 1 hours, 30 days, 0, "Test");
    }

    function testConstructorInvalidSharesDecimalsLow() public {
        MockERC4626 invalidShares = new MockERC4626(address(asset), 5);
        vm.expectRevert();
        new YieldBearingOracleAdapter(address(baseAgg), address(invalidShares), 1 hours, 1 hours, 30 days, 0, "Test");
    }

    function testConstructorInvalidSharesDecimalsHigh() public {
        MockERC4626 invalidShares = new MockERC4626(address(asset), 19);
        vm.expectRevert();
        new YieldBearingOracleAdapter(address(baseAgg), address(invalidShares), 1 hours, 1 hours, 30 days, 0, "Test");
    }

    function testConstructorInvalidAssetDecimalsHigh() public {
        MockERC20 invalid = new MockERC20("Invalid", "INV", 19);
        MockERC4626 invalidShares = new MockERC4626(address(invalid), 18);

        vm.expectRevert();
        new YieldBearingOracleAdapter(address(baseAgg), address(invalidShares), 1 hours, 1 hours, 30 days, 0, "Test");
    }

    function testConstructorAssetZeroAddress() public {
        MockERC4626 invalidShares = new MockERC4626(address(0), 18);
        vm.expectRevert();
        new YieldBearingOracleAdapter(address(baseAgg), address(invalidShares), 1 hours, 1 hours, 30 days, 0, "Test");
    }

    function testConstructorRevertsOnDecimalsFailure() public {
        MockAggregatorRevertDecimals revertDecimals = new MockAggregatorRevertDecimals(2000e8);
        vm.expectRevert();
        new YieldBearingOracleAdapter(address(revertDecimals), address(shares), 1 hours, 1 hours, 30 days, 0, "Test");
    }

    function testLatestAnswer() public view {
        int256 answer = oracle.latestAnswer();
        assertEq(answer, 2100e8);
    }

    function testLatestAnswerNegativePrice() public {
        baseAgg.setAnswer(-1000e8);
        int256 answer = oracle.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestAnswerWithZeroPrice() public {
        baseAgg.setAnswer(0);
        int256 answer = oracle.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestAnswerIgnoresAnsweredInRound() public {
        baseAgg.setAnsweredInRound(0);
        int256 answer = oracle.latestAnswer();
        assertEq(answer, 2100e8);
    }

    function testLatestAnswerReturnsZeroOnAnsweredInRoundLessThanRoundId() public {
        baseAgg.setAnswer(2000e8);
        baseAgg.setAnsweredInRound(1);
        int256 answer = oracle.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestAnswerReturnsZeroOnStartedAtAfterUpdatedAt() public {
        baseAgg.setStartedAt(block.timestamp + 1);
        int256 answer = oracle.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestAnswerReturnsZeroOnZeroRoundId() public {
        MockAggregatorZeroRound zeroRoundAgg = new MockAggregatorZeroRound(2000e8, 8);
        YieldBearingOracleAdapter oracleZeroRound =
            new YieldBearingOracleAdapter(address(zeroRoundAgg), address(shares), 1 hours, 1 hours, 30 days, 0, "Test");

        int256 answer = oracleZeroRound.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestAnswerWithZeroTimestamp() public {
        baseAgg.setTimestamp(0);
        int256 answer = oracle.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestAnswerPriceTooOld() public {
        baseAgg.setStale();
        int256 answer = oracle.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestAnswerWithRevertingRoundData() public {
        MockAggregatorRevertLatestRoundData revertAgg = new MockAggregatorRevertLatestRoundData(8);
        YieldBearingOracleAdapter oracleRevert =
            new YieldBearingOracleAdapter(address(revertAgg), address(shares), 1 hours, 1 hours, 30 days, 0, "Test");

        int256 answer = oracleRevert.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestAnswerWithRevertingSharesConversion() public {
        MockERC4626RevertConvertToAssets revertShares = new MockERC4626RevertConvertToAssets(address(asset), 18);
        YieldBearingOracleAdapter oracleRevert = new YieldBearingOracleAdapter(
            address(baseAgg), address(revertShares), 1 hours, 1 hours, 30 days, 0, "Test"
        );

        int256 answer = oracleRevert.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestAnswerReturnsZeroOnMulDivOverflow() public {
        baseAgg.setAnswer(int256(1) << 200);
        shares.setRatio((uint256(1) << 196) - 1);

        int256 answer = oracle.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestAnswerReturnsZeroOnInt256Overflow() public {
        baseAgg.setAnswer(int256(1) << 245);
        shares.setRatio(uint256(1) << 70);

        int256 answer = oracle.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestTimestamp() public view {
        uint256 timestamp = oracle.latestTimestamp();
        assertEq(timestamp, block.timestamp);
    }

    function testLatestTimestampIgnoresAnsweredInRound() public {
        baseAgg.setAnsweredInRound(0);
        uint256 timestamp = oracle.latestTimestamp();
        assertEq(timestamp, block.timestamp);
    }

    function testLatestTimestampWithZeroTimestamp() public {
        baseAgg.setTimestamp(0);
        uint256 timestamp = oracle.latestTimestamp();
        assertEq(timestamp, 0);
    }

    function testLatestTimestampPriceTooOld() public {
        baseAgg.setStale();
        uint256 timestamp = oracle.latestTimestamp();
        assertEq(timestamp, 0);
    }

    function testLatestRound() public view {
        uint256 round = oracle.latestRound();
        assertEq(round, 1);
    }

    function testGetAnswerWithValidRound() public view {
        int256 answer = oracle.getAnswer(1);
        assertEq(answer, 2100e8);
    }

    function testGetAnswerWithOversizedRound() public view {
        uint256 oversizedRound = uint256(type(uint80).max) + 1;
        int256 answer = oracle.getAnswer(oversizedRound);
        assertEq(answer, 0);
    }

    function testGetAnswerWithNegativePrice() public {
        baseAgg.setAnswer(-1000e8);
        int256 answer = oracle.getAnswer(1);
        assertEq(answer, 0);
    }

    function testGetAnswerWithZeroTimestamp() public {
        baseAgg.setTimestamp(0);
        int256 answer = oracle.getAnswer(1);
        assertEq(answer, 0);
    }

    function testGetAnswerWithStaleTimestamp() public {
        baseAgg.setStale();
        int256 answer = oracle.getAnswer(1);
        assertEq(answer, 0);
    }

    function testGetAnswerWithRevertedRoundData() public {
        MockAggregatorRevertRoundData revertAgg = new MockAggregatorRevertRoundData(2000e8, 8);
        YieldBearingOracleAdapter oracleRevert =
            new YieldBearingOracleAdapter(address(revertAgg), address(shares), 1 hours, 1 hours, 30 days, 0, "Test");
        int256 answer = oracleRevert.getAnswer(1);
        assertEq(answer, 2100e8);
    }

    function testGetAnswerWithIncompleteRound() public {
        baseAgg.setIncompleteRound();
        int256 answer = oracle.getAnswer(1);
        assertEq(answer, 0);
    }

    function testGetTimestampWithValidRound() public view {
        uint256 timestamp = oracle.getTimestamp(1);
        assertEq(timestamp, block.timestamp);
    }

    function testGetTimestampWithOversizedRound() public view {
        uint256 oversizedRound = uint256(type(uint80).max) + 1;
        uint256 timestamp = oracle.getTimestamp(oversizedRound);
        assertEq(timestamp, 0);
    }

    function testGetTimestampWithIncompleteRound() public {
        baseAgg.setIncompleteRound();
        uint256 timestamp = oracle.getTimestamp(1);
        assertEq(timestamp, 0);
    }

    function testGetTimestampWithZeroTimestamp() public {
        baseAgg.setTimestamp(0);
        uint256 timestamp = oracle.getTimestamp(1);
        assertEq(timestamp, 0);
    }

    function testGetTimestampWithStaleTimestamp() public {
        baseAgg.setStale();
        uint256 timestamp = oracle.getTimestamp(1);
        assertEq(timestamp, 0);
    }

    function testGetTimestampWithRevertedRoundData() public {
        MockAggregatorRevertRoundData revertAgg = new MockAggregatorRevertRoundData(2000e8, 8);
        YieldBearingOracleAdapter oracleRevert =
            new YieldBearingOracleAdapter(address(revertAgg), address(shares), 1 hours, 1 hours, 30 days, 0, "Test");
        uint256 timestamp = oracleRevert.getTimestamp(1);
        assertEq(timestamp, block.timestamp);
    }

    function testLatestRoundData() public view {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();

        assertEq(roundId, 1);
        assertEq(answer, 2100e8);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, 1);
    }

    function testLatestRoundDataRevertsOnZeroPrice() public {
        baseAgg.setAnswer(0);
        vm.expectRevert();
        oracle.latestRoundData();
    }

    function testLatestRoundDataIgnoresAnsweredInRound() public {
        baseAgg.setAnsweredInRound(0);
        (, int256 answer,,,) = oracle.latestRoundData();
        assertEq(answer, 2100e8);
    }

    function testLatestRoundDataRevertsOnZeroRoundId() public {
        MockAggregatorZeroRound zeroRoundAgg = new MockAggregatorZeroRound(2000e8, 8);
        YieldBearingOracleAdapter oracleZeroRound =
            new YieldBearingOracleAdapter(address(zeroRoundAgg), address(shares), 1 hours, 1 hours, 30 days, 0, "Test");

        vm.expectRevert();
        oracleZeroRound.latestRoundData();
    }

    function testLatestRoundDataRevertsOnAnsweredInRoundLessThanRoundId() public {
        baseAgg.setAnswer(2000e8);
        baseAgg.setAnsweredInRound(1);
        vm.expectRevert();
        oracle.latestRoundData();
    }

    function testLatestRoundDataRevertsOnZeroTimestamp() public {
        baseAgg.setTimestamp(0);
        vm.expectRevert();
        oracle.latestRoundData();
    }

    function testLatestRoundDataRevertsOnZeroSharesConversion() public {
        shares.setRatio(0);
        vm.expectRevert();
        oracle.latestRoundData();
    }

    function testLatestAnswerReturnsZeroOnFutureTimestamp() public {
        baseAgg.setTimestamp(block.timestamp + 1);
        int256 answer = oracle.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestRoundDataRevertsOnFutureTimestamp() public {
        baseAgg.setTimestamp(block.timestamp + 1);
        vm.expectRevert();
        oracle.latestRoundData();
    }

    function testLatestRoundDataRevertsOnStaleTimestamp() public {
        baseAgg.setStale();
        vm.expectRevert();
        oracle.latestRoundData();
    }

    function testLatestRoundDataRevertsOnStartedAtAfterUpdatedAt() public {
        baseAgg.setStartedAt(block.timestamp + 1);
        vm.expectRevert();
        oracle.latestRoundData();
    }

    function testLatestRoundDataRevertsOnMulDivOverflow() public {
        baseAgg.setAnswer(int256(1) << 200);
        shares.setRatio((uint256(1) << 196) - 1);

        vm.expectRevert(IYieldBearingOracleAdapter.InvalidSharesConversion.selector);
        oracle.latestRoundData();
    }

    function testGetRoundDataRevertsOnInt256Overflow() public {
        baseAgg.setAnswer(int256(1) << 245);
        shares.setRatio(uint256(1) << 70);

        uint80 roundId = uint80(oracle.latestRound());
        vm.expectRevert(IYieldBearingOracleAdapter.InvalidSharesConversion.selector);
        oracle.getRoundData(roundId);
    }

    function testGetRoundDataRevertsOnNonLatestRound() public {
        baseAgg.setAnswer(2100e8);
        uint80 latestRoundId = uint80(oracle.latestRound());
        vm.expectRevert();
        oracle.getRoundData(latestRoundId - 1);
    }

    function testGetRoundData() public view {
        (uint80 roundId, int256 answer,,,) = oracle.getRoundData(1);
        assertEq(roundId, 1);
        assertEq(answer, 2100e8);
    }

    function testSetGrowthCapBoundsAsOwner() public {
        uint16 growthBps = 500;
        oracle.setGrowthCapBounds(growthBps);
        assertEq(oracle.getMaxAnnualGrowthBps(), growthBps);
    }

    function testGrowthRateCalculation() public {
        oracle.setGrowthCapBounds(500);
        shares.setRatio(1.05e18);
        oracle.updateSnapshot();
        vm.warp(block.timestamp + 3601);
        oracle.latestAnswer();
        uint256 growthRate = oracle.getGrowthRatePerSecond();

        assertGt(growthRate, 0);
    }

    function testSetGrowthCapBoundsAfterSnapshotUpdatesGrowthRate() public {
        oracle.setGrowthCapBounds(500);
        shares.setRatio(1.05e18);
        oracle.updateSnapshot();
        vm.warp(block.timestamp + 3601);
        oracle.latestAnswer();
        uint256 previousRate = oracle.getGrowthRatePerSecond();

        oracle.setGrowthCapBounds(1000);
        uint256 newRate = oracle.getGrowthRatePerSecond();

        assertGt(newRate, previousRate);
    }

    function testUpdateSnapshotAsOwner() public {
        oracle.setGrowthCapBounds(500);
        shares.setRatio(1.05e18);
        uint256 queueTime = block.timestamp;
        oracle.updateSnapshot();
        vm.warp(block.timestamp + 3600);
        assertEq(oracle.getSnapshotRatio(), 1.05e18);
        assertEq(oracle.getSnapshotTimestamp(), queueTime);
    }

    function testUpdateSnapshotAsKeeper() public {
        oracle.setGrowthCapBounds(500);
        oracle.setKeeper(keeper);
        shares.setRatio(1.05e18);

        vm.prank(keeper);
        oracle.updateSnapshot();
        vm.warp(block.timestamp + 3600);
        assertEq(oracle.getSnapshotRatio(), 1.05e18);
    }

    function testUpdateSnapshotRevertsOnUint48TimestampOverflow() public {
        oracle.setGrowthCapBounds(500);
        shares.setRatio(1e18);
        oracle.updateSnapshot();

        // Force delayed path and overflow in block.timestamp + minimumSnapshotDelay.
        vm.warp(uint256(type(uint48).max) - 3599);
        vm.expectRevert(IYieldBearingOracleAdapter.InvalidSnapshotTimestamp.selector);
        oracle.updateSnapshot();
    }

    function testUpdateSnapshotImmediateRevertsWhenBoundsUnset() public {
        vm.expectRevert();
        oracle.updateSnapshotImmediate();
    }

    function testUpdateSnapshotImmediateBypassesDelay() public {
        oracle.setGrowthCapBounds(500);
        shares.setRatio(1.0e18);
        oracle.updateSnapshot();
        vm.warp(block.timestamp + 1 hours);

        shares.setRatio(1.2e18);
        uint256 nowTs = block.timestamp;
        oracle.updateSnapshotImmediate();

        assertEq(oracle.getSnapshotRatio(), 1.2e18);
        assertEq(oracle.getSnapshotTimestamp(), nowTs);
    }

    function testImmediateSnapshotCanLatchTransientlyInflatedRatio() public {
        oracleHarness.setGrowthCapBounds(500);

        shares.setRatio(2.0e18);
        oracleHarness.updateSnapshotImmediate();

        // Simulate post-snapshot normalization after a transient ratio spike.
        shares.setRatio(1.0e18);

        assertEq(oracleHarness.getSnapshotRatio(), 2.0e18);
        assertEq(oracleHarness.calculateMaxRatio(), 2.0e18);
        assertFalse(oracleHarness.isCapped());
    }

    function testQueuedSnapshotUsesQueueTimeRatioEvenIfRatioNormalizesBeforeActivation() public {
        oracleHarness.setGrowthCapBounds(500);

        shares.setRatio(1.0e18);
        oracleHarness.updateSnapshot();
        vm.warp(block.timestamp + 1 hours);

        shares.setRatio(2.0e18);
        uint256 queuedAt = block.timestamp;
        oracleHarness.updateSnapshot();
        uint256 expectedEffectiveAt = queuedAt + oracleHarness.minimumSnapshotDelay();

        // Simulate post-queue normalization before pending snapshot becomes effective.
        shares.setRatio(1.0e18);
        vm.warp(expectedEffectiveAt + 1);

        uint256 inflatedMaxRatio = oracleHarness.calculateMaxRatio();
        assertGt(inflatedMaxRatio, 2.0e18);
        assertFalse(oracleHarness.isCapped());
    }

    function testUpdateSnapshotImmediateRevertsOnZeroRatio() public {
        oracle.setGrowthCapBounds(500);
        shares.setRatio(0);
        vm.expectRevert();
        oracle.updateSnapshotImmediate();
    }

    function testUpdateSnapshotImmediateRevertsOnOversizedRatio() public {
        oracle.setGrowthCapBounds(500);
        shares.setRatio(uint256(type(uint104).max) + 1);
        vm.expectRevert();
        oracle.updateSnapshotImmediate();
    }

    function testUpdateSnapshotImmediateRevertsOnGrowthRateOverflow() public {
        oracle.setGrowthCapBounds(10000);
        shares.setRatio(type(uint104).max);
        vm.expectRevert(IYieldBearingOracleAdapter.InvalidGrowthRate.selector);
        oracle.updateSnapshotImmediate();
    }

    function testUpdateSnapshotImmediateRevertsOnUint48TimestampOverflow() public {
        oracle.setGrowthCapBounds(500);
        shares.setRatio(1e18);
        vm.warp(uint256(type(uint48).max) + 1);
        vm.expectRevert(IYieldBearingOracleAdapter.InvalidSnapshotTimestamp.selector);
        oracle.updateSnapshotImmediate();
    }

    function testSetGrowthCapBoundsAsKeeperReverts() public {
        oracle.setKeeper(keeper);

        vm.prank(keeper);
        vm.expectRevert();
        oracle.setGrowthCapBounds(500);
    }

    function testSetRejectionGraceBpsAsOwner() public {
        vm.expectEmit(false, false, false, true, address(oracle));
        emit RejectionGraceUpdated(0, 100);
        oracle.setRejectionGraceBps(100);
        assertEq(oracle.getRejectionGraceBps(), 100);
    }

    function testSetRejectionGraceBpsAsNonOwnerReverts() public {
        vm.prank(user);
        vm.expectRevert();
        oracle.setRejectionGraceBps(100);
    }

    function testSetRejectionGraceBpsOutOfRangeReverts() public {
        vm.expectRevert(IYieldBearingOracleAdapter.InvalidRejectionGrace.selector);
        oracle.setRejectionGraceBps(10001);
    }

    function testUpdateSnapshotUnauthorized() public {
        oracle.setGrowthCapBounds(500);
        shares.setRatio(1.05e18);
        vm.prank(user);
        vm.expectRevert();
        oracle.updateSnapshot();
    }

    function testUpdateSnapshotZeroRatio() public {
        oracle.setGrowthCapBounds(500);
        shares.setRatio(0);
        vm.expectRevert();
        oracle.updateSnapshot();
    }

    function testSetGrowthCapBoundsInvalidGrowthRate() public {
        vm.expectRevert();
        oracle.setGrowthCapBounds(0);

        vm.expectRevert();
        oracle.setGrowthCapBounds(10001);
    }

    function testSetGrowthCapBoundsOverflowAfterSnapshot() public {
        oracle.setGrowthCapBounds(1);
        shares.setRatio(1e24);
        oracle.updateSnapshot();
        vm.warp(block.timestamp + 3600);
        vm.expectRevert();
        oracle.setGrowthCapBounds(10000);
    }

    function testSetGrowthCapBoundsValidatesPendingSnapshot() public {
        oracle.setGrowthCapBounds(500);
        shares.setRatio(1.05e18);
        oracle.updateSnapshot();

        shares.setRatio(1.1e18);
        oracle.updateSnapshot();

        oracle.setGrowthCapBounds(600);
        assertEq(oracle.getMaxAnnualGrowthBps(), 600);
    }

    function testSetGrowthCapBoundsRevertsOnPendingGrowthRateOverflow() public {
        _storeSlot5(address(oracle), 500, type(uint104).max, uint48(block.timestamp + 1), 0);
        vm.expectRevert(IYieldBearingOracleAdapter.InvalidGrowthRate.selector);
        oracle.setGrowthCapBounds(10000);
    }

    function testUpdateSnapshotWithoutBoundsSet() public {
        shares.setRatio(1.05e18);
        vm.expectRevert();
        oracle.updateSnapshot();
    }

    function testUpdateSnapshotOverwritesPending() public {
        oracle.setGrowthCapBounds(500);
        shares.setRatio(1.05e18);
        oracle.updateSnapshot();

        shares.setRatio(1.1e18);
        oracle.updateSnapshot();
        vm.warp(block.timestamp + 3600);
        assertEq(oracle.getSnapshotRatio(), 1.1e18);
    }

    function testSnapshotActivatedEmitted() public {
        oracle.setGrowthCapBounds(500);
        shares.setRatio(1.05e18);
        uint48 expectedTimestamp = uint48(block.timestamp);

        vm.expectEmit(false, false, false, true, address(oracle));
        emit SnapshotQueued(1.05e18, expectedTimestamp);

        vm.expectEmit(false, false, false, true, address(oracle));
        emit SnapshotActivated(1.05e18, expectedTimestamp);

        oracle.updateSnapshot();
    }

    function testSnapshotActivatedEmittedOnDelayedUpdate() public {
        oracle.setGrowthCapBounds(500);

        shares.setRatio(1.05e18);
        oracle.updateSnapshot();

        shares.setRatio(1.1e18);
        uint256 queuedAt = block.timestamp;
        uint48 effectiveAt = uint48(queuedAt + oracle.minimumSnapshotDelay());

        vm.expectEmit(false, false, false, true, address(oracle));
        emit SnapshotQueued(1.1e18, effectiveAt);
        oracle.updateSnapshot();

        vm.warp(effectiveAt);

        shares.setRatio(1.15e18);
        vm.expectEmit(false, false, false, true, address(oracle));
        emit SnapshotActivated(1.1e18, effectiveAt);
        oracle.updateSnapshot();
    }

    function testSameBlockZeroDelaySnapshotActivates() public {
        YieldBearingOracleAdapter zeroDelayOracle =
            new YieldBearingOracleAdapter(address(baseAgg), address(shares), 1 hours, 0, 30 days, 0, "Test");
        zeroDelayOracle.setGrowthCapBounds(500);

        shares.setRatio(1.05e18);
        uint48 firstTimestamp = uint48(block.timestamp);

        vm.expectEmit(false, false, false, true, address(zeroDelayOracle));
        emit SnapshotQueued(1.05e18, firstTimestamp);
        vm.expectEmit(false, false, false, true, address(zeroDelayOracle));
        emit SnapshotActivated(1.05e18, firstTimestamp);
        zeroDelayOracle.updateSnapshot();

        shares.setRatio(1.1e18);
        uint48 secondTimestamp = uint48(block.timestamp);
        vm.expectEmit(false, false, false, true, address(zeroDelayOracle));
        emit SnapshotQueued(1.1e18, secondTimestamp);
        zeroDelayOracle.updateSnapshot();

        shares.setRatio(1.15e18);
        vm.expectEmit(false, false, false, true, address(zeroDelayOracle));
        emit SnapshotActivated(1.1e18, secondTimestamp);
        vm.expectEmit(false, false, false, true, address(zeroDelayOracle));
        emit SnapshotQueued(1.15e18, secondTimestamp);
        zeroDelayOracle.updateSnapshot();

        assertEq(zeroDelayOracle.getSnapshotRatio(), 1.15e18);
        assertEq(zeroDelayOracle.getSnapshotTimestamp(), secondTimestamp);
    }

    function testUpdateSnapshotOverflowCheck() public {
        oracle.setGrowthCapBounds(10000);
        shares.setRatio(uint256(type(uint104).max) + 1);
        vm.expectRevert();
        oracle.updateSnapshot();
    }

    function testUpdateSnapshotRevertsOnGrowthRateOverflow() public {
        oracle.setGrowthCapBounds(10000);
        shares.setRatio(type(uint104).max);
        vm.expectRevert(IYieldBearingOracleAdapter.InvalidGrowthRate.selector);
        oracle.updateSnapshot();
    }

    function testUpdateSnapshotRevertsWhenPendingGrowthRateOverflows() public {
        _storeSlot5(address(oracle), 10000, type(uint104).max, uint48(block.timestamp), 0);
        vm.expectRevert(IYieldBearingOracleAdapter.InvalidGrowthRate.selector);
        oracle.updateSnapshot();
    }

    function testPendingSnapshotEffectiveReadPaths() public {
        oracle.setGrowthCapBounds(500);
        shares.setRatio(1.05e18);
        oracle.updateSnapshot();

        shares.setRatio(1.1e18);
        uint256 queuedAt = block.timestamp;
        oracle.updateSnapshot();
        uint256 expectedEffectiveAt = queuedAt + oracle.minimumSnapshotDelay();
        vm.warp(expectedEffectiveAt + 1);

        assertEq(oracle.getSnapshotTimestamp(), expectedEffectiveAt);

        uint256 expectedRate = (uint256(1.1e18) * 500 * 1e18) / (10000 * 365 days);
        assertEq(oracle.getGrowthRatePerSecond(), expectedRate);

        baseAgg.setTimestamp(block.timestamp);
        assertGt(oracle.latestAnswer(), 0);
    }

    function testIsCappedWhenNotSet() public view {
        assertFalse(oracle.isCapped());
    }

    function testIsCappedWhenBoundsSetNoSnapshot() public {
        oracle.setGrowthCapBounds(500);
        assertFalse(oracle.isCapped());
    }

    function testIsCappedWhenUnderCap() public {
        oracle.setGrowthCapBounds(500);
        shares.setRatio(1.05e18);
        oracle.updateSnapshot();
        vm.warp(block.timestamp + 3600);

        assertFalse(oracle.isCapped());
    }

    function testIsCappedWhenOverCap() public {
        oracle.setGrowthCapBounds(100);
        shares.setRatio(1.0e18);
        oracle.updateSnapshot();
        vm.warp(block.timestamp + 3600);
        vm.warp(block.timestamp + 7 days);

        shares.setRatio(2.0e18);
        assertTrue(oracle.isCapped());
    }

    function testSnapshotAgeDoesNotClampGrowth() public {
        oracle.setGrowthCapBounds(10000);
        shares.setRatio(1.0e18);
        oracle.updateSnapshot();
        vm.warp(block.timestamp + 3600);
        vm.warp(block.timestamp + 50 days);
        shares.setRatio(1.1e18);

        assertFalse(oracle.isCapped());
    }

    function testIsCappedReturnsFalseOnRevertingShares() public {
        MockERC4626ToggleConvertToAssets toggleShares = new MockERC4626ToggleConvertToAssets(address(asset), 18);
        YieldBearingOracleAdapter revertOracle = new YieldBearingOracleAdapter(
            address(baseAgg), address(toggleShares), 1 hours, 1 hours, 30 days, 0, "Test"
        );
        revertOracle.setGrowthCapBounds(500);
        toggleShares.setRatio(1.05e18);
        revertOracle.updateSnapshot();

        toggleShares.setRevertConvert(true);

        assertFalse(revertOracle.isCapped());
    }

    function testIsCappedReturnsFalseWhenMaxRatioZero() public {
        uint48 futureTimestamp = uint48(block.timestamp + 1);
        _storeSlot4(address(oracleHarness), 1, futureTimestamp, 1);
        _storeSlot5(address(oracleHarness), 100, 0, 0, 0);

        assertFalse(oracleHarness.isCapped());
    }

    function testPriceCapApplied() public {
        oracle.setGrowthCapBounds(500);
        shares.setRatio(1.05e18);
        oracle.updateSnapshot();
        vm.warp(block.timestamp + 3600);
        vm.warp(block.timestamp + 7 days);

        shares.setRatio(10e18);
        baseAgg.setAnswer(2000e8);

        int256 answer = oracle.latestAnswer();
        assertEq(answer, 0);
    }

    function testPriceClampsToHardCapWithinRejectionGrace() public {
        oracle.setGrowthCapBounds(100);
        oracle.setRejectionGraceBps(100);
        shares.setRatio(1e18);
        uint256 snapshotTs = block.timestamp;
        oracle.updateSnapshot();

        vm.warp(snapshotTs + 30 days);
        uint256 elapsed = block.timestamp - snapshotTs;
        uint256 growthRate = (uint256(1e18) * 100 * 1e18) / (10000 * 365 days);
        uint256 maxRatio = 1e18 + ((growthRate * elapsed) / 1e18);
        assertGt(maxRatio, 0);

        uint256 withinGraceRatio = (maxRatio * 10050) / 10000; // 0.50% above hard cap, within 1.00% rejection grace
        shares.setRatio(withinGraceRatio);
        baseAgg.setAnswer(2000e8);

        int256 expected = int256((uint256(2000e8) * maxRatio) / 1e18);
        int256 answer = oracle.latestAnswer();
        assertEq(answer, expected);
        assertTrue(oracle.isCapped());
    }

    function testLatestRoundDataClampsToHardCapWithinRejectionGrace() public {
        oracle.setGrowthCapBounds(100);
        oracle.setRejectionGraceBps(100);
        shares.setRatio(1e18);
        uint256 snapshotTs = block.timestamp;
        oracle.updateSnapshot();

        vm.warp(snapshotTs + 30 days);
        uint256 elapsed = block.timestamp - snapshotTs;
        uint256 growthRate = (uint256(1e18) * 100 * 1e18) / (10000 * 365 days);
        uint256 maxRatio = 1e18 + ((growthRate * elapsed) / 1e18);
        assertGt(maxRatio, 0);

        uint256 withinGraceRatio = (maxRatio * 10050) / 10000; // 0.50% above hard cap, within 1.00% rejection grace
        shares.setRatio(withinGraceRatio);
        baseAgg.setAnswer(2000e8);

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = oracle.latestRoundData();
        int256 expected = int256((uint256(2000e8) * maxRatio) / 1e18);
        assertEq(answer, expected);
        assertEq(roundId, 2);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, 2);
        assertTrue(oracle.isCapped());
    }

    function testPriceRejectsBeyondHardCapPlusRejectionGrace() public {
        oracle.setGrowthCapBounds(100);
        oracle.setRejectionGraceBps(100);
        shares.setRatio(1e18);
        uint256 snapshotTs = block.timestamp;
        oracle.updateSnapshot();

        vm.warp(snapshotTs + 30 days);
        uint256 elapsed = block.timestamp - snapshotTs;
        uint256 growthRate = (uint256(1e18) * 100 * 1e18) / (10000 * 365 days);
        uint256 maxRatio = 1e18 + ((growthRate * elapsed) / 1e18);
        assertGt(maxRatio, 0);

        uint256 beyondGraceRatio = (maxRatio * 10101) / 10000; // 1.01% above hard cap, outside 1.00% rejection grace
        shares.setRatio(beyondGraceRatio);
        baseAgg.setAnswer(2000e8);

        assertTrue(oracle.isCapped());
        assertEq(oracle.latestAnswer(), 0);
        vm.expectRevert(IYieldBearingOracleAdapter.InvalidSharesConversion.selector);
        oracle.latestRoundData();
    }

    function testLatestAnswerReturnsZeroWhenMaxRatioIsZero() public {
        _storeSlot4(address(oracleHarness), 1, uint48(block.timestamp + 1), 1);
        _storeSlot5(address(oracleHarness), 100, 0, 0, 0);

        int256 answer = oracleHarness.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestAnswerReturnsZeroWhenGraceCapOverflowFailsSafe() public {
        uint256 hugeTimestamp = uint256(1) << 211;
        vm.warp(hugeTimestamp);

        _storeSlot4(address(oracleHarness), 1, 0, type(uint104).max);
        _storeSlot5(address(oracleHarness), 100, 0, 0, 10000);

        baseAgg.setAnswer(2000e8);
        vm.mockCall(
            address(shares),
            abi.encodeWithSelector(IERC4626.convertToAssets.selector, uint256(1e18)),
            abi.encode(type(uint256).max)
        );

        uint256 maxAllowed = oracleHarness.calculateMaxRatio();
        assertGt(maxAllowed, uint256(1) << 255);

        int256 answer = oracleHarness.latestAnswer();
        assertEq(answer, 0);
    }

    function testLatestRoundDataCapsRatioWhenOverMax() public {
        oracle.setGrowthCapBounds(100);
        shares.setRatio(1e18);
        oracle.updateSnapshot();
        vm.warp(block.timestamp + 3600);
        vm.warp(block.timestamp + 29 days);
        baseAgg.setTimestamp(block.timestamp);
        shares.setRatio(5e18);
        vm.expectRevert();
        oracle.latestRoundData();
    }

    function testPriceNotCappedWhenUnderLimit() public {
        oracle.setGrowthCapBounds(500);
        shares.setRatio(1.05e18);
        oracle.updateSnapshot();

        int256 answer = oracle.latestAnswer();
        assertEq(answer, 2100e8);
    }

    function testGetCurrentSlackBpsNoSnapshot() public view {
        (uint256 slackBps, bool ok) = oracle.getCurrentSlackBps();
        assertEq(slackBps, 0);
        assertFalse(ok);
    }

    function testGetCurrentSlackBpsReturnsFalseOnRevertingShares() public {
        MockERC4626ToggleConvertToAssets toggleShares = new MockERC4626ToggleConvertToAssets(address(asset), 18);
        YieldBearingOracleAdapter revertOracle = new YieldBearingOracleAdapter(
            address(baseAgg), address(toggleShares), 1 hours, 1 hours, 30 days, 0, "Test"
        );
        revertOracle.setGrowthCapBounds(500);
        toggleShares.setRatio(1.05e18);
        revertOracle.updateSnapshot();
        toggleShares.setRevertConvert(true);

        (uint256 slackBps, bool ok) = revertOracle.getCurrentSlackBps();
        assertEq(slackBps, 0);
        assertFalse(ok);
    }

    function testGetCurrentSlackBpsReturnsFalseWhenMaxRatioZero() public {
        uint48 futureTimestamp = uint48(block.timestamp + 1);
        _storeSlot4(address(oracleHarness), 1, futureTimestamp, 1);
        _storeSlot5(address(oracleHarness), 100, 0, 0, 0);

        (uint256 slackBps, bool ok) = oracleHarness.getCurrentSlackBps();
        assertEq(slackBps, 0);
        assertFalse(ok);
    }

    function testGetCurrentSlackBpsUnderCap() public {
        oracle.setGrowthCapBounds(1000);
        shares.setRatio(1.0e18);
        oracle.updateSnapshot();
        vm.warp(block.timestamp + 10 days);

        shares.setRatio(1.002e18);
        (uint256 slackBps, bool ok) = oracle.getCurrentSlackBps();
        assertTrue(ok);
        assertGt(slackBps, 0);
    }

    function testGetCurrentSlackBpsOverCap() public {
        oracle.setGrowthCapBounds(500);
        shares.setRatio(1.05e18);
        oracle.updateSnapshot();
        vm.warp(block.timestamp + 7 days);

        shares.setRatio(10e18);
        (uint256 slackBps, bool ok) = oracle.getCurrentSlackBps();
        assertTrue(ok);
        assertEq(slackBps, 0);
    }

    function testGetCurrentSlackBpsReturnsFalseOnZeroRatio() public {
        oracle.setGrowthCapBounds(500);
        shares.setRatio(1.05e18);
        oracle.updateSnapshot();

        shares.setRatio(0);
        (uint256 slackBps, bool ok) = oracle.getCurrentSlackBps();
        assertEq(slackBps, 0);
        assertFalse(ok);
    }

    function testCalculateMaxRatioReturnsZeroWhenPendingGrowthRateOverflows() public {
        _storeSlot4(address(oracleHarness), 0, 0, 0);
        _storeSlot5(address(oracleHarness), 10000, type(uint104).max, uint48(block.timestamp), 0);

        uint256 maxRatio = oracleHarness.calculateMaxRatio();
        assertEq(maxRatio, 0);
    }

    function testCalculateMaxRatioReturnsZeroOnGrowthMulOverflow() public {
        uint256 hugeTimestamp = 5708990770823839524233143877798262020507697152000000000000000014;
        _storeSlot4(address(oracleHarness), type(uint104).max, 0, type(uint104).max);
        _storeSlot5(address(oracleHarness), 100, 0, 0, 0);

        vm.warp(hugeTimestamp);
        uint256 maxRatio = oracleHarness.calculateMaxRatio();
        assertEq(maxRatio, 0);
    }

    function testCalculateMaxRatioReturnsZeroOnAdditionOverflow() public {
        uint256 hugeTimestamp = 5708990770823839524233143877798262020507697151000000000000000014;
        _storeSlot4(address(oracleHarness), type(uint104).max, 0, type(uint104).max);
        _storeSlot5(address(oracleHarness), 100, 0, 0, 0);

        vm.warp(hugeTimestamp);
        uint256 maxRatio = oracleHarness.calculateMaxRatio();
        assertEq(maxRatio, 0);
    }

    function testSetKeeperAsOwner() public {
        oracle.setKeeper(keeper);
        assertEq(oracle.keeper(), keeper);
    }

    function testSetKeeperToZeroAddress() public {
        oracle.setKeeper(address(0));
        assertEq(oracle.keeper(), address(0));
    }

    function testSetKeeperToContractAddress() public {
        vm.expectRevert();
        oracle.setKeeper(address(oracle));
    }

    function testSetKeeperToOwner() public {
        vm.expectRevert();
        oracle.setKeeper(owner);
    }

    function testSetKeeperUnauthorized() public {
        vm.prank(user);
        vm.expectRevert();
        oracle.setKeeper(keeper);
    }

    function testRenounceOwnershipReverts() public {
        vm.expectRevert();
        oracle.renounceOwnership();
    }

    function testTransferOwnership() public {
        oracle.transferOwnership(user);
        assertEq(oracle.pendingOwner(), user);

        vm.prank(user);
        oracle.acceptOwnership();
        assertEq(oracle.owner(), user);
    }

    function testZeroSharesConversion() public {
        shares.setRatio(0);
        int256 answer = oracle.latestAnswer();
        assertEq(answer, 0);
    }

    function testNoMaxDelay() public {
        YieldBearingOracleAdapter oracleNoDelay =
            new YieldBearingOracleAdapter(address(baseAgg), address(shares), 0, 1 hours, 30 days, 0, "Test");

        vm.warp(block.timestamp + 365 days);
        int256 answer = oracleNoDelay.latestAnswer();
        assertEq(answer, 2100e8);
    }

    function testDecimalScaling() public {
        MockAggregator base6 = new MockAggregator(2000e6, 6);
        MockERC20 asset6 = new MockERC20("Asset6", "A6", 6);
        MockERC4626 shares6 = new MockERC4626(address(asset6), 6);

        YieldBearingOracleAdapter oracle6 =
            new YieldBearingOracleAdapter(address(base6), address(shares6), 1 hours, 1 hours, 30 days, 0, "Test");

        int256 answer = oracle6.latestAnswer();
        assertEq(answer, 2100e8);
    }

    function testIsFreshWithZeroTimestampReturnsFalse() public view {
        assertFalse(oracleHarness.isFresh(0));
    }

    function testCalculateMaxRatioViewWithoutSnapshot() public view {
        assertEq(oracleHarness.calculateMaxRatio(), 0);
    }

    function testTryComputeGrowthRateOverflow() public view {
        (uint104 rate, bool ok) = oracleHarness.tryComputeGrowthRate(type(uint104).max, 10000);
        assertFalse(ok);
        assertEq(rate, 0);
    }
}
