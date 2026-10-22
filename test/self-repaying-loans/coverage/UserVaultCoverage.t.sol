// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "../../BaseTestLocal.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPriceOracleGetter} from "@aave/core-v3/contracts/interfaces/IPriceOracleGetter.sol";
import {IACLManager} from "@aave/core-v3/contracts/interfaces/IACLManager.sol";
import {AaveOracle} from "@aave/core-v3/contracts/misc/AaveOracle.sol";
import {AggregatorInterface} from "@aave/core-v3/contracts/dependencies/chainlink/AggregatorInterface.sol";

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {UserVaultHarness} from "../harness/UserVaultHarness.sol";
import {IUserVault} from "../../../src/interfaces/IUserVault.sol";
import {IUserVaultRegistry} from "../../../src/interfaces/IUserVaultRegistry.sol";
import {IRevenueReward} from "../../../src/interfaces/IRevenueReward.sol";
import {UserVault} from "../../../src/self-repaying-loans/UserVault.sol";
import {UserVaultRegistry} from "../../../src/self-repaying-loans/UserVaultRegistry.sol";
import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";
import {MockERC20} from "../../_utils/MockERC20.sol";

/**
 * @notice Fixed-answer Chainlink-style source consumed by AaveOracle.setAssetSources.
 * @dev AaveOracle only reads `latestAnswer()` from a source; the other AggregatorInterface
 *      members are stubbed. A positive answer makes the oracle return this source's price.
 */
contract MockAggregatorSource is AggregatorInterface {
    int256 private _answer;

    constructor(int256 answer_) {
        _answer = answer_;
    }

    function setAnswer(int256 answer_) external {
        _answer = answer_;
    }

    function latestAnswer() external view returns (int256) {
        return _answer;
    }

    function latestTimestamp() external view returns (uint256) {
        return block.timestamp;
    }

    function latestRound() external pure returns (uint256) {
        return 1;
    }

    function getAnswer(uint256) external view returns (int256) {
        return _answer;
    }

    function getTimestamp(uint256) external view returns (uint256) {
        return block.timestamp;
    }
}

/**
 * @notice Minimal fallback price oracle returning a stored USD price (8-dec) per asset.
 * @dev Installed as the AaveOracle fallback so that an asset with no source resolves to a
 *      deterministic value (default 0) — used to drive swapAndVerify's GettingAssetPriceFailed branch.
 */
contract MockPriceSource is IPriceOracleGetter {
    address public immutable BASE_CURRENCY;
    uint256 public immutable BASE_CURRENCY_UNIT;

    mapping(address => uint256) private _prices;

    constructor(address baseCurrency, uint256 baseCurrencyUnit) {
        BASE_CURRENCY = baseCurrency;
        BASE_CURRENCY_UNIT = baseCurrencyUnit;
    }

    function setAssetPrice(address asset, uint256 price) external {
        _prices[asset] = price;
    }

    function getAssetPrice(address asset) external view returns (uint256) {
        return _prices[asset];
    }
}

/**
 * @notice Configurable mock swap aggregator used to drive UserVault._swap.
 * @dev On `swap(...)` it pulls `amountIn` of tokenIn from the caller (the vault, which
 *      has approved this contract) and transfers `amountOut` of a pre-funded tokenOut
 *      balance back. `setMode` toggles failure / no-op behaviour to exercise SwapFailed
 *      and zero-delta branches.
 */
contract MockSwapAggregator {
    using SafeERC20 for IERC20;

    enum Mode {
        Normal, // pull tokenIn, push tokenOut
        Revert, // revert to exercise SwapFailed
        NoOut, // pull tokenIn, push nothing (zero out delta)
        NoPull // push tokenOut without pulling tokenIn
    }

    Mode public mode;

    function setMode(Mode newMode) external {
        mode = newMode;
    }

    /// @dev Aggregator entrypoint targeted by aggregatorData.
    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut) external {
        if (mode == Mode.Revert) revert("AGG_REVERT");

        if (mode != Mode.NoPull) {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        }

        if (mode != Mode.NoOut) {
            IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        }
    }
}

