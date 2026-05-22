// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {CommonChecksLibrary} from "../libraries/CommonChecksLibrary.sol";
import {IVotingPowerMultiplier} from "../interfaces/IVotingPowerMultiplier.sol";
import {IDustLock} from "../interfaces/IDustLock.sol";

/**
 * @title VotingPowerMultiplier
 * @author Neverland
 * @notice Manages voting power (veNFT) based point multipliers for the leaderboard
 * @dev Uses tiered system: higher voting power = higher multiplier
 * @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
 */
contract VotingPowerMultiplier is IVotingPowerMultiplier, OwnableUpgradeable {
    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Minimum multiplier (1.0x in basis points)
    uint256 public constant MIN_MULTIPLIER_BPS = 10_000;

    /// @notice Maximum multiplier (5.0x in basis points)
    uint256 public constant MAX_MULTIPLIER_BPS = 50_000;

    /*//////////////////////////////////////////////////////////////
                          STORAGE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice DustLock contract for voting power queries
    IDustLock public immutable dustLock;

    /// @notice Array of voting power tiers (must be sorted ascending by minVotingPower)
    VotingPowerTier[] private tiers;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets immutable DustLock dependency and disables implementation initializers
     * @param _dustLock Address of the DustLock contract used for voting power reads
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(address _dustLock) {
        CommonChecksLibrary.revertIfZeroAddress(_dustLock);
        dustLock = IDustLock(_dustLock);
        _disableInitializers();
    }

    /**
     * @notice Initialize with owner
     * @param _initialOwner Initial owner for Ownable
     */
    function initialize(address _initialOwner) external initializer {
        __Ownable_init();
        _transferOwnership(_initialOwner);
        CommonChecksLibrary.revertIfZeroAddress(_initialOwner);

        // Initialize with default tier (0 voting power = 1.0x)
        tiers.push(VotingPowerTier({minVotingPower: 0, multiplierBps: MIN_MULTIPLIER_BPS}));

        emit TierAdded(0, 0, MIN_MULTIPLIER_BPS, 1);
    }

    /*//////////////////////////////////////////////////////////////
                               ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVotingPowerMultiplier
    function addTier(uint256 minVotingPower, uint256 multiplierBps) external onlyOwner {
        if (multiplierBps < MIN_MULTIPLIER_BPS || multiplierBps > MAX_MULTIPLIER_BPS) {
            revert MultiplierTooHigh(multiplierBps);
        }

        // Ensure tiers remain sorted
        if (tiers.length > 0) {
            if (minVotingPower <= tiers[tiers.length - 1].minVotingPower) {
                revert TiersNotAscending();
            }
        }

        tiers.push(VotingPowerTier({minVotingPower: minVotingPower, multiplierBps: multiplierBps}));

        emit TierAdded(tiers.length - 1, minVotingPower, multiplierBps, tiers.length);
    }

    /// @inheritdoc IVotingPowerMultiplier
    function updateTier(uint256 tierIndex, uint256 minVotingPower, uint256 multiplierBps) external onlyOwner {
        if (tierIndex >= tiers.length) {
            revert InvalidTierIndex(tierIndex);
        }
        // Tier 0 must always have minVotingPower = 0 to ensure all voting powers get a multiplier
        if (tierIndex == 0 && minVotingPower != 0) {
            revert InvalidTierIndex(tierIndex);
        }
        if (multiplierBps < MIN_MULTIPLIER_BPS || multiplierBps > MAX_MULTIPLIER_BPS) {
            revert MultiplierTooHigh(multiplierBps);
        }

        // Ensure tiers remain sorted
        if (tierIndex > 0 && minVotingPower <= tiers[tierIndex - 1].minVotingPower) {
            revert TiersNotAscending();
        }
        if (tierIndex < tiers.length - 1 && minVotingPower >= tiers[tierIndex + 1].minVotingPower) {
            revert TiersNotAscending();
        }

        VotingPowerTier memory oldTier = tiers[tierIndex];
        tiers[tierIndex] = VotingPowerTier({minVotingPower: minVotingPower, multiplierBps: multiplierBps});

        emit TierUpdated(tierIndex, oldTier.minVotingPower, minVotingPower, oldTier.multiplierBps, multiplierBps);
    }

    /// @inheritdoc IVotingPowerMultiplier
    function removeTier(uint256 tierIndex) external onlyOwner {
        if (tierIndex == 0) {
            revert InvalidTierIndex(tierIndex);
        }
        if (tierIndex >= tiers.length) {
            revert InvalidTierIndex(tierIndex);
        }

        // Shift elements left to maintain ascending order
        for (uint256 i = tierIndex; i < tiers.length - 1; i++) {
            tiers[i] = tiers[i + 1];
        }
        tiers.pop();

        emit TierRemoved(tierIndex, tiers.length);
    }

    // Note: dustLock is immutable and set in constructor for security
    // To change dustLock, deploy a new implementation with the new address

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVotingPowerMultiplier
    function getMultiplierForVotingPower(uint256 votingPower) public view returns (uint256 multiplierBps) {
        // Find the highest tier the voting power qualifies for
        uint256 tierCount = tiers.length;
        for (uint256 i = tierCount; i > 0; --i) {
            if (votingPower >= tiers[i - 1].minVotingPower) {
                return tiers[i - 1].multiplierBps;
            }
        }

        // Should never reach here if tier 0 has minVotingPower = 0
        return MIN_MULTIPLIER_BPS;
    }

    /// @inheritdoc IVotingPowerMultiplier
    function getUserMultiplier(address user)
        external
        view
        returns (uint256 multiplierBps, uint256 votingPower, uint256 tokenId)
    {
        uint256 balance = dustLock.balanceOf(user);
        if (balance == 0) {
            return (MIN_MULTIPLIER_BPS, 0, 0);
        }

        // Find the veNFT with highest voting power
        uint256 maxVotingPower = 0;
        uint256 maxTokenId = 0;

        for (uint256 i = 0; i < balance; ++i) {
            uint256 tid = dustLock.ownerToNFTokenIdList(user, i);
            uint256 vp = dustLock.balanceOfNFT(tid);

            if (vp > maxVotingPower) {
                maxVotingPower = vp;
                maxTokenId = tid;
            }
        }

        multiplierBps = getMultiplierForVotingPower(maxVotingPower);
        votingPower = maxVotingPower;
        tokenId = maxTokenId;
    }

    /// @inheritdoc IVotingPowerMultiplier
    function getAllTiers() external view returns (VotingPowerTier[] memory) {
        return tiers;
    }

    /// @inheritdoc IVotingPowerMultiplier
    function getTierCount() external view returns (uint256) {
        return tiers.length;
    }

    /// @inheritdoc IVotingPowerMultiplier
    function getTier(uint256 tierIndex) external view returns (VotingPowerTier memory) {
        if (tierIndex >= tiers.length) {
            revert InvalidTierIndex(tierIndex);
        }
        return tiers[tierIndex];
    }

    /// @notice Disabled to prevent accidental renouncement of ownership
    function renounceOwnership() public view override onlyOwner {
        revert();
    }

    /*//////////////////////////////////////////////////////////////
                              STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    /// @dev Reserved storage gap for future upgrades
    uint256[50] private __gap;
}
