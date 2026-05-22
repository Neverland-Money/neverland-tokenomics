// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {OracleLib} from "../../src/libraries/OracleLib.sol";
import {IYieldBearingOracleAdapter} from "../../src/interfaces/IYieldBearingOracleAdapter.sol";
import {YieldBearingOracleAdapter} from "../../src/oracles/YieldBearingOracleAdapter.sol";
import {RatioOracleAggregator} from "../../src/oracles/RatioOracleAggregator.sol";

contract PropMockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }
}

contract PropMockAggregator is AggregatorV3Interface {
    int256 private _answer;
    uint8 private _decimals;
    uint80 private _roundId;
    uint80 private _answeredInRound;
    uint256 private _startedAt;
    uint256 private _updatedAt;

    constructor(int256 answer_, uint8 decimals_) {
        _answer = answer_;
        _decimals = decimals_;
        _roundId = 1;
        _answeredInRound = 1;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
    }

    function setAnswer(int256 answer_) external {
        _answer = answer_;
        if (_roundId < type(uint80).max) {
            _roundId++;
        }
        _answeredInRound = _roundId;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
    }

    function setRoundData(
        int256 answer_,
        uint80 roundId_,
        uint256 startedAt_,
        uint256 updatedAt_,
        uint80 answeredInRound_
    ) external {
        _answer = answer_;
        _roundId = roundId_;
        _startedAt = startedAt_;
        _updatedAt = updatedAt_;
        _answeredInRound = answeredInRound_;
    }

    function answer() external view returns (int256) {
        return _answer;
    }

    function roundId() external view returns (uint80) {
        return _roundId;
    }

    function startedAtValue() external view returns (uint256) {
        return _startedAt;
    }

    function updatedAtValue() external view returns (uint256) {
        return _updatedAt;
    }

    function answeredInRoundValue() external view returns (uint80) {
        return _answeredInRound;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "Property Mock Aggregator";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80)
        external
        view
        returns (uint80 roundId_, int256 answer_, uint256 startedAt_, uint256 updatedAt_, uint80 answeredInRound_)
    {
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId_, int256 answer_, uint256 startedAt_, uint256 updatedAt_, uint80 answeredInRound_)
    {
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }

    function latestAnswer() external view returns (int256) {
        return _answer;
    }

    function latestTimestamp() external view returns (uint256) {
        return _updatedAt;
    }

    function latestRound() external view returns (uint256) {
        return _roundId;
    }

    function getAnswer(uint256) external view returns (int256) {
        return _answer;
    }

    function getTimestamp(uint256) external view returns (uint256) {
        return _updatedAt;
    }
}

