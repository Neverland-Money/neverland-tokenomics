// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IDustLock} from "../../../src/interfaces/IDustLock.sol";

import {ClaimReformModel} from "../_utils/ClaimReformModel.sol";

import {BaseTestLocal} from "../../BaseTestLocal.sol";

contract ClaimReformReentrantRewardToken is ERC20 {
    enum Action {
        None,
        Lock,
        Unlock
    }

    IDustLock private dustLock;
    uint256 private targetTokenId;
    Action private action;
    bool private armed;

    bool public reentryAttempted;
    bool public lastReentrySucceeded;

    constructor() ERC20("Claim Reform Reentrant Reward", "CRRR") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function armLock(IDustLock dustLock_, uint256 targetTokenId_) external {
        dustLock = dustLock_;
        targetTokenId = targetTokenId_;
        action = Action.Lock;
        armed = true;
    }

    function armUnlock(IDustLock dustLock_, uint256 targetTokenId_) external {
        dustLock = dustLock_;
        targetTokenId = targetTokenId_;
        action = Action.Unlock;
        armed = true;
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        super._afterTokenTransfer(from, to, amount);
        if (!armed || from == address(0) || amount == 0) return;

        armed = false;
        reentryAttempted = true;
        if (action == Action.Lock) {
            (lastReentrySucceeded,) = address(dustLock).call(abi.encodeCall(IDustLock.lockPermanent, (targetTokenId)));
        } else if (action == Action.Unlock) {
            (lastReentrySucceeded,) = address(dustLock).call(abi.encodeCall(IDustLock.unlockPermanent, (targetTokenId)));
        }
    }
}

contract ClaimReformReentrantPermanentReceiver {
    enum Action {
        Lock,
        Unlock
    }

    IDustLock private immutable dustLock;
    Action private immutable action;

    constructor(IDustLock dustLock_, Action action_) {
        dustLock = dustLock_;
        action = action_;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (action == Action.Lock) {
            dustLock.lockPermanent(tokenId);
        } else {
            dustLock.unlockPermanent(tokenId);
        }

        return this.onERC721Received.selector;
    }
}

