// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPoolDataProvider} from "@aave/core-v3/contracts/interfaces/IPoolDataProvider.sol";

import {IDustRewardsController} from "../../../src/interfaces/IDustRewardsController.sol";
import {INeverlandUiProvider} from "../../../src/interfaces/INeverlandUiProvider.sol";
import {NeverlandUiProvider} from "../../../src/utils/NeverlandUiProvider.sol";

/**
 * @notice Mainnet fork acceptance for the Pendle AUSD isolated market emission workaround.
 * @dev Run with:
 *   MAINNET_RPC=https://rpc.monad.xyz RUN_MAINNET_FORK_TESTS=true \
 *     forge test --match-contract NeverlandUiProviderPendleAusdFork -vvv
 */
contract NeverlandUiProviderPendleAusdForkTest is Test {
    address internal constant USER = 0xcb69535ABBc95a042914507F963bDD74ad0025FF;
    address internal constant DUST = 0xAD96C3dffCD6374294e2573A7fBBA96097CC8d7c;
    address internal constant DUST_LOCK = 0xBB4738D05AD1b3Da57a4881baE62Ce9bb1eEeD6C;
    address internal constant REVENUE_REWARD = 0xff20ac10eb808B1e31F5CfCa58D80eDE2Ba71c43;
    address internal constant DUST_REWARDS_CONTROLLER = 0x57ea245cCbFAb074baBb9d01d1F0c60525E52cec;
    address internal constant DUST_HELPER = 0x4b80e62364Ee452e8C9d3ea342E445f515A2CD9b;
    address internal constant CANONICAL_POOL_ADDRESSES_PROVIDER = 0x49D75170F55C964dfdd6726c74fdEDEe75553A0f;
    address internal constant PENDLE_AUSD_POOL_ADDRESSES_PROVIDER = 0xb80397A931FcFdA3aC999a3a5639C328Dc72A58F;

    address internal constant ISOLATED_PT_AUSD_ATOKEN = 0xf5A4D774aFFD6f22B6fE76ce20BB9312F23C8784;
    address internal constant ISOLATED_AUSD_ATOKEN = 0xF58E7aDC6F4eC524C09B7b6f058d3aB48D7CD65e;
    address internal constant ISOLATED_AUSD_VARIABLE_DEBT = 0x9da2d91D0CcF2daaf16B8Bd2778593Af1C369657;

    NeverlandUiProvider internal provider;

    function setUp() public {
        vm.skip(!vm.envOr("RUN_MAINNET_FORK_TESTS", false), "set RUN_MAINNET_FORK_TESTS=true to enable mainnet RPC");

        string memory mainnetRpcUrl = vm.envString("MAINNET_RPC");
        uint256 forkBlock = vm.envOr("MAINNET_FORK_BLOCK", uint256(0));
        uint256 forkId = forkBlock == 0 ? vm.createFork(mainnetRpcUrl) : vm.createFork(mainnetRpcUrl, forkBlock);
        vm.selectFork(forkId);
        assertEq(block.chainid, 143, "MAINNET_RPC must be Monad mainnet");

        provider = new NeverlandUiProvider(
            DUST_LOCK, REVENUE_REWARD, DUST_REWARDS_CONTROLLER, DUST_HELPER, CANONICAL_POOL_ADDRESSES_PROVIDER
        );
    }

    function testPendleAusdEmissionWorkaroundDoesNotRequireControllerUpgrade() public view {
        (bool hasControllerAssetList,) = DUST_REWARDS_CONTROLLER.staticcall(abi.encodeWithSignature("getAssetsList()"));
        assertFalse(hasControllerAssetList, "live controller already exposes getAssetsList");

        address[] memory canonicalAssets = _assetsFromProvider(CANONICAL_POOL_ADDRESSES_PROVIDER);
        address[] memory isolatedAssets = _assetsFromProvider(PENDLE_AUSD_POOL_ADDRESSES_PROVIDER);
        assertGt(canonicalAssets.length, 0, "canonical asset enumeration empty");
        assertGe(isolatedAssets.length, 3, "isolated asset count");

        INeverlandUiProvider.UserEmissionAsset[] memory breakdown = provider.getUserEmissionBreakdown(USER, DUST);

        assertGe(breakdown.length, canonicalAssets.length + 3, "missing isolated assets");
        assertGt(_amountFor(breakdown, ISOLATED_PT_AUSD_ATOKEN), 0, "missing isolated PT-AUSD supply DUST");
        assertGt(_amountFor(breakdown, ISOLATED_AUSD_ATOKEN), 0, "missing isolated AUSD supply DUST");
        assertGt(_amountFor(breakdown, ISOLATED_AUSD_VARIABLE_DEBT), 0, "missing isolated AUSD variable debt DUST");
        assertEq(
            breakdown[_indexFor(breakdown, ISOLATED_PT_AUSD_ATOKEN)].symbol,
            "npAUSD_8OCT2026",
            "isolated PT-AUSD symbol"
        );
        assertFalse(breakdown[_indexFor(breakdown, ISOLATED_PT_AUSD_ATOKEN)].isDebt, "PT-AUSD row side");
        assertEq(breakdown[_indexFor(breakdown, ISOLATED_AUSD_ATOKEN)].symbol, "npAUSD", "isolated AUSD symbol");
        assertFalse(breakdown[_indexFor(breakdown, ISOLATED_AUSD_ATOKEN)].isDebt, "AUSD row side");
        assertEq(
            breakdown[_indexFor(breakdown, ISOLATED_AUSD_VARIABLE_DEBT)].symbol,
            "variableDebtNpAUSD",
            "isolated debt symbol"
        );
        assertTrue(breakdown[_indexFor(breakdown, ISOLATED_AUSD_VARIABLE_DEBT)].isDebt, "AUSD debt row side");

        uint256 canonicalDust =
            IDustRewardsController(DUST_REWARDS_CONTROLLER).getUserRewards(canonicalAssets, USER, DUST);
        uint256 isolatedDust =
            IDustRewardsController(DUST_REWARDS_CONTROLLER).getUserRewards(isolatedAssets, USER, DUST);
        assertGt(isolatedDust, 0, "isolated DUST should accrue");

        (address[] memory rewardTokens, uint256[] memory totalRewards) = provider.getUserEmissions(USER);
        uint256 providerDustTotal = _amountFor(rewardTokens, totalRewards, DUST);

        assertEq(providerDustTotal, canonicalDust + isolatedDust, "provider DUST total");
        assertGt(providerDustTotal, canonicalDust, "provider total should include isolated DUST");
    }

    function _assetsFromProvider(address providerAddr) internal view returns (address[] memory assets) {
        address dataProviderAddr = IPoolAddressesProvider(providerAddr).getPoolDataProvider();
        IPoolDataProvider dataProvider = IPoolDataProvider(dataProviderAddr);
        IPoolDataProvider.TokenData[] memory reserves = dataProvider.getAllReservesTokens();

        assets = new address[](reserves.length * 2);
        uint256 n;
        for (uint256 i; i < reserves.length;) {
            (address aTokenAddr,, address variableDebtTokenAddr) =
                dataProvider.getReserveTokensAddresses(reserves[i].tokenAddress);
            if (aTokenAddr != address(0)) {
                assets[n] = aTokenAddr;
                unchecked {
                    ++n;
                }
            }
            if (variableDebtTokenAddr != address(0)) {
                assets[n] = variableDebtTokenAddr;
                unchecked {
                    ++n;
                }
            }
            unchecked {
                ++i;
            }
        }

        assembly ("memory-safe") {
            mstore(assets, n)
        }
    }

    function _amountFor(address[] memory tokens, uint256[] memory amounts, address target)
        internal
        pure
        returns (uint256)
    {
        for (uint256 i; i < tokens.length;) {
            if (tokens[i] == target) return amounts[i];
            unchecked {
                ++i;
            }
        }
        return 0;
    }

    function _amountFor(INeverlandUiProvider.UserEmissionAsset[] memory breakdown, address target)
        internal
        pure
        returns (uint256)
    {
        for (uint256 i; i < breakdown.length;) {
            if (breakdown[i].asset == target) return breakdown[i].amount;
            unchecked {
                ++i;
            }
        }
        return 0;
    }

    function _indexFor(INeverlandUiProvider.UserEmissionAsset[] memory breakdown, address target)
        internal
        pure
        returns (uint256)
    {
        for (uint256 i; i < breakdown.length;) {
            if (breakdown[i].asset == target) return i;
            unchecked {
                ++i;
            }
        }
        revert("missing row");
    }
}
