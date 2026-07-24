// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IUserVaultFactory} from "./IUserVaultFactory.sol";

/**
 * @title INeverlandUiRevenueReward
 * @author Neverland
 * @notice RevenueReward view surface emitted by the production NeverlandUiProvider.
 * @dev This intentionally includes `pendingRewards`, which the recovered production
 *      RevenueReward implementation does not expose. Keeping the selector here
 *      preserves the deployment-selected compiler output and recovered-source
 *      compatibility boundary without widening the canonical IRevenueReward interface.
 */
interface INeverlandUiRevenueReward {
    /**
     * @notice Returns the UserVault factory configured on RevenueReward
     * @return factory Configured UserVault factory
     */
    function userVaultFactory() external view returns (IUserVaultFactory);

    /**
     * @notice Returns the maximum token IDs accepted by a batched reward preview
     * @return maxTokenIds Maximum token ID count
     */
    function MAX_TOKENIDS() external view returns (uint256);

    /**
     * @notice Returns the maximum reward tokens accepted by a batched reward preview
     * @return maxTokens Maximum reward-token count
     */
    function MAX_TOKENS() external view returns (uint256);

    /**
     * @notice Returns the configured reward distributor
     * @return distributor Reward-distributor address
     */
    function rewardDistributor() external view returns (address);

    /**
     * @notice Returns cumulative rewards notified for a reward token
     * @param token Reward-token address
     * @return amount Cumulative notified amount
     */
    function totalRewardsPerToken(address token) external view returns (uint256);

    /**
     * @notice Returns pending receiver-level rewards for a user and reward token
     * @dev The recovered production RevenueReward does not expose this selector.
     * @param token Reward-token address
     * @param user User address
     * @return amount Pending reward amount
     */
    function pendingRewards(address token, address user) external view returns (uint256 amount);

    /**
     * @notice Returns rewards assigned to an epoch for a reward token
     * @param token Reward-token address
     * @param epoch Epoch timestamp
     * @return amount Reward amount assigned to the epoch
     */
    function tokenRewardsPerEpoch(address token, uint256 epoch) external view returns (uint256);

    /**
     * @notice Returns the configured reward receiver for a DustLock token ID
     * @param tokenId DustLock token ID
     * @return receiver Reward-receiver address
     */
    function tokenRewardReceiver(uint256 tokenId) external view returns (address);

    /**
     * @notice Previews all requested reward-token amounts across token IDs
     * @param tokens Reward-token addresses
     * @param tokenIds DustLock token IDs
     * @return matrix Per-token-ID reward amounts for each reward token
     * @return totals Aggregate amount for each reward token
     */
    function earnedRewardsAll(address[] calldata tokens, uint256[] calldata tokenIds)
        external
        view
        returns (uint256[][] memory matrix, uint256[] memory totals);

    /**
     * @notice Returns all registered reward-token addresses
     * @return tokens Registered reward tokens
     */
    function getRewardTokens() external view returns (address[] memory tokens);

    /**
     * @notice Returns token IDs routed to the user's self-repaying-loan vault
     * @param user User address
     * @return tokenIds Routed DustLock token IDs
     */
    function getUserTokensWithSelfRepayingLoan(address user) external view returns (uint256[] memory tokenIds);
}