contract PropMockERC4626 is IERC4626 {
    address private _asset;
    uint8 private _decimals;
    uint256 private _ratio;
    bool private _revertConvert;

    constructor(address asset_, uint8 decimals_) {
        _asset = asset_;
        _decimals = decimals_;
        _ratio = 1e18;
    }

    function setRatio(uint256 ratio_) external {
        _ratio = ratio_;
    }

    function setRevertConvert(bool shouldRevert) external {
        _revertConvert = shouldRevert;
    }

    function ratio() external view returns (uint256) {
        return _ratio;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        if (_revertConvert) revert("CONVERT_REVERT");
        if (_ratio == 0) return 0;
        return (shares * _ratio) / 1e18;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return (assets * 1e18) / _ratio;
    }

    function totalAssets() external pure returns (uint256) {
        return type(uint256).max;
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
        return type(uint256).max;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function allowance(address, address) external pure returns (uint256) {
        return type(uint256).max;
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
        return "Property Mock Vault";
    }

    function symbol() external pure returns (string memory) {
        return "PMV";
    }
}

contract YieldAdapterInvariantHandler is Test {
    YieldBearingOracleAdapter public oracle;
    PropMockAggregator public feed;
    PropMockERC4626 public vault;

    constructor() {
        PropMockERC20 asset = new PropMockERC20("Asset", "AST", 18);
        vault = new PropMockERC4626(address(asset), 18);
        feed = new PropMockAggregator(2_000e8, 8);

        oracle = new YieldBearingOracleAdapter(
            address(feed), address(vault), 1 days, 1 hours, 30 days, 100, "loAZND/USD via vault shares"
        );
        oracle.setGrowthCapBounds(1_000);
        oracle.updateSnapshotImmediate();
    }

    function actionSetBasePrice(int256 rawBasePrice) external {
        int256 bounded = rawBasePrice;
        int256 maxAbs = 1e20;
        if (bounded > maxAbs) bounded = maxAbs;
        if (bounded < -maxAbs) bounded = -maxAbs;
        feed.setAnswer(bounded);
    }

    function actionSetRatio(uint256 rawRatio) external {
        vault.setRatio(bound(rawRatio, 0, type(uint104).max));
    }

    function actionWarp(uint32 rawDelta) external {
        uint256 delta = bound(uint256(rawDelta), 0, 7 days);
        vm.warp(block.timestamp + delta);
    }

    function actionSetRoundMetadata(
        uint80 rawRoundId,
        uint80 rawAnsweredInRound,
        uint32 rawStartedOffset,
        uint32 rawUpdatedOffset,
        uint8 mode
    ) external {
        uint256 nowTs = block.timestamp;
        uint80 roundId = rawRoundId == 0 ? 1 : rawRoundId;
        uint256 startedAt = _backdate(nowTs, bound(uint256(rawStartedOffset), 0, 3 days));
        uint256 updatedAt = _backdate(nowTs, bound(uint256(rawUpdatedOffset), 0, 3 days));

        uint8 normalizedMode = mode % 6;
        if (normalizedMode == 1) {
            // Stale.
            updatedAt = _backdate(nowTs, 1 days + bound(uint256(rawUpdatedOffset), 1, 3 days));
        } else if (normalizedMode == 2) {
            // Future timestamp.
            updatedAt = nowTs + bound(uint256(rawUpdatedOffset), 1, 1 days);
        } else if (normalizedMode == 3) {
            // startedAt after updatedAt.
            updatedAt = _backdate(nowTs, bound(uint256(rawUpdatedOffset), 0, 1 days));
            startedAt = updatedAt + 1 + bound(uint256(rawStartedOffset), 0, 1 days);
        } else if (normalizedMode == 4) {
            // Zero round id.
            roundId = 0;
        } else if (normalizedMode == 5) {
            // Zero timestamp.
            startedAt = 0;
            updatedAt = 0;
        }

        feed.setRoundData(feed.answer(), roundId, startedAt, updatedAt, rawAnsweredInRound);
    }

    function actionSetGrowthBps(uint16 rawBps) external {
        uint16 bps = uint16(bound(uint256(rawBps), 1, 10_000));
        try oracle.setGrowthCapBounds(bps) {} catch {}
    }

    function actionSetRejectionGraceBps(uint16 rawBps) external {
        uint16 bps = uint16(bound(uint256(rawBps), 0, 10_000));
        try oracle.setRejectionGraceBps(bps) {} catch {}
    }

    function actionUpdateSnapshot(uint8 mode) external {
        if ((mode & 1) == 0) {
            try oracle.updateSnapshot() {} catch {}
        } else {
            try oracle.updateSnapshotImmediate() {} catch {}
        }
    }

    function actionToggleConvertRevert(bool shouldRevert) external {
        vault.setRevertConvert(shouldRevert);
    }

    function _backdate(uint256 nowTs, uint256 delta) internal pure returns (uint256) {
        return delta > nowTs ? 0 : nowTs - delta;
    }
}

contract YieldOracleInvariantTest is StdInvariant, Test {
    YieldAdapterInvariantHandler internal handler;
    YieldBearingOracleAdapter internal oracle;
    PropMockAggregator internal feed;
    PropMockERC4626 internal vault;

    function setUp() public {
        handler = new YieldAdapterInvariantHandler();
        oracle = handler.oracle();
        feed = handler.feed();
        vault = handler.vault();

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.actionSetBasePrice.selector;
        selectors[1] = handler.actionSetRatio.selector;
        selectors[2] = handler.actionWarp.selector;
        selectors[3] = handler.actionSetRoundMetadata.selector;
        selectors[4] = handler.actionSetGrowthBps.selector;
        selectors[5] = handler.actionSetRejectionGraceBps.selector;
        selectors[6] = handler.actionUpdateSnapshot.selector;
        selectors[7] = handler.actionToggleConvertRevert.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_latestAnswerNeverNegative() public view {
        assertGe(oracle.latestAnswer(), 0);
    }

    function invariant_positiveLegacyHasRoundAndTimestamp() public view {
        int256 answer = oracle.latestAnswer();
        if (answer > 0) {
            assertGt(oracle.latestRound(), 0);
            assertGt(oracle.latestTimestamp(), 0);
        }
    }

    function invariant_strictDataConsistentWhenAvailable() public view {
        try oracle.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
        ) {
            startedAt;
            answeredInRound;
            assertGt(roundId, 0);
            assertGt(answer, 0);
            assertLe(updatedAt, block.timestamp);
            if (oracle.maxDelay() > 0) {
                assertLe(block.timestamp - updatedAt, oracle.maxDelay());
            }
            assertEq(oracle.latestAnswer(), answer);
        } catch {}
    }

    function invariant_slackAndCappedConsistency() public view {
        (uint256 slackBps, bool ok) = oracle.getCurrentSlackBps();
        if (ok) {
            assertLe(slackBps, 10_000);
            if (oracle.isCapped()) assertEq(slackBps, 0);
        }
    }

    function invariant_strictPriceRespectsHardCapWhenConfigured() public view {
        try oracle.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
        ) {
            roundId;
            startedAt;
            updatedAt;
            answeredInRound;
            uint256 snapshotRatio = oracle.getSnapshotRatio();
            uint256 snapshotTs = oracle.getSnapshotTimestamp();
            uint256 growthRate = oracle.getGrowthRatePerSecond();
            uint256 maxAnnualGrowthBps = oracle.getMaxAnnualGrowthBps();
            if (snapshotRatio == 0 || maxAnnualGrowthBps == 0 || snapshotTs > block.timestamp) return;

            (uint256 allowedGrowth, bool okGrowth) =
                OracleLib.tryMulDiv(growthRate, block.timestamp - snapshotTs, uint256(1e18));
            if (!okGrowth || snapshotRatio > type(uint256).max - allowedGrowth) return;
            uint256 maxAllowedRatio = snapshotRatio + allowedGrowth;

            int256 basePrice = feed.answer();
            if (basePrice <= 0) return;

            (uint256 capPrice, bool okCapPrice) =
                OracleLib.tryMulDiv(uint256(basePrice), maxAllowedRatio, uint256(1e18));
            if (!okCapPrice || capPrice > uint256(type(int256).max)) return;

            assertLe(uint256(answer), capPrice);
            // If above hard cap is accepted, it must still be clamped to hard cap.
            if (vault.ratio() > maxAllowedRatio) {
                assertEq(uint256(answer), capPrice);
            }
        } catch {}
    }
}

