// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IDustLock} from "../../../src/interfaces/IDustLock.sol";
import {ITransferValidator} from "../../../src/interfaces/ITransferValidator.sol";

import "../../BaseTestLocal.sol";

/// @notice Transfer validator that reverts with empty returndata to exercise the
///         `TransferValidationFailed` branch (returnData.length == 0) in `_validateTransfer`.
contract EmptyRevertValidator is ITransferValidator {
    function validateTransfer(address, address, address, uint256) external pure override {
        // Empty revert -> zero-length returndata so DustLock falls into TransferValidationFailed.
        revert();
    }
}

/**
 * @notice Targets DustLock guard/revert arms that are not exercised anywhere else in the
 *         test tree: SameNFT, SplitNotAllowed, AmountTooBig, InvalidWithdrawPenalty,
 *         LockNotExpired, and the empty-returndata TransferValidationFailed path.
 */
contract DustLockBranchCoverageTest is BaseTestLocal {
    EmptyRevertValidator internal emptyRevertValidator;

    function _setUp() internal override {
        // Initial time => 1 sec after the start of week1 (mirrors DustLock.t.sol)
        assertEq(block.timestamp, 1 weeks + 1);
        mintErc20Token(address(DUST), user, TOKEN_100K);
        emptyRevertValidator = new EmptyRevertValidator();
    }

    /*//////////////////////////////////////////////////////////////
                              MERGE
    //////////////////////////////////////////////////////////////*/

    /// @notice merge(_from, _to) with identical ids must revert with SameNFT before any other check.
    function testMergeSameNftReverts() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        vm.expectRevert(IDustLock.SameNFT.selector);
        dustLock.merge(tokenId, tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                              SPLIT
    //////////////////////////////////////////////////////////////*/

    /// @notice split must revert SplitNotAllowed when neither per-user nor global split is enabled.
    function testSplitNotAllowedReverts() public {
        DUST.approve(address(dustLock), TOKEN_1 * 3);
        uint256 tokenId = dustLock.createLock(TOKEN_1 * 3, MAXTIME);

        // canSplit[owner] and canSplit[address(0)] both default to false.
        vm.expectRevert(IDustLock.SplitNotAllowed.selector);
        dustLock.split(tokenId, TOKEN_1);
    }

    /// @notice split must revert AmountTooBig when the requested amount is >= the locked amount.
    function testSplitAmountTooBigReverts() public {
        // Enable split globally.
        dustLock.toggleSplit(address(0), true);

        DUST.approve(address(dustLock), TOKEN_1 * 2);
        uint256 tokenId = dustLock.createLock(TOKEN_1 * 2, MAXTIME);

        // _amount (>= minLockAmount) but >= locked amount triggers AmountTooBig.
        vm.expectRevert(IDustLock.AmountTooBig.selector);
        dustLock.split(tokenId, TOKEN_1 * 2);
    }

    /*//////////////////////////////////////////////////////////////
                        EARLY WITHDRAW PENALTY
    //////////////////////////////////////////////////////////////*/

    /// @notice setEarlyWithdrawPenalty must revert when penalty >= BASIS_POINTS (10_000).
    function testSetEarlyWithdrawPenaltyTooHighReverts() public {
        vm.expectRevert(IDustLock.InvalidWithdrawPenalty.selector);
        dustLock.setEarlyWithdrawPenalty(BASIS_POINTS);
    }

    /// @notice setEarlyWithdrawPenalty must revert below the 2_500 bps floor that guards the curve.
    function testSetEarlyWithdrawPenaltyTooLowReverts() public {
        vm.expectRevert(IDustLock.InvalidWithdrawPenalty.selector);
        dustLock.setEarlyWithdrawPenalty(2_499);
    }

    /*//////////////////////////////////////////////////////////////
                              WITHDRAW
    //////////////////////////////////////////////////////////////*/

    /// @notice withdraw before lock expiry must revert with LockNotExpired.
    function testWithdrawBeforeExpiryReverts() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        // Still within the lock window.
        vm.expectRevert(IDustLock.LockNotExpired.selector);
        dustLock.withdraw(tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                  ERC721-C TRANSFER VALIDATION FAILURE
    //////////////////////////////////////////////////////////////*/

    /// @notice A validator that reverts with empty returndata must surface TransferValidationFailed.
    function testTransferValidationFailedEmptyRevert() public {
        // Configure validator + mark `user` (the caller) as a fee-enforced operator so validation runs.
        dustLock.setTransferValidator(address(emptyRevertValidator));
        dustLock.setFeeEnforcedOperator(user, true);

        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);
        skipAndRoll(1);

        vm.expectRevert(IDustLock.TransferValidationFailed.selector);
        dustLock.transferFrom(user, user2, tokenId);
    }
}
