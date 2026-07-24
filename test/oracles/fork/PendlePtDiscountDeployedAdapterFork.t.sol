// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Test} from "forge-std/Test.sol";

import {IPendlePtDiscountOracleAdapter} from "../../../src/interfaces/IPendlePtDiscountOracleAdapter.sol";

import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";

import {PendlePtDiscountOracleAdapter} from "../../../src/oracles/PendlePtDiscountOracleAdapter.sol";

/**
 * @title PendlePtDiscountDeployedAdapterFork
 * @author Neverland
 * @notice Fork checks for the deployed PT-AUSD-8OCT2026 discount oracle at its canonical Monad mainnet address.
 * @dev This complements PendlePtDiscountOracleFork, which deploys a fresh adapter for integration scenarios.
 *
 * Run:
 *   RUN_MAINNET_FORK_TESTS=true MAINNET_RPC=<rpc-url> \
 *     forge test --match-contract PendlePtDiscountDeployedAdapterFork -vvv
 */
contract PendlePtDiscountDeployedAdapterFork is Test {
    /*//////////////////////////////////////////////////////////////
                       MONAD MAINNET ADDRESSES (REAL)
    //////////////////////////////////////////////////////////////*/

    /// @dev Deployed PendlePtDiscountOracleAdapter-AUSD-1791417600.
    address internal constant DEPLOYED_ADAPTER = 0x1Df73A14709FeEAc83386fd1b8099dEc4B00f789;
    /// @dev Deployment/phase-1 owner recorded by the production handoff artifact.
    address internal constant EXPECTED_DEPLOYMENT_OWNER = 0x0000B06460777398083CB501793a4d6393900000;
    /// @dev Pendle market for the configured PT-AUSD-8OCT2026 reserve.
    address internal constant PT_AUSD_MARKET = 0x6f99CF00ee7290aE78a072Bb6910eF72D1129fE7;
    /// @dev Pendle PT-AUSD-8OCT2026 principal token.
    address internal constant PT_AUSD = 0x9FC74f8Ed616B5BaF52a170caa97d6d3898602d1;
    /// @dev PT standardized-yield token recorded by the live PT.
    address internal constant SY_AUSD = 0xBA3d60f5000f472aef947FB8020a3E6319F9a0B7;
    /// @dev Yield token paired with the configured PT in the live Pendle market.
    address internal constant YT_AUSD = 0xEdDeE9C0B56248d70A9BFdD103f8bD97C35DfD89;
    /// @dev AUSD underlying accounting asset recorded by the live SY.
    address internal constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    /// @dev Chainlink AUSD/USD aggregator.
    address internal constant AUSD_USD_FEED = 0xE20751C7B5867bCBef815ffc1b284c3f412a9e13;

    /// @dev Adapter deployment block from the Ignition journal.
    uint256 internal constant DEPLOYMENT_BLOCK = 83_885_504;
    /// @dev Deployment block timestamp from Monad mainnet.
    uint256 internal constant DEPLOYMENT_BLOCK_TIMESTAMP = 1_782_504_674;
    /// @dev Runtime bytecode hash for the deployed adapter at DEPLOYMENT_BLOCK.
    bytes32 internal constant EXPECTED_RUNTIME_CODE_HASH =
        0xce020453eef36780e8cc043f7c6ad3e4ab71ad539ed1716dfca4b620fe037740;
    /// @dev PT-AUSD-8OCT2026 maturity, cached by the deployed adapter.
    uint256 internal constant EXPECTED_MATURITY = 1_791_417_600;
    uint256 internal constant MAX_DELAY = 108_000;
    uint16 internal constant MAX_RATE_BPS = 4_000;
    uint16 internal constant RATE_BPS = 1_200;
    /// @dev Lower owner-governed rate used to prove permissioned retuning on a fork.
    uint16 internal constant UPDATED_RATE_BPS = 1_000;
    uint8 internal constant EXPECTED_FEED_DECIMALS = 8;
    uint8 internal constant EXPECTED_PT_DECIMALS = 6;
    /// @dev Pendle assetInfo type for a token asset.
    uint8 internal constant PENDLE_ASSET_TYPE_TOKEN = 0;

    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS_TO_WAD = 1e14;

    /**
     * @notice Compact round tuple used to avoid stack pressure in deployed-adapter coherence checks.
     * @param roundId Chainlink round ID.
     * @param answer Round answer.
     * @param startedAt Round start timestamp.
     * @param updatedAt Round update timestamp.
     * @param answeredInRound Round ID in which the answer was computed.
     */
    struct RoundData {
        uint80 roundId;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    /**
     * @notice Mirrors the adapter event for deployed-fork expectEmit assertions.
     * @param previousRatePerYear The previous annual discount rate in basis points.
     * @param newRatePerYear The new annual discount rate in basis points.
     */
    event DiscountRatePerYearUpdated(uint16 previousRatePerYear, uint16 newRatePerYear);

    string internal mainnetRpcUrl;

    PendlePtDiscountOracleAdapter internal adapter;

    function setUp() public {
        vm.skip(!vm.envOr("RUN_MAINNET_FORK_TESTS", false), "set RUN_MAINNET_FORK_TESTS=true to enable mainnet RPC");

        mainnetRpcUrl = vm.envString("MAINNET_RPC");
        uint256 forkId = vm.createFork(mainnetRpcUrl, DEPLOYMENT_BLOCK);
        vm.selectFork(forkId);
        assertEq(block.chainid, 143, "MAINNET_RPC must be Monad mainnet");
        assertEq(block.number, DEPLOYMENT_BLOCK, "deployment fork block mismatch");
        assertEq(block.timestamp, DEPLOYMENT_BLOCK_TIMESTAMP, "deployment fork timestamp mismatch");

        adapter = PendlePtDiscountOracleAdapter(DEPLOYED_ADAPTER);
        vm.label(DEPLOYED_ADAPTER, "Deployed PendlePtDiscountOracleAdapter");
        vm.label(PT_AUSD_MARKET, "Pendle PT-AUSD-8OCT2026 Market");
        vm.label(PT_AUSD, "PT-AUSD-8OCT2026");
        vm.label(SY_AUSD, "SY-AUSD");
        vm.label(YT_AUSD, "YT-AUSD-8OCT2026");
        vm.label(AUSD, "AUSD");
        vm.label(AUSD_USD_FEED, "AUSD/USD");
    }

    /*//////////////////////////////////////////////////////////////
                          1. DEPLOYED IDENTITY
    //////////////////////////////////////////////////////////////*/

    /// @notice The real adapter address must expose the runtime identity recorded in the handoff artifact.
    function test_deployedAdapter_identityMatchesHandoff() public view {
        assertGt(DEPLOYED_ADAPTER.code.length, 0, "deployed adapter has no code");
        assertEq(DEPLOYED_ADAPTER.codehash, EXPECTED_RUNTIME_CODE_HASH, "runtime codehash mismatch");
        assertEq(address(adapter), DEPLOYED_ADAPTER, "adapter address mismatch");
        assertEq(address(adapter.baseAggregator()), AUSD_USD_FEED, "base aggregator mismatch");
        assertEq(address(adapter.principalToken()), PT_AUSD, "principal token mismatch");
        assertEq(adapter.maturity(), EXPECTED_MATURITY, "maturity mismatch");
        assertEq(adapter.maxDelay(), MAX_DELAY, "maxDelay mismatch");
        assertEq(adapter.baseDecimals(), EXPECTED_FEED_DECIMALS, "base decimals mismatch");
        assertEq(adapter.maxDiscountRatePerYear(), MAX_RATE_BPS, "max rate mismatch");
        assertEq(adapter.discountRatePerYear(), RATE_BPS, "active rate mismatch");
        assertEq(adapter.description(), "PT-AUSD-8OCT2026 / USD", "description mismatch");
        assertEq(adapter.decimals(), 8, "answer decimals mismatch");
        assertEq(adapter.version(), 1, "version mismatch");
        assertEq(adapter.owner(), EXPECTED_DEPLOYMENT_OWNER, "owner mismatch");
        assertEq(adapter.pendingOwner(), address(0), "pending owner must be empty");

        assertEq(AggregatorV3Interface(AUSD_USD_FEED).decimals(), EXPECTED_FEED_DECIMALS, "feed decimals mismatch");
        assertEq(AggregatorV3Interface(AUSD_USD_FEED).description(), "AUSD / USD", "feed description mismatch");
        assertEq(IExpiry(PT_AUSD).expiry(), EXPECTED_MATURITY, "PT expiry mismatch");
        assertEq(IExpiry(PT_AUSD).SY(), SY_AUSD, "PT SY mismatch");
        assertEq(IDecimals(PT_AUSD).decimals(), EXPECTED_PT_DECIMALS, "PT decimals mismatch");
        assertEq(IDecimals(AUSD).decimals(), EXPECTED_PT_DECIMALS, "AUSD decimals mismatch");

        assertGt(PT_AUSD_MARKET.code.length, 0, "PT market has no code");
        (address marketSy, address marketPt, address marketYt) = IPendleMarketTokens(PT_AUSD_MARKET).readTokens();
        assertEq(marketSy, SY_AUSD, "market SY mismatch");
        assertEq(marketPt, PT_AUSD, "market PT mismatch");
        assertEq(marketYt, YT_AUSD, "market YT mismatch");
        assertEq(IPendleMarketTokens(PT_AUSD_MARKET).expiry(), EXPECTED_MATURITY, "market expiry mismatch");

        (uint8 assetType, address assetAddress, uint8 assetDecimals) = ISyAssetInfo(SY_AUSD).assetInfo();
        assertEq(assetType, PENDLE_ASSET_TYPE_TOKEN, "SY asset type mismatch");
        assertEq(assetAddress, AUSD, "SY asset mismatch");
        assertEq(assetDecimals, EXPECTED_PT_DECIMALS, "SY asset decimals mismatch");
        assertEq(ISyAssetInfo(SY_AUSD).yieldToken(), AUSD, "SY yield token mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                   2. DISCOUNT + ROUND COHERENCE
    //////////////////////////////////////////////////////////////*/

    /// @notice The real adapter computes the live pre-maturity discount and keeps legacy/V3 reads coherent.
    function test_deployedAdapter_latestAnswerAndRoundDataCoherent() public {
        RoundData memory baseRound = _latestBaseRound();

        assertGt(baseRound.answer, 0, "base price must be positive");
        assertLe(baseRound.updatedAt, block.timestamp, "base feed updated in future");
        assertLe(block.timestamp - baseRound.updatedAt, MAX_DELAY, "base feed stale at deployment block");
        assertLt(block.timestamp, EXPECTED_MATURITY, "deployment block must be pre-maturity");

        uint256 expectedDiscount = _discountWadAt(block.timestamp);
        int256 expectedAnswer = _expectedAnswer(baseRound.answer, block.timestamp);
        int256 answer = adapter.latestAnswer();

        assertEq(answer, expectedAnswer, "latestAnswer mismatch");
        assertGt(answer, 0, "answer must be positive");
        assertLt(answer, baseRound.answer, "pre-maturity PT must price below par");
        assertEq(adapter.getCurrentDiscount(), expectedDiscount, "discount mismatch");

        RoundData memory latestRound = _latestAdapterRound();
        assertEq(latestRound.roundId, baseRound.roundId, "roundId not forwarded");
        assertEq(latestRound.answer, expectedAnswer, "latestRoundData answer mismatch");
        assertEq(latestRound.startedAt, baseRound.startedAt, "startedAt not forwarded");
        assertEq(latestRound.updatedAt, baseRound.updatedAt, "updatedAt not forwarded");
        assertEq(latestRound.answeredInRound, baseRound.answeredInRound, "answeredInRound not forwarded");

        assertEq(adapter.latestRound(), uint256(baseRound.roundId), "legacy latestRound mismatch");
        assertEq(adapter.latestTimestamp(), baseRound.updatedAt, "legacy latestTimestamp mismatch");
        assertEq(adapter.getAnswer(uint256(baseRound.roundId)), expectedAnswer, "legacy getAnswer mismatch");
        assertEq(adapter.getTimestamp(uint256(baseRound.roundId)), baseRound.updatedAt, "legacy getTimestamp mismatch");
        assertEq(adapter.getAnswer(uint256(baseRound.roundId) + 1), 0, "non-latest getAnswer must be zero");
        assertEq(adapter.getTimestamp(uint256(baseRound.roundId) + 1), 0, "non-latest getTimestamp must be zero");

        RoundData memory requestedRound = _adapterRound(baseRound.roundId);
        assertEq(requestedRound.roundId, baseRound.roundId, "getRoundData roundId mismatch");
        assertEq(requestedRound.answer, expectedAnswer, "getRoundData answer mismatch");
        assertEq(requestedRound.startedAt, baseRound.startedAt, "getRoundData startedAt mismatch");
        assertEq(requestedRound.updatedAt, baseRound.updatedAt, "getRoundData updatedAt mismatch");
        assertEq(requestedRound.answeredInRound, baseRound.answeredInRound, "getRoundData answeredInRound mismatch");

        vm.expectRevert(CommonChecksLibrary.StaleRound.selector);
        adapter.getRoundData(baseRound.roundId + 1);
    }

    /**
     * @notice The current live fork still serves positive, fresh, and independently recomputed round data.
     * @dev Ownership is deliberately not pinned here because the current owner is live governance state.
     */
    function test_deployedAdapter_liveLatestRoundDataFreshPositiveAndCoherent() public {
        uint256 liveForkId = vm.createFork(mainnetRpcUrl);
        vm.selectFork(liveForkId);
        assertEq(block.chainid, 143, "MAINNET_RPC must be Monad mainnet");

        adapter = PendlePtDiscountOracleAdapter(DEPLOYED_ADAPTER);
        assertEq(DEPLOYED_ADAPTER.codehash, EXPECTED_RUNTIME_CODE_HASH, "runtime codehash mismatch");

        RoundData memory baseRound = _latestBaseRound();
        assertGt(baseRound.answer, 0, "live base price must be positive");
        assertLe(baseRound.updatedAt, block.timestamp, "live base feed updated in future");
        assertLe(block.timestamp - baseRound.updatedAt, MAX_DELAY, "live base feed stale");

        int256 expectedAnswer = _expectedAnswer(baseRound.answer, block.timestamp);
        RoundData memory liveRound = _latestAdapterRound();
        assertEq(liveRound.roundId, baseRound.roundId, "live roundId not forwarded");
        assertEq(liveRound.answer, expectedAnswer, "live answer mismatch");
        assertGt(liveRound.answer, 0, "live adapter answer must be positive");
        assertEq(liveRound.startedAt, baseRound.startedAt, "live startedAt not forwarded");
        assertEq(liveRound.updatedAt, baseRound.updatedAt, "live updatedAt not forwarded");
        assertEq(liveRound.answeredInRound, baseRound.answeredInRound, "live answeredInRound not forwarded");
        assertEq(adapter.getCurrentDiscount(), _discountWadAt(block.timestamp), "live discount mismatch");
    }

    /// @notice The deployed adapter's discount decays as time-to-maturity shrinks and reaches par at maturity.
    function test_deployedAdapter_timeToMaturityDiscountDecaysToPar() public {
        int256 parPrice = 100_000_000;
        uint256 startTs = block.timestamp;

        _mockFreshRound(parPrice, startTs);
        int256 startAnswer = adapter.latestAnswer();
        uint256 startDiscount = adapter.getCurrentDiscount();
        assertEq(startAnswer, _expectedAnswer(parPrice, startTs), "start answer mismatch");
        assertGt(startDiscount, 0, "start discount must be positive");
        assertLt(startAnswer, parPrice, "start answer must be below par");

        uint256 midpointTs = (startTs + EXPECTED_MATURITY) / 2;
        vm.warp(midpointTs);
        _mockFreshRound(parPrice, midpointTs);
        int256 midpointAnswer = adapter.latestAnswer();
        uint256 midpointDiscount = adapter.getCurrentDiscount();
        assertEq(midpointAnswer, _expectedAnswer(parPrice, midpointTs), "midpoint answer mismatch");
        assertLt(midpointDiscount, startDiscount, "discount must decay");
        assertGt(midpointAnswer, startAnswer, "price must rise toward maturity");
        assertLt(midpointAnswer, parPrice, "midpoint answer must still be below par");

        uint256 lastPreMaturityTs = EXPECTED_MATURITY - 1;
        vm.warp(lastPreMaturityTs);
        _mockFreshRound(parPrice, lastPreMaturityTs);
        int256 lastPreMaturityAnswer = adapter.latestAnswer();
        assertEq(lastPreMaturityAnswer, _expectedAnswer(parPrice, lastPreMaturityTs), "pre-maturity answer mismatch");
        assertGt(lastPreMaturityAnswer, midpointAnswer, "price must keep rising");
        assertLt(lastPreMaturityAnswer, parPrice, "one second before maturity remains discounted");

        vm.warp(EXPECTED_MATURITY);
        _mockFreshRound(parPrice, EXPECTED_MATURITY);
        assertEq(adapter.getCurrentDiscount(), 0, "discount must be zero at maturity");
        assertEq(adapter.latestAnswer(), parPrice, "maturity answer must be par");
    }

    /*//////////////////////////////////////////////////////////////
                           3. STALENESS
    //////////////////////////////////////////////////////////////*/

    /// @notice Staleness is inclusive at maxDelay and then fails closed on the next second.
    function test_deployedAdapter_stalenessBoundaries() public {
        (uint80 baseRoundId, int256 basePrice,, uint256 baseUpdatedAt,) =
            AggregatorV3Interface(AUSD_USD_FEED).latestRoundData();
        assertGt(basePrice, 0, "base price must be positive");

        vm.warp(baseUpdatedAt + MAX_DELAY);
        assertGt(adapter.latestAnswer(), 0, "exact maxDelay boundary must be accepted");

        RoundData memory boundaryRound = _latestAdapterRound();
        assertGt(boundaryRound.answer, 0, "strict boundary answer must be positive");
        assertEq(boundaryRound.updatedAt, baseUpdatedAt, "strict boundary updatedAt mismatch");

        vm.warp(baseUpdatedAt + MAX_DELAY + 1);
        assertEq(adapter.latestAnswer(), 0, "stale latestAnswer must fail closed");
        assertEq(adapter.latestTimestamp(), 0, "stale latestTimestamp must fail closed");
        assertEq(adapter.latestRound(), 0, "stale latestRound must fail closed");
        assertEq(adapter.getAnswer(uint256(baseRoundId)), 0, "stale getAnswer must fail closed");
        assertEq(adapter.getTimestamp(uint256(baseRoundId)), 0, "stale getTimestamp must fail closed");

        vm.expectRevert(
            abi.encodeWithSelector(
                CommonChecksLibrary.PriceTooOld.selector, block.timestamp, baseUpdatedAt, baseUpdatedAt + MAX_DELAY
            )
        );
        adapter.latestRoundData();
    }

    /// @notice Zero or negative base-feed answers under-price through legacy reads and revert on strict reads.
    function test_deployedAdapter_nonPositiveBaseFeedFailsClosed() public {
        _mockFreshRound(0, block.timestamp);

        assertEq(adapter.latestAnswer(), 0, "zero latestAnswer must fail closed");
        assertEq(adapter.latestTimestamp(), 0, "zero latestTimestamp must fail closed");
        assertEq(adapter.latestRound(), 0, "zero latestRound must fail closed");
        assertEq(adapter.getAnswer(1), 0, "zero getAnswer must fail closed");
        assertEq(adapter.getTimestamp(1), 0, "zero getTimestamp must fail closed");

        vm.expectRevert(CommonChecksLibrary.InvalidBasePrice.selector);
        adapter.latestRoundData();

        _mockFreshRound(-1, block.timestamp);

        assertEq(adapter.latestAnswer(), 0, "negative latestAnswer must fail closed");
        assertEq(adapter.latestTimestamp(), 0, "negative latestTimestamp must fail closed");
        assertEq(adapter.latestRound(), 0, "negative latestRound must fail closed");

        vm.expectRevert(CommonChecksLibrary.InvalidBasePrice.selector);
        adapter.latestRoundData();
    }

    /// @notice Pins the replacement runtime's strict rejection of zero answeredInRound metadata.
    function test_deployedAdapter_rejectsZeroAnsweredInRoundMetadata() public {
        uint80 roundId = 2;
        int256 basePrice = 100_000_000;
        _mockRound(basePrice, block.timestamp, block.timestamp, roundId, 0);

        assertEq(adapter.latestAnswer(), 0, "legacy latestAnswer must fail closed");
        assertEq(adapter.latestTimestamp(), 0, "legacy latestTimestamp must fail closed");
        assertEq(adapter.latestRound(), 0, "legacy latestRound must fail closed");
        assertEq(adapter.getAnswer(uint256(roundId)), 0, "legacy getAnswer must fail closed");
        assertEq(adapter.getTimestamp(uint256(roundId)), 0, "legacy getTimestamp must fail closed");

        vm.expectRevert(CommonChecksLibrary.StaleRound.selector);
        adapter.latestRoundData();

        vm.expectRevert(CommonChecksLibrary.StaleRound.selector);
        adapter.getRoundData(roundId);
    }

    /*//////////////////////////////////////////////////////////////
                       4. POST-MATURITY PAR
    //////////////////////////////////////////////////////////////*/

    /// @notice At and after maturity the deployed adapter passes a fresh base feed through 1:1.
    function test_deployedAdapter_atAndPostMaturityPricesAtPar() public {
        int256 parPrice = 100_000_000;

        vm.warp(EXPECTED_MATURITY);
        _mockFreshRound(parPrice, block.timestamp);

        assertEq(adapter.getCurrentDiscount(), 0, "discount must be zero at maturity");
        assertEq(adapter.latestAnswer(), parPrice, "latestAnswer must be par at maturity");

        (uint80 roundId, int256 roundAnswer,, uint256 updatedAt,) = adapter.latestRoundData();
        assertEq(roundId, 1, "mocked roundId mismatch");
        assertEq(roundAnswer, parPrice, "latestRoundData must be par at maturity");
        assertEq(updatedAt, block.timestamp, "updatedAt mismatch");

        (, int256 getRoundAnswer,,,) = adapter.getRoundData(1);
        assertEq(getRoundAnswer, parPrice, "getRoundData must be par at maturity");
        assertEq(adapter.getAnswer(1), parPrice, "legacy getAnswer must be par at maturity");
        assertEq(adapter.getTimestamp(1), block.timestamp, "legacy getTimestamp mismatch");

        vm.warp(EXPECTED_MATURITY + 90 days);
        _mockFreshRound(97_000_000, block.timestamp);
        assertEq(adapter.getCurrentDiscount(), 0, "discount must stay zero post-maturity");
        assertEq(adapter.latestAnswer(), 97_000_000, "post-maturity answer must track base feed");
    }

    /*//////////////////////////////////////////////////////////////
                            5. OWNERSHIP
    //////////////////////////////////////////////////////////////*/

    /// @notice Only the deployed owner can retune the discount rate, and the new rate immediately affects price.
    function test_deployedAdapter_ownerOnlyDiscountUpdateOnFork() public {
        RoundData memory baseRound = _latestBaseRound();
        int256 originalAnswer = adapter.latestAnswer();

        vm.prank(makeAddr("notOwner"));
        vm.expectRevert();
        adapter.setDiscountRatePerYear(UPDATED_RATE_BPS);
        assertEq(adapter.discountRatePerYear(), RATE_BPS, "non-owner changed rate");

        vm.expectEmit(false, false, false, true, address(adapter));
        emit DiscountRatePerYearUpdated(RATE_BPS, UPDATED_RATE_BPS);
        vm.prank(EXPECTED_DEPLOYMENT_OWNER);
        adapter.setDiscountRatePerYear(UPDATED_RATE_BPS);

        int256 updatedAnswer = adapter.latestAnswer();
        assertEq(adapter.discountRatePerYear(), UPDATED_RATE_BPS, "owner rate update mismatch");
        assertEq(
            updatedAnswer,
            _expectedAnswerAtRate(baseRound.answer, block.timestamp, UPDATED_RATE_BPS),
            "updated answer mismatch"
        );
        assertGt(updatedAnswer, originalAnswer, "lower discount rate should raise price");
    }

    /// @notice The deployed owner can set the immutable ceiling exactly, but cannot set zero or exceed it.
    function test_deployedAdapter_ownerRateCeilingBehavior() public {
        RoundData memory baseRound = _latestBaseRound();
        int256 originalAnswer = adapter.latestAnswer();

        vm.startPrank(EXPECTED_DEPLOYMENT_OWNER);

        vm.expectRevert(IPendlePtDiscountOracleAdapter.InvalidDiscountRate.selector);
        adapter.setDiscountRatePerYear(0);

        vm.expectRevert(IPendlePtDiscountOracleAdapter.InvalidDiscountRate.selector);
        adapter.setDiscountRatePerYear(MAX_RATE_BPS + 1);

        vm.expectEmit(false, false, false, true, address(adapter));
        emit DiscountRatePerYearUpdated(RATE_BPS, MAX_RATE_BPS);
        adapter.setDiscountRatePerYear(MAX_RATE_BPS);

        vm.stopPrank();

        int256 ceilingAnswer = adapter.latestAnswer();
        assertEq(adapter.discountRatePerYear(), MAX_RATE_BPS, "ceiling rate not stored");
        assertEq(
            ceilingAnswer,
            _expectedAnswerAtRate(baseRound.answer, block.timestamp, MAX_RATE_BPS),
            "ceiling answer mismatch"
        );
        assertLt(ceilingAnswer, originalAnswer, "higher discount rate should lower price");
    }

    /// @notice The deployed owner cannot accidentally renounce risk control.
    function test_deployedAdapter_ownerCannotRenounce() public {
        vm.prank(EXPECTED_DEPLOYMENT_OWNER);
        vm.expectRevert(IPendlePtDiscountOracleAdapter.OwnershipRequired.selector);
        adapter.renounceOwnership();

        assertEq(adapter.owner(), EXPECTED_DEPLOYMENT_OWNER, "owner changed after failed renounce");
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Overrides the real base feed's latest round with fresh mock data.
     * @param price Mock base-feed price.
     * @param timestamp Mock round timestamp.
     */
    function _mockFreshRound(int256 price, uint256 timestamp) internal {
        _mockRound(price, timestamp, timestamp, 1, 1);
    }

    /**
     * @notice Overrides the real base feed's latest round with arbitrary mocked metadata.
     * @param price Mock base-feed price.
     * @param startedAt Mock round start timestamp.
     * @param updatedAt Mock round update timestamp.
     * @param roundId Mock round ID.
     * @param answeredInRound Mock answered-in-round metadata.
     */
    function _mockRound(int256 price, uint256 startedAt, uint256 updatedAt, uint80 roundId, uint80 answeredInRound)
        internal
    {
        vm.clearMockedCalls();
        vm.mockCall(
            AUSD_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(roundId, price, startedAt, updatedAt, answeredInRound)
        );
    }

    /**
     * @notice Reads the latest base-feed round into a compact struct.
     * @return roundData Latest base-feed round data.
     */
    function _latestBaseRound() internal view returns (RoundData memory roundData) {
        (roundData.roundId, roundData.answer, roundData.startedAt, roundData.updatedAt, roundData.answeredInRound) =
            AggregatorV3Interface(AUSD_USD_FEED).latestRoundData();
    }

    /**
     * @notice Reads the deployed adapter's latest round into a compact struct.
     * @return roundData Latest adapter round data.
     */
    function _latestAdapterRound() internal view returns (RoundData memory roundData) {
        (roundData.roundId, roundData.answer, roundData.startedAt, roundData.updatedAt, roundData.answeredInRound) =
            adapter.latestRoundData();
    }

    /**
     * @notice Reads a deployed-adapter round into a compact struct.
     * @param roundId Requested round ID.
     * @return roundData Requested adapter round data.
     */
    function _adapterRound(uint80 roundId) internal view returns (RoundData memory roundData) {
        (roundData.roundId, roundData.answer, roundData.startedAt, roundData.updatedAt, roundData.answeredInRound) =
            adapter.getRoundData(roundId);
    }

    /**
     * @notice Computes the expected deployed-adapter answer at a timestamp.
     * @param basePrice Base AUSD/USD price at 8 decimals.
     * @param timestamp Timestamp to evaluate.
     * @return The expected PT/USD answer at 8 decimals.
     */
    function _expectedAnswer(int256 basePrice, uint256 timestamp) internal pure returns (int256) {
        return _expectedAnswerAtRate(basePrice, timestamp, RATE_BPS);
    }

    /**
     * @notice Computes the expected deployed-adapter answer for a supplied discount rate.
     * @param basePrice Base AUSD/USD price at 8 decimals.
     * @param timestamp Timestamp to evaluate.
     * @param rateBps Annual discount rate in basis points.
     * @return The expected PT/USD answer at 8 decimals.
     */
    function _expectedAnswerAtRate(int256 basePrice, uint256 timestamp, uint16 rateBps) internal pure returns (int256) {
        uint256 discountWad = _discountWadAtRate(timestamp, rateBps);

        return int256((uint256(basePrice) * (WAD - discountWad)) / WAD);
    }

    /**
     * @notice Computes the configured linear discount at a timestamp.
     * @param timestamp Timestamp to evaluate.
     * @return The discount at 1e18 fixed-point scale.
     */
    function _discountWadAt(uint256 timestamp) internal pure returns (uint256) {
        return _discountWadAtRate(timestamp, RATE_BPS);
    }

    /**
     * @notice Computes the configured linear discount at a timestamp for a supplied rate.
     * @param timestamp Timestamp to evaluate.
     * @param rateBps Annual discount rate in basis points.
     * @return The discount at 1e18 fixed-point scale.
     */
    function _discountWadAtRate(uint256 timestamp, uint16 rateBps) internal pure returns (uint256) {
        if (timestamp >= EXPECTED_MATURITY) return 0;

        uint256 timeToMaturity = EXPECTED_MATURITY - timestamp;

        return (timeToMaturity * uint256(rateBps) * BPS_TO_WAD) / SECONDS_PER_YEAR;
    }
}

/**
 * @title IExpiry
 * @author Neverland
 * @notice Minimal Pendle PT expiry interface used by the fork test.
 */
interface IExpiry {
    /// @notice Returns the PT maturity timestamp.
    function expiry() external view returns (uint256);

    /// @notice Returns the PT standardized-yield token.
    function SY() external view returns (address);
}

/**
 * @title IPendleMarketTokens
 * @author Neverland
 * @notice Minimal Pendle market token interface used by the fork test.
 */
interface IPendleMarketTokens {
    /**
     * @notice Returns the market's maturity timestamp.
     * @return The market maturity timestamp.
     */
    function expiry() external view returns (uint256);

    /**
     * @notice Returns the SY, PT, and YT paired by the market.
     * @return sy The market SY token.
     * @return pt The market PT token.
     * @return yt The market YT token.
     */
    function readTokens() external view returns (address sy, address pt, address yt);
}

/**
 * @title IDecimals
 * @author Neverland
 * @notice Minimal ERC20 decimals interface used by the fork test.
 */
interface IDecimals {
    /// @notice Returns token decimals.
    function decimals() external view returns (uint8);
}

/**
 * @title ISyAssetInfo
 * @author Neverland
 * @notice Minimal Pendle SY asset-info interface used by the fork test.
 */
interface ISyAssetInfo {
    /// @notice Returns the SY asset type, asset address, and asset decimals.
    function assetInfo() external view returns (uint8 assetType, address assetAddress, uint8 assetDecimals);

    /// @notice Returns the SY yield token.
    function yieldToken() external view returns (address);
}
