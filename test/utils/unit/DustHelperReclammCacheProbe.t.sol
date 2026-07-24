// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

import {IReClammPool} from "../../../src/interfaces/IReClammPool.sol";
import {NeverlandDustHelper} from "../../../src/utils/NeverlandDustHelper.sol";

contract DustHelperProbeERC20 is ERC20 {
    uint8 private immutable _tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }
}

contract DustHelperProbeReclammPool {
    IReClammPool.ReClammPoolDynamicData private _data;

    function setData(uint256 dustBalance, uint256 pairedBalance, bool dustToken0) external {
        _data.balancesLiveScaled18 = new uint256[](2);
        _data.lastVirtualBalances = new uint256[](2);
        if (dustToken0) {
            _data.balancesLiveScaled18[0] = dustBalance;
            _data.balancesLiveScaled18[1] = pairedBalance;
        } else {
            _data.balancesLiveScaled18[0] = pairedBalance;
            _data.balancesLiveScaled18[1] = dustBalance;
        }
        _data.isPoolInitialized = true;
    }

    function getReClammPoolDynamicData() external view returns (IReClammPool.ReClammPoolDynamicData memory) {
        return _data;
    }
}

contract DustHelperReclammCacheProbe is Test {
    function testHardcodedUpdateCachesManualPriceWhileReclammSourceConfigured() public {
        DustHelperProbeERC20 dust = new DustHelperProbeERC20("DUST", "DUST", 18);
        NeverlandDustHelper helper = new NeverlandDustHelper(address(dust), address(this));
        DustHelperProbeReclammPool reclamm = new DustHelperProbeReclammPool();

        reclamm.setData(2 ether, 1 ether, true);
        helper.setReclammPool(address(reclamm), true);

        (uint256 oraclePrice, bool fromOracle) = helper.getPrice();
        assertEq(oraclePrice, 50_000_000, "reCLAMM computes 0.50 USD/DUST");
        assertTrue(fromOracle, "source is oracle before hardcoded update");

        helper.updateHardcodedPrice(60_000_000);

        (uint256 cachedPrice, bool cachedFromOracle) = helper.getPrice();
        assertEq(cachedPrice, 60_000_000, "manual price was cached over configured reCLAMM source");
        assertFalse(cachedFromOracle, "cached source flag is manual");

        skip(helper.priceUpdateInterval() + 1);

        (uint256 refreshedPrice, bool refreshedFromOracle) = helper.getPrice();
        assertEq(refreshedPrice, 50_000_000, "reCLAMM source resumes after cache expiry");
        assertTrue(refreshedFromOracle, "source returns to oracle");
    }

    function testHardcodedUpdateDoesNotRefreshChainlinkRoundData() public {
        DustHelperProbeERC20 dust = new DustHelperProbeERC20("DUST", "DUST", 18);
        NeverlandDustHelper helper = new NeverlandDustHelper(address(dust), address(this));

        (uint80 initialRound, int256 initialAnswer,, uint256 initialUpdatedAt,) = helper.latestRoundData();
        assertEq(initialRound, 1, "initial round");
        assertEq(uint256(initialAnswer), helper.DEFAULT_DUST_PRICE(), "initial round answer");

        skip(1 hours);
        helper.updateHardcodedPrice(60_000_000);

        (uint256 getPriceAnswer, bool fromOracle) = helper.getPrice();
        assertEq(getPriceAnswer, 60_000_000, "manual price updates getPrice");
        assertFalse(fromOracle, "manual price is not oracle sourced");

        (uint80 staleRound, int256 staleAnswer,, uint256 staleUpdatedAt,) = helper.latestRoundData();
        assertEq(staleRound, initialRound, "round id did not advance");
        assertEq(uint256(staleAnswer), helper.DEFAULT_DUST_PRICE(), "round answer stayed stale");
        assertEq(staleUpdatedAt, initialUpdatedAt, "round timestamp stayed stale");

        helper.updatePriceCache();

        (uint80 stillStaleRound, int256 stillStaleAnswer,, uint256 stillStaleUpdatedAt,) = helper.latestRoundData();
        assertEq(stillStaleRound, initialRound, "cache refresh short-circuits round update");
        assertEq(uint256(stillStaleAnswer), helper.DEFAULT_DUST_PRICE(), "round answer is still stale");
        assertEq(stillStaleUpdatedAt, initialUpdatedAt, "round timestamp is still stale");
    }

    function testPriceLimitTighteningDoesNotInvalidateManualFallbackPrice() public {
        DustHelperProbeERC20 dust = new DustHelperProbeERC20("DUST", "DUST", 18);
        NeverlandDustHelper helper = new NeverlandDustHelper(address(dust), address(this));

        helper.setPriceLimits(50_000_000, 100_000_000);

        (uint256 cachedPrice, bool cachedFromOracle) = helper.getPrice();
        assertEq(cachedPrice, helper.DEFAULT_DUST_PRICE(), "fresh cache ignores tightened lower bound");
        assertFalse(cachedFromOracle, "manual fallback source flag");

        skip(helper.priceUpdateInterval() + 1);

        (uint256 fallbackPrice, bool fallbackFromOracle) = helper.getPrice();
        assertEq(fallbackPrice, helper.DEFAULT_DUST_PRICE(), "manual fallback ignores tightened lower bound");
        assertFalse(fallbackFromOracle, "manual fallback source flag after expiry");

        vm.expectRevert();
        helper.updatePriceCache();
    }
}
