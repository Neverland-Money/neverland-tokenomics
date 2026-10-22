// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IDustLock} from "../../../src/interfaces/IDustLock.sol";

import {DustLock} from "../../../src/tokens/DustLock.sol";
import "../../BaseTestLocal.sol";

/**
 * @notice Test-only harness exposing DustLock's internal mint/burn guards.
 * @dev Subclasses DustLock so the exposed wrappers run in the contract's own
 *      context; deployed behind the same UUPS/Transparent proxy + initializer
 *      pattern as the production contract so storage and `_msgSender()`
 *      resolution match production exactly.
 */
contract DustLockHarness is DustLock {
    constructor(address _forwarder) DustLock(_forwarder) {}

    /// @notice Wrapper around the internal `_addTokenTo` guard.
    function exposed_addTokenTo(address _to, uint256 _tokenId) external {
        _addTokenTo(_to, _tokenId);
    }

    /// @notice Wrapper around the internal `_removeTokenFrom` guard.
    function exposed_removeTokenFrom(address _from, uint256 _tokenId) external {
        _removeTokenFrom(_from, _tokenId);
    }

    /// @notice Wrapper around the internal `_burn` guard.
    function exposed_burn(uint256 _tokenId) external {
        _burn(_tokenId);
    }
}

/// @notice Receiver whose `onERC721Received` reverts with a non-empty string reason.
contract RevertingStringReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert("nope");
    }
}

/// @notice Custom error used by the custom-error reverting receiver.
error ReceiverRejected();

/// @notice Receiver whose `onERC721Received` reverts with a non-empty custom error.
contract RevertingCustomErrorReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert ReceiverRejected();
    }
}

/**
 * @notice Coverage tests for DustLock guard branches not reachable through the
 *         normal public-API happy paths.
 * @dev Targets exact uncovered branches:
 *      - increaseAmount NotApprovedOrOwner TRUE arm
 *      - increaseUnlockTime NotApprovedOrOwner TRUE arm
 *      - _safeTransferFrom catch non-empty `reason` bubble-up (assembly revert)
 *      - _addTokenTo AlreadyOwned, _removeTokenFrom NotOwner, _burn NotApprovedOrOwner
 */
contract DustLockGuardCoverageTest is BaseTestLocal {
    DustLockHarness internal harness;

    /// @dev `user == address(this)` (see BaseTest); used as the default lock creator/owner.
    address internal notOwner = address(0xBEEF);

    function _setUp() internal override {
        // Fund the default actor (address(this)) so it can create locks on both
        // the production `dustLock` and the harness instance.
        mintErc20Token(address(DUST), user, TOKEN_100K);

        // Deploy the harness behind the same proxy pattern as production DustLock.
        DustLockHarness harnessImpl = new DustLockHarness(FORWARDER);
        harness = DustLockHarness(_deployProxy(address(harnessImpl)));
        harness.initialize(FORWARDER, address(DUST), "https://neverland.money/nfts/");

        vm.label(address(harness), "DustLockHarness");
        vm.label(notOwner, "notOwner");
    }

    /* ========================================================================
                      increaseAmount / increaseUnlockTime gates
       ======================================================================== */

    /// @notice Line 1007: increaseAmount must revert for a non-owner / non-approved caller.
    function testIncreaseAmountNonOwnerReverts() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        // notOwner is neither owner, approved, nor operator for `tokenId`.
        vm.prank(notOwner);
        vm.expectRevert(IDustLock.NotApprovedOrOwner.selector);
        dustLock.increaseAmount(tokenId, TOKEN_1);
    }

    /// @notice Line 1014: increaseUnlockTime must revert for a non-owner / non-approved caller.
    function testIncreaseUnlockTimeNonOwnerReverts() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 tokenId = dustLock.createLock(TOKEN_1, MAXTIME);

        vm.prank(notOwner);
        vm.expectRevert(IDustLock.NotApprovedOrOwner.selector);
        dustLock.increaseUnlockTime(tokenId, MAXTIME);
    }

    /* ========================================================================
                  safeTransferFrom non-empty receiver-reason bubble-up
       ======================================================================== */

    /// @notice Lines 408/412 (ELSE arm): a non-empty string reason bubbles up verbatim.
    function testSafeTransferReceiverStringReasonBubblesUp() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 id = dustLock.createLock(TOKEN_1, MAXTIME);

        RevertingStringReceiver receiver = new RevertingStringReceiver();

        // The catch arm re-reverts the original non-empty reason ("nope") via assembly,
        // NOT the empty-reason fallback ERC721TransferToNonERC721ReceiverImplementer.
        vm.expectRevert(bytes("nope"));
        dustLock.safeTransferFrom(user, address(receiver), id);
    }

    /// @notice Lines 408/412 (ELSE arm): a non-empty custom-error reason bubbles up verbatim.
    function testSafeTransferReceiverCustomErrorReasonBubblesUp() public {
        DUST.approve(address(dustLock), TOKEN_1);
        uint256 id = dustLock.createLock(TOKEN_1, MAXTIME);

        RevertingCustomErrorReceiver receiver = new RevertingCustomErrorReceiver();

        vm.expectRevert(ReceiverRejected.selector);
        dustLock.safeTransferFrom(user, address(receiver), id);
    }

    /* ========================================================================
              internal defensive guards (via DustLockHarness)
       ======================================================================== */

    /// @notice Line 461: _addTokenTo reverts AlreadyOwned when the token id is already owned.
    function testAddTokenToAlreadyOwnedReverts() public {
        // Create a lock on the harness so tokenId 1 is owned by `user`.
        DUST.approve(address(harness), TOKEN_1);
        uint256 ownedTokenId = harness.createLock(TOKEN_1, MAXTIME);
        assertEq(harness.ownerOf(ownedTokenId), user);

        // Re-adding an already-owned token id must hit the AlreadyOwned guard.
        vm.expectRevert(IDustLock.AlreadyOwned.selector);
        harness.exposed_addTokenTo(notOwner, ownedTokenId);
    }

    /// @notice Line 527: _removeTokenFrom reverts NotOwner when `_from` is not the current owner.
    function testRemoveTokenFromNotOwnerReverts() public {
        DUST.approve(address(harness), TOKEN_1);
        uint256 ownedTokenId = harness.createLock(TOKEN_1, MAXTIME);
        assertEq(harness.ownerOf(ownedTokenId), user);

        // `notOwner` does not own the token -> NotOwner guard.
        vm.expectRevert(IDustLock.NotOwner.selector);
        harness.exposed_removeTokenFrom(notOwner, ownedTokenId);
    }

    /// @notice Line 544: _burn reverts NotApprovedOrOwner when `_msgSender()` is not approved/owner.
    function testBurnNotApprovedOrOwnerReverts() public {
        DUST.approve(address(harness), TOKEN_1);
        uint256 ownedTokenId = harness.createLock(TOKEN_1, MAXTIME);
        assertEq(harness.ownerOf(ownedTokenId), user);

        // Prank a non-owner so `_msgSender()` resolves to it inside _burn.
        vm.prank(notOwner);
        vm.expectRevert(IDustLock.NotApprovedOrOwner.selector);
        harness.exposed_burn(ownedTokenId);
    }
}
