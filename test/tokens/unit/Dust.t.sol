// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "../../BaseTestLocal.sol";

contract DustTest is BaseTestLocal {
    function testRenounceOwnershipReverts() public {
        // Arrange
        address currentOwner = DUST.owner();
        assertEq(currentOwner, admin, "Owner should be admin");

        // Act & Assert
        vm.prank(admin);
        vm.expectRevert(bytes(""));
        DUST.renounceOwnership();

        // Verify owner hasn't changed
        assertEq(DUST.owner(), admin, "Owner should still be admin after failed renounce");
    }

    function testRenounceOwnershipRevertsForNonOwner() public {
        // Arrange
        address currentOwner = DUST.owner();
        assertEq(currentOwner, admin, "Owner should be admin");

        // Act & Assert - non-owner trying to call renounceOwnership should revert
        vm.prank(user);
        bytes4 errorStringSelector = bytes4(keccak256("Error(string)"));
        vm.expectRevert(abi.encodeWithSelector(errorStringSelector, "Ownable: caller is not the owner"));
        DUST.renounceOwnership();

        // Verify owner hasn't changed
        assertEq(DUST.owner(), admin, "Owner should still be admin");
    }
}
