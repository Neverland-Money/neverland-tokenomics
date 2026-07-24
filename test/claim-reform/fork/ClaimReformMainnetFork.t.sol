// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {IDustLock} from "../../../src/interfaces/IDustLock.sol";
import {IDustLockTransferStrategy} from "../../../src/interfaces/IDustLockTransferStrategy.sol";
import {IDustRewardsController} from "../../../src/interfaces/IDustRewardsController.sol";
import {IDustTransferStrategy} from "../../../src/interfaces/IDustTransferStrategy.sol";
import {IRevenueReward} from "../../../src/interfaces/IRevenueReward.sol";

import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";

import {DustLockTransferStrategy} from "../../../src/emissions/DustLockTransferStrategy.sol";
import {RevenueReward} from "../../../src/rewards/RevenueReward.sol";
import {DustLock} from "../../../src/tokens/DustLock.sol";
import {ClaimReformModel} from "../_utils/ClaimReformModel.sol";
import {MockERC20} from "../../_utils/MockERC20.sol";

/**
 * @title ClaimReformMainnetForkTest
 * @author Neverland
 * @notice Pinned Monad-mainnet rehearsal of the atomic DustLock and RevenueReward NGV-05 implementation upgrade
 * @dev This suite only mutates an ephemeral local fork. Enable it explicitly with
 *      RUN_CLAIM_REFORM_FORK_TESTS=true and provide MAINNET_RPC.
 */
