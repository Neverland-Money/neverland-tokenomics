// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "@neverland-money/lending-core/contracts/interfaces/IPool.sol";
import {AaveOracle} from "@neverland-money/lending-core/contracts/misc/AaveOracle.sol";
import {ACLManager} from "@neverland-money/lending-core/contracts/protocol/configuration/ACLManager.sol";
import {
    PoolAddressesProvider
} from "@neverland-money/lending-core/contracts/protocol/configuration/PoolAddressesProvider.sol";
import {
    DefaultReserveInterestRateStrategy
} from "@neverland-money/lending-core/contracts/protocol/pool/DefaultReserveInterestRateStrategy.sol";
import {Pool} from "@neverland-money/lending-core/contracts/protocol/pool/Pool.sol";

import {INeverlandPendleMaturityGateway} from "../../../src/interfaces/INeverlandPendleMaturityGateway.sol";

import {NeverlandPendleMaturityGateway} from "../../../src/utils/NeverlandPendleMaturityGateway.sol";
import {
    MockFlashPool,
    MockGatewayToken,
    MockMorpho,
    MockPendleMarket,
    MockPendlePt,
    MockPendleRouter,
    MockPendleSy,
    MockPendleYt
} from "../mocks/PendleMaturityGatewayMocks.sol";
import {MockChainlinkAggregator} from "../../_utils/MockChainlinkAggregator.sol";
import {TestPoolConfigurator} from "../../risk/mocks/TestPoolConfigurator.sol";

/**
 * @title GatewayLendingCoreBase
 * @author Neverland
 * @notice Real lending-core pool and receipt tokens with local Pendle and flash-lender fixtures
 */
