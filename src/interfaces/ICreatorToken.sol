// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/**
 * @title ICreatorToken
 * @author Neverland
 * @notice Interface for ERC721-C creator token standard
 * @dev Enables enforceable creator earnings on marketplace sales via Seaport v1.6
 *      Based on OpenSea's ERC721-C standard for on-chain royalty enforcement
 */
interface ICreatorToken {
    /**
     * @notice Emitted when the transfer validator is updated
     * @param oldValidator Previous validator address
     * @param newValidator New validator address
     */
    event TransferValidatorUpdated(address oldValidator, address newValidator);

    /**
     * @notice Get the current transfer validator address
     * @dev Returns address(0) if no validator is set
     * @return validator The address of the current transfer validator
     */
    function getTransferValidator() external view returns (address validator);

    /**
     * @notice Get the transfer validation function signature and type
     * @dev Returns the function selector that should be called on the validator
     * @return functionSignature The bytes4 selector of the validation function
     * @return isViewFunction Whether the validation function is a view function
     */
    function getTransferValidationFunction() external view returns (bytes4 functionSignature, bool isViewFunction);

    /**
     * @notice Set a new transfer validator
     * @dev Only callable by contract owner/admin.
     *      Validator contract must implement the validateTransfer function.
     *
     *      NOTE: When a validator is active (non-zero), gasless NFT transfers via
     *      the trusted ERC2771 forwarder are disabled. The forwarder obscures the
     *      original operator identity, preventing the validator from distinguishing
     *      marketplace sales from peer-to-peer transfers. Users must transfer
     *      directly (not via meta-transaction) when creator-earnings validation
     *      is enabled. Set to address(0) to disable validation and restore
     *      forwarder-relayed transfer support.
     * @param validator Address of the new transfer validator contract
     */
    function setTransferValidator(address validator) external;
}
