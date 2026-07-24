// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

import {IDustLock} from "./IDustLock.sol";
import {IDustTransferStrategy} from "./IDustTransferStrategy.sol";

/**
 * @title IDustLockTransferStrategy
 * @author Neverland
 * @notice Interface for the DustLock transfer strategy which manages reward distributions to veNFT holders
 * @dev Extends IDustTransferStrategy with specialized functionality for veNFT integration and DUST token handling
 */
interface IDustLockTransferStrategy is IDustTransferStrategy {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted once per gross reward release after the V3 strategy has priced and routed it
     * @param to Beneficiary receiving the net proceeds
     * @param destinationTokenId veNFT credited with the net DUST (existing or newly created), or zero for a liquid transfer
     * @param lockTime Requested lock signal: zero for instant, max uint for permanent, otherwise the requested seconds
     * @param gross Gross DUST released by the controller before pricing
     * @param penalty Exact DUST routed to the early-exit burn wallet
     * @param net Exact DUST delivered to the beneficiary or lock
     */
    event RewardClaimPriced(
        address indexed to,
        uint256 indexed destinationTokenId,
        uint256 lockTime,
        uint256 gross,
        uint256 penalty,
        uint256 net
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Error thrown when V3 is mapped before the DustLock claim-reform capability is active
    error DustLockClaimReformInactive();

    /// @notice Error thrown when a guarded activation or rollback assertion does not match on-chain state
    error InvalidActivationState();

    /// @notice Error thrown when reward token is not DUST
    error InvalidRewardAddress();

    /// @notice Error thrown when tokenId owner is not the recipient
    error NotTokenOwner();

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the DustLock contract that manages veNFTs
     * @return The DustLock contract interface
     */
    function DUST_LOCK() external view returns (IDustLock);

    /**
     * @notice Returns the vault address where DUST rewards are stored before distribution
     * @return The address of the DUST vault
     */
    function DUST_VAULT() external view returns (address);

    /**
     * @notice Returns the DUST token address
     * @return The address of the DUST token
     */
    function DUST() external view returns (address);

    /**
     * @notice Returns the transfer strategy version
     * @return The current contract version
     */
    function version() external view returns (uint256);

    /**
     * @notice Quotes the exact NGV-05 penalty allocation and user/lock proceeds for a claim
     * @dev Timed commitments price linearly from 40% at the 28-day minimum down to 0 at
     *      `MAX_LOCK_DURATION - WEEK` (358 days); commitments at or above that band, permanent
     *      routes, and permanent existing locks are all untolled.
     * @param amount Gross DUST reward amount
     * @param lockTime Requested duration, zero for instant, or max uint for permanent
     * @param tokenId Existing veNFT to receive the reward, or zero for a new position
     * @return penaltyAmount Exact DUST amount routed to the early-exit burn wallet
     * @return netAmount Exact liquid or locked user proceeds
     */
    function previewClaim(uint256 amount, uint256 lockTime, uint256 tokenId)
        external
        view
        returns (uint256 penaltyAmount, uint256 netAmount);

    /**
     * @notice Reverts unless controller, allowance, token, and capability match a guarded state
     * @param expectedActive False for the V2.0.0 predecessor state; true for DustLock V2.1.0
     */
    function assertActivationState(bool expectedActive) external view;
}
