// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPool} from "@neverland-money/lending-core/contracts/interfaces/IPool.sol";
import {Ownable} from "@openzeppelin-v5/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin-v5/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin-v5/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuardTransient} from "@openzeppelin-v5/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin-v5/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

import {IMorphoFlashLoan} from "../../../src/interfaces/IMorphoFlashLoan.sol";
import {IMorphoFlashLoanCallback} from "../../../src/interfaces/IMorphoFlashLoanCallback.sol";
import {INeverlandPendleMaturityGateway} from "../../../src/interfaces/INeverlandPendleMaturityGateway.sol";
import {IPendleRouterV4} from "../../../src/interfaces/IPendleRouterV4.sol";

import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";

import {NeverlandPendleMaturityGateway} from "../../../src/utils/NeverlandPendleMaturityGateway.sol";

import {
    MockAclManager,
    MockAddressesProvider,
    MockFlashPool,
    MockGatewayAToken,
    MockGatewayToken,
    MockIsolatedPool,
    MockMorpho,
    MockPendleMarket,
    MockPendlePt,
    MockPendleRouter,
    MockPendleSy,
    MockPendleYt,
    MockVariableDebtToken,
    NonPrincipalToken,
    PartialPrincipalToken
} from "../mocks/PendleMaturityGatewayMocks.sol";

/**
 * @title NeverlandPendleMaturityGatewayTest
 * @author Neverland
 * @notice Unit tests for the Pendle maturity gateway
 * @dev Pins the minimal Pendle and Morpho interface selectors to the live deployments, then covers
 *      construction, the owner surface, the views, the flash callback guards, Close, and Migrate over local mocks.
 */
