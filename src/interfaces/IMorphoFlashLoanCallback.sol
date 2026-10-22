// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/**
 * @title IMorphoFlashLoanCallback
 * @author Neverland
 * @notice Callback Morpho Blue invokes on the borrower of a flash loan
 */
interface IMorphoFlashLoanCallback {
    /**
     * @notice Called by Morpho after transferring the loan to the borrower
     * @dev The borrower must hold `assets` and approve Morpho before returning; Morpho pulls repayment afterward.
     * @param assets The amount borrowed
     * @param data The data passed to `flashLoan`
     */
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
}
