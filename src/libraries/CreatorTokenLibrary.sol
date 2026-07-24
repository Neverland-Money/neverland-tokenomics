// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ICreatorToken} from "../interfaces/ICreatorToken.sol";
import {IDustLock} from "../interfaces/IDustLock.sol";
import {ITransferValidator} from "../interfaces/ITransferValidator.sol";

import {CommonChecksLibrary} from "./CommonChecksLibrary.sol";
import {CommonLibrary} from "./CommonLibrary.sol";

/**
 * @title CreatorTokenLibrary
 * @author Neverland
 * @notice External linked library holding the ERC721-C transfer-validator and
 *         fee-enforced-operator logic for DustLock.
 * @dev Stateless by construction: it owns no storage and never `delegatecall`s or `selfdestruct`s.
 *      DustLock keeps every creator-earnings state variable; this library reaches them through
 *      `storage` reference params (mappings/arrays) and value params, executing under DustLock's
 *      `delegatecall` so `address(this)`, `msg.sender`, and emitted-event provenance all resolve to
 *      DustLock. This is the same reference-parameter pattern `BalanceLogicLibrary` uses, extracted
 *      purely to keep DustLock under the EIP-170 runtime-bytecode limit with no behavior change.
 */
library CreatorTokenLibrary {
    /**
     * @notice Validates a token transfer against the ERC721-C transfer validator.
     * @dev - Fee-enforced operators (marketplace conduits) are always validated.
     *      - Forwarder-relayed transfers are explicitly blocked when a validator is
     *        active because the forwarder obscures the original operator identity,
     *        preventing the validator from distinguishing marketplace sales from
     *        peer-to-peer transfers. Users should transfer directly for P2P.
     *      - All other callers (non-enforced, non-forwarder) skip validation,
     *        allowing free peer-to-peer transfers.
     *      Runs under DustLock's delegatecall, so `caller` is the original `msg.sender` and the
     *      forwarder check is supplied as a value param (DustLock evaluates `isTrustedForwarder`).
     * @param validator_ The configured transfer validator (`address(0)` skips validation).
     * @param callerIsForwarder Whether the original `msg.sender` is the trusted forwarder.
     * @param storedSelector The configured validation selector (`bytes4(0)` means use the default).
     * @param storedIsView Whether the configured selector should be invoked via `staticcall`.
     * @param feeEnforcedOperatorIndexPlusOne Index+1 of each fee-enforced operator (0 = not enforced).
     * @param caller The address initiating the transfer (msg.sender).
     * @param from The current owner of the token.
     * @param to The recipient of the token.
     * @param tokenId_ The token id being transferred.
     */
    function validateTransfer(
        address validator_,
        bool callerIsForwarder,
        bytes4 storedSelector,
        bool storedIsView,
        mapping(address => uint256) storage feeEnforcedOperatorIndexPlusOne,
        address caller,
        address from,
        address to,
        uint256 tokenId_
    ) external {
        if (validator_ == address(0)) return;

        /*
         * Block forwarder-relayed transfers when a validator is active.
         * The forwarder obscures the original operator, so the validator cannot
         * distinguish marketplace sales from P2P transfers. Users should transfer
         * directly (not via meta-tx) when ERC721-C validation is enabled.
         */
        if (callerIsForwarder) revert IDustLock.ForwarderTransferNotAllowed();

        /*
         * Only validate fee-enforced operators (marketplace conduits).
         * Non-enforced callers (regular users) skip validation for free P2P transfers.
         */
        if (feeEnforcedOperatorIndexPlusOne[caller] == 0) return;

        (bytes4 validationSelector, bool isViewFunction) = getTransferValidationFunction(storedSelector, storedIsView);

        bytes memory data = abi.encodeWithSelector(validationSelector, caller, from, to, tokenId_);
        (bool success, bytes memory returnData) = isViewFunction ? validator_.staticcall(data) : validator_.call(data);
        if (!success) {
            if (returnData.length == 0) revert IDustLock.TransferValidationFailed();
            assembly {
                revert(add(32, returnData), mload(returnData))
            }
        }
    }

    /**
     * @notice Validates a candidate transfer validator and emits `TransferValidatorUpdated`.
     * @dev Reverts if `newValidator` is non-zero and not a contract. The caller (DustLock) performs
     *      the SSTORE of `newValidator`; value-type slots are not crossed as storage pointers.
     * @param oldValidator The current validator address (for the emitted event).
     * @param newValidator The new validator address (`address(0)` disables validation).
     */
    function setTransferValidator(address oldValidator, address newValidator) external {
        if (newValidator != address(0) && !CommonLibrary.isContract(newValidator)) {
            revert IDustLock.InvalidTransferValidatorContract();
        }

        emit ICreatorToken.TransferValidatorUpdated(oldValidator, newValidator);
    }

    /**
     * @notice Resolves the next validation view flag and emits `TransferValidationFunctionUpdated`.
     * @dev A zero selector forces the returned view flag true so the default view call is restored.
     *      The caller (DustLock) performs the SSTOREs of the selector and the returned view flag.
     * @param storedSelector The currently configured selector.
     * @param storedIsView The currently configured view flag.
     * @param validationSelector The new validation selector.
     * @param isViewFunction The requested view flag for the new selector.
     * @return nextIsViewFunction The view flag DustLock must persist alongside `validationSelector`.
     */
    function setTransferValidationFunction(
        bytes4 storedSelector,
        bool storedIsView,
        bytes4 validationSelector,
        bool isViewFunction
    ) external returns (bool nextIsViewFunction) {
        (bytes4 oldSelector, bool oldIsView) = getTransferValidationFunction(storedSelector, storedIsView);
        nextIsViewFunction = validationSelector == bytes4(0) ? true : isViewFunction;

        emit IDustLock.TransferValidationFunctionUpdated(oldSelector, validationSelector, oldIsView, nextIsViewFunction);

        return nextIsViewFunction;
    }

    /**
     * @notice Adds or removes a fee-enforced operator and emits `FeeEnforcedOperatorUpdated` on change.
     * @dev Maintains the swap-and-pop `feeEnforcedOperators` array alongside the index+1 mapping.
     *      No-ops (and skips the event) when the requested state already holds.
     * @param feeEnforcedOperatorIndexPlusOne Index+1 of each operator in the array (0 = not enforced).
     * @param feeEnforcedOperators The fee-enforced operator list.
     * @param operator The operator address (must be non-zero).
     * @param enforced Whether fees are enforced for this operator.
     */
    function setFeeEnforcedOperator(
        mapping(address => uint256) storage feeEnforcedOperatorIndexPlusOne,
        address[] storage feeEnforcedOperators,
        address operator,
        bool enforced
    ) external {
        CommonChecksLibrary.revertIfZeroAddress(operator);

        uint256 indexPlusOne = feeEnforcedOperatorIndexPlusOne[operator];
        if (enforced) {
            if (indexPlusOne == 0) {
                feeEnforcedOperators.push(operator);
                feeEnforcedOperatorIndexPlusOne[operator] = feeEnforcedOperators.length;

                emit IDustLock.FeeEnforcedOperatorUpdated(operator, true);
            }
            return;
        }

        if (indexPlusOne == 0) return;

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = feeEnforcedOperators.length - 1;
        if (index != lastIndex) {
            address lastOperator = feeEnforcedOperators[lastIndex];
            feeEnforcedOperators[index] = lastOperator;
            feeEnforcedOperatorIndexPlusOne[lastOperator] = index + 1;
        }

        feeEnforcedOperators.pop();
        delete feeEnforcedOperatorIndexPlusOne[operator];

        emit IDustLock.FeeEnforcedOperatorUpdated(operator, false);
    }

    /**
     * @notice Resolves the selector and call type for the transfer validation function.
     * @dev Defaults to SIP-7 substandard 8 (`validateTransfer`) when no custom selector is set.
     * @param storedSelector The configured validation selector (`bytes4(0)` means use the default).
     * @param storedIsView Whether the configured selector should be invoked via `staticcall`.
     * @return validationSelector The 4-byte selector used to call the transfer validator.
     * @return isViewFunction True if the validator should be invoked via `staticcall`.
     */
    function getTransferValidationFunction(bytes4 storedSelector, bool storedIsView)
        public
        pure
        returns (bytes4 validationSelector, bool isViewFunction)
    {
        if (storedSelector == bytes4(0)) {
            // SIP-7 substandard 8: validateTransfer(address,address,address,uint256)
            return (ITransferValidator.validateTransfer.selector, true);
        }

        return (storedSelector, storedIsView);
    }
}