contract DustLockPermanentReentrancyTest is BaseTestLocal {
    address internal constant EARLY_EXIT_WALLET = address(0xb007);

    function testRevenueRewardCallbackCannotUnlockPermanentDuringMerge() public {
        ClaimReformReentrantRewardToken reward = new ClaimReformReentrantRewardToken();
        uint256 fromAmount = 10 * TOKEN_1;
        uint256 toAmount = 20 * TOKEN_1;
        uint256 totalAmount = fromAmount + toAmount;

        mintErc20Token(address(DUST), user, totalAmount);
        DUST.approve(address(dustLock), totalAmount);
        uint256 fromTokenId = dustLock.createLockPermanentFor(fromAmount, MAXTIME, address(reward));
        uint256 toTokenId = dustLock.createLockPermanentFor(toAmount, MAXTIME, address(reward));
        _fundRewardEpoch(reward);
        skipToNextEpoch(1);

        reward.armUnlock(dustLock, toTokenId);
        vm.prank(address(reward));
        dustLock.merge(fromTokenId, toTokenId);

        IDustLock.LockedBalance memory merged = dustLock.locked(toTokenId);
        assertTrue(reward.reentryAttempted());
        assertFalse(reward.lastReentrySucceeded());
        assertTrue(merged.isPermanent);
        assertEq(uint256(merged.amount), totalAmount);
        assertEq(dustLock.permanentLockBalance(), totalAmount);
    }

    function testRevenueRewardCallbackCannotLockPermanentDuringTimedMerge() public {
        ClaimReformReentrantRewardToken reward = new ClaimReformReentrantRewardToken();
        uint256 fromAmount = 10 * TOKEN_1;
        uint256 toAmount = 20 * TOKEN_1;
        uint256 totalAmount = fromAmount + toAmount;

        mintErc20Token(address(DUST), user, totalAmount);
        DUST.approve(address(dustLock), totalAmount);
        uint256 fromTokenId = dustLock.createLockFor(fromAmount, MAXTIME, address(reward));
        uint256 toTokenId = dustLock.createLockFor(toAmount, MAXTIME, address(reward));
        _fundRewardEpoch(reward);
        skipToNextEpoch(1);

        reward.armLock(dustLock, toTokenId);
        vm.prank(address(reward));
        dustLock.merge(fromTokenId, toTokenId);

        IDustLock.LockedBalance memory merged = dustLock.locked(toTokenId);
        assertTrue(reward.reentryAttempted());
        assertFalse(reward.lastReentrySucceeded());
        assertFalse(merged.isPermanent);
        assertEq(uint256(merged.amount), totalAmount);
        assertEq(dustLock.permanentLockBalance(), 0);
    }

    function testSafeTransferCallbackCannotLockPermanent() public {
        mintErc20Token(address(DUST), user, TOKEN_1);
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);
        ClaimReformReentrantPermanentReceiver receiver =
            new ClaimReformReentrantPermanentReceiver(dustLock, ClaimReformReentrantPermanentReceiver.Action.Lock);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        dustLock.safeTransferFrom(user, address(receiver), tokenId);

        assertEq(dustLock.ownerOf(tokenId), user);
        assertFalse(dustLock.locked(tokenId).isPermanent);
    }

    function testSafeTransferCallbackCannotUnlockPermanent() public {
        mintErc20Token(address(DUST), user, TOKEN_1);
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLockPermanent(TOKEN_1, MAXTIME);
        ClaimReformReentrantPermanentReceiver receiver =
            new ClaimReformReentrantPermanentReceiver(dustLock, ClaimReformReentrantPermanentReceiver.Action.Unlock);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        dustLock.safeTransferFrom(user, address(receiver), tokenId);

        assertEq(dustLock.ownerOf(tokenId), user);
        assertTrue(dustLock.locked(tokenId).isPermanent);
    }

    function testApprovedOperatorCanStillLockAndUnlockPermanent() public {
        mintErc20Token(address(DUST), user, TOKEN_1);
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);
        dustLock.approve(user2, tokenId);

        vm.prank(user2);
        dustLock.lockPermanent(tokenId);
        assertTrue(dustLock.locked(tokenId).isPermanent);

        vm.prank(user2);
        dustLock.unlockPermanent(tokenId);
        assertFalse(dustLock.locked(tokenId).isPermanent);
    }

    function testPermanentEarlyWithdrawAutoUnlocksAndCompletes() public {
        mintErc20Token(address(DUST), user, TOKEN_1);
        DUST.approve(address(dustLock), TOKEN_1);
        dustLock.setEarlyWithdrawTreasury(EARLY_EXIT_WALLET);
        uint256 tokenId = dustLock.createLockPermanent(TOKEN_1, MAXTIME);

        /*
         * The one-step path auto-unlocks internally and charges the fresh weekly-rounded end price,
         * identical to unlockPermanent followed by earlyWithdraw as two manual steps.
         */
        (uint256 expectedPenalty,) = ClaimReformModel.permanentExit(TOKEN_1, block.timestamp);
        assertEq(dustLock.earlyWithdrawPenaltyAmount(tokenId), expectedPenalty);

        dustLock.earlyWithdraw(tokenId);

        assertEq(dustLock.permanentLockBalance(), 0);
        assertEq(dustLock.supply(), 0);
        assertEq(DUST.balanceOf(EARLY_EXIT_WALLET), expectedPenalty);
    }

    function _fundRewardEpoch(ClaimReformReentrantRewardToken reward) internal {
        reward.mint(admin, TOKEN_1K);
        vm.startPrank(admin);
        reward.approve(address(revenueReward), TOKEN_1K);
        revenueReward.notifyRewardAmount(address(reward), TOKEN_1K);
        vm.stopPrank();
    }
}