abstract contract GatewayLendingCoreBase is Test {
    PoolAddressesProvider internal provider;
    ACLManager internal acl;
    IPool internal pool;
    TestPoolConfigurator internal configurator;
    AaveOracle internal oracle;

    MockGatewayToken internal ausd;
    MockPendlePt internal ptOld;
    MockPendleSy internal syOld;
    MockPendleYt internal ytOld;
    MockPendlePt internal ptNew;
    MockPendleSy internal syNew;
    MockPendleYt internal ytNew;
    MockPendleMarket internal marketNew;
    MockPendleRouter internal router;
    MockMorpho internal morpho;
    MockFlashPool internal flashPool;
    NeverlandPendleMaturityGateway internal gateway;

    MockChainlinkAggregator internal ausdFeed;
    MockChainlinkAggregator internal ptOldFeed;
    MockChainlinkAggregator internal ptNewFeed;

    IERC20 internal aOld;
    IERC20 internal aNew;
    IERC20 internal vDebt;

    address internal owner = makeAddr("owner");
    address internal supplier = makeAddr("supplier");

    function setUp() public virtual {
        vm.warp(1_790_000_000);
        provider = new PoolAddressesProvider("LC", address(this));
        provider.setACLAdmin(address(this));
        acl = new ACLManager(provider);
        provider.setACLManager(address(acl));
        acl.addPoolAdmin(address(this));
        provider.setPoolImpl(address(new Pool(provider)));
        pool = IPool(provider.getPool());
        configurator = new TestPoolConfigurator(provider);
        provider.setAddress(bytes32("POOL_CONFIGURATOR"), address(configurator));

        ausd = new MockGatewayToken("AUSD", "AUSD");
        ptOld = new MockPendlePt("PT-OLD");
        syOld = new MockPendleSy(ausd);
        ytOld = new MockPendleYt(ptOld, syOld);
        ptOld.setSy(address(syOld));
        ptOld.setYt(address(ytOld));
        ptNew = new MockPendlePt("PT-NEW");
        syNew = new MockPendleSy(ausd);
        ytNew = new MockPendleYt(ptNew, syNew);
        ptNew.setSy(address(syNew));
        ptNew.setYt(address(ytNew));
        marketNew = new MockPendleMarket(address(syNew), address(ptNew), address(ytNew));
        router = new MockPendleRouter();
        router.setPriceWad(0.99e18);

        /// AUSD debt accrues at 10%; PT reserves remain unborrowed with a fixed liquidity index.
        address rate =
            address(new DefaultReserveInterestRateStrategy(provider, 0.8e27, 0.1e27, 0, 0, 0, 0, 0, 0, 0.2e27));
        address zero = address(new DefaultReserveInterestRateStrategy(provider, 0.8e27, 0, 0, 0, 0, 0, 0, 0, 0.2e27));
        configurator.initReserve(address(ausd), 6, rate, address(this));
        configurator.initReserve(address(ptOld), 6, zero, address(this));
        configurator.initReserve(address(ptNew), 6, zero, address(this));
        /// Match the source and target risk profiles used by the maturity gateway.
        configurator.configureReserveAsCollateral(address(ptOld), 9150, 9350, 10250);
        configurator.configureReserveAsCollateral(address(ptNew), 9500, 9600, 10150);
        configurator.setReserveBorrowing(address(ausd), true);

        ausdFeed = new MockChainlinkAggregator(1e8, 8, "AUSD/USD");
        ptOldFeed = new MockChainlinkAggregator(1e8, 8, "PT-OLD/USD");
        ptNewFeed = new MockChainlinkAggregator(0.988e8, 8, "PT-NEW/USD");
        address[] memory assets = new address[](3);
        address[] memory sources = new address[](3);
        assets[0] = address(ausd);
        assets[1] = address(ptOld);
        assets[2] = address(ptNew);
        sources[0] = address(ausdFeed);
        sources[1] = address(ptOldFeed);
        sources[2] = address(ptNewFeed);
        oracle = new AaveOracle(provider, assets, sources, address(0), address(0), 1e8);
        provider.setPriceOracle(address(oracle));

        _supply(address(ausd), supplier, 50_000_000e6);

        morpho = new MockMorpho();
        flashPool = new MockFlashPool(address(ausd));
        gateway = new NeverlandPendleMaturityGateway(
            pool, address(ausd), address(morpho), IPool(address(flashPool)), address(router), address(marketNew), owner
        );

        aOld = IERC20(pool.getReserveData(address(ptOld)).aTokenAddress);
        aNew = IERC20(pool.getReserveData(address(ptNew)).aTokenAddress);
        vDebt = IERC20(pool.getReserveData(address(ausd)).variableDebtTokenAddress);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Mints and supplies a fixture asset for a user
     * @param asset The reserve asset
     * @param user The supplier
     * @param amount Raw asset amount
     */
    function _supply(address asset, address user, uint256 amount) internal {
        MockGatewayToken(asset).mint(user, amount);
        vm.startPrank(user);
        IERC20(asset).approve(address(pool), amount);
        pool.supply(asset, amount, user, 0);
        vm.stopPrank();
    }

    /**
     * @notice Opens a source-PT position using the real lending pool
     * @param user Position owner
     * @param pt Source collateral
     * @param debt AUSD variable debt
     */
    function _open(address user, uint256 pt, uint256 debt) internal {
        _supply(address(ptOld), user, pt);
        if (debt != 0) {
            vm.prank(user);
            pool.borrow(address(ausd), debt, 2, 0, user);
        }
    }

    /// @notice Applies the source maturity configuration while retaining its liquidation threshold
    function _mature() internal {
        ptOld.setExpired(true);
        configurator.configureReserveAsCollateral(address(ptOld), 1, 9350, 10250);
        configurator.setReserveFreeze(address(ptOld), true);
    }

    /**
     * @notice Sets the mock lender's available cash
     * @param cash Raw AUSD amount
     */
    function _setMorphoCash(uint256 cash) internal {
        uint256 bal = ausd.balanceOf(address(morpho));
        if (bal > cash) ausd.burn(address(morpho), bal - cash);
        else ausd.mint(address(morpho), cash - bal);
    }

    /**
     * @notice Builds a close with no surplus minimum
     * @param ptAmount Source amount or max sentinel
     * @param to Surplus recipient
     * @param maxRounds Round budget
     * @return Close parameters
     */
    function _closeParams(uint256 ptAmount, address to, uint256 maxRounds)
        internal
        view
        returns (INeverlandPendleMaturityGateway.CloseParams memory)
    {
        return INeverlandPendleMaturityGateway.CloseParams({
            ptOld: address(ptOld), ptAmount: ptAmount, minSurplusOut: 0, to: to, maxRounds: maxRounds
        });
    }

    /**
     * @notice Builds a migration with no caller output or health minimum
     * @param ptAmount Source amount or max sentinel
     * @param repayAmount Requested repayment
     * @param maxRounds Round budget
     * @return Migration parameters
     */
    function _migrateParams(uint256 ptAmount, uint256 repayAmount, uint256 maxRounds)
        internal
        view
        returns (INeverlandPendleMaturityGateway.MigrateParams memory)
    {
        return INeverlandPendleMaturityGateway.MigrateParams({
            ptOld: address(ptOld),
            ptAmount: ptAmount,
            ptNew: address(ptNew),
            repayAmount: repayAmount,
            minPtOut: 0,
            minHealthFactor: 0,
            maxRounds: maxRounds
        });
    }

    /**
     * @notice Reads the real pool's health factor
     * @param user Position owner
     * @return hf Health factor in WAD
     */
    function _hf(address user) internal view returns (uint256 hf) {
        (,,,,, hf) = pool.getUserAccountData(user);
    }
}
