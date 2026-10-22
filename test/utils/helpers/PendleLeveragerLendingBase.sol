// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICreditDelegationToken} from "@neverland-money/lending-core/contracts/interfaces/ICreditDelegationToken.sol";
import {IPool} from "@neverland-money/lending-core/contracts/interfaces/IPool.sol";
import {IScaledBalanceToken} from "@neverland-money/lending-core/contracts/interfaces/IScaledBalanceToken.sol";
import {
    ReserveConfiguration
} from "@neverland-money/lending-core/contracts/protocol/libraries/configuration/ReserveConfiguration.sol";
import {DataTypes} from "@neverland-money/lending-core/contracts/protocol/libraries/types/DataTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {INeverlandPendleLeverager as ILeverager} from "../../../src/interfaces/INeverlandPendleLeverager.sol";
import {IPendlePtLeverageRouter} from "../../../src/interfaces/IPendlePtLeverageRouter.sol";
import {NeverlandPendleLeverager} from "../../../src/utils/NeverlandPendleLeverager.sol";
import {GatewayLendingCoreBase} from "../integration/GatewayLendingCoreBase.sol";
import {MockPendleLeveragerRouter} from "../mocks/PendleLeveragerMocks.sol";
import {MockPendleRouter, MockPendleMarket, MockGatewayToken} from "../mocks/PendleMaturityGatewayMocks.sol";

/// @notice Local Pendle sale boundary; the pool, collateral transfers, delegation and debt tokens remain real.
contract PendleLeveragerLendingRouter is MockPendleRouter {
    uint256 public salePriceWad = 1e18;
    uint256[] public soldAmounts;
    uint256[] public salePrices;

    function setSalePrices(uint256[] memory values) external {
        salePrices = values;
    }

    function setSalePrice(uint256 value) external {
        salePriceWad = value;
    }

    function swapExactPtForToken(
        address receiver,
        address market,
        uint256 exactPtIn,
        IPendlePtLeverageRouter.TokenOutput calldata output,
        LimitOrderData calldata
    ) external returns (uint256 amountOut, uint256, uint256) {
        (, address pt,) = MockPendleMarket(market).readTokens();
        IERC20(pt).transferFrom(msg.sender, address(this), exactPtIn);
        soldAmounts.push(exactPtIn);
        uint256 price = salePrices.length == 0 ? salePriceWad : salePrices[soldAmounts.length - 1];
        amountOut = exactPtIn * price / 1e18;
        require(amountOut >= output.minTokenOut, "sale floor");
        MockGatewayToken(output.tokenOut).mint(receiver, amountOut);

        return (amountOut, 0, 0);
    }

    function saleCount() external view returns (uint256) {
        return soldAmounts.length;
    }
}

