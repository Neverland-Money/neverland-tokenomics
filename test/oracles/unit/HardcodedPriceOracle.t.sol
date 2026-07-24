// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {AaveOracle} from "@aave/core-v3/contracts/misc/AaveOracle.sol";
import {PoolAddressesProvider} from "@aave/core-v3/contracts/protocol/configuration/PoolAddressesProvider.sol";
import {Test} from "forge-std/Test.sol";

import {IHardcodedPriceOracle} from "../../../src/interfaces/IHardcodedPriceOracle.sol";

import {HardcodedPriceOracle} from "../../../src/oracles/HardcodedPriceOracle.sol";

/**
 * @title HardcodedPriceOracleTest
 * @author Neverland
 * @notice Unit tests for the fixed-price, non-upgradeable Aave price source
 * @dev Pins the constant-answer surface, the deploy-time validation guards, and real end-to-end
 *      reads through a live Aave `AaveOracle`.
 */
contract HardcodedPriceOracleTest is Test {
    HardcodedPriceOracle internal oracle;

    /// @dev Deploy answer (the price at 8 decimals); 1e8 == $1.00.
    uint256 internal constant ANSWER = 1e8;

    /// @dev Expected int256 answer the feed reports ($1.00 at 8 decimals).
    int256 internal constant SCALED_PRICE = 1e8;

    /// @dev A fractional answer: $1.04 at 8 decimals.
    uint256 internal constant FRACTIONAL_ANSWER = 104_000_000;

    /// @dev USD base currency marker used by the Aave oracle wiring.
    address internal constant BASE_CURRENCY = address(0);

    /// @dev 1 USD expressed at 8 decimals.
    uint256 internal constant BASE_CURRENCY_UNIT = 1e8;

    /// @dev Human-readable feed description set at deployment.
    string internal constant DESCRIPTION = "Neverland Hardcoded Price Oracle";

    function setUp() public {
        vm.warp(365 days);

        oracle = new HardcodedPriceOracle(ANSWER, DESCRIPTION);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOY VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_constructor_revertsOnZeroPrice() public {
        vm.expectRevert(IHardcodedPriceOracle.InvalidPrice.selector);
        new HardcodedPriceOracle(0, DESCRIPTION);
    }

    function test_constructor_revertsBeyondInt256() public {
        // One past the int256 ceiling: deployment must revert, never wrap negative.
        uint256 tooLarge = uint256(type(int256).max) + 1;

        vm.expectRevert(IHardcodedPriceOracle.InvalidPrice.selector);
        new HardcodedPriceOracle(tooLarge, DESCRIPTION);
    }

    function test_constructor_revertsOnAstronomicalPrice() public {
        // Even uint256.max reverts cleanly as InvalidPrice (it is far beyond the int256 range).
        vm.expectRevert(IHardcodedPriceOracle.InvalidPrice.selector);
        new HardcodedPriceOracle(type(uint256).max, DESCRIPTION);
    }

    function test_constructor_acceptsMaxRepresentableAnswer() public {
        uint256 maxAnswer = uint256(type(int256).max);

        HardcodedPriceOracle maxOracle = new HardcodedPriceOracle(maxAnswer, DESCRIPTION);

        assertEq(maxOracle.latestAnswer(), type(int256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTANT ANSWER
    //////////////////////////////////////////////////////////////*/

    function test_latestAnswer_returnsConfiguredAnswer() public view {
        assertEq(oracle.latestAnswer(), SCALED_PRICE);
    }

    function test_fractionalAnswer_isReportedExactly() public {
        // $1.04 is representable at 8 decimals; the feed reports it verbatim.
        HardcodedPriceOracle fractional = new HardcodedPriceOracle(FRACTIONAL_ANSWER, DESCRIPTION);

        assertEq(uint256(fractional.latestAnswer()), FRACTIONAL_ANSWER);
        assertEq(fractional.decimals(), 8);
    }

    function test_decimals_isEight() public view {
        assertEq(oracle.decimals(), 8);
    }

    function test_description_isSetPerDeploy() public {
        // A second oracle carries its own deploy-set description, proving it is not hardcoded.
        HardcodedPriceOracle labeled = new HardcodedPriceOracle(ANSWER, "AUSD / USD");

        assertEq(oracle.description(), DESCRIPTION);
        assertEq(labeled.description(), "AUSD / USD");
    }

    function test_version_isOne() public view {
        assertEq(oracle.version(), 1);
    }

    function test_latestRoundData_isConstantAndFresh() public view {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();

        assertEq(roundId, 1);
        assertEq(answer, SCALED_PRICE);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, 1);
    }

    function test_legacyRoundReads_ignoreRoundId() public view {
        assertEq(oracle.latestRound(), 1);
        assertEq(oracle.latestTimestamp(), block.timestamp);
        assertEq(oracle.getAnswer(0), SCALED_PRICE);
        assertEq(oracle.getAnswer(type(uint256).max), SCALED_PRICE);
        assertEq(oracle.getTimestamp(0), block.timestamp);
        assertEq(oracle.getTimestamp(type(uint256).max), block.timestamp);
    }

    function test_getRoundData_ignoresRoundId() public view {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.getRoundData(12345);

        assertEq(roundId, 1);
        assertEq(answer, SCALED_PRICE);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, 1);
    }

    function test_answerStaysFreshAfterTimeWarp() public {
        vm.warp(block.timestamp + 5000 days);

        assertEq(oracle.latestAnswer(), SCALED_PRICE);
        assertEq(oracle.latestTimestamp(), block.timestamp);

        (,,, uint256 updatedAt,) = oracle.latestRoundData();
        assertEq(updatedAt, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                          AAVE INTEGRATION
    //////////////////////////////////////////////////////////////*/

    function test_aaveOracle_readsHardcodedPrice() public {
        address asset = makeAddr("asset");

        PoolAddressesProvider provider = new PoolAddressesProvider("Hardcoded Market", address(this));
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = asset;
        sources[0] = address(oracle);
        AaveOracle aaveOracle = new AaveOracle(
            IPoolAddressesProvider(address(provider)), assets, sources, address(0), BASE_CURRENCY, BASE_CURRENCY_UNIT
        );

        assertEq(aaveOracle.getAssetPrice(asset), uint256(SCALED_PRICE));
        assertEq(aaveOracle.getAssetPrice(asset), uint256(oracle.latestAnswer()));
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_latestAnswer_returnsAnswer(uint256 answer) public {
        answer = bound(answer, 1, uint256(type(int256).max));

        HardcodedPriceOracle fuzzed = new HardcodedPriceOracle(answer, DESCRIPTION);

        assertEq(uint256(fuzzed.latestAnswer()), answer);
        assertEq(fuzzed.decimals(), 8);
    }

    function testFuzz_constructor_revertsBeyondInt256(uint256 answer) public {
        answer = bound(answer, uint256(type(int256).max) + 1, type(uint256).max);

        vm.expectRevert(IHardcodedPriceOracle.InvalidPrice.selector);
        new HardcodedPriceOracle(answer, DESCRIPTION);
    }
}