contract NeverlandPendleMaturityGatewayTest is Test {
    /*//////////////////////////////////////////////////////////////
                                FIXTURES
    //////////////////////////////////////////////////////////////*/

    /// @dev Independent balances and counters sampled before preview and execution
    struct ExecutionState {
        bytes32 digest;
        uint256 source;
        uint256 target;
        uint256 debt;
        uint256 paid;
        uint256 routerCash;
        uint256 morphoLoans;
        uint256 poolLoans;
        address lender;
        uint256 cash;
    }

    /// @dev Liquidation threshold of both PT reserves, in bps.
    uint256 internal constant PT_LT_BPS = 9_350;

    NeverlandPendleMaturityGateway internal gateway;
    GatewayHarness internal harness;
    MockIsolatedPool internal pool;
    MockVariableDebtToken internal debtToken;
    MockFlashPool internal flashPool;
    MockMorpho internal morpho;
    MockPendleRouter internal router;

    MockGatewayToken internal ausd;
    MockGatewayAToken internal aAusd;

    MockPendlePt internal ptOld;
    MockPendleSy internal syOld;
    MockPendleYt internal ytOld;
    MockGatewayAToken internal aPtOld;

    MockPendlePt internal ptNew;
    MockPendleSy internal syNew;
    MockPendleYt internal ytNew;
    MockGatewayAToken internal aPtNew;
    MockPendleMarket internal marketNew;

    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");
    address internal attacker = makeAddr("attacker");
    address internal beneficiary = makeAddr("beneficiary");

    function setUp() public {
        ausd = new MockGatewayToken("AUSD", "AUSD");
        pool = new MockIsolatedPool(address(ausd), address(new MockAddressesProvider(address(new MockAclManager()))));
        debtToken = pool.DEBT_TOKEN();

        (ptOld, syOld, ytOld) = _deployPrincipalToken("PT-OLD");
        (ptNew, syNew, ytNew) = _deployPrincipalToken("PT-NEW");
        marketNew = new MockPendleMarket(address(syNew), address(ptNew), address(ytNew));

        aAusd = pool.listReserve(address(ausd), 1e18, 0);
        aPtOld = pool.listReserve(address(ptOld), 1e18, PT_LT_BPS);
        aPtNew = pool.listReserve(address(ptNew), 0.985e18, PT_LT_BPS);

        morpho = new MockMorpho();
        flashPool = new MockFlashPool(address(ausd));
        router = new MockPendleRouter();

        gateway = _deploy(
            IPool(address(pool)), address(ausd), address(morpho), IPool(address(flashPool)), address(router), owner
        );
        harness = new GatewayHarness(
            IPool(address(pool)),
            address(ausd),
            address(morpho),
            IPool(address(flashPool)),
            address(router),
            address(marketNew),
            owner
        );
        // Registry tests start empty; constructor tests exercise the initialized state separately.
        vm.startPrank(owner);
        gateway.removeMigrationTarget(address(ptNew));
        harness.removeMigrationTarget(address(ptNew));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               INTERFACES
    //////////////////////////////////////////////////////////////*/

    /// @notice The router subset hashes to the live `swapExactTokenForPt` selector
    function test_interfaces_routerSelectorMatchesLiveRouter() public pure {
        assertEq(IPendleRouterV4.swapExactTokenForPt.selector, bytes4(0xc81f847a));
    }

    /// @notice The Morpho subsets hash to the live selectors
    function test_interfaces_morphoSelectorsMatchLiveMorpho() public pure {
        assertEq(IMorphoFlashLoan.flashLoan.selector, bytes4(0xe0232b42));
        assertEq(IMorphoFlashLoanCallback.onMorphoFlashLoan.selector, bytes4(0x31f57072));
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Deployment enables the initial target and hands ownership directly to governance
    function test_constructor_registersInitialMarketAndEmits() public {
        vm.expectEmit();
        emit INeverlandPendleMaturityGateway.MigrationTargetSet(address(ptNew), address(marketNew));
        NeverlandPendleMaturityGateway deployed = _deploy(
            IPool(address(pool)), address(ausd), address(morpho), IPool(address(flashPool)), address(router), owner
        );

        assertEq(deployed.owner(), owner);
        assertEq(deployed.pendingOwner(), address(0));
        assertEq(deployed.migrationMarket(address(ptNew)), address(marketNew));
        INeverlandPendleMaturityGateway.MigrationTarget[] memory targets = deployed.migrationTargets();
        assertEq(targets.length, 1);
        assertEq(targets[0].pt, address(ptNew));
        assertEq(targets[0].market, address(marketNew));
    }

    /// @notice The initial target cannot bypass expiry, token binding, listing, or fixed-par validation
    function testFuzz_constructor_rejectsInvalidInitialMarket(uint8 scenario) public {
        scenario = uint8(bound(scenario, 0, 5));
        bytes memory expected;
        if (scenario == 0) {
            marketNew.setExpired(true);
            expected = abi.encodeWithSelector(
                INeverlandPendleMaturityGateway.TargetMarketExpired.selector, address(marketNew)
            );
        } else if (scenario == 1) {
            marketNew = new MockPendleMarket(address(syOld), address(ptNew), address(ytNew));
            expected =
                abi.encodeWithSelector(INeverlandPendleMaturityGateway.InvalidMarket.selector, address(marketNew));
        } else if (scenario == 2) {
            syNew.setValidTokenIn(address(ausd), false);
            expected = abi.encodeWithSelector(INeverlandPendleMaturityGateway.UnsupportedSy.selector, address(syNew));
        } else if (scenario == 3) {
            pool.setReserveNormalizedIncome(address(ptNew), 1e27 + 1);
            expected =
                abi.encodeWithSelector(INeverlandPendleMaturityGateway.ReserveIndexNotPar.selector, address(ptNew));
        } else if (scenario == 4) {
            (MockPendlePt pt, MockPendleSy sy, MockPendleYt yt) = _deployPrincipalToken("PT-UNLISTED");
            marketNew = new MockPendleMarket(address(sy), address(pt), address(yt));
            expected = abi.encodeWithSelector(INeverlandPendleMaturityGateway.ReserveNotListed.selector, address(pt));
        } else {
            marketNew = MockPendleMarket(address(0));
        }

        if (expected.length == 0) vm.expectRevert();
        else vm.expectRevert(expected);
        _deploy(IPool(address(pool)), address(ausd), address(morpho), IPool(address(flashPool)), address(router), owner);
    }

    /// @notice Governance can remove and restore the constructor's target; the deployer has no owner privilege
    function test_constructor_initialTargetRemainsGoverned() public {
        NeverlandPendleMaturityGateway deployed = _deploy(
            IPool(address(pool)), address(ausd), address(morpho), IPool(address(flashPool)), address(router), owner
        );
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        deployed.removeMigrationTarget(address(ptNew));
        vm.startPrank(owner);
        deployed.removeMigrationTarget(address(ptNew));
        assertEq(deployed.migrationTargets().length, 0);
        deployed.setMigrationTarget(address(marketNew));
        vm.stopPrank();
        assertEq(deployed.migrationMarket(address(ptNew)), address(marketNew));
    }

    /// @notice Construction binds the five immutables and assigns the owner with nothing pending
    function test_constructor_bindsImmutablesAndOwner() public view {
        assertEq(address(gateway.POOL()), address(pool));
        assertEq(gateway.DEBT_ASSET(), address(ausd));
        assertEq(gateway.MORPHO(), address(morpho));
        assertEq(address(gateway.FLASH_POOL()), address(flashPool));
        assertEq(gateway.PENDLE_ROUTER(), address(router));
        assertEq(gateway.owner(), owner);
        assertEq(gateway.pendingOwner(), address(0));
    }

    /// @notice A zero pool is rejected
    function test_constructor_revertsOnZeroPool() public {
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        _deploy(IPool(address(0)), address(ausd), address(morpho), IPool(address(flashPool)), address(router), owner);
    }

    /// @notice A zero debt asset is rejected
    function test_constructor_revertsOnZeroDebtAsset() public {
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        _deploy(IPool(address(pool)), address(0), address(morpho), IPool(address(flashPool)), address(router), owner);
    }

    /// @notice A zero Morpho is rejected
    function test_constructor_revertsOnZeroMorpho() public {
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        _deploy(IPool(address(pool)), address(ausd), address(0), IPool(address(flashPool)), address(router), owner);
    }

    /// @notice A zero flash pool is rejected
    function test_constructor_revertsOnZeroFlashPool() public {
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        _deploy(IPool(address(pool)), address(ausd), address(morpho), IPool(address(0)), address(router), owner);
    }

    /// @notice A zero router is rejected
    function test_constructor_revertsOnZeroRouter() public {
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        _deploy(IPool(address(pool)), address(ausd), address(morpho), IPool(address(flashPool)), address(0), owner);
    }

    /// @notice A zero owner is rejected by the base constructor
    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        _deploy(
            IPool(address(pool)), address(ausd), address(morpho), IPool(address(flashPool)), address(router), address(0)
        );
    }

    /// @notice The flash pool must differ from the position pool
    function test_constructor_revertsWhenFlashPoolIsPool() public {
        vm.expectRevert(CommonChecksLibrary.SameAddress.selector);
        _deploy(IPool(address(pool)), address(ausd), address(morpho), IPool(address(pool)), address(router), owner);
    }

    /// @notice The flash-receiver provider view forwards the position pool's provider
    function test_addressesProvider_returnsPoolProvider() public view {
        assertEq(address(gateway.ADDRESSES_PROVIDER()), pool.ADDRESSES_PROVIDER());
    }

    /*//////////////////////////////////////////////////////////////
                            MIGRATION TARGETS
    //////////////////////////////////////////////////////////////*/

    /// @notice Registering a market enables its PT and emits the pair
    function test_setMigrationTarget_registersAndEmits() public {
        vm.expectEmit(address(gateway));
        emit INeverlandPendleMaturityGateway.MigrationTargetSet(address(ptNew), address(marketNew));
        vm.prank(owner);
        gateway.setMigrationTarget(address(marketNew));

        assertEq(gateway.migrationMarket(address(ptNew)), address(marketNew));
        INeverlandPendleMaturityGateway.MigrationTarget[] memory targets = gateway.migrationTargets();
        assertEq(targets.length, 1);
        assertEq(targets[0].pt, address(ptNew));
        assertEq(targets[0].market, address(marketNew));
    }

    /// @notice A second market for the same PT replaces the first without adding an entry
    function test_setMigrationTarget_repointsExistingTarget() public {
        MockPendleMarket replacement = new MockPendleMarket(address(syNew), address(ptNew), address(ytNew));
        vm.startPrank(owner);
        gateway.setMigrationTarget(address(marketNew));

        vm.expectEmit(address(gateway));
        emit INeverlandPendleMaturityGateway.MigrationTargetSet(address(ptNew), address(replacement));
        gateway.setMigrationTarget(address(replacement));
        vm.stopPrank();

        assertEq(gateway.migrationMarket(address(ptNew)), address(replacement));
        INeverlandPendleMaturityGateway.MigrationTarget[] memory targets = gateway.migrationTargets();
        assertEq(targets.length, 1);
        assertEq(targets[0].market, address(replacement));
    }

    /// @notice A market whose PT is not a reserve of the pool is rejected
    function test_setMigrationTarget_revertsWhenPtNotListed() public {
        (MockPendlePt unlisted, MockPendleSy sy, MockPendleYt yt) = _deployPrincipalToken("PT-UNLISTED");
        MockPendleMarket market = new MockPendleMarket(address(sy), address(unlisted), address(yt));

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.ReserveNotListed.selector, address(unlisted))
        );
        vm.prank(owner);
        gateway.setMigrationTarget(address(market));
    }

    /// @notice A market whose SY differs from its PT's SY is rejected
    function test_setMigrationTarget_revertsOnSyMismatch() public {
        MockPendleMarket market = new MockPendleMarket(address(syOld), address(ptNew), address(ytNew));

        vm.expectRevert(abi.encodeWithSelector(INeverlandPendleMaturityGateway.InvalidMarket.selector, address(market)));
        vm.prank(owner);
        gateway.setMigrationTarget(address(market));
    }

    /// @notice A market whose YT differs from its PT's YT is rejected
    function test_setMigrationTarget_revertsOnYtMismatch() public {
        MockPendleMarket market = new MockPendleMarket(address(syNew), address(ptNew), address(ytOld));

        vm.expectRevert(abi.encodeWithSelector(INeverlandPendleMaturityGateway.InvalidMarket.selector, address(market)));
        vm.prank(owner);
        gateway.setMigrationTarget(address(market));
    }

    /// @notice An expired market is rejected
    function test_setMigrationTarget_revertsWhenMarketExpired() public {
        marketNew.setExpired(true);

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.TargetMarketExpired.selector, address(marketNew))
        );
        vm.prank(owner);
        gateway.setMigrationTarget(address(marketNew));
    }

    /// @notice An SY that does not accept the debt asset is rejected
    function test_setMigrationTarget_revertsWhenSyRejectsDebtAssetIn() public {
        syNew.setValidTokenIn(address(ausd), false);

        vm.expectRevert(abi.encodeWithSelector(INeverlandPendleMaturityGateway.UnsupportedSy.selector, address(syNew)));
        vm.prank(owner);
        gateway.setMigrationTarget(address(marketNew));
    }

    /// @notice An SY that does not return the debt asset is rejected
    function test_setMigrationTarget_revertsWhenSyRejectsDebtAssetOut() public {
        syNew.setValidTokenOut(address(ausd), false);

        vm.expectRevert(abi.encodeWithSelector(INeverlandPendleMaturityGateway.UnsupportedSy.selector, address(syNew)));
        vm.prank(owner);
        gateway.setMigrationTarget(address(marketNew));
    }

    /// @notice Only the owner registers targets
    function test_setMigrationTarget_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        gateway.setMigrationTarget(address(marketNew));
    }

    /// @notice Removing a target clears its market and list entry and emits the pair
    function test_removeMigrationTarget_removesAndEmits() public {
        vm.startPrank(owner);
        gateway.setMigrationTarget(address(marketNew));

        vm.expectEmit(address(gateway));
        emit INeverlandPendleMaturityGateway.MigrationTargetRemoved(address(ptNew), address(marketNew));
        gateway.removeMigrationTarget(address(ptNew));
        vm.stopPrank();

        assertEq(gateway.migrationMarket(address(ptNew)), address(0));
        assertEq(gateway.migrationTargets().length, 0);
    }

    /// @notice Removing a PT that is not enabled reverts
    function test_removeMigrationTarget_revertsWhenNotEnabled() public {
        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.MigrationTargetNotEnabled.selector, address(ptNew))
        );
        vm.prank(owner);
        gateway.removeMigrationTarget(address(ptNew));
    }

    /// @notice Only the owner removes targets
    function test_removeMigrationTarget_revertsForNonOwner() public {
        vm.prank(owner);
        gateway.setMigrationTarget(address(marketNew));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        gateway.removeMigrationTarget(address(ptNew));
    }

    /*//////////////////////////////////////////////////////////////
                                OWNERSHIP
    //////////////////////////////////////////////////////////////*/

    /// @notice The owner recovers a token held by the gateway
    function test_emergencyTokenTransfer_recoversAndEmits() public {
        ausd.mint(address(gateway), 5e18);

        vm.expectEmit(address(gateway));
        emit INeverlandPendleMaturityGateway.ERC20Recovered(address(ausd), beneficiary, 5e18);
        vm.prank(owner);
        gateway.emergencyTokenTransfer(address(ausd), beneficiary, 5e18);

        assertEq(ausd.balanceOf(beneficiary), 5e18);
        assertEq(ausd.balanceOf(address(gateway)), 0);
    }

    /// @notice Recovery to the zero address reverts
    function test_emergencyTokenTransfer_revertsForZeroRecipient() public {
        ausd.mint(address(gateway), 5e18);

        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        vm.prank(owner);
        gateway.emergencyTokenTransfer(address(ausd), address(0), 5e18);
    }

    /// @notice Only the owner recovers tokens
    function test_emergencyTokenTransfer_revertsForNonOwner() public {
        ausd.mint(address(gateway), 5e18);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        gateway.emergencyTokenTransfer(address(ausd), attacker, 5e18);
    }

    /// @notice The owner cannot renounce
    function test_renounceOwnership_revertsForOwner() public {
        vm.expectRevert(INeverlandPendleMaturityGateway.OwnershipRequired.selector);
        vm.prank(owner);
        gateway.renounceOwnership();

        assertEq(gateway.owner(), owner);
    }

    /// @notice A non-owner hits the ownership check first
    function test_renounceOwnership_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        gateway.renounceOwnership();
    }

    /// @notice Ownership moves only once the nominee accepts
    function test_transferOwnership_requiresAcceptance() public {
        address nominee = makeAddr("nominee");

        vm.prank(owner);
        gateway.transferOwnership(nominee);

        assertEq(gateway.owner(), owner);
        assertEq(gateway.pendingOwner(), nominee);

        vm.prank(nominee);
        gateway.acceptOwnership();

        assertEq(gateway.owner(), nominee);
        assertEq(gateway.pendingOwner(), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                            SOURCE AND TARGET
    //////////////////////////////////////////////////////////////*/

    /// @notice A PT that is not a reserve of the pool is rejected
    function test_resolveSource_revertsWhenNotListed() public {
        (MockPendlePt unlisted,,) = _deployPrincipalToken("PT-UNLISTED");
        unlisted.setExpired(true);

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.ReserveNotListed.selector, address(unlisted))
        );
        harness.exposed_resolveSource(address(unlisted));
    }

    /// @notice A listed reserve that fails the PT reads is not a PT, the debt asset included
    function test_resolveSource_revertsForListedNonPrincipalToken() public {
        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.NotPrincipalToken.selector, address(ausd))
        );
        harness.exposed_resolveSource(address(ausd));

        NonPrincipalToken plain = new NonPrincipalToken();
        pool.listReserve(address(plain), 1e18, 0);

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.NotPrincipalToken.selector, address(plain))
        );
        harness.exposed_resolveSource(address(plain));
    }

    /// @notice A listed reserve that reports expiry but whose `SY()` read reverts is not a PT
    function test_resolveSource_revertsWhenSyReadFails() public {
        PartialPrincipalToken partialPt = new PartialPrincipalToken();
        pool.listReserve(address(partialPt), 1e18, 0);
        partialPt.setRevertSy(true);

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.NotPrincipalToken.selector, address(partialPt))
        );
        harness.exposed_resolveSource(address(partialPt));
    }

    /// @notice A listed reserve that reports expiry and an SY but whose `YT()` read reverts is not a PT
    function test_resolveSource_revertsWhenYtReadFails() public {
        PartialPrincipalToken partialPt = new PartialPrincipalToken();
        pool.listReserve(address(partialPt), 1e18, 0);
        partialPt.setRevertYt(true);

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.NotPrincipalToken.selector, address(partialPt))
        );
        harness.exposed_resolveSource(address(partialPt));
    }

    /// @notice A PT before maturity is rejected
    function test_resolveSource_revertsBeforeMaturity() public {
        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.PrincipalTokenNotMatured.selector, address(ptOld))
        );
        harness.exposed_resolveSource(address(ptOld));
    }

    /// @notice A matured PT whose SY does not return the debt asset is rejected
    function test_resolveSource_revertsWhenSyRejectsDebtAssetOut() public {
        ptOld.setExpired(true);
        syOld.setValidTokenOut(address(ausd), false);

        vm.expectRevert(abi.encodeWithSelector(INeverlandPendleMaturityGateway.UnsupportedSy.selector, address(syOld)));
        harness.exposed_resolveSource(address(ptOld));
    }

    /// @notice A matured PT resolves to its aToken, YT, and SY
    function test_resolveSource_returnsTokens() public {
        ptOld.setExpired(true);

        NeverlandPendleMaturityGateway.SourceToken memory source = harness.exposed_resolveSource(address(ptOld));

        assertEq(source.pt, address(ptOld));
        assertEq(source.aToken, address(aPtOld));
        assertEq(source.yt, address(ytOld));
        assertEq(source.sy, address(syOld));
    }

    /// @notice A PT that is not an enabled target is rejected
    function test_resolveTarget_revertsWhenNotEnabled() public {
        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.MigrationTargetNotEnabled.selector, address(ptNew))
        );
        harness.exposed_resolveTarget(address(ptNew));
    }

    /// @notice An enabled target whose market has since expired is rejected
    function test_resolveTarget_revertsWhenMarketExpired() public {
        vm.prank(owner);
        harness.setMigrationTarget(address(marketNew));
        marketNew.setExpired(true);

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.TargetMarketExpired.selector, address(marketNew))
        );
        harness.exposed_resolveTarget(address(ptNew));
    }

    /// @notice An enabled target resolves to its market and reserve id
    function test_resolveTarget_returnsMarketAndReserveId() public {
        vm.prank(owner);
        harness.setMigrationTarget(address(marketNew));

        NeverlandPendleMaturityGateway.TargetToken memory target = harness.exposed_resolveTarget(address(ptNew));

        assertEq(target.pt, address(ptNew));
        assertEq(target.market, address(marketNew));
        assertEq(target.reserveId, pool.getReserveData(address(ptNew)).id);
        assertEq(target.reserveId, 2);
    }

    /// @notice The max sentinel uses the named user's approved balance; an explicit amount passes through
    function test_resolveAmount_resolvesMaxToUserBalance() public {
        aPtOld.mint(user, 700e18);
        aPtOld.mint(attacker, 5e18);
        vm.prank(user);
        aPtOld.approve(address(harness), 700e18);

        vm.startPrank(attacker);
        assertEq(harness.exposed_resolveAmount(user, address(aPtOld), type(uint256).max), 700e18);
        assertEq(harness.exposed_resolveAmount(user, address(aPtOld), 400e18), 400e18);
        vm.stopPrank();
    }

    /// @notice A dust donation cannot increase the amount resolved beyond the caller's exact allowance
    function test_close_maxAmountRespectsExactAllowanceAfterDonation() public {
        _openPosition(user, 1_000e18, 700e18);
        _openPosition(beneficiary, 1, 0);
        _mature();
        vm.prank(user);
        aPtOld.approve(address(gateway), 1_000e18);
        vm.prank(beneficiary);
        aPtOld.transfer(user, 1);
        ausd.mint(address(morpho), 1_000e18);

        vm.prank(user);
        INeverlandPendleMaturityGateway.CloseResult memory result =
            gateway.close(_closeParams(type(uint256).max, 0, beneficiary, 1));

        assertEq(result.ptAmount, 1_000e18);
        assertEq(aPtOld.balanceOf(user), 1);
        assertEq(debtToken.balanceOf(user), 0);
        _assertGatewayEmpty();
    }

    /// @notice Max repayment can repay all migrated value when the caller owes more than that value
    function test_migrate_maxRepaymentClampsToPartialAmount() public {
        _prepareOracleMigration(1_000e18, 700e18, 1_000e18);

        INeverlandPendleMaturityGateway.MigrateResult memory result =
            _assertMigrateParamsMatchPreview(_migrateParams(100e18, type(uint256).max, 1), false);

        assertEq(result.repay, 100e18);
        assertEq(result.spent, 0);
        assertEq(result.debtAfter, 600e18);
    }

    /// @notice A lender cannot replace the entry caller with another user who approved the gateway
    function test_close_rejectsLenderRewrittenUser() public {
        _openPosition(user, 1_000e18, 100e18);
        _openPosition(beneficiary, 100e18, 0);
        _mature();
        _approveSource(user);
        _approveSource(beneficiary);
        ausd.mint(address(morpho), 100e18);
        NeverlandPendleMaturityGateway.RoundContext memory rewritten;
        rewritten.operation = NeverlandPendleMaturityGateway.Operation.CLOSE;
        rewritten.user = beneficiary;
        rewritten.source = harness.exposed_resolveSource(address(ptOld));
        rewritten.amount = 100e18;
        rewritten.repay = 100e18;
        morpho.setCallbackData(abi.encode(rewritten));
        bytes32 beforeState = _previewState();

        vm.expectRevert(INeverlandPendleMaturityGateway.FlashCallbackUnauthorized.selector);
        vm.prank(user);
        gateway.close(_closeParams(100e18, 0, user, 1));

        assertEq(_previewState(), beforeState);
        assertEq(aPtOld.balanceOf(beneficiary), 100e18);
    }

    /// @notice An unavailable global pool cannot prevent an otherwise valid Morpho-funded close
    function test_close_globalPoolReadFailureFallsBackToMorpho() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 1_000e18);
        vm.mockCallRevert(
            address(flashPool), abi.encodeWithSelector(MockFlashPool.getReserveData.selector), bytes("unavailable")
        );

        _assertCapacity(address(morpho), 1_000e18);
        _assertCloseMatchesPreview(1_000e18);
    }

    /// @notice The par floor dominates a near-par oracle and rejects a one-unit shortfall
    function test_migrate_parFloorExactBoundary() public {
        _prepareOracleMigration(10_000, 0, 10_000);
        pool.setPrice(address(ptNew), 0.9833e18);
        router.setPriceWad(uint256(10_000e18) / 9_998);
        _assertMigrateRevertParity(
            _migrateParams(10_000, 0, 1),
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.OutputBelowMinimum.selector, 9_998, 9_999)
        );
        router.setPriceWad(uint256(10_000e18) / 9_999);

        INeverlandPendleMaturityGateway.MigrateResult memory result = _assertMigrateMatchesPreview(10_000, 0);

        assertEq(result.ptOut, 9_999);
        assertLt(result.oracleMinimumPtOut, result.ptOut);
    }

    /// @notice The par budget is applied once to aggregate spending across all swaps
    function test_migrate_parFloorAggregatesRounds() public {
        _prepareOracleMigration(20_000, 0, 10_000);
        router.setPriceWad(uint256(10_000e18) / 9_998);
        _assertMigrateRevertParity(
            _migrateParams(20_000, 0, 2),
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.OutputBelowMinimum.selector, 19_996, 19_998)
        );
        router.setPriceWad(uint256(10_000e18) / 9_999);

        INeverlandPendleMaturityGateway.MigrateResult memory result = _assertMigrateMatchesPreview(20_000, 0);

        assertEq(result.rounds, 2);
        assertEq(result.spent, 20_000);
        assertEq(result.ptOut, 19_998);
    }

    /// @notice Less than ten thousand raw units permits no par-floor loss from rounding
    function test_migrate_parFloorSmallAmountRoundsUp() public {
        _prepareOracleMigration(9_999, 0, 9_999);
        router.setPriceWad(1e18 + 1);
        _assertMigrateRevertParity(
            _migrateParams(9_999, 0, 1),
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.OutputBelowMinimum.selector, 9_998, 9_999)
        );
        router.setPriceWad(1e18);

        assertEq(_assertMigrateMatchesPreview(9_999, 0).ptOut, 9_999);
    }

    /// @notice Only purchase spending consumes the par-floor loss budget
    function test_migrate_parFloorExcludesRepayment() public {
        _prepareOracleMigration(20_000, 10_000, 20_000);
        router.setPriceWad(uint256(10_000e18) / 9_999);

        INeverlandPendleMaturityGateway.MigrateResult memory result = _assertMigrateMatchesPreview(20_000, 10_000);

        assertEq(result.repay, 10_000);
        assertEq(result.spent, 10_000);
        assertEq(result.ptOut, 9_999);
    }

    /// @notice Both lenders must echo every encoded field, then still support an unmodified multi-round call
    function test_migrate_bothLendersBindEveryRoundField() public {
        _prepareOracleMigration(1_000e18, 100e18, 500e18);
        flashPool.seed(beneficiary, 600e18);
        uint256 initial = vm.snapshotState();
        for (uint256 lender; lender < 2; ++lender) {
            vm.revertToState(initial);
            initial = vm.snapshotState();
            flashPool.ACL().setFlashBorrower(address(gateway), lender == 1);
            NeverlandPendleMaturityGateway.RoundContext memory ctx;
            ctx.operation = NeverlandPendleMaturityGateway.Operation.MIGRATE;
            ctx.user = user;
            ctx.source = harness.exposed_resolveSource(address(ptOld));
            ctx.target = NeverlandPendleMaturityGateway.TargetToken({
                pt: address(ptNew), market: address(marketNew), reserveId: pool.getReserveData(address(ptNew)).id
            });
            ctx.amount = 500e18;
            ctx.repay = 100e18;
            bytes memory original = abi.encode(ctx);
            for (uint256 word; word < original.length / 32; ++word) {
                bytes memory rewritten = abi.encode(ctx);
                rewritten[word * 32 + 31] = bytes1(uint8(rewritten[word * 32 + 31]) ^ 1);
                if (lender == 0) morpho.setCallbackData(rewritten);
                else flashPool.setCallbackData(rewritten);
                _assertMigrateRevertParity(
                    _migrateParams(1_000e18, 100e18, 2),
                    abi.encodePacked(INeverlandPendleMaturityGateway.FlashCallbackUnauthorized.selector)
                );
            }
            morpho.setCallbackData("");
            flashPool.setCallbackData("");
            INeverlandPendleMaturityGateway.MigrateResult memory result =
                _assertMigrateParamsMatchPreview(_migrateParams(1_000e18, 100e18, 2), false);

            assertEq(result.rounds, 2);
            assertEq(result.flashSource, lender == 0 ? address(morpho) : address(flashPool));
        }
    }

    /// @notice Registration, source resolution, and target resolution reject each unsupported settlement condition
    function test_parValidation_checksSourceRegistrationAndChangedTarget() public {
        _prepareOracleMigration(1_000e18, 700e18, 1_000e18);
        for (uint256 condition; condition < 4; ++condition) {
            _setUnsupportedSettlement(false, condition, true);
            _assertCloseRevertParity(
                address(ptOld),
                100e18,
                abi.encodeWithSelector(INeverlandPendleMaturityGateway.UnsupportedSy.selector, address(syOld))
            );
            _setUnsupportedSettlement(false, condition, false);
            _setUnsupportedSettlement(true, condition, true);
            vm.expectRevert(
                abi.encodeWithSelector(INeverlandPendleMaturityGateway.UnsupportedSy.selector, address(syNew))
            );
            vm.prank(owner);
            gateway.setMigrationTarget(address(marketNew));
            _assertMigrateRevertParity(
                _migrateParams(100e18, 0, 1),
                abi.encodeWithSelector(INeverlandPendleMaturityGateway.UnsupportedSy.selector, address(syNew))
            );
            _setUnsupportedSettlement(true, condition, false);
        }
        _assertMigrateMatchesPreview(100e18, 0);
    }

    /// @notice Indexes on either side of par reject registration, Close, Migrate, and their previews
    function testFuzz_parValidation_rejectsNonParReserveIndex(uint128 indexSeed, bool abovePar) public {
        uint256 index = bound(indexSeed, abovePar ? 1e27 + 1 : 0, abovePar ? type(uint128).max : 1e27 - 1);
        _prepareOracleMigration(1_000e18, 700e18, 1_000e18);
        pool.setReserveNormalizedIncome(address(ptOld), index);
        bytes memory sourceReason =
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.ReserveIndexNotPar.selector, address(ptOld));

        _assertCloseRevertParity(address(ptOld), 100e18, sourceReason);
        _assertMigrateRevertParity(_migrateParams(100e18, 0, 1), sourceReason);

        pool.setReserveNormalizedIncome(address(ptOld), 1e27);
        pool.setReserveNormalizedIncome(address(ptNew), index);
        bytes memory targetReason =
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.ReserveIndexNotPar.selector, address(ptNew));

        vm.expectRevert(targetReason);
        vm.prank(owner);
        gateway.setMigrationTarget(address(marketNew));
        _assertMigrateRevertParity(_migrateParams(100e18, 0, 1), targetReason);
    }

    /// @notice Every nested global-pool capacity read may fail without blocking a funded Morpho action
    function test_flashCapacity_allPoolReadFailuresFallBackToMorpho() public {
        _prepareOracleMigration(1_000e18, 700e18, 1_000e18);
        flashPool.seed(beneficiary, 2_000e18);
        flashPool.ACL().setFlashBorrower(address(gateway), true);
        uint256 initial = vm.snapshotState();
        for (uint256 read; read < 6; ++read) {
            vm.revertToState(initial);
            initial = vm.snapshotState();
            bytes32 beforeState = _previewState();
            _failFlashPoolRead(read);
            _assertCapacity(address(morpho), 1_000e18);
            vm.prank(user);
            INeverlandPendleMaturityGateway.MigrateResult memory preview =
                gateway.previewMigrate(_migrateParams(100e18, 0, 1));
            vm.clearMockedCalls();

            assertEq(_previewState(), beforeState);

            _failFlashPoolRead(read);
            vm.prank(user);
            INeverlandPendleMaturityGateway.MigrateResult memory actual = gateway.migrate(_migrateParams(100e18, 0, 1));
            vm.clearMockedCalls();

            assertEq(abi.encode(preview), abi.encode(actual));
            assertEq(actual.flashSource, address(morpho));
            assertEq(aPtOld.balanceOf(user), 900e18);
            assertEq(aPtNew.balanceOf(user), actual.ptOut);
            _assertNoApprovals();
            _assertGatewayEmpty();
        }
    }

    /// @notice Failed capacity reads with no Morpho cash produce the controlled liquidity error
    function test_flashCapacity_allPoolReadFailuresWithoutMorphoCash() public {
        _prepareOracleMigration(1_000e18, 700e18, 0);
        flashPool.seed(beneficiary, 2_000e18);
        flashPool.ACL().setFlashBorrower(address(gateway), true);
        bytes32 beforeState = _previewState();
        for (uint256 read; read < 6; ++read) {
            _failFlashPoolRead(read);
            _assertCapacity(address(0), 0);
            bytes memory reason = abi.encodeWithSelector(
                INeverlandPendleMaturityGateway.InsufficientFlashLiquidity.selector, 700e18, 0, 1
            );
            vm.expectRevert(reason);
            vm.prank(user);
            gateway.previewClose(_closeParams(1_000e18, 0, beneficiary, 1));
            vm.expectRevert(reason);
            vm.prank(user);
            gateway.close(_closeParams(1_000e18, 0, beneficiary, 1));
            vm.clearMockedCalls();

            assertEq(_previewState(), beforeState);
        }
    }

    /// @notice A pool capacity getter that exhausts its gas cap leaves Morpho available
    function test_flashCapacity_gasBurningPoolReadFallsBackToMorpho() public {
        _prepareOracleMigration(1_000e18, 700e18, 1_000e18);
        GatewayCapacityGasBurner burner = new GatewayCapacityGasBurner();
        vm.mockFunction(
            address(flashPool), address(burner), abi.encodeCall(MockFlashPool.getReserveData, (address(ausd)))
        );

        _assertCapacity(address(morpho), 1_000e18);
        _assertCloseMatchesPreview(1_000e18);
    }

    /// @notice A max migration consumes only the exact approval even after a source-aToken donation
    function test_migrate_maxAmountRespectsExactAllowanceAfterDonation() public {
        _prepareOracleMigration(1_000e18, 700e18, 1_000e18);
        _openPosition(beneficiary, 1, 0);
        vm.prank(user);
        aPtOld.approve(address(gateway), 1_000e18);
        vm.prank(beneficiary);
        aPtOld.transfer(user, 1);

        INeverlandPendleMaturityGateway.MigrateResult memory result = _assertMigrateMatchesPreview(type(uint256).max, 0);

        assertEq(result.ptAmount, 1_000e18);
        assertEq(aPtOld.balanceOf(user), 1);
        assertEq(aPtOld.allowance(user, address(gateway)), 0);
    }

    /// @notice An exact permit protects a max action against a dust increase in the source balance
    function test_maxAmount_exactPermitAfterDonation() public {
        _prepareOracleMigration(1_000e18, 700e18, 1_000e18);
        _openPosition(beneficiary, 1, 0);
        vm.prank(user);
        aPtOld.approve(address(gateway), 0);
        vm.prank(beneficiary);
        aPtOld.transfer(user, 1);
        uint256 initial = vm.snapshotState();
        for (uint256 action; action < 2; ++action) {
            vm.revertToState(initial);
            initial = vm.snapshotState();
            INeverlandPendleMaturityGateway.PermitParams memory permit = _permit(1_000e18);
            bytes memory previewData = action == 0
                ? abi.encodeCall(
                    gateway.previewCloseWithPermit, (_closeParams(type(uint256).max, 0, beneficiary, 1), permit)
                )
                : abi.encodeCall(gateway.previewMigrateWithPermit, (_migrateParams(type(uint256).max, 0, 1), permit));
            bytes memory actionData = action == 0
                ? abi.encodeCall(gateway.closeWithPermit, (_closeParams(type(uint256).max, 0, beneficiary, 1), permit))
                : abi.encodeCall(gateway.migrateWithPermit, (_migrateParams(type(uint256).max, 0, 1), permit));
            bytes32 beforeState = _previewState();
            vm.prank(user);
            (bool success, bytes memory preview) = address(gateway).call(previewData);

            assertTrue(success);
            assertEq(_previewState(), beforeState);

            vm.prank(user);
            bytes memory actual;
            (success, actual) = address(gateway).call(actionData);

            assertTrue(success);
            assertEq(actual, preview);
            assertEq(aPtOld.balanceOf(user), 1);
            assertEq(aPtOld.allowance(user, address(gateway)), 0);
            assertEq(aPtOld.permitCallCount(), 1);
            _assertNoApprovals();
            _assertGatewayEmpty();
        }
    }

    /// @notice Unlimited approval still resolves max to the actual balance
    function test_resolveAmount_capsUnlimitedAllowanceAtBalance() public {
        aPtOld.mint(user, 100e18);
        vm.prank(user);
        aPtOld.approve(address(harness), type(uint256).max);

        assertEq(harness.exposed_resolveAmount(user, address(aPtOld), type(uint256).max), 100e18);
    }

    /// @notice Debt above the migrated amount is repaid over every available round without buying PT
    function test_migrate_maxRepaymentClampsAcrossRoundsWithOtherCollateral() public {
        _prepareOracleMigration(1_000e18, 1_500e18, 200e18);
        _supplyFor(user, ptNew, 2_000e18);

        INeverlandPendleMaturityGateway.MigrateResult memory result =
            _assertMigrateMatchesPreview(500e18, type(uint256).max);

        assertEq(result.repay, 500e18);
        assertEq(result.spent, 0);
        assertEq(result.ptOut, 0);
        assertEq(result.rounds, 3);
        assertEq(result.debtAfter, 1_000e18);
        assertEq(aPtOld.balanceOf(user), 500e18);
        assertEq(router.swapCount(), 0);
    }

    /// @notice A full-cash first repayment restores health where an even first round cannot
    function test_close_debtLimitedUsesFullCashFirstRound() public {
        _openPosition(user, 1_000e18, 955e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 310e18);
        vm.expectCall(address(pool), abi.encodeCall(MockIsolatedPool.repay, (address(ausd), 310e18, 2, user)), 6);

        INeverlandPendleMaturityGateway.CloseResult memory result = _assertCloseMatchesPreview(type(uint256).max);

        assertEq(result.rounds, 4);
        assertEq(result.debtAfter, 0);
        assertEq(result.surplus, 45e18);
    }

    /// @notice A zero amount, explicit or from an empty balance, is rejected
    function test_resolveAmount_revertsOnZero() public {
        vm.expectRevert(INeverlandPendleMaturityGateway.InvalidAmount.selector);
        harness.exposed_resolveAmount(user, address(aPtOld), 0);

        vm.expectRevert(INeverlandPendleMaturityGateway.InvalidAmount.selector);
        harness.exposed_resolveAmount(user, address(aPtOld), type(uint256).max);
    }

    /// @notice The variable-debt token is the debt asset's in the position pool
    function test_variableDebtToken_returnsDebtAssetDebtToken() public view {
        assertEq(harness.exposed_variableDebtToken(), address(debtToken));
    }

    /// @notice Each flash source maps to its lender address
    function test_lenderOf_mapsEachSource() public view {
        assertEq(harness.exposed_lenderOf(NeverlandPendleMaturityGateway.FlashSource.NONE), address(0));
        assertEq(harness.exposed_lenderOf(NeverlandPendleMaturityGateway.FlashSource.MORPHO), address(morpho));
        assertEq(harness.exposed_lenderOf(NeverlandPendleMaturityGateway.FlashSource.POOL), address(flashPool));
    }

    /*//////////////////////////////////////////////////////////////
                             FLASH CAPACITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Without the flash-borrower role only Morpho counts, however rich the pool
    function test_flashCapacity_morphoOnlyWithoutRole() public {
        ausd.mint(address(morpho), 100e18);
        flashPool.seed(beneficiary, 400e18);

        _assertCapacity(address(morpho), 100e18);
    }

    /// @notice With the role the richer pool wins
    function test_flashCapacity_prefersLargerPoolWithRole() public {
        ausd.mint(address(morpho), 100e18);
        flashPool.seed(beneficiary, 400e18);
        flashPool.ACL().setFlashBorrower(address(gateway), true);

        _assertCapacity(address(flashPool), 400e18);
    }

    /// @notice Equal cash picks Morpho
    function test_flashCapacity_morphoOnTie() public {
        ausd.mint(address(morpho), 400e18);
        flashPool.seed(beneficiary, 400e18);
        flashPool.ACL().setFlashBorrower(address(gateway), true);

        _assertCapacity(address(morpho), 400e18);
    }

    /// @notice A paused debt reserve takes the pool out
    function test_flashCapacity_skipsPoolWhenPaused() public {
        _richerPoolWithRole();
        flashPool.setPaused(true);

        _assertCapacity(address(morpho), 100e18);
    }

    /// @notice An inactive debt reserve takes the pool out
    function test_flashCapacity_skipsPoolWhenInactive() public {
        _richerPoolWithRole();
        flashPool.setActive(false);

        _assertCapacity(address(morpho), 100e18);
    }

    /// @notice A flash-disabled debt reserve takes the pool out
    function test_flashCapacity_skipsPoolWhenFlashDisabled() public {
        _richerPoolWithRole();
        flashPool.setFlashEnabled(false);

        _assertCapacity(address(morpho), 100e18);
    }

    /// @notice A debt asset the pool does not list takes the pool out
    function test_flashCapacity_skipsPoolWhenDebtAssetNotListed() public {
        _richerPoolWithRole();
        flashPool.setListed(false);

        _assertCapacity(address(morpho), 100e18);
    }

    /// @notice Cash donated to the aToken above its supply is not lendable and is ignored
    function test_flashCapacity_poolCashCappedAtATokenSupply() public {
        ausd.mint(address(morpho), 500e18);
        flashPool.seed(beneficiary, 400e18);
        ausd.mint(address(flashPool.A_TOKEN()), 500e18);
        flashPool.ACL().setFlashBorrower(address(gateway), true);

        _assertCapacity(address(morpho), 500e18);

        ausd.burn(address(morpho), 400e18);

        _assertCapacity(address(flashPool), 400e18);
    }

    /// @notice Lent-out liquidity leaves the pool's cash below its aToken supply; the cash is what counts
    function test_flashCapacity_poolCashBelowATokenSupplyIsBalance() public {
        ausd.mint(address(morpho), 100e18);
        flashPool.seed(beneficiary, 400e18);
        ausd.burn(address(flashPool.A_TOKEN()), 150e18);
        flashPool.ACL().setFlashBorrower(address(gateway), true);

        _assertCapacity(address(flashPool), 250e18);
    }

    /// @notice No cash anywhere reports no source
    function test_flashCapacity_noneWhenBothEmpty() public {
        flashPool.ACL().setFlashBorrower(address(gateway), true);

        _assertCapacity(address(0), 0);
    }

    /// @notice Nothing to borrow skips selection and the round check
    function test_selectFlashSource_zeroTotalSkipsCheck() public view {
        (NeverlandPendleMaturityGateway.FlashSource lender, uint256 cash) = harness.exposed_selectFlashSource(0, 0);

        assertEq(uint8(lender), uint8(NeverlandPendleMaturityGateway.FlashSource.NONE));
        assertEq(cash, 0);
    }

    /// @notice A positive total with no cash anywhere reverts
    function test_selectFlashSource_revertsWhenNoCash() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                INeverlandPendleMaturityGateway.InsufficientFlashLiquidity.selector, 1_000e18, 0, uint256(5)
            )
        );
        harness.exposed_selectFlashSource(1_000e18, 5);
    }

    /// @notice The rounds needed are `ceil(total / cash)` and must fit `maxRounds`
    function test_selectFlashSource_revertsWhenRoundsExceedMax() public {
        ausd.mint(address(morpho), 300e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                INeverlandPendleMaturityGateway.InsufficientFlashLiquidity.selector, 1_000e18, 300e18, uint256(3)
            )
        );
        harness.exposed_selectFlashSource(1_000e18, 3);

        (NeverlandPendleMaturityGateway.FlashSource lender, uint256 cash) =
            harness.exposed_selectFlashSource(1_000e18, 4);

        assertEq(uint8(lender), uint8(NeverlandPendleMaturityGateway.FlashSource.MORPHO));
        assertEq(cash, 300e18);
    }

    /// @notice An exact multiple of the cash needs exactly that many rounds
    function test_selectFlashSource_exactMultipleFitsBoundary() public {
        ausd.mint(address(morpho), 300e18);

        (, uint256 cash) = harness.exposed_selectFlashSource(900e18, 3);

        assertEq(cash, 300e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                INeverlandPendleMaturityGateway.InsufficientFlashLiquidity.selector, 900e18 + 1, 300e18, uint256(3)
            )
        );
        harness.exposed_selectFlashSource(900e18 + 1, 3);
    }

    /// @notice The flash pool is selected for the harness when it holds the role and more cash
    function test_selectFlashSource_picksPoolWithRole() public {
        ausd.mint(address(morpho), 100e18);
        flashPool.seed(beneficiary, 400e18);
        flashPool.ACL().setFlashBorrower(address(harness), true);

        (NeverlandPendleMaturityGateway.FlashSource lender, uint256 cash) = harness.exposed_selectFlashSource(800e18, 2);

        assertEq(uint8(lender), uint8(NeverlandPendleMaturityGateway.FlashSource.POOL));
        assertEq(cash, 400e18);
    }

    /*//////////////////////////////////////////////////////////////
                             FLASH CALLBACKS
    //////////////////////////////////////////////////////////////*/

    /// @notice A pool callback from anyone but the flash pool is rejected
    function test_executeOperation_revertsForWrongSender() public {
        vm.expectRevert(INeverlandPendleMaturityGateway.FlashCallbackUnauthorized.selector);
        vm.prank(attacker);
        gateway.executeOperation(_array(address(ausd)), _array(1e18), _array(0), address(gateway), _roundData(1e18));
    }

    /// @notice A pool flash loan another account starts with the gateway as receiver is rejected
    function test_executeOperation_revertsForForeignInitiator() public {
        flashPool.seed(beneficiary, 100e18);

        vm.expectRevert(INeverlandPendleMaturityGateway.FlashCallbackUnauthorized.selector);
        vm.prank(attacker);
        flashPool.flashLoan(address(gateway), _array(address(ausd)), _array(1e18), _array(0), attacker, "", 0);
    }

    /// @notice The flash pool naming the gateway as initiator is rejected outside an in-flight round
    function test_executeOperation_revertsWithoutInFlightFlag() public {
        vm.expectRevert(INeverlandPendleMaturityGateway.FlashCallbackUnauthorized.selector);
        vm.prank(address(flashPool));
        harness.executeOperation(_array(address(ausd)), _array(1e18), _array(0), address(harness), _roundData(1e18));
    }

    /// @notice A callback charging any premium is rejected, even inside a pool round
    function test_executeOperation_revertsOnNonZeroPremium() public {
        harness.exposed_setInFlight(NeverlandPendleMaturityGateway.FlashSource.POOL);

        vm.expectRevert(INeverlandPendleMaturityGateway.FlashCallbackUnauthorized.selector);
        vm.prank(address(flashPool));
        harness.executeOperation(_array(address(ausd)), _array(1e18), _array(1), address(harness), _roundData(1e18));
    }

    /// @notice A callback lending two assets, or any asset but the debt asset, is rejected inside a pool round
    function test_executeOperation_revertsOnWrongAssetOrCount() public {
        harness.exposed_setInFlight(NeverlandPendleMaturityGateway.FlashSource.POOL);
        address[] memory twoAssets = new address[](2);
        twoAssets[0] = address(ausd);
        twoAssets[1] = address(ausd);
        uint256[] memory twoAmounts = new uint256[](2);
        twoAmounts[0] = 1e18;
        twoAmounts[1] = 1e18;
        uint256[] memory twoPremiums = new uint256[](2);

        vm.startPrank(address(flashPool));
        vm.expectRevert(INeverlandPendleMaturityGateway.FlashCallbackUnauthorized.selector);
        harness.executeOperation(twoAssets, twoAmounts, twoPremiums, address(harness), _roundData(1e18));

        vm.expectRevert(INeverlandPendleMaturityGateway.FlashCallbackUnauthorized.selector);
        harness.executeOperation(_array(address(ptOld)), _array(1e18), _array(0), address(harness), _roundData(1e18));
        vm.stopPrank();
    }

    /// @notice A callback whose amount or premium arrays do not hold exactly one entry is rejected
    function test_executeOperation_revertsOnAmountsOrPremiumsLength() public {
        harness.exposed_setInFlight(NeverlandPendleMaturityGateway.FlashSource.POOL);
        uint256[] memory two = new uint256[](2);
        two[0] = 1e18;
        uint256[] memory none = new uint256[](0);

        vm.startPrank(address(flashPool));
        vm.expectRevert(INeverlandPendleMaturityGateway.FlashCallbackUnauthorized.selector);
        harness.executeOperation(_array(address(ausd)), two, _array(0), address(harness), _roundData(1e18));

        vm.expectRevert(INeverlandPendleMaturityGateway.FlashCallbackUnauthorized.selector);
        harness.executeOperation(_array(address(ausd)), _array(1e18), two, address(harness), _roundData(1e18));

        vm.expectRevert(INeverlandPendleMaturityGateway.FlashCallbackUnauthorized.selector);
        harness.executeOperation(_array(address(ausd)), _array(1e18), none, address(harness), _roundData(1e18));
        vm.stopPrank();
    }

    /// @notice A pool callback during a Morpho round is rejected
    function test_executeOperation_revertsWhenFlagNamesMorpho() public {
        harness.exposed_setInFlight(NeverlandPendleMaturityGateway.FlashSource.MORPHO);

        vm.expectRevert(INeverlandPendleMaturityGateway.FlashCallbackUnauthorized.selector);
        vm.prank(address(flashPool));
        harness.executeOperation(_array(address(ausd)), _array(1e18), _array(0), address(harness), _roundData(1e18));
    }

    /// @notice A Morpho callback from anyone but Morpho is rejected
    function test_onMorphoFlashLoan_revertsForWrongSender() public {
        harness.exposed_setInFlight(NeverlandPendleMaturityGateway.FlashSource.MORPHO);

        vm.expectRevert(INeverlandPendleMaturityGateway.FlashCallbackUnauthorized.selector);
        vm.prank(attacker);
        harness.onMorphoFlashLoan(1e18, _roundData(1e18));
    }

    /// @notice Morpho calling back outside an in-flight round is rejected
    function test_onMorphoFlashLoan_revertsWithoutFlag() public {
        vm.expectRevert(INeverlandPendleMaturityGateway.FlashCallbackUnauthorized.selector);
        vm.prank(address(morpho));
        harness.onMorphoFlashLoan(1e18, _roundData(1e18));
    }

    /// @notice A Morpho callback during a pool round is rejected
    function test_onMorphoFlashLoan_revertsWhenFlagNamesPool() public {
        harness.exposed_setInFlight(NeverlandPendleMaturityGateway.FlashSource.POOL);

        vm.expectRevert(INeverlandPendleMaturityGateway.FlashCallbackUnauthorized.selector);
        vm.prank(address(morpho));
        harness.onMorphoFlashLoan(1e18, _roundData(1e18));
    }

    /// @notice A lent amount that differs from the round's amount is rejected
    function test_onMorphoFlashLoan_revertsOnAmountMismatch() public {
        _prepareOracleMigration(1_000e18, 700e18, 1_000e18);
        morpho.setCallbackAmount(1e18);

        _assertCloseParamsRevertParity(
            _closeParams(1_000e18, 0, beneficiary, 1),
            abi.encodePacked(INeverlandPendleMaturityGateway.FlashCallbackUnauthorized.selector)
        );
    }

    /// @notice A lender that returns without calling back fails the round instead of skipping it
    function test_flash_revertsWhenLenderSkipsCallback() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 1_000e18);
        morpho.setSkipCallback(true);

        vm.expectRevert(INeverlandPendleMaturityGateway.FlashCallbackUnauthorized.selector);
        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 0, beneficiary, 1));
    }

    /// @notice Each lender is repaid in full and left with no allowance
    function test_flash_resetsLenderAllowance() public {
        address other = makeAddr("other");
        _openPosition(user, 1_000e18, 700e18);
        _openPosition(other, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _approveSource(other);
        ausd.mint(address(morpho), 1_000e18);

        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 0, beneficiary, 1));

        assertEq(morpho.flashLoanCount(), 1);
        assertEq(ausd.balanceOf(address(morpho)), 1_000e18);
        assertEq(ausd.allowance(address(gateway), address(morpho)), 0);

        flashPool.seed(beneficiary, 2_000e18);
        flashPool.ACL().setFlashBorrower(address(gateway), true);

        vm.prank(other);
        gateway.close(_closeParams(type(uint256).max, 0, beneficiary, 1));

        assertEq(flashPool.flashLoanCount(), 1);
        assertEq(flashPool.lastPremium(), 0);
        assertEq(ausd.balanceOf(address(flashPool.A_TOKEN())), 2_000e18);
        assertEq(ausd.allowance(address(gateway), address(flashPool)), 0);
    }

    /// @notice A richer pool without the flash-borrower role is never called; Morpho funds every round
    function test_flash_poolWithoutRoleIsNeverUsed() public {
        _openPosition(user, 1_000e18, 300e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 100e18);
        flashPool.seed(beneficiary, 1_000e18);

        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 0, beneficiary, 3));

        assertEq(morpho.flashLoanCount(), 3);
        assertEq(flashPool.flashLoanCount(), 0);
        assertEq(debtToken.balanceOf(user), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                  CLOSE
    //////////////////////////////////////////////////////////////*/

    /// @notice A full close with debt below the PT repays everything and pays the rest to `to`
    function test_close_fullRepaysDebtAndPaysSurplus() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 1_000e18);

        vm.expectEmit(address(gateway));
        emit INeverlandPendleMaturityGateway.PositionClosed(
            user, address(ptOld), 1_000e18, 700e18, 300e18, beneficiary, 1
        );
        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 300e18, beneficiary, 1));

        assertEq(debtToken.balanceOf(user), 0);
        assertEq(aPtOld.balanceOf(user), 0);
        assertEq(ausd.balanceOf(beneficiary), 300e18);
        assertEq(ausd.balanceOf(address(morpho)), 1_000e18);
        _assertGatewayEmpty();
    }

    /// @notice Debt above the PT falls by the PT and nothing is paid out
    function test_close_debtAbovePtRepaysPtAndPaysNothing() public {
        _openPosition(user, 500e18, 700e18);
        _supplyFor(user, ptNew, 500e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 1_000e18);

        vm.expectEmit(address(gateway));
        emit INeverlandPendleMaturityGateway.PositionClosed(user, address(ptOld), 500e18, 500e18, 0, beneficiary, 1);
        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 0, beneficiary, 1));

        assertEq(debtToken.balanceOf(user), 200e18);
        assertEq(aPtOld.balanceOf(user), 0);
        assertEq(aPtNew.balanceOf(user), 500e18);
        assertEq(ausd.balanceOf(beneficiary), 0);
        _assertGatewayEmpty();
    }

    /// @notice With no debt the PT redeems without any flash loan and all of it is paid out
    function test_close_zeroDebtRedeemsWithoutFlash() public {
        _openPosition(user, 1_000e18, 0);
        _mature();
        _approveSource(user);

        vm.expectEmit(address(gateway));
        emit INeverlandPendleMaturityGateway.PositionClosed(user, address(ptOld), 1_000e18, 0, 1_000e18, beneficiary, 0);
        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 1_000e18, beneficiary, 0));

        assertEq(ausd.balanceOf(beneficiary), 1_000e18);
        assertEq(morpho.flashLoanCount(), 0);
        assertEq(flashPool.flashLoanCount(), 0);
        _assertGatewayEmpty();
    }

    /// @notice A partial amount repays only that much and leaves the rest supplied
    function test_close_partialAmount() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 1_000e18);

        vm.prank(user);
        gateway.close(_closeParams(400e18, 0, beneficiary, 1));

        assertEq(debtToken.balanceOf(user), 300e18);
        assertEq(aPtOld.balanceOf(user), 600e18);
        assertEq(ausd.balanceOf(beneficiary), 0);
        _assertGatewayEmpty();
    }

    /// @notice Morpho cash below the debt loops rounds until the debt is gone
    function test_close_multiRoundViaMorpho() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 300e18);

        vm.expectEmit(address(gateway));
        emit INeverlandPendleMaturityGateway.PositionClosed(
            user, address(ptOld), 1_000e18, 700e18, 300e18, beneficiary, 3
        );
        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 300e18, beneficiary, 3));

        assertEq(morpho.flashLoanCount(), 3);
        assertEq(ausd.balanceOf(address(morpho)), 300e18);
        assertEq(debtToken.balanceOf(user), 0);
        _assertGatewayEmpty();
    }

    /// @notice With the role the richer pool funds the rounds at zero premium
    function test_close_multiRoundViaPoolWithRole() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _richerPoolWithRole();

        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 300e18, beneficiary, 2));

        assertEq(flashPool.flashLoanCount(), 2);
        assertEq(flashPool.lastPremium(), 0);
        assertEq(morpho.flashLoanCount(), 0);
        assertEq(ausd.balanceOf(address(flashPool.A_TOKEN())), 400e18);
        assertEq(debtToken.balanceOf(user), 0);
        assertEq(ausd.balanceOf(beneficiary), 300e18);
        _assertGatewayEmpty();
    }

    /// @notice Debt that needs more rounds than allowed reverts before any flash loan
    function test_close_revertsWhenRoundsInsufficient() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 300e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                INeverlandPendleMaturityGateway.InsufficientFlashLiquidity.selector, 700e18, 300e18, uint256(2)
            )
        );
        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 0, beneficiary, 2));
    }

    /**
     * @notice An upward-rounded remainder needing one more round than allowed reverts; one more round succeeds
     * @dev Fresh debt rounding leaves two raw units after the two full-cash rounds.
     */
    function test_close_dustRoundBeyondMaxRoundsReverts() public {
        pool.setRoundingMode(MockIsolatedPool.RoundingMode.LENDING_CORE);
        _openPosition(user, 1_000e18, 700e18 + 1);
        uint256 owed = debtToken.balanceOf(user);
        assertEq(owed, 700e18 + 2);
        uint256 cash = owed / 2;
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), cash);

        vm.expectRevert(
            abi.encodeWithSelector(
                INeverlandPendleMaturityGateway.InsufficientFlashLiquidity.selector, 2, cash, uint256(2)
            )
        );
        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 0, beneficiary, 2));

        assertEq(debtToken.balanceOf(user), owed);
        assertEq(aPtOld.balanceOf(user), 1_000e18);

        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 0, beneficiary, 3));

        assertEq(debtToken.balanceOf(user), 0);
        assertEq(morpho.flashLoanCount(), 3);
        assertEq(ausd.balanceOf(beneficiary), 1_000e18 - 2 * cash - 2);
        _assertGatewayEmpty();
    }

    /// @notice A surplus below the caller's minimum reverts
    function test_close_revertsBelowMinSurplus() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 1_000e18);

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.OutputBelowMinimum.selector, 300e18, 301e18)
        );
        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 301e18, beneficiary, 1));
    }

    /// @notice A zero recipient is rejected
    function test_close_revertsForZeroRecipient() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);

        vm.expectRevert(CommonChecksLibrary.InvalidToAddress.selector);
        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 0, address(0), 1));
    }

    /// @notice A surplus paid to the gateway itself stays in it, so the entry-balance check reverts
    function test_close_toGatewayWithSurplusRevertsBalanceMismatch() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 1_000e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                INeverlandPendleMaturityGateway.BalanceMismatch.selector, address(ausd), uint256(0), 300e18
            )
        );
        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 0, address(gateway), 1));
    }

    /// @notice A zero amount is rejected
    function test_close_revertsForZeroAmount() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);

        vm.expectRevert(INeverlandPendleMaturityGateway.InvalidAmount.selector);
        vm.prank(user);
        gateway.close(_closeParams(0, 0, beneficiary, 1));
    }

    /// @notice The max sentinel over an empty balance is rejected
    function test_close_revertsForZeroBalanceWithMax() public {
        _mature();

        vm.expectRevert(INeverlandPendleMaturityGateway.InvalidAmount.selector);
        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 0, beneficiary, 1));
    }

    /// @notice A PT before maturity cannot be closed
    function test_close_revertsBeforeMaturity() public {
        _openPosition(user, 1_000e18, 700e18);
        _approveSource(user);

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.PrincipalTokenNotMatured.selector, address(ptOld))
        );
        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 0, beneficiary, 1));
    }

    /// @notice A redemption returning less than one debt asset per PT reverts with the gateway's own check
    function test_close_revertsOnRedemptionShortfall() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 1_000e18);
        syOld.setRateBps(9_999);
        syOld.setIgnoreMinOut(true);
        vm.mockCall(address(syOld), abi.encodeCall(MockPendleSy.previewRedeem, (address(ausd), 1e18)), abi.encode(1e18));

        vm.expectRevert(
            abi.encodeWithSelector(
                INeverlandPendleMaturityGateway.RedemptionShortfall.selector, 700e18, 700e18 - 700e18 / 1e4
            )
        );
        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 0, beneficiary, 1));
    }

    /// @notice A solvent position below HF 1 still closes when the debt clears in one round
    function test_close_healthFactorBelowOneStillClosesInOneRound() public {
        _openPosition(user, 1_000e18, 954e18);
        (,,,,, uint256 healthFactor) = pool.getUserAccountData(user);
        assertLt(healthFactor, 0.99e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 1_000e18);

        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 46e18, beneficiary, 1));

        assertEq(debtToken.balanceOf(user), 0);
        assertEq(ausd.balanceOf(beneficiary), 46e18);
        _assertGatewayEmpty();
    }

    /// @notice Below HF 1 a multi-round close fails at the first pull, which leaves the position still unhealthy
    function test_close_multiRoundRevertsWhenIntermediateHfBelowOne() public {
        _openPosition(user, 1_000e18, 990e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 400e18);

        vm.expectRevert(bytes("35"));
        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 0, beneficiary, 3));
    }

    /// @notice A close touches only the caller; an approval from another user cannot be used against them
    function test_close_onlyTouchesCallerPosition() public {
        address other = makeAddr("other");
        _openPosition(user, 1_000e18, 700e18);
        _openPosition(other, 800e18, 500e18);
        _mature();
        _approveSource(user);
        _approveSource(other);
        ausd.mint(address(morpho), 1_000e18);

        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 0, beneficiary, 1));

        assertEq(aPtOld.balanceOf(other), 800e18);
        assertEq(debtToken.balanceOf(other), 500e18);

        _approveSource(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, attacker, 0, uint256(800e18))
        );
        vm.prank(attacker);
        gateway.close(_closeParams(800e18, 0, attacker, 1));

        assertEq(aPtOld.balanceOf(other), 800e18);
    }

    /// @notice Tokens already held by the gateway are neither used nor paid out
    function test_close_ignoresStrayBalances() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 1_000e18);
        _seedStrays();

        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 300e18, beneficiary, 1));

        assertEq(ausd.balanceOf(beneficiary), 300e18);
        _assertStraysUnchanged();
    }

    /// @notice PT donated to the old YT redeems with the caller's PT and is paid out as surplus
    function test_close_yieldTokenDonationPaidAsSurplus() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 1_000e18);
        ptOld.mint(address(ytOld), 5e18);

        vm.expectEmit(address(gateway));
        emit INeverlandPendleMaturityGateway.PositionClosed(
            user, address(ptOld), 1_000e18, 700e18, 305e18, beneficiary, 1
        );
        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 300e18, beneficiary, 1));

        assertEq(ausd.balanceOf(beneficiary), 305e18);
        _assertGatewayEmpty();
    }

    /// @notice A close leaves no allowance to the pool, router, YT, or either lender
    function test_close_leavesNoApprovals() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 300e18);

        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 0, beneficiary, 3));

        _assertNoApprovals();
    }

    /// @notice The entry lock rejects a close re-entered from inside a round
    function test_close_guardRejectsReentry() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);
        router.setHook(
            address(gateway),
            abi.encodeCall(
                NeverlandPendleMaturityGateway.close, (_closeParams(type(uint256).max, 0, address(router), 1))
            )
        );
        router.setMode(MockPendleRouter.Mode.REENTER_CLOSE);

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        vm.prank(user);
        gateway.migrate(_migrateParams(type(uint256).max, 0, 1));
    }

    /// @notice The permit is tried with the caller's signature before the pull
    function test_closeWithPermit_usesPermit() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        ausd.mint(address(morpho), 1_000e18);
        INeverlandPendleMaturityGateway.PermitParams memory permit = _permit(1_000e18);

        vm.prank(user);
        gateway.closeWithPermit(_closeParams(type(uint256).max, 300e18, beneficiary, 1), permit);

        _assertPermitForwarded(permit);
        assertEq(debtToken.balanceOf(user), 0);
        assertEq(ausd.balanceOf(beneficiary), 300e18);
    }

    /// @notice A permit consumed by a front-runner is tolerated when the allowance is in place
    function test_closeWithPermit_toleratesFrontRunPermit() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 1_000e18);
        aPtOld.setRevertOnPermit(true);

        vm.prank(user);
        gateway.closeWithPermit(_closeParams(type(uint256).max, 300e18, beneficiary, 1), _permit(1_000e18));

        assertEq(aPtOld.permitCallCount(), 0);
        assertEq(debtToken.balanceOf(user), 0);
    }

    /// @notice A failed permit with no allowance cannot resolve a nonzero max amount
    function test_closeWithPermit_requiresAllowanceWhenPermitFails() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        ausd.mint(address(morpho), 1_000e18);
        aPtOld.setRevertOnPermit(true);

        vm.expectRevert(INeverlandPendleMaturityGateway.InvalidAmount.selector);
        vm.prank(user);
        gateway.closeWithPermit(_closeParams(type(uint256).max, 0, beneficiary, 1), _permit(1_000e18));
    }

    /// @notice A permit over an unlisted source is rejected
    function test_closeWithPermit_revertsForUnlistedSource() public {
        (MockPendlePt unlisted,,) = _deployPrincipalToken("PT-UNLISTED");
        INeverlandPendleMaturityGateway.CloseParams memory params = _closeParams(1e18, 0, beneficiary, 1);
        params.ptOld = address(unlisted);

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.ReserveNotListed.selector, address(unlisted))
        );
        vm.prank(user);
        gateway.closeWithPermit(params, _permit(1e18));
    }

    /// @notice Surplus is the PT minus the repaid debt, and the repayment is the smaller of the two
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_close_surplusEqualsPtMinusDebt(uint96 pt, uint96 debt, uint96 cash) public {
        uint256 ptAmount = bound(pt, 1, type(uint96).max);
        uint256 debtAmount = bound(debt, 0, 2 * ptAmount);
        _openPosition(user, ptAmount, debtAmount);
        if (debtAmount != 0) _supplyFor(user, ptNew, 2 * debtAmount);
        uint256 repaid = Math.min(ptAmount, debtAmount);
        uint256 cashAmount = bound(cash, repaid / 16 + 1, type(uint96).max);
        uint256 maxRounds = Math.ceilDiv(repaid, cashAmount);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), cashAmount);

        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 0, beneficiary, maxRounds));

        assertEq(debtToken.balanceOf(user), debtAmount - repaid);
        assertEq(ausd.balanceOf(beneficiary), ptAmount - repaid);
        assertEq(aPtOld.balanceOf(user), 0);
        assertEq(morpho.flashLoanCount(), maxRounds);
        assertEq(ausd.balanceOf(address(morpho)), cashAmount);
        _assertGatewayEmpty();
    }

    /**
     * @notice Under lending-core rounding a full close ends at zero debt within one extra round
     * @dev Drift is at most 2 wei per round, so one extra round suffices once the cash exceeds that; wei-scale cash can
     *      need more and then reverts `InsufficientFlashLiquidity` like any short budget.
     */
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_close_multiRoundRoundingLeavesNoDebt(uint96 debt, uint64 cash) public {
        pool.setRoundingMode(MockIsolatedPool.RoundingMode.LENDING_CORE);
        pool.mintDebt(user, bound(debt, 1e6, type(uint96).max));
        uint256 owed = debtToken.balanceOf(user);
        _supplyFor(user, ptOld, 2 * owed);
        uint256 cashAmount = bound(cash, owed / 16 + 2, owed + 2);
        uint256 rounds = Math.ceilDiv(owed, cashAmount);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), cashAmount);

        vm.prank(user);
        gateway.close(_closeParams(type(uint256).max, 0, beneficiary, rounds + 1));

        uint256 surplus = ausd.balanceOf(beneficiary);
        assertEq(debtToken.balanceOf(user), 0);
        assertLe(morpho.flashLoanCount(), rounds + 1);
        assertLe(surplus, owed);
        assertGe(surplus + 2 * morpho.flashLoanCount(), owed);
        _assertGatewayEmpty();
    }

    /*//////////////////////////////////////////////////////////////
                                 MIGRATE
    //////////////////////////////////////////////////////////////*/

    /// @notice A full migration swaps all the collateral into the target and leaves the debt
    function test_migrate_fullSwapsCollateralLeavesDebt() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);
        uint256 bought = _bought(1_000e18);

        vm.expectEmit(address(gateway));
        emit INeverlandPendleMaturityGateway.PositionMigrated(
            user, address(ptOld), address(ptNew), 1_000e18, bought, 0, 1
        );
        vm.prank(user);
        gateway.migrate(_migrateParams(type(uint256).max, 0, 1));

        assertEq(aPtOld.balanceOf(user), 0);
        assertEq(aPtNew.balanceOf(user), bought);
        assertEq(debtToken.balanceOf(user), 700e18);
        assertTrue(_usesAsCollateral(user, pool.getReserveData(address(ptNew)).id));
        assertEq(ausd.balanceOf(address(morpho)), 1_000e18);
        assertEq(router.lastReceiver(), address(gateway));
        assertEq(router.lastMarket(), address(marketNew));
        assertEq(router.lastMinPtOut(), 0);
        assertEq(router.lastTokenIn(), address(ausd));
        assertEq(router.lastNetTokenIn(), 1_000e18);
        assertEq(router.lastTokenMintSy(), address(ausd));
        assertEq(router.lastPendleSwap(), address(0));
        assertEq(uint8(router.lastSwapType()), uint8(IPendleRouterV4.SwapType.NONE));
        _assertGatewayEmpty();
    }

    /// @notice A partial migration leaves the rest of the source supplied
    function test_migrate_partialAmount() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);

        vm.prank(user);
        gateway.migrate(_migrateParams(400e18, 0, 1));

        assertEq(aPtOld.balanceOf(user), 600e18);
        assertEq(aPtNew.balanceOf(user), _bought(400e18));
        assertEq(debtToken.balanceOf(user), 700e18);
        _assertGatewayEmpty();
    }

    /// @notice A repayment larger than one round is consumed from the first even rounds; the rest buys the target
    function test_migrate_repayAmountSpansRounds() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 300e18);
        uint256 bought = _bought(50e18) + 2 * _bought(250e18);

        vm.expectCall(address(pool), abi.encodeCall(MockIsolatedPool.repay, (address(ausd), 250e18, 2, user)), 1);
        vm.expectCall(address(pool), abi.encodeCall(MockIsolatedPool.repay, (address(ausd), 200e18, 2, user)), 1);
        vm.expectEmit(address(gateway));
        emit INeverlandPendleMaturityGateway.PositionMigrated(
            user, address(ptOld), address(ptNew), 1_000e18, bought, 450e18, 4
        );
        vm.prank(user);
        gateway.migrate(_migrateParams(type(uint256).max, 450e18, 4));

        assertEq(debtToken.balanceOf(user), 250e18);
        assertEq(aPtNew.balanceOf(user), bought);
        assertEq(router.swapCount(), 3);
        assertEq(morpho.flashLoanCount(), 4);
        _assertGatewayEmpty();
    }

    /// @notice A repayment above the debt is clamped to it
    function test_migrate_repayAmountClampedToDebt() public {
        _openPosition(user, 1_000e18, 100e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);

        vm.expectEmit(address(gateway));
        emit INeverlandPendleMaturityGateway.PositionMigrated(
            user, address(ptOld), address(ptNew), 1_000e18, _bought(900e18), 100e18, 1
        );
        vm.prank(user);
        gateway.migrate(_migrateParams(type(uint256).max, 500e18, 1));

        assertEq(debtToken.balanceOf(user), 0);
        _assertGatewayEmpty();
    }

    /// @notice A clamped repayment above the migrated amount is rejected
    function test_migrate_revertsWhenRepayExceedsAmount() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();

        vm.expectRevert(INeverlandPendleMaturityGateway.InvalidAmount.selector);
        vm.prank(user);
        gateway.migrate(_migrateParams(500e18, 600e18, 1));
    }

    /// @notice A repayment equal to the round skips the purchase; a zero `minPtOut` still passes
    function test_migrate_repayConsumesWholeRoundSkipsPurchase() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);

        vm.expectEmit(address(gateway));
        emit INeverlandPendleMaturityGateway.PositionMigrated(
            user, address(ptOld), address(ptNew), 700e18, 0, 700e18, 1
        );
        vm.prank(user);
        gateway.migrate(_migrateParams(700e18, 700e18, 1));

        assertEq(router.swapCount(), 0);
        assertEq(debtToken.balanceOf(user), 0);
        assertEq(aPtOld.balanceOf(user), 300e18);
        assertEq(aPtNew.balanceOf(user), 0);
        _assertGatewayEmpty();
    }

    /// @notice A single-round migration always uses the bounded on-chain search
    function test_migrate_singleRoundUsesSafeSearch() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(type(uint256).max, 0, 1);

        vm.prank(user);
        gateway.migrate(params);

        _assertApprox(router.lastApprox(), IPendleRouterV4.ApproxParams(0, type(uint256).max, 0, 256, 5e13));
    }

    /// @notice Every migration round uses the router's bounded on-chain search
    function test_migrate_multiRoundPassesDefaultApprox() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 600e18);
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(type(uint256).max, 0, 2);

        vm.prank(user);
        gateway.migrate(params);

        assertEq(router.swapCount(), 2);
        _assertApprox(router.lastApprox(), IPendleRouterV4.ApproxParams(0, type(uint256).max, 0, 256, 5e13));
    }

    /// @notice Target PT below the caller's minimum over the whole call reverts
    function test_migrate_revertsBelowMinPtOut() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 600e18);
        uint256 bought = 2 * _bought(500e18);
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(type(uint256).max, 0, 2);
        params.minPtOut = bought + 1;

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.OutputBelowMinimum.selector, bought, bought + 1)
        );
        vm.prank(user);
        gateway.migrate(params);
    }

    /// @notice Target PT exactly at the caller's minimum passes
    function test_migrate_minPtOutEqualToOutputPasses() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 600e18);
        uint256 bought = 2 * _bought(500e18);
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(type(uint256).max, 0, 2);
        params.minPtOut = bought;

        vm.prank(user);
        gateway.migrate(params);

        assertEq(aPtNew.balanceOf(user), bought);
        _assertGatewayEmpty();
    }

    /// @notice A zero caller minimum cannot allow more than 10% less output than the oracle reference
    function test_migrate_oracleFloorRejectsBadPriceAndRollsBack() public {
        _prepareOracleMigration(1_000e18, 0, 600e18);
        router.setPriceWad(2e18);
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(1_000e18, 0, 2);

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.OutputBelowMinimum.selector, 500e18, 999.9e18)
        );
        vm.prank(user);
        gateway.migrate(params);

        assertEq(aPtOld.balanceOf(user), 1_000e18);
        assertEq(aPtNew.balanceOf(user), 0);
        assertEq(ausd.balanceOf(address(morpho)), 600e18);
        assertEq(ausd.balanceOf(address(router)), 0);
        assertEq(router.swapCount(), 0);
        _assertGatewayEmpty();
        _assertNoApprovals();
    }

    /// @notice Exactly 90% of the oracle reference passes, while one raw PT unit less reverts
    function test_migrate_oracleFloorExactBoundary() public {
        _prepareOracleMigration(10, 0, 10);
        pool.setPrice(address(ptNew), 0.9e18);
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(10, 0, 1);
        router.setPriceWad(1e18 + 1);

        vm.expectRevert(abi.encodeWithSelector(INeverlandPendleMaturityGateway.OutputBelowMinimum.selector, 9, 10));
        vm.prank(user);
        gateway.migrate(params);

        router.setPriceWad(1e18);
        vm.prank(user);
        gateway.migrate(params);

        assertEq(aPtNew.balanceOf(user), 10);
        _assertGatewayEmpty();
    }

    /// @notice Fractional minimum output rounds up rather than allowing a one-unit shortfall
    function test_migrate_oracleFloorRoundsUp() public {
        _prepareOracleMigration(2, 0, 2);
        pool.setPrice(address(ptNew), 1.1e18);
        router.setPriceWad(2e18);
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(2, 0, 1);

        vm.expectRevert(abi.encodeWithSelector(INeverlandPendleMaturityGateway.OutputBelowMinimum.selector, 1, 2));
        vm.prank(user);
        gateway.migrate(params);
    }

    /// @notice Repayment across several rounds is excluded from the oracle purchase floor
    function test_migrate_oracleFloorExcludesRepayment() public {
        _prepareOracleMigration(1_000e18, 600e18, 400e18);
        pool.setPrice(address(ptNew), 0.9e18);
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(1_000e18, type(uint256).max, 3);

        vm.prank(user);
        gateway.migrate(params);

        assertEq(aPtNew.balanceOf(user), 400e18);
        assertEq(debtToken.balanceOf(user), 0);
        assertEq(ausd.balanceOf(address(router)), 400e18);
        assertEq(morpho.flashLoanCount(), 3);
        _assertGatewayEmpty();
    }

    /// @notice The debt-asset oracle price participates in the floor instead of assuming a dollar peg
    function test_migrate_oracleFloorUsesDebtAssetPrice() public {
        _prepareOracleMigration(1_000e18, 0, 1_000e18);
        pool.setPrice(address(ausd), 2e18);
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(1_000e18, 0, 1);

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.OutputBelowMinimum.selector, 1_000e18, 1_800e18)
        );
        vm.prank(user);
        gateway.migrate(params);
    }

    /// @notice Both price legs must be positive even when the caller ends without debt
    function test_migrate_oracleFloorRejectsZeroPrices() public {
        _prepareOracleMigration(1_000e18, 0, 1_000e18);
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(1_000e18, 0, 1);
        pool.setPrice(address(ausd), 0);

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.InvalidOraclePrice.selector, address(ausd))
        );
        vm.prank(user);
        gateway.migrate(params);

        pool.setPrice(address(ausd), 1e18);
        pool.setPrice(address(ptNew), 0);

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.InvalidOraclePrice.selector, address(ptNew))
        );
        vm.prank(user);
        gateway.migrate(params);

        assertEq(aPtOld.balanceOf(user), 1_000e18);
        assertEq(aPtNew.balanceOf(user), 0);
    }

    /// @notice An unavailable oracle cannot fall back to a zero caller minimum
    function test_migrate_oracleFloorPropagatesOracleFailure() public {
        _prepareOracleMigration(1_000e18, 0, 1_000e18);
        vm.mockCallRevert(
            address(pool),
            abi.encodeWithSelector(MockIsolatedPool.getAssetPrice.selector, address(ptNew)),
            bytes("oracle unavailable")
        );
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(1_000e18, 0, 1);

        vm.expectRevert(bytes("oracle unavailable"));
        vm.prank(user);
        gateway.migrate(params);

        assertEq(aPtOld.balanceOf(user), 1_000e18);
        assertEq(ausd.balanceOf(address(morpho)), 1_000e18);
    }

    /// @notice The floor follows an oracle replacement in the pool's addresses provider
    function test_migrate_oracleFloorUsesCurrentPoolOracle() public {
        _prepareOracleMigration(1_000e18, 0, 1_000e18);
        MockIsolatedPool replacement =
            new MockIsolatedPool(address(ausd), address(new MockAddressesProvider(address(new MockAclManager()))));
        replacement.setPrice(address(ausd), 1e18);
        replacement.setPrice(address(ptNew), 0.5e18);
        MockAddressesProvider(pool.ADDRESSES_PROVIDER()).setPriceOracle(address(replacement));
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(1_000e18, 0, 1);

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.OutputBelowMinimum.selector, 1_000e18, 1_800e18)
        );
        vm.prank(user);
        gateway.migrate(params);
    }

    /// @notice A repayment-only migration still works without any oracle price
    function test_migrate_oracleFloorSkipsPriceWhenNothingBought() public {
        _prepareOracleMigration(100e18, 100e18, 100e18);
        MockAddressesProvider(pool.ADDRESSES_PROVIDER()).setPriceOracle(address(0));

        vm.prank(user);
        gateway.migrate(_migrateParams(100e18, type(uint256).max, 1));

        assertEq(debtToken.balanceOf(user), 0);
        assertEq(aPtOld.balanceOf(user), 0);
        assertEq(aPtNew.balanceOf(user), 0);
        _assertGatewayEmpty();
    }

    /// @notice A source with different reserve units is rejected before its tokens move
    function test_migrate_rejectsHigherSourceDecimals() public {
        _prepareOracleMigration(1e6, 0, 1e6);
        pool.setReserveDecimals(address(ausd), 6);

        _assertMigrateRevertParity(
            _migrateParams(1e6, 0, 1),
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.UnsupportedSy.selector, address(syOld))
        );
    }

    /// @notice An enabled target is revalidated when its reserve units change
    function test_migrate_rejectsLowerTargetDecimals() public {
        _prepareOracleMigration(1e18, 0, 1e18);
        pool.setReserveDecimals(address(ptNew), 6);

        _assertMigrateRevertParity(
            _migrateParams(1e18, 0, 1),
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.UnsupportedSy.selector, address(syNew))
        );
    }

    /// @notice Equal-unit reserves require the smallest integer output preserving 90% of oracle value
    function testFuzz_oracleFloorPreservesValue(uint96 spent, uint64 debtPrice, uint64 ptPrice, uint8 decimals) public {
        spent = uint96(bound(spent, 1, type(uint96).max));
        debtPrice = uint64(bound(debtPrice, 1, 1e12));
        ptPrice = uint64(bound(ptPrice, 1, 1e12));
        decimals = uint8(bound(decimals, 0, 24));
        pool.setPrice(address(ausd), debtPrice);
        pool.setPrice(address(ptNew), ptPrice);
        pool.setReserveDecimals(address(ausd), decimals);
        pool.setReserveDecimals(address(ptNew), decimals);

        uint256 minimum = harness.exposed_oracleMinimum(address(ptNew), spent);

        uint256 inputValue = uint256(spent) * debtPrice * 9;
        uint256 outputUnitValue = uint256(ptPrice) * 10;
        assertGe(minimum * outputUnitValue, inputValue);
        assertLt((minimum - 1) * outputUnitValue, inputValue);
    }

    /// @notice A final health factor below the caller's minimum reverts
    function test_migrate_revertsBelowMinHealthFactor() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);
        uint256 snapshot = vm.snapshotState();
        vm.prank(user);
        gateway.migrate(_migrateParams(type(uint256).max, 0, 1));
        (,,,,, uint256 healthFactor) = pool.getUserAccountData(user);
        vm.revertToState(snapshot);
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(type(uint256).max, 0, 1);
        params.minHealthFactor = healthFactor + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                INeverlandPendleMaturityGateway.HealthFactorBelowMinimum.selector, healthFactor, healthFactor + 1
            )
        );
        vm.prank(user);
        gateway.migrate(params);

        params.minHealthFactor = healthFactor;
        vm.prank(user);
        gateway.migrate(params);
    }

    /// @notice A zero minimum leaves only the pool's own check, so a thin position still migrates
    function test_migrate_zeroMinHealthFactorSkipsCheck() public {
        _openPosition(user, 1_000e18, 929e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);

        vm.mockCallRevert(
            address(pool),
            abi.encodeWithSelector(MockIsolatedPool.getUserAccountData.selector),
            bytes("report unavailable")
        );
        vm.prank(user);
        INeverlandPendleMaturityGateway.MigrateResult memory result =
            gateway.migrate(_migrateParams(type(uint256).max, 0, 1));

        assertFalse(result.healthFactorAvailable);
        assertEq(result.healthFactorAfter, 0);

        uint256 healthFactor = aPtNew.balanceOf(user) * 0.985e18 / 1e18 * PT_LT_BPS / 10_000 * 1e18 / 929e18;
        assertGe(healthFactor, 1e18);
        assertLt(healthFactor, 1.002e18);
    }

    /// @notice Without debt after the migration the minimum is not checked
    function test_migrate_noDebtSkipsHealthCheck() public {
        _openPosition(user, 1_000e18, 0);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(type(uint256).max, 0, 1);
        params.minHealthFactor = type(uint256).max;

        vm.expectCall(address(pool), abi.encodeWithSelector(MockIsolatedPool.getUserAccountData.selector), 0);
        vm.prank(user);
        gateway.migrate(params);

        assertEq(aPtNew.balanceOf(user), _bought(1_000e18));
    }

    /// @notice A first supply that leaves the target off as collateral reverts
    function test_migrate_revertsWhenCollateralNotEnabled() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);
        pool.setCollateralEnabledOnSupply(false);

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.CollateralNotEnabled.selector, address(ptNew))
        );
        vm.prank(user);
        gateway.migrate(_migrateParams(type(uint256).max, 0, 1));
    }

    /// @notice An unregistered target is rejected
    function test_migrate_revertsWhenTargetNotEnabled() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.MigrationTargetNotEnabled.selector, address(ptNew))
        );
        vm.prank(user);
        gateway.migrate(_migrateParams(type(uint256).max, 0, 1));
    }

    /// @notice A registered target whose market has expired is rejected
    function test_migrate_revertsWhenTargetMarketExpired() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        marketNew.setExpired(true);

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.TargetMarketExpired.selector, address(marketNew))
        );
        vm.prank(user);
        gateway.migrate(_migrateParams(type(uint256).max, 0, 1));
    }

    /// @notice A matured PT registered as its own target is rejected, since its market expired with it
    function test_migrate_revertsWhenTargetIsMaturedSource() public {
        MockPendleMarket marketOld = new MockPendleMarket(address(syOld), address(ptOld), address(ytOld));
        vm.prank(owner);
        gateway.setMigrationTarget(address(marketOld));
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        marketOld.setExpired(true);
        _approveSource(user);
        ausd.mint(address(morpho), 1_000e18);
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(type(uint256).max, 0, 1);
        params.ptNew = address(ptOld);

        vm.expectRevert(
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.TargetMarketExpired.selector, address(marketOld))
        );
        vm.prank(user);
        gateway.migrate(params);
    }

    /// @notice `maxRounds` one below `ceil(ptAmount / cash)` reverts before any flash loan; exactly that many passes
    function test_migrate_maxRoundsBoundary() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 250e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                INeverlandPendleMaturityGateway.InsufficientFlashLiquidity.selector, 1_000e18, 250e18, uint256(3)
            )
        );
        vm.prank(user);
        gateway.migrate(_migrateParams(type(uint256).max, 0, 3));

        vm.prank(user);
        gateway.migrate(_migrateParams(type(uint256).max, 0, 4));

        assertEq(morpho.flashLoanCount(), 4);
        assertEq(aPtOld.balanceOf(user), 0);
        assertEq(aPtNew.balanceOf(user), 4 * _bought(250e18));
        _assertGatewayEmpty();
    }

    /// @notice A source pull that would leave the position below HF 1 reverts in the pool
    function test_migrate_revertsWhenHfDropsBelowOne() public {
        _openPosition(user, 1_000e18, 932e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);

        vm.expectRevert(bytes("35"));
        vm.prank(user);
        gateway.migrate(_migrateParams(type(uint256).max, 0, 1));
    }

    /// @notice A router pulling more than the exact allowance reverts
    function test_migrate_routerPullingExtraReverts() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);
        router.setMode(MockPendleRouter.Mode.PULL_EXTRA);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(router), 1_000e18, uint256(1_000e18 + 1)
            )
        );
        vm.prank(user);
        gateway.migrate(_migrateParams(type(uint256).max, 0, 1));
    }

    /// @notice A pool flash loan naming the gateway, started from inside a round, is rejected
    function test_migrate_flashPoolSpoofDuringRoundRejected() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);
        flashPool.seed(beneficiary, 100e18);
        router.setHook(
            address(flashPool),
            abi.encodeCall(
                MockFlashPool.flashLoan,
                (address(gateway), _array(address(ausd)), _array(1e18), _array(0), address(gateway), "", 0)
            )
        );
        router.setMode(MockPendleRouter.Mode.FLASH_POOL_SPOOF);

        vm.expectRevert(INeverlandPendleMaturityGateway.FlashCallbackUnauthorized.selector);
        vm.prank(user);
        gateway.migrate(_migrateParams(type(uint256).max, 0, 1));
    }

    /// @notice The owner's rescue cannot run inside a user call
    function test_emergencyTokenTransfer_blockedDuringCall() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);
        vm.prank(owner);
        gateway.transferOwnership(address(router));
        vm.prank(address(router));
        gateway.acceptOwnership();
        router.setHook(
            address(gateway),
            abi.encodeCall(NeverlandPendleMaturityGateway.emergencyTokenTransfer, (address(ausd), attacker, 1e18))
        );
        router.setMode(MockPendleRouter.Mode.REENTER_CLOSE);

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        vm.prank(user);
        gateway.migrate(_migrateParams(type(uint256).max, 0, 1));
    }

    /// @notice PT donated to the old YT is forwarded to the caller instead of failing the balance check
    function test_migrate_yieldTokenDonationForwardedToCaller() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);
        ptOld.mint(address(ytOld), 5e18);

        vm.prank(user);
        gateway.migrate(_migrateParams(type(uint256).max, 0, 1));

        assertEq(ausd.balanceOf(user), 5e18);
        assertEq(aPtNew.balanceOf(user), _bought(1_000e18));
        _assertGatewayEmpty();
    }

    /// @notice Two migrations in one transaction each report only their own supplied target PT
    function test_migrate_twiceInOneTransaction() public {
        BatchCaller batch = new BatchCaller();
        _openPosition(address(batch), 1_000e18, 700e18);
        _mature();
        _approveSource(address(batch));
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);
        uint256 bought = _bought(500e18);

        vm.expectEmit(address(gateway));
        emit INeverlandPendleMaturityGateway.PositionMigrated(
            address(batch), address(ptOld), address(ptNew), 500e18, bought, 0, 1
        );
        vm.expectEmit(address(gateway));
        emit INeverlandPendleMaturityGateway.PositionMigrated(
            address(batch), address(ptOld), address(ptNew), 500e18, bought, 0, 1
        );
        batch.migrateTwice(gateway, _migrateParams(500e18, 0, 1), _migrateParams(500e18, 0, 1));

        assertEq(aPtOld.balanceOf(address(batch)), 0);
        assertEq(aPtNew.balanceOf(address(batch)), 2 * bought);
        _assertGatewayEmpty();
    }

    /// @notice Tokens already held by the gateway are neither used nor paid out
    function test_migrate_ignoresStrayBalances() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);
        _seedStrays();
        ptNew.mint(address(gateway), 13e18);

        vm.prank(user);
        gateway.migrate(_migrateParams(type(uint256).max, 0, 1));

        assertEq(ausd.balanceOf(user), 0);
        assertEq(aPtNew.balanceOf(user), _bought(1_000e18));
        assertEq(ptNew.balanceOf(address(gateway)), 13e18);
        _assertStraysUnchanged();
    }

    /// @notice A migration leaves no allowance to the pool, router, YT, or either lender
    function test_migrate_leavesNoApprovals() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 300e18);

        vm.prank(user);
        gateway.migrate(_migrateParams(type(uint256).max, 200e18, 4));

        _assertNoApprovals();
        assertEq(ptNew.allowance(address(gateway), address(pool)), 0);
    }

    /// @notice A 1-wei partial repayment burns no debt shares and reverts cleanly in the pool
    function test_migrate_oneWeiRepayRemainderRevertsCleanly() public {
        pool.setRoundingMode(MockIsolatedPool.RoundingMode.LENDING_CORE);
        _openPosition(user, 1_000e18, 700e18);
        uint256 owed = debtToken.balanceOf(user);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);

        vm.expectRevert(bytes("25"));
        vm.prank(user);
        gateway.migrate(_migrateParams(type(uint256).max, 1, 1));

        assertEq(debtToken.balanceOf(user), owed);
        assertEq(aPtOld.balanceOf(user), 1_000e18);
        assertEq(aPtNew.balanceOf(user), 0);
    }

    /// @notice The permit is tried with the caller's signature before the pull
    function test_migrateWithPermit_usesPermit() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);
        INeverlandPendleMaturityGateway.PermitParams memory permit = _permit(1_000e18);

        vm.prank(user);
        gateway.migrateWithPermit(_migrateParams(type(uint256).max, 0, 1), permit);

        _assertPermitForwarded(permit);
        assertEq(aPtNew.balanceOf(user), _bought(1_000e18));
    }

    /// @notice A permit consumed by a front-runner is tolerated when the allowance is in place
    function test_migrateWithPermit_toleratesFrontRunPermit() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);
        aPtOld.setRevertOnPermit(true);

        vm.prank(user);
        gateway.migrateWithPermit(_migrateParams(type(uint256).max, 0, 1), _permit(1_000e18));

        assertEq(aPtOld.permitCallCount(), 0);
        assertEq(aPtNew.balanceOf(user), _bought(1_000e18));
    }

    /**
     * @notice Under lending-core rounding the debt falls by the clamped repayment, less at most 2 wei per partial repay
     *         round; a repayment covering the whole debt clears it exactly
     */
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_migrate_debtChangesByClampedRepay(uint96 pt, uint96 debt, uint96 repay, uint96 cash) public {
        pool.setRoundingMode(MockIsolatedPool.RoundingMode.LENDING_CORE);
        uint256 ptAmount = bound(pt, 1e6, type(uint96).max);
        _openPosition(user, ptAmount, bound(debt, 0, ptAmount * 9 / 10));
        uint256 owed = debtToken.balanceOf(user);
        uint256 cashAmount = bound(cash, ptAmount / 8 + 1, ptAmount);
        uint256 repayAmount = bound(repay, 0, ptAmount);
        uint256 clamped = Math.min(repayAmount, owed);
        (uint256 repayRounds, bool oneWeiChunk) = _repayChunks(ptAmount, cashAmount, clamped);
        vm.assume(repayAmount >= owed || !oneWeiChunk);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), cashAmount);

        vm.prank(user);
        gateway.migrate(_migrateParams(type(uint256).max, repayAmount, Math.ceilDiv(ptAmount, cashAmount)));

        uint256 decrease = owed - debtToken.balanceOf(user);
        assertLe(decrease, clamped);
        assertGe(decrease + 2 * repayRounds, clamped);
        if (repayAmount >= owed) assertEq(debtToken.balanceOf(user), 0);
        assertEq(aPtOld.balanceOf(user), 0);
        assertEq(ausd.balanceOf(address(morpho)), cashAmount);
        _assertGatewayEmpty();
    }

    /// @notice Asking to repay the whole debt clears it exactly across rounds under lending-core rounding
    function test_migrate_fullRepayClearsDebtUnderRounding() public {
        pool.setRoundingMode(MockIsolatedPool.RoundingMode.LENDING_CORE);
        _openPosition(user, 1_000e18, 700e18 + 1);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 300e18);

        vm.prank(user);
        gateway.migrate(_migrateParams(type(uint256).max, type(uint256).max, 4));

        assertEq(debtToken.balanceOf(user), 0);
        assertFalse(_isBorrowing(user, pool.getReserveData(address(ausd)).id));
        assertEq(aPtOld.balanceOf(user), 0);
        assertEq(morpho.flashLoanCount(), 4);
        _assertGatewayEmpty();
    }

    /// @notice A repayment one wei short of the debt keeps the partial path and leaves the remainder owed
    function test_migrate_partialRepayKeepsRemainder() public {
        pool.setRoundingMode(MockIsolatedPool.RoundingMode.LENDING_CORE);
        _openPosition(user, 1_000e18, 700e18 + 1);
        uint256 owed = debtToken.balanceOf(user);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 300e18);

        vm.prank(user);
        gateway.migrate(_migrateParams(type(uint256).max, owed - 2, 4));

        assertGe(debtToken.balanceOf(user), 2);
        assertLe(debtToken.balanceOf(user), 6);
        assertTrue(_isBorrowing(user, pool.getReserveData(address(ausd)).id));
        _assertGatewayEmpty();
    }

    /// @notice The minimum is enforced while the user borrows any reserve, even with no debt-asset debt
    function test_migrate_minHealthFactorEnforcedWhenBorrowingOtherReserve() public {
        MockGatewayToken otherAsset = new MockGatewayToken("Other", "OTH");
        pool.listReserve(address(otherAsset), 1e18, 0);
        _openPosition(user, 1_000e18, 0);
        pool.setBorrowing(user, address(otherAsset), true);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(type(uint256).max, 0, 1);
        params.minHealthFactor = 1e18;
        vm.mockCall(
            address(pool),
            abi.encodeWithSelector(MockIsolatedPool.getUserAccountData.selector, user),
            abi.encode(uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0.9e18))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                INeverlandPendleMaturityGateway.HealthFactorBelowMinimum.selector, uint256(0.9e18), uint256(1e18)
            )
        );
        vm.prank(user);
        gateway.migrate(params);
    }

    /// @notice Rounds are sized evenly, so `2 * cash + 1` runs three near-equal rounds with no 1-wei tail
    function test_migrate_evenRoundsAvoidWeiTail() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 300e18);
        uint256 ptAmount = 600e18 + 1;
        uint256 bought = _bought(200e18 + 1) + 2 * _bought(200e18);

        vm.expectCall(
            address(morpho), abi.encodeWithSelector(MockMorpho.flashLoan.selector, address(ausd), 200e18 + 1), 1
        );
        vm.expectCall(address(morpho), abi.encodeWithSelector(MockMorpho.flashLoan.selector, address(ausd), 200e18), 2);
        vm.expectEmit(address(gateway));
        emit INeverlandPendleMaturityGateway.PositionMigrated(
            user, address(ptOld), address(ptNew), ptAmount, bought, 0, 3
        );
        vm.prank(user);
        gateway.migrate(_migrateParams(ptAmount, 0, 3));

        assertEq(router.swapCount(), 3);
        assertEq(router.lastNetTokenIn(), 200e18);
        _assertGatewayEmpty();
    }

    /// @notice With the role the richer pool funds every migration round at zero premium and keeps no allowance
    function test_migrate_multiRoundViaPoolWithRole() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        _richerPoolWithRole();

        vm.prank(user);
        gateway.migrate(_migrateParams(type(uint256).max, 0, 3));

        assertEq(flashPool.flashLoanCount(), 3);
        assertEq(flashPool.lastPremium(), 0);
        assertEq(morpho.flashLoanCount(), 0);
        assertEq(ausd.balanceOf(address(flashPool.A_TOKEN())), 400e18);
        assertEq(aPtOld.balanceOf(user), 0);
        assertEq(
            aPtNew.balanceOf(user), _bought(333_333_333_333_333_333_334) + 2 * _bought(333_333_333_333_333_333_333)
        );
        _assertNoApprovals();
        assertEq(ptNew.allowance(address(gateway), address(pool)), 0);
        _assertGatewayEmpty();
    }

    /// @notice The end-of-call check rejects any change to the debt asset or either PT, and skips a zero target
    function test_assertSnapshot_revertsOnAnyChangedBalance() public {
        ausd.mint(address(harness), 5);
        ptOld.mint(address(harness), 7);
        ptNew.mint(address(harness), 11);
        NeverlandPendleMaturityGateway.BalanceSnapshot memory entry =
            harness.exposed_snapshot(address(ptOld), address(ptNew));
        NeverlandPendleMaturityGateway.BalanceSnapshot memory closeEntry =
            harness.exposed_snapshot(address(ptOld), address(0));

        assertEq(entry.debtAsset, 5);
        assertEq(entry.ptOld, 7);
        assertEq(entry.ptNew, 11);
        assertEq(closeEntry.ptNew, 0);
        harness.exposed_assertSnapshot(entry, address(ptOld), address(ptNew));
        harness.exposed_assertSnapshot(closeEntry, address(ptOld), address(0));

        ptNew.mint(address(harness), 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                INeverlandPendleMaturityGateway.BalanceMismatch.selector, address(ptNew), uint256(11), uint256(12)
            )
        );
        harness.exposed_assertSnapshot(entry, address(ptOld), address(ptNew));

        ptOld.burn(address(harness), 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                INeverlandPendleMaturityGateway.BalanceMismatch.selector, address(ptOld), uint256(7), uint256(6)
            )
        );
        harness.exposed_assertSnapshot(closeEntry, address(ptOld), address(0));

        ausd.mint(address(harness), 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                INeverlandPendleMaturityGateway.BalanceMismatch.selector, address(ausd), uint256(5), uint256(6)
            )
        );
        harness.exposed_assertSnapshot(entry, address(ptOld), address(ptNew));
    }

    /*//////////////////////////////////////////////////////////////
                                PREVIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Both paths reject an explicit amount above the caller's source balance
    function test_previewClose_rejectsExcessiveBalanceRegression() public {
        _openPosition(user, 100e18, 0);
        _mature();
        _approveSource(user);

        _assertCloseRevertParity(
            address(ptOld),
            101e18,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user, 100e18, 101e18)
        );
    }

    /// @notice A debt-free close previews a flash-free redemption of the caller's whole balance
    function test_previewClose_noDebtNeedsNoFlash() public {
        _openPosition(user, 1_000e18, 0);
        _mature();
        _approveSource(user);

        INeverlandPendleMaturityGateway.CloseResult memory preview = _assertCloseMatchesPreview(type(uint256).max);

        assertEq(preview.ptAmount, 1_000e18);
        assertEq(preview.debt, 0);
        assertEq(preview.debtRepaid, 0);
        assertEq(preview.surplus, 1_000e18);
        assertEq(preview.flashSource, address(0));
        assertEq(preview.flashCash, 0);
        assertEq(preview.rounds, 0);
        assertEq(preview.healthFactorAfter, type(uint256).max);
    }

    /// @notice A full close previews the whole repayment, the surplus, one Morpho round, and no remaining debt
    function test_previewClose_fullRepay() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 1_000e18);

        INeverlandPendleMaturityGateway.CloseResult memory preview = _assertCloseMatchesPreview(type(uint256).max);

        assertEq(preview.ptAmount, 1_000e18);
        assertEq(preview.debt, 700e18);
        assertEq(preview.debtRepaid, 700e18);
        assertEq(preview.surplus, 300e18);
        assertEq(preview.flashSource, address(morpho));
        assertEq(preview.flashCash, 1_000e18);
        assertEq(preview.rounds, 1);
        assertEq(preview.healthFactorAfter, type(uint256).max);
    }

    /// @notice Debt above the PT previews a repayment of the PT, no surplus, and the health factor of what remains
    function test_previewClose_debtAbovePt() public {
        _openPosition(user, 500e18, 700e18);
        _supplyFor(user, ptNew, 500e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 1_000e18);

        INeverlandPendleMaturityGateway.CloseResult memory preview = _assertCloseMatchesPreview(type(uint256).max);

        assertEq(preview.debtRepaid, 500e18);
        assertEq(preview.surplus, 0);
        assertEq(preview.rounds, 1);
        assertEq(preview.healthFactorAfter, 2.3024375e18);
    }

    /// @notice A partial close previews the remaining collateral against the remaining debt
    function test_previewClose_partialAmount() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 1_000e18);

        INeverlandPendleMaturityGateway.CloseResult memory preview = _assertCloseMatchesPreview(400e18);

        assertEq(preview.ptAmount, 400e18);
        assertEq(preview.debtRepaid, 400e18);
        assertEq(preview.surplus, 0);
        assertEq(preview.healthFactorAfter, 1.87e18);
    }

    /// @notice Morpho cash below the debt previews `ceil(debt / cash)` rounds
    function test_previewClose_multiRoundViaMorpho() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 300e18);

        INeverlandPendleMaturityGateway.CloseResult memory preview = _assertCloseMatchesPreview(type(uint256).max);

        assertEq(preview.flashSource, address(morpho));
        assertEq(preview.flashCash, 300e18);
        assertEq(preview.rounds, 3);
    }

    /// @notice With the role the richer global pool is the previewed lender
    function test_previewClose_multiRoundViaPoolWithRole() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _richerPoolWithRole();

        INeverlandPendleMaturityGateway.CloseResult memory preview = _assertCloseMatchesPreview(type(uint256).max);

        assertEq(preview.flashSource, address(flashPool));
        assertEq(preview.flashCash, 400e18);
        assertEq(preview.rounds, 2);
    }

    /// @notice Fractional debt prices return the exact pool account data after repayment
    function test_previewClose_debtValueRoundsUpLikePool() public {
        _openPosition(user, 1_000e18, 7);
        pool.setPrice(address(ausd), 1.5e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 1e18);

        INeverlandPendleMaturityGateway.CloseResult memory preview = _assertCloseMatchesPreview(1);

        assertEq(preview.debtRepaid, 1);
        assertEq(preview.healthFactorAfter, (1_000e18 - 1) * PT_LT_BPS * 1e18 / 9 / 10_000);
    }

    /// @notice Mixed liquidation thresholds return the exact final pool health factor
    function test_previewClose_mixedThresholdsMatchExactly() public {
        MockGatewayToken otherAsset = new MockGatewayToken("Other", "OTH");
        pool.listReserve(address(otherAsset), 1e18, 7_000);
        _openPosition(user, 1_000e18, 500e18);
        _supplyFor(user, otherAsset, 333e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 1_000e18);

        _assertCloseMatchesPreview(400e18);
    }

    /// @notice Source PT not enabled as collateral leaves the remaining collateral unchanged
    function test_previewClose_sourceNotCollateral() public {
        pool.setCollateralEnabledOnSupply(false);
        _supplyFor(user, ptOld, 1_000e18);
        pool.setCollateralEnabledOnSupply(true);
        _supplyFor(user, ptNew, 1_000e18);
        pool.mintDebt(user, 700e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 1_000e18);

        INeverlandPendleMaturityGateway.CloseResult memory preview = _assertCloseMatchesPreview(400e18);

        assertEq(preview.healthFactorAfter, uint256(985e18) * PT_LT_BPS * 1e18 / 300e18 / 10_000);
    }

    /// @notice An unhealthy source pull returns the pool's exact revert rather than a projected health factor
    function test_previewClose_unhealthySourcePullBubblesRevert() public {
        _openPosition(user, 1_000e18, 950e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 1_000e18);

        _assertCloseRevertParity(address(ptOld), 100e18, abi.encodeWithSignature("Error(string)", "35"));
    }

    /// @notice A close that clears all debt needs no price, like the real call, so an unavailable oracle is tolerated
    function test_previewClose_debtClearedNeedsNoOracle() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 1_000e18);
        MockAddressesProvider(pool.ADDRESSES_PROVIDER()).setPriceOracle(address(0));
        vm.mockCallRevert(
            address(pool), abi.encodeWithSelector(MockIsolatedPool.getUserAccountData.selector), bytes("stale")
        );

        INeverlandPendleMaturityGateway.CloseResult memory preview = _assertCloseMatchesPreview(type(uint256).max);

        assertEq(preview.healthFactorAfter, type(uint256).max);
    }

    /// @notice Another borrowing flag requires actual account data after the debt asset is cleared
    function test_previewClose_otherBorrowingReadsAccountData() public {
        MockGatewayToken otherAsset = new MockGatewayToken("Other", "OTH");
        pool.listReserve(address(otherAsset), 1e18, 0);
        _openPosition(user, 1_000e18, 700e18);
        pool.setBorrowing(user, address(otherAsset), true);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 1_000e18);

        vm.expectCall(address(pool), abi.encodeWithSelector(MockIsolatedPool.getUserAccountData.selector, user));
        vm.prank(user);
        INeverlandPendleMaturityGateway.CloseResult memory preview =
            gateway.previewClose(_closeParams(type(uint256).max, 0, beneficiary, type(uint256).max));

        assertEq(preview.healthFactorAfter, type(uint256).max);
    }

    /// @notice Every source validation the real close runs fails the preview with the same error
    function test_previewClose_revertParity() public {
        (MockPendlePt unlisted,,) = _deployPrincipalToken("PT-UNLISTED");
        _openPosition(user, 1_000e18, 700e18);
        _approveSource(user);
        ausd.mint(address(morpho), 1_000e18);

        _assertCloseRevertParity(
            address(unlisted),
            1e18,
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.ReserveNotListed.selector, address(unlisted))
        );
        _assertCloseRevertParity(
            address(ausd),
            1e18,
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.NotPrincipalToken.selector, address(ausd))
        );
        _assertCloseRevertParity(
            address(ptOld),
            1e18,
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.PrincipalTokenNotMatured.selector, address(ptOld))
        );
        _mature();
        syOld.setValidTokenOut(address(ausd), false);
        _assertCloseRevertParity(
            address(ptOld),
            1e18,
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.UnsupportedSy.selector, address(syOld))
        );
        syOld.setValidTokenOut(address(ausd), true);
        _assertCloseRevertParity(
            address(ptOld), 0, abi.encodePacked(INeverlandPendleMaturityGateway.InvalidAmount.selector)
        );
        aPtOld.burn(user, 1_000e18);
        _assertCloseRevertParity(
            address(ptOld), type(uint256).max, abi.encodePacked(INeverlandPendleMaturityGateway.InvalidAmount.selector)
        );
    }

    /// @notice Both paths return the caller's exact round limit in a liquidity failure
    function test_previewClose_revertsWithoutFlashCash() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);

        _assertCloseParamsRevertParity(
            _closeParams(type(uint256).max, 0, beneficiary, 5),
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.InsufficientFlashLiquidity.selector, 700e18, 0, 5)
        );
    }

    /// @notice Every preview field equals the executed close
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_previewClose_matchesClose(uint96 pt, uint96 debt, uint96 cash, uint96 amount) public {
        uint256 ptAmount = bound(pt, 1, type(uint96).max);
        uint256 debtAmount = bound(debt, 0, 2 * ptAmount);
        _openPosition(user, ptAmount, debtAmount);
        if (debtAmount != 0) _supplyFor(user, ptNew, 2 * debtAmount);
        uint256 requested = amount % 2 == 0 ? type(uint256).max : bound(amount, 1, ptAmount);
        uint256 cashAmount = bound(cash, Math.min(ptAmount, debtAmount) / 16 + 1, type(uint96).max);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), cashAmount);

        _assertCloseMatchesPreview(requested);
    }

    /// @notice Repayment rounding is simulated, including any extra round needed to clear debt
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_previewClose_exactRoundsUnderRounding(uint96 debt, uint64 cash) public {
        pool.setRoundingMode(MockIsolatedPool.RoundingMode.LENDING_CORE);
        pool.mintDebt(user, bound(debt, 1e6, type(uint96).max));
        uint256 owed = debtToken.balanceOf(user);
        _supplyFor(user, ptOld, 2 * owed);
        uint256 cashAmount = bound(cash, owed / 16 + 2, owed + 2);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), cashAmount);

        INeverlandPendleMaturityGateway.CloseResult memory preview = _assertCloseMatchesPreview(type(uint256).max);

        assertEq(preview.debtAfter, 0);
        assertEq(preview.rounds, morpho.flashLoanCount());
        assertEq(preview.healthFactorAfter, type(uint256).max);
    }

    /// @notice A single-round migration previews the oracle floor and the actual health factor
    function test_previewMigrate_singleRoundUsesSafeSearch() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);

        INeverlandPendleMaturityGateway.MigrateResult memory preview =
            _assertMigrateMatchesPreview(type(uint256).max, 0);

        assertEq(preview.ptAmount, 1_000e18);
        assertEq(preview.debt, 700e18);
        assertEq(preview.repay, 0);
        assertEq(preview.spent, 1_000e18);
        assertEq(preview.flashSource, address(morpho));
        assertEq(preview.flashCash, 1_000e18);
        assertEq(preview.rounds, 1);
        assertEq(preview.oracleMinimumPtOut, Math.mulDiv(1_000e18, 9_000, 0.985e18 * 10_000 / 1e18, Math.Rounding.Ceil));
        assertEq(preview.debtAfter, 700e18);
        assertEq(preview.healthFactorAfter, _bought(1_000e18) * 0.985e18 / 1e18 * PT_LT_BPS * 1e18 / 700e18 / 10_000);
    }

    /// @notice A multi-round migration previews exact rounds and the router's on-chain search
    function test_previewMigrate_multiRoundUsesDefaultApprox() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 300e18);

        INeverlandPendleMaturityGateway.MigrateResult memory preview =
            _assertMigrateMatchesPreview(type(uint256).max, 0);

        assertEq(preview.rounds, 4);
    }

    /// @notice A repayment spanning rounds previews the clamped repayment, the spend, and the debt left
    function test_previewMigrate_repaySpansRounds() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 300e18);

        INeverlandPendleMaturityGateway.MigrateResult memory preview =
            _assertMigrateMatchesPreview(type(uint256).max, 450e18);

        assertEq(preview.repay, 450e18);
        assertEq(preview.spent, 550e18);
        assertEq(preview.debtAfter, 250e18);
        assertEq(preview.rounds, 4);
    }

    /// @notice A repayment above the debt is clamped and execution ends without debt
    function test_previewMigrate_repayClampedToDebt() public {
        _openPosition(user, 1_000e18, 100e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);

        INeverlandPendleMaturityGateway.MigrateResult memory preview =
            _assertMigrateMatchesPreview(type(uint256).max, 500e18);

        assertEq(preview.repay, 100e18);
        assertEq(preview.spent, 900e18);
        assertEq(preview.debtAfter, 0);
        assertEq(preview.healthFactorAfter, type(uint256).max);
    }

    /// @notice The full-repay path previews the whole debt repaid
    function test_previewMigrate_fullRepayPath() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 300e18);

        INeverlandPendleMaturityGateway.MigrateResult memory preview =
            _assertMigrateMatchesPreview(type(uint256).max, type(uint256).max);

        assertEq(preview.repay, 700e18);
        assertEq(preview.spent, 300e18);
        assertEq(preview.debtAfter, 0);
        assertEq(preview.healthFactorAfter, type(uint256).max);
    }

    /// @notice Repayment rounding is reflected in actual debt reduction, spend, surplus, and output
    function test_previewMigrate_fullRepayUnderRounding() public {
        pool.setRoundingMode(MockIsolatedPool.RoundingMode.LENDING_CORE);
        _openPosition(user, 1_000e18, 700e18 + 1);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 300e18);

        INeverlandPendleMaturityGateway.MigrateResult memory preview =
            _assertMigrateMatchesPreview(type(uint256).max, type(uint256).max);

        assertEq(preview.debtAfter, 0);
        assertEq(preview.repay, preview.debt);
    }

    /// @notice A repayment of the whole amount previews no purchase, no oracle floor, and no oracle read
    function test_previewMigrate_repayOnlyNeedsNoOracle() public {
        _prepareOracleMigration(100e18, 100e18, 100e18);
        pool.setCollateralEnabledOnSupply(false);
        _supplyFor(user, ptNew, 1e18);
        MockAddressesProvider(pool.ADDRESSES_PROVIDER()).setPriceOracle(address(0));

        INeverlandPendleMaturityGateway.MigrateResult memory preview = _assertMigrateMatchesPreview(100e18, 100e18);

        assertEq(preview.spent, 0);
        assertEq(preview.oracleMinimumPtOut, 0);
        assertEq(preview.debtAfter, 0);
        assertEq(preview.healthFactorAfter, type(uint256).max);
    }

    /// @notice With the role the richer global pool is the previewed lender
    function test_previewMigrate_viaPoolWithRole() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        _richerPoolWithRole();

        INeverlandPendleMaturityGateway.MigrateResult memory preview =
            _assertMigrateMatchesPreview(type(uint256).max, 0);

        assertEq(preview.flashSource, address(flashPool));
        assertEq(preview.flashCash, 400e18);
        assertEq(preview.rounds, 3);
    }

    /// @notice Target collateral already enabled passes and counts in the actual health factor
    function test_previewMigrate_existingTargetCollateral() public {
        _openPosition(user, 1_000e18, 700e18);
        _supplyFor(user, ptNew, 200e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);

        INeverlandPendleMaturityGateway.MigrateResult memory preview =
            _assertMigrateMatchesPreview(type(uint256).max, 0);

        assertEq(
            preview.healthFactorAfter,
            (200e18 + _bought(1_000e18)) * 0.985e18 / 1e18 * PT_LT_BPS * 1e18 / 700e18 / 10_000
        );
    }

    /// @notice The preview runs the oracle floor against real purchases without an off-chain quote
    function test_previewMigrate_oracleFloorMatchesEnforcedMinimum() public {
        _prepareOracleMigration(1_000e18, 0, 600e18);
        router.setPriceWad(2e18);

        _assertMigrateRevertParity(
            _migrateParams(1_000e18, 0, 2),
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.OutputBelowMinimum.selector, 500e18, 999.9e18)
        );
    }

    /// @notice Matching six-decimal reserves preserve the raw-unit oracle floor and actual output
    function test_previewMigrate_oracleFloorSupportsEqualSixDecimals() public {
        _prepareOracleMigration(1e6, 0, 1e6);
        pool.setReserveDecimals(address(ausd), 6);
        pool.setReserveDecimals(address(ptOld), 6);
        pool.setReserveDecimals(address(ptNew), 6);
        pool.setPrice(address(ptNew), 0.8e18);
        router.setPriceWad(0.8e18);

        INeverlandPendleMaturityGateway.MigrateResult memory preview = _assertMigrateMatchesPreview(1e6, 0);

        assertEq(preview.oracleMinimumPtOut, 1_125_000);
        assertEq(preview.ptOut, 1_250_000);
    }

    /// @notice The actual health factor is the exact boundary enforced by both paths
    function test_previewMigrate_healthFactorMatchesPoolCheck() public {
        _prepareOracleMigration(1_000e18, 700e18, 1_000e18);
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(type(uint256).max, 0, 1);
        vm.prank(user);
        INeverlandPendleMaturityGateway.MigrateResult memory preview = gateway.previewMigrate(params);
        params.minHealthFactor = preview.healthFactorAfter + 1;

        _assertMigrateRevertParity(
            params,
            abi.encodeWithSelector(
                INeverlandPendleMaturityGateway.HealthFactorBelowMinimum.selector,
                preview.healthFactorAfter,
                params.minHealthFactor
            )
        );
        params.minHealthFactor = preview.healthFactorAfter;
        _assertMigrateParamsMatchPreview(params, false);
    }

    /// @notice Every validation the real migration runs fails the preview with the same error
    function test_previewMigrate_revertParity() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 1_000e18);
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(type(uint256).max, 0, 10);

        _assertMigrateRevertParity(
            params,
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.MigrationTargetNotEnabled.selector, address(ptNew))
        );
        _registerTarget();
        marketNew.setExpired(true);
        _assertMigrateRevertParity(
            params,
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.TargetMarketExpired.selector, address(marketNew))
        );
        marketNew.setExpired(false);
        params.ptAmount = 0;
        _assertMigrateRevertParity(params, abi.encodePacked(INeverlandPendleMaturityGateway.InvalidAmount.selector));
        params.ptAmount = 500e18;
        params.repayAmount = 600e18;
        _assertMigrateRevertParity(params, abi.encodePacked(INeverlandPendleMaturityGateway.InvalidAmount.selector));
        params.ptOld = address(ptNew);
        params.repayAmount = 0;
        _assertMigrateRevertParity(
            params,
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.PrincipalTokenNotMatured.selector, address(ptNew))
        );
    }

    /// @notice Held target collateral that is switched off fails the preview like the real first supply
    function test_previewMigrate_revertsWhenHeldTargetNotCollateral() public {
        _openPosition(user, 1_000e18, 700e18);
        pool.setCollateralEnabledOnSupply(false);
        _supplyFor(user, ptNew, 10e18);
        pool.setCollateralEnabledOnSupply(true);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);

        _assertMigrateRevertParity(
            _migrateParams(type(uint256).max, 0, 1),
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.CollateralNotEnabled.selector, address(ptNew))
        );
    }

    /// @notice A first supply into a zero-LTV target cannot enable collateral, in the preview and the real call
    function test_previewMigrate_revertsWhenTargetLtvZero() public {
        _openPosition(user, 1_000e18, 0);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);
        pool.setLtBps(address(ptNew), 0);

        _assertMigrateRevertParity(
            _migrateParams(type(uint256).max, 0, 1),
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.CollateralNotEnabled.selector, address(ptNew))
        );
    }

    /// @notice A first supply into an isolated target cannot enable collateral, in the preview and the real call
    function test_previewMigrate_revertsWhenTargetHasDebtCeiling() public {
        _openPosition(user, 1_000e18, 0);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), 1_000e18);
        pool.setDebtCeiling(address(ptNew), 1);

        _assertMigrateRevertParity(
            _migrateParams(type(uint256).max, 0, 1),
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.CollateralNotEnabled.selector, address(ptNew))
        );
    }

    /// @notice Zero prices fail the previewed floor like the real one
    function test_previewMigrate_revertsOnZeroPrices() public {
        _prepareOracleMigration(1_000e18, 0, 1_000e18);
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(1_000e18, 0, 1);
        pool.setPrice(address(ausd), 0);

        _assertMigrateRevertParity(
            params, abi.encodeWithSelector(INeverlandPendleMaturityGateway.InvalidOraclePrice.selector, address(ausd))
        );
        pool.setPrice(address(ausd), 1e18);
        pool.setPrice(address(ptNew), 0);
        _assertMigrateRevertParity(
            params, abi.encodeWithSelector(INeverlandPendleMaturityGateway.InvalidOraclePrice.selector, address(ptNew))
        );
    }

    /// @notice Both paths return the caller's exact liquidity failure
    function test_previewMigrate_revertsWithoutFlashCash() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _approveSource(user);
        _registerTarget();

        _assertMigrateRevertParity(
            _migrateParams(type(uint256).max, 0, 5),
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.InsufficientFlashLiquidity.selector, 1_000e18, 0, 5)
        );
    }

    /// @notice Every preview field equals the executed migration using the router's actual output
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_previewMigrate_matchesMigrate(uint96 pt, uint96 debt, uint96 repay, uint96 cash) public {
        uint256 ptAmount = bound(pt, 1e6, type(uint96).max);
        _openPosition(user, ptAmount, bound(debt, 0, ptAmount / 2));
        uint256 repayAmount = repay % 3 == 0 ? type(uint256).max : bound(repay, 0, ptAmount);
        uint256 cashAmount = bound(cash, ptAmount / 8 + 1, type(uint96).max);
        _mature();
        _approveSource(user);
        _registerTarget();
        ausd.mint(address(morpho), cashAmount);

        _assertMigrateMatchesPreview(type(uint256).max, repayAmount);
    }

    /// @notice Close enforces the actual source allowance and returns all token error arguments
    function test_previewClose_requiresSourceAllowance() public {
        _openPosition(user, 100e18, 0);
        _mature();

        _assertCloseRevertParity(
            address(ptOld),
            100e18,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(gateway), 0, 100e18)
        );
    }

    /// @notice Migration cannot simulate a source balance the caller does not own
    function test_previewMigrate_rejectsExcessiveBalance() public {
        _prepareOracleMigration(100e18, 0, 101e18);

        _assertMigrateRevertParity(
            _migrateParams(101e18, 0, 1),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user, 100e18, 101e18)
        );
    }

    /// @notice A migration cannot bypass source approval in its preview
    function test_previewMigrate_requiresSourceAllowance() public {
        _prepareOracleMigration(100e18, 0, 100e18);
        vm.prank(user);
        aPtOld.approve(address(gateway), 0);

        _assertMigrateRevertParity(
            _migrateParams(100e18, 0, 1),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(gateway), 0, 100e18)
        );
    }

    /// @notice Surplus minimum failures occur after redemption and roll back its effects
    function test_previewClose_enforcesSurplusMinimum() public {
        _prepareOracleMigration(1_000e18, 700e18, 1_000e18);
        INeverlandPendleMaturityGateway.CloseParams memory params = _closeParams(1_000e18, 300e18 + 1, beneficiary, 1);

        _assertCloseParamsRevertParity(
            params,
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.OutputBelowMinimum.selector, 300e18, 300e18 + 1)
        );
        params.minSurplusOut = 300e18;
        _assertCloseParamsMatchPreview(params, false);
    }

    /// @notice Caller PT minimums are checked against the router's actual output
    function test_previewMigrate_enforcesCallerMinimum() public {
        _prepareOracleMigration(1_000e18, 700e18, 1_000e18);
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(1_000e18, 0, 1);
        params.minPtOut = 1_000e18 + 1;

        _assertMigrateRevertParity(
            params,
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.OutputBelowMinimum.selector, 1_000e18, 1_000e18 + 1)
        );
        params.minPtOut = 1_000e18;
        _assertMigrateParamsMatchPreview(params, false);
    }

    /// @notice Insufficient round budgets fail identically instead of returning a suggested limit
    function test_previews_enforceMaxRounds() public {
        _prepareOracleMigration(1_000e18, 700e18, 300e18);

        _assertCloseParamsRevertParity(
            _closeParams(1_000e18, 0, beneficiary, 2),
            abi.encodeWithSelector(
                INeverlandPendleMaturityGateway.InsufficientFlashLiquidity.selector, 700e18, 300e18, 2
            )
        );
        _assertMigrateRevertParity(
            _migrateParams(1_000e18, 0, 3),
            abi.encodeWithSelector(
                INeverlandPendleMaturityGateway.InsufficientFlashLiquidity.selector, 1_000e18, 300e18, 3
            )
        );
        _assertCloseParamsRevertParity(
            _closeParams(1_000e18, 0, beneficiary, 0),
            abi.encodeWithSelector(
                INeverlandPendleMaturityGateway.InsufficientFlashLiquidity.selector, 700e18, 300e18, 0
            )
        );
    }

    /// @notice A mixed-threshold close at the audited boundary returns the healthy executed value exactly
    function test_previewClose_mixedThresholdBoundary() public {
        MockGatewayToken other = new MockGatewayToken("Other", "OTH");
        pool.listReserve(address(other), 1e18, 8_000);
        _openPosition(user, 1_000e18, 1_207.8498e18);
        _supplyFor(user, other, 333e18);
        _mature();
        _approveSource(user);
        ausd.mint(address(morpho), 100e18);

        INeverlandPendleMaturityGateway.CloseResult memory preview = _assertCloseMatchesPreview(100e18);

        assertEq(preview.healthFactorAfter, 1_000_045_313_001_816_672);
        assertTrue(preview.healthFactorAvailable);
    }

    /// @notice A valid migration near one is no longer rejected by a rounded average-threshold projection
    function test_previewMigrate_mixedThresholdBoundary() public {
        MockGatewayToken other = new MockGatewayToken("Other", "OTH");
        pool.listReserve(address(other), 1e18, 8_000);
        _openPosition(user, 1_000e18, 1_200.4148e18);
        _supplyFor(user, other, 333e18);
        _mature();
        _approveSource(user);
        _registerTarget();
        pool.setPrice(address(ptNew), 0.99e18);
        router.setPriceWad(1e18);
        ausd.mint(address(morpho), 100e18);
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(100e18, 0, 1);
        params.minPtOut = 100e18;
        params.minHealthFactor = 1e18;

        INeverlandPendleMaturityGateway.MigrateResult memory preview = _assertMigrateParamsMatchPreview(params, false);

        assertEq(preview.healthFactorAfter, 1_000_041_818_877_941_191);
        assertTrue(preview.healthFactorAvailable);
    }

    /// @notice Each purchase's integer output is simulated instead of quoting the whole input once
    function test_previewMigrate_countsPerRoundOutputRounding() public {
        _prepareOracleMigration(11, 0, 4);
        router.setPriceWad(0.6e18);
        pool.setPrice(address(ptNew), 0.6e18);

        INeverlandPendleMaturityGateway.MigrateResult memory preview = _assertMigrateMatchesPreview(11, 0);

        assertEq(preview.rounds, 3);
        assertEq(preview.spent, 11);
        assertEq(preview.ptOut, 17);
        assertEq(preview.oracleMinimumPtOut, 17);
        assertLt(preview.ptOut, uint256(11e18) / 0.6e18);
    }

    /// @notice Donated YT-held PT becomes actual close surplus while gateway balances remain protected
    function test_previewClose_accountsForDonations() public {
        _prepareOracleMigration(1_000e18, 700e18, 300e18);
        _seedStrays();
        ptOld.mint(address(ytOld), 13e18);
        syOld.setRateBps(10_100);

        INeverlandPendleMaturityGateway.CloseResult memory preview = _assertCloseMatchesPreview(type(uint256).max);

        assertEq(preview.surplus, 323.13e18);
        _assertStraysUnchanged();
    }

    /// @notice Migration reports excess redemption separately from actual PT purchase spending
    function test_previewMigrate_accountsForDonations() public {
        _prepareOracleMigration(1_000e18, 700e18, 300e18);
        _seedStrays();
        ptOld.mint(address(ytOld), 13e18);
        syOld.setRateBps(10_100);

        INeverlandPendleMaturityGateway.MigrateResult memory preview = _assertMigrateMatchesPreview(1_000e18, 450e18);

        assertEq(preview.surplus, 23.13e18);
        assertEq(preview.spent, 550e18);
        _assertStraysUnchanged();
    }

    /// @notice Pool supply restrictions are reached during preview and preserve their exact revert bytes
    function test_previewMigrate_bubblesReserveSupplyFailure() public {
        _prepareOracleMigration(100e18, 0, 100e18);
        bytes memory reason = abi.encodeWithSignature("Error(string)", "RESERVE_FROZEN");
        vm.mockCallRevert(address(pool), abi.encodeWithSelector(MockIsolatedPool.supply.selector), reason);

        _assertMigrateRevertParity(_migrateParams(100e18, 0, 1), reason);
    }

    /// @notice Simultaneous failures preserve execution order, including redemption before the final oracle floor
    function test_previewMigrate_preservesFailureOrder() public {
        _prepareOracleMigration(100e18, 0, 100e18);
        pool.setPrice(address(ptNew), 0);
        syOld.setRateBps(9_000);
        vm.mockCall(address(syOld), abi.encodeCall(MockPendleSy.previewRedeem, (address(ausd), 1e18)), abi.encode(1e18));

        _assertMigrateRevertParity(
            _migrateParams(100e18, 0, 1), abi.encodeWithSignature("Error(string)", "SY: insufficient out")
        );
    }

    /// @notice An unavailable account-data getter does not prevent a valid partial close
    function test_previewClose_reportsUnavailableHealthFactor() public {
        _prepareOracleMigration(1_000e18, 700e18, 1_000e18);
        vm.mockCallRevert(
            address(pool), abi.encodeWithSelector(MockIsolatedPool.getUserAccountData.selector), bytes("stale")
        );

        INeverlandPendleMaturityGateway.CloseResult memory preview = _assertCloseMatchesPreview(100e18);

        assertEq(preview.healthFactorAfter, 0);
        assertFalse(preview.healthFactorAvailable);
    }

    /// @notice Optional migration reporting tolerates failed reads but an explicit HF minimum remains mandatory
    function test_previewMigrate_unavailableHealthFactorDoesNotBypassMinimum() public {
        _prepareOracleMigration(1_000e18, 700e18, 1_000e18);
        bytes memory reason = bytes("stale");
        vm.mockCallRevert(address(pool), abi.encodeWithSelector(MockIsolatedPool.getUserAccountData.selector), reason);
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(100e18, 0, 1);
        params.minHealthFactor = 1e18;
        _assertMigrateRevertParity(params, reason);
        params.minHealthFactor = 0;

        INeverlandPendleMaturityGateway.MigrateResult memory preview = _assertMigrateParamsMatchPreview(params, false);

        assertEq(preview.healthFactorAfter, 0);
        assertFalse(preview.healthFactorAvailable);
    }

    /// @notice Each guarded migration uses one strict account read for both its minimum and its result
    function test_previewMigrate_reusesRequiredHealthFactor() public {
        _prepareOracleMigration(1_000e18, 700e18, 1_000e18);
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(100e18, 20e18, 1);
        params.minHealthFactor = 1e18;
        bytes32 stateBefore = _previewState();
        vm.expectCall(address(pool), abi.encodeWithSelector(MockIsolatedPool.getUserAccountData.selector, user), 2);

        vm.prank(user);
        INeverlandPendleMaturityGateway.MigrateResult memory preview = gateway.previewMigrate(params);

        assertEq(_previewState(), stateBefore);
        assertTrue(preview.healthFactorAvailable);
        assertGe(preview.healthFactorAfter, params.minHealthFactor);

        vm.prank(user);
        INeverlandPendleMaturityGateway.MigrateResult memory actual = gateway.migrate(params);

        assertEq(abi.encode(actual), abi.encode(preview));
        _assertNoApprovals();
        _assertGatewayEmpty();
    }

    /// @notice The final strict read sees paid surplus, exceeds the optional gas cap, and still enforces the minimum
    function test_previewMigrate_checksHealthFactorAfterSurplus() public {
        _prepareOracleMigration(1_000e18, 700e18, 1_000e18);
        syOld.setRateBps(10_100);
        GatewaySettledHealthFactor reporter = new GatewaySettledHealthFactor(ausd);
        vm.mockFunction(
            address(pool), address(reporter), abi.encodeWithSelector(MockIsolatedPool.getUserAccountData.selector, user)
        );
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(100e18, 20e18, 1);
        params.minHealthFactor = 2e18 + 1;
        _assertMigrateRevertParity(
            params,
            abi.encodeWithSelector(
                INeverlandPendleMaturityGateway.HealthFactorBelowMinimum.selector, uint256(2e18), params.minHealthFactor
            )
        );
        params.minHealthFactor = 2e18;

        INeverlandPendleMaturityGateway.MigrateResult memory result = _assertMigrateParamsMatchPreview(params, false);

        assertTrue(result.healthFactorAvailable);
        assertEq(result.healthFactorAfter, 2e18);
        assertEq(result.surplus, 1e18);
        assertEq(ausd.balanceOf(user), result.surplus);
    }

    /// @notice Short and oversized account-data responses are unavailable instead of causing ABI decoding failures
    function test_previewClose_malformedHealthFactorResponses() public {
        _prepareOracleMigration(1_000e18, 700e18, 1_000e18);
        uint256[6] memory lengths = [uint256(0), 1, 160, 191, 193, 4_096];
        for (uint256 i; i < lengths.length; ++i) {
            vm.mockCall(
                address(pool),
                abi.encodeWithSelector(MockIsolatedPool.getUserAccountData.selector),
                new bytes(lengths[i])
            );
            INeverlandPendleMaturityGateway.CloseResult memory preview = _assertCloseMatchesPreview(1e18);
            assertFalse(preview.healthFactorAvailable);
        }
    }

    /// @notice Failed or malformed configuration reporting cannot make a debt-free close fail
    function test_previewClose_unavailableConfigurationRead() public {
        _prepareOracleMigration(1_000e18, 0, 1_000e18);
        bytes memory getter = abi.encodeWithSelector(MockIsolatedPool.getUserConfiguration.selector, user);
        vm.mockCallRevert(address(pool), getter, bytes("configuration unavailable"));
        INeverlandPendleMaturityGateway.CloseResult memory preview = _assertCloseMatchesPreview(100e18);
        assertFalse(preview.healthFactorAvailable);
        vm.clearMockedCalls();
        uint256[4] memory lengths = [uint256(0), 31, 33, 4_096];
        for (uint256 i; i < lengths.length; ++i) {
            vm.mockCall(address(pool), getter, new bytes(lengths[i]));
            preview = _assertCloseMatchesPreview(100e18);
            assertFalse(preview.healthFactorAvailable);
        }
    }

    /// @notice A getter that burns its gas allowance cannot consume settlement's remaining gas
    function test_previewClose_gasBurningHealthFactorRead() public {
        _prepareOracleMigration(1_000e18, 700e18, 1_000e18);
        GatewayReportingGasBurner burner = new GatewayReportingGasBurner();
        vm.mockFunction(
            address(pool), address(burner), abi.encodeWithSelector(MockIsolatedPool.getUserAccountData.selector, user)
        );

        INeverlandPendleMaturityGateway.CloseResult memory preview = _assertCloseMatchesPreview(100e18);

        assertFalse(preview.healthFactorAvailable);
        assertEq(preview.debtAfter, 600e18);
    }

    /// @notice A bounded call can settle and preview identically when only optional account reporting runs out of gas
    function test_previewClose_gasStarvedHealthFactorRead() public {
        _prepareGasStarvedHealthFactorReporting();
        INeverlandPendleMaturityGateway.CloseParams memory params = _closeParams(100e18, 0, beneficiary, 1);
        bytes32 stateBefore = _previewState();

        uint256 gasBefore = gasleft();
        vm.prank(user);
        INeverlandPendleMaturityGateway.CloseResult memory ampleGas = gateway.previewClose(params);
        uint256 gasBudget = gasBefore - gasleft() + 600_000;

        assertTrue(ampleGas.healthFactorAvailable);
        assertEq(ampleGas.healthFactorAfter, 2e18);
        assertEq(_previewState(), stateBefore);

        vm.prank(user);
        INeverlandPendleMaturityGateway.CloseResult memory preview = gateway.previewClose{gas: gasBudget}(params);

        assertFalse(preview.healthFactorAvailable);
        assertEq(preview.healthFactorAfter, 0);
        assertEq(_previewState(), stateBefore);

        vm.prank(user);
        INeverlandPendleMaturityGateway.CloseResult memory actual = gateway.close{gas: gasBudget}(params);

        assertEq(abi.encode(actual), abi.encode(preview));
        assertEq(actual.debtRepaid, 100e18);
        assertEq(actual.debtAfter, 600e18);
        assertEq(debtToken.balanceOf(user), 600e18);
        assertEq(aPtOld.balanceOf(user), 900e18);
        assertEq(morpho.flashLoanCount(), 1);
        _assertNoApprovals();
        _assertGatewayEmpty();
    }

    /// @notice A migration preserves its swap and repayment result when optional account reporting is gas-starved
    function test_previewMigrate_gasStarvedHealthFactorRead() public {
        _prepareGasStarvedHealthFactorReporting();
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(100e18, 20e18, 1);
        bytes32 stateBefore = _previewState();

        uint256 gasBefore = gasleft();
        vm.prank(user);
        INeverlandPendleMaturityGateway.MigrateResult memory ampleGas = gateway.previewMigrate(params);
        uint256 gasBudget = gasBefore - gasleft() + 600_000;

        assertTrue(ampleGas.healthFactorAvailable);
        assertEq(ampleGas.healthFactorAfter, 2e18);
        assertEq(_previewState(), stateBefore);

        vm.prank(user);
        INeverlandPendleMaturityGateway.MigrateResult memory preview = gateway.previewMigrate{gas: gasBudget}(params);

        assertFalse(preview.healthFactorAvailable);
        assertEq(preview.healthFactorAfter, 0);
        assertEq(_previewState(), stateBefore);

        vm.prank(user);
        INeverlandPendleMaturityGateway.MigrateResult memory actual = gateway.migrate{gas: gasBudget}(params);

        assertEq(abi.encode(actual), abi.encode(preview));
        assertEq(actual.repay, 20e18);
        assertEq(actual.spent, 80e18);
        assertEq(actual.ptOut, 80e18);
        assertEq(debtToken.balanceOf(user), 680e18);
        assertEq(aPtOld.balanceOf(user), 900e18);
        assertEq(aPtNew.balanceOf(user), actual.ptOut);
        assertEq(morpho.flashLoanCount(), 1);
        _assertNoApprovals();
        _assertGatewayEmpty();
    }

    /// @notice Simulated permits roll back allowance and recording state before the identical permit executes
    function test_previewCloseWithPermit_rollsBackPermit() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        ausd.mint(address(morpho), 300e18);

        _assertCloseParamsMatchPreview(_closeParams(type(uint256).max, 300e18, beneficiary, 4), true);
        _assertPermitForwarded(_permit(1_000e18));
        assertEq(aPtOld.allowance(user, address(gateway)), 0);
    }

    /// @notice Permit migration previews leave permit state available for the real migration
    function test_previewMigrateWithPermit_rollsBackPermit() public {
        _openPosition(user, 1_000e18, 700e18);
        _mature();
        _registerTarget();
        ausd.mint(address(morpho), 300e18);

        _assertMigrateParamsMatchPreview(_migrateParams(type(uint256).max, 0, 4), true);
        _assertPermitForwarded(_permit(1_000e18));
        assertEq(aPtOld.allowance(user, address(gateway)), 0);
    }

    /// @notice Consumed permits fall back to an existing allowance in both previews and execution
    function test_previewsWithPermit_tolerateConsumedPermitWithAllowance() public {
        _prepareOracleMigration(1_000e18, 700e18, 1_000e18);
        aPtOld.setRevertOnPermit(true);

        _assertCloseParamsMatchPreview(_closeParams(100e18, 0, beneficiary, 1), true);
        _assertMigrateParamsMatchPreview(_migrateParams(100e18, 0, 1), true);
        assertEq(aPtOld.permitCallCount(), 0);
    }

    /// @notice Failed permits cannot let either preview bypass a missing allowance
    function test_previewsWithPermit_requireAllowanceWhenPermitFails() public {
        _prepareOracleMigration(100e18, 0, 100e18);
        vm.prank(user);
        aPtOld.approve(address(gateway), 0);
        aPtOld.setRevertOnPermit(true);
        INeverlandPendleMaturityGateway.CloseParams memory closeParams = _closeParams(100e18, 0, beneficiary, 1);
        INeverlandPendleMaturityGateway.MigrateParams memory migrateParams = _migrateParams(100e18, 0, 1);
        INeverlandPendleMaturityGateway.PermitParams memory permit = _permit(100e18);
        bytes memory reason =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(gateway), 0, 100e18);

        _assertRevertParity(
            user,
            abi.encodeCall(gateway.previewCloseWithPermit, (closeParams, permit)),
            abi.encodeCall(gateway.closeWithPermit, (closeParams, permit)),
            reason
        );
        _assertRevertParity(
            user,
            abi.encodeCall(gateway.previewMigrateWithPermit, (migrateParams, permit)),
            abi.encodeCall(gateway.migrateWithPermit, (migrateParams, permit)),
            reason
        );
    }

    /// @notice A failure after consuming a valid permit rolls the permit back in both paths
    function test_previewCloseWithPermit_rollsBackPermitOnFailure() public {
        _prepareOracleMigration(100e18, 0, 100e18);
        vm.prank(user);
        aPtOld.approve(address(gateway), 0);
        INeverlandPendleMaturityGateway.CloseParams memory params = _closeParams(100e18, 101e18, beneficiary, 1);
        INeverlandPendleMaturityGateway.PermitParams memory permit = _permit(100e18);

        _assertRevertParity(
            user,
            abi.encodeCall(gateway.previewCloseWithPermit, (params, permit)),
            abi.encodeCall(gateway.closeWithPermit, (params, permit)),
            abi.encodeWithSelector(INeverlandPendleMaturityGateway.OutputBelowMinimum.selector, 100e18, 101e18)
        );
        params.minSurplusOut = 100e18;
        _assertCloseParamsMatchPreview(params, true);
    }

    /// @notice A foreign caller can only preview and settle its own position
    function test_previews_preserveCallerOwnership() public {
        _prepareOracleMigration(1_000e18, 700e18, 1_000e18);
        INeverlandPendleMaturityGateway.CloseParams memory params = _closeParams(type(uint256).max, 0, beneficiary, 1);
        _assertRevertParity(
            attacker,
            abi.encodeCall(gateway.previewClose, (params)),
            abi.encodeCall(gateway.close, (params)),
            abi.encodePacked(INeverlandPendleMaturityGateway.InvalidAmount.selector)
        );
        _openPosition(attacker, 100e18, 0);
        _approveSource(attacker);
        bytes32 stateBefore = _previewState();
        vm.prank(attacker);
        INeverlandPendleMaturityGateway.CloseResult memory preview = gateway.previewClose(params);

        assertEq(_previewState(), stateBefore);

        vm.prank(attacker);
        INeverlandPendleMaturityGateway.CloseResult memory actual = gateway.close(params);

        assertEq(abi.encode(preview), abi.encode(actual));
        assertEq(preview.ptAmount, 100e18);
        assertEq(preview.debt, 0);
        assertEq(aPtOld.balanceOf(user), 1_000e18);
        assertEq(debtToken.balanceOf(user), 700e18);
        assertEq(aPtOld.balanceOf(attacker), 0);
    }

    /// @notice Repeated success, a reverted simulation, and another success do not leak transient state
    function test_previews_successRevertSuccessAcrossLenders() public {
        _prepareOracleMigration(1_000e18, 700e18, 300e18);
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(100e18, 0, 1);
        bytes32 stateBefore = _previewState();
        vm.prank(user);
        INeverlandPendleMaturityGateway.MigrateResult memory first = gateway.previewMigrate(params);
        vm.prank(user);
        INeverlandPendleMaturityGateway.MigrateResult memory second = gateway.previewMigrate(params);

        assertEq(abi.encode(first), abi.encode(second));
        assertEq(_previewState(), stateBefore);

        params.minPtOut = first.ptOut + 1;
        _assertMigrateRevertParity(
            params,
            abi.encodeWithSelector(
                INeverlandPendleMaturityGateway.OutputBelowMinimum.selector, first.ptOut, params.minPtOut
            )
        );
        flashPool.seed(beneficiary, 400e18);
        flashPool.ACL().setFlashBorrower(address(gateway), true);
        params.minPtOut = first.ptOut;

        INeverlandPendleMaturityGateway.MigrateResult memory last = _assertMigrateParamsMatchPreview(params, false);

        assertEq(last.flashSource, address(flashPool));

        _assertCloseMatchesPreview(100e18);
    }

    /// @notice Preview entrypoints reached during a router callback remain subject to the execution reentrancy guard
    function test_previews_rejectCallbackReentrancy() public {
        _prepareOracleMigration(1_000e18, 700e18, 1_000e18);
        router.setMode(MockPendleRouter.Mode.REENTER_CLOSE);
        bytes[4] memory calls = [
            abi.encodeCall(gateway.previewClose, (_closeParams(1, 0, beneficiary, 1))),
            abi.encodeCall(gateway.previewMigrate, (_migrateParams(1, 0, 1))),
            abi.encodeCall(gateway.previewCloseWithPermit, (_closeParams(1, 0, beneficiary, 1), _permit(1))),
            abi.encodeCall(gateway.previewMigrateWithPermit, (_migrateParams(1, 0, 1), _permit(1)))
        ];
        for (uint256 i; i < calls.length; ++i) {
            router.setHook(address(gateway), calls[i]);
            _assertMigrateRevertParity(
                _migrateParams(100e18, 0, 1),
                abi.encodePacked(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
            );
        }
        router.setMode(MockPendleRouter.Mode.NORMAL);
        _assertMigrateMatchesPreview(100e18, 0);
    }

    /// @notice Catching a nested preview's revert preserves the outer guard and rolls back callback state
    function test_previews_preserveGuardAfterCaughtCallbackRevert() public {
        _prepareOracleMigration(1_000e18, 700e18, 1_000e18);
        GatewayPreviewReentryProbe probe = new GatewayPreviewReentryProbe();
        router.setMode(MockPendleRouter.Mode.REENTER_CLOSE);
        router.setHook(address(probe), abi.encodeCall(probe.checkGuard, (gateway, _closeParams(1, 0, beneficiary, 1))));
        INeverlandPendleMaturityGateway.MigrateParams memory params = _migrateParams(100e18, 0, 1);
        vm.prank(user);
        gateway.previewMigrate(params);

        assertEq(probe.checks(), 0);

        _assertMigrateParamsMatchPreview(params, false);

        assertEq(probe.checks(), 3);
    }

    /// @notice A dependency cannot forge simulator success by reverting with an encoded success envelope
    function test_previewMigrate_bubblesForgedNestedEnvelope() public {
        _prepareOracleMigration(100e18, 0, 100e18);
        INeverlandPendleMaturityGateway.MigrateResult memory forged;
        forged.ptOut = type(uint256).max;
        forged.healthFactorAvailable = true;
        bytes memory reason = abi.encode(true, abi.encode(forged));
        vm.mockCallRevert(address(router), abi.encodeWithSelector(IPendleRouterV4.swapExactTokenForPt.selector), reason);

        _assertMigrateRevertParity(_migrateParams(100e18, 0, 1), reason);
    }

    /// @notice Arbitrary dependency errors, including empty data, are preserved byte for byte
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_previewMigrate_bubblesRawDependencyError(bytes memory reason) public {
        vm.assume(reason.length <= 256);
        _prepareOracleMigration(100e18, 0, 100e18);
        vm.mockCallRevert(address(router), abi.encodeWithSelector(IPendleRouterV4.swapExactTokenForPt.selector), reason);

        _assertMigrateRevertParity(_migrateParams(100e18, 0, 1), reason);
    }

    /// @notice Direct simulation of each allowed action reverts with its result and rolls back all effects
    function test_simulate_allFourActionsAlwaysRollback() public {
        _prepareOracleMigration(1_000e18, 700e18, 1_000e18);
        INeverlandPendleMaturityGateway.CloseParams memory closeParams = _closeParams(100e18, 0, beneficiary, 1);
        INeverlandPendleMaturityGateway.MigrateParams memory migrateParams = _migrateParams(100e18, 0, 1);
        INeverlandPendleMaturityGateway.PermitParams memory permit = _permit(100e18);
        bytes[4] memory actions = [
            abi.encodeCall(gateway.close, (closeParams)),
            abi.encodeCall(gateway.closeWithPermit, (closeParams, permit)),
            abi.encodeCall(gateway.migrate, (migrateParams)),
            abi.encodeCall(gateway.migrateWithPermit, (migrateParams, permit))
        ];
        bytes[4] memory previews = [
            abi.encodeCall(gateway.previewClose, (closeParams)),
            abi.encodeCall(gateway.previewCloseWithPermit, (closeParams, permit)),
            abi.encodeCall(gateway.previewMigrate, (migrateParams)),
            abi.encodeCall(gateway.previewMigrateWithPermit, (migrateParams, permit))
        ];
        bytes32 stateBefore = _previewState();
        for (uint256 i; i < actions.length; ++i) {
            vm.prank(user);
            (bool completed, bytes memory envelope) =
                address(gateway).call(abi.encodeCall(gateway.simulate, (actions[i])));

            assertFalse(completed);

            (bool actionSucceeded, bytes memory result) = abi.decode(envelope, (bool, bytes));

            assertTrue(actionSucceeded);
            assertEq(_previewState(), stateBefore);

            vm.prank(user);
            (bool previewSucceeded, bytes memory previewResult) = address(gateway).call(previews[i]);

            assertTrue(previewSucceeded);
            assertEq(result, previewResult);
            assertEq(_previewState(), stateBefore);
        }
    }

    /// @notice Failed actions are wrapped once as failures by the simulator
    function test_simulate_wrapsExecutionFailure() public {
        _prepareOracleMigration(100e18, 0, 100e18);
        bytes32 stateBefore = _previewState();
        bytes memory action = abi.encodeCall(gateway.close, (_closeParams(101e18, 0, beneficiary, 1)));
        vm.prank(user);
        (bool completed, bytes memory envelope) = address(gateway).call(abi.encodeCall(gateway.simulate, (action)));
        (bool actionSucceeded, bytes memory reason) = abi.decode(envelope, (bool, bytes));

        assertFalse(completed);
        assertFalse(actionSucceeded);
        assertEq(reason, abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user, 100e18, 101e18));
        assertEq(_previewState(), stateBefore);
    }

    /// @notice Administrative, callback, preview, and recursive simulator selectors cannot run through the trampoline
    function test_simulate_rejectsOtherSelectors() public {
        bytes[9] memory rejected = [
            bytes(""),
            hex"12",
            hex"123456",
            abi.encodeWithSelector(gateway.owner.selector),
            abi.encodeCall(gateway.removeMigrationTarget, (address(ptNew))),
            abi.encodeCall(gateway.previewClose, (_closeParams(1, 0, beneficiary, 1))),
            abi.encodeCall(gateway.previewMigrate, (_migrateParams(1, 0, 1))),
            abi.encodeCall(gateway.simulate, (bytes(""))),
            abi.encodeCall(gateway.onMorphoFlashLoan, (1, bytes("")))
        ];
        for (uint256 i; i < rejected.length; ++i) {
            vm.expectRevert(INeverlandPendleMaturityGateway.InvalidSimulationCall.selector);
            vm.prank(owner);
            gateway.simulate(rejected[i]);
        }
    }

    /// @notice Any selector outside the four settlement actions is rejected before dispatch
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_simulate_rejectsUnapprovedSelector(bytes4 selector) public {
        vm.assume(
            selector != gateway.close.selector && selector != gateway.closeWithPermit.selector
                && selector != gateway.migrate.selector && selector != gateway.migrateWithPermit.selector
        );

        vm.expectRevert(INeverlandPendleMaturityGateway.InvalidSimulationCall.selector);
        gateway.simulate(abi.encodePacked(selector));
    }

    /// @notice Truncated arguments to an allowed action are reported as an action failure
    function test_simulate_wrapsMalformedActionArguments() public {
        bytes memory action = abi.encodePacked(gateway.close.selector);
        (bool completed, bytes memory envelope) = address(gateway).call(abi.encodeCall(gateway.simulate, (action)));

        assertFalse(completed);
        assertEq(envelope, abi.encode(false, bytes("")));
    }

    /// @notice Junk calldata is rejected or wrapped exactly once, without committing any state
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_simulate_junkInputAlwaysRollsBack(bytes memory action) public {
        vm.assume(action.length <= 512);
        _prepareOracleMigration(100e18, 0, 100e18);
        bytes32 stateBefore = _previewState();

        vm.prank(user);
        (bool completed, bytes memory envelope) = address(gateway).call(abi.encodeCall(gateway.simulate, (action)));

        assertFalse(completed);
        assertEq(_previewState(), stateBefore);

        bytes4 selector = bytes4(action);
        if (
            action.length < 4
                || (selector != gateway.close.selector
                    && selector != gateway.closeWithPermit.selector
                    && selector != gateway.migrate.selector
                    && selector != gateway.migrateWithPermit.selector)
        ) {
            assertEq(envelope, abi.encodeWithSelector(INeverlandPendleMaturityGateway.InvalidSimulationCall.selector));
        } else {
            vm.prank(user);
            (bool success, bytes memory result) = address(gateway).call(action);

            assertEq(envelope, abi.encode(success, result));
        }
    }

    /// @notice Every allowed selector wraps truncated ABI arguments as a failure without executing the action
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_simulate_wrapsTruncatedArguments(uint8 actionIndex, uint16 lengthSeed) public {
        _prepareOracleMigration(100e18, 0, 100e18);
        INeverlandPendleMaturityGateway.CloseParams memory closeParams = _closeParams(100e18, 0, beneficiary, 1);
        INeverlandPendleMaturityGateway.MigrateParams memory migrateParams = _migrateParams(100e18, 0, 1);
        INeverlandPendleMaturityGateway.PermitParams memory permit = _permit(100e18);
        bytes[4] memory actions = [
            abi.encodeCall(gateway.close, (closeParams)),
            abi.encodeCall(gateway.closeWithPermit, (closeParams, permit)),
            abi.encodeCall(gateway.migrate, (migrateParams)),
            abi.encodeCall(gateway.migrateWithPermit, (migrateParams, permit))
        ];
        bytes memory action = actions[actionIndex % 4];
        uint256 length = bound(lengthSeed, 4, action.length - 1);
        assembly ("memory-safe") {
            mstore(action, length)
        }
        bytes32 stateBefore = _previewState();

        vm.prank(user);
        (bool completed, bytes memory envelope) = address(gateway).call(abi.encodeCall(gateway.simulate, (action)));

        assertFalse(completed);
        assertEq(envelope, abi.encode(false, bytes("")));
        assertEq(_previewState(), stateBefore);
    }

    /// @notice Invalid self-call envelopes fail closed; only a mocked simulator can produce these encodings
    function test_previewClose_rejectsMalformedSimulatorEnvelopes() public {
        _prepareOracleMigration(100e18, 0, 100e18);
        INeverlandPendleMaturityGateway.CloseParams memory params = _closeParams(100e18, 0, beneficiary, 1);
        bytes memory simulation = abi.encodeCall(gateway.simulate, (abi.encodeCall(gateway.close, (params))));
        bytes[10] memory malformed = [
            bytes(hex"01"),
            new bytes(31),
            abi.encode(true),
            new bytes(63),
            abi.encode(true, uint256(64)),
            abi.encodePacked(abi.encode(true, uint256(64)), new bytes(31)),
            abi.encode(uint256(2), uint256(64), uint256(0)),
            abi.encode(true, type(uint256).max, uint256(0)),
            abi.encode(true, uint256(64), uint256(1)),
            abi.encode(true, uint256(64), type(uint256).max)
        ];
        bytes32 stateBefore = _previewState();
        for (uint256 i; i < malformed.length; ++i) {
            vm.mockCallRevert(address(gateway), simulation, malformed[i]);

            vm.prank(user);
            (bool success,) = address(gateway).call(abi.encodeCall(gateway.previewClose, (params)));

            assertFalse(success, "malformed simulator envelope was accepted as success");
            assertEq(_previewState(), stateBefore);
        }
    }

    /// @notice An empty trampoline failure is preserved without trying to decode an absent envelope
    function test_previewClose_bubblesEmptySimulatorFailure() public {
        INeverlandPendleMaturityGateway.CloseParams memory params = _closeParams(100e18, 0, beneficiary, 1);
        bytes memory simulation = abi.encodeCall(gateway.simulate, (abi.encodeCall(gateway.close, (params))));
        vm.mockCallRevert(address(gateway), simulation, bytes(""));
        vm.prank(user);
        (bool success, bytes memory reason) = address(gateway).call(abi.encodeCall(gateway.previewClose, (params)));

        assertFalse(success);
        assertEq(reason, bytes(""));
    }

    /// @notice A simulator that returns normally is rejected instead of being trusted as a rollback boundary
    function test_previewClose_rejectsNormallyReturningSimulator() public {
        _prepareOracleMigration(100e18, 0, 100e18);
        INeverlandPendleMaturityGateway.CloseParams memory params = _closeParams(100e18, 0, beneficiary, 1);
        bytes memory simulation = abi.encodeCall(gateway.simulate, (abi.encodeCall(gateway.close, (params))));
        vm.mockCall(address(gateway), simulation, abi.encode(true, bytes("forged")));

        vm.expectRevert(INeverlandPendleMaturityGateway.InvalidSimulationCall.selector);
        vm.prank(user);
        gateway.previewClose(params);
    }

    /*//////////////////////////////////////////////////////////////
                              MOCK FIDELITY
    //////////////////////////////////////////////////////////////*/

    /// @notice At a non-unit index a partial repay leaves the debt at or a few wei above the exact remainder
    function testFuzz_mockPool_partialRepayDriftsUpOnly(uint96 debt, uint96 part) public {
        debt = uint96(bound(debt, 2, type(uint96).max));
        pool.setRoundingMode(MockIsolatedPool.RoundingMode.LENDING_CORE);
        pool.mintDebt(user, debt);
        uint256 before = debtToken.balanceOf(user);
        part = uint96(bound(part, 2, before - 1));
        ausd.mint(address(this), before + 2);
        ausd.approve(address(pool), type(uint256).max);

        pool.repay(address(ausd), part, 2, user);
        uint256 left = debtToken.balanceOf(user);

        assertGe(left, before - part);
        assertLe(left, before - part + 2);

        pool.repay(address(ausd), left, 2, user);

        assertEq(debtToken.balanceOf(user), 0);
    }

    /// @notice Repay checks run in lending-core order: zero amount, max on behalf, then no debt
    function test_mockPool_repayChecksFollowLendingCoreOrder() public {
        vm.expectRevert(bytes("26"));
        pool.repay(address(ausd), 0, 2, user);

        vm.expectRevert(bytes("40"));
        pool.repay(address(ausd), type(uint256).max, 2, user);

        vm.expectRevert(bytes("39"));
        pool.repay(address(ausd), 1, 2, user);
    }

    /// @notice Emptying a balance clears its collateral flag; a first receipt enables it where the LT allows
    function test_mockPool_collateralFlagsFollowBalances() public {
        uint256 id = pool.getReserveData(address(ptOld)).id;
        ptOld.mint(user, 100e18);
        vm.startPrank(user);
        ptOld.approve(address(pool), 100e18);
        pool.supply(address(ptOld), 100e18, user, 0);
        aPtOld.transfer(beneficiary, 100e18);
        vm.stopPrank();

        assertFalse(_usesAsCollateral(user, id));
        assertTrue(_usesAsCollateral(beneficiary, id));

        vm.prank(beneficiary);
        pool.withdraw(address(ptOld), type(uint256).max, beneficiary);

        assertFalse(_usesAsCollateral(beneficiary, id));

        ausd.mint(user, 1e18);
        vm.startPrank(user);
        ausd.approve(address(pool), 1e18);
        pool.supply(address(ausd), 1e18, user, 0);
        vm.stopPrank();

        assertFalse(_usesAsCollateral(user, pool.getReserveData(address(ausd)).id));
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Changes one settlement condition while keeping every other field valid
     * @param target Whether to change the target or source
     * @param condition Reserve units, SY index, PY index, or redemption fee
     * @param invalid Whether to install or clear the unsupported condition
     */
    function _setUnsupportedSettlement(bool target, uint256 condition, bool invalid) internal {
        MockPendleSy sy = target ? syNew : syOld;
        MockPendleYt yt = target ? ytNew : ytOld;
        if (condition == 0) pool.setReserveDecimals(address(target ? ptNew : ptOld), invalid ? 6 : 18);
        else if (condition == 1) sy.setExchangeRate(invalid ? 1e18 + 1 : 1e18);
        else if (condition == 2) yt.setPyIndexStored(invalid ? 1e18 + 1 : 1e18);
        else sy.setRateBps(invalid ? 9_999 : 10_000);
    }

    /**
     * @notice Fails one exact external getter in the nested global-pool capacity path
     * @param read Reserve, provider, ACL address, role, token cash, or aToken supply
     */
    function _failFlashPoolRead(uint256 read) internal {
        address target;
        bytes memory data;
        if (read == 0) {
            target = address(flashPool);
            data = abi.encodeCall(MockFlashPool.getReserveData, (address(ausd)));
        } else if (read == 1) {
            target = address(flashPool);
            data = abi.encodeWithSignature("ADDRESSES_PROVIDER()");
        } else if (read == 2) {
            target = flashPool.ADDRESSES_PROVIDER();
            data = abi.encodeWithSignature("getACLManager()");
        } else if (read == 3) {
            target = address(flashPool.ACL());
            data = abi.encodeWithSignature("isFlashBorrower(address)", address(gateway));
        } else if (read == 4) {
            target = address(ausd);
            data = abi.encodeCall(IERC20.balanceOf, (address(flashPool.A_TOKEN())));
        } else {
            target = address(flashPool.A_TOKEN());
            data = abi.encodeCall(IERC20.totalSupply, ());
        }
        vm.mockCallRevert(target, data, bytes("pool capacity unavailable"));
    }

    /**
     * @notice Opens a position and registers a par-priced target for oracle-floor tests
     * @param amount Source collateral
     * @param debt User debt
     * @param cash Flash liquidity
     */
    function _prepareOracleMigration(uint256 amount, uint256 debt, uint256 cash) internal {
        _openPosition(user, amount, debt);
        _mature();
        _approveSource(user);
        _registerTarget();
        pool.setPrice(address(ptNew), 1e18);
        router.setPriceWad(1e18);
        ausd.mint(address(morpho), cash);
    }

    /**
     * @notice Prepares an indebted position whose optional account getter exhausts a limited gas allowance
     */
    function _prepareGasStarvedHealthFactorReporting() internal {
        _prepareOracleMigration(1_000e18, 700e18, 1_000e18);
        GatewayReportingGasThreshold reporter = new GatewayReportingGasThreshold();
        vm.mockFunction(
            address(pool), address(reporter), abi.encodeWithSelector(MockIsolatedPool.getUserAccountData.selector, user)
        );
    }

    /**
     * @notice Simulates and executes a close with identical parameters
     * @param ptAmount Requested source amount
     * @return preview Simulated outcome
     */
    function _assertCloseMatchesPreview(uint256 ptAmount)
        internal
        returns (INeverlandPendleMaturityGateway.CloseResult memory preview)
    {
        return _assertCloseParamsMatchPreview(_closeParams(ptAmount, 0, beneficiary, type(uint256).max), false);
    }

    /**
     * @notice Checks complete rollback, exact return values, and independent close effects
     * @param params Parameters shared by preview and execution
     * @param withPermit Whether to use the permit entrypoints
     * @return preview Simulated outcome
     */
    function _assertCloseParamsMatchPreview(INeverlandPendleMaturityGateway.CloseParams memory params, bool withPermit)
        internal
        returns (INeverlandPendleMaturityGateway.CloseResult memory preview)
    {
        ExecutionState memory beforeState = _executionState(params.to);
        INeverlandPendleMaturityGateway.PermitParams memory permit = _permit(beforeState.source);

        vm.prank(user);
        preview = withPermit ? gateway.previewCloseWithPermit(params, permit) : gateway.previewClose(params);

        assertEq(_previewState(), beforeState.digest, "close preview changed state");

        vm.expectEmit(address(gateway));
        emit INeverlandPendleMaturityGateway.PositionClosed(
            user, address(ptOld), preview.ptAmount, preview.debtRepaid, preview.surplus, params.to, preview.rounds
        );
        vm.prank(user);
        INeverlandPendleMaturityGateway.CloseResult memory actual =
            withPermit ? gateway.closeWithPermit(params, permit) : gateway.close(params);

        assertEq(abi.encode(preview), abi.encode(actual), "close result differs from preview");
        assertEq(preview.ptAmount, beforeState.source - aPtOld.balanceOf(user));
        assertEq(preview.debt, beforeState.debt);
        assertEq(preview.debtRepaid, beforeState.debt - debtToken.balanceOf(user));
        assertEq(preview.debtAfter, debtToken.balanceOf(user));
        assertEq(preview.surplus, ausd.balanceOf(params.to) - beforeState.paid);
        assertEq(preview.flashSource, preview.rounds == 0 ? address(0) : beforeState.lender);
        assertEq(preview.flashCash, preview.rounds == 0 ? 0 : beforeState.cash);

        _assertFlashLoans(preview.flashSource, preview.rounds, beforeState.morphoLoans, beforeState.poolLoans);
        _assertHealthFactor(preview.healthFactorAfter, preview.healthFactorAvailable);
        _assertNoApprovals();
    }

    /**
     * @notice Simulates and executes a migration without an off-chain purchase quote
     * @param ptAmount Requested source amount
     * @param repayAmount Requested repayment
     * @return preview Simulated outcome
     */
    function _assertMigrateMatchesPreview(uint256 ptAmount, uint256 repayAmount)
        internal
        returns (INeverlandPendleMaturityGateway.MigrateResult memory preview)
    {
        INeverlandPendleMaturityGateway.MigrateParams memory params =
            _migrateParams(ptAmount, repayAmount, type(uint256).max);

        return _assertMigrateParamsMatchPreview(params, false);
    }

    /**
     * @notice Checks complete rollback, exact return values, and independent migration effects
     * @param params Parameters shared by preview and execution
     * @param withPermit Whether to use the permit entrypoints
     * @return preview Simulated outcome
     */
    function _assertMigrateParamsMatchPreview(
        INeverlandPendleMaturityGateway.MigrateParams memory params,
        bool withPermit
    ) internal returns (INeverlandPendleMaturityGateway.MigrateResult memory preview) {
        ExecutionState memory beforeState = _executionState(user);
        INeverlandPendleMaturityGateway.PermitParams memory permit = _permit(beforeState.source);

        vm.prank(user);
        preview = withPermit ? gateway.previewMigrateWithPermit(params, permit) : gateway.previewMigrate(params);

        assertEq(_previewState(), beforeState.digest, "migration preview changed state");

        vm.expectEmit(address(gateway));
        emit INeverlandPendleMaturityGateway.PositionMigrated(
            user, address(ptOld), address(ptNew), preview.ptAmount, preview.ptOut, preview.repay, preview.rounds
        );
        vm.prank(user);
        INeverlandPendleMaturityGateway.MigrateResult memory actual =
            withPermit ? gateway.migrateWithPermit(params, permit) : gateway.migrate(params);

        assertEq(abi.encode(preview), abi.encode(actual), "migration result differs from preview");
        assertEq(preview.ptAmount, beforeState.source - aPtOld.balanceOf(user));
        assertEq(preview.ptOut, aPtNew.balanceOf(user) - beforeState.target);
        assertEq(preview.debt, beforeState.debt);
        assertEq(preview.repay, beforeState.debt - debtToken.balanceOf(user));
        assertEq(preview.debtAfter, debtToken.balanceOf(user));
        assertEq(preview.spent, ausd.balanceOf(address(router)) - beforeState.routerCash);
        assertEq(preview.surplus, ausd.balanceOf(user) - beforeState.paid);
        assertEq(preview.flashSource, beforeState.lender);
        assertEq(preview.flashCash, beforeState.cash);

        _assertFlashLoans(preview.flashSource, preview.rounds, beforeState.morphoLoans, beforeState.poolLoans);
        if (preview.spent != 0) {
            _assertApprox(router.lastApprox(), IPendleRouterV4.ApproxParams(0, type(uint256).max, 0, 256, 5e13));
        }
        _assertHealthFactor(preview.healthFactorAfter, preview.healthFactorAvailable);
        _assertNoApprovals();
    }

    /**
     * @notice Samples independent amounts used to verify the reported result
     * @param recipient Recipient of the operation's surplus
     * @return state Balances and loan counts before the call
     */
    function _executionState(address recipient) internal view returns (ExecutionState memory state) {
        state.digest = _previewState();
        state.source = aPtOld.balanceOf(user);
        state.target = aPtNew.balanceOf(user);
        state.debt = debtToken.balanceOf(user);
        state.paid = ausd.balanceOf(recipient);
        state.routerCash = ausd.balanceOf(address(router));
        state.morphoLoans = morpho.flashLoanCount();
        state.poolLoans = flashPool.flashLoanCount();
        (state.lender, state.cash) = gateway.flashCapacity();
    }

    /**
     * @notice Fingerprints balances, supplies, allowances, configuration, permit data, and integration state
     * @return stateHash Current state of all actors and tokens touched by the fixture's execution paths
     */
    function _previewState() internal view returns (bytes32 stateHash) {
        address[8] memory tokens = [
            address(ausd),
            address(ptOld),
            address(ptNew),
            address(aPtOld),
            address(aPtNew),
            address(aAusd),
            address(syOld),
            address(syNew)
        ];
        address[12] memory accounts = [
            user,
            attacker,
            beneficiary,
            address(gateway),
            address(pool),
            address(router),
            address(morpho),
            address(flashPool.A_TOKEN()),
            address(aPtOld),
            address(aPtNew),
            address(ytOld),
            address(aAusd)
        ];
        for (uint256 i; i < tokens.length; ++i) {
            IERC20 token = IERC20(tokens[i]);
            stateHash = keccak256(abi.encode(stateHash, token.totalSupply()));
            for (uint256 j; j < accounts.length; ++j) {
                stateHash = keccak256(
                    abi.encode(
                        stateHash,
                        token.balanceOf(accounts[j]),
                        token.allowance(accounts[j], address(gateway)),
                        token.allowance(address(gateway), accounts[j])
                    )
                );
            }
        }
        for (uint256 i; i < accounts.length; ++i) {
            (bool readable, bytes memory configuration) = address(pool)
                .staticcall(abi.encodeWithSelector(MockIsolatedPool.getUserConfiguration.selector, accounts[i]));
            stateHash = keccak256(
                abi.encode(
                    stateHash,
                    readable,
                    configuration,
                    debtToken.balanceOf(accounts[i]),
                    debtToken.scaledBalanceOf(accounts[i])
                )
            );
        }
        stateHash = keccak256(abi.encode(stateHash, debtToken.scaledTotalSupply()));
        address[5] memory contracts =
            [address(gateway), address(router), address(aPtOld), address(morpho), address(flashPool)];
        for (uint256 i; i < contracts.length; ++i) {
            for (uint256 slot; slot < 24; ++slot) {
                stateHash = keccak256(abi.encode(stateHash, vm.load(contracts[i], bytes32(slot))));
            }
        }
    }

    /**
     * @notice Asserts the selected lender ran exactly the reported rounds
     * @param source Reported lender
     * @param rounds Reported rounds
     * @param morphoLoans Initial Morpho loan count
     * @param poolLoans Initial global-pool loan count
     */
    function _assertFlashLoans(address source, uint256 rounds, uint256 morphoLoans, uint256 poolLoans) internal view {
        assertEq(morpho.flashLoanCount() - morphoLoans, source == address(morpho) ? rounds : 0);
        assertEq(flashPool.flashLoanCount() - poolLoans, source == address(flashPool) ? rounds : 0);
    }

    /**
     * @notice Asserts the health factor is the actual final pool value when available
     * @param reported Reported health factor
     * @param available Whether account data could be read
     */
    function _assertHealthFactor(uint256 reported, bool available) internal view {
        if (!available) {
            assertEq(reported, 0);

            return;
        }
        if (
            pool.getUserConfiguration(user).data & 0x5555555555555555555555555555555555555555555555555555555555555555
                == 0
        ) {
            assertEq(reported, type(uint256).max);

            return;
        }
        (,,,,, uint256 healthFactor) = pool.getUserAccountData(user);
        assertEq(reported, healthFactor);
    }

    /**
     * @notice Checks exact close errors for a source and amount
     * @param pt Source asset
     * @param ptAmount Requested amount
     * @param reason Complete expected revert bytes
     */
    function _assertCloseRevertParity(address pt, uint256 ptAmount, bytes memory reason) internal {
        INeverlandPendleMaturityGateway.CloseParams memory params = _closeParams(ptAmount, 0, beneficiary, 10);
        params.ptOld = pt;
        _assertCloseParamsRevertParity(params, reason);
    }

    /**
     * @notice Checks exact errors for identical close parameters
     * @param params Parameters shared by both calls
     * @param reason Complete expected revert bytes
     */
    function _assertCloseParamsRevertParity(
        INeverlandPendleMaturityGateway.CloseParams memory params,
        bytes memory reason
    ) internal {
        _assertRevertParity(
            user, abi.encodeCall(gateway.previewClose, (params)), abi.encodeCall(gateway.close, (params)), reason
        );
    }

    /**
     * @notice Checks exact errors for identical migration parameters
     * @param params Parameters shared by both calls
     * @param reason Complete expected revert bytes
     */
    function _assertMigrateRevertParity(
        INeverlandPendleMaturityGateway.MigrateParams memory params,
        bytes memory reason
    ) internal {
        _assertRevertParity(
            user, abi.encodeCall(gateway.previewMigrate, (params)), abi.encodeCall(gateway.migrate, (params)), reason
        );
    }

    /**
     * @notice Requires byte-for-byte error equality and complete rollback on both failing calls
     * @param caller Position owner passed as msg.sender
     * @param previewData Encoded preview call
     * @param executionData Encoded execution call
     * @param reason Complete expected revert bytes
     */
    function _assertRevertParity(
        address caller,
        bytes memory previewData,
        bytes memory executionData,
        bytes memory reason
    ) internal {
        bytes32 stateBefore = _previewState();
        vm.prank(caller);
        (bool previewSuccess, bytes memory previewResult) = address(gateway).call(previewData);

        assertFalse(previewSuccess, "preview unexpectedly succeeded");
        assertEq(previewResult, reason, "preview revert bytes differ");
        assertEq(_previewState(), stateBefore, "failed preview changed state");

        vm.prank(caller);
        (bool executionSuccess, bytes memory executionResult) = address(gateway).call(executionData);

        assertFalse(executionSuccess, "execution unexpectedly succeeded");
        assertEq(executionResult, previewResult, "execution revert bytes differ");
        assertEq(_previewState(), stateBefore, "failed execution changed state");
    }

    /**
     * @notice Asserts the gateway's reported flash source and cash
     * @param source The expected lender address
     * @param cash The expected cash
     */
    function _assertCapacity(address source, uint256 cash) internal view {
        (address actualSource, uint256 actualCash) = gateway.flashCapacity();

        assertEq(actualSource, source);
        assertEq(actualCash, cash);
    }

    /**
     * @notice Reads a user's collateral flag for a reserve id from the mock pool
     * @param account The user
     * @param id The reserve id
     * @return Whether the flag is set
     */
    function _usesAsCollateral(address account, uint256 id) internal view returns (bool) {
        return (pool.getUserConfiguration(account).data >> (id * 2 + 1)) & 1 != 0;
    }

    /**
     * @notice Supplies `pt` source PT for `account` and opens `debt` of variable debt against it
     * @param account The borrower
     * @param pt The source PT supplied
     * @param debt The debt opened
     */
    function _openPosition(address account, uint256 pt, uint256 debt) internal {
        _supplyFor(account, ptOld, pt);
        if (debt != 0) pool.mintDebt(account, debt);
    }

    /**
     * @notice Mints `amount` of `token` to `account` and supplies it to the pool on its behalf
     * @param account The supplier
     * @param token The reserve asset
     * @param amount The amount
     */
    function _supplyFor(address account, MockGatewayToken token, uint256 amount) internal {
        token.mint(account, amount);
        vm.startPrank(account);
        token.approve(address(pool), amount);
        pool.supply(address(token), amount, account, 0);
        vm.stopPrank();
    }

    /// @notice Expires the source PT
    function _mature() internal {
        ptOld.setExpired(true);
    }

    /**
     * @notice Approves the gateway on `account`'s source aTokens
     * @param account The position owner
     */
    function _approveSource(address account) internal {
        vm.prank(account);
        aPtOld.approve(address(gateway), type(uint256).max);
    }

    /// @notice Registers the target market and prices the target PT at 0.99 debt asset
    function _registerTarget() internal {
        vm.prank(owner);
        gateway.setMigrationTarget(address(marketNew));
        router.setPriceWad(0.99e18);
    }

    /**
     * @notice Target PT the router mints for `spend` at 0.99
     * @param spend The debt asset spent
     * @return The target PT bought
     */
    function _bought(uint256 spend) internal pure returns (uint256) {
        return spend * 1e18 / 0.99e18;
    }

    /**
     * @notice Close parameters over the source PT
     * @param ptAmount The source amount
     * @param minSurplusOut The minimum surplus
     * @param to The surplus recipient
     * @param maxRounds The round limit
     * @return The parameters
     */
    function _closeParams(uint256 ptAmount, uint256 minSurplusOut, address to, uint256 maxRounds)
        internal
        view
        returns (INeverlandPendleMaturityGateway.CloseParams memory)
    {
        return INeverlandPendleMaturityGateway.CloseParams({
            ptOld: address(ptOld), ptAmount: ptAmount, minSurplusOut: minSurplusOut, to: to, maxRounds: maxRounds
        });
    }

    /**
     * @notice Migration parameters from the source to the target PT with no output or health-factor minimum
     * @param ptAmount The source amount
     * @param repayAmount The repayment
     * @param maxRounds The round limit
     * @return params The parameters
     */
    function _migrateParams(uint256 ptAmount, uint256 repayAmount, uint256 maxRounds)
        internal
        view
        returns (INeverlandPendleMaturityGateway.MigrateParams memory params)
    {
        params.ptOld = address(ptOld);
        params.ptAmount = ptAmount;
        params.ptNew = address(ptNew);
        params.repayAmount = repayAmount;
        params.maxRounds = maxRounds;
    }

    /**
     * @notice A recognizable permit over `value`
     * @param value The permitted amount
     * @return The permit
     */
    function _permit(uint256 value) internal view returns (INeverlandPendleMaturityGateway.PermitParams memory) {
        return INeverlandPendleMaturityGateway.PermitParams({
            value: value, deadline: block.timestamp + 1 hours, v: 27, r: bytes32(uint256(1)), s: bytes32(uint256(2))
        });
    }

    /**
     * @notice Asserts the source aToken received exactly `permit` from the user for the gateway
     * @param permit The permit sent
     */
    function _assertPermitForwarded(INeverlandPendleMaturityGateway.PermitParams memory permit) internal view {
        assertEq(aPtOld.permitCallCount(), 1);
        assertEq(aPtOld.lastPermitOwner(), user);
        assertEq(aPtOld.lastPermitSpender(), address(gateway));
        assertEq(aPtOld.lastPermitValue(), permit.value);
        assertEq(aPtOld.lastPermitDeadline(), permit.deadline);
        assertEq(aPtOld.lastPermitV(), permit.v);
        assertEq(aPtOld.lastPermitR(), permit.r);
        assertEq(aPtOld.lastPermitS(), permit.s);
    }

    /**
     * @notice Asserts two router search hints are equal
     * @param actual The recorded hint
     * @param expected The expected hint
     */
    function _assertApprox(IPendleRouterV4.ApproxParams memory actual, IPendleRouterV4.ApproxParams memory expected)
        internal
        pure
    {
        assertEq(actual.guessMin, expected.guessMin);
        assertEq(actual.guessMax, expected.guessMax);
        assertEq(actual.guessOffchain, expected.guessOffchain);
        assertEq(actual.maxIteration, expected.maxIteration);
        assertEq(actual.eps, expected.eps);
    }

    /// @notice Asserts the gateway holds none of the tokens a call touches
    function _assertGatewayEmpty() internal view {
        assertEq(ausd.balanceOf(address(gateway)), 0);
        assertEq(ptOld.balanceOf(address(gateway)), 0);
        assertEq(ptNew.balanceOf(address(gateway)), 0);
        assertEq(aPtOld.balanceOf(address(gateway)), 0);
        assertEq(aPtNew.balanceOf(address(gateway)), 0);
        assertEq(syOld.balanceOf(address(gateway)), 0);
        assertEq(syNew.balanceOf(address(gateway)), 0);
    }

    /// @notice Asserts the gateway left no debt-asset or source-PT allowance behind
    function _assertNoApprovals() internal view {
        assertEq(ausd.allowance(address(gateway), address(pool)), 0);
        assertEq(ausd.allowance(address(gateway), address(router)), 0);
        assertEq(ausd.allowance(address(gateway), address(morpho)), 0);
        assertEq(ausd.allowance(address(gateway), address(flashPool)), 0);
        assertEq(ptOld.allowance(address(gateway), address(pool)), 0);
        assertEq(ptOld.allowance(address(gateway), address(ytOld)), 0);
    }

    /// @notice Sends the gateway stray debt asset, source PT, source aTokens, and source SY
    function _seedStrays() internal {
        ausd.mint(address(gateway), 7e18);
        ptOld.mint(address(gateway), 11e18);
        aPtOld.mint(address(gateway), 17e18);
        syOld.mint(address(gateway), 19e18);
    }

    /// @notice Asserts the stray balances from `_seedStrays` are untouched
    function _assertStraysUnchanged() internal view {
        assertEq(ausd.balanceOf(address(gateway)), 7e18);
        assertEq(ptOld.balanceOf(address(gateway)), 11e18);
        assertEq(aPtOld.balanceOf(address(gateway)), 17e18);
        assertEq(syOld.balanceOf(address(gateway)), 19e18);
    }

    /**
     * @notice Flash data encoding a round of `amount`
     * @param amount The round amount
     * @return The encoded round
     */
    function _roundData(uint256 amount) internal pure returns (bytes memory) {
        NeverlandPendleMaturityGateway.RoundContext memory ctx;
        ctx.amount = amount;

        return abi.encode(ctx);
    }

    /**
     * @notice A one-element address array
     * @param value The element
     * @return array The array
     */
    function _array(address value) internal pure returns (address[] memory array) {
        array = new address[](1);
        array[0] = value;
    }

    /**
     * @notice A one-element uint256 array
     * @param value The element
     * @return array The array
     */
    function _array(uint256 value) internal pure returns (uint256[] memory array) {
        array = new uint256[](1);
        array[0] = value;
    }

    /**
     * @notice Reads a user's borrowing flag for a reserve id from the mock pool
     * @param account The user
     * @param id The reserve id
     * @return Whether the flag is set
     */
    function _isBorrowing(address account, uint256 id) internal view returns (bool) {
        return (pool.getUserConfiguration(account).data >> (id * 2)) & 1 != 0;
    }

    /**
     * @notice Replays a migration's even round sizing to count partial repay rounds and spot a 1-wei repay chunk
     * @param ptAmount The migrated amount
     * @param cash The lender's cash
     * @param repayTotal The clamped repayment
     * @return rounds Rounds that repay
     * @return oneWeiChunk Whether any repay chunk is exactly 1 wei
     */
    function _repayChunks(uint256 ptAmount, uint256 cash, uint256 repayTotal)
        internal
        pure
        returns (uint256 rounds, bool oneWeiChunk)
    {
        for (uint256 ptLeft = ptAmount; ptLeft != 0 && repayTotal != 0;) {
            uint256 amount = Math.ceilDiv(ptLeft, Math.ceilDiv(ptLeft, cash));
            uint256 chunk = Math.min(repayTotal, amount);
            if (chunk == 1) oneWeiChunk = true;
            repayTotal -= chunk;
            ptLeft -= amount;
            ++rounds;
        }
    }

    /// @notice Morpho at 100, the pool at 400 with the gateway holding the role
    function _richerPoolWithRole() internal {
        ausd.mint(address(morpho), 100e18);
        flashPool.seed(beneficiary, 400e18);
        flashPool.ACL().setFlashBorrower(address(gateway), true);
    }

    /**
     * @notice Deploys a gateway with the given constructor arguments
     * @param pool_ The position pool
     * @param debtAsset_ The debt asset
     * @param morpho_ The Morpho lender
     * @param flashPool_ The flash pool
     * @param router_ The Pendle router
     * @param owner_ The initial owner
     * @return The gateway
     */
    function _deploy(
        IPool pool_,
        address debtAsset_,
        address morpho_,
        IPool flashPool_,
        address router_,
        address owner_
    ) internal returns (NeverlandPendleMaturityGateway) {
        return new NeverlandPendleMaturityGateway(
            pool_, debtAsset_, morpho_, flashPool_, router_, address(marketNew), owner_
        );
    }

    /**
     * @notice Deploys a PT with its SY and YT, wired both ways
     * @param symbol The PT symbol
     * @return pt The PT
     * @return sy Its SY, redeeming into AUSD
     * @return yt Its YT
     */
    function _deployPrincipalToken(string memory symbol)
        internal
        returns (MockPendlePt pt, MockPendleSy sy, MockPendleYt yt)
    {
        pt = new MockPendlePt(symbol);
        sy = new MockPendleSy(ausd);
        yt = new MockPendleYt(pt, sy);
        pt.setSy(address(sy));
        pt.setYt(address(yt));
    }
}

