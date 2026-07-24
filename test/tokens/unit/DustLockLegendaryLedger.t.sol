// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IDustLockLegendaryLedger} from "../../../src/interfaces/IDustLockLegendaryLedger.sol";
import {IDustLock} from "../../../src/interfaces/IDustLock.sol";
import {DustLockLegendaryLedger} from "../../../src/tokens/DustLockLegendaryLedger.sol";
import {Dust} from "../../../src/tokens/Dust.sol";
import {DustLock} from "../../../src/tokens/DustLock.sol";
import {Vm} from "forge-std/Vm.sol";

import "../../BaseTest.sol";

contract TestDelegateProxy {
    address private immutable implementation;

    constructor(address implementation_) {
        implementation = implementation_;
    }

    fallback() external payable {
        _delegate();
    }

    receive() external payable {
        _delegate();
    }

    function _delegate() private {
        address implementation_ = implementation;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), implementation_, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch success
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

contract RejectNativeReceiver {
    receive() external payable {
        revert("reject-native");
    }
}

abstract contract DustLockLegendaryLedgerBaseTest is BaseTest {
    Dust internal DUST;
    IDustLock internal dustLock;

    function _testSetup() internal virtual override {
        skip(1 weeks);

        Dust dustImpl = new Dust();
        DUST = Dust(_deployProxy(address(dustImpl)));

        DustLock dustLockImpl = new DustLock(FORWARDER);
        dustLock = IDustLock(_deployProxy(address(dustLockImpl)));
        DustLock(address(dustLock)).initialize(FORWARDER, address(DUST), "https://neverland.money/nfts/");

        DUST.initialize(admin, 0);

        vm.label(address(DUST), "DUST");
        vm.label(address(dustLock), "DustLock");
    }

    function _deployProxy(address implementation) internal returns (address) {
        TestDelegateProxy proxy = new TestDelegateProxy(implementation);
        return address(proxy);
    }
}

contract DustLockLegendaryLedgerTest is DustLockLegendaryLedgerBaseTest {
    uint8 internal constant LEGENDARY_ATTEMPT_NONE = 0;
    uint8 internal constant LEGENDARY_ATTEMPT_TIMED = 1;
    uint8 internal constant LEGENDARY_ATTEMPT_PERMANENT = 2;
    uint256 internal constant DEFAULT_ATTEMPT_THRESHOLD = TOKEN_10K;

    event LegendaryAttemptThresholdUpdated(uint256 threshold);
    event ERC20Recovered(address indexed token, address indexed recipient, uint256 amount);
    event NativeRecovered(address indexed recipient, uint256 amount);
    event LegendaryLedgerAttemptRecorded(
        address indexed owner, uint256 indexed tokenId, uint8 indexed attemptType, uint256 value, uint256 lockDuration
    );

    DustLockLegendaryLedger internal gateway;
    Dust internal bonusToken;

    function _setUp() internal override {
        assertEq(block.timestamp, 1 weeks + 1);

        gateway = new DustLockLegendaryLedger(address(dustLock), admin, DEFAULT_ATTEMPT_THRESHOLD);
        Dust bonusTokenImpl = new Dust();
        bonusToken = Dust(_deployProxy(address(bonusTokenImpl)));
        bonusToken.initialize(admin, 0);
        mintErc20Token(address(DUST), user, TOKEN_100K);
        vm.label(address(bonusToken), "BONUS");
    }

    function testSetup() public view {
        assertEq(address(gateway.dustLock()), address(dustLock));
        assertEq(address(gateway.dustToken()), address(DUST));
        assertEq(gateway.owner(), admin);
        assertEq(gateway.legendaryAttemptThreshold(), DEFAULT_ATTEMPT_THRESHOLD);
    }

    function testConstructorZeroThresholdReverts() public {
        vm.expectRevert(IDustLockLegendaryLedger.InvalidLegendaryAttemptThreshold.selector);
        new DustLockLegendaryLedger(address(dustLock), admin, 0);
    }

    function testLegendaryAttemptThresholdOnlySetByOwner() public {
        vm.prank(user1);
        vm.expectRevert("Ownable: caller is not the owner");
        gateway.setLegendaryAttemptThreshold(TOKEN_100K);

        vm.prank(admin);
        vm.expectRevert(IDustLockLegendaryLedger.InvalidLegendaryAttemptThreshold.selector);
        gateway.setLegendaryAttemptThreshold(0);

        vm.prank(admin);
        vm.expectEmit(address(gateway));
        emit LegendaryAttemptThresholdUpdated(TOKEN_100K);
        gateway.setLegendaryAttemptThreshold(TOKEN_100K);

        assertEq(gateway.legendaryAttemptThreshold(), TOKEN_100K);
    }

    function testLegendaryAttemptThresholdNoOpDoesNotEmit() public {
        vm.prank(admin);
        gateway.setLegendaryAttemptThreshold(TOKEN_100K);

        vm.recordLogs();
        vm.prank(admin);
        gateway.setLegendaryAttemptThreshold(TOKEN_100K);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0);
    }

    function testCreateLockAtThresholdRecordsTimedAttemptAndEmitsEvent() public {
        uint256 nextTokenId = dustLock.tokenId() + 1;

        DUST.approve(address(gateway), DEFAULT_ATTEMPT_THRESHOLD);

        vm.expectEmit(address(gateway));
        emit LegendaryLedgerAttemptRecorded(
            user, nextTokenId, LEGENDARY_ATTEMPT_TIMED, DEFAULT_ATTEMPT_THRESHOLD, MAXTIME
        );
        uint256 tokenId = gateway.createLock(DEFAULT_ATTEMPT_THRESHOLD, MAXTIME);

        uint8 attemptType = gateway.legendaryAttemptTypeOf(tokenId);
        assertEq(tokenId, nextTokenId);
        assertEq(attemptType, LEGENDARY_ATTEMPT_TIMED);
        assertTrue(gateway.hasLegendaryAttempt(tokenId));
        assertEq(dustLock.ownerOf(tokenId), user);
        assertEq(DUST.balanceOf(address(gateway)), 0);
        assertEq(DUST.allowance(address(gateway), address(dustLock)), 0);
    }

    function testCreateLockBelowThresholdReverts() public {
        DUST.approve(address(gateway), TOKEN_1K);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDustLockLegendaryLedger.LockAmountBelowLegendaryThreshold.selector, TOKEN_1K, DEFAULT_ATTEMPT_THRESHOLD
            )
        );
        gateway.createLock(TOKEN_1K, MAXTIME);
    }

    function testThresholdUpdateAffectsFutureAcceptance() public {
        vm.prank(admin);
        gateway.setLegendaryAttemptThreshold(TOKEN_100K);

        DUST.approve(address(gateway), TOKEN_10K);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDustLockLegendaryLedger.LockAmountBelowLegendaryThreshold.selector, TOKEN_10K, TOKEN_100K
            )
        );
        gateway.createLock(TOKEN_10K, MAXTIME);

        DUST.approve(address(gateway), TOKEN_100K);
        uint256 tokenId = gateway.createLock(TOKEN_100K, MAXTIME);
        assertEq(gateway.legendaryAttemptTypeOf(tokenId), LEGENDARY_ATTEMPT_TIMED);
    }

    function testCreateLockBelowDustLockMinimumRevertsBeforeTokenPull() public {
        uint256 driftedMin = TOKEN_100K;
        uint256 amount = TOKEN_10K + TOKEN_1K;

        dustLock.setMinLockAmount(driftedMin);

        uint256 userBalanceBefore = DUST.balanceOf(user);
        DUST.approve(address(gateway), amount);

        vm.expectRevert(
            abi.encodeWithSelector(IDustLockLegendaryLedger.LockAmountBelowDustLockMinimum.selector, amount, driftedMin)
        );
        gateway.createLock(amount, MAXTIME);

        assertEq(DUST.balanceOf(user), userBalanceBefore);
        assertEq(DUST.balanceOf(address(gateway)), 0);
        assertEq(DUST.allowance(address(gateway), address(dustLock)), 0);
    }

    function testFuzzCreateLockPermanentRecordsAttemptType(
        uint256 amountSeed,
        uint256 blockNumberSeed,
        uint256 durationSeed
    ) public {
        uint256 amount = bound(amountSeed, DEFAULT_ATTEMPT_THRESHOLD, TOKEN_100K);
        uint256 blockNumber = bound(blockNumberSeed, 1, type(uint64).max);
        // DustLock rounds block.timestamp + lockDuration down to whole weeks, so
        // values below MINTIME + WEEK can still underflow the effective minimum.
        uint256 lockDuration = bound(durationSeed, MINTIME + WEEK, MAXTIME);

        vm.roll(blockNumber);

        uint256 nextTokenId = dustLock.tokenId() + 1;
        DUST.approve(address(gateway), amount);

        vm.expectEmit(address(gateway));
        emit LegendaryLedgerAttemptRecorded(user, nextTokenId, LEGENDARY_ATTEMPT_PERMANENT, amount, lockDuration);
        uint256 tokenId = gateway.createLockPermanent(amount, lockDuration);

        uint8 attemptType = gateway.legendaryAttemptTypeOf(tokenId);
        assertEq(tokenId, nextTokenId);
        assertEq(attemptType, LEGENDARY_ATTEMPT_PERMANENT);
        assertTrue(gateway.hasLegendaryAttempt(tokenId));
    }

    function testFuzzCreateLockPermanentBelowThresholdReverts(uint256 amountSeed) public {
        uint256 amount = bound(amountSeed, MIN_LOCK_AMOUNT, DEFAULT_ATTEMPT_THRESHOLD - 1);

        DUST.approve(address(gateway), amount);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDustLockLegendaryLedger.LockAmountBelowLegendaryThreshold.selector, amount, DEFAULT_ATTEMPT_THRESHOLD
            )
        );
        gateway.createLockPermanent(amount, MAXTIME);
    }

    function testCreateLockPermanentBelowDustLockMinimumRevertsBeforeTokenPull() public {
        uint256 driftedMin = TOKEN_100K;
        uint256 amount = TOKEN_10K + TOKEN_1K;

        dustLock.setMinLockAmount(driftedMin);

        uint256 userBalanceBefore = DUST.balanceOf(user);
        DUST.approve(address(gateway), amount);

        vm.expectRevert(
            abi.encodeWithSelector(IDustLockLegendaryLedger.LockAmountBelowDustLockMinimum.selector, amount, driftedMin)
        );
        gateway.createLockPermanent(amount, MAXTIME);

        assertEq(DUST.balanceOf(user), userBalanceBefore);
        assertEq(DUST.balanceOf(address(gateway)), 0);
        assertEq(DUST.allowance(address(gateway), address(dustLock)), 0);
    }

    function testCreateLockPermanentRecordsPermanentAttemptAndEmitsEvent() public {
        uint256 nextTokenId = dustLock.tokenId() + 1;

        DUST.approve(address(gateway), DEFAULT_ATTEMPT_THRESHOLD);

        vm.expectEmit(address(gateway));
        emit LegendaryLedgerAttemptRecorded(
            user, nextTokenId, LEGENDARY_ATTEMPT_PERMANENT, DEFAULT_ATTEMPT_THRESHOLD, MAXTIME
        );
        uint256 tokenId = gateway.createLockPermanent(DEFAULT_ATTEMPT_THRESHOLD, MAXTIME);

        uint8 attemptType = gateway.legendaryAttemptTypeOf(tokenId);
        assertEq(tokenId, nextTokenId);
        assertEq(attemptType, LEGENDARY_ATTEMPT_PERMANENT);
        assertTrue(gateway.hasLegendaryAttempt(tokenId));
        assertEq(DUST.balanceOf(address(gateway)), 0);
        assertEq(DUST.allowance(address(gateway), address(dustLock)), 0);
    }

    function testCreateLockPermanentInvalidDurationBubblesDustLockRevert() public {
        DUST.approve(address(gateway), DEFAULT_ATTEMPT_THRESHOLD);
        vm.expectRevert(IDustLock.LockDurationNotInFuture.selector);
        gateway.createLockPermanent(DEFAULT_ATTEMPT_THRESHOLD, 0);
    }

    function testRecoverERC20OnlyOwner() public {
        uint256 accidentalAmount = TOKEN_1K;
        mintErc20Token(address(bonusToken), address(gateway), accidentalAmount);
        assertEq(bonusToken.balanceOf(address(gateway)), accidentalAmount);

        vm.prank(user1);
        vm.expectRevert("Ownable: caller is not the owner");
        gateway.recoverERC20(address(bonusToken), admin, accidentalAmount);

        vm.prank(admin);
        vm.expectRevert(IDustLockLegendaryLedger.InvalidERC20RecoveryToken.selector);
        gateway.recoverERC20(address(0), admin, accidentalAmount);

        vm.prank(admin);
        vm.expectRevert(IDustLockLegendaryLedger.InvalidERC20RecoveryRecipient.selector);
        gateway.recoverERC20(address(bonusToken), address(0), accidentalAmount);

        vm.prank(admin);
        vm.expectRevert(IDustLockLegendaryLedger.InvalidERC20RecoveryAmount.selector);
        gateway.recoverERC20(address(bonusToken), admin, 0);

        vm.prank(admin);
        vm.expectEmit(address(gateway));
        emit ERC20Recovered(address(bonusToken), admin, accidentalAmount);
        gateway.recoverERC20(address(bonusToken), admin, accidentalAmount);

        assertEq(bonusToken.balanceOf(address(gateway)), 0);
        assertEq(bonusToken.balanceOf(admin), accidentalAmount);
    }

    function testRecoverERC20SupportsDustToken() public {
        uint256 accidentalAmount = TOKEN_1K;
        mintErc20Token(address(DUST), address(gateway), accidentalAmount);
        assertEq(DUST.balanceOf(address(gateway)), accidentalAmount);

        vm.prank(admin);
        vm.expectEmit(address(gateway));
        emit ERC20Recovered(address(DUST), admin, accidentalAmount);
        gateway.recoverERC20(address(DUST), admin, accidentalAmount);

        assertEq(DUST.balanceOf(address(gateway)), 0);
        assertEq(DUST.balanceOf(admin), accidentalAmount);
    }

    function testRecoverERC20RevertsWhenAmountExceedsLedgerBalance() public {
        uint256 accidentalAmount = TOKEN_1K;
        mintErc20Token(address(bonusToken), address(gateway), accidentalAmount);

        vm.prank(admin);
        vm.expectRevert(bytes("ERC20: transfer amount exceeds balance"));
        gateway.recoverERC20(address(bonusToken), admin, accidentalAmount + 1);
    }

    function testRecoverNativeOnlyOwner() public {
        uint256 accidentalAmount = 1 ether;
        vm.deal(address(gateway), accidentalAmount);
        assertEq(address(gateway).balance, accidentalAmount);

        vm.prank(user1);
        vm.expectRevert("Ownable: caller is not the owner");
        gateway.recoverNative(admin, accidentalAmount);

        vm.prank(admin);
        vm.expectRevert(IDustLockLegendaryLedger.InvalidNativeRecoveryRecipient.selector);
        gateway.recoverNative(address(0), accidentalAmount);

        vm.prank(admin);
        vm.expectRevert(IDustLockLegendaryLedger.InvalidNativeRecoveryAmount.selector);
        gateway.recoverNative(admin, 0);

        uint256 adminBalanceBefore = admin.balance;

        vm.prank(admin);
        vm.expectEmit(address(gateway));
        emit NativeRecovered(admin, accidentalAmount);
        gateway.recoverNative(admin, accidentalAmount);

        assertEq(address(gateway).balance, 0);
        assertEq(admin.balance, adminBalanceBefore + accidentalAmount);
    }

    function testRecoverNativeSupportsPartialRecovery() public {
        vm.deal(address(gateway), 1 ether);
        uint256 adminBalanceBefore = admin.balance;

        vm.prank(admin);
        vm.expectEmit(address(gateway));
        emit NativeRecovered(admin, 0.4 ether);
        gateway.recoverNative(admin, 0.4 ether);

        assertEq(address(gateway).balance, 0.6 ether);
        assertEq(admin.balance, adminBalanceBefore + 0.4 ether);
    }

    function testRecoverNativeRevertsWhenTransferFails() public {
        RejectNativeReceiver recipient = new RejectNativeReceiver();
        vm.deal(address(gateway), 1 ether);

        vm.prank(admin);
        vm.expectRevert(IDustLockLegendaryLedger.NativeRecoveryFailed.selector);
        gateway.recoverNative(address(recipient), 1 ether);
    }

    function testRecoverNativeRevertsWhenAmountExceedsLedgerBalance() public {
        vm.deal(address(gateway), 0.5 ether);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDustLockLegendaryLedger.InsufficientNativeRecoveryBalance.selector, 1 ether, 0.5 ether
            )
        );
        gateway.recoverNative(admin, 1 ether);
    }

    function testNativeTokenTransferReverts() public {
        vm.deal(user1, 1 ether);

        vm.prank(user1);
        (bool success,) = address(gateway).call{value: 1 ether}("");

        assertFalse(success);
        assertEq(address(gateway).balance, 0);
    }

    function testHistoricalAttemptsRemainImmutableAfterThresholdChanges() public {
        DUST.approve(address(gateway), DEFAULT_ATTEMPT_THRESHOLD);
        uint256 tokenId = gateway.createLock(DEFAULT_ATTEMPT_THRESHOLD, MAXTIME);

        uint8 initialAttemptType = gateway.legendaryAttemptTypeOf(tokenId);
        assertEq(initialAttemptType, LEGENDARY_ATTEMPT_TIMED);

        vm.prank(admin);
        gateway.setLegendaryAttemptThreshold(TOKEN_100K);

        uint8 historicalAttemptType = gateway.legendaryAttemptTypeOf(tokenId);
        assertEq(historicalAttemptType, LEGENDARY_ATTEMPT_TIMED);
    }

    function testMergeDoesNotMigrateAttemptToDestination() public {
        DUST.approve(address(gateway), DEFAULT_ATTEMPT_THRESHOLD * 2);
        uint256 sourceTokenId = gateway.createLock(DEFAULT_ATTEMPT_THRESHOLD, MAXTIME);
        uint256 destinationTokenId = gateway.createLock(DEFAULT_ATTEMPT_THRESHOLD, MAXTIME);

        assertEq(gateway.legendaryAttemptTypeOf(sourceTokenId), LEGENDARY_ATTEMPT_TIMED);
        assertEq(gateway.legendaryAttemptTypeOf(destinationTokenId), LEGENDARY_ATTEMPT_TIMED);
        assertTrue(gateway.hasLegendaryAttempt(sourceTokenId));
        assertTrue(gateway.hasLegendaryAttempt(destinationTokenId));

        dustLock.merge(sourceTokenId, destinationTokenId);

        /// Source token is burned by DustLock.merge; gateway snapshot intentionally remains historical.
        assertEq(gateway.legendaryAttemptTypeOf(sourceTokenId), LEGENDARY_ATTEMPT_TIMED);
        assertEq(gateway.legendaryAttemptTypeOf(destinationTokenId), LEGENDARY_ATTEMPT_TIMED);
        assertTrue(gateway.hasLegendaryAttempt(sourceTokenId));
        assertTrue(gateway.hasLegendaryAttempt(destinationTokenId));
    }

    function testMergeGatewaySourceIntoDirectDestinationDoesNotCreateDestinationAttempt() public {
        DUST.approve(address(gateway), DEFAULT_ATTEMPT_THRESHOLD);
        uint256 sourceTokenId = gateway.createLock(DEFAULT_ATTEMPT_THRESHOLD, MAXTIME);

        DUST.approve(address(dustLock), DEFAULT_ATTEMPT_THRESHOLD);
        uint256 destinationTokenId = dustLock.createLockFor(DEFAULT_ATTEMPT_THRESHOLD, MAXTIME, user);

        assertEq(gateway.legendaryAttemptTypeOf(sourceTokenId), LEGENDARY_ATTEMPT_TIMED);
        assertEq(gateway.legendaryAttemptTypeOf(destinationTokenId), LEGENDARY_ATTEMPT_NONE);
        assertTrue(gateway.hasLegendaryAttempt(sourceTokenId));
        assertFalse(gateway.hasLegendaryAttempt(destinationTokenId));

        dustLock.merge(sourceTokenId, destinationTokenId);

        /// Source token is burned by DustLock.merge; gateway snapshot intentionally remains historical.
        assertEq(gateway.legendaryAttemptTypeOf(sourceTokenId), LEGENDARY_ATTEMPT_TIMED);
        assertEq(gateway.legendaryAttemptTypeOf(destinationTokenId), LEGENDARY_ATTEMPT_NONE);
        assertTrue(gateway.hasLegendaryAttempt(sourceTokenId));
        assertFalse(gateway.hasLegendaryAttempt(destinationTokenId));
    }

    function testSplitDoesNotCreateAttemptSnapshotsForChildren() public {
        DUST.approve(address(gateway), DEFAULT_ATTEMPT_THRESHOLD);
        uint256 sourceTokenId = gateway.createLock(DEFAULT_ATTEMPT_THRESHOLD, MAXTIME);
        assertEq(gateway.legendaryAttemptTypeOf(sourceTokenId), LEGENDARY_ATTEMPT_TIMED);
        assertTrue(gateway.hasLegendaryAttempt(sourceTokenId));

        dustLock.toggleSplit(address(0), true);
        (uint256 childTokenId1, uint256 childTokenId2) = dustLock.split(sourceTokenId, TOKEN_1K * 5);

        /// Source token is burned by DustLock.split; gateway snapshot intentionally remains historical.
        assertEq(gateway.legendaryAttemptTypeOf(sourceTokenId), LEGENDARY_ATTEMPT_TIMED);
        assertEq(gateway.legendaryAttemptTypeOf(childTokenId1), LEGENDARY_ATTEMPT_NONE);
        assertEq(gateway.legendaryAttemptTypeOf(childTokenId2), LEGENDARY_ATTEMPT_NONE);
        assertTrue(gateway.hasLegendaryAttempt(sourceTokenId));
        assertFalse(gateway.hasLegendaryAttempt(childTokenId1));
        assertFalse(gateway.hasLegendaryAttempt(childTokenId2));
    }

    function testDirectDustLockMintDoesNotCreateGatewayAttemptType() public {
        DUST.approve(address(dustLock), DEFAULT_ATTEMPT_THRESHOLD);
        uint256 tokenId = dustLock.createLockFor(DEFAULT_ATTEMPT_THRESHOLD, MAXTIME, user);

        uint8 attemptType = gateway.legendaryAttemptTypeOf(tokenId);
        assertEq(attemptType, LEGENDARY_ATTEMPT_NONE);
        assertFalse(gateway.hasLegendaryAttempt(tokenId));
    }

    function testRenounceOwnershipReverts() public {
        vm.prank(admin);
        vm.expectRevert(IDustLockLegendaryLedger.RenounceOwnershipDisabled.selector);
        gateway.renounceOwnership();
    }

    function testTransferOwnershipRequiresAcceptOwnership() public {
        vm.prank(admin);
        gateway.transferOwnership(user1);

        assertEq(gateway.owner(), admin);
        assertEq(gateway.pendingOwner(), user1);

        vm.prank(user2);
        vm.expectRevert("Ownable2Step: caller is not the new owner");
        gateway.acceptOwnership();

        vm.prank(user1);
        gateway.acceptOwnership();

        assertEq(gateway.owner(), user1);
        assertEq(gateway.pendingOwner(), address(0));
    }
}