contract RatioInvariantHandler is Test {
    RatioOracleAggregator public oracle;
    PropMockAggregator public ratioFeed;
    PropMockAggregator public baseFeed;

    constructor() {
        ratioFeed = new PropMockAggregator(1e8, 8);
        baseFeed = new PropMockAggregator(2_000e8, 8);
        oracle = new RatioOracleAggregator(address(ratioFeed), address(baseFeed), 1 days);
    }

    function actionSetRatioPrice(int256 rawPrice) external {
        int256 bounded = rawPrice;
        int256 maxAbs = 1e20;
        if (bounded > maxAbs) bounded = maxAbs;
        if (bounded < -maxAbs) bounded = -maxAbs;
        ratioFeed.setAnswer(bounded);
    }

    function actionSetBasePrice(int256 rawPrice) external {
        int256 bounded = rawPrice;
        int256 maxAbs = 1e20;
        if (bounded > maxAbs) bounded = maxAbs;
        if (bounded < -maxAbs) bounded = -maxAbs;
        baseFeed.setAnswer(bounded);
    }

    function actionWarp(uint32 rawDelta) external {
        uint256 delta = bound(uint256(rawDelta), 0, 7 days);
        vm.warp(block.timestamp + delta);
    }

    function actionSetRatioRoundMetadata(
        uint80 rawRoundId,
        uint80 rawAnsweredInRound,
        uint32 rawStartedOffset,
        uint32 rawUpdatedOffset,
        uint8 mode
    ) external {
        _setMetadata(ratioFeed, rawRoundId, rawAnsweredInRound, rawStartedOffset, rawUpdatedOffset, mode);
    }

    function actionSetBaseRoundMetadata(
        uint80 rawRoundId,
        uint80 rawAnsweredInRound,
        uint32 rawStartedOffset,
        uint32 rawUpdatedOffset,
        uint8 mode
    ) external {
        _setMetadata(baseFeed, rawRoundId, rawAnsweredInRound, rawStartedOffset, rawUpdatedOffset, mode);
    }

    function _setMetadata(
        PropMockAggregator feed,
        uint80 rawRoundId,
        uint80 rawAnsweredInRound,
        uint32 rawStartedOffset,
        uint32 rawUpdatedOffset,
        uint8 mode
    ) internal {
        uint256 nowTs = block.timestamp;
        uint80 roundId = rawRoundId == 0 ? 1 : rawRoundId;
        uint256 startedAt = _backdate(nowTs, bound(uint256(rawStartedOffset), 0, 3 days));
        uint256 updatedAt = _backdate(nowTs, bound(uint256(rawUpdatedOffset), 0, 3 days));
        uint8 normalizedMode = mode % 6;

        if (normalizedMode == 1) {
            updatedAt = _backdate(nowTs, 1 days + bound(uint256(rawUpdatedOffset), 1, 3 days));
        } else if (normalizedMode == 2) {
            updatedAt = nowTs + bound(uint256(rawUpdatedOffset), 1, 1 days);
        } else if (normalizedMode == 3) {
            updatedAt = _backdate(nowTs, bound(uint256(rawUpdatedOffset), 0, 1 days));
            startedAt = updatedAt + 1 + bound(uint256(rawStartedOffset), 0, 1 days);
        } else if (normalizedMode == 4) {
            roundId = 0;
        } else if (normalizedMode == 5) {
            startedAt = 0;
            updatedAt = 0;
        }

        feed.setRoundData(feed.answer(), roundId, startedAt, updatedAt, rawAnsweredInRound);
    }

    function _backdate(uint256 nowTs, uint256 delta) internal pure returns (uint256) {
        return delta > nowTs ? 0 : nowTs - delta;
    }
}