/**
 * @title GatewayHarness
 * @author Neverland
 * @notice Exposes the gateway's internal resolution, flash-source, and balance-check helpers, and sets the flash flag
 */
contract GatewayHarness is NeverlandPendleMaturityGateway {
    constructor(
        IPool pool_,
        address debtAsset_,
        address morpho_,
        IPool flashPool_,
        address pendleRouter_,
        address initialMarket_,
        address initialOwner_
    )
        NeverlandPendleMaturityGateway(
            pool_, debtAsset_, morpho_, flashPool_, pendleRouter_, initialMarket_, initialOwner_
        )
    {}

    function exposed_resolveSource(address pt) external view returns (SourceToken memory) {
        return _resolveSource(pt);
    }

    function exposed_resolveTarget(address pt) external view returns (TargetToken memory) {
        return _resolveTarget(pt);
    }

    function exposed_resolveAmount(address user, address aToken, uint256 requested) external view returns (uint256) {
        return _resolveAmount(user, aToken, requested);
    }

    function exposed_selectFlashSource(uint256 flashTotal, uint256 maxRounds)
        external
        view
        returns (FlashSource lender, uint256 cash)
    {
        return _selectFlashSource(flashTotal, maxRounds);
    }

    function exposed_lenderOf(FlashSource lender) external view returns (address) {
        return _lenderOf(lender);
    }

    function exposed_variableDebtToken() external view returns (address) {
        return _variableDebtToken();
    }

    function exposed_snapshot(address ptOld, address ptNew) external view returns (BalanceSnapshot memory) {
        return _snapshot(ptOld, ptNew);
    }

    function exposed_oracleMinimum(address pt, uint256 spent) external view returns (uint256) {
        return _oracleMinimum(pt, spent);
    }

    function exposed_assertSnapshot(BalanceSnapshot memory entry, address ptOld, address ptNew) external view {
        _assertSnapshot(entry, ptOld, ptNew);
    }

    function exposed_setInFlight(FlashSource lender) external {
        _inFlight = lender;
    }
}