abstract contract PendleLeveragerLendingBase is GatewayLendingCoreBase {
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
    NeverlandPendleLeverager internal leverager;
    PendleLeveragerLendingRouter internal tradeRouter;

    function setUp() public virtual override {
        super.setUp();
        tradeRouter = new PendleLeveragerLendingRouter();
        tradeRouter.setPriceWad(1e18);
        _flashEnabled(true);
        leverager = new NeverlandPendleLeverager(
            pool,
            address(ausd),
            address(morpho),
            IPool(address(flashPool)),
            address(tradeRouter),
            address(marketNew),
            owner
        );
        _setMorphoCash(100_000e6);
    }

    function _flashEnabled(bool enabled) internal {
        DataTypes.ReserveConfigurationMap memory config = pool.getConfiguration(address(ausd));
        config.setFlashLoanEnabled(enabled);
        vm.prank(address(configurator));
        pool.setConfiguration(address(ausd), config);
    }

    // Funds exactly one decrease lender: Morpho, or the role-enabled external pool with Morpho emptied.
    function _lender(bool externalPool, uint256 cash) internal {
        _setMorphoCash(externalPool ? 0 : cash);
        if (externalPool) {
            flashPool.seed(supplier, cash);
            flashPool.ACL().setFlashBorrower(address(leverager), true);
        }
    }

    // Smallest partial repayment that burns a debt share at the current borrow index: ceil(index / RAY).
    function _minimumPartialCash() internal view returns (uint256) {
        return (pool.getReserveNormalizedVariableDebt(address(ausd)) + 1e27 - 1) / 1e27;
    }

    function _createParams(uint256 principal, uint256 borrowing)
        internal
        view
        returns (ILeverager.CreateParams memory)
    {
        return ILeverager.CreateParams(principal, borrowing, 0, 0, block.timestamp);
    }

    function _increaseParams(uint256 borrowing) internal view returns (ILeverager.IncreaseParams memory) {
        return ILeverager.IncreaseParams(borrowing, 0, 0, block.timestamp);
    }

    function _decreaseParams(uint256 collateral, uint256 repayment, uint256 rounds)
        internal
        view
        returns (ILeverager.DecreaseParams memory)
    {
        return ILeverager.DecreaseParams(collateral, repayment, repayment, 0, 0, rounds, block.timestamp);
    }

    function _approveDebt(address user, uint256 amount) internal {
        vm.prank(user);
        ICreditDelegationToken(address(vDebt)).approveDelegation(address(leverager), amount);
    }

    function _create(address user, uint256 principal, uint256 borrowing)
        internal
        returns (ILeverager.PositionResult memory)
    {
        ptNew.mint(user, principal);
        vm.prank(user);
        ptNew.approve(address(leverager), principal);
        _approveDebt(user, borrowing);
        vm.prank(user);
        return leverager.createPosition(_createParams(principal, borrowing));
    }

    function _approveCollateral(address user, uint256 amount) internal {
        vm.prank(user);
        aNew.approve(address(leverager), amount);
    }

    function _decrease(address user, uint256 collateral, uint256 repayment, uint256 rounds)
        internal
        returns (ILeverager.PositionResult memory)
    {
        _approveCollateral(user, collateral);
        vm.prank(user);
        return leverager.decreaseLeverage(_decreaseParams(collateral, repayment, rounds));
    }

    function _debtShares(address user) internal view returns (uint256) {
        return IScaledBalanceToken(address(vDebt)).scaledBalanceOf(user);
    }

    /// @dev Captures observable account, reserve, venue and custody state for atomicity and preview assertions.
    function _stateDigest(address user) internal view returns (bytes32) {
        bytes32 account = keccak256(
            abi.encode(
                aNew.balanceOf(user),
                _debtShares(user),
                vDebt.balanceOf(user),
                ausd.balanceOf(user),
                ptNew.balanceOf(user),
                aNew.allowance(user, address(leverager)),
                ptNew.allowance(user, address(leverager)),
                ICreditDelegationToken(address(vDebt)).borrowAllowance(user, address(leverager)),
                pool.getUserConfiguration(user)
            )
        );
        bytes32 reserves = keccak256(
            abi.encode(
                pool.getReserveData(address(ausd)),
                pool.getReserveData(address(ptNew)),
                ausd.balanceOf(pool.getReserveData(address(ausd)).aTokenAddress),
                ptNew.balanceOf(address(aNew)),
                aNew.totalSupply(),
                vDebt.totalSupply()
            )
        );
        bytes32 venues = keccak256(
            abi.encode(
                ausd.balanceOf(address(morpho)),
                ausd.balanceOf(address(flashPool.A_TOKEN())),
                flashPool.flashLoanCount(),
                tradeRouter.swapCount(),
                tradeRouter.saleCount(),
                ausd.balanceOf(address(tradeRouter)),
                ptNew.balanceOf(address(tradeRouter)),
                ausd.totalSupply(),
                ptNew.totalSupply()
            )
        );
        bytes32 custody = keccak256(
            abi.encode(
                ausd.balanceOf(address(leverager)),
                ptNew.balanceOf(address(leverager)),
                syNew.balanceOf(address(leverager)),
                aNew.balanceOf(address(leverager)),
                ausd.allowance(address(leverager), address(pool)),
                ausd.allowance(address(leverager), address(tradeRouter)),
                ausd.allowance(address(leverager), address(morpho)),
                ausd.allowance(address(leverager), address(flashPool)),
                ptNew.allowance(address(leverager), address(pool)),
                ptNew.allowance(address(leverager), address(tradeRouter))
            )
        );

        return keccak256(abi.encode(account, reserves, venues, custody));
    }

    function _assertCustody(uint256 debtDonation, uint256 ptDonation, uint256 syDonation, uint256 aDonation)
        internal
        view
    {
        assertEq(ausd.balanceOf(address(leverager)), debtDonation, "debt custody");
        assertEq(ptNew.balanceOf(address(leverager)), ptDonation, "PT custody");
        assertEq(syNew.balanceOf(address(leverager)), syDonation, "SY custody");
        assertEq(
            IScaledBalanceToken(address(aNew)).scaledBalanceOf(address(leverager)), aDonation, "aPT shares custody"
        );
        assertEq(ausd.allowance(address(leverager), address(pool)), 0);
        assertEq(ausd.allowance(address(leverager), address(tradeRouter)), 0);
        assertEq(ausd.allowance(address(leverager), address(morpho)), 0);
        assertEq(ausd.allowance(address(leverager), address(flashPool)), 0);
        assertEq(ptNew.allowance(address(leverager), address(pool)), 0);
        assertEq(ptNew.allowance(address(leverager), address(tradeRouter)), 0);
        assertEq(ptNew.allowance(address(leverager), address(ytNew)), 0);
        assertEq(syNew.allowance(address(leverager), address(tradeRouter)), 0);
        assertEq(vDebt.balanceOf(address(leverager)), 0, "gateway owns no debt");
    }
}