contract RatioOracleInvariantTest is StdInvariant, Test {
    RatioInvariantHandler internal handler;
    RatioOracleAggregator internal oracle;
    PropMockAggregator internal ratioFeed;
    PropMockAggregator internal baseFeed;

    function setUp() public {
        handler = new RatioInvariantHandler();
        oracle = handler.oracle();
        ratioFeed = handler.ratioFeed();
        baseFeed = handler.baseFeed();

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.actionSetRatioPrice.selector;
        selectors[1] = handler.actionSetBasePrice.selector;
        selectors[2] = handler.actionWarp.selector;
        selectors[3] = handler.actionSetRatioRoundMetadata.selector;
        selectors[4] = handler.actionSetBaseRoundMetadata.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_ratioLivenessSymmetry() public view {
        try oracle.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
        ) {
            startedAt;
            answeredInRound;
            assertGt(roundId, 0);
            assertGt(answer, 0);
            assertLe(updatedAt, block.timestamp);
            if (_lenientMetadataOk()) {
                assertEq(oracle.latestAnswer(), answer);
                assertEq(oracle.latestRound(), uint256(roundId));
                assertEq(oracle.latestTimestamp(), updatedAt);
            }
        } catch {}
    }

    function _lenientMetadataOk() internal view returns (bool) {
        (
            uint80 ratioRoundId,
            int256 ratioAnswer,
            uint256 ratioStartedAt,
            uint256 ratioUpdatedAt,
            uint80 ratioAnsweredInRound
        ) = ratioFeed.latestRoundData();
        (
            uint80 baseRoundId,
            int256 baseAnswer,
            uint256 baseStartedAt,
            uint256 baseUpdatedAt,
            uint80 baseAnsweredInRound
        ) = baseFeed.latestRoundData();

        return ratioStartedAt <= ratioUpdatedAt && (ratioAnsweredInRound == 0 || ratioAnsweredInRound >= ratioRoundId)
            && baseStartedAt <= baseUpdatedAt && (baseAnsweredInRound == 0 || baseAnsweredInRound >= baseRoundId)
            && ratioAnswer > 0 && baseAnswer > 0;
    }
}

