// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IScaledBalanceToken} from "@aave/core-v3/contracts/interfaces/IScaledBalanceToken.sol";
import {IEACAggregatorProxy} from "@aave-v3-periphery/contracts/misc/interfaces/IEACAggregatorProxy.sol";
import {ITransferStrategyBase} from "@aave-v3-periphery/contracts/rewards/interfaces/ITransferStrategyBase.sol";
import {IRewardsController} from "@aave-v3-periphery/contracts/rewards/interfaces/IRewardsController.sol";
import {RewardsDataTypes} from "@aave-v3-periphery/contracts/rewards/libraries/RewardsDataTypes.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IDustLock} from "../../../src/interfaces/IDustLock.sol";

import {ClaimReformModel} from "../_utils/ClaimReformModel.sol";

import {DustLockTransferStrategy} from "../../../src/emissions/DustLockTransferStrategy.sol";
import {DustRewardsController} from "../../../src/emissions/DustRewardsController.sol";
import {DustTransferStrategyBase} from "../../../src/emissions/DustTransferStrategyBase.sol";
import {BaseTestLocal} from "../../BaseTestLocal.sol";

contract ClaimReformScaledToken is ERC20, IScaledBalanceToken {
    uint256 internal constant INDEX = 1e27;

    constructor() ERC20("Claim Reform Asset", "CRA") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function scaledBalanceOf(address account) external view returns (uint256) {
        return balanceOf(account);
    }

    function getScaledUserBalanceAndSupply(address account) external view returns (uint256, uint256) {
        return (balanceOf(account), totalSupply());
    }

    function scaledTotalSupply() external view returns (uint256) {
        return totalSupply();
    }

    function getPreviousIndex(address) external pure returns (uint256) {
        return INDEX;
    }
}

contract ClaimReformPredecessorStrategy is DustTransferStrategyBase {
    constructor(address controller, address admin) DustTransferStrategyBase(controller, admin) {}

    function performTransfer(address, address, uint256, uint256, uint256)
        external
        view
        override
        onlyIncentivesController
        returns (bool)
    {
        return true;
    }
}