/**
 * @title BatchCaller
 * @author Neverland
 * @notice Holds a position and runs two migrations in one transaction
 */
contract BatchCaller {
    function migrateTwice(
        NeverlandPendleMaturityGateway gateway,
        INeverlandPendleMaturityGateway.MigrateParams calldata first,
        INeverlandPendleMaturityGateway.MigrateParams calldata second
    ) external {
        gateway.migrate(first);
        gateway.migrate(second);
    }
}

/**
 * @title GatewayReportingGasBurner
 * @author Neverland
 * @notice Exhausts the gas forwarded to an optional account-data read
 */
contract GatewayReportingGasBurner {
    /// @notice Burns all forwarded gas without returning account data
    function getUserAccountData(address) external pure {
        assembly ("memory-safe") {
            for {} 1 {} {}
        }
    }
}

/**
 * @title GatewayReportingGasThreshold
 * @author Neverland
 * @notice Returns account data with ample gas and exhausts smaller reporting budgets
 */
contract GatewayReportingGasThreshold {
    /// @notice Needs 450k gas, below the reporting cap but above half the bounded calls' remaining gas
    function getUserAccountData(address) external view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        if (gasleft() < 450_000) {
            assembly ("memory-safe") {
                for {} 1 {} {}
            }
        }

        return (0, 0, 0, 0, 0, 2e18);
    }
}