contract ClaimReformMainnetForkTest is Test {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /// @dev Named DustLock state read through the active implementation for cross-implementation equality
    struct DustLockCriticalState {
        bool canSplitSampledOwner;
        uint256 earlyWithdrawPenalty;
        address earlyWithdrawTreasury;
        uint256 epoch;
        uint256 feeEnforcedOperatorCount;
        address forwarder;
        uint256 minLockAmount;
        address pendingTeam;
        uint256 permanentLockBalance;
        address revenueReward;
        uint96 royaltyFeeBps;
        address royaltyReceiver;
        address sampledApproved;
        bytes32 sampledGlobalPointHash;
        bytes32 sampledLockHash;
        address sampledOwner;
        uint256 sampledOwnerBalance;
        uint256 sampledOwnerFirstTokenId;
        int256 sampledSlopeChange;
        string sampledTokenURI;
        uint256 sampledUserPointEpoch;
        bytes32 sampledUserPointHash;
        uint256 sampledVotingPower;
        uint256 supply;
        address team;
        address token;
        uint256 tokenId;
        uint256 totalVotingPower;
        address transferValidator;
    }

    /// @dev Named RevenueReward state read through the active implementation for cross-implementation equality
    struct RevenueRewardCriticalState {
        address dustLock;
        address rewardDistributor;
        bytes32 rewardLedgerHash;
        bytes32 rewardTokensHash;
        uint256 rewardTokensLength;
        uint256 sampledLastEarnTime;
        uint256 sampledMintTime;
        uint256 sampledRemainingAccScaled;
        address sampledRewardReceiver;
        bytes32 sampledUserTokensHash;
        bytes32 selfRepayUsersHash;
        address userVaultFactory;
    }

    /// @dev Named fork state restored after the locally isolated strategy route rehearsal
    struct StrategyRouteBaseline {
        uint256 burnWalletBalance;
        uint256 dustLockBalance;
        uint256 lockedSupply;
        uint256 permanentLockBalance;
        uint256 recipientBalance;
        uint256 tokenId;
        uint256 totalSupply;
        uint256 vaultBalance;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    address internal constant DUST = 0xAD96C3dffCD6374294e2573A7fBBA96097CC8d7c;
    address internal constant DUST_LOCK = 0xBB4738D05AD1b3Da57a4881baE62Ce9bb1eEeD6C;
    address internal constant DUST_LOCK_TRANSFER_STRATEGY_V2 = 0x958192C6208b3289951342eDDE1a051dE4E955bb;
    address internal constant DUST_REWARDS_CONTROLLER = 0x57ea245cCbFAb074baBb9d01d1F0c60525E52cec;
    address internal constant DUST_VAULT = 0x178D5F48a27f728E24e7d530a7c5c901778AAdE7;
    address internal constant REVENUE_REWARD = 0xff20ac10eb808B1e31F5CfCa58D80eDE2Ba71c43;
    address internal constant DUST_LOCK_PREDECESSOR_IMPLEMENTATION = 0x1bEF87340a8068D4E91bC19B2e5ddfb66466e2D7;
    address internal constant REVENUE_REWARD_PREDECESSOR_IMPLEMENTATION = 0x6459AaB1C6Ca2EBA6c4d0CeFb00e469E48430b79;
    address internal constant CORE_PROXY_ADMIN = 0x6400650cED1eD7179143D40b4431c3cC8c068D90;
    address internal constant GOVERNANCE_TIMELOCK = 0x3e4749D9Df7EC5ecd9184c301592bAc058a6F82f;
    address internal constant STRATEGY_TEST_USER = address(0xc1a2);
    address internal constant TEST_USER = address(0xc1a1);

    uint256 internal constant DEFAULT_FORK_BLOCK = 87_945_871;
    uint256 internal constant MAXTIME = 365 days;
    uint256 internal constant DUST_LOCK_STORAGE_SLOT_COUNT = 228;
    uint256 internal constant REVENUE_REWARD_STORAGE_SLOT_COUNT = 215;
    uint256 internal constant SAMPLE_ACTIVE_TOKEN_ID = 21_408;
    uint256 internal constant STRATEGY_EXISTING_PERMANENT_GROSS = 444 ether;
    uint256 internal constant STRATEGY_EXISTING_TIMED_GROSS = 333 ether;
    uint256 internal constant STRATEGY_FUNDING = 10_000 ether;
    uint256 internal constant STRATEGY_INSTANT_GROSS = 101 ether + 1;
    uint256 internal constant STRATEGY_NEW_PERMANENT_GROSS = 700 ether;
    uint256 internal constant STRATEGY_NEW_TIMED_GROSS = 1_000 ether;
    uint256 internal constant STRATEGY_TIMED_DURATION = 180 days;

    bytes4 internal constant PREDECESSOR_INTERFACE_ID = 0x03448477;
    bytes4 internal constant CLAIM_REFORM_INTERFACE_ID = 0xef81dd26;

    /*//////////////////////////////////////////////////////////////
                          STORAGE VARIABLES
    //////////////////////////////////////////////////////////////*/

    IDustLock internal dustLock = IDustLock(DUST_LOCK);
    IRevenueReward internal revenueReward = IRevenueReward(REVENUE_REWARD);
    ProxyAdmin internal proxyAdmin = ProxyAdmin(CORE_PROXY_ADMIN);

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        vm.skip(
            !vm.envOr("RUN_CLAIM_REFORM_FORK_TESTS", false),
            "set RUN_CLAIM_REFORM_FORK_TESTS=true and MAINNET_RPC to enable the fork rehearsal"
        );

        string memory rpc = vm.envString("MAINNET_RPC");
        uint256 forkBlock = vm.envOr("CLAIM_REFORM_FORK_BLOCK", DEFAULT_FORK_BLOCK);
        vm.createSelectFork(rpc, forkBlock);

        assertEq(block.chainid, 143, "MAINNET_RPC must be Monad mainnet");
        assertEq(proxyAdmin.owner(), GOVERNANCE_TIMELOCK, "unexpected ProxyAdmin owner");
        assertEq(
            proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(payable(DUST_LOCK))),
            DUST_LOCK_PREDECESSOR_IMPLEMENTATION,
            "unexpected DustLock predecessor implementation"
        );
        assertEq(
            proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(payable(REVENUE_REWARD))),
            REVENUE_REWARD_PREDECESSOR_IMPLEMENTATION,
            "unexpected RevenueReward predecessor implementation"
        );
        /*
         * The fork quote model prices exits at the live scalar; pin it so a scalar change on
         * mainnet fails here with a clear message instead of a model mismatch.
         */
        assertEq(dustLock.earlyWithdrawPenalty(), 7_500, "unexpected DustLock earlyWithdrawPenalty scalar");
    }

    /*//////////////////////////////////////////////////////////////
                                TESTS
    //////////////////////////////////////////////////////////////*/

    function testPinnedUpgradePreservesStateActivatesPricingAndRollsBackCleanly() public {
        assertEq(dustLock.version(), "2.0.0");
        assertEq(type(IDustLock).interfaceId, CLAIM_REFORM_INTERFACE_ID);
        assertTrue(dustLock.supportsInterface(PREDECESSOR_INTERFACE_ID));
        assertFalse(dustLock.supportsInterface(CLAIM_REFORM_INTERFACE_ID));
        _assertClaimReformQuoteUnavailable();
        _assertFollowingEpochNotifyUnavailable();

        IDustLock.LockedBalance memory sampledLockBefore = dustLock.locked(SAMPLE_ACTIVE_TOKEN_ID);
        address sampledOwnerBefore = dustLock.ownerOf(SAMPLE_ACTIVE_TOKEN_ID);
        uint256 tokenIdBefore = dustLock.tokenId();
        uint256 supplyBefore = dustLock.supply();
        uint256 permanentBefore = dustLock.permanentLockBalance();
        bytes32[] memory dustLockPredecessorStorage = _snapshotStorage(DUST_LOCK, DUST_LOCK_STORAGE_SLOT_COUNT);
        bytes32[] memory revenueRewardPredecessorStorage =
            _snapshotStorage(REVENUE_REWARD, REVENUE_REWARD_STORAGE_SLOT_COUNT);

        RevenueReward revenueRewardCandidate = new RevenueReward(dustLock.forwarder());
        DustLock dustLockCandidate = new DustLock(dustLock.forwarder());
        vm.startPrank(GOVERNANCE_TIMELOCK);
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(payable(REVENUE_REWARD)), address(revenueRewardCandidate));
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(payable(DUST_LOCK)), address(dustLockCandidate));
        vm.stopPrank();

        assertEq(
            proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(payable(REVENUE_REWARD))),
            address(revenueRewardCandidate)
        );
        assertEq(
            proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(payable(DUST_LOCK))),
            address(dustLockCandidate)
        );
        _assertStorageEquals(DUST_LOCK, dustLockPredecessorStorage);
        _assertStorageEquals(REVENUE_REWARD, revenueRewardPredecessorStorage);
        assertEq(dustLock.version(), "2.1.0");
        assertTrue(dustLock.supportsInterface(PREDECESSOR_INTERFACE_ID));
        assertTrue(dustLock.supportsInterface(CLAIM_REFORM_INTERFACE_ID));
        assertEq(dustLock.tokenId(), tokenIdBefore);
        assertEq(dustLock.supply(), supplyBefore);
        assertEq(dustLock.permanentLockBalance(), permanentBefore);
        assertEq(dustLock.ownerOf(SAMPLE_ACTIVE_TOKEN_ID), sampledOwnerBefore);
        assertEq(
            keccak256(abi.encode(dustLock.locked(SAMPLE_ACTIVE_TOKEN_ID))), keccak256(abi.encode(sampledLockBefore))
        );

        uint256 sampledAmount = uint256(sampledLockBefore.amount);
        uint256 sampledRemaining = sampledLockBefore.end - block.timestamp;
        uint256 sampledNet = sampledAmount * (3 * MAXTIME - 2 * sampledRemaining) / (4 * MAXTIME);
        assertEq(dustLock.earlyWithdrawPenaltyAmount(SAMPLE_ACTIVE_TOKEN_ID), sampledAmount - sampledNet);

        (bool initializedAgain,) = DUST_LOCK.call(
            abi.encodeCall(DustLock.initialize, (dustLock.forwarder(), DUST, "https://invalid.example/"))
        );
        assertFalse(initializedAgain, "proxy initializer replay succeeded");
        (bool revenueRewardInitializedAgain,) = REVENUE_REWARD.call(
            abi.encodeCall(
                RevenueReward.initialize,
                (dustLock.forwarder(), dustLock, revenueReward.rewardDistributor(), revenueReward.userVaultFactory())
            )
        );
        assertFalse(revenueRewardInitializedAgain, "RevenueReward proxy initializer replay succeeded");
        _assertStorageEquals(DUST_LOCK, dustLockPredecessorStorage);
        _assertStorageEquals(REVENUE_REWARD, revenueRewardPredecessorStorage);

        _exerciseForkRevenueBoundary();
        _exerciseForkFollowingEpochNotify();
        _exerciseForkOnlyExit();
        bytes32[] memory dustLockPostActionStorage = _snapshotStorage(DUST_LOCK, DUST_LOCK_STORAGE_SLOT_COUNT);
        bytes32[] memory revenueRewardPostActionStorage =
            _snapshotStorage(REVENUE_REWARD, REVENUE_REWARD_STORAGE_SLOT_COUNT);

        vm.startPrank(GOVERNANCE_TIMELOCK);
        proxyAdmin.upgrade(
            ITransparentUpgradeableProxy(payable(REVENUE_REWARD)), REVENUE_REWARD_PREDECESSOR_IMPLEMENTATION
        );
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(payable(DUST_LOCK)), DUST_LOCK_PREDECESSOR_IMPLEMENTATION);
        vm.stopPrank();

        assertEq(
            proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(payable(REVENUE_REWARD))),
            REVENUE_REWARD_PREDECESSOR_IMPLEMENTATION
        );
        assertEq(
            proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(payable(DUST_LOCK))),
            DUST_LOCK_PREDECESSOR_IMPLEMENTATION
        );
        _assertStorageEquals(DUST_LOCK, dustLockPostActionStorage);
        _assertStorageEquals(REVENUE_REWARD, revenueRewardPostActionStorage);
        assertEq(dustLock.version(), "2.0.0");
        assertTrue(dustLock.supportsInterface(PREDECESSOR_INTERFACE_ID));
        assertFalse(dustLock.supportsInterface(CLAIM_REFORM_INTERFACE_ID));
        _assertClaimReformQuoteUnavailable();
        _assertFollowingEpochNotifyUnavailable();
    }

    function testPinnedUpgradeReadsBackCriticalStorageUnshifted() public {
        DustLockCriticalState memory dustLockBefore = _captureDustLockCriticalState();
        RevenueRewardCriticalState memory revenueRewardBefore = _captureRevenueRewardCriticalState();
        assertGt(dustLockBefore.tokenId, 0);
        assertGt(dustLockBefore.supply, 0);
        assertGt(dustLockBefore.totalVotingPower, 0);
        assertGt(revenueRewardBefore.rewardTokensLength, 0);
        assertNotEq(dustLockBefore.sampledOwner, address(0));
        _assertDustLockSlotPinning(dustLockBefore);
        _assertRevenueRewardSlotPinning(revenueRewardBefore);

        _upgradeForkCoreCandidates();

        _assertCoreCriticalStateUnchangedAndPinned(dustLockBefore, revenueRewardBefore);

        vm.startPrank(GOVERNANCE_TIMELOCK);
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(payable(DUST_LOCK)), DUST_LOCK_PREDECESSOR_IMPLEMENTATION);
        proxyAdmin.upgrade(
            ITransparentUpgradeableProxy(payable(REVENUE_REWARD)), REVENUE_REWARD_PREDECESSOR_IMPLEMENTATION
        );
        vm.stopPrank();

        _assertCoreCriticalStateUnchangedAndPinned(dustLockBefore, revenueRewardBefore);
    }

    function testPinnedStrategyV3FailsClosedActivatesExercisesAllRoutesAndRestoresForkState() public {
        IDustRewardsController controller = IDustRewardsController(DUST_REWARDS_CONTROLLER);
        uint256 originalStrategyAllowanceBefore = IERC20(DUST).allowance(DUST_VAULT, DUST_LOCK_TRANSFER_STRATEGY_V2);
        assertEq(originalStrategyAllowanceBefore, type(uint256).max);
        (address originalStrategy, address emissionManager, DustLockTransferStrategy strategy) =
            _deployAndConfigureForkStrategy(controller);

        bytes32 sampledLockHashBefore = keccak256(abi.encode(dustLock.locked(SAMPLE_ACTIVE_TOKEN_ID)));
        address sampledOwnerBefore = dustLock.ownerOf(SAMPLE_ACTIVE_TOKEN_ID);
        bytes32[] memory dustLockStorageBefore = _snapshotStorage(DUST_LOCK, DUST_LOCK_STORAGE_SLOT_COUNT);
        bytes32[] memory revenueRewardStorageBefore =
            _snapshotStorage(REVENUE_REWARD, REVENUE_REWARD_STORAGE_SLOT_COUNT);

        _assertStrategyFailsClosedBeforeUpgrade(strategy);
        _upgradeForkCoreCandidates();

        _assertStorageEquals(DUST_LOCK, dustLockStorageBefore);
        _assertStorageEquals(REVENUE_REWARD, revenueRewardStorageBefore);
        strategy.assertActivationState(true);
        vm.expectRevert(IDustLockTransferStrategy.InvalidActivationState.selector);
        strategy.assertActivationState(false);

        address burnWallet = dustLock.earlyWithdrawTreasury();
        assertNotEq(burnWallet, address(0));
        assertNotEq(burnWallet, STRATEGY_TEST_USER);
        assertNotEq(burnWallet, DUST_VAULT);
        assertNotEq(burnWallet, DUST_LOCK);
        _exerciseAndRestoreForkStrategyRoutes(strategy, burnWallet);

        _rollbackForkCoreCandidates(strategy);
        _restoreForkStrategyConfiguration(controller, emissionManager, originalStrategy, strategy);

        assertEq(controller.getTransferStrategy(DUST), DUST_LOCK_TRANSFER_STRATEGY_V2);
        uint256 originalStrategyAllowanceAfter = IERC20(DUST).allowance(DUST_VAULT, originalStrategy);
        assertEq(originalStrategyAllowanceAfter, originalStrategyAllowanceBefore);
        assertEq(originalStrategyAllowanceAfter, type(uint256).max);
        assertEq(IERC20(DUST).allowance(DUST_VAULT, address(strategy)), 0);
        assertEq(IERC20(DUST).allowance(address(strategy), DUST_LOCK), 0);
        assertEq(IERC20(DUST).balanceOf(address(strategy)), 0);
        _assertStorageEquals(DUST_LOCK, dustLockStorageBefore);
        _assertStorageEquals(REVENUE_REWARD, revenueRewardStorageBefore);
        assertEq(dustLock.ownerOf(SAMPLE_ACTIVE_TOKEN_ID), sampledOwnerBefore);
        assertEq(keccak256(abi.encode(dustLock.locked(SAMPLE_ACTIVE_TOKEN_ID))), sampledLockHashBefore);
    }

    function testPinnedSampledLockDepositRevertsInsideFinalMinDuration() public {
        IDustRewardsController controller = IDustRewardsController(DUST_REWARDS_CONTROLLER);
        (,, DustLockTransferStrategy strategy) = _deployAndConfigureForkStrategy(controller);
        _upgradeForkCoreCandidates();
        strategy.assertActivationState(true);

        IDustLock.LockedBalance memory sampled = dustLock.locked(SAMPLE_ACTIVE_TOKEN_ID);
        address sampledOwner = dustLock.ownerOf(SAMPLE_ACTIVE_TOKEN_ID);
        assertFalse(sampled.isPermanent);

        /*
         * Warp to one second after the sampled lock's deposit cutoff (end - MINTIME is an exact weekly
         * boundary). Accepted behavior: with no grace, deposits into a lock inside its final 28 days
         * revert, and the one-second-late retry window does not exist.
         */
        uint256 cutoff = sampled.end - 28 days;
        assertEq(cutoff % 1 weeks, 0, "cutoff should be an exact reward boundary");
        vm.warp(cutoff + 1);
        vm.roll(block.number + 1);
        assertLt(dustLock.locked(SAMPLE_ACTIVE_TOKEN_ID).end - block.timestamp, 28 days);

        vm.expectRevert(IDustLock.DepositForLockDurationTooShort.selector);
        strategy.previewClaim(STRATEGY_EXISTING_TIMED_GROSS, 0, SAMPLE_ACTIVE_TOKEN_ID);

        vm.expectRevert(IDustLock.DepositForLockDurationTooShort.selector);
        vm.prank(DUST_REWARDS_CONTROLLER);
        strategy.performTransfer(sampledOwner, DUST, STRATEGY_EXISTING_TIMED_GROSS, 0, SAMPLE_ACTIVE_TOKEN_ID);

        // The direct DustLock path rejects the same deposit for the same reason.
        vm.expectRevert(IDustLock.DepositForLockDurationTooShort.selector);
        vm.prank(sampledOwner);
        dustLock.depositFor(SAMPLE_ACTIVE_TOKEN_ID, 1 ether);
    }

    /**
     * @notice E2E month-spanning proof of following-epoch scheduling on a live mainnet fork
     * @dev Ordinary notify pays at the next epoch boundary; following-epoch notify pays only at the
     *      epoch after next (zero before it); a following notify a month later lands and pays at its
     *      own later epoch. Claims settle exact quoted amounts and the contract balance conserves.
     */
    function testPinnedFollowingEpochSchedulingAcrossMonth() public {
        _upgradeForkCoreCandidates();

        // Constant voting power across the whole schedule.
        deal(DUST, TEST_USER, 10_000 ether, true);
        vm.startPrank(TEST_USER);
        IERC20(DUST).approve(DUST_LOCK, 10_000 ether);
        uint256 tokenId = dustLock.createLockPermanent(10_000 ether, MAXTIME);
        vm.stopPrank();

        MockERC20 rewardToken = new MockERC20("NGV-05 Fork Reward", "NGV05", 6);
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);

        uint256 epochB = block.timestamp - (block.timestamp % 1 weeks) + 1 weeks;
        uint256 epochC = epochB + 1 weeks;
        uint256 amountB = 1_000e6;
        uint256 amountC = 2_000e6;
        uint256 amountD = 3_000e6;

        address distributor = revenueReward.rewardDistributor();
        deal(address(rewardToken), distributor, amountB + amountC + amountD, true);
        vm.startPrank(distributor);
        rewardToken.approve(REVENUE_REWARD, type(uint256).max);
        revenueReward.notifyRewardAmount(address(rewardToken), amountB);
        revenueReward.notifyRewardAmountForFollowingEpoch(address(rewardToken), amountC);
        vm.stopPrank();

        // Each notify lands in exactly its scheduled bucket.
        assertEq(revenueReward.tokenRewardsPerEpoch(address(rewardToken), epochB), amountB, "ordinary bucket");
        assertEq(revenueReward.tokenRewardsPerEpoch(address(rewardToken), epochC), amountC, "following bucket");

        uint256 paidB = _claimForkEpochExactly(tokenId, rewardToken, tokens, epochB);

        // The following notify is not claimable before its epoch: settling at the current time yields zero.
        assertEq(revenueReward.earnedRewards(address(rewardToken), tokenId, epochB + 1), 0, "following not early");

        uint256 paidC = _claimForkEpochExactly(tokenId, rewardToken, tokens, epochC);

        // A month later, schedule following again; it lands in its own later bucket.
        vm.warp(epochC + 3 weeks);
        uint256 epochD = block.timestamp - (block.timestamp % 1 weeks) + 2 weeks;
        vm.prank(distributor);
        revenueReward.notifyRewardAmountForFollowingEpoch(address(rewardToken), amountD);
        assertEq(revenueReward.tokenRewardsPerEpoch(address(rewardToken), epochD), amountD, "month-later bucket");

        uint256 paidD = _claimForkEpochExactly(tokenId, rewardToken, tokens, epochD);

        // Conservation: the contract keeps exactly the unclaimed remainder of all three notifies.
        assertEq(
            rewardToken.balanceOf(REVENUE_REWARD),
            amountB + amountC + amountD - (paidB + paidC + paidD),
            "unclaimed remainder conserved"
        );
        assertEq(revenueReward.totalRewardsPerToken(address(rewardToken)), amountB + amountC + amountD);
    }

    /**
     * @notice Asserts the boundary-second deferral, then claims the epoch at +1 and checks exact payout
     * @return paid The exact amount settled for that epoch
     */
    function _claimForkEpochExactly(uint256 tokenId, MockERC20 rewardToken, address[] memory tokens, uint256 epoch)
        internal
        returns (uint256 paid)
    {
        vm.warp(epoch);
        vm.roll(block.number + 1);
        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        vm.prank(TEST_USER);
        revenueReward.getRewardUntilTs(tokenId, tokens, epoch);

        vm.warp(epoch + 1);
        uint256 expected = revenueReward.earnedRewards(address(rewardToken), tokenId, epoch);
        assertGt(expected, 0);
        uint256 balBefore = rewardToken.balanceOf(TEST_USER);
        vm.prank(TEST_USER);
        revenueReward.getRewardUntilTs(tokenId, tokens, epoch);
        assertEq(rewardToken.balanceOf(TEST_USER) - balBefore, expected, "epoch pays exactly");

        return expected;
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _exerciseForkRevenueBoundary() internal {
        uint256 amount = 10 ether;
        deal(DUST, TEST_USER, amount, true);
        vm.startPrank(TEST_USER);
        IERC20(DUST).approve(DUST_LOCK, amount);
        uint256 tokenId = dustLock.createLock(amount, MAXTIME);
        vm.stopPrank();

        MockERC20 rewardToken = new MockERC20("NGV-05 Fork Reward", "NGV05", 6);
        uint256 rewardAmount = 10_000e6;
        address distributor = revenueReward.rewardDistributor();
        deal(address(rewardToken), distributor, rewardAmount, true);
        vm.startPrank(distributor);
        rewardToken.approve(REVENUE_REWARD, rewardAmount);
        revenueReward.notifyRewardAmount(address(rewardToken), rewardAmount);
        vm.stopPrank();

        uint256 boundary = block.timestamp - (block.timestamp % 1 weeks) + 1 weeks;
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);
        vm.warp(boundary);
        vm.roll(block.number + 1);

        assertEq(revenueReward.earnedRewards(address(rewardToken), tokenId, boundary), 0);
        vm.prank(TEST_USER);
        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        revenueReward.getReward(tokenId, tokens);

        vm.warp(boundary + 1);
        vm.roll(block.number + 1);
        uint256 expectedReward = revenueReward.earnedRewards(address(rewardToken), tokenId, boundary);
        assertGt(expectedReward, 0);
        uint256 balanceBefore = rewardToken.balanceOf(TEST_USER);
        vm.prank(TEST_USER);
        revenueReward.getReward(tokenId, tokens);
        assertEq(rewardToken.balanceOf(TEST_USER) - balanceBefore, expectedReward);
    }

    function _exerciseForkOnlyExit() internal {
        uint256 amount = 10 ether;
        deal(DUST, TEST_USER, amount, true);
        vm.startPrank(TEST_USER);
        IERC20(DUST).approve(DUST_LOCK, amount);
        uint256 tokenId = dustLock.createLock(amount, MAXTIME);
        vm.stopPrank();

        uint256 penalty = dustLock.earlyWithdrawPenaltyAmount(tokenId);
        uint256 ownerBefore = IERC20(DUST).balanceOf(TEST_USER);
        uint256 treasuryBefore = IERC20(DUST).balanceOf(dustLock.earlyWithdrawTreasury());
        uint256 escrowBefore = IERC20(DUST).balanceOf(DUST_LOCK);
        uint256 lockedSupplyBefore = dustLock.supply();
        uint256 totalSupplyBefore = IERC20(DUST).totalSupply();

        vm.prank(TEST_USER);
        dustLock.earlyWithdraw(tokenId);

        assertEq(IERC20(DUST).balanceOf(TEST_USER) - ownerBefore, amount - penalty);
        assertEq(IERC20(DUST).balanceOf(dustLock.earlyWithdrawTreasury()) - treasuryBefore, penalty);
        assertEq(escrowBefore - IERC20(DUST).balanceOf(DUST_LOCK), amount);
        assertEq(lockedSupplyBefore - dustLock.supply(), amount);
        assertEq(IERC20(DUST).totalSupply(), totalSupplyBefore);
    }

    function _exerciseForkFollowingEpochNotify() internal {
        uint256 amount = 10 ether;
        deal(DUST, TEST_USER, amount, true);
        vm.startPrank(TEST_USER);
        IERC20(DUST).approve(DUST_LOCK, amount);
        uint256 tokenId = dustLock.createLock(amount, MAXTIME);
        vm.stopPrank();

        MockERC20 rewardToken = new MockERC20("NGV-05 Following Reward", "NGV05F", 6);
        uint256 rewardAmount = 10_000e6;
        address distributor = revenueReward.rewardDistributor();
        deal(address(rewardToken), distributor, rewardAmount, true);
        vm.startPrank(distributor);
        rewardToken.approve(REVENUE_REWARD, rewardAmount);
        revenueReward.notifyRewardAmountForFollowingEpoch(address(rewardToken), rewardAmount);
        vm.stopPrank();

        uint256 nextEpoch = block.timestamp - (block.timestamp % 1 weeks) + 1 weeks;
        uint256 targetEpoch = nextEpoch + 1 weeks;
        assertEq(revenueReward.tokenRewardsPerEpoch(address(rewardToken), nextEpoch), 0);
        assertEq(revenueReward.tokenRewardsPerEpoch(address(rewardToken), targetEpoch), rewardAmount);
        assertEq(revenueReward.totalRewardsPerToken(address(rewardToken)), rewardAmount);
        assertEq(rewardToken.balanceOf(REVENUE_REWARD), rewardAmount);

        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);
        vm.warp(nextEpoch + 1);
        vm.roll(block.number + 1);
        vm.prank(TEST_USER);
        revenueReward.getReward(tokenId, tokens);
        assertEq(rewardToken.balanceOf(TEST_USER), 0);

        vm.warp(targetEpoch);
        vm.roll(block.number + 1);
        vm.prank(TEST_USER);
        vm.expectRevert(CommonChecksLibrary.EpochFinalizationPending.selector);
        revenueReward.getReward(tokenId, tokens);

        vm.warp(targetEpoch + 1);
        vm.roll(block.number + 1);
        uint256 expectedReward = revenueReward.earnedRewards(address(rewardToken), tokenId, targetEpoch);
        assertGt(expectedReward, 0);
        vm.prank(TEST_USER);
        revenueReward.getReward(tokenId, tokens);
        assertEq(rewardToken.balanceOf(TEST_USER), expectedReward);
    }

    /**
     * @notice Deploys V3 against canonical fork wiring and stages the short fail-closed activation window
     * @param controller Canonical forked DustRewardsController
     * @return originalStrategy Canonical V2 strategy restored after rollback
     * @return emissionManager Forked authority used only through local impersonation
     * @return strategy Fresh V3 strategy candidate
     */
    function _deployAndConfigureForkStrategy(IDustRewardsController controller)
        internal
        returns (address originalStrategy, address emissionManager, DustLockTransferStrategy strategy)
    {
        originalStrategy = controller.getTransferStrategy(DUST);
        assertEq(originalStrategy, DUST_LOCK_TRANSFER_STRATEGY_V2);

        IDustLockTransferStrategy predecessorStrategy = IDustLockTransferStrategy(originalStrategy);
        address rewardsAdmin = predecessorStrategy.getRewardsAdmin();
        assertEq(predecessorStrategy.version(), 2);
        assertEq(predecessorStrategy.getIncentivesController(), DUST_REWARDS_CONTROLLER);
        assertNotEq(rewardsAdmin, address(0));
        assertEq(address(predecessorStrategy.DUST_LOCK()), DUST_LOCK);
        assertEq(predecessorStrategy.DUST_VAULT(), DUST_VAULT);
        assertEq(predecessorStrategy.DUST(), DUST);

        emissionManager = controller.EMISSION_MANAGER();
        assertNotEq(emissionManager, address(0));

        strategy = new DustLockTransferStrategy(DUST_REWARDS_CONTROLLER, rewardsAdmin, DUST_VAULT, DUST_LOCK);
        assertEq(strategy.version(), 3);
        assertEq(strategy.getIncentivesController(), DUST_REWARDS_CONTROLLER);
        assertEq(strategy.getRewardsAdmin(), rewardsAdmin);
        assertEq(address(strategy.DUST_LOCK()), DUST_LOCK);
        assertEq(strategy.DUST_VAULT(), DUST_VAULT);
        assertEq(strategy.DUST(), DUST);
        assertEq(IERC20(DUST).allowance(DUST_VAULT, address(strategy)), 0);

        vm.prank(DUST_VAULT);
        assertTrue(IERC20(DUST).approve(address(strategy), type(uint256).max));
        vm.prank(emissionManager);
        controller.setTransferStrategy(DUST, IDustTransferStrategy(address(strategy)));

        assertEq(controller.getTransferStrategy(DUST), address(strategy));
        assertEq(IERC20(DUST).allowance(DUST_VAULT, address(strategy)), type(uint256).max);
        strategy.assertActivationState(false);
        vm.expectRevert(IDustLockTransferStrategy.InvalidActivationState.selector);
        strategy.assertActivationState(true);
    }

    /**
     * @notice Proves a fully configured V3 strategy cannot pull the forked vault while DustLock is V2
     * @param strategy Fresh V3 strategy candidate
     */
    function _assertStrategyFailsClosedBeforeUpgrade(DustLockTransferStrategy strategy) internal {
        (uint256 expectedPenalty, uint256 expectedNet) = ClaimReformModel.instantClaim(STRATEGY_INSTANT_GROSS);
        (uint256 previewPenalty, uint256 previewNet) = strategy.previewClaim(STRATEGY_INSTANT_GROSS, 0, 0);
        assertEq(previewPenalty, expectedPenalty);
        assertEq(previewNet, expectedNet);
        assertGt(expectedPenalty, 0);
        assertGt(expectedNet, 0);
        assertEq(expectedPenalty + expectedNet, STRATEGY_INSTANT_GROSS);

        address burnWallet = dustLock.earlyWithdrawTreasury();
        StrategyRouteBaseline memory baseline = _captureStrategyRouteBaseline(burnWallet);

        vm.prank(DUST_REWARDS_CONTROLLER);
        vm.expectRevert(IDustLockTransferStrategy.DustLockClaimReformInactive.selector);
        strategy.performTransfer(STRATEGY_TEST_USER, DUST, STRATEGY_INSTANT_GROSS, 0, 0);

        _assertStrategyRouteBaseline(baseline, burnWallet);
        _assertStrategyResiduals(strategy);
    }

    /// @dev Deploys and selects both reviewed proxy candidates through the forked ProxyAdmin authority
    function _upgradeForkCoreCandidates() internal {
        RevenueReward revenueRewardCandidate = new RevenueReward(dustLock.forwarder());
        DustLock dustLockCandidate = new DustLock(dustLock.forwarder());

        vm.startPrank(GOVERNANCE_TIMELOCK);
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(payable(REVENUE_REWARD)), address(revenueRewardCandidate));
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(payable(DUST_LOCK)), address(dustLockCandidate));
        vm.stopPrank();

        assertEq(
            proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(payable(REVENUE_REWARD))),
            address(revenueRewardCandidate)
        );
        assertEq(
            proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(payable(DUST_LOCK))),
            address(dustLockCandidate)
        );
        assertEq(dustLock.version(), "2.1.0");
        assertTrue(dustLock.supportsInterface(CLAIM_REFORM_INTERFACE_ID));
    }

    /**
     * @notice Runs every strategy route, proves exact accounting, then reverts only those local fork mutations
     * @param strategy Active V3 strategy candidate
     * @param burnWallet Canonical DustLock early-exit penalty recipient
     */
    function _exerciseAndRestoreForkStrategyRoutes(DustLockTransferStrategy strategy, address burnWallet) internal {
        uint256 routeSnapshot = vm.snapshotState();
        StrategyRouteBaseline memory baseline = _captureStrategyRouteBaseline(burnWallet);
        bytes32[] memory dustLockStorageBefore = _snapshotStorage(DUST_LOCK, DUST_LOCK_STORAGE_SLOT_COUNT);
        bytes32[] memory revenueRewardStorageBefore =
            _snapshotStorage(REVENUE_REWARD, REVENUE_REWARD_STORAGE_SLOT_COUNT);

        deal(DUST, DUST_VAULT, baseline.vaultBalance + STRATEGY_FUNDING, true);
        assertEq(IERC20(DUST).balanceOf(DUST_VAULT) - baseline.vaultBalance, STRATEGY_FUNDING);
        assertEq(IERC20(DUST).totalSupply() - baseline.totalSupply, STRATEGY_FUNDING);

        _exerciseStrategyInstant(strategy, burnWallet);
        uint256 timedTokenId = _exerciseStrategyNewTimed(strategy, burnWallet);
        _exerciseStrategyExistingTimed(strategy, burnWallet, timedTokenId);
        uint256 permanentTokenId = _exerciseStrategyNewPermanent(strategy, burnWallet);
        _exerciseStrategyExistingPermanent(strategy, burnWallet, permanentTokenId);

        uint256 totalGross = STRATEGY_INSTANT_GROSS + STRATEGY_NEW_TIMED_GROSS + STRATEGY_EXISTING_TIMED_GROSS
            + STRATEGY_NEW_PERMANENT_GROSS + STRATEGY_EXISTING_PERMANENT_GROSS;
        assertEq(baseline.vaultBalance + STRATEGY_FUNDING - IERC20(DUST).balanceOf(DUST_VAULT), totalGross);
        assertGt(IERC20(DUST).balanceOf(burnWallet), baseline.burnWalletBalance);
        assertGt(IERC20(DUST).balanceOf(DUST_LOCK), baseline.dustLockBalance);
        assertGt(dustLock.supply(), baseline.lockedSupply);
        assertGt(dustLock.permanentLockBalance(), baseline.permanentLockBalance);
        assertEq(dustLock.tokenId(), baseline.tokenId + 2);

        assertTrue(vm.revertToStateAndDelete(routeSnapshot));
        _assertStrategyRouteBaseline(baseline, burnWallet);
        _assertStorageEquals(DUST_LOCK, dustLockStorageBefore);
        _assertStorageEquals(REVENUE_REWARD, revenueRewardStorageBefore);
        strategy.assertActivationState(true);
        _assertStrategyResiduals(strategy);
    }

    /**
     * @notice Exercises the liquid instant route and reconciles its fixed penalty split
     * @param strategy Active V3 strategy candidate
     * @param burnWallet Canonical penalty recipient
     */
    function _exerciseStrategyInstant(DustLockTransferStrategy strategy, address burnWallet) internal {
        (uint256 expectedPenalty, uint256 expectedNet) = ClaimReformModel.instantClaim(STRATEGY_INSTANT_GROSS);
        (uint256 previewPenalty, uint256 previewNet) = strategy.previewClaim(STRATEGY_INSTANT_GROSS, 0, 0);
        assertEq(previewPenalty, expectedPenalty);
        assertEq(previewNet, expectedNet);
        assertGt(expectedPenalty, 0);
        assertGt(expectedNet, 0);
        assertEq(expectedPenalty + expectedNet, STRATEGY_INSTANT_GROSS);

        StrategyRouteBaseline memory baseline = _captureStrategyRouteBaseline(burnWallet);

        vm.prank(DUST_REWARDS_CONTROLLER);
        assertTrue(strategy.performTransfer(STRATEGY_TEST_USER, DUST, STRATEGY_INSTANT_GROSS, 0, 0));

        assertEq(baseline.vaultBalance - IERC20(DUST).balanceOf(DUST_VAULT), STRATEGY_INSTANT_GROSS);
        assertEq(IERC20(DUST).balanceOf(STRATEGY_TEST_USER) - baseline.recipientBalance, expectedNet);
        assertEq(IERC20(DUST).balanceOf(burnWallet) - baseline.burnWalletBalance, expectedPenalty);
        assertEq(IERC20(DUST).balanceOf(DUST_LOCK), baseline.dustLockBalance);
        assertEq(dustLock.supply(), baseline.lockedSupply);
        assertEq(dustLock.permanentLockBalance(), baseline.permanentLockBalance);
        assertEq(IERC20(DUST).totalSupply(), baseline.totalSupply);
        _assertStrategyResiduals(strategy);
    }

    /**
     * @notice Exercises a new timed lock route against independently modeled weekly commitment rounding
     * @param strategy Active V3 strategy candidate
     * @param burnWallet Canonical penalty recipient
     * @return tokenId New timed veNFT used by the existing-timed subroute
     */
    function _exerciseStrategyNewTimed(DustLockTransferStrategy strategy, address burnWallet)
        internal
        returns (uint256 tokenId)
    {
        uint256 commitment = ClaimReformModel.realizedCommitment(block.timestamp, STRATEGY_TIMED_DURATION);
        (uint256 expectedPenalty, uint256 expectedNet) =
            ClaimReformModel.timedClaim(STRATEGY_NEW_TIMED_GROSS, commitment);
        (uint256 previewPenalty, uint256 previewNet) =
            strategy.previewClaim(STRATEGY_NEW_TIMED_GROSS, STRATEGY_TIMED_DURATION, 0);
        assertEq(previewPenalty, expectedPenalty);
        assertEq(previewNet, expectedNet);
        assertGt(commitment, 28 days);
        assertLe(commitment, MAXTIME);
        assertGt(expectedPenalty, 0);
        assertGt(expectedNet, 0);
        assertEq(expectedPenalty + expectedNet, STRATEGY_NEW_TIMED_GROSS);

        StrategyRouteBaseline memory baseline = _captureStrategyRouteBaseline(burnWallet);

        vm.prank(DUST_REWARDS_CONTROLLER);
        assertTrue(
            strategy.performTransfer(STRATEGY_TEST_USER, DUST, STRATEGY_NEW_TIMED_GROSS, STRATEGY_TIMED_DURATION, 0)
        );

        tokenId = dustLock.tokenId();
        IDustLock.LockedBalance memory lock = dustLock.locked(tokenId);
        assertEq(tokenId, baseline.tokenId + 1);
        assertEq(dustLock.ownerOf(tokenId), STRATEGY_TEST_USER);
        assertEq(uint256(lock.amount), expectedNet);
        assertEq(lock.end - block.timestamp, commitment);
        assertFalse(lock.isPermanent);
        assertEq(baseline.vaultBalance - IERC20(DUST).balanceOf(DUST_VAULT), STRATEGY_NEW_TIMED_GROSS);
        assertEq(IERC20(DUST).balanceOf(STRATEGY_TEST_USER), baseline.recipientBalance);
        assertEq(IERC20(DUST).balanceOf(burnWallet) - baseline.burnWalletBalance, expectedPenalty);
        assertEq(IERC20(DUST).balanceOf(DUST_LOCK) - baseline.dustLockBalance, expectedNet);
        assertEq(dustLock.supply() - baseline.lockedSupply, expectedNet);
        assertEq(dustLock.permanentLockBalance(), baseline.permanentLockBalance);
        assertEq(IERC20(DUST).totalSupply(), baseline.totalSupply);
        _assertStrategyResiduals(strategy);
    }

    /**
     * @notice Exercises the existing timed-lock route and reconciles the remaining commitment quote
     * @param strategy Active V3 strategy candidate
     * @param burnWallet Canonical penalty recipient
     * @param tokenId Existing timed veNFT owned by the route recipient
     */
    function _exerciseStrategyExistingTimed(DustLockTransferStrategy strategy, address burnWallet, uint256 tokenId)
        internal
    {
        IDustLock.LockedBalance memory lockBefore = dustLock.locked(tokenId);
        uint256 remaining = lockBefore.end - block.timestamp;
        // The fresh 180-day lock always prices at its actual remaining commitment (no clamp, no grace).
        uint256 commitment = remaining;
        (uint256 expectedPenalty, uint256 expectedNet) =
            ClaimReformModel.timedClaim(STRATEGY_EXISTING_TIMED_GROSS, commitment);
        (uint256 previewPenalty, uint256 previewNet) = strategy.previewClaim(STRATEGY_EXISTING_TIMED_GROSS, 0, tokenId);
        assertEq(previewPenalty, expectedPenalty);
        assertEq(previewNet, expectedNet);
        assertGt(expectedPenalty, 0);
        assertGt(expectedNet, 0);
        assertEq(expectedPenalty + expectedNet, STRATEGY_EXISTING_TIMED_GROSS);

        StrategyRouteBaseline memory baseline = _captureStrategyRouteBaseline(burnWallet);

        vm.prank(DUST_REWARDS_CONTROLLER);
        assertTrue(strategy.performTransfer(STRATEGY_TEST_USER, DUST, STRATEGY_EXISTING_TIMED_GROSS, 0, tokenId));

        IDustLock.LockedBalance memory lockAfter = dustLock.locked(tokenId);
        assertEq(dustLock.tokenId(), baseline.tokenId);
        assertEq(dustLock.ownerOf(tokenId), STRATEGY_TEST_USER);
        assertEq(uint256(lockAfter.amount), uint256(lockBefore.amount) + expectedNet);
        assertEq(lockAfter.end, lockBefore.end);
        assertFalse(lockAfter.isPermanent);
        assertEq(baseline.vaultBalance - IERC20(DUST).balanceOf(DUST_VAULT), STRATEGY_EXISTING_TIMED_GROSS);
        assertEq(IERC20(DUST).balanceOf(STRATEGY_TEST_USER), baseline.recipientBalance);
        assertEq(IERC20(DUST).balanceOf(burnWallet) - baseline.burnWalletBalance, expectedPenalty);
        assertEq(IERC20(DUST).balanceOf(DUST_LOCK) - baseline.dustLockBalance, expectedNet);
        assertEq(dustLock.supply() - baseline.lockedSupply, expectedNet);
        assertEq(dustLock.permanentLockBalance(), baseline.permanentLockBalance);
        assertEq(IERC20(DUST).totalSupply(), baseline.totalSupply);
        _assertStrategyResiduals(strategy);
    }

    /**
     * @notice Exercises a new permanent-lock route with zero penalty
     * @param strategy Active V3 strategy candidate
     * @param burnWallet Canonical penalty recipient
     * @return tokenId New permanent veNFT used by the existing-permanent subroute
     */
    function _exerciseStrategyNewPermanent(DustLockTransferStrategy strategy, address burnWallet)
        internal
        returns (uint256 tokenId)
    {
        (uint256 previewPenalty, uint256 previewNet) =
            strategy.previewClaim(STRATEGY_NEW_PERMANENT_GROSS, type(uint256).max, 0);
        assertEq(previewPenalty, 0);
        assertEq(previewNet, STRATEGY_NEW_PERMANENT_GROSS);
        assertGt(previewNet, 0);

        StrategyRouteBaseline memory baseline = _captureStrategyRouteBaseline(burnWallet);

        vm.prank(DUST_REWARDS_CONTROLLER);
        assertTrue(
            strategy.performTransfer(STRATEGY_TEST_USER, DUST, STRATEGY_NEW_PERMANENT_GROSS, type(uint256).max, 0)
        );

        tokenId = dustLock.tokenId();
        IDustLock.LockedBalance memory lock = dustLock.locked(tokenId);
        assertEq(tokenId, baseline.tokenId + 1);
        assertEq(dustLock.ownerOf(tokenId), STRATEGY_TEST_USER);
        assertEq(uint256(lock.amount), STRATEGY_NEW_PERMANENT_GROSS);
        assertEq(lock.end, 0);
        assertTrue(lock.isPermanent);
        assertEq(baseline.vaultBalance - IERC20(DUST).balanceOf(DUST_VAULT), STRATEGY_NEW_PERMANENT_GROSS);
        assertEq(IERC20(DUST).balanceOf(STRATEGY_TEST_USER), baseline.recipientBalance);
        assertEq(IERC20(DUST).balanceOf(burnWallet), baseline.burnWalletBalance);
        assertEq(IERC20(DUST).balanceOf(DUST_LOCK) - baseline.dustLockBalance, STRATEGY_NEW_PERMANENT_GROSS);
        assertEq(dustLock.supply() - baseline.lockedSupply, STRATEGY_NEW_PERMANENT_GROSS);
        assertEq(dustLock.permanentLockBalance() - baseline.permanentLockBalance, STRATEGY_NEW_PERMANENT_GROSS);
        assertEq(IERC20(DUST).totalSupply(), baseline.totalSupply);
        _assertStrategyResiduals(strategy);
    }

    /**
     * @notice Exercises the existing permanent-lock route with zero penalty
     * @param strategy Active V3 strategy candidate
     * @param burnWallet Canonical penalty recipient
     * @param tokenId Existing permanent veNFT owned by the route recipient
     */
    function _exerciseStrategyExistingPermanent(DustLockTransferStrategy strategy, address burnWallet, uint256 tokenId)
        internal
    {
        IDustLock.LockedBalance memory lockBefore = dustLock.locked(tokenId);
        (uint256 previewPenalty, uint256 previewNet) =
            strategy.previewClaim(STRATEGY_EXISTING_PERMANENT_GROSS, 0, tokenId);
        assertEq(previewPenalty, 0);
        assertEq(previewNet, STRATEGY_EXISTING_PERMANENT_GROSS);
        assertTrue(lockBefore.isPermanent);

        StrategyRouteBaseline memory baseline = _captureStrategyRouteBaseline(burnWallet);

        vm.prank(DUST_REWARDS_CONTROLLER);
        assertTrue(strategy.performTransfer(STRATEGY_TEST_USER, DUST, STRATEGY_EXISTING_PERMANENT_GROSS, 0, tokenId));

        IDustLock.LockedBalance memory lockAfter = dustLock.locked(tokenId);
        assertEq(dustLock.tokenId(), baseline.tokenId);
        assertEq(dustLock.ownerOf(tokenId), STRATEGY_TEST_USER);
        assertEq(uint256(lockAfter.amount), uint256(lockBefore.amount) + STRATEGY_EXISTING_PERMANENT_GROSS);
        assertEq(lockAfter.end, 0);
        assertTrue(lockAfter.isPermanent);
        assertEq(baseline.vaultBalance - IERC20(DUST).balanceOf(DUST_VAULT), STRATEGY_EXISTING_PERMANENT_GROSS);
        assertEq(IERC20(DUST).balanceOf(STRATEGY_TEST_USER), baseline.recipientBalance);
        assertEq(IERC20(DUST).balanceOf(burnWallet), baseline.burnWalletBalance);
        assertEq(IERC20(DUST).balanceOf(DUST_LOCK) - baseline.dustLockBalance, STRATEGY_EXISTING_PERMANENT_GROSS);
        assertEq(dustLock.supply() - baseline.lockedSupply, STRATEGY_EXISTING_PERMANENT_GROSS);
        assertEq(dustLock.permanentLockBalance() - baseline.permanentLockBalance, STRATEGY_EXISTING_PERMANENT_GROSS);
        assertEq(IERC20(DUST).totalSupply(), baseline.totalSupply);
        _assertStrategyResiduals(strategy);
    }

    /**
     * @notice Executes the exact guarded reverse proxy order while V3 remains configured
     * @param strategy Configured V3 strategy candidate
     */
    function _rollbackForkCoreCandidates(DustLockTransferStrategy strategy) internal {
        strategy.assertActivationState(true);

        vm.startPrank(GOVERNANCE_TIMELOCK);
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(payable(DUST_LOCK)), DUST_LOCK_PREDECESSOR_IMPLEMENTATION);
        proxyAdmin.upgrade(
            ITransparentUpgradeableProxy(payable(REVENUE_REWARD)), REVENUE_REWARD_PREDECESSOR_IMPLEMENTATION
        );
        vm.stopPrank();

        assertEq(
            proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(payable(DUST_LOCK))),
            DUST_LOCK_PREDECESSOR_IMPLEMENTATION
        );
        assertEq(
            proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(payable(REVENUE_REWARD))),
            REVENUE_REWARD_PREDECESSOR_IMPLEMENTATION
        );
        strategy.assertActivationState(false);
        vm.expectRevert(IDustLockTransferStrategy.InvalidActivationState.selector);
        strategy.assertActivationState(true);
    }

    /**
     * @notice Restores the original controller mapping and fresh-candidate allowance after guarded rollback
     * @param controller Canonical forked DustRewardsController
     * @param emissionManager Forked controller authority
     * @param originalStrategy Canonical V2 strategy
     * @param strategy Fresh V3 strategy candidate
     */
    function _restoreForkStrategyConfiguration(
        IDustRewardsController controller,
        address emissionManager,
        address originalStrategy,
        DustLockTransferStrategy strategy
    ) internal {
        vm.prank(emissionManager);
        controller.setTransferStrategy(DUST, IDustTransferStrategy(originalStrategy));
        vm.prank(DUST_VAULT);
        assertTrue(IERC20(DUST).approve(address(strategy), 0));

        assertEq(controller.getTransferStrategy(DUST), originalStrategy);
        assertEq(IERC20(DUST).allowance(DUST_VAULT, address(strategy)), 0);
        vm.expectRevert(IDustLockTransferStrategy.InvalidActivationState.selector);
        strategy.assertActivationState(false);
    }

    function _assertFollowingEpochNotifyUnavailable() internal {
        (bool success, bytes memory returndata) =
            REVENUE_REWARD.call(abi.encodeCall(IRevenueReward.notifyRewardAmountForFollowingEpoch, (address(0), 1)));

        assertFalse(success);
        assertEq(returndata.length, 0);
    }

    /**
     * @notice Captures named route state before temporary fork funding and strategy actions
     * @param burnWallet Canonical penalty recipient
     * @return baseline Named state expected after local snapshot restoration
     */
    function _captureStrategyRouteBaseline(address burnWallet)
        internal
        view
        returns (StrategyRouteBaseline memory baseline)
    {
        baseline.burnWalletBalance = IERC20(DUST).balanceOf(burnWallet);
        baseline.dustLockBalance = IERC20(DUST).balanceOf(DUST_LOCK);
        baseline.lockedSupply = dustLock.supply();
        baseline.permanentLockBalance = dustLock.permanentLockBalance();
        baseline.recipientBalance = IERC20(DUST).balanceOf(STRATEGY_TEST_USER);
        baseline.tokenId = dustLock.tokenId();
        baseline.totalSupply = IERC20(DUST).totalSupply();
        baseline.vaultBalance = IERC20(DUST).balanceOf(DUST_VAULT);
    }

    /**
     * @notice Proves the local strategy-route snapshot restored every named asset and DustLock value
     * @param baseline Expected named fork state
     * @param burnWallet Canonical penalty recipient
     */
    function _assertStrategyRouteBaseline(StrategyRouteBaseline memory baseline, address burnWallet) internal view {
        assertEq(IERC20(DUST).balanceOf(burnWallet), baseline.burnWalletBalance);
        assertEq(IERC20(DUST).balanceOf(DUST_LOCK), baseline.dustLockBalance);
        assertEq(dustLock.supply(), baseline.lockedSupply);
        assertEq(dustLock.permanentLockBalance(), baseline.permanentLockBalance);
        assertEq(IERC20(DUST).balanceOf(STRATEGY_TEST_USER), baseline.recipientBalance);
        assertEq(dustLock.tokenId(), baseline.tokenId);
        assertEq(IERC20(DUST).totalSupply(), baseline.totalSupply);
        assertEq(IERC20(DUST).balanceOf(DUST_VAULT), baseline.vaultBalance);
    }

    /**
     * @notice Proves no DUST or DustLock allowance remains inside V3 after a completed or reverted route
     * @param strategy V3 strategy candidate
     */
    function _assertStrategyResiduals(DustLockTransferStrategy strategy) internal view {
        assertEq(IERC20(DUST).balanceOf(address(strategy)), 0);
        assertEq(IERC20(DUST).allowance(address(strategy), DUST_LOCK), 0);
        assertEq(IERC20(DUST).allowance(DUST_VAULT, address(strategy)), type(uint256).max);
    }

    function _assertClaimReformQuoteUnavailable() internal view {
        (bool success, bytes memory returndata) =
            DUST_LOCK.staticcall(abi.encodeCall(IDustLock.earlyWithdrawPenaltyAmount, (SAMPLE_ACTIVE_TOKEN_ID)));

        assertFalse(success);
        assertEq(returndata.length, 0);
    }

    function _snapshotStorage(address target, uint256 slotCount) internal view returns (bytes32[] memory snapshot) {
        snapshot = new bytes32[](slotCount);
        for (uint256 slot; slot < slotCount; ++slot) {
            snapshot[slot] = vm.load(target, bytes32(slot));
        }
    }

    function _assertStorageEquals(address target, bytes32[] memory expected) internal view {
        for (uint256 slot; slot < expected.length; ++slot) {
            assertEq(vm.load(target, bytes32(slot)), expected[slot]);
        }
    }

    /**
     * @notice Reads every critical DustLock storage surface through the currently active implementation
     * @return state Named critical state for cross-implementation equality and canonical-slot pinning
     */
    function _captureDustLockCriticalState() internal view returns (DustLockCriticalState memory state) {
        IDustLock.LockedBalance memory sampledLock = dustLock.locked(SAMPLE_ACTIVE_TOKEN_ID);
        address sampledOwner = dustLock.ownerOf(SAMPLE_ACTIVE_TOKEN_ID);
        uint256 sampledUserPointEpoch = dustLock.userPointEpoch(SAMPLE_ACTIVE_TOKEN_ID);

        state.canSplitSampledOwner = dustLock.canSplit(sampledOwner);
        state.earlyWithdrawPenalty = dustLock.earlyWithdrawPenalty();
        state.earlyWithdrawTreasury = dustLock.earlyWithdrawTreasury();
        state.epoch = dustLock.epoch();
        state.feeEnforcedOperatorCount = dustLock.feeEnforcedOperatorCount();
        state.forwarder = dustLock.forwarder();
        state.minLockAmount = dustLock.minLockAmount();
        state.pendingTeam = dustLock.pendingTeam();
        state.permanentLockBalance = dustLock.permanentLockBalance();
        state.revenueReward = address(dustLock.revenueReward());
        state.royaltyFeeBps = dustLock.royaltyFeeBps();
        state.royaltyReceiver = dustLock.royaltyReceiver();
        state.sampledApproved = dustLock.getApproved(SAMPLE_ACTIVE_TOKEN_ID);
        state.sampledGlobalPointHash = keccak256(abi.encode(dustLock.pointHistory(state.epoch)));
        state.sampledLockHash = keccak256(abi.encode(sampledLock));
        state.sampledOwner = sampledOwner;
        state.sampledOwnerBalance = dustLock.balanceOf(sampledOwner);
        state.sampledOwnerFirstTokenId = dustLock.ownerToNFTokenIdList(sampledOwner, 0);
        state.sampledSlopeChange = dustLock.slopeChanges(sampledLock.end);
        state.sampledTokenURI = DustLock(DUST_LOCK).tokenURI(SAMPLE_ACTIVE_TOKEN_ID);
        state.sampledUserPointEpoch = sampledUserPointEpoch;
        state.sampledUserPointHash =
            keccak256(abi.encode(dustLock.userPointHistory(SAMPLE_ACTIVE_TOKEN_ID, sampledUserPointEpoch)));
        state.sampledVotingPower = dustLock.balanceOfNFT(SAMPLE_ACTIVE_TOKEN_ID);
        state.supply = dustLock.supply();
        state.team = dustLock.team();
        state.token = dustLock.token();
        state.tokenId = dustLock.tokenId();
        state.totalVotingPower = dustLock.totalSupply();
        state.transferValidator = dustLock.transferValidator();
    }

    /**
     * @notice Reads every critical RevenueReward storage surface through the currently active implementation
     * @return state Named critical state for cross-implementation equality and canonical-slot pinning
     */
    function _captureRevenueRewardCriticalState() internal view returns (RevenueRewardCriticalState memory state) {
        address[] memory tokens = revenueReward.getRewardTokens();
        address[] memory selfRepayUsers = revenueReward.getUsersWithSelfRepayingLoan(0, type(uint64).max);
        uint256 currentEpochStart = block.timestamp - (block.timestamp % 1 weeks);
        bytes memory ledger;
        for (uint256 i = 0; i < tokens.length; ++i) {
            ledger = abi.encodePacked(
                ledger,
                abi.encode(
                    tokens[i],
                    revenueReward.isRewardToken(tokens[i]),
                    revenueReward.totalRewardsPerToken(tokens[i]),
                    revenueReward.tokenRewardsPerEpoch(tokens[i], currentEpochStart),
                    revenueReward.tokenRewardsPerEpoch(tokens[i], currentEpochStart + 1 weeks)
                )
            );
        }

        state.dustLock = address(revenueReward.dustLock());
        state.rewardDistributor = revenueReward.rewardDistributor();
        state.rewardLedgerHash = keccak256(ledger);
        state.rewardTokensHash = keccak256(abi.encode(tokens));
        state.rewardTokensLength = revenueReward.rewardTokensLength();
        state.sampledLastEarnTime = revenueReward.lastEarnTime(tokens[0], SAMPLE_ACTIVE_TOKEN_ID);
        state.sampledMintTime = revenueReward.tokenMintTime(SAMPLE_ACTIVE_TOKEN_ID);
        state.sampledRemainingAccScaled =
            revenueReward.tokenRewardsRemainingAccScaled(tokens[0], SAMPLE_ACTIVE_TOKEN_ID);
        state.sampledRewardReceiver = revenueReward.tokenRewardReceiver(SAMPLE_ACTIVE_TOKEN_ID);
        state.sampledUserTokensHash = selfRepayUsers.length == 0
            ? bytes32(0)
            : keccak256(abi.encode(revenueReward.getUserTokensWithSelfRepayingLoan(selfRepayUsers[0])));
        state.selfRepayUsersHash = keccak256(abi.encode(selfRepayUsers));
        state.userVaultFactory = address(revenueReward.userVaultFactory());
    }

    /**
     * @notice Proves two DustLock critical-state captures are identical field by field
     * @param expected Capture read through the predecessor implementation
     * @param actual Capture read through the currently active implementation
     */
    function _assertDustLockCriticalStateEq(DustLockCriticalState memory expected, DustLockCriticalState memory actual)
        internal
        pure
    {
        assertEq(actual.canSplitSampledOwner, expected.canSplitSampledOwner);
        assertEq(actual.earlyWithdrawPenalty, expected.earlyWithdrawPenalty);
        assertEq(actual.earlyWithdrawTreasury, expected.earlyWithdrawTreasury);
        assertEq(actual.epoch, expected.epoch);
        assertEq(actual.feeEnforcedOperatorCount, expected.feeEnforcedOperatorCount);
        assertEq(actual.forwarder, expected.forwarder);
        assertEq(actual.minLockAmount, expected.minLockAmount);
        assertEq(actual.pendingTeam, expected.pendingTeam);
        assertEq(actual.permanentLockBalance, expected.permanentLockBalance);
        assertEq(actual.revenueReward, expected.revenueReward);
        assertEq(actual.royaltyFeeBps, expected.royaltyFeeBps);
        assertEq(actual.royaltyReceiver, expected.royaltyReceiver);
        assertEq(actual.sampledApproved, expected.sampledApproved);
        assertEq(actual.sampledGlobalPointHash, expected.sampledGlobalPointHash);
        assertEq(actual.sampledLockHash, expected.sampledLockHash);
        assertEq(actual.sampledOwner, expected.sampledOwner);
        assertEq(actual.sampledOwnerBalance, expected.sampledOwnerBalance);
        assertEq(actual.sampledOwnerFirstTokenId, expected.sampledOwnerFirstTokenId);
        assertEq(actual.sampledSlopeChange, expected.sampledSlopeChange);
        assertEq(actual.sampledTokenURI, expected.sampledTokenURI);
        assertEq(actual.sampledUserPointEpoch, expected.sampledUserPointEpoch);
        assertEq(actual.sampledUserPointHash, expected.sampledUserPointHash);
        assertEq(actual.sampledVotingPower, expected.sampledVotingPower);
        assertEq(actual.supply, expected.supply);
        assertEq(actual.team, expected.team);
        assertEq(actual.token, expected.token);
        assertEq(actual.tokenId, expected.tokenId);
        assertEq(actual.totalVotingPower, expected.totalVotingPower);
        assertEq(actual.transferValidator, expected.transferValidator);
    }

    /**
     * @notice Proves two RevenueReward critical-state captures are identical field by field
     * @param expected Capture read through the predecessor implementation
     * @param actual Capture read through the currently active implementation
     */
    function _assertRevenueRewardCriticalStateEq(
        RevenueRewardCriticalState memory expected,
        RevenueRewardCriticalState memory actual
    ) internal pure {
        assertEq(actual.dustLock, expected.dustLock);
        assertEq(actual.rewardDistributor, expected.rewardDistributor);
        assertEq(actual.rewardLedgerHash, expected.rewardLedgerHash);
        assertEq(actual.rewardTokensHash, expected.rewardTokensHash);
        assertEq(actual.rewardTokensLength, expected.rewardTokensLength);
        assertEq(actual.sampledLastEarnTime, expected.sampledLastEarnTime);
        assertEq(actual.sampledMintTime, expected.sampledMintTime);
        assertEq(actual.sampledRemainingAccScaled, expected.sampledRemainingAccScaled);
        assertEq(actual.sampledRewardReceiver, expected.sampledRewardReceiver);
        assertEq(actual.sampledUserTokensHash, expected.sampledUserTokensHash);
        assertEq(actual.selfRepayUsersHash, expected.selfRepayUsersHash);
        assertEq(actual.userVaultFactory, expected.userVaultFactory);
    }

    /**
     * @notice Proves the active DustLock implementation reads each critical variable from its canonical slot
     * @param state Critical state captured through the same active implementation
     */
    function _assertDustLockSlotPinning(DustLockCriticalState memory state) internal view {
        assertEq(state.forwarder, _loadAddress(DUST_LOCK, bytes32(uint256(151))));
        assertEq(state.token, _loadAddress(DUST_LOCK, bytes32(uint256(152))));
        assertEq(state.team, _loadAddress(DUST_LOCK, bytes32(uint256(153))));
        assertEq(state.pendingTeam, _loadAddress(DUST_LOCK, bytes32(uint256(154))));
        assertEq(state.tokenId, uint256(vm.load(DUST_LOCK, bytes32(uint256(157)))));
        assertEq(state.epoch, uint256(vm.load(DUST_LOCK, bytes32(uint256(166)))));
        assertEq(state.supply, uint256(vm.load(DUST_LOCK, bytes32(uint256(167)))));
        assertEq(state.permanentLockBalance, uint256(vm.load(DUST_LOCK, bytes32(uint256(173)))));
        assertEq(state.earlyWithdrawPenalty, uint256(vm.load(DUST_LOCK, bytes32(uint256(174)))));
        assertEq(state.earlyWithdrawTreasury, _loadAddress(DUST_LOCK, bytes32(uint256(175))));
        assertEq(state.minLockAmount, uint256(vm.load(DUST_LOCK, bytes32(uint256(176)))));
        assertEq(state.revenueReward, _loadAddress(DUST_LOCK, bytes32(uint256(177))));
        assertEq(state.transferValidator, _loadAddress(DUST_LOCK, bytes32(uint256(178))));
        uint256 royaltyWord = uint256(vm.load(DUST_LOCK, bytes32(uint256(179))));
        assertEq(state.royaltyReceiver, address(uint160(royaltyWord)));
        assertEq(state.royaltyFeeBps, uint96(royaltyWord >> 160));
        assertEq(state.feeEnforcedOperatorCount, uint256(vm.load(DUST_LOCK, bytes32(uint256(182)))));

        assertEq(state.sampledOwner, _loadAddress(DUST_LOCK, _mappingSlot(SAMPLE_ACTIVE_TOKEN_ID, 159)));
        assertEq(state.sampledOwnerBalance, uint256(vm.load(DUST_LOCK, _mappingSlot(state.sampledOwner, 160))));
        assertEq(state.sampledApproved, _loadAddress(DUST_LOCK, _mappingSlot(SAMPLE_ACTIVE_TOKEN_ID, 161)));
        assertEq(state.sampledUserPointEpoch, uint256(vm.load(DUST_LOCK, _mappingSlot(SAMPLE_ACTIVE_TOKEN_ID, 170))));

        IDustLock.LockedBalance memory sampledLock = dustLock.locked(SAMPLE_ACTIVE_TOKEN_ID);
        bytes32 lockBase = _mappingSlot(SAMPLE_ACTIVE_TOKEN_ID, 168);
        assertEq(sampledLock.amount, int256(uint256(vm.load(DUST_LOCK, lockBase))));
        assertEq(sampledLock.effectiveStart, uint256(vm.load(DUST_LOCK, bytes32(uint256(lockBase) + 1))));
        assertEq(sampledLock.end, uint256(vm.load(DUST_LOCK, bytes32(uint256(lockBase) + 2))));
        assertEq(sampledLock.isPermanent, vm.load(DUST_LOCK, bytes32(uint256(lockBase) + 3)) != bytes32(0));
        assertEq(state.sampledSlopeChange, int256(uint256(vm.load(DUST_LOCK, _mappingSlot(sampledLock.end, 171)))));

        uint256 sampledOwnerIndex = uint256(vm.load(DUST_LOCK, _mappingSlot(SAMPLE_ACTIVE_TOKEN_ID, 165)));
        assertEq(dustLock.ownerToNFTokenIdList(state.sampledOwner, sampledOwnerIndex), SAMPLE_ACTIVE_TOKEN_ID);
    }

    /**
     * @notice Proves the active RevenueReward implementation reads each critical variable from its canonical slot
     * @param state Critical state captured through the same active implementation
     */
    function _assertRevenueRewardSlotPinning(RevenueRewardCriticalState memory state) internal view {
        assertEq(state.dustLock, _loadAddress(REVENUE_REWARD, bytes32(uint256(151))));
        assertEq(state.userVaultFactory, _loadAddress(REVENUE_REWARD, bytes32(uint256(152))));
        assertEq(state.rewardDistributor, _loadAddress(REVENUE_REWARD, bytes32(uint256(153))));
        assertEq(state.rewardTokensLength, uint256(vm.load(REVENUE_REWARD, bytes32(uint256(155)))));

        address sampledToken = revenueReward.rewardTokens(0);
        uint256 currentEpochStart = block.timestamp - (block.timestamp % 1 weeks);
        assertEq(sampledToken, _loadAddress(REVENUE_REWARD, _arrayDataSlot(155)));
        assertEq(uint256(vm.load(REVENUE_REWARD, _mappingSlot(sampledToken, 154))), 1);
        assertEq(
            revenueReward.totalRewardsPerToken(sampledToken),
            uint256(vm.load(REVENUE_REWARD, _mappingSlot(sampledToken, 156)))
        );
        assertEq(
            revenueReward.tokenRewardsPerEpoch(sampledToken, currentEpochStart),
            uint256(vm.load(REVENUE_REWARD, _mappingSlot(currentEpochStart, _mappingSlot(sampledToken, 157))))
        );
        assertEq(
            state.sampledLastEarnTime,
            uint256(vm.load(REVENUE_REWARD, _mappingSlot(SAMPLE_ACTIVE_TOKEN_ID, _mappingSlot(sampledToken, 158))))
        );
        assertEq(
            state.sampledRemainingAccScaled,
            uint256(vm.load(REVENUE_REWARD, _mappingSlot(SAMPLE_ACTIVE_TOKEN_ID, _mappingSlot(sampledToken, 159))))
        );
        assertEq(state.sampledMintTime, uint256(vm.load(REVENUE_REWARD, _mappingSlot(SAMPLE_ACTIVE_TOKEN_ID, 160))));
        assertEq(state.sampledRewardReceiver, _loadAddress(REVENUE_REWARD, _mappingSlot(SAMPLE_ACTIVE_TOKEN_ID, 161)));

        uint256 selfRepayUserCount = uint256(vm.load(REVENUE_REWARD, bytes32(uint256(163))));
        address[] memory selfRepayUsers = revenueReward.getUsersWithSelfRepayingLoan(0, type(uint64).max);
        assertEq(selfRepayUsers.length, selfRepayUserCount);
        if (selfRepayUserCount > 0) {
            assertEq(selfRepayUsers[0], _loadAddress(REVENUE_REWARD, _arrayDataSlot(163)));
        }
    }

    /**
     * @notice Proves the active implementations reproduce the expected critical state from canonical slots
     * @param expectedDustLock DustLock baseline captured through the predecessor implementation
     * @param expectedRevenueReward RevenueReward baseline captured through the predecessor implementation
     */
    function _assertCoreCriticalStateUnchangedAndPinned(
        DustLockCriticalState memory expectedDustLock,
        RevenueRewardCriticalState memory expectedRevenueReward
    ) internal view {
        _assertDustLockCriticalStateEq(expectedDustLock, _captureDustLockCriticalState());
        _assertRevenueRewardCriticalStateEq(expectedRevenueReward, _captureRevenueRewardCriticalState());
        _assertDustLockSlotPinning(_captureDustLockCriticalState());
        _assertRevenueRewardSlotPinning(_captureRevenueRewardCriticalState());
    }

    /**
     * @notice Loads the address stored in the low 160 bits of a storage slot
     * @param target Contract whose storage is read
     * @param slot Storage slot to read
     * @return Stored address value
     */
    function _loadAddress(address target, bytes32 slot) private view returns (address) {
        return address(uint160(uint256(vm.load(target, slot))));
    }

    /**
     * @notice Computes the value slot of an address-keyed mapping entry
     * @param key Mapping key
     * @param slot Declaration slot of the mapping
     * @return Storage slot holding the value
     */
    function _mappingSlot(address key, uint256 slot) private pure returns (bytes32) {
        return keccak256(abi.encode(key, slot));
    }

    /**
     * @notice Computes the value slot of a uint256-keyed mapping entry
     * @param key Mapping key
     * @param slot Declaration slot of the mapping
     * @return Storage slot holding the value
     */
    function _mappingSlot(uint256 key, uint256 slot) private pure returns (bytes32) {
        return keccak256(abi.encode(key, slot));
    }

    /**
     * @notice Computes the value slot of a nested mapping entry from its outer value slot
     * @param key Inner mapping key
     * @param baseSlot Outer mapping value slot
     * @return Storage slot holding the value
     */
    function _mappingSlot(uint256 key, bytes32 baseSlot) private pure returns (bytes32) {
        return keccak256(abi.encode(key, baseSlot));
    }

    /**
     * @notice Computes the first data slot of a dynamic storage array
     * @param slot Declaration slot of the array
     * @return First element slot
     */
    function _arrayDataSlot(uint256 slot) private pure returns (bytes32) {
        return keccak256(abi.encode(slot));
    }
}
