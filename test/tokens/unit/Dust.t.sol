// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CommonChecksLibrary} from "../../../src/libraries/CommonChecksLibrary.sol";

import {Dust} from "../../../src/tokens/Dust.sol";
import {BaseTestLocal} from "../../BaseTestLocal.sol";

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

    function testRevenueCoverageDustAdminTransferPauseAndBurn() public {
        mintErc20Token(address(DUST), admin, TOKEN_1K);

        vm.prank(admin);
        DUST.transfer(user1, TOKEN_1);
        assertEq(DUST.balanceOf(user1), TOKEN_1);

        vm.prank(admin);
        DUST.pause();

        vm.prank(user1);
        vm.expectRevert();
        DUST.transfer(user2, 1);

        vm.prank(admin);
        DUST.unpause();

        vm.prank(user1);
        DUST.approve(user2, TOKEN_1 / 2);

        vm.prank(user2);
        DUST.burnFrom(user1, TOKEN_1 / 2);
        assertEq(DUST.balanceOf(user1), TOKEN_1 / 2);

        vm.prank(user1);
        DUST.burn(TOKEN_1 / 2);
        assertEq(DUST.balanceOf(user1), 0);
    }

    function testRevenueCoverageDustInitializeRejectsZeroOwner() public {
        Dust implementation = new Dust();
        ProxyAdmin adminProxy = new ProxyAdmin();
        bytes memory initData = abi.encodeWithSelector(Dust.initialize.selector, address(0), 0);

        vm.expectRevert(CommonChecksLibrary.AddressZero.selector);
        new TransparentUpgradeableProxy(address(implementation), address(adminProxy), initData);
    }
}
