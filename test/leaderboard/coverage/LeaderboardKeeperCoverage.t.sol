// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "../unit/LeaderboardBase.sol";
import {LeaderboardKeeper} from "../../../src/leaderboard/LeaderboardKeeper.sol";
import {ILeaderboardKeeper} from "../../../src/interfaces/ILeaderboardKeeper.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @title LeaderboardKeeperCoverageTest
 * @notice Coverage-focused unit tests targeting the LeaderboardKeeper paths not exercised by
 *         test/unit/leaderboard/LeaderboardKeeper.t.sol: syncNFTBalances (all length/auth/batch
 *         branches), syncLPPositions (all six length branches + per-array revert reporting),
 *         syncMyState (success + cooldown revert), setSelfSyncCooldown, the self-sync getter, and
 *         the bare-revert renounceOwnership disablement.
 * @dev Reuses LeaderboardBase for the upgradeable proxy + DustLock/registry wiring. Asserts ONLY
 *      against the current source. syncLPPositions validates each array in order (pools, tokenIds,
 *      tickLowers, tickUppers, liquidities) and reverts ArrayLengthMismatch(users.length, badLen)
 *      reporting the actual offending array length — so when only tokenIds/tickLowers/tickUppers/
 *      liquidities differ while pools.length == users.length, the reported actual is that array's
 *      real length, not pools.length.
 */
