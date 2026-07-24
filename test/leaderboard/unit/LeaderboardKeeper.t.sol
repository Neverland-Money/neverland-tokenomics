// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./LeaderboardBase.sol";
import {LeaderboardKeeper} from "../../../src/leaderboard/LeaderboardKeeper.sol";
import {ILeaderboardKeeper} from "../../../src/interfaces/ILeaderboardKeeper.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract LeaderboardKeeperTest is LeaderboardBase {
    LeaderboardKeeper public keeper;

    address public keeperBot = makeAddr("keeperBot");

    function setUp() public override {
        super.setUp();

        // Deploy LeaderboardKeeper (Upgradeable)
        LeaderboardKeeper keeperImpl = new LeaderboardKeeper(address(dustLock), address(nftRegistry));
        TransparentUpgradeableProxy keeperProxy =
            new TransparentUpgradeableProxy(address(keeperImpl), address(proxyAdmin), "");
        keeper = LeaderboardKeeper(address(keeperProxy));
        keeper.initialize(admin, keeperBot, 3600); // 1 hour interval
    }

    /*//////////////////////////////////////////////////////////////
                           INITIALIZATION TESTS
      //////////////////////////////////////////////////////////////*/

    function testInitialConfiguration() public view {
        assertEq(keeper.keeper(), keeperBot, "Initial keeper address");
        assertEq(keeper.minSettlementInterval(), 3600, "Initial interval");
        assertEq(keeper.owner(), admin, "Initial owner");
        assertEq(keeper.MAX_BATCH_SIZE(), 400, "Max batch size");
    }

    function testConstructorZeroAddressDustLock() public {
        vm.expectRevert();
        new LeaderboardKeeper(ZERO_ADDRESS, address(nftRegistry));
    }

    function testConstructorZeroAddressNFTRegistry() public {
        vm.expectRevert();
        new LeaderboardKeeper(address(dustLock), ZERO_ADDRESS);
    }

    function testInitializeZeroAddressOwner() public {
        LeaderboardKeeper keeperImpl = new LeaderboardKeeper(address(dustLock), address(nftRegistry));
        TransparentUpgradeableProxy keeperProxy =
            new TransparentUpgradeableProxy(address(keeperImpl), address(proxyAdmin), "");
        LeaderboardKeeper newKeeper = LeaderboardKeeper(address(keeperProxy));

        vm.expectRevert();
        newKeeper.initialize(ZERO_ADDRESS, keeperBot, 3600);
    }

    function testInitializeZeroAddressKeeper() public {
        LeaderboardKeeper keeperImpl = new LeaderboardKeeper(address(dustLock), address(nftRegistry));
        TransparentUpgradeableProxy keeperProxy =
            new TransparentUpgradeableProxy(address(keeperImpl), address(proxyAdmin), "");
        LeaderboardKeeper newKeeper = LeaderboardKeeper(address(keeperProxy));

        vm.expectRevert();
        newKeeper.initialize(admin, ZERO_ADDRESS, 3600);
    }

    /*//////////////////////////////////////////////////////////////
                         SYNC VOTING POWER TESTS
      //////////////////////////////////////////////////////////////*/

    function testSyncVotingPower() public {
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        uint256[] memory votingPowers = new uint256[](2);
        votingPowers[0] = 1000e18;
        votingPowers[1] = 2000e18;

        vm.prank(keeperBot);
        keeper.syncVotingPower(users, votingPowers);
    }

    function testSyncVotingPowerEmitsEvents() public {
        address[] memory users = new address[](1);
        users[0] = user1;

        uint256[] memory votingPowers = new uint256[](1);
        votingPowers[0] = 1000e18;

        vm.expectEmit(true, true, true, true);
        emit ILeaderboardKeeper.VotingPowerSynced(user1, 1000e18, block.timestamp);

        vm.expectEmit(true, true, true, true);
        emit ILeaderboardKeeper.BatchComplete("sync_vp", 1, block.timestamp);

        vm.prank(keeperBot);
        keeper.syncVotingPower(users, votingPowers);
    }

    function testSyncVotingPowerArrayLengthMismatch() public {
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        uint256[] memory votingPowers = new uint256[](1);
        votingPowers[0] = 1000e18;

        vm.prank(keeperBot);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardKeeper.ArrayLengthMismatch.selector, 2, 1));
        keeper.syncVotingPower(users, votingPowers);
    }

    function testSyncVotingPowerBatchTooLarge() public {
        address[] memory users = new address[](401);
        uint256[] memory votingPowers = new uint256[](401);

        vm.prank(keeperBot);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardKeeper.BatchTooLarge.selector, 401, 400));
        keeper.syncVotingPower(users, votingPowers);
    }

    function testSyncVotingPowerOnlyKeeper() public {
        address[] memory users = new address[](1);
        users[0] = user1;

        uint256[] memory votingPowers = new uint256[](1);
        votingPowers[0] = 1000e18;

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardKeeper.NotKeeper.selector, user1));
        keeper.syncVotingPower(users, votingPowers);
    }

    function testSyncVotingPowerOwnerCanCall() public {
        address[] memory users = new address[](1);
        users[0] = user1;

        uint256[] memory votingPowers = new uint256[](1);
        votingPowers[0] = 1000e18;

        vm.prank(admin);
        keeper.syncVotingPower(users, votingPowers);
    }

    /*//////////////////////////////////////////////////////////////
                              SETTLE TESTS
      //////////////////////////////////////////////////////////////*/

    function testSettle() public {
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        vm.prank(keeperBot);
        keeper.settle(users);

        assertEq(keeper.lastSettlement(user1), block.timestamp, "User1 settlement time");
        assertEq(keeper.lastSettlement(user2), block.timestamp, "User2 settlement time");
    }

    function testSettleSkipsRecentlySettled() public {
        address[] memory users = new address[](1);
        users[0] = user1;

        // First settlement
        vm.prank(keeperBot);
        keeper.settle(users);

        uint256 firstSettlement = keeper.lastSettlement(user1);
        assertEq(firstSettlement, block.timestamp, "First settlement");

        // Try to settle again immediately (should skip)
        vm.prank(keeperBot);
        keeper.settle(users);

        // Last settlement should be unchanged
        assertEq(keeper.lastSettlement(user1), firstSettlement, "Settlement unchanged");
    }

    function testSettleAfterInterval() public {
        address[] memory users = new address[](1);
        users[0] = user1;

        // First settlement
        vm.prank(keeperBot);
        keeper.settle(users);

        // Wait for interval to pass
        vm.warp(block.timestamp + 3601);

        // Second settlement should succeed
        vm.prank(keeperBot);
        keeper.settle(users);

        assertEq(keeper.lastSettlement(user1), block.timestamp, "Settlement updated");
    }

    function testSettleBatchTooLarge() public {
        address[] memory users = new address[](401);

        vm.prank(keeperBot);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardKeeper.BatchTooLarge.selector, 401, 400));
        keeper.settle(users);
    }

    function testSettleEmitsEvents() public {
        address[] memory users = new address[](1);
        users[0] = user1;

        vm.expectEmit(true, true, true, true);
        emit ILeaderboardKeeper.UserSettled(user1, block.timestamp);

        vm.expectEmit(true, true, true, true);
        emit ILeaderboardKeeper.BatchComplete("settle", 1, block.timestamp);

        vm.prank(keeperBot);
        keeper.settle(users);
    }

    /*//////////////////////////////////////////////////////////////
                         EMERGENCY SETTLE TESTS
      //////////////////////////////////////////////////////////////*/

    function testEmergencySettle() public {
        vm.prank(admin);
        keeper.emergencySettle(user1);

        assertEq(keeper.lastSettlement(user1), block.timestamp, "Settlement time");
    }

    function testEmergencySettleZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert();
        keeper.emergencySettle(address(0));
    }

    function testEmergencySettleOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        keeper.emergencySettle(user2);
    }

    function testEmergencySettleEmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit ILeaderboardKeeper.UserSettled(user1, block.timestamp);

        vm.prank(admin);
        keeper.emergencySettle(user1);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN TESTS
      //////////////////////////////////////////////////////////////*/

    function testSetKeeper() public {
        address newKeeper = makeAddr("newKeeper");

        vm.prank(admin);
        keeper.setKeeper(newKeeper);

        assertEq(keeper.keeper(), newKeeper, "Keeper updated");
    }

    function testSetKeeperEmitsEvent() public {
        address newKeeper = makeAddr("newKeeper");

        vm.expectEmit(true, true, true, true);
        emit ILeaderboardKeeper.KeeperUpdated(keeperBot, newKeeper);

        vm.prank(admin);
        keeper.setKeeper(newKeeper);
    }

    function testSetKeeperZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert();
        keeper.setKeeper(address(0));
    }

    function testSetKeeperOnlyOwner() public {
        address newKeeper = makeAddr("newKeeper");

        vm.prank(user1);
        vm.expectRevert();
        keeper.setKeeper(newKeeper);
    }

    function testSetMinSettlementInterval() public {
        uint256 newInterval = 7200; // 2 hours

        vm.prank(admin);
        keeper.setMinSettlementInterval(newInterval);

        assertEq(keeper.minSettlementInterval(), newInterval, "Interval updated");
    }

    function testSetMinSettlementIntervalEmitsEvent() public {
        uint256 newInterval = 7200;

        vm.expectEmit(true, true, true, true);
        emit ILeaderboardKeeper.MinSettlementIntervalUpdated(3600, newInterval);

        vm.prank(admin);
        keeper.setMinSettlementInterval(newInterval);
    }

    function testSetMinSettlementIntervalOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        keeper.setMinSettlementInterval(7200);
    }
}