/// @notice User contract that rejects native ETH, used to drive recoverETH's ETHSendFailed branch.
contract RejectEth {
    receive() external payable {
        revert("NO_ETH");
    }
}

/**
 * @notice Minimal RevenueReward stand-in implementing only the two members UserVault calls.
 * @dev `getReward` transfers a configured reward amount to the caller during the call, so the
 *      vault's balance-delta accounting in getTokenIdsReward observes a real, in-call increase.
 */
contract MockRevenueReward {
    using SafeERC20 for IERC20;

    mapping(uint256 => address) public tokenRewardReceiver;

    address public rewardAsset;
    uint256 public payout;

    function setReceiver(uint256 tokenId, address receiver) external {
        tokenRewardReceiver[tokenId] = receiver;
    }

    function setPayout(address asset, uint256 amount) external {
        rewardAsset = asset;
        payout = amount;
    }

    /// @dev Mirrors IRevenueReward.getReward; pays out the configured reward to the calling vault.
    function getReward(uint256, address[] calldata) external {
        if (payout > 0) {
            IERC20(rewardAsset).safeTransfer(msg.sender, payout);
        }
    }
}

/**
 * @title UserVaultCoverage
 * @notice Coverage-focused unit tests for UserVault's Aave swap/repay/deposit/recover paths,
 *         exercised against the local (non-fork) Aave market deployed by BaseTestLocal.
 */
