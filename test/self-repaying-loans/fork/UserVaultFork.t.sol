// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import "../../BaseTestFork.sol";
import {HarnessFactory} from "../harness/HarnessFactory.sol";

import {BaseTestLocal} from "../../BaseTestLocal.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPoolAddressesProviderRegistry} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProviderRegistry.sol";
import {IPoolDataProvider} from "@aave/core-v3/contracts/interfaces/IPoolDataProvider.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IAaveOracle} from "@aave/core-v3/contracts/interfaces/IAaveOracle.sol";

import {UserVaultHarness} from "../harness/UserVaultHarness.sol";

contract UserVaultForkTest is BaseTestFork, BaseTestLocal {
    HarnessFactory harnessFactory;

    // Mainnet fork chain data
    address poolAddressesProviderRegistryAddress = 0xD0CCDe10CAcd12f1c839Db6400B82a82ab90fa9B;
    address poolAddressesProviderAddress = 0x49D75170F55C964dfdd6726c74fdEDEe75553A0f;
    address poolDataProviderAddress = 0xfd0b6b6F736376F7B99ee989c749007c7757fDba;

    address USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address WETH = 0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242;
    address WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;
    address WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address USDT0 = 0xe7cd86e13AC4309349F30B3435a9d337750fC82D;
    uint256 collateralAmount = 1_500_000;
    uint256 borrowAmount = 34_000;
    uint256 repayAmount = 17_000;

    IPoolAddressesProviderRegistry _poolAddressesProviderRegistry;
    IPoolAddressesProvider _poolAddressesProvider;
    IPoolDataProvider _poolDataProvider;

    function _testSetup() internal override(BaseTestFork, BaseTestLocal) {
        BaseTestFork._testSetup();
        BaseTestLocal._testSetup();
    }

    function _setUp() internal override {
        // mint ethereum
        address[] memory usersToMintEth = new address[](1);
        usersToMintEth[0] = address(this);

        uint256[] memory ethAmountToMint = new uint256[](1);
        ethAmountToMint[0] = 1 ether;

        mintETH(usersToMintEth, ethAmountToMint);

        harnessFactory = new HarnessFactory();
        _poolAddressesProviderRegistry = IPoolAddressesProviderRegistry(poolAddressesProviderRegistryAddress);
        _poolAddressesProvider = IPoolAddressesProvider(poolAddressesProviderAddress);
        _poolDataProvider = IPoolDataProvider(poolDataProviderAddress);
    }

    function testRepayDebt() public {
        address poolUser = address(0xBEEF);

        // arrange
        _createForkDebt(poolUser);

        (UserVaultHarness _userVault,,,) =
            harnessFactory.createUserVaultHarness(poolUser, revenueReward, _poolAddressesProviderRegistry, automation);

        mintErc20Token(USDT0, address(_userVault), repayAmount);
        uint256 debtBefore = _currentVariableDebt(USDT0, poolUser);
        assertGt(debtBefore, repayAmount);

        // act
        vm.prank(automation);
        _userVault.repayDebt(poolAddressesProviderAddress, USDT0, repayAmount);

        // assert
        uint256 debtAfter = _currentVariableDebt(USDT0, poolUser);
        assertLt(debtAfter, debtBefore);
        assertEq(_tokenBalance(USDT0, address(_userVault)), 0);
    }

    function testAaveOracle() public view {
        // act
        uint256[] memory prices1 = _getAssetsPrices(USDC, WETH);
        uint256[] memory prices2 = _getAssetsPrices(WBTC, WMON);
        uint256[] memory prices3 = _getAssetsPrices(USDT0, address(0));

        // assert
        assertGt(prices1[0], 0);
        assertGt(prices1[1], 0);
        assertGt(prices2[0], 0);
        assertGt(prices2[1], 0);
        assertGt(prices3[0], 0);
        assertGt(prices3[1], 0);
    }

    function _createForkDebt(address poolUser) internal {
        IPool pool = IPool(_poolAddressesProvider.getPool());
        mintETH(_singleAddress(poolUser), _singleUint256(1 ether));
        mintErc20Token(USDC, poolUser, collateralAmount);

        vm.startPrank(poolUser);
        IERC20(USDC).approve(address(pool), collateralAmount);
        pool.supply(USDC, collateralAmount, poolUser, 0);
        pool.setUserUseReserveAsCollateral(USDC, true);
        pool.borrow(USDT0, borrowAmount, 2, 0, poolUser);
        vm.stopPrank();
    }

    function _currentVariableDebt(address asset, address account) internal view returns (uint256 currentVariableDebt) {
        (,, currentVariableDebt,,,,,,) = _poolDataProvider.getUserReserveData(asset, account);
    }

    function _tokenBalance(address token, address account) internal view returns (uint256) {
        return IERC20(token).balanceOf(account);
    }

    function _getAssetsPrices(address token1, address token2) internal view returns (uint256[] memory) {
        address[] memory assets = new address[](2);
        assets[0] = token1;
        assets[1] = token2;
        return IAaveOracle(_poolAddressesProvider.getPriceOracle()).getAssetsPrices(assets);
    }

    function _singleAddress(address value) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }

    function _singleUint256(uint256 value) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }
}
