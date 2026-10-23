// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {AaveOracle} from "@aave/core-v3/contracts/misc/AaveOracle.sol";
import {PoolAddressesProvider} from "@aave/core-v3/contracts/protocol/configuration/PoolAddressesProvider.sol";
import {Test} from "forge-std/Test.sol";

import {IGovernedPriceOracle} from "../../../src/interfaces/IGovernedPriceOracle.sol";

import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";

import {GovernedPriceOracle} from "../../../src/oracles/GovernedPriceOracle.sol";

/**
 * @title GovernedPriceOracleTest
 * @author Neverland
 * @notice Unit tests for the owner-governed Aave price source
 * @dev Pins the owner-only setter, honest round metadata, deploy/update validation guards, the
 *      two-step ownership surface, and real end-to-end reads through a live Aave `AaveOracle`.
 */
contract GovernedPriceOracleTest is Test {
    /**
     * @notice Mirrors the canonical Chainlink update event for expectEmit assertions
     * @param current The new price in 8-decimal USD scale
     * @param roundId The post counter
     * @param updatedAt The timestamp of the post
     */
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    /**
     * @notice Mirrors the canonical Chainlink round event for expectEmit assertions
     * @param roundId The post counter
     * @param startedBy The price-posting authority
     * @param startedAt The timestamp of the post
     */
    event NewRound(uint256 indexed roundId, address indexed startedBy, uint256 startedAt);

    /**
     * @notice Mirrors the OpenZeppelin ownership event emitted during construction
     * @param previousOwner The previous owner
     * @param newOwner The new owner
     */
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @notice Mirrors the oracle event for expectEmit assertions
     * @param previousAnswer The previous price in 8-decimal USD scale
     * @param newAnswer The new price in 8-decimal USD scale
     */
    event PriceUpdated(int256 previousAnswer, int256 newAnswer);

    /// @dev Deploy answer (the price at 8 decimals); 1e8 == $1.00.
    uint256 internal constant ANSWER = 1e8;

    /// @dev A second posted price: $1.04 at 8 decimals.
    uint256 internal constant NEW_ANSWER = 104_000_000;

    /// @dev USD base currency marker used by the Aave oracle wiring.
    address internal constant BASE_CURRENCY = address(0);

    /// @dev 1 USD expressed at 8 decimals.
    uint256 internal constant BASE_CURRENCY_UNIT = 1e8;

    /// @dev Human-readable feed description set at deployment.
    string internal constant DESCRIPTION = "USDe / USD";

    GovernedPriceOracle internal oracle;

    function setUp() public {
        vm.warp(365 days);

        oracle = new GovernedPriceOracle(ANSWER, DESCRIPTION);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOY VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_constructor_setsState() public view {
        assertEq(oracle.latestAnswer(), int256(uint256(ANSWER)));
        assertEq(oracle.latestTimestamp(), block.timestamp);
        assertEq(oracle.latestRound(), 1);
        assertEq(oracle.description(), DESCRIPTION);
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.version(), 1);
        assertEq(oracle.owner(), address(this));
        assertEq(oracle.pendingOwner(), address(0));
    }

    function test_constructor_emitsCanonicalRoundEvents() public {
        vm.expectEmit(true, true, false, true);
        emit OwnershipTransferred(address(0), address(this));
        vm.expectEmit(true, true, false, true);
        emit NewRound(1, address(this), block.timestamp);
        vm.expectEmit(true, true, false, true);
        emit AnswerUpdated(int256(uint256(ANSWER)), 1, block.timestamp);
        vm.expectEmit(false, false, false, true);
        emit PriceUpdated(0, int256(uint256(ANSWER)));

        new GovernedPriceOracle(ANSWER, DESCRIPTION);
    }

    function test_constructor_revertsOnZeroPrice() public {
        vm.expectRevert(IGovernedPriceOracle.InvalidPrice.selector);
        new GovernedPriceOracle(0, DESCRIPTION);
    }

    function test_constructor_revertsBeyondInt256() public {
        uint256 tooLarge = uint256(type(int256).max) + 1;

        vm.expectRevert(IGovernedPriceOracle.InvalidPrice.selector);
        new GovernedPriceOracle(tooLarge, DESCRIPTION);
    }

    function test_constructor_acceptsMaxRepresentableAnswer() public {
        GovernedPriceOracle maxOracle = new GovernedPriceOracle(uint256(type(int256).max), DESCRIPTION);

        assertEq(maxOracle.latestAnswer(), type(int256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            GOVERNED SETTER
    //////////////////////////////////////////////////////////////*/

    function test_setPrice_updatesAnswerRoundAndTimestampAndEmits() public {
        uint256 postedAt = block.timestamp + 1 days;
        vm.warp(postedAt);

        vm.expectEmit(true, true, false, true);
        emit NewRound(2, address(this), postedAt);
        vm.expectEmit(true, true, false, true);
        emit AnswerUpdated(int256(uint256(NEW_ANSWER)), 2, postedAt);
        vm.expectEmit(false, false, false, true);
        emit PriceUpdated(int256(uint256(ANSWER)), int256(uint256(NEW_ANSWER)));
        oracle.setPrice(NEW_ANSWER);

        assertEq(oracle.latestAnswer(), int256(uint256(NEW_ANSWER)));
        assertEq(oracle.latestTimestamp(), postedAt);
        assertEq(oracle.latestRound(), 2);
    }

    function test_setPrice_sameValueReattestsWithNewRoundAndTimestamp() public {
        uint256 postedAt = block.timestamp + 1 days;
        vm.warp(postedAt);

        vm.expectEmit(true, true, false, true);
        emit NewRound(2, address(this), postedAt);
        vm.expectEmit(true, true, false, true);
        emit AnswerUpdated(int256(uint256(ANSWER)), 2, postedAt);
        vm.expectEmit(false, false, false, true);
        emit PriceUpdated(int256(uint256(ANSWER)), int256(uint256(ANSWER)));
        oracle.setPrice(ANSWER);

        assertEq(oracle.latestAnswer(), int256(uint256(ANSWER)));
        assertEq(oracle.latestTimestamp(), postedAt);
        assertEq(oracle.latestRound(), 2);
    }

    function test_setPrice_chainsSequentialGovernedSteps() public {
        oracle.setPrice(NEW_ANSWER);
        oracle.setPrice(ANSWER);

        assertEq(oracle.latestAnswer(), int256(uint256(ANSWER)));
        assertEq(oracle.latestRound(), 3);
    }

    function test_setPrice_revertsForNonOwner() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert("Ownable: caller is not the owner");
        oracle.setPrice(NEW_ANSWER);
    }

    function test_setPrice_revertsOnZero() public {
        vm.expectRevert(IGovernedPriceOracle.InvalidPrice.selector);
        oracle.setPrice(0);
    }

    function test_setPrice_revertsBeyondInt256() public {
        vm.expectRevert(IGovernedPriceOracle.InvalidPrice.selector);
        oracle.setPrice(uint256(type(int256).max) + 1);
    }

    function test_setPrice_acceptsMaxRepresentableAnswer() public {
        oracle.setPrice(uint256(type(int256).max));

        assertEq(oracle.latestAnswer(), type(int256).max);
    }

    function test_setPrice_failedUpdateLeavesStateUntouched() public {
        vm.expectRevert(IGovernedPriceOracle.InvalidPrice.selector);
        oracle.setPrice(0);

        assertEq(oracle.latestAnswer(), int256(uint256(ANSWER)));
        assertEq(oracle.latestRound(), 1);
        assertEq(oracle.latestTimestamp(), 365 days);
    }

    /*//////////////////////////////////////////////////////////////
                          HONEST ROUND METADATA
    //////////////////////////////////////////////////////////////*/

    function test_latestTimestamp_staysAtPostTimeNotBlockTime() public {
        // Unlike the Hardcoded oracle, freshness is NOT synthetic: updatedAt is the last post time.
        uint256 postedAt = block.timestamp;
        vm.warp(postedAt + 5000 days);

        assertEq(oracle.latestAnswer(), int256(uint256(ANSWER)));
        assertEq(oracle.latestTimestamp(), postedAt);

        (, int256 answer, uint256 startedAt, uint256 updatedAt,) = oracle.latestRoundData();
        assertEq(answer, int256(uint256(ANSWER)));
        assertEq(startedAt, postedAt);
        assertEq(updatedAt, postedAt);
        assertEq(oracle.getTimestamp(1), postedAt);
    }

    function test_latestRoundData_reflectsLatestPost() public {
        uint256 postedAt = block.timestamp + 3 days;
        vm.warp(postedAt);
        oracle.setPrice(NEW_ANSWER);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();

        assertEq(roundId, 2);
        assertEq(answer, int256(uint256(NEW_ANSWER)));
        assertEq(startedAt, postedAt);
        assertEq(updatedAt, postedAt);
        assertEq(answeredInRound, 2);
    }

    function test_legacyRoundReads_areLatestRoundOnly() public {
        oracle.setPrice(NEW_ANSWER);

        assertEq(oracle.getAnswer(2), int256(uint256(NEW_ANSWER)));
        assertEq(oracle.getTimestamp(2), block.timestamp);

        // Historical and unknown rounds are not stored.
        assertEq(oracle.getAnswer(1), 0);
        assertEq(oracle.getTimestamp(1), 0);
        assertEq(oracle.getAnswer(type(uint256).max), 0);
        assertEq(oracle.getTimestamp(type(uint256).max), 0);
    }

    function test_getRoundData_revertsOnNonLatestRound() public {
        oracle.setPrice(NEW_ANSWER);

        (uint80 roundId,,,,) = oracle.getRoundData(2);
        assertEq(roundId, 2);

        vm.expectRevert(CommonChecksLibrary.StaleRound.selector);
        oracle.getRoundData(1);
    }

    /*//////////////////////////////////////////////////////////////
                          OWNERSHIP SURFACE
    //////////////////////////////////////////////////////////////*/

    function test_renounceOwnership_isDisabled() public {
        vm.expectRevert(IGovernedPriceOracle.OwnershipRequired.selector);
        oracle.renounceOwnership();
    }

    function test_ownershipHandoff_isTwoStep() public {
        address safe = makeAddr("governanceSafe");

        oracle.transferOwnership(safe);
        assertEq(oracle.owner(), address(this));
        assertEq(oracle.pendingOwner(), safe);

        vm.prank(safe);
        oracle.acceptOwnership();
        assertEq(oracle.owner(), safe);
        assertEq(oracle.pendingOwner(), address(0));

        // Price control follows the accepted owner.
        vm.expectRevert("Ownable: caller is not the owner");
        oracle.setPrice(NEW_ANSWER);
        vm.prank(safe);
        oracle.setPrice(NEW_ANSWER);
        assertEq(oracle.latestAnswer(), int256(uint256(NEW_ANSWER)));
    }

    function test_pendingOwnerCannotPostBeforeAcceptance() public {
        address governanceSafe = makeAddr("governanceSafe");
        oracle.transferOwnership(governanceSafe);

        vm.prank(governanceSafe);
        vm.expectRevert("Ownable: caller is not the owner");
        oracle.setPrice(NEW_ANSWER);

        oracle.setPrice(NEW_ANSWER);
        assertEq(oracle.latestAnswer(), int256(uint256(NEW_ANSWER)));
    }

    /*//////////////////////////////////////////////////////////////
                          AAVE INTEGRATION
    //////////////////////////////////////////////////////////////*/

    function test_aaveOracle_tracksPostedPrice() public {
        address asset = makeAddr("asset");

        PoolAddressesProvider provider = new PoolAddressesProvider("Governed Market", address(this));
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = asset;
        sources[0] = address(oracle);
        AaveOracle aaveOracle = new AaveOracle(
            IPoolAddressesProvider(address(provider)), assets, sources, address(0), BASE_CURRENCY, BASE_CURRENCY_UNIT
        );

        assertEq(aaveOracle.getAssetPrice(asset), ANSWER);

        oracle.setPrice(NEW_ANSWER);
        assertEq(aaveOracle.getAssetPrice(asset), NEW_ANSWER);
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_setPrice_roundTrips(uint256 answer) public {
        answer = bound(answer, 1, uint256(type(int256).max));

        oracle.setPrice(answer);

        assertEq(uint256(oracle.latestAnswer()), answer);
        assertEq(oracle.latestRound(), 2);
    }

    function testFuzz_setPrice_revertsBeyondInt256(uint256 answer) public {
        answer = bound(answer, uint256(type(int256).max) + 1, type(uint256).max);

        vm.expectRevert(IGovernedPriceOracle.InvalidPrice.selector);
        oracle.setPrice(answer);
    }
}
