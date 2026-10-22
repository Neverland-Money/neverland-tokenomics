// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/**
 * @title IMorphoFlashLoan
 * @author Neverland
 * @notice Subset of Morpho Blue used to take a fee-free flash loan
 */
interface IMorphoFlashLoan {
    /**
     * @notice Lends `assets` of `token` to the caller for the duration of its callback
     * @dev The caller must implement `IMorphoFlashLoanCallback` and approve Morpho for repayment.
     * @param token The token to borrow
     * @param assets The amount to borrow
     * @param data Opaque data forwarded to the callback
     */
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}
