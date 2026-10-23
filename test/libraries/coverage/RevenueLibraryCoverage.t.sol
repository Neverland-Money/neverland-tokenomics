// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IDustLock} from "../../../src/interfaces/IDustLock.sol";

import {BalanceLogicLibrary} from "../../../src/libraries/BalanceLogicLibrary.sol";
import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";
import {EpochTimeLibrary} from "../../../src/libraries/EpochTimeLibrary.sol";
import {SafeCastLibrary} from "../../../src/libraries/SafeCastLibrary.sol";

contract RevenueCommonChecksHarness {
    function revertIfInvalidFromAddress(address from) external pure {
        CommonChecksLibrary.revertIfInvalidFromAddress(from);
    }

    function revertIfInvalidRange(uint256 from, uint256 to) external pure {
        CommonChecksLibrary.revertIfInvalidRange(from, to);
    }

    function revertIfInvalidToAddress(address to) external pure {
        CommonChecksLibrary.revertIfInvalidToAddress(to);
    }

    function revertIfInvalidTokenId(address owner) external pure {
        CommonChecksLibrary.revertIfInvalidTokenId(owner);
    }

    function revertIfInvalidUserAddress(address user) external pure {
        CommonChecksLibrary.revertIfInvalidUserAddress(user);
    }

    function revertIfSameAddress(address first, address second) external pure {
        CommonChecksLibrary.revertIfSameAddress(first, second);
    }

    function revertIfZeroAddress(address account) external pure {
        CommonChecksLibrary.revertIfZeroAddress(account);
    }

    function revertIfZeroAmount(uint256 amount) external pure {
        CommonChecksLibrary.revertIfZeroAmount(amount);
    }

    function revertIfZeroBalance(uint256 balance) external pure {
        CommonChecksLibrary.revertIfZeroBalance(balance);
    }
}

contract RevenueEpochTimeHarness {
    function epochNext(uint256 timestamp) external pure returns (uint256) {
        return EpochTimeLibrary.epochNext(timestamp);
    }

    function epochStart(uint256 timestamp) external pure returns (uint256) {
        return EpochTimeLibrary.epochStart(timestamp);
    }

    function epochVoteEnd(uint256 timestamp) external pure returns (uint256) {
        return EpochTimeLibrary.epochVoteEnd(timestamp);
    }

    function epochVoteStart(uint256 timestamp) external pure returns (uint256) {
        return EpochTimeLibrary.epochVoteStart(timestamp);
    }
}

contract RevenueSafeCastHarness {
    function toInt128(uint256 value) external pure returns (int128) {
        return SafeCastLibrary.toInt128(value);
    }

    function toInt256(uint256 value) external pure returns (int256) {
        return SafeCastLibrary.toInt256(value);
    }

    function toUint256FromInt256(int256 value) external pure returns (uint256) {
        return SafeCastLibrary.toUint256(value);
    }
}

contract RevenueBalanceLogicHarness {
    uint256 internal constant MAX_USER_POINTS = 1_000_000_000;

    mapping(uint256 => IDustLock.GlobalPoint) internal pointHistory;
    mapping(uint256 => int256) internal slopeChanges;
    mapping(uint256 => uint256) internal userPointEpoch;
    mapping(uint256 => IDustLock.UserPoint[MAX_USER_POINTS]) internal userPointHistory;

    function balanceOfNFTAt(uint256 tokenId, uint256 timestamp) external view returns (uint256) {
        return BalanceLogicLibrary.balanceOfNFTAt(userPointEpoch, userPointHistory, tokenId, timestamp);
    }

    function getPastGlobalPointIndex(uint256 epoch, uint256 timestamp) external view returns (uint256) {
        return BalanceLogicLibrary.getPastGlobalPointIndex(epoch, pointHistory, timestamp);
    }

    function getPastUserPointIndex(uint256 tokenId, uint256 timestamp) external view returns (uint256) {
        return BalanceLogicLibrary.getPastUserPointIndex(userPointEpoch, userPointHistory, tokenId, timestamp);
    }

    function setGlobalPoint(uint256 epoch, int256 bias, int256 slope, uint256 timestamp, uint256 permanentLockBalance)
        external
    {
        pointHistory[epoch] = IDustLock.GlobalPoint({
            bias: bias, slope: slope, ts: timestamp, blk: block.number, permanentLockBalance: permanentLockBalance
        });
    }

    function setSlopeChange(uint256 timestamp, int256 slopeChange) external {
        slopeChanges[timestamp] = slopeChange;
    }

    function setUserPoint(
        uint256 tokenId,
        uint256 epoch,
        int256 bias,
        int256 slope,
        uint256 timestamp,
        uint256 permanent
    ) external {
        userPointEpoch[tokenId] = epoch;
        userPointHistory[tokenId][epoch] =
            IDustLock.UserPoint({bias: bias, slope: slope, ts: timestamp, blk: block.number, permanent: permanent});
    }

    function supplyAt(uint256 epoch, uint256 timestamp) external view returns (uint256) {
        return BalanceLogicLibrary.supplyAt(slopeChanges, pointHistory, epoch, timestamp);
    }
}

