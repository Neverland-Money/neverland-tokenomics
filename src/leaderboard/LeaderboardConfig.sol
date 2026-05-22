// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {CommonChecksLibrary} from "../libraries/CommonChecksLibrary.sol";
import {ILeaderboardConfig} from "../interfaces/ILeaderboardConfig.sol";

/**
 * @title LeaderboardConfig
 * @author Neverland
 * @notice Dynamic configuration for leaderboard point accrual rates
 * @dev Emits events that the subgraph listens to for rate changes
 * @custom:oz-upgrades-unsafe-allow constructor
 */
contract LeaderboardConfig is ILeaderboardConfig, OwnableUpgradeable {
    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum rate allowed (1.0 per day = 10000 basis points)
    uint256 public constant MAX_RATE_BPS = 10_000;

    /// @notice Maximum daily bonus (1000 points)
    uint256 public constant MAX_DAILY_BONUS = 1000e18;

    /// @notice Maximum cooldown (24 hours)
    uint256 public constant MAX_COOLDOWN_SECONDS = 86_400;

    /*//////////////////////////////////////////////////////////////
                          STORAGE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit point rate in basis points per day per USD (100 = 0.01)
    uint256 public depositRateBps;

    /// @notice Borrow point rate in basis points per day per USD (500 = 0.05)
    uint256 public borrowRateBps;

    /// @notice VP point rate in basis points per day per 1e18 VP
    uint256 public vpRateBps;

    /// @notice Supply daily bonus in points (18 decimals)
    uint256 public supplyDailyBonus;

    /// @notice Borrow daily bonus in points (18 decimals)
    uint256 public borrowDailyBonus;

    /// @notice Repay daily bonus in points (18 decimals)
    uint256 public repayDailyBonus;

    /// @notice Withdraw daily bonus in points (18 decimals)
    uint256 public withdrawDailyBonus;

    /// @notice Cooldown period in seconds before settling inactive reserves
    uint256 public cooldownSeconds;

    /// @notice Minimum USD value required for daily bonus eligibility (18 decimals)
    uint256 public minDailyBonusUsd;

    /// @notice Mapping of pool address to LP configuration
    mapping(address => LpPoolConfig) public lpPoolConfigs;

    /// @notice Array of configured LP pool addresses
    address[] public configuredLPPools;

    /// @notice Mapping of address to blacklist status
    mapping(address => bool) private _blacklisted;

    /// @notice Array of blacklisted addresses
    address[] private _blacklistedAddresses;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Disables initializers on the implementation contract
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize configuration with initial values
     * @param _initialOwner Initial owner for Ownable
     * @param _depositRateBps Initial deposit rate (100 = 0.01)
     * @param _borrowRateBps Initial borrow rate (500 = 0.05)
     * @param _vpRateBps Initial VP rate (per 1e18 VP)
     * @param _supplyDailyBonus Initial supply bonus (10e18 = 10 points)
     * @param _borrowDailyBonus Initial borrow bonus (20e18 = 20 points)
     * @param _repayDailyBonus Initial repay bonus (0 = disabled)
     * @param _withdrawDailyBonus Initial withdraw bonus (0 = disabled)
     * @param _cooldownSeconds Initial cooldown (3600 = 1 hour)
     * @param _minDailyBonusUsd Initial minimum USD (0 = disabled)
     */
    function initialize(
        address _initialOwner,
        uint256 _depositRateBps,
        uint256 _borrowRateBps,
        uint256 _vpRateBps,
        uint256 _supplyDailyBonus,
        uint256 _borrowDailyBonus,
        uint256 _repayDailyBonus,
        uint256 _withdrawDailyBonus,
        uint256 _cooldownSeconds,
        uint256 _minDailyBonusUsd
    ) external initializer {
        __Ownable_init();
        _transferOwnership(_initialOwner);
        CommonChecksLibrary.revertIfZeroAddress(_initialOwner);

        if (_depositRateBps > MAX_RATE_BPS) revert RateTooHigh(_depositRateBps);
        if (_borrowRateBps > MAX_RATE_BPS) revert RateTooHigh(_borrowRateBps);
        if (_vpRateBps > MAX_RATE_BPS) revert RateTooHigh(_vpRateBps);
        if (_supplyDailyBonus > MAX_DAILY_BONUS) {
            revert BonusTooHigh(_supplyDailyBonus);
        }
        if (_borrowDailyBonus > MAX_DAILY_BONUS) {
            revert BonusTooHigh(_borrowDailyBonus);
        }
        if (_repayDailyBonus > MAX_DAILY_BONUS) {
            revert BonusTooHigh(_repayDailyBonus);
        }
        if (_withdrawDailyBonus > MAX_DAILY_BONUS) {
            revert BonusTooHigh(_withdrawDailyBonus);
        }
        if (_cooldownSeconds > MAX_COOLDOWN_SECONDS) {
            revert CooldownTooLong(_cooldownSeconds);
        }

        depositRateBps = _depositRateBps;
        borrowRateBps = _borrowRateBps;
        vpRateBps = _vpRateBps;
        supplyDailyBonus = _supplyDailyBonus;
        borrowDailyBonus = _borrowDailyBonus;
        repayDailyBonus = _repayDailyBonus;
        withdrawDailyBonus = _withdrawDailyBonus;
        cooldownSeconds = _cooldownSeconds;
        minDailyBonusUsd = _minDailyBonusUsd;

        emit DepositRateUpdated(0, _depositRateBps, block.timestamp);
        emit BorrowRateUpdated(0, _borrowRateBps, block.timestamp);
        emit VpRateUpdated(0, _vpRateBps, block.timestamp);
        emit DailyBonusUpdated(
            0, _supplyDailyBonus, 0, _borrowDailyBonus, 0, _repayDailyBonus, 0, _withdrawDailyBonus, block.timestamp
        );
        emit CooldownUpdated(0, _cooldownSeconds, block.timestamp);
        emit MinDailyBonusUsdUpdated(0, _minDailyBonusUsd, block.timestamp);
        emit ConfigSnapshot(
            _depositRateBps,
            _borrowRateBps,
            _vpRateBps,
            _supplyDailyBonus,
            _borrowDailyBonus,
            _repayDailyBonus,
            _withdrawDailyBonus,
            _cooldownSeconds,
            _minDailyBonusUsd,
            block.timestamp
        );
    }

    /*//////////////////////////////////////////////////////////////
                               ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILeaderboardConfig
    function setDepositRate(uint256 newRateBps) external onlyOwner {
        if (newRateBps > MAX_RATE_BPS) revert RateTooHigh(newRateBps);
        uint256 oldRate = depositRateBps;
        depositRateBps = newRateBps;
        emit DepositRateUpdated(oldRate, newRateBps, block.timestamp);
        emit ConfigSnapshot(
            depositRateBps,
            borrowRateBps,
            vpRateBps,
            supplyDailyBonus,
            borrowDailyBonus,
            repayDailyBonus,
            withdrawDailyBonus,
            cooldownSeconds,
            minDailyBonusUsd,
            block.timestamp
        );
    }

    /// @inheritdoc ILeaderboardConfig
    function setBorrowRate(uint256 newRateBps) external onlyOwner {
        if (newRateBps > MAX_RATE_BPS) revert RateTooHigh(newRateBps);
        uint256 oldRate = borrowRateBps;
        borrowRateBps = newRateBps;
        emit BorrowRateUpdated(oldRate, newRateBps, block.timestamp);
        emit ConfigSnapshot(
            depositRateBps,
            borrowRateBps,
            vpRateBps,
            supplyDailyBonus,
            borrowDailyBonus,
            repayDailyBonus,
            withdrawDailyBonus,
            cooldownSeconds,
            minDailyBonusUsd,
            block.timestamp
        );
    }

    /// @inheritdoc ILeaderboardConfig
    function setVpRate(uint256 newRateBps) external onlyOwner {
        if (newRateBps > MAX_RATE_BPS) revert RateTooHigh(newRateBps);
        uint256 oldRate = vpRateBps;
        vpRateBps = newRateBps;
        emit VpRateUpdated(oldRate, newRateBps, block.timestamp);
        emit ConfigSnapshot(
            depositRateBps,
            borrowRateBps,
            vpRateBps,
            supplyDailyBonus,
            borrowDailyBonus,
            repayDailyBonus,
            withdrawDailyBonus,
            cooldownSeconds,
            minDailyBonusUsd,
            block.timestamp
        );
    }

    /// @inheritdoc ILeaderboardConfig
    function setDailyBonuses(uint256 supply, uint256 borrow, uint256 repay, uint256 withdraw) external onlyOwner {
        if (supply > MAX_DAILY_BONUS) revert BonusTooHigh(supply);
        if (borrow > MAX_DAILY_BONUS) revert BonusTooHigh(borrow);
        if (repay > MAX_DAILY_BONUS) revert BonusTooHigh(repay);
        if (withdraw > MAX_DAILY_BONUS) revert BonusTooHigh(withdraw);
        uint256 oldSupply = supplyDailyBonus;
        uint256 oldBorrow = borrowDailyBonus;
        uint256 oldRepay = repayDailyBonus;
        uint256 oldWithdraw = withdrawDailyBonus;
        supplyDailyBonus = supply;
        borrowDailyBonus = borrow;
        repayDailyBonus = repay;
        withdrawDailyBonus = withdraw;
        emit DailyBonusUpdated(
            oldSupply, supply, oldBorrow, borrow, oldRepay, repay, oldWithdraw, withdraw, block.timestamp
        );
        emit ConfigSnapshot(
            depositRateBps,
            borrowRateBps,
            vpRateBps,
            supplyDailyBonus,
            borrowDailyBonus,
            repayDailyBonus,
            withdrawDailyBonus,
            cooldownSeconds,
            minDailyBonusUsd,
            block.timestamp
        );
    }

    /// @inheritdoc ILeaderboardConfig
    function setCooldown(uint256 newSeconds) external onlyOwner {
        if (newSeconds > MAX_COOLDOWN_SECONDS) {
            revert CooldownTooLong(newSeconds);
        }
        uint256 oldSeconds = cooldownSeconds;
        cooldownSeconds = newSeconds;
        emit CooldownUpdated(oldSeconds, newSeconds, block.timestamp);
        emit ConfigSnapshot(
            depositRateBps,
            borrowRateBps,
            vpRateBps,
            supplyDailyBonus,
            borrowDailyBonus,
            repayDailyBonus,
            withdrawDailyBonus,
            cooldownSeconds,
            minDailyBonusUsd,
            block.timestamp
        );
    }

    /// @inheritdoc ILeaderboardConfig
    function setMinDailyBonusUsd(uint256 newMin) external onlyOwner {
        uint256 oldMin = minDailyBonusUsd;
        minDailyBonusUsd = newMin;
        emit MinDailyBonusUsdUpdated(oldMin, newMin, block.timestamp);
        emit ConfigSnapshot(
            depositRateBps,
            borrowRateBps,
            vpRateBps,
            supplyDailyBonus,
            borrowDailyBonus,
            repayDailyBonus,
            withdrawDailyBonus,
            cooldownSeconds,
            minDailyBonusUsd,
            block.timestamp
        );
    }

    /// @inheritdoc ILeaderboardConfig
    function updateAllRates(
        uint256 _depositRate,
        uint256 _borrowRate,
        uint256 _vpRate,
        uint256 _supplyBonus,
        uint256 _borrowBonus
    ) external onlyOwner {
        if (_depositRate > MAX_RATE_BPS) revert RateTooHigh(_depositRate);
        if (_borrowRate > MAX_RATE_BPS) revert RateTooHigh(_borrowRate);
        if (_vpRate > MAX_RATE_BPS) revert RateTooHigh(_vpRate);
        if (_supplyBonus > MAX_DAILY_BONUS) revert BonusTooHigh(_supplyBonus);
        if (_borrowBonus > MAX_DAILY_BONUS) revert BonusTooHigh(_borrowBonus);

        uint256 oldDepositRate = depositRateBps;
        uint256 oldBorrowRate = borrowRateBps;
        uint256 oldVpRate = vpRateBps;
        uint256 oldSupply = supplyDailyBonus;
        uint256 oldBorrow = borrowDailyBonus;
        uint256 oldRepay = repayDailyBonus;
        uint256 oldWithdraw = withdrawDailyBonus;

        depositRateBps = _depositRate;
        borrowRateBps = _borrowRate;
        vpRateBps = _vpRate;
        supplyDailyBonus = _supplyBonus;
        borrowDailyBonus = _borrowBonus;

        emit DepositRateUpdated(oldDepositRate, _depositRate, block.timestamp);
        emit BorrowRateUpdated(oldBorrowRate, _borrowRate, block.timestamp);
        emit VpRateUpdated(oldVpRate, _vpRate, block.timestamp);
        emit DailyBonusUpdated(
            oldSupply,
            _supplyBonus,
            oldBorrow,
            _borrowBonus,
            oldRepay,
            repayDailyBonus,
            oldWithdraw,
            withdrawDailyBonus,
            block.timestamp
        );
        emit ConfigSnapshot(
            depositRateBps,
            borrowRateBps,
            vpRateBps,
            supplyDailyBonus,
            borrowDailyBonus,
            repayDailyBonus,
            withdrawDailyBonus,
            cooldownSeconds,
            minDailyBonusUsd,
            block.timestamp
        );
    }

    /// @inheritdoc ILeaderboardConfig
    function awardPoints(address user, uint256 points, string calldata reason) external onlyOwner {
        CommonChecksLibrary.revertIfZeroAddress(user);
        emit PointsAwarded(user, points, reason, block.timestamp);
    }

    /// @inheritdoc ILeaderboardConfig
    function batchAwardPoints(address[] calldata users, uint256[] calldata points, string calldata reason)
        external
        onlyOwner
    {
        if (users.length != points.length) revert("Array length mismatch");
        if (users.length == 0) revert("Empty arrays");

        for (uint256 i = 0; i < users.length; i++) {
            CommonChecksLibrary.revertIfZeroAddress(users[i]);

            emit PointsAwarded(users[i], points[i], reason, block.timestamp);
        }
    }

    /// @inheritdoc ILeaderboardConfig
    function removePoints(address user, uint256 points, string calldata reason) external onlyOwner {
        CommonChecksLibrary.revertIfZeroAddress(user);
        emit PointsRemoved(user, points, reason, block.timestamp);
    }

    /// @inheritdoc ILeaderboardConfig
    function batchRemovePoints(address[] calldata users, uint256[] calldata points, string calldata reason)
        external
        onlyOwner
    {
        if (users.length != points.length) revert("Array length mismatch");
        if (users.length == 0) revert("Empty arrays");

        for (uint256 i = 0; i < users.length; i++) {
            CommonChecksLibrary.revertIfZeroAddress(users[i]);

            emit PointsRemoved(users[i], points[i], reason, block.timestamp);
        }
    }

    /// @notice Disabled to prevent accidental renouncement of ownership
    function renounceOwnership() public view override onlyOwner {
        revert();
    }

    /// @inheritdoc ILeaderboardConfig
    function configureLPPool(address pool, address positionManager, address token0, address token1, uint256 lpRateBps)
        external
        onlyOwner
    {
        CommonChecksLibrary.revertIfZeroAddress(pool);
        CommonChecksLibrary.revertIfZeroAddress(positionManager);
        CommonChecksLibrary.revertIfZeroAddress(token0);
        CommonChecksLibrary.revertIfZeroAddress(token1);
        if (lpRateBps > MAX_RATE_BPS) revert RateTooHigh(lpRateBps);

        // Track new pools in array
        if (lpPoolConfigs[pool].positionManager == address(0)) {
            configuredLPPools.push(pool);
        }

        lpPoolConfigs[pool] = LpPoolConfig({
            positionManager: positionManager, token0: token0, token1: token1, lpRateBps: lpRateBps, isActive: true
        });

        emit LPPoolConfigured(pool, positionManager, token0, token1, lpRateBps, block.timestamp);
    }

    /// @inheritdoc ILeaderboardConfig
    function disableLPPool(address pool) external onlyOwner {
        if (!lpPoolConfigs[pool].isActive) revert LPPoolNotConfigured(pool);

        lpPoolConfigs[pool].isActive = false;
        emit LPPoolDisabled(pool, block.timestamp);
    }

    /// @inheritdoc ILeaderboardConfig
    function setLPRate(address pool, uint256 newRateBps) external onlyOwner {
        if (!lpPoolConfigs[pool].isActive) revert LPPoolNotConfigured(pool);
        if (newRateBps > MAX_RATE_BPS) revert RateTooHigh(newRateBps);

        uint256 oldRate = lpPoolConfigs[pool].lpRateBps;
        lpPoolConfigs[pool].lpRateBps = newRateBps;
        emit LPRateUpdated(pool, oldRate, newRateBps, block.timestamp);
    }

    /// @inheritdoc ILeaderboardConfig
    function addToBlacklist(address account) external onlyOwner {
        _addToBlacklist(account);
    }

    /// @inheritdoc ILeaderboardConfig
    function removeFromBlacklist(address account) external onlyOwner {
        _removeFromBlacklist(account);
    }

    /// @inheritdoc ILeaderboardConfig
    function addToBlacklistBatch(address[] calldata accounts) external onlyOwner {
        uint256 len = accounts.length;
        for (uint256 i = 0; i < len; ++i) {
            _addToBlacklist(accounts[i]);
        }
    }

    /// @inheritdoc ILeaderboardConfig
    function removeFromBlacklistBatch(address[] calldata accounts) external onlyOwner {
        uint256 len = accounts.length;
        for (uint256 i = 0; i < len; ++i) {
            _removeFromBlacklist(accounts[i]);
        }
    }

    /**
     * @notice Internal function to add an address to blacklist
     * @param account The address to blacklist
     */
    function _addToBlacklist(address account) internal {
        CommonChecksLibrary.revertIfZeroAddress(account);
        if (_blacklisted[account]) revert AlreadyBlacklisted(account);

        _blacklisted[account] = true;
        _blacklistedAddresses.push(account);

        emit AddressBlacklisted(account, block.timestamp);
    }

    /**
     * @notice Internal function to remove an address from blacklist
     * @param account The address to remove from blacklist
     */
    function _removeFromBlacklist(address account) internal {
        if (!_blacklisted[account]) revert NotBlacklisted(account);

        _blacklisted[account] = false;

        // Remove from array by swapping with last element
        uint256 len = _blacklistedAddresses.length;
        for (uint256 i = 0; i < len; ++i) {
            if (_blacklistedAddresses[i] == account) {
                _blacklistedAddresses[i] = _blacklistedAddresses[len - 1];
                _blacklistedAddresses.pop();
                break;
            }
        }

        emit AddressUnblacklisted(account, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILeaderboardConfig
    function getDepositRatePerDay() external view returns (uint256 rate) {
        return depositRateBps;
    }

    /// @inheritdoc ILeaderboardConfig
    function getBorrowRatePerDay() external view returns (uint256 rate) {
        return borrowRateBps;
    }

    /// @inheritdoc ILeaderboardConfig
    function getVpRatePerDay() external view returns (uint256 rate) {
        return vpRateBps;
    }

    /// @inheritdoc ILeaderboardConfig
    function getDailyBonuses() external view returns (uint256 supply, uint256 borrow, uint256 repay, uint256 withdraw) {
        return (supplyDailyBonus, borrowDailyBonus, repayDailyBonus, withdrawDailyBonus);
    }

    /// @inheritdoc ILeaderboardConfig
    function getAllConfig()
        external
        view
        returns (
            uint256 depositRate,
            uint256 borrowRate,
            uint256 vpRate,
            uint256 supplyBonus,
            uint256 borrowBonus,
            uint256 repayBonus,
            uint256 withdrawBonus,
            uint256 cooldown,
            uint256 minUsd
        )
    {
        return (
            depositRateBps,
            borrowRateBps,
            vpRateBps,
            supplyDailyBonus,
            borrowDailyBonus,
            repayDailyBonus,
            withdrawDailyBonus,
            cooldownSeconds,
            minDailyBonusUsd
        );
    }

    /// @inheritdoc ILeaderboardConfig
    function getLPPoolConfig(address pool)
        external
        view
        returns (address positionManager, address token0, address token1, uint256 lpRateBps, bool isActive)
    {
        LpPoolConfig storage config = lpPoolConfigs[pool];
        return (config.positionManager, config.token0, config.token1, config.lpRateBps, config.isActive);
    }

    /// @inheritdoc ILeaderboardConfig
    function getConfiguredLPPools() external view returns (address[] memory pools) {
        return configuredLPPools;
    }

    /// @inheritdoc ILeaderboardConfig
    function getLPPoolCount() external view returns (uint256 count) {
        return configuredLPPools.length;
    }

    /// @inheritdoc ILeaderboardConfig
    function isBlacklisted(address account) external view returns (bool) {
        return _blacklisted[account];
    }

    /// @inheritdoc ILeaderboardConfig
    function getBlacklistedAddresses() external view returns (address[] memory accounts) {
        return _blacklistedAddresses;
    }

    /// @inheritdoc ILeaderboardConfig
    function getBlacklistCount() external view returns (uint256 count) {
        return _blacklistedAddresses.length;
    }

    /*//////////////////////////////////////////////////////////////
                              STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    /// @dev Reserved storage gap for future upgrades
    uint256[50] private __gap;
}