/// @notice Unit fixture: flash-enabled debt reserve, local sale router and a user who fully approves the leverager.
abstract contract PendleLeveragerUnitBase is GatewayLendingCoreBase {
    NeverlandPendleLeverager internal leverager;
    MockPendleLeveragerRouter internal saleRouter;
    address internal user = makeAddr("leverager user");

    function setUp() public virtual override {
        super.setUp();
        DataTypes.ReserveConfigurationMap memory config = pool.getConfiguration(address(ausd));
        config.data |= 1 << 63;
        vm.prank(address(configurator));
        pool.setConfiguration(address(ausd), config);
        saleRouter = new MockPendleLeveragerRouter();
        leverager = _deploy(pool, address(morpho), IPool(address(flashPool)), address(saleRouter), address(marketNew));
        vm.startPrank(user);
        IERC20(address(ptNew)).approve(address(leverager), type(uint256).max);
        aNew.approve(address(leverager), type(uint256).max);
        ICreditDelegationToken(address(vDebt)).approveDelegation(address(leverager), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Makes no call before the creation, so a preceding vm.expectRevert applies to the constructor.
    function _deploy(IPool pool_, address lender, IPool flashPool_, address router_, address market_)
        internal
        returns (NeverlandPendleLeverager)
    {
        return new NeverlandPendleLeverager(pool_, address(ausd), lender, flashPool_, router_, market_, owner);
    }

    function _create(uint256 seed, uint256 borrow_) internal returns (ILeverager.PositionResult memory result) {
        ptNew.mint(user, seed);
        vm.prank(user);
        result = leverager.createPosition(ILeverager.CreateParams(seed, borrow_, 0, 0, block.timestamp));
    }

    function _decrease(uint256 pt, uint256 repay_, uint256 rounds)
        internal
        view
        returns (ILeverager.DecreaseParams memory)
    {
        return ILeverager.DecreaseParams(pt, repay_, repay_, 0, 0, rounds, block.timestamp);
    }
}
