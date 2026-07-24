// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {NeverlandDustHelper} from "../../../src/utils/NeverlandDustHelper.sol";
import {MockERC20} from "../../_utils/MockERC20.sol";

contract DustHelperProbeOracle {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

contract DustHelperProbeV3Pool {
    uint160 private immutable _sqrtPriceX96;
    address private immutable _token0;
    address private immutable _token1;

    constructor(uint160 sqrtPriceX96_, address token0_, address token1_) {
        _sqrtPriceX96 = sqrtPriceX96_;
        _token0 = token0_;
        _token1 = token1_;
    }

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        return (_sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function token0() external view returns (address) {
        return _token0;
    }

    function token1() external view returns (address) {
        return _token1;
    }
}

contract DustHelperV3OverflowProbeTest is Test {
    function testExtremeV3SqrtPriceFailsSoft() public {
        MockERC20 dust = new MockERC20("DUST", "DUST", 18);
        MockERC20 paired = new MockERC20("PAIR", "PAIR", 18);
        NeverlandDustHelper helper = new NeverlandDustHelper(address(dust), address(this));

        helper.setPair(address(new DustHelperProbeV3Pool(type(uint160).max, address(dust), address(paired))));
        helper.setPairOracle(address(new DustHelperProbeOracle()));

        (bool ok, bytes memory data) = address(helper).staticcall(abi.encodeCall(helper.getPrice, ()));
        (uint256 price, bool fromOracle) = abi.decode(data, (uint256, bool));

        assertTrue(ok, "V3 extreme price should not bubble a helper revert");
        assertEq(price, 0, "V3 extreme price should fail closed to zero");
        assertFalse(fromOracle, "V3 extreme price should not be reported as oracle-backed");
    }
}