contract RevenueLibraryCoverageTest is Test {
    RevenueBalanceLogicHarness internal balanceLogic;
    RevenueCommonChecksHarness internal commonChecks;
    RevenueEpochTimeHarness internal epochTime;
    RevenueSafeCastHarness internal safeCast;

    function setUp() public {
        balanceLogic = new RevenueBalanceLogicHarness();
        commonChecks = new RevenueCommonChecksHarness();
        epochTime = new RevenueEpochTimeHarness();
        safeCast = new RevenueSafeCastHarness();
    }

    function testBalanceLogicBinarySearchBranches() public {
        assertEq(balanceLogic.getPastUserPointIndex(1, 10), 0);
        balanceLogic.setUserPoint(1, 1, 10e18, 0, 100, 0);
        balanceLogic.setUserPoint(1, 2, 20e18, 0, 200, 0);
        balanceLogic.setUserPoint(1, 3, 30e18, 0, 300, 0);
        assertEq(balanceLogic.getPastUserPointIndex(1, 350), 3);
        assertEq(balanceLogic.getPastUserPointIndex(1, 50), 0);
        assertEq(balanceLogic.getPastUserPointIndex(1, 200), 2);
        assertEq(balanceLogic.getPastUserPointIndex(1, 250), 2);

        assertEq(balanceLogic.getPastGlobalPointIndex(0, 10), 0);
        balanceLogic.setGlobalPoint(1, 10e18, 0, 100, 0);
        balanceLogic.setGlobalPoint(2, 20e18, 0, 200, 0);
        balanceLogic.setGlobalPoint(3, 30e18, 0, 300, 0);
        assertEq(balanceLogic.getPastGlobalPointIndex(3, 350), 3);
        assertEq(balanceLogic.getPastGlobalPointIndex(3, 50), 0);
        assertEq(balanceLogic.getPastGlobalPointIndex(3, 200), 2);
        assertEq(balanceLogic.getPastGlobalPointIndex(3, 250), 2);
    }

    function testBalanceLogicPowerBranches() public {
        assertEq(balanceLogic.balanceOfNFTAt(9, 1 weeks), 0);

        balanceLogic.setUserPoint(9, 1, 0, 0, 1 weeks, 77);
        assertEq(balanceLogic.balanceOfNFTAt(9, 2 weeks), 77);

        balanceLogic.setUserPoint(10, 1, 10e18, 1e18, 1 weeks, 0);
        assertEq(balanceLogic.balanceOfNFTAt(10, 1 weeks + 5), 5);
        assertEq(balanceLogic.balanceOfNFTAt(10, 1 weeks + 20), 0);

        assertEq(balanceLogic.supplyAt(0, 1 weeks), 0);
        balanceLogic.setGlobalPoint(1, 14e18, 1e18, 1 weeks, 3);
        balanceLogic.setSlopeChange(2 weeks, -1e18);
        assertEq(balanceLogic.supplyAt(1, 1 weeks + 5), 12);
        assertEq(balanceLogic.supplyAt(1, 3 weeks), 3);
    }

    function testCommonChecksPassAndRevertBranches() public {
        commonChecks.revertIfZeroAddress(address(1));
        commonChecks.revertIfZeroAmount(1);
        commonChecks.revertIfInvalidRange(1, 1);
        commonChecks.revertIfSameAddress(address(1), address(2));
        commonChecks.revertIfZeroBalance(1);
        commonChecks.revertIfInvalidTokenId(address(1));
        commonChecks.revertIfInvalidFromAddress(address(1));
        commonChecks.revertIfInvalidToAddress(address(1));
        commonChecks.revertIfInvalidUserAddress(address(1));

        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        commonChecks.revertIfZeroAddress(address(0));
        vm.expectRevert(CommonChecksLibrary.ZeroAmount.selector);
        commonChecks.revertIfZeroAmount(0);
        vm.expectRevert(CommonChecksLibrary.InvalidRange.selector);
        commonChecks.revertIfInvalidRange(2, 1);
        vm.expectRevert(CommonChecksLibrary.SameAddress.selector);
        commonChecks.revertIfSameAddress(address(1), address(1));
        vm.expectRevert(CommonChecksLibrary.ZeroBalance.selector);
        commonChecks.revertIfZeroBalance(0);
        vm.expectRevert(CommonChecksLibrary.InvalidTokenId.selector);
        commonChecks.revertIfInvalidTokenId(address(0));
        vm.expectRevert(CommonChecksLibrary.InvalidFromAddress.selector);
        commonChecks.revertIfInvalidFromAddress(address(0));
        vm.expectRevert(CommonChecksLibrary.InvalidToAddress.selector);
        commonChecks.revertIfInvalidToAddress(address(0));
        vm.expectRevert(CommonChecksLibrary.InvalidUserAddress.selector);
        commonChecks.revertIfInvalidUserAddress(address(0));
    }

    function testEpochTimeLibrary() public view {
        uint256 timestamp = 3 weeks + 2 days + 3 hours;
        assertEq(epochTime.epochStart(timestamp), 3 weeks);
        assertEq(epochTime.epochNext(timestamp), 4 weeks);
        assertEq(epochTime.epochVoteStart(timestamp), 3 weeks + 1 hours);
        assertEq(epochTime.epochVoteEnd(timestamp), 4 weeks - 1 hours);
    }

    function testSafeCastLibrary() public {
        assertEq(safeCast.toInt128(uint256(uint128(type(int128).max))), type(int128).max);
        assertEq(safeCast.toInt256(uint256(type(int256).max)), type(int256).max);
        assertEq(safeCast.toUint256FromInt256(int256(1)), 1);

        vm.expectRevert(SafeCastLibrary.SafeCastOverflow.selector);
        safeCast.toInt128(uint256(uint128(type(int128).max)) + 1);
        vm.expectRevert(SafeCastLibrary.SafeCastOverflow.selector);
        safeCast.toInt256(uint256(type(int256).max) + 1);
        vm.expectRevert(SafeCastLibrary.SafeCastUnderflow.selector);
        safeCast.toUint256FromInt256(int256(-1));
    }
}