contract LeaderboardKeeperCoverageTest is LeaderboardBase {
    LeaderboardKeeper internal keeper;

    address internal keeperBot = makeAddr("keeperBot");
    uint256 internal constant INTERVAL = 3600; // 1 hour

    function setUp() public override {
        super.setUp();

        LeaderboardKeeper keeperImpl = new LeaderboardKeeper(address(dustLock), address(nftRegistry));
        TransparentUpgradeableProxy keeperProxy =
            new TransparentUpgradeableProxy(address(keeperImpl), address(proxyAdmin), "");
        keeper = LeaderboardKeeper(address(keeperProxy));
        keeper.initialize(admin, keeperBot, INTERVAL);
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _addrs(uint256 n) internal pure returns (address[] memory arr) {
        arr = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            arr[i] = address(uint160(0x1000 + i));
        }
    }

    function _uints(uint256 n) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            arr[i] = i + 1;
        }
    }

    function _ticks(uint256 n) internal pure returns (int24[] memory arr) {
        arr = new int24[](n);
        for (uint256 i = 0; i < n; ++i) {
            arr[i] = int24(int256(i));
        }
    }

    function _liqs(uint256 n) internal pure returns (uint128[] memory arr) {
        arr = new uint128[](n);
        for (uint256 i = 0; i < n; ++i) {
            arr[i] = uint128(i + 1);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          INITIAL CONFIG / GETTERS
    //////////////////////////////////////////////////////////////*/

    function testInitialSelfSyncCooldownIsOneHour() public view {
        assertEq(keeper.selfSyncCooldown(), 1 hours, "default self-sync cooldown");
    }

    function testInitializeEmitsSelfSyncCooldownEvent() public {
        // Fresh, uninitialized proxy to capture the init-time emissions.
        LeaderboardKeeper keeperImpl = new LeaderboardKeeper(address(dustLock), address(nftRegistry));
        TransparentUpgradeableProxy keeperProxy =
            new TransparentUpgradeableProxy(address(keeperImpl), address(proxyAdmin), "");
        LeaderboardKeeper fresh = LeaderboardKeeper(address(keeperProxy));

        vm.expectEmit(true, true, false, true);
        emit ILeaderboardKeeper.KeeperUpdated(address(0), keeperBot);
        vm.expectEmit(false, false, false, true);
        emit ILeaderboardKeeper.MinSettlementIntervalUpdated(0, INTERVAL);
        vm.expectEmit(false, false, false, true);
        emit ILeaderboardKeeper.SelfSyncCooldownUpdated(0, 1 hours);

        fresh.initialize(admin, keeperBot, INTERVAL);
    }

    function testCannotReinitialize() public {
        vm.expectRevert();
        keeper.initialize(admin, keeperBot, INTERVAL);
    }

    /*//////////////////////////////////////////////////////////////
                            syncNFTBalances
    //////////////////////////////////////////////////////////////*/

    function testSyncNFTBalancesValid() public {
        address[] memory users = _addrs(2);
        address[] memory collections = new address[](2);
        collections[0] = address(nftCollection1);
        collections[1] = address(nftCollection2);
        // expectedLen = 2 * 2 = 4
        uint256[] memory balances = _uints(4);

        vm.expectEmit(true, true, false, true);
        emit ILeaderboardKeeper.NFTBalanceSynced(users[0], collections[0], balances[0], block.timestamp);
        vm.expectEmit(true, true, false, true);
        emit ILeaderboardKeeper.NFTBalanceSynced(users[0], collections[1], balances[1], block.timestamp);
        vm.expectEmit(true, true, false, true);
        emit ILeaderboardKeeper.NFTBalanceSynced(users[1], collections[0], balances[2], block.timestamp);
        vm.expectEmit(true, true, false, true);
        emit ILeaderboardKeeper.NFTBalanceSynced(users[1], collections[1], balances[3], block.timestamp);
        vm.expectEmit(false, false, false, true);
        emit ILeaderboardKeeper.BatchComplete("sync_nft", 4, block.timestamp);

        vm.prank(keeperBot);
        keeper.syncNFTBalances(users, collections, balances);
    }

    function testSyncNFTBalancesEmptyUsers() public {
        address[] memory users = new address[](0);
        address[] memory collections = _addrs(3);
        uint256[] memory balances = new uint256[](0); // 0 * 3 = 0

        vm.expectEmit(false, false, false, true);
        emit ILeaderboardKeeper.BatchComplete("sync_nft", 0, block.timestamp);

        vm.prank(keeperBot);
        keeper.syncNFTBalances(users, collections, balances);
    }

    function testSyncNFTBalancesEmptyCollections() public {
        // usersLen=3, collectionsLen=0 -> expectedLen=0, inner loop never runs.
        address[] memory users = _addrs(3);
        address[] memory collections = new address[](0);
        uint256[] memory balances = new uint256[](0);

        vm.expectEmit(false, false, false, true);
        emit ILeaderboardKeeper.BatchComplete("sync_nft", 0, block.timestamp);

        vm.prank(keeperBot);
        keeper.syncNFTBalances(users, collections, balances);
    }

    function testSyncNFTBalancesArrayLengthMismatch() public {
        address[] memory users = _addrs(2);
        address[] memory collections = _addrs(2); // expectedLen = 4
        uint256[] memory balances = _uints(3); // wrong

        vm.prank(keeperBot);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardKeeper.ArrayLengthMismatch.selector, 4, 3));
        keeper.syncNFTBalances(users, collections, balances);
    }

    function testSyncNFTBalancesBatchTooLarge() public {
        // 21 * 20 = 420 > 400. balances must match expectedLen so the batch check is the first to fire.
        address[] memory users = _addrs(21);
        address[] memory collections = _addrs(20);
        uint256[] memory balances = _uints(420);

        vm.prank(keeperBot);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardKeeper.BatchTooLarge.selector, 420, 400));
        keeper.syncNFTBalances(users, collections, balances);
    }

    function testSyncNFTBalancesOnlyKeeper() public {
        address[] memory users = _addrs(1);
        address[] memory collections = _addrs(1);
        uint256[] memory balances = _uints(1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardKeeper.NotKeeper.selector, user1));
        keeper.syncNFTBalances(users, collections, balances);
    }

    function testSyncNFTBalancesOwnerCanCall() public {
        address[] memory users = _addrs(1);
        address[] memory collections = _addrs(1);
        uint256[] memory balances = _uints(1);

        vm.prank(admin);
        keeper.syncNFTBalances(users, collections, balances);
    }

    /*//////////////////////////////////////////////////////////////
                            syncLPPositions
    //////////////////////////////////////////////////////////////*/

    function testSyncLPPositionsValid() public {
        uint256 n = 2;
        address[] memory users = _addrs(n);
        address[] memory pools = _addrs(n);
        uint256[] memory tokenIds = _uints(n);
        int24[] memory tickLowers = _ticks(n);
        int24[] memory tickUppers = _ticks(n);
        uint128[] memory liquidities = _liqs(n);

        vm.expectEmit(true, true, false, true);
        emit ILeaderboardKeeper.LPPositionSynced(
            users[0], pools[0], tokenIds[0], tickLowers[0], tickUppers[0], liquidities[0], block.timestamp
        );
        vm.expectEmit(true, true, false, true);
        emit ILeaderboardKeeper.LPPositionSynced(
            users[1], pools[1], tokenIds[1], tickLowers[1], tickUppers[1], liquidities[1], block.timestamp
        );
        vm.expectEmit(false, false, false, true);
        emit ILeaderboardKeeper.BatchComplete("sync_lp", n, block.timestamp);

        vm.prank(keeperBot);
        keeper.syncLPPositions(users, pools, tokenIds, tickLowers, tickUppers, liquidities);
    }

    function testSyncLPPositionsEmptyIsNoop() public {
        address[] memory empty = new address[](0);
        uint256[] memory emptyU = new uint256[](0);
        int24[] memory emptyT = new int24[](0);
        uint128[] memory emptyL = new uint128[](0);

        vm.expectEmit(false, false, false, true);
        emit ILeaderboardKeeper.BatchComplete("sync_lp", 0, block.timestamp);

        vm.prank(keeperBot);
        keeper.syncLPPositions(empty, empty, emptyU, emptyT, emptyT, emptyL);
    }

    /// @dev pools is the mismatched array: revert reports (len, pools.length) accurately here.
    function testSyncLPPositionsPoolsMismatch() public {
        address[] memory users = _addrs(2);
        address[] memory pools = _addrs(1); // mismatch
        uint256[] memory tokenIds = _uints(2);
        int24[] memory tickLowers = _ticks(2);
        int24[] memory tickUppers = _ticks(2);
        uint128[] memory liquidities = _liqs(2);

        vm.prank(keeperBot);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardKeeper.ArrayLengthMismatch.selector, 2, 1));
        keeper.syncLPPositions(users, pools, tokenIds, tickLowers, tickUppers, liquidities);
    }

    /**
     * @notice Confirms a tokenIds mismatch reports the offending array length
     * @dev pools matches, so the revert is (2, 1) rather than a masked (2, 2).
     */
    function testSyncLPPositionsTokenIdsMismatchReportsActualLen() public {
        address[] memory users = _addrs(2);
        address[] memory pools = _addrs(2);
        uint256[] memory tokenIds = _uints(1); // the actual mismatch
        int24[] memory tickLowers = _ticks(2);
        int24[] memory tickUppers = _ticks(2);
        uint128[] memory liquidities = _liqs(2);

        // pools matches (2); tokenIds is checked next and reports its real length 1.
        vm.prank(keeperBot);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardKeeper.ArrayLengthMismatch.selector, 2, 1));
        keeper.syncLPPositions(users, pools, tokenIds, tickLowers, tickUppers, liquidities);
    }

    /**
     * @notice Confirms a tickLowers mismatch reports the offending array length
     * @dev pools and tokenIds match, so the revert reports (3, 2).
     */
    function testSyncLPPositionsTickLowersMismatchReportsActualLen() public {
        address[] memory users = _addrs(3);
        address[] memory pools = _addrs(3);
        uint256[] memory tokenIds = _uints(3);
        int24[] memory tickLowers = _ticks(2); // mismatch
        int24[] memory tickUppers = _ticks(3);
        uint128[] memory liquidities = _liqs(3);

        vm.prank(keeperBot);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardKeeper.ArrayLengthMismatch.selector, 3, 2));
        keeper.syncLPPositions(users, pools, tokenIds, tickLowers, tickUppers, liquidities);
    }

    /**
     * @notice Confirms a tickUppers mismatch reports the offending array length
     * @dev The earlier arrays match, so the revert reports (3, 2).
     */
    function testSyncLPPositionsTickUppersMismatchReportsActualLen() public {
        address[] memory users = _addrs(3);
        address[] memory pools = _addrs(3);
        uint256[] memory tokenIds = _uints(3);
        int24[] memory tickLowers = _ticks(3);
        int24[] memory tickUppers = _ticks(2); // mismatch
        uint128[] memory liquidities = _liqs(3);

        vm.prank(keeperBot);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardKeeper.ArrayLengthMismatch.selector, 3, 2));
        keeper.syncLPPositions(users, pools, tokenIds, tickLowers, tickUppers, liquidities);
    }

    /**
     * @notice Confirms a liquidities mismatch reports the offending array length
     * @dev All earlier arrays match, so the final array check reports (3, 2).
     */
    function testSyncLPPositionsLiquiditiesMismatchReportsActualLen() public {
        address[] memory users = _addrs(3);
        address[] memory pools = _addrs(3);
        uint256[] memory tokenIds = _uints(3);
        int24[] memory tickLowers = _ticks(3);
        int24[] memory tickUppers = _ticks(3);
        uint128[] memory liquidities = _liqs(2); // mismatch

        vm.prank(keeperBot);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardKeeper.ArrayLengthMismatch.selector, 3, 2));
        keeper.syncLPPositions(users, pools, tokenIds, tickLowers, tickUppers, liquidities);
    }

    function testSyncLPPositionsBatchTooLarge() public {
        uint256 n = 401;
        address[] memory users = _addrs(n);
        address[] memory pools = _addrs(n);
        uint256[] memory tokenIds = _uints(n);
        int24[] memory tickLowers = _ticks(n);
        int24[] memory tickUppers = _ticks(n);
        uint128[] memory liquidities = _liqs(n);

        vm.prank(keeperBot);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardKeeper.BatchTooLarge.selector, 401, 400));
        keeper.syncLPPositions(users, pools, tokenIds, tickLowers, tickUppers, liquidities);
    }

    function testSyncLPPositionsOnlyKeeper() public {
        uint256 n = 1;
        address[] memory users = _addrs(n);
        address[] memory pools = _addrs(n);
        uint256[] memory tokenIds = _uints(n);
        int24[] memory tickLowers = _ticks(n);
        int24[] memory tickUppers = _ticks(n);
        uint128[] memory liquidities = _liqs(n);

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardKeeper.NotKeeper.selector, user2));
        keeper.syncLPPositions(users, pools, tokenIds, tickLowers, tickUppers, liquidities);
    }

    function testSyncLPPositionsOwnerCanCall() public {
        uint256 n = 1;
        address[] memory users = _addrs(n);
        address[] memory pools = _addrs(n);
        uint256[] memory tokenIds = _uints(n);
        int24[] memory tickLowers = _ticks(n);
        int24[] memory tickUppers = _ticks(n);
        uint128[] memory liquidities = _liqs(n);

        vm.prank(admin);
        keeper.syncLPPositions(users, pools, tokenIds, tickLowers, tickUppers, liquidities);
    }

    /*//////////////////////////////////////////////////////////////
                              syncMyState
    //////////////////////////////////////////////////////////////*/

    function testSyncMyStateFirstCallSucceeds() public {
        // lastSettlement[user1] == 0; block.timestamp >= 0 + cooldown holds after the warmup skip.
        vm.recordLogs();

        vm.prank(user1);
        keeper.syncMyState();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "self-sync must emit only settlement");
        assertEq(logs[0].emitter, address(keeper), "unexpected settlement emitter");
        assertEq(logs[0].topics.length, 2, "unexpected settlement topic count");
        assertEq(logs[0].topics[0], keccak256("UserSettled(address,uint256)"), "unexpected event selector");
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(user1))), "unexpected settled user");
        assertEq(abi.decode(logs[0].data, (uint256)), block.timestamp, "unexpected settlement timestamp");
        assertEq(keeper.lastSettlement(user1), block.timestamp, "settlement recorded");
    }

    function testSyncMyStateCooldownRevert() public {
        // First sync sets lastSettlement = now.
        vm.prank(user1);
        keeper.syncMyState();

        uint256 lastSync = keeper.lastSettlement(user1);
        /*
         * Read the cooldown up front. An external call between prank and the target would
         * consume the prank and run syncMyState as the test contract instead of user1.
         */
        uint256 cooldown = keeper.selfSyncCooldown();

        // Advance partway through the cooldown so the gate fires with a non-zero elapsed.
        uint256 elapsed = 100;
        vm.warp(lastSync + elapsed);

        bytes memory expectedRevert =
            abi.encodeWithSelector(ILeaderboardKeeper.CooldownNotElapsed.selector, user1, elapsed, cooldown);

        vm.prank(user1);
        vm.expectRevert(expectedRevert);
        keeper.syncMyState();
    }

    function testSyncMyStateSucceedsAfterCooldown() public {
        vm.prank(user1);
        keeper.syncMyState();

        vm.warp(block.timestamp + keeper.selfSyncCooldown() + 1);

        vm.prank(user1);
        keeper.syncMyState();

        assertEq(keeper.lastSettlement(user1), block.timestamp, "settlement updated after cooldown");
    }

    function testSyncMyStateBoundaryExactCooldownSucceeds() public {
        vm.prank(user1);
        keeper.syncMyState();

        // Exactly at lastSync + cooldown: block.timestamp < lastSync + cooldown is false -> allowed.
        vm.warp(keeper.lastSettlement(user1) + keeper.selfSyncCooldown());

        vm.prank(user1);
        keeper.syncMyState();

        assertEq(keeper.lastSettlement(user1), block.timestamp, "boundary sync allowed");
    }

    /*//////////////////////////////////////////////////////////////
                          setSelfSyncCooldown
    //////////////////////////////////////////////////////////////*/

    function testSetSelfSyncCooldown() public {
        vm.prank(admin);
        keeper.setSelfSyncCooldown(7200);

        assertEq(keeper.selfSyncCooldown(), 7200, "cooldown updated");
    }

    function testSetSelfSyncCooldownEmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit ILeaderboardKeeper.SelfSyncCooldownUpdated(1 hours, 30 minutes);

        vm.prank(admin);
        keeper.setSelfSyncCooldown(30 minutes);
    }

    function testSetSelfSyncCooldownOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert("Ownable: caller is not the owner");
        keeper.setSelfSyncCooldown(7200);
    }

    function testSetSelfSyncCooldownToZeroDisablesCooldown() public {
        vm.prank(admin);
        keeper.setSelfSyncCooldown(0);

        // First sync.
        vm.prank(user1);
        keeper.syncMyState();

        /*
         * With cooldown 0, an immediate second sync in the same block is allowed because
         * block.timestamp < lastSync + 0 is false.
         */
        vm.prank(user1);
        keeper.syncMyState();

        assertEq(keeper.lastSettlement(user1), block.timestamp, "repeat sync allowed with zero cooldown");
    }

    /*//////////////////////////////////////////////////////////////
                  KEEPER AUTH ON syncVotingPower (owner path)
    //////////////////////////////////////////////////////////////*/

    function testSetKeeperThenNewKeeperCanSync() public {
        address newKeeper = makeAddr("newKeeper");

        vm.prank(admin);
        keeper.setKeeper(newKeeper);
        assertEq(keeper.keeper(), newKeeper, "keeper rotated");

        // Old keeper bot is no longer authorized.
        address[] memory users = _addrs(1);
        uint256[] memory vps = _uints(1);
        vm.prank(keeperBot);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardKeeper.NotKeeper.selector, keeperBot));
        keeper.syncVotingPower(users, vps);

        // New keeper is authorized.
        vm.prank(newKeeper);
        keeper.syncVotingPower(users, vps);
    }

    /*//////////////////////////////////////////////////////////////
                          renounceOwnership
    //////////////////////////////////////////////////////////////*/

    /// @dev Disabled via a BARE `revert()` for the owner.
    function testRenounceOwnershipRevertsForOwner() public {
        vm.prank(admin);
        vm.expectRevert();
        keeper.renounceOwnership();

        assertEq(keeper.owner(), admin, "owner unchanged");
    }

    function testRenounceOwnershipRevertsForNonOwner() public {
        vm.prank(user1);
        vm.expectRevert("Ownable: caller is not the owner");
        keeper.renounceOwnership();

        assertEq(keeper.owner(), admin, "owner unchanged");
    }
}