contract UserVaultCoverageTest is BaseTestLocal {
    using SafeERC20 for IERC20;

    UserVaultHarness internal vault;
    UserVaultRegistry internal registry;
    UpgradeableBeacon internal beacon;

    MockSwapAggregator internal aggregator;
    MockPriceSource internal fallbackPriceSource;
    MockAggregatorSource internal rewardSource;
    MockAggregatorSource internal debtSource;

    MockERC20 internal rewardToken; // tokenIn  (18 dec)
    MockERC20 internal debtToken; // tokenOut (6 dec)

    // Oracle prices, Aave 8-dec format.
    uint256 internal constant REWARD_PRICE = 1e8; // $1 per reward token
    uint256 internal constant DEBT_PRICE = 1e8; // $1 per debt token

    uint256 internal constant MAX_SLIPPAGE_BPS = 500; // 5%

    address internal validProvider;
    address internal pool;

    /// @dev Re-declare event for expectEmit matching against the interface signature.
    event LoanSelfRepaid(
        address indexed user,
        address indexed userVault,
        address poolAddressesProvider,
        address debtToken,
        uint256 amount
    );

    /// @dev Accept ETH so recoverETH can pay the user (== this test contract) on the happy path.
    receive() external payable {}

    function _setUp() internal override {
        // Deploy a registry owned by this test contract so aggregator/slippage config is settable here.
        registry = new UserVaultRegistry();
        registry.setExecutor(automation);

        // Vault behind a beacon proxy (matches production deployment shape).
        beacon = new UpgradeableBeacon(address(new UserVaultHarness()));
        vault = UserVaultHarness(address(new BeaconProxy(address(beacon), "")));
        vault.initialize(user, revenueReward, registry, poolAddressesProviderRegistry);

        // Tokens: reward (in) 18-dec, debt (out) 6-dec — also covers decimal normalisation.
        rewardToken = new MockERC20("Reward", "RWD", 18);
        debtToken = new MockERC20("Debt", "DEBT", 6);

        // Aggregator pre-funded with debt token so it can deliver swap output.
        aggregator = new MockSwapAggregator();
        mintErc20Token(address(debtToken), address(aggregator), 1_000_000 * 1e6);

        // Registry config (test contract owns the registry created by the factory).
        registry.setSupportedAggregators(address(aggregator), true);
        registry.setMaxSwapSlippageBps(MAX_SLIPPAGE_BPS);

        // Oracle wiring. AAVE_ADMIN (== address(this)) holds DEFAULT_ADMIN_ROLE on the ACL
        // manager; grant it asset-listing admin so it may call setAssetSources/setFallbackOracle.
        address oracleAddr = IPoolAddressesProvider(address(poolAddressesProvider)).getPriceOracle();
        IACLManager aclManager = IACLManager(IPoolAddressesProvider(address(poolAddressesProvider)).getACLManager());
        aclManager.addAssetListingAdmin(address(this));

        // Fixed-price sources for the priced pair (positive answer => oracle uses the source).
        rewardSource = new MockAggregatorSource(int256(REWARD_PRICE));
        debtSource = new MockAggregatorSource(int256(DEBT_PRICE));

        address[] memory assets = new address[](2);
        assets[0] = address(rewardToken);
        assets[1] = address(debtToken);
        address[] memory sources = new address[](2);
        sources[0] = address(rewardSource);
        sources[1] = address(debtSource);
        AaveOracle(oracleAddr).setAssetSources(assets, sources);

        // Fallback oracle returns 0 for unpriced assets, exercising the zero-price branch.
        fallbackPriceSource = new MockPriceSource(BASE_CURRENCY, BASE_CURRENCY_UNIT);
        AaveOracle(oracleAddr).setFallbackOracle(address(fallbackPriceSource));

        validProvider = address(poolAddressesProvider);
        pool = IPoolAddressesProvider(validProvider).getPool();
    }

    /* ========================================================================
                                   HELPERS
    ======================================================================== */

    /// @dev Builds aggregatorData for the mock aggregator's `swap` entrypoint.
    function _aggData(uint256 amountIn, uint256 amountOut) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            MockSwapAggregator.swap.selector, address(rewardToken), amountIn, address(debtToken), amountOut
        );
    }

    /// @dev Deploys an additional beacon-proxied vault for the given user, reusing the shared beacon/registry.
    function _newVault(address forUser) internal returns (UserVaultHarness) {
        UserVaultHarness v = UserVaultHarness(address(new BeaconProxy(address(beacon), "")));
        v.initialize(forUser, revenueReward, registry, poolAddressesProviderRegistry);
        return v;
    }

    /// @dev Deploys a vault wired to a MockRevenueReward so reward-claim flows move real tokens in-call.
    function _newVaultWithMockReward(address forUser)
        internal
        returns (UserVaultHarness v, MockRevenueReward mockReward)
    {
        mockReward = new MockRevenueReward();
        v = UserVaultHarness(address(new BeaconProxy(address(beacon), "")));
        v.initialize(forUser, IRevenueReward(address(mockReward)), registry, poolAddressesProviderRegistry);
    }

    /* ========================================================================
                                  INITIALIZE
    ======================================================================== */

    /// @dev Fresh, uninitialized beacon proxy whose initialize() reaches the zero-address checks.
    function _freshProxy() internal returns (UserVault) {
        return UserVault(address(new BeaconProxy(address(beacon), "")));
    }

    function testInitializeRevertsOnZeroUser() public {
        UserVault fresh = _freshProxy();

        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        fresh.initialize(address(0), revenueReward, registry, poolAddressesProviderRegistry);
    }

    function testInitializeRevertsOnZeroRevenueReward() public {
        UserVault fresh = _freshProxy();

        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        fresh.initialize(user, IRevenueReward(address(0)), registry, poolAddressesProviderRegistry);
    }

    function testInitializeRevertsOnZeroRegistry() public {
        UserVault fresh = _freshProxy();

        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        fresh.initialize(user, revenueReward, IUserVaultRegistry(address(0)), poolAddressesProviderRegistry);
    }

    function testInitializeRevertsOnZeroProviderRegistry() public {
        UserVault fresh = _freshProxy();

        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        fresh.initialize(user, revenueReward, registry, IPoolAddressesProviderRegistry(address(0)));
    }

    function testInitializeDisabledOnImplementation() public {
        // Constructor calls _disableInitializers on a freshly deployed implementation.
        UserVault impl = new UserVault();

        vm.expectRevert();
        impl.initialize(user, revenueReward, registry, poolAddressesProviderRegistry);
    }

    function testCannotReinitialize() public {
        vm.expectRevert();
        vault.initialize(user, revenueReward, registry, poolAddressesProviderRegistry);
    }

    /* ========================================================================
                                 VIEW GETTERS
    ======================================================================== */

    function testViewGetters() public view {
        assertEq(vault.user(), user, "user");
        assertEq(address(vault.revenueReward()), address(revenueReward), "revenueReward");
        assertEq(address(vault.userVaultRegistry()), address(registry), "registry");
        assertEq(
            address(vault.poolAddressesProviderRegistry()), address(poolAddressesProviderRegistry), "providerRegistry"
        );
    }

    /* ========================================================================
                                  recoverERC20
    ======================================================================== */

    function testRecoverERC20ByExecutor() public {
        uint256 amount = 1_000 * 1e6;
        mintErc20Token(address(debtToken), address(vault), amount);

        uint256 userBefore = debtToken.balanceOf(user);

        vm.prank(automation);
        vault.recoverERC20(address(debtToken), amount);

        assertEq(debtToken.balanceOf(user), userBefore + amount, "user received tokens");
        assertEq(debtToken.balanceOf(address(vault)), 0, "vault drained");
    }

    function testRecoverERC20ByUser() public {
        uint256 amount = 500 * 1e6;
        mintErc20Token(address(debtToken), address(vault), amount);

        uint256 userBefore = debtToken.balanceOf(user);

        // user == address(this); call directly (no prank needed, but be explicit).
        vm.prank(user);
        vault.recoverERC20(address(debtToken), amount);

        assertEq(debtToken.balanceOf(user), userBefore + amount, "user received tokens");
    }

    function testRecoverERC20RevertsForStranger() public {
        mintErc20Token(address(debtToken), address(vault), 1e6);

        vm.prank(user1);
        vm.expectRevert(CommonChecksLibrary.UnauthorizedAccess.selector);
        vault.recoverERC20(address(debtToken), 1e6);
    }

    /* ========================================================================
                                   recoverETH
    ======================================================================== */

    function testRecoverETHByExecutor() public {
        uint256 amount = 1 ether;
        vm.deal(address(vault), amount);

        uint256 userBefore = user.balance;

        vm.prank(automation);
        vault.recoverETH(amount);

        assertEq(user.balance, userBefore + amount, "user received ETH");
        assertEq(address(vault).balance, 0, "vault ETH drained");
    }

    function testRecoverETHRevertsForStranger() public {
        vm.deal(address(vault), 1 ether);

        vm.prank(user2);
        vm.expectRevert(CommonChecksLibrary.UnauthorizedAccess.selector);
        vault.recoverETH(1 ether);
    }

    function testRecoverETHRevertsWhenUserRejectsEth() public {
        // Build a vault whose `user` is a contract that rejects ETH.
        RejectEth rejecter = new RejectEth();
        UserVaultHarness rejectVault = _newVault(address(rejecter));

        vm.deal(address(rejectVault), 1 ether);

        vm.prank(automation);
        vm.expectRevert(IUserVault.ETHSendFailed.selector);
        rejectVault.recoverETH(1 ether);
    }

    /* ========================================================================
                                   repayDebt
    ======================================================================== */

    function testRepayDebtEventUsesRequestedAmount() public {
        uint256 amount = 1_000 * 1e6;
        mintErc20Token(address(debtToken), address(vault), amount);

        // Aave can return less than requested when the outstanding debt is smaller.
        bytes memory repayCall =
            abi.encodeWithSelector(IPool.repay.selector, address(debtToken), amount, uint256(2), user);
        vm.mockCall(pool, repayCall, abi.encode(amount - 1));

        // Expect approve(pool, amount), repay, approve(pool, 0), then the event.
        vm.expectCall(address(debtToken), abi.encodeWithSelector(IERC20.approve.selector, pool, amount));
        vm.expectCall(pool, repayCall);
        vm.expectCall(address(debtToken), abi.encodeWithSelector(IERC20.approve.selector, pool, uint256(0)));

        vm.expectEmit(true, true, true, true, address(vault));
        emit LoanSelfRepaid(user, address(vault), validProvider, address(debtToken), amount);

        vm.prank(automation);
        vault.repayDebt(validProvider, address(debtToken), amount);
    }

    function testRepayDebtRevertsForNonExecutor() public {
        mintErc20Token(address(debtToken), address(vault), 1e6);

        vm.prank(user1);
        vm.expectRevert(IUserVault.NotExecutor.selector);
        vault.repayDebt(validProvider, address(debtToken), 1e6);
    }

    function testRepayDebtRevertsForInvalidProvider() public {
        mintErc20Token(address(debtToken), address(vault), 1e6);

        vm.prank(automation);
        vm.expectRevert(IUserVault.InvalidPoolAddressesProvider.selector);
        vault.repayDebt(NON_ZERO_ADDRESS, address(debtToken), 1e6);
    }

    /* ========================================================================
                                depositCollateral
    ======================================================================== */

    function testDepositCollateralHappyPath() public {
        uint256 amount = 2_000 * 1e6;
        mintErc20Token(address(debtToken), address(vault), amount);

        bytes memory supplyCall =
            abi.encodeWithSelector(IPool.supply.selector, address(debtToken), amount, user, uint16(0));
        vm.mockCall(pool, supplyCall, "");

        vm.expectCall(address(debtToken), abi.encodeWithSelector(IERC20.approve.selector, pool, amount));
        vm.expectCall(pool, supplyCall);
        vm.expectCall(address(debtToken), abi.encodeWithSelector(IERC20.approve.selector, pool, uint256(0)));

        vm.prank(automation);
        vault.depositCollateral(validProvider, address(debtToken), amount);
    }

    function testDepositCollateralRevertsForNonExecutor() public {
        vm.prank(user1);
        vm.expectRevert(IUserVault.NotExecutor.selector);
        vault.depositCollateral(validProvider, address(debtToken), 1e6);
    }

    function testDepositCollateralRevertsForInvalidProvider() public {
        vm.prank(automation);
        vm.expectRevert(IUserVault.InvalidPoolAddressesProvider.selector);
        vault.depositCollateral(NON_ZERO_ADDRESS, address(debtToken), 1e6);
    }

    /* ========================================================================
                                  swapAndVerify
    ======================================================================== */

    function testSwapAndVerifyHappyPath() public {
        uint256 amountIn = 1_000 * 1e18; // $1000 of reward
        uint256 amountOut = 1_000 * 1e6; // $1000 of debt -> 0% slippage

        mintErc20Token(address(rewardToken), address(vault), amountIn);

        vm.prank(automation);
        uint256 outAmount = vault.swapAndVerify(
            address(rewardToken),
            amountIn,
            address(debtToken),
            address(aggregator),
            _aggData(amountIn, amountOut),
            validProvider,
            MAX_SLIPPAGE_BPS
        );

        assertEq(outAmount, amountOut, "returned swapped out amount");
        assertEq(debtToken.balanceOf(address(vault)), amountOut, "vault holds debt token");
        assertEq(rewardToken.balanceOf(address(vault)), 0, "reward token consumed");
        // approval reset to zero after swap
        assertEq(rewardToken.allowance(address(vault), address(aggregator)), 0, "allowance reset");
    }

    function testSwapAndVerifyWithinSlippagePasses() public {
        uint256 amountIn = 1_000 * 1e18; // $1000
        uint256 amountOut = 970 * 1e6; // $970 -> 3% slippage, under 5% max

        mintErc20Token(address(rewardToken), address(vault), amountIn);

        vm.prank(automation);
        uint256 outAmount = vault.swapAndVerify(
            address(rewardToken),
            amountIn,
            address(debtToken),
            address(aggregator),
            _aggData(amountIn, amountOut),
            validProvider,
            MAX_SLIPPAGE_BPS
        );

        assertEq(outAmount, amountOut, "swap returns out amount under slippage cap");
    }

    function testSwapAndVerifyRevertsOnExcessSlippage() public {
        uint256 amountIn = 1_000 * 1e18; // $1000
        uint256 amountOut = 900 * 1e6; // $900 -> 10% slippage > 5% max

        mintErc20Token(address(rewardToken), address(vault), amountIn);

        vm.prank(automation);
        vm.expectRevert(IUserVault.SlippageExceeded.selector);
        vault.swapAndVerify(
            address(rewardToken),
            amountIn,
            address(debtToken),
            address(aggregator),
            _aggData(amountIn, amountOut),
            validProvider,
            MAX_SLIPPAGE_BPS
        );
    }

    function testSwapAndVerifyRevertsOnUnsupportedAggregator() public {
        uint256 amountIn = 1_000 * 1e18;
        mintErc20Token(address(rewardToken), address(vault), amountIn);

        MockSwapAggregator bad = new MockSwapAggregator(); // not whitelisted

        vm.prank(automation);
        vm.expectRevert(IUserVault.AggregatorNotSupported.selector);
        vault.swapAndVerify(
            address(rewardToken),
            amountIn,
            address(debtToken),
            address(bad),
            _aggData(amountIn, 1e6),
            validProvider,
            MAX_SLIPPAGE_BPS
        );
    }

    function testSwapAndVerifyRevertsOnSwapFailure() public {
        uint256 amountIn = 1_000 * 1e18;
        mintErc20Token(address(rewardToken), address(vault), amountIn);

        aggregator.setMode(MockSwapAggregator.Mode.Revert);

        vm.prank(automation);
        vm.expectRevert(IUserVault.SwapFailed.selector);
        vault.swapAndVerify(
            address(rewardToken),
            amountIn,
            address(debtToken),
            address(aggregator),
            _aggData(amountIn, 1e6),
            validProvider,
            MAX_SLIPPAGE_BPS
        );
    }

    function testSwapAndVerifyRevertsOnZeroPriceFromOracle() public {
        // A fresh token pair the oracle source does not price -> getAssetsPrices returns 0.
        MockERC20 unpriced = new MockERC20("Unpriced", "UNP", 18);
        uint256 amountIn = 100 * 1e18;
        mintErc20Token(address(unpriced), address(vault), amountIn);

        // Whitelisted aggregator that pulls tokenIn and delivers debt token out.
        // tokenIn=unpriced has no oracle source => price 0 => GettingAssetPriceFailed.
        bytes memory data = abi.encodeWithSelector(
            MockSwapAggregator.swap.selector, address(unpriced), amountIn, address(debtToken), uint256(1e6)
        );

        vm.prank(automation);
        vm.expectRevert(IUserVault.GettingAssetPriceFailed.selector);
        vault.swapAndVerify(
            address(unpriced), amountIn, address(debtToken), address(aggregator), data, validProvider, MAX_SLIPPAGE_BPS
        );
    }

    function testSwapAndVerifyRevertsOnMaxSlippageTooHigh() public {
        uint256 amountIn = 1_000 * 1e18;
        mintErc20Token(address(rewardToken), address(vault), amountIn);

        vm.prank(automation);
        vm.expectRevert(IUserVault.MaxSlippageTooHigh.selector);
        vault.swapAndVerify(
            address(rewardToken),
            amountIn,
            address(debtToken),
            address(aggregator),
            _aggData(amountIn, 1e6),
            validProvider,
            MAX_SLIPPAGE_BPS + 1 // exceeds registry max
        );
    }

    function testSwapAndVerifyRevertsOnZeroTokenIn() public {
        vm.prank(automation);
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        vault.swapAndVerify(
            address(0),
            1e18,
            address(debtToken),
            address(aggregator),
            _aggData(1e18, 1e6),
            validProvider,
            MAX_SLIPPAGE_BPS
        );
    }

    function testSwapAndVerifyRevertsOnZeroTokenOut() public {
        vm.prank(automation);
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        vault.swapAndVerify(
            address(rewardToken),
            1e18,
            address(0),
            address(aggregator),
            _aggData(1e18, 1e6),
            validProvider,
            MAX_SLIPPAGE_BPS
        );
    }

    function testSwapAndVerifyRevertsOnZeroAmount() public {
        vm.prank(automation);
        vm.expectRevert(CommonChecksLibrary.ZeroAmount.selector);
        vault.swapAndVerify(
            address(rewardToken),
            0,
            address(debtToken),
            address(aggregator),
            _aggData(0, 1e6),
            validProvider,
            MAX_SLIPPAGE_BPS
        );
    }

    function testSwapAndVerifyRevertsOnZeroAggregator() public {
        vm.prank(automation);
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        vault.swapAndVerify(
            address(rewardToken),
            1e18,
            address(debtToken),
            address(0),
            _aggData(1e18, 1e6),
            validProvider,
            MAX_SLIPPAGE_BPS
        );
    }

    function testSwapAndVerifyRevertsOnInvalidProvider() public {
        uint256 amountIn = 1_000 * 1e18;
        mintErc20Token(address(rewardToken), address(vault), amountIn);

        vm.prank(automation);
        vm.expectRevert(IUserVault.InvalidPoolAddressesProvider.selector);
        vault.swapAndVerify(
            address(rewardToken),
            amountIn,
            address(debtToken),
            address(aggregator),
            _aggData(amountIn, 1e6),
            NON_ZERO_ADDRESS,
            MAX_SLIPPAGE_BPS
        );
    }

    function testSwapAndVerifyRevertsForNonExecutor() public {
        uint256 amountIn = 1e18;
        mintErc20Token(address(rewardToken), address(vault), amountIn);

        vm.prank(user1);
        vm.expectRevert(IUserVault.NotExecutor.selector);
        vault.swapAndVerify(
            address(rewardToken),
            amountIn,
            address(debtToken),
            address(aggregator),
            _aggData(amountIn, 1e6),
            validProvider,
            MAX_SLIPPAGE_BPS
        );
    }

    /* ========================================================================
                                getTokenIdsReward
    ======================================================================== */

    function testGetTokenIdsRewardRevertsOnZeroRewardToken() public {
        uint256[] memory ids = new uint256[](0);

        vm.prank(automation);
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        vault.getTokenIdsReward(ids, address(0));
    }

    function testGetTokenIdsRewardRevertsForNonExecutor() public {
        uint256[] memory ids = new uint256[](0);

        vm.prank(user1);
        vm.expectRevert(IUserVault.NotExecutor.selector);
        vault.getTokenIdsReward(ids, address(rewardToken));
    }

    function testGetTokenIdsRewardEmptyReturnsZero() public {
        uint256[] memory ids = new uint256[](0);

        vm.prank(automation);
        uint256 amount = vault.getTokenIdsReward(ids, address(rewardToken));

        assertEq(amount, 0, "no tokenIds => zero claimed");
    }

    function testGetTokenIdsRewardRevertsForWrongReceiver() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 7;

        // RevenueReward reports a different receiver for this tokenId.
        vm.mockCall(
            address(revenueReward),
            abi.encodeWithSelector(IRevenueReward.tokenRewardReceiver.selector, uint256(7)),
            abi.encode(address(0xBEEF))
        );

        vm.prank(automation);
        vm.expectRevert(IUserVault.InvalidUserVaultForToken.selector);
        vault.getTokenIdsReward(ids, address(rewardToken));
    }

    function testGetTokenIdsRewardHappyPathReturnsDelta() public {
        (UserVaultHarness rewardVault, MockRevenueReward mockReward) = _newVaultWithMockReward(user);

        uint256[] memory ids = new uint256[](2);
        ids[0] = 42;
        ids[1] = 43;
        uint256 perToken = 125 * 1e18;
        uint256 expected = perToken * 2; // two tokenIds claimed in one call

        // Both tokenIds report this vault as their receiver; each getReward call pays `perToken`.
        mockReward.setReceiver(42, address(rewardVault));
        mockReward.setReceiver(43, address(rewardVault));
        mockReward.setPayout(address(rewardToken), perToken);
        mintErc20Token(address(rewardToken), address(mockReward), expected);

        vm.prank(automation);
        uint256 amount = rewardVault.getTokenIdsReward(ids, address(rewardToken));

        assertEq(amount, expected, "claimed equals balance delta");
        assertEq(rewardToken.balanceOf(address(rewardVault)), expected, "vault received rewards");
    }

    /* ========================================================================
                                  repayUserDebt
    ======================================================================== */

    function testRepayUserDebtFullFlow() public {
        // End-to-end: claim reward (real delta), swap reward -> debt, repay (mocked pool).
        (UserVaultHarness flowVault, MockRevenueReward mockReward) = _newVaultWithMockReward(user);

        uint256 rewardIn = 1_000 * 1e18; // $1000 reward
        uint256 debtOut = 980 * 1e6; // $980 debt -> 2% slippage (under cap)

        uint256[] memory ids = new uint256[](1);
        ids[0] = 99;

        // 1) Reward claim moves rewardIn into the vault during getReward.
        mockReward.setReceiver(99, address(flowVault));
        mockReward.setPayout(address(rewardToken), rewardIn);
        mintErc20Token(address(rewardToken), address(mockReward), rewardIn);

        // 2) Repay: mock the pool's repay to consume the swapped debt token and report the repaid amount.
        bytes memory repayCall =
            abi.encodeWithSelector(IPool.repay.selector, address(debtToken), debtOut, uint256(2), user);
        vm.mockCall(pool, repayCall, abi.encode(debtOut));

        vm.expectCall(pool, repayCall);
        vm.expectEmit(true, true, true, true, address(flowVault));
        emit LoanSelfRepaid(user, address(flowVault), validProvider, address(debtToken), debtOut);

        IUserVault.RepayUserDebtParams memory params = IUserVault.RepayUserDebtParams({
            debtToken: address(debtToken),
            poolAddressesProvider: validProvider,
            tokenIds: ids,
            rewardToken: address(rewardToken),
            rewardTokenAmountToSwap: rewardIn,
            aggregatorAddress: address(aggregator),
            aggregatorData: _aggData(rewardIn, debtOut),
            maxSlippageBps: MAX_SLIPPAGE_BPS
        });

        vm.prank(automation);
        flowVault.repayUserDebt(params);

        // Reward token consumed by the swap; debt token forwarded to the (mocked) pool repay.
        assertEq(rewardToken.balanceOf(address(flowVault)), 0, "reward token swapped");
        assertEq(debtToken.balanceOf(address(flowVault)), debtOut, "swapped debt held pending repay");
    }

    function testRepayUserDebtRevertsForNonExecutor() public {
        uint256[] memory ids = new uint256[](0);

        IUserVault.RepayUserDebtParams memory params = IUserVault.RepayUserDebtParams({
            debtToken: address(debtToken),
            poolAddressesProvider: validProvider,
            tokenIds: ids,
            rewardToken: address(rewardToken),
            rewardTokenAmountToSwap: 1e18,
            aggregatorAddress: address(aggregator),
            aggregatorData: _aggData(1e18, 1e6),
            maxSlippageBps: MAX_SLIPPAGE_BPS
        });

        vm.prank(user1);
        vm.expectRevert(IUserVault.NotExecutor.selector);
        vault.repayUserDebt(params);
    }

    /* ========================================================================
                          exposed internal: _verifySlippage
    ======================================================================== */

    function testExposedVerifySlippageFavorableTradeNoRevert() public view {
        // actual ($1100) > desired ($1000): branch where no slippage check fires.
        vault.exposed_verifySlippage(
            address(rewardToken),
            1_000 * 1e18,
            REWARD_PRICE,
            address(debtToken),
            1_100 * 1e6,
            DEBT_PRICE,
            0 // even 0 bps tolerated since trade is favorable
        );
    }

    function testExposedVerifySlippageExceededReverts() public {
        vm.expectRevert(IUserVault.SlippageExceeded.selector);
        vault.exposed_verifySlippage(
            address(rewardToken),
            1_000 * 1e18,
            REWARD_PRICE,
            address(debtToken),
            900 * 1e6, // $900 vs $1000 -> 10% slippage
            DEBT_PRICE,
            100 // 1% max
        );
    }

    /* ========================================================================
                       exposed internal: _getTokenPricesInUsd_8dec
    ======================================================================== */

    function testExposedGetAssetsPricesReturnsOraclePrices() public view {
        uint256[] memory prices = vault.exposed_getAssetsPrices(
            address(rewardToken), address(debtToken), IPoolAddressesProvider(validProvider)
        );

        assertEq(prices.length, 2, "two prices");
        assertEq(prices[0], REWARD_PRICE, "reward price");
        assertEq(prices[1], DEBT_PRICE, "debt price");
    }
}