/**
 * @title GatewaySettledHealthFactor
 * @author Neverland
 * @notice Supplies account data only after surplus payment and with more gas than optional reporting allows
 */
contract GatewaySettledHealthFactor {
    error StrictReadRequired();
    error SurplusNotSettled();

    IERC20 public immutable DEBT_ASSET;

    constructor(IERC20 debtAsset) {
        DEBT_ASSET = debtAsset;
    }

    /// @notice Requires completed surplus settlement and a strict account-data call
    function getUserAccountData(address account)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        if (DEBT_ASSET.balanceOf(account) == 0) revert SurplusNotSettled();
        if (gasleft() <= 500_000) revert StrictReadRequired();

        return (0, 0, 0, 0, 0, 2e18);
    }
}

/**
 * @title GatewayPreviewReentryProbe
 * @author Neverland
 * @notice Checks that caught simulation failures preserve an active execution guard
 */
contract GatewayPreviewReentryProbe is Test {
    /// @dev Successful guard checks made by the callback
    uint256 public checks;

    /**
     * @notice Attempts a preview, direct simulation, and execution from one callback
     * @param gateway Gateway being called by the router
     * @param params Reentrant close parameters
     */
    function checkGuard(
        NeverlandPendleMaturityGateway gateway,
        INeverlandPendleMaturityGateway.CloseParams calldata params
    ) external {
        bytes memory expected = abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        (bool success, bytes memory result) = address(gateway).call(abi.encodeCall(gateway.previewClose, (params)));

        assertFalse(success, "nested preview bypassed guard");
        assertEq(result, expected);

        (success, result) =
            address(gateway).call(abi.encodeCall(gateway.simulate, (abi.encodeCall(gateway.close, (params)))));

        assertFalse(success, "simulator returned normally");

        (bool executed, bytes memory reason) = abi.decode(result, (bool, bytes));

        assertFalse(executed, "simulation bypassed guard");
        assertEq(reason, expected);

        (success, result) = address(gateway).call(abi.encodeCall(gateway.close, (params)));

        assertFalse(success, "preview cleared outer guard");
        assertEq(result, expected);

        checks += 3;
    }
}

/**
 * @title GatewayCapacityGasBurner
 * @author Neverland
 * @notice Exhausts the optional global-pool capacity read without affecting the Morpho path
 */
contract GatewayCapacityGasBurner {
    /// @notice Burns the forwarded capacity-read gas
    fallback() external {
        assembly ("memory-safe") {
            for {} 1 {} {}
        }
    }
}