contract ClaimReformControllerE2ETest is BaseTestLocal {
    struct ExistingClaimCase {
        address rewardUser;
        address lockOwner;
        uint256 tokenId;
        uint256 accruedBefore;
        uint256 gross;
        bool isPermanent;
    }

    struct ExistingClaimSnapshot {
        IDustLock.LockedBalance lock;
        uint256 vaultBalance;
        uint256 burnWalletBalance;
        uint256 dustLockBalance;
        uint256 lockOwnerBalance;
        uint256 lockedSupply;
        uint256 permanentLockBalance;
        uint256 totalSupply;
    }

    DustRewardsController internal controller;
    DustLockTransferStrategy internal strategy;
    ClaimReformScaledToken internal asset;
    address internal emissionManager = address(0xe117);
    address internal dustVault = address(0xd057);

    function _setUp() internal override {
        controller = new DustRewardsController(emissionManager);
        controller.initialize(address(0x1234));
        asset = new ClaimReformScaledToken();
        asset.mint(user, 100 ether);
        asset.mint(user4, 100 ether);

        ClaimReformPredecessorStrategy predecessor = new ClaimReformPredecessorStrategy(address(controller), admin);
        RewardsDataTypes.RewardsConfigInput[] memory config = new RewardsDataTypes.RewardsConfigInput[](1);
        config[0].emissionPerSecond = 1 ether;
        config[0].distributionEnd = uint32(block.timestamp + 365 days);
        config[0].asset = address(asset);
        config[0].reward = address(DUST);
        config[0].transferStrategy = ITransferStrategyBase(address(predecessor));
        config[0].rewardOracle = IEACAggregatorProxy(address(0));
        vm.prank(emissionManager);
        controller.configureAssets(config);

        mintErc20Token(address(DUST), dustVault, TOKEN_1M);
        strategy = new DustLockTransferStrategy(address(controller), admin, dustVault, address(dustLock));
        vm.prank(dustVault);
        DUST.approve(address(strategy), type(uint256).max);
        dustLock.setEarlyWithdrawTreasury(user3);
    }

    /**
     * @notice Accrues gross DUST under the predecessor and activates the V3 transfer strategy
     * @return assets Reward-controller asset list used for the subsequent claim
     * @return gross Gross DUST accrued before the strategy cutover
     */
    function _accrueAndActivate() internal returns (address[] memory assets, uint256 gross) {
        assets = new address[](1);
        assets[0] = address(asset);

        skipAndRoll(10);
        vm.prank(address(asset));
        controller.handleAction(user, asset.totalSupply(), asset.balanceOf(user));
        gross = controller.getUserRewards(assets, user, address(DUST));
        assertGt(gross, 0);
        assertNotEq(controller.getTransferStrategy(address(DUST)), address(strategy));

        vm.prank(emissionManager);
        controller.setTransferStrategy(address(DUST), strategy);
        strategy.assertActivationState(true);
    }

    /**
     * @notice Accrues the same nonzero reward entitlement for two independent users before activating V3
     * @return assets Reward-controller asset list used for the subsequent claims
     * @return userGross Exact gross reward entitlement accrued by `user`
     * @return user4Gross Exact gross reward entitlement accrued by `user4`
     */
    function _accrueTwoUsersAndActivate()
        internal
        returns (address[] memory assets, uint256 userGross, uint256 user4Gross)
    {
        assets = new address[](1);
        assets[0] = address(asset);

        skipAndRoll(10);
        vm.prank(address(asset));
        controller.handleAction(user, asset.totalSupply(), asset.balanceOf(user));
        vm.prank(address(asset));
        controller.handleAction(user4, asset.totalSupply(), asset.balanceOf(user4));

        userGross = controller.getUserRewards(assets, user, address(DUST));
        user4Gross = controller.getUserRewards(assets, user4, address(DUST));
        assertEq(userGross, 5 ether);
        assertEq(user4Gross, 5 ether);
        assertNotEq(controller.getTransferStrategy(address(DUST)), address(strategy));

        vm.prank(emissionManager);
        controller.setTransferStrategy(address(DUST), strategy);
        strategy.assertActivationState(true);
    }

    /**
     * @notice Claims into an existing lock and reconciles controller, strategy, token, and lock accounting
     * @param assets Reward-controller asset list
     * @param claimCase Exact user, destination, and partial-claim expectation
     */
    function _claimExistingAndAssert(address[] memory assets, ExistingClaimCase memory claimCase) internal {
        assertGt(claimCase.accruedBefore, 0);
        assertGt(claimCase.gross, 0);
        assertLe(claimCase.gross, claimCase.accruedBefore);
        assertEq(controller.getUserRewards(assets, claimCase.rewardUser, address(DUST)), claimCase.accruedBefore);
        assertEq(dustLock.ownerOf(claimCase.tokenId), claimCase.lockOwner);

        IDustLock.LockedBalance memory beforeLock = dustLock.locked(claimCase.tokenId);
        assertEq(beforeLock.isPermanent, claimCase.isPermanent);

        uint256 penalty;
        uint256 net;
        if (claimCase.isPermanent) {
            net = claimCase.gross;
        } else {
            uint256 remaining = beforeLock.end - block.timestamp;
            (penalty, net) = ClaimReformModel.timedClaim(claimCase.gross, remaining);
        }
        (uint256 previewPenalty, uint256 previewNet) = strategy.previewClaim(claimCase.gross, 0, claimCase.tokenId);
        assertEq(previewPenalty, penalty);
        assertEq(previewNet, net);
        assertEq(penalty + net, claimCase.gross);
        if (claimCase.isPermanent) {
            assertEq(penalty, 0);
            assertEq(net, claimCase.gross);
        } else if (beforeLock.end - block.timestamp >= MAXTIME - 1 weeks) {
            assertEq(penalty, 0);
            assertEq(net, claimCase.gross);
        } else {
            assertGt(penalty, 0);
            assertGt(net, 0);
            assertLt(net, claimCase.gross);
        }

        ExistingClaimSnapshot memory beforeState = ExistingClaimSnapshot({
            lock: beforeLock,
            vaultBalance: DUST.balanceOf(dustVault),
            burnWalletBalance: DUST.balanceOf(user3),
            dustLockBalance: DUST.balanceOf(address(dustLock)),
            lockOwnerBalance: DUST.balanceOf(claimCase.lockOwner),
            lockedSupply: dustLock.supply(),
            permanentLockBalance: dustLock.permanentLockBalance(),
            totalSupply: DUST.totalSupply()
        });
        assertEq(DUST.balanceOf(address(strategy)), 0);
        assertEq(DUST.allowance(address(strategy), address(dustLock)), 0);
        assertEq(DUST.allowance(dustVault, address(strategy)), type(uint256).max);

        vm.expectEmit(true, true, true, true, address(dustLock));
        emit IDustLock.Deposit(
            address(strategy),
            claimCase.tokenId,
            IDustLock.DepositType.DEPOSIT_FOR_TYPE,
            net,
            beforeState.lock.end,
            block.timestamp
        );
        vm.expectEmit(true, true, true, true, address(controller));
        emit IRewardsController.RewardsClaimed(
            claimCase.rewardUser, address(DUST), claimCase.lockOwner, claimCase.rewardUser, claimCase.gross
        );
        vm.prank(claimCase.rewardUser);
        uint256 claimed =
            controller.claimRewards(assets, claimCase.gross, claimCase.lockOwner, address(DUST), 0, claimCase.tokenId);

        IDustLock.LockedBalance memory afterLock = dustLock.locked(claimCase.tokenId);
        assertEq(claimed, claimCase.gross);
        assertEq(
            controller.getUserRewards(assets, claimCase.rewardUser, address(DUST)),
            claimCase.accruedBefore - claimCase.gross
        );
        assertEq(beforeState.vaultBalance - DUST.balanceOf(dustVault), claimCase.gross);
        assertEq(DUST.balanceOf(user3) - beforeState.burnWalletBalance, penalty);
        assertEq(DUST.balanceOf(address(dustLock)) - beforeState.dustLockBalance, net);
        assertEq(DUST.balanceOf(claimCase.lockOwner), beforeState.lockOwnerBalance);
        assertEq(dustLock.supply() - beforeState.lockedSupply, net);
        assertEq(dustLock.permanentLockBalance() - beforeState.permanentLockBalance, claimCase.isPermanent ? net : 0);
        assertEq(DUST.totalSupply(), beforeState.totalSupply);
        assertEq(uint256(afterLock.amount), uint256(beforeState.lock.amount) + net);
        assertEq(afterLock.end, beforeState.lock.end);
        assertEq(afterLock.isPermanent, claimCase.isPermanent);
        if (claimCase.isPermanent) {
            assertEq(afterLock.effectiveStart, beforeState.lock.effectiveStart);
        } else {
            uint256 expectedEffectiveStart =
                (uint256(beforeState.lock.amount) * beforeState.lock.effectiveStart + net * block.timestamp)
                    / (uint256(beforeState.lock.amount) + net);
            assertEq(afterLock.effectiveStart, expectedEffectiveStart);
        }
        assertEq(DUST.balanceOf(address(strategy)), 0);
        assertEq(DUST.allowance(address(strategy), address(dustLock)), 0);
        assertEq(DUST.allowance(dustVault, address(strategy)), type(uint256).max);
    }

    function testPreCutoverAccrualUsesV3EconomicsWhenClaimedAfterCutover() public {
        (address[] memory assets, uint256 gross) = _accrueAndActivate();

        (uint256 expectedPenalty, uint256 expectedNet) = strategy.previewClaim(gross, 0, 0);
        uint256 receiverBefore = DUST.balanceOf(user2);
        uint256 treasuryBefore = DUST.balanceOf(user3);
        uint256 vaultBefore = DUST.balanceOf(dustVault);
        uint256 supplyBefore = DUST.totalSupply();

        uint256 claimed = controller.claimRewards(assets, type(uint256).max, user2, address(DUST), 0, 0);

        assertEq(claimed, gross);
        assertEq(DUST.balanceOf(user2) - receiverBefore, expectedNet);
        assertEq(DUST.balanceOf(user3) - treasuryBefore, expectedPenalty);
        assertEq(vaultBefore - DUST.balanceOf(dustVault), gross);
        assertEq(DUST.totalSupply(), supplyBefore);
        assertEq(expectedNet + expectedPenalty, gross);
    }

    function testControllerTimedClaimReportsGrossAndLocksOnlyNet() public {
        (address[] memory assets, uint256 gross) = _accrueAndActivate();
        uint256 lockTime = MINTIME + WEEK;
        (uint256 expectedPenalty, uint256 expectedNet) = strategy.previewClaim(gross, lockTime, 0);
        uint256 vaultBefore = DUST.balanceOf(dustVault);
        uint256 treasuryBefore = DUST.balanceOf(user3);
        uint256 supplyBefore = DUST.totalSupply();

        vm.expectEmit(true, true, true, true, address(controller));
        emit IRewardsController.RewardsClaimed(user, address(DUST), user2, user, gross);
        uint256 claimed = controller.claimRewards(assets, type(uint256).max, user2, address(DUST), lockTime, 0);

        uint256 tokenId = dustLock.tokenId();
        assertEq(claimed, gross);
        assertEq(dustLock.ownerOf(tokenId), user2);
        assertEq(uint256(dustLock.locked(tokenId).amount), expectedNet);
        assertEq(vaultBefore - DUST.balanceOf(dustVault), gross);
        assertEq(DUST.balanceOf(user3) - treasuryBefore, expectedPenalty);
        assertEq(DUST.totalSupply(), supplyBefore);
        assertEq(expectedNet + expectedPenalty, gross);
    }

    function testControllerPermanentClaimReportsAndLocksGrossWithoutPenalty() public {
        (address[] memory assets, uint256 gross) = _accrueAndActivate();
        (uint256 expectedPenalty, uint256 expectedNet) = strategy.previewClaim(gross, type(uint256).max, 0);
        uint256 vaultBefore = DUST.balanceOf(dustVault);
        uint256 supplyBefore = DUST.totalSupply();

        vm.expectEmit(true, true, true, true, address(controller));
        emit IRewardsController.RewardsClaimed(user, address(DUST), user2, user, gross);
        uint256 claimed = controller.claimRewards(assets, type(uint256).max, user2, address(DUST), type(uint256).max, 0);

        IDustLock.LockedBalance memory lock = dustLock.locked(dustLock.tokenId());
        assertEq(claimed, gross);
        assertEq(expectedPenalty, 0);
        assertEq(expectedNet, gross);
        assertEq(uint256(lock.amount), gross);
        assertTrue(lock.isPermanent);
        assertEq(vaultBefore - DUST.balanceOf(dustVault), gross);
        assertEq(DUST.totalSupply(), supplyBefore);
    }

    function testControllerExistingLocksSupportIndependentPartialAndRepeatedClaims() public {
        (address[] memory assets, uint256 timedGross, uint256 permanentGross) = _accrueTwoUsersAndActivate();

        mintErc20Token(address(DUST), user2, TOKEN_1K);
        vm.startPrank(user2);
        DUST.approve(address(dustLock), TOKEN_1K);
        uint256 timedTokenId = dustLock.createLock(TOKEN_1K, MAXTIME);
        vm.stopPrank();

        mintErc20Token(address(DUST), user4, TOKEN_1K);
        vm.startPrank(user4);
        DUST.approve(address(dustLock), TOKEN_1K);
        uint256 permanentTokenId = dustLock.createLockPermanent(TOKEN_1K, MAXTIME);
        vm.stopPrank();

        uint256 timedFirstGross = timedGross / 3;
        uint256 permanentFirstGross = permanentGross / 4;
        assertGt(timedFirstGross, 0);
        assertGt(timedGross - timedFirstGross, 0);
        assertGt(permanentFirstGross, 0);
        assertGt(permanentGross - permanentFirstGross, 0);

        _claimExistingAndAssert(
            assets,
            ExistingClaimCase({
                rewardUser: user,
                lockOwner: user2,
                tokenId: timedTokenId,
                accruedBefore: timedGross,
                gross: timedFirstGross,
                isPermanent: false
            })
        );
        assertEq(controller.getUserRewards(assets, user4, address(DUST)), permanentGross);

        _claimExistingAndAssert(
            assets,
            ExistingClaimCase({
                rewardUser: user,
                lockOwner: user2,
                tokenId: timedTokenId,
                accruedBefore: timedGross - timedFirstGross,
                gross: timedGross - timedFirstGross,
                isPermanent: false
            })
        );
        assertEq(controller.getUserRewards(assets, user, address(DUST)), 0);
        assertEq(controller.getUserRewards(assets, user4, address(DUST)), permanentGross);

        _claimExistingAndAssert(
            assets,
            ExistingClaimCase({
                rewardUser: user4,
                lockOwner: user4,
                tokenId: permanentTokenId,
                accruedBefore: permanentGross,
                gross: permanentFirstGross,
                isPermanent: true
            })
        );
        assertEq(controller.getUserRewards(assets, user, address(DUST)), 0);

        _claimExistingAndAssert(
            assets,
            ExistingClaimCase({
                rewardUser: user4,
                lockOwner: user4,
                tokenId: permanentTokenId,
                accruedBefore: permanentGross - permanentFirstGross,
                gross: permanentGross - permanentFirstGross,
                isPermanent: true
            })
        );
        assertEq(controller.getUserRewards(assets, user, address(DUST)), 0);
        assertEq(controller.getUserRewards(assets, user4, address(DUST)), 0);
    }
}
