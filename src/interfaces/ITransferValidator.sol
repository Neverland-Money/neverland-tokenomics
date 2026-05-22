// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/**
 * @title ITransferValidator
 * @author Neverland
 * @notice Interface for transfer validation contracts used in ERC721-C
 * @dev Validators enforce creator earnings by checking conditions before allowing transfers
 */
interface ITransferValidator {
    /**
     * @notice Validate that a transfer is authorized for a specific tokenId
     * @dev Called by the NFT contract before executing transfer
     *      Reverts if transfer is not authorized (e.g., creator fees not paid)
     * @param caller Address initiating the transfer (msg.sender from NFT contract)
     * @param from Current owner of the token
     * @param to Recipient of the token
     * @param tokenId The token ID being transferred
     */
    function validateTransfer(address caller, address from, address to, uint256 tokenId) external view;
}
