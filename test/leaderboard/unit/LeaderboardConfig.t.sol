// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ILeaderboardConfig} from "../../../src/interfaces/ILeaderboardConfig.sol";
import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";
import {LeaderboardConfig} from "../../../src/leaderboard/LeaderboardConfig.sol";

import "./LeaderboardBase.sol";

contract LeaderboardConfigTest is LeaderboardBase {
    function testInitialConfiguration() public view {
        assertEq(leaderboardConfig.depositRateBps(), DEPOSIT_RATE, "Initial deposit rate");
        assertEq(leaderboardConfig.borrowRateBps(), BORROW_RATE, "Initial borrow rate");
        assertEq(leaderboardConfig.vpRateBps(), VP_RATE, "Initial VP rate");
        assertEq(leaderboardConfig.supplyDailyBonus(), SUPPLY_BONUS, "Initial supply bonus");
        assertEq(leaderboardConfig.borrowDailyBonus(), BORROW_BONUS, "Initial borrow bonus");
        assertEq(leaderboardConfig.repayDailyBonus(), 0, "Initial repay bonus");
        assertEq(leaderboardConfig.withdrawDailyBonus(), 0, "Initial withdraw bonus");
        assertEq(leaderboardConfig.cooldownSeconds(), COOLDOWN, "Initial cooldown");
        assertEq(leaderboardConfig.minDailyBonusUsd(), MIN_DAILY_BONUS_USD, "Initial min daily bonus USD");

        // Check constants
        assertEq(leaderboardConfig.MAX_RATE_BPS(), 10_000, "Max rate should be 10000 bps");
        assertEq(leaderboardConfig.MAX_DAILY_BONUS(), 1000e18, "Max daily bonus should be 1000e18");
        assertEq(leaderboardConfig.MAX_COOLDOWN_SECONDS(), 86_400, "Max cooldown should be 24 hours");
    }

    function testSetDepositRate() public {
        uint256 newRate = 200; // 0.02 per USD/day

        vm.prank(admin);
        leaderboardConfig.setDepositRate(newRate);

        assertEq(leaderboardConfig.depositRateBps(), newRate, "Deposit rate should be updated");

        // Other configs should remain unchanged
        assertEq(leaderboardConfig.borrowRateBps(), BORROW_RATE, "Borrow rate unchanged");
    }

    function testSetDepositRateTooHigh() public {
        uint256 tooHigh = 10_001;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardConfig.RateTooHigh.selector, tooHigh));
        leaderboardConfig.setDepositRate(tooHigh);
    }

    function testSetDepositRateOnlyOwner() public {
        vm.prank(user1);
        _expectOwnableCallerNotOwnerRevert();
        leaderboardConfig.setDepositRate(200);
    }

    function testSetBorrowRate() public {
        uint256 newRate = 1000; // 0.1 per USD/day

        vm.prank(admin);
        leaderboardConfig.setBorrowRate(newRate);

        assertEq(leaderboardConfig.borrowRateBps(), newRate, "Borrow rate should be updated");
    }

    function testSetDailyBonuses() public {
        uint256 newSupply = 50e18;
        uint256 newBorrow = 100e18;
        uint256 newRepay = 15e18;
        uint256 newWithdraw = 5e18;

        vm.prank(admin);
        leaderboardConfig.setDailyBonuses(newSupply, newBorrow, newRepay, newWithdraw);

        assertEq(leaderboardConfig.supplyDailyBonus(), newSupply, "Supply bonus updated");
        assertEq(leaderboardConfig.borrowDailyBonus(), newBorrow, "Borrow bonus updated");
        assertEq(leaderboardConfig.repayDailyBonus(), newRepay, "Repay bonus updated");
        assertEq(leaderboardConfig.withdrawDailyBonus(), newWithdraw, "Withdraw bonus updated");
    }

    function testSetDailyBonusesTooHigh() public {
        uint256 tooHigh = 1001e18;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardConfig.BonusTooHigh.selector, tooHigh));
        leaderboardConfig.setDailyBonuses(tooHigh, 20e18, 0, 0);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardConfig.BonusTooHigh.selector, tooHigh));
        leaderboardConfig.setDailyBonuses(10e18, tooHigh, 0, 0);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardConfig.BonusTooHigh.selector, tooHigh));
        leaderboardConfig.setDailyBonuses(10e18, 20e18, tooHigh, 0);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardConfig.BonusTooHigh.selector, tooHigh));
        leaderboardConfig.setDailyBonuses(10e18, 20e18, 0, tooHigh);
    }

    function testSetCooldown() public {
        uint256 newCooldown = 7200; // 2 hours

        vm.prank(admin);
        leaderboardConfig.setCooldown(newCooldown);

        assertEq(leaderboardConfig.cooldownSeconds(), newCooldown, "Cooldown updated");
    }

    function testSetCooldownTooLong() public {
        uint256 tooLong = 86_401; // > 24 hours

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardConfig.CooldownTooLong.selector, tooLong));
        leaderboardConfig.setCooldown(tooLong);
    }

    function testSetMinDailyBonusUsd() public {
        uint256 newMin = 500e18; // $500

        vm.prank(admin);
        leaderboardConfig.setMinDailyBonusUsd(newMin);

        assertEq(leaderboardConfig.minDailyBonusUsd(), newMin, "Min daily bonus USD updated");
    }

    function testUpdateAllRates() public {
        uint256 newDepositRate = 150;
        uint256 newBorrowRate = 750;
        uint256 newSupplyBonus = 25e18;
        uint256 newBorrowBonus = 50e18;

        vm.prank(admin);
        leaderboardConfig.updateAllRates(newDepositRate, newBorrowRate, 200, newSupplyBonus, newBorrowBonus);

        assertEq(leaderboardConfig.depositRateBps(), newDepositRate, "Deposit rate updated");
        assertEq(leaderboardConfig.borrowRateBps(), newBorrowRate, "Borrow rate updated");
        assertEq(leaderboardConfig.supplyDailyBonus(), newSupplyBonus, "Supply bonus updated");
        assertEq(leaderboardConfig.borrowDailyBonus(), newBorrowBonus, "Borrow bonus updated");

        // Cooldown and min bonus should be unchanged
        assertEq(leaderboardConfig.cooldownSeconds(), COOLDOWN, "Cooldown unchanged");
        assertEq(leaderboardConfig.minDailyBonusUsd(), MIN_DAILY_BONUS_USD, "Min bonus unchanged");
    }

    function testUpdateAllRatesWithInvalidValues() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardConfig.RateTooHigh.selector, 10_001));
        leaderboardConfig.updateAllRates(10_001, 500, 200, 10e18, 20e18);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardConfig.RateTooHigh.selector, 10_001));
        leaderboardConfig.updateAllRates(100, 10_001, 200, 10e18, 20e18);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardConfig.BonusTooHigh.selector, 1001e18));
        leaderboardConfig.updateAllRates(100, 500, 200, 1001e18, 20e18);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardConfig.BonusTooHigh.selector, 1001e18));
        leaderboardConfig.updateAllRates(100, 500, 200, 10e18, 1001e18);
    }

    function testGetDepositRatePerDay() public view {
        uint256 rate = leaderboardConfig.getDepositRatePerDay();
        assertEq(rate, DEPOSIT_RATE, "Should return deposit rate");
    }

    function testGetBorrowRatePerDay() public view {
        uint256 rate = leaderboardConfig.getBorrowRatePerDay();
        assertEq(rate, BORROW_RATE, "Should return borrow rate");
    }

    function testGetDailyBonuses() public view {
        (uint256 supply, uint256 borrow, uint256 repay, uint256 withdraw) = leaderboardConfig.getDailyBonuses();
        assertEq(supply, SUPPLY_BONUS, "Should return supply bonus");
        assertEq(borrow, BORROW_BONUS, "Should return borrow bonus");
        assertEq(repay, 0, "Should return repay bonus");
        assertEq(withdraw, 0, "Should return withdraw bonus");
    }

    function testGetAllConfig() public view {
        (
            uint256 depositRate,
            uint256 borrowRate,
            uint256 vpRate,
            uint256 supplyBonus,
            uint256 borrowBonus,
            uint256 repayBonus,
            uint256 withdrawBonus,
            uint256 cooldown,
            uint256 minUsd
        ) = leaderboardConfig.getAllConfig();

        assertEq(depositRate, DEPOSIT_RATE, "Deposit rate");
        assertEq(borrowRate, BORROW_RATE, "Borrow rate");
        assertEq(vpRate, VP_RATE, "VP rate");
        assertEq(supplyBonus, SUPPLY_BONUS, "Supply bonus");
        assertEq(borrowBonus, BORROW_BONUS, "Borrow bonus");
        assertEq(repayBonus, 0, "Repay bonus");
        assertEq(withdrawBonus, 0, "Withdraw bonus");
        assertEq(cooldown, COOLDOWN, "Cooldown");
        assertEq(minUsd, MIN_DAILY_BONUS_USD, "Min USD");
    }

    function testConfigSnapshotEmitted() public {
        // Updating a rate must emit ConfigSnapshot with the full post-update state.
        uint256 newRate = 200;

        vm.expectEmit(true, true, true, true);
        emit ILeaderboardConfig.ConfigSnapshot(
            newRate,
            BORROW_RATE,
            VP_RATE,
            SUPPLY_BONUS,
            BORROW_BONUS,
            0,
            0,
            COOLDOWN,
            MIN_DAILY_BONUS_USD,
            block.timestamp
        );

        vm.prank(admin);
        leaderboardConfig.setDepositRate(newRate);

        assertEq(leaderboardConfig.depositRateBps(), newRate, "Rate updated");
    }

    function testDeterministicRateCalculations() public {
        // Set specific rates
        vm.prank(admin);
        leaderboardConfig.updateAllRates(
            100, // 0.01 per USD/day = 1 point per 100 USD per day
            500, // 0.05 per USD/day = 5 points per 100 USD per day
            200, // 0.02 per veDUST/day = 2 points per 100 veDUST per day
            15e18, // 15 points/day
            30e18 // 30 points/day
        );

        assertEq(leaderboardConfig.depositRateBps(), 100, "Deposit: 100 bps");
        assertEq(leaderboardConfig.borrowRateBps(), 500, "Borrow: 500 bps");
        assertEq(leaderboardConfig.vpRateBps(), 200, "VP: 200 bps");
        assertEq(leaderboardConfig.supplyDailyBonus(), 15e18, "Supply bonus: 15");
        assertEq(leaderboardConfig.borrowDailyBonus(), 30e18, "Borrow bonus: 30");

        // Example calculation:
        // User has $10,000 supplied
        // Points per day = 10000 * 100 / 10000 = 100 points/day
        // Plus bonus = 15 points/day
        // Total = 115 points/day (before multipliers)
    }

    function testInitializeRejectsInvalidValues() public {
        _expectInitializeRevert(
            10_001,
            BORROW_RATE,
            VP_RATE,
            SUPPLY_BONUS,
            BORROW_BONUS,
            0,
            0,
            COOLDOWN,
            abi.encodeWithSelector(ILeaderboardConfig.RateTooHigh.selector, 10_001)
        );
        _expectInitializeRevert(
            DEPOSIT_RATE,
            10_001,
            VP_RATE,
            SUPPLY_BONUS,
            BORROW_BONUS,
            0,
            0,
            COOLDOWN,
            abi.encodeWithSelector(ILeaderboardConfig.RateTooHigh.selector, 10_001)
        );
        _expectInitializeRevert(
            DEPOSIT_RATE,
            BORROW_RATE,
            10_001,
            SUPPLY_BONUS,
            BORROW_BONUS,
            0,
            0,
            COOLDOWN,
            abi.encodeWithSelector(ILeaderboardConfig.RateTooHigh.selector, 10_001)
        );
        _expectInitializeRevert(
            DEPOSIT_RATE,
            BORROW_RATE,
            VP_RATE,
            1001e18,
            BORROW_BONUS,
            0,
            0,
            COOLDOWN,
            abi.encodeWithSelector(ILeaderboardConfig.BonusTooHigh.selector, 1001e18)
        );
        _expectInitializeRevert(
            DEPOSIT_RATE,
            BORROW_RATE,
            VP_RATE,
            SUPPLY_BONUS,
            1001e18,
            0,
            0,
            COOLDOWN,
            abi.encodeWithSelector(ILeaderboardConfig.BonusTooHigh.selector, 1001e18)
        );
        _expectInitializeRevert(
            DEPOSIT_RATE,
            BORROW_RATE,
            VP_RATE,
            SUPPLY_BONUS,
            BORROW_BONUS,
            1001e18,
            0,
            COOLDOWN,
            abi.encodeWithSelector(ILeaderboardConfig.BonusTooHigh.selector, 1001e18)
        );
        _expectInitializeRevert(
            DEPOSIT_RATE,
            BORROW_RATE,
            VP_RATE,
            SUPPLY_BONUS,
            BORROW_BONUS,
            0,
            1001e18,
            COOLDOWN,
            abi.encodeWithSelector(ILeaderboardConfig.BonusTooHigh.selector, 1001e18)
        );
        _expectInitializeRevert(
            DEPOSIT_RATE,
            BORROW_RATE,
            VP_RATE,
            SUPPLY_BONUS,
            BORROW_BONUS,
            0,
            0,
            86_401,
            abi.encodeWithSelector(ILeaderboardConfig.CooldownTooLong.selector, 86_401)
        );
    }

    function testVpBorrowAndUpdateAllRateReverts() public {
        vm.prank(admin);
        leaderboardConfig.setVpRate(333);
        assertEq(leaderboardConfig.getVpRatePerDay(), 333, "VP rate updated");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardConfig.RateTooHigh.selector, 10_001));
        leaderboardConfig.setVpRate(10_001);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardConfig.RateTooHigh.selector, 10_001));
        leaderboardConfig.setBorrowRate(10_001);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardConfig.RateTooHigh.selector, 10_001));
        leaderboardConfig.updateAllRates(100, 500, 10_001, 10e18, 20e18);
    }

    function testManualPointsAndBatchReverts() public {
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        uint256[] memory points = new uint256[](2);
        points[0] = 1e18;
        points[1] = 2e18;

        vm.startPrank(admin);
        leaderboardConfig.awardPoints(user1, 1e18, "award");
        leaderboardConfig.removePoints(user1, 1e18, "remove");
        leaderboardConfig.batchAwardPoints(users, points, "batch award");
        leaderboardConfig.batchRemovePoints(users, points, "batch remove");

        uint256[] memory shortPoints = new uint256[](1);
        vm.expectRevert(bytes("Array length mismatch"));
        leaderboardConfig.batchAwardPoints(users, shortPoints, "mismatch");
        vm.expectRevert(bytes("Array length mismatch"));
        leaderboardConfig.batchRemovePoints(users, shortPoints, "mismatch");

        address[] memory emptyUsers = new address[](0);
        uint256[] memory emptyPoints = new uint256[](0);
        vm.expectRevert(bytes("Empty arrays"));
        leaderboardConfig.batchAwardPoints(emptyUsers, emptyPoints, "empty");
        vm.expectRevert(bytes("Empty arrays"));
        leaderboardConfig.batchRemovePoints(emptyUsers, emptyPoints, "empty");

        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        leaderboardConfig.awardPoints(address(0), 1e18, "zero");
        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        leaderboardConfig.removePoints(address(0), 1e18, "zero");
        vm.stopPrank();
    }

    function testLpPoolConfigurationLifecycle() public {
        address pool = makeAddr("pool");
        address manager = makeAddr("positionManager");
        address token0 = makeAddr("token0");
        address token1 = makeAddr("token1");

        vm.startPrank(admin);
        leaderboardConfig.configureLPPool(pool, manager, token0, token1, 123);
        assertEq(leaderboardConfig.getLPPoolCount(), 1, "LP pool count");

        (address savedManager, address savedToken0, address savedToken1, uint256 lpRateBps, bool isActive) =
            leaderboardConfig.getLPPoolConfig(pool);
        assertEq(savedManager, manager, "manager");
        assertEq(savedToken0, token0, "token0");
        assertEq(savedToken1, token1, "token1");
        assertEq(lpRateBps, 123, "rate");
        assertTrue(isActive, "active");

        leaderboardConfig.configureLPPool(pool, manager, token0, token1, 456);
        assertEq(leaderboardConfig.getLPPoolCount(), 1, "Reconfigure does not duplicate pool");

        leaderboardConfig.setLPRate(pool, 789);
        (,,, lpRateBps, isActive) = leaderboardConfig.getLPPoolConfig(pool);
        assertEq(lpRateBps, 789, "updated LP rate");
        assertTrue(isActive, "still active");

        vm.expectRevert(abi.encodeWithSelector(ILeaderboardConfig.RateTooHigh.selector, 10_001));
        leaderboardConfig.setLPRate(pool, 10_001);

        address[] memory pools = leaderboardConfig.getConfiguredLPPools();
        assertEq(pools.length, 1, "configured pools length");
        assertEq(pools[0], pool, "configured pool");

        leaderboardConfig.disableLPPool(pool);
        (,,,, isActive) = leaderboardConfig.getLPPoolConfig(pool);
        assertFalse(isActive, "disabled");

        vm.expectRevert(abi.encodeWithSelector(ILeaderboardConfig.LPPoolNotConfigured.selector, pool));
        leaderboardConfig.disableLPPool(pool);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardConfig.LPPoolNotConfigured.selector, pool));
        leaderboardConfig.setLPRate(pool, 1);
        vm.expectRevert(abi.encodeWithSelector(ILeaderboardConfig.RateTooHigh.selector, 10_001));
        leaderboardConfig.configureLPPool(makeAddr("pool2"), manager, token0, token1, 10_001);
        vm.stopPrank();
    }

    function testBlacklistLifecycleAndViews() public {
        address[] memory accounts = new address[](2);
        accounts[0] = user1;
        accounts[1] = user2;

        vm.startPrank(admin);
        leaderboardConfig.addToBlacklist(user1);
        assertTrue(leaderboardConfig.isBlacklisted(user1), "user1 blacklisted");
        assertEq(leaderboardConfig.getBlacklistCount(), 1, "one blacklisted");

        vm.expectRevert(abi.encodeWithSelector(ILeaderboardConfig.AlreadyBlacklisted.selector, user1));
        leaderboardConfig.addToBlacklist(user1);

        leaderboardConfig.removeFromBlacklist(user1);
        assertFalse(leaderboardConfig.isBlacklisted(user1), "user1 removed");

        vm.expectRevert(abi.encodeWithSelector(ILeaderboardConfig.NotBlacklisted.selector, user1));
        leaderboardConfig.removeFromBlacklist(user1);

        leaderboardConfig.addToBlacklistBatch(accounts);
        address[] memory blacklisted = leaderboardConfig.getBlacklistedAddresses();
        assertEq(blacklisted.length, 2, "batch added");
        assertTrue(leaderboardConfig.isBlacklisted(user2), "user2 blacklisted");

        address[] memory removeAccounts = new address[](2);
        removeAccounts[0] = user2;
        removeAccounts[1] = user1;
        leaderboardConfig.removeFromBlacklistBatch(removeAccounts);
        assertEq(leaderboardConfig.getBlacklistCount(), 0, "batch removed");

        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        leaderboardConfig.addToBlacklist(address(0));
        vm.stopPrank();
    }

    function testRenounceOwnershipReverts() public {
        vm.prank(admin);
        vm.expectRevert(bytes(""));
        leaderboardConfig.renounceOwnership();
    }

    function _expectOwnableCallerNotOwnerRevert() internal {
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("Error(string)")), "Ownable: caller is not the owner"));
    }

    function _expectInitializeRevert(
        uint256 depositRate,
        uint256 borrowRate,
        uint256 vpRate,
        uint256 supplyBonus,
        uint256 borrowBonus,
        uint256 repayBonus,
        uint256 withdrawBonus,
        uint256 cooldown,
        bytes memory expectedRevert
    ) internal {
        LeaderboardConfig config = LeaderboardConfig(_deployProxy(address(new LeaderboardConfig())));
        vm.expectRevert(expectedRevert);
        config.initialize(
            admin,
            depositRate,
            borrowRate,
            vpRate,
            supplyBonus,
            borrowBonus,
            repayBonus,
            withdrawBonus,
            cooldown,
            MIN_DAILY_BONUS_USD
        );
    }
}