contract OraclePropertyFuzzTest is Test {
    YieldBearingOracleAdapter internal yieldOracle;
    PropMockAggregator internal yieldBaseFeed;
    PropMockERC4626 internal yieldVault;

    RatioOracleAggregator internal ratioOracle;
    PropMockAggregator internal ratioFeed;
    PropMockAggregator internal ratioBaseFeed;

    function setUp() public {
        vm.warp(100 days);

        PropMockERC20 asset = new PropMockERC20("Asset", "AST", 18);
        yieldVault = new PropMockERC4626(address(asset), 18);
        yieldBaseFeed = new PropMockAggregator(2_000e8, 8);
        yieldOracle = new YieldBearingOracleAdapter(
            address(yieldBaseFeed), address(yieldVault), 1 days, 1 hours, 30 days, 100, "loAZND/USD via vault shares"
        );
        yieldOracle.setGrowthCapBounds(1_000);
        yieldOracle.updateSnapshotImmediate();

        ratioFeed = new PropMockAggregator(1e8, 8);
        ratioBaseFeed = new PropMockAggregator(2_000e8, 8);
        ratioOracle = new RatioOracleAggregator(address(ratioFeed), address(ratioBaseFeed), 1 days);
    }

    function testFuzz_YieldLatestAnswerNeverNegative(int256 rawBasePrice, uint256 rawRatio) public {
        int256 basePrice = _boundSigned(rawBasePrice, -1e20, 1e20);
        uint256 ratio = bound(rawRatio, 0, type(uint104).max);

        yieldBaseFeed.setRoundData(basePrice, 1, block.timestamp, block.timestamp, 1);
        yieldVault.setRatio(ratio);

        int256 answer = yieldOracle.latestAnswer();
        assertGe(answer, 0);
    }

    function testFuzz_YieldStrictMatchesLegacyOnValidInputs(
        uint96 rawBasePrice,
        uint96 rawRatio,
        uint16 rawGrowthBps,
        uint16 rawGraceBps,
        uint32 rawElapsed
    ) public {
        uint256 basePrice = bound(uint256(rawBasePrice), 1e8, 1e20);
        uint256 ratio = bound(uint256(rawRatio), 1e18, 5e18);
        uint16 growthBps = uint16(bound(uint256(rawGrowthBps), 1, 10_000));
        uint16 graceBps = uint16(bound(uint256(rawGraceBps), 0, 10_000));
        uint256 elapsed = bound(uint256(rawElapsed), 0, 3 days);

        yieldOracle.setGrowthCapBounds(growthBps);
        yieldOracle.setRejectionGraceBps(graceBps);
        yieldVault.setRatio(ratio);
        yieldOracle.updateSnapshotImmediate();

        vm.warp(block.timestamp + elapsed);
        yieldBaseFeed.setRoundData(int256(basePrice), 2, block.timestamp, block.timestamp, 2);
        yieldVault.setRatio(ratio);

        int256 legacy = yieldOracle.latestAnswer();
        (, int256 strictAnswer,,,) = yieldOracle.latestRoundData();

        assertEq(legacy, strictAnswer);
        assertGt(strictAnswer, 0);
    }

    function testFuzz_YieldRoundingIsConservativeUnderCap(uint96 rawBasePrice, uint96 rawRatio) public {
        uint256 basePrice = bound(uint256(rawBasePrice), 1e8, 1e20);
        uint256 ratio = bound(uint256(rawRatio), 1e18, 5e18);

        yieldOracle.setGrowthCapBounds(10_000);
        yieldOracle.setRejectionGraceBps(0);
        yieldVault.setRatio(ratio);
        yieldOracle.updateSnapshotImmediate();
        yieldBaseFeed.setRoundData(int256(basePrice), 9, block.timestamp, block.timestamp, 9);

        (, int256 strictAnswer,,,) = yieldOracle.latestRoundData();

        uint256 product = basePrice * ratio;
        uint256 quotient = product / 1e18;
        uint256 remainder = product % 1e18;
        assertEq(uint256(strictAnswer), quotient);
        if (remainder > 0) {
            assertLt(uint256(strictAnswer) * 1e18, product);
        }
    }

    function testFuzz_YieldWithinGraceClampsToHardCap(
        uint96 rawBasePrice,
        uint16 rawGrowthBps,
        uint16 rawGraceBps,
        uint32 rawElapsed,
        uint16 rawOverBps
    ) public {
        uint256 basePrice = bound(uint256(rawBasePrice), 1, 1e20);
        uint16 growthBps = uint16(bound(uint256(rawGrowthBps), 1, 3_000));
        uint16 graceBps = uint16(bound(uint256(rawGraceBps), 1, 2_000));
        uint256 elapsed = bound(uint256(rawElapsed), 1 hours, 30 days);

        yieldOracle.setGrowthCapBounds(growthBps);
        yieldOracle.setRejectionGraceBps(graceBps);
        yieldVault.setRatio(1e18);
        yieldOracle.updateSnapshotImmediate();

        vm.warp(block.timestamp + elapsed);
        uint256 maxAllowedRatio = _currentMaxAllowedRatio(yieldOracle);
        uint256 overBps = bound(uint256(rawOverBps), 1, uint256(graceBps));
        uint256 ratio = (maxAllowedRatio * (10_000 + overBps)) / 10_000;
        yieldVault.setRatio(ratio);
        yieldBaseFeed.setRoundData(int256(basePrice), 3, block.timestamp, block.timestamp, 3);

        (uint256 expected, bool ok) = OracleLib.tryMulDiv(basePrice, maxAllowedRatio, uint256(1e18));
        assertTrue(ok);

        int256 legacy = yieldOracle.latestAnswer();
        (, int256 strictAnswer,,,) = yieldOracle.latestRoundData();
        assertEq(legacy, int256(expected));
        assertEq(strictAnswer, int256(expected));
        assertTrue(yieldOracle.isCapped());
    }

    function testFuzz_YieldBeyondGraceRejects(
        uint96 rawBasePrice,
        uint16 rawGrowthBps,
        uint16 rawGraceBps,
        uint32 rawElapsed,
        uint16 rawOverBps
    ) public {
        uint256 basePrice = bound(uint256(rawBasePrice), 1, 1e20);
        uint16 growthBps = uint16(bound(uint256(rawGrowthBps), 1, 3_000));
        uint16 graceBps = uint16(bound(uint256(rawGraceBps), 0, 2_000));
        uint256 elapsed = bound(uint256(rawElapsed), 1 hours, 30 days);

        yieldOracle.setGrowthCapBounds(growthBps);
        yieldOracle.setRejectionGraceBps(graceBps);
        yieldVault.setRatio(1e18);
        yieldOracle.updateSnapshotImmediate();

        vm.warp(block.timestamp + elapsed);
        uint256 maxAllowedRatio = _currentMaxAllowedRatio(yieldOracle);
        uint256 overBps = bound(uint256(rawOverBps), uint256(graceBps) + 1, uint256(graceBps) + 1_000);
        uint256 ratio = (maxAllowedRatio * (10_000 + overBps)) / 10_000;
        yieldVault.setRatio(ratio);
        yieldBaseFeed.setRoundData(int256(basePrice), 4, block.timestamp, block.timestamp, 4);

        assertEq(yieldOracle.latestAnswer(), 0);
        vm.expectRevert(IYieldBearingOracleAdapter.InvalidSharesConversion.selector);
        yieldOracle.latestRoundData();
        assertTrue(yieldOracle.isCapped());
    }

    function testFuzz_YieldMaxDelayBoundary(uint8 rawExtra) public {
        uint256 extra = bound(uint256(rawExtra), 0, 1);
        uint256 ts = block.timestamp - yieldOracle.maxDelay() - extra;
        yieldBaseFeed.setRoundData(2_000e8, 10, ts, ts, 10);
        yieldVault.setRatio(1e18);

        if (extra == 0) {
            (, int256 answer,, uint256 updatedAt,) = yieldOracle.latestRoundData();
            assertGt(answer, 0);
            assertEq(updatedAt, ts);
        } else {
            assertEq(yieldOracle.latestAnswer(), 0);
            vm.expectRevert();
            yieldOracle.latestRoundData();
        }
    }

    function testFuzz_YieldGraceThresholdBoundaryAcceptsThenRejects(
        uint96 rawBasePrice,
        uint16 rawGrowthBps,
        uint16 rawGraceBps,
        uint32 rawElapsed
    ) public {
        uint256 basePrice = bound(uint256(rawBasePrice), 1e8, 1e20);
        uint16 growthBps = uint16(bound(uint256(rawGrowthBps), 1, 3_000));
        uint16 graceBps = uint16(bound(uint256(rawGraceBps), 0, 2_000));
        uint256 elapsed = bound(uint256(rawElapsed), 1 hours, 30 days);

        yieldOracle.setGrowthCapBounds(growthBps);
        yieldOracle.setRejectionGraceBps(graceBps);
        yieldVault.setRatio(1e18);
        yieldOracle.updateSnapshotImmediate();

        vm.warp(block.timestamp + elapsed);
        uint256 maxAllowedRatio = _currentMaxAllowedRatio(yieldOracle);
        (uint256 graceCapRatio, bool okGrace) = OracleLib.tryMulDiv(maxAllowedRatio, 10_000 + graceBps, 10_000);
        assertTrue(okGrace);

        yieldBaseFeed.setRoundData(int256(basePrice), 11, block.timestamp, block.timestamp, 11);
        yieldVault.setRatio(graceCapRatio);
        (, int256 answerAtBoundary,,,) = yieldOracle.latestRoundData();

        (uint256 expectedCapPrice, bool okCap) = OracleLib.tryMulDiv(basePrice, maxAllowedRatio, 1e18);
        assertTrue(okCap);
        if (graceCapRatio > maxAllowedRatio) {
            assertEq(uint256(answerAtBoundary), expectedCapPrice);
        } else {
            (uint256 expectedAtBoundary, bool okBoundary) = OracleLib.tryMulDiv(basePrice, graceCapRatio, 1e18);
            assertTrue(okBoundary);
            assertEq(uint256(answerAtBoundary), expectedAtBoundary);
        }

        yieldVault.setRatio(graceCapRatio + 1);
        assertEq(yieldOracle.latestAnswer(), 0);
        vm.expectRevert(IYieldBearingOracleAdapter.InvalidSharesConversion.selector);
        yieldOracle.latestRoundData();
    }

    function testFuzz_RatioLatestAnswerNeverNegative(int256 rawRatio, int256 rawBasePrice) public {
        int256 ratioPrice = _boundSigned(rawRatio, -1e20, 1e20);
        int256 basePrice = _boundSigned(rawBasePrice, -1e20, 1e20);

        ratioFeed.setRoundData(ratioPrice, 1, block.timestamp, block.timestamp, 1);
        ratioBaseFeed.setRoundData(basePrice, 1, block.timestamp, block.timestamp, 1);

        int256 answer = ratioOracle.latestAnswer();
        assertGe(answer, 0);
    }

    function testFuzz_RatioStrictMatchesLegacyOnValidInputs(uint96 rawRatio, uint96 rawBasePrice) public {
        uint256 ratioPrice = bound(uint256(rawRatio), 1e8, 1e14);
        uint256 basePrice = bound(uint256(rawBasePrice), 1e8, 1e14);

        ratioFeed.setRoundData(int256(ratioPrice), 2, block.timestamp, block.timestamp, 2);
        ratioBaseFeed.setRoundData(int256(basePrice), 2, block.timestamp, block.timestamp, 2);

        int256 legacy = ratioOracle.latestAnswer();
        (, int256 strictAnswer,,,) = ratioOracle.latestRoundData();

        assertEq(legacy, strictAnswer);
        assertGt(strictAnswer, 0);
    }

    function testFuzz_RatioRoundingIsConservative(uint96 rawRatio, uint96 rawBasePrice) public {
        uint256 ratioPrice = bound(uint256(rawRatio), 1e8, 1e20);
        uint256 basePrice = bound(uint256(rawBasePrice), 1e8, 1e20);
        ratioFeed.setRoundData(int256(ratioPrice), 12, block.timestamp, block.timestamp, 12);
        ratioBaseFeed.setRoundData(int256(basePrice), 12, block.timestamp, block.timestamp, 12);

        (, int256 strictAnswer,,,) = ratioOracle.latestRoundData();
        uint256 product = ratioPrice * basePrice;
        uint256 quotient = product / 1e8;
        uint256 remainder = product % 1e8;
        assertEq(uint256(strictAnswer), quotient);
        if (remainder > 0) {
            assertLt(uint256(strictAnswer) * 1e8, product);
        }
    }

    function testFuzz_RatioMaxDelayBoundary(uint8 rawExtra) public {
        uint256 extra = bound(uint256(rawExtra), 0, 1);
        uint256 ts = block.timestamp - 1 days - extra;
        ratioFeed.setRoundData(1e8, 13, ts, ts, 13);
        ratioBaseFeed.setRoundData(2_000e8, 13, ts, ts, 13);

        if (extra == 0) {
            (, int256 answer,, uint256 updatedAt,) = ratioOracle.latestRoundData();
            assertGt(answer, 0);
            assertEq(updatedAt, ts);
        } else {
            assertEq(ratioOracle.latestAnswer(), 0);
            vm.expectRevert();
            ratioOracle.latestRoundData();
        }
    }

    function _currentMaxAllowedRatio(YieldBearingOracleAdapter oracle) internal view returns (uint256 maxAllowedRatio) {
        uint256 snapshotRatio = oracle.getSnapshotRatio();
        uint256 snapshotTimestamp = oracle.getSnapshotTimestamp();
        uint256 growthRate = oracle.getGrowthRatePerSecond();
        if (snapshotRatio == 0 || snapshotTimestamp > block.timestamp) return 0;

        (uint256 allowedGrowth, bool ok) =
            OracleLib.tryMulDiv(growthRate, block.timestamp - snapshotTimestamp, uint256(1e18));
        if (!ok || snapshotRatio > type(uint256).max - allowedGrowth) return 0;

        return snapshotRatio + allowedGrowth;
    }

    function _boundSigned(int256 value, int256 minValue, int256 maxValue) internal pure returns (int256) {
        if (value < minValue) return minValue;
        if (value > maxValue) return maxValue;
        return value;
    }
}
