// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Dust} from "../../../src/tokens/Dust.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DustBurnTest is Test {
    Dust public dust;
    Dust public dustImpl;

    address public owner = address(0x1);
    address public alice = address(0x2);
    address public bob = address(0x3);

    uint256 public constant INITIAL_SUPPLY = 1_000_000_000; // 1 billion
    uint256 public constant INITIAL_SUPPLY_WEI = INITIAL_SUPPLY * 1e18;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function logState(string memory label) internal {
        emit log_string(label);
        emit log_named_uint("totalSupply", dust.totalSupply());
        emit log_named_uint("ownerBalance", dust.balanceOf(owner));
        emit log_named_uint("aliceBalance", dust.balanceOf(alice));
        emit log_named_uint("bobBalance", dust.balanceOf(bob));
        emit log_named_uint("paused", dust.paused() ? 1 : 0);
    }

    function logAllowance(string memory label, address holder, address spender) internal {
        emit log_string(label);
        emit log_named_address("holder", holder);
        emit log_named_address("spender", spender);
        emit log_named_uint("allowance", dust.allowance(holder, spender));
    }

    function setUp() public {
        // Deploy implementation
        dustImpl = new Dust();

        // Deploy proxy
        bytes memory initData = abi.encodeCall(Dust.initialize, (owner, INITIAL_SUPPLY));
        ERC1967Proxy proxy = new ERC1967Proxy(address(dustImpl), initData);
        dust = Dust(address(proxy));

        // Transfer some tokens to alice and bob for testing
        vm.startPrank(owner);
        dust.transfer(alice, 1000 * 1e18);
        dust.transfer(bob, 500 * 1e18);
        vm.stopPrank();

        emit log_string("setUp: initial state");
        emit log_named_address("owner", owner);
        emit log_named_address("alice", alice);
        emit log_named_address("bob", bob);
        logState("setUp: balances and pause state");
    }

    function testBurnReducesBalanceAndTotalSupply() public {
        uint256 burnAmount = 100 * 1e18;

        uint256 aliceBalanceBefore = dust.balanceOf(alice);
        uint256 totalSupplyBefore = dust.totalSupply();

        logState("before burn");

        vm.prank(alice);
        dust.burn(burnAmount);

        uint256 aliceBalanceAfter = dust.balanceOf(alice);
        uint256 totalSupplyAfter = dust.totalSupply();

        // Verify balance reduced
        assertEq(aliceBalanceAfter, aliceBalanceBefore - burnAmount, "Alice balance should decrease by burn amount");

        // Verify total supply reduced
        assertEq(totalSupplyAfter, totalSupplyBefore - burnAmount, "Total supply should decrease by burn amount");

        // Log results
        emit log_named_uint("Alice balance before", aliceBalanceBefore);
        emit log_named_uint("Alice balance after", aliceBalanceAfter);
        emit log_named_uint("Total supply before", totalSupplyBefore);
        emit log_named_uint("Total supply after", totalSupplyAfter);
        emit log_named_uint("Burned amount", burnAmount);
        logState("after burn");
    }

    function testBurnEmitsTransferToZeroAddress() public {
        uint256 burnAmount = 50 * 1e18;

        logState("before burn emit check");

        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, address(0), burnAmount);

        vm.prank(alice);
        dust.burn(burnAmount);

        logState("after burn emit check");
    }

    function testPauseBlocksBurn() public {
        uint256 burnAmount = 1e18;

        logState("before pause");

        vm.prank(owner);
        dust.pause();

        logState("after pause");
        emit log_string("attempt burn while paused");

        vm.prank(alice);
        vm.expectRevert("ERC20Pausable: token transfer while paused");
        dust.burn(burnAmount);

        logState("after paused burn revert");
    }

    function testPauseBlocksBurnFrom() public {
        uint256 burnAmount = 1e18;

        logState("before approve for burnFrom");

        vm.prank(alice);
        dust.approve(bob, burnAmount);

        logAllowance("allowance after approve", alice, bob);

        vm.prank(owner);
        dust.pause();

        logState("after pause");
        emit log_string("attempt burnFrom while paused");

        vm.prank(bob);
        vm.expectRevert("ERC20Pausable: token transfer while paused");
        dust.burnFrom(alice, burnAmount);

        logAllowance("allowance after paused burnFrom revert", alice, bob);
        logState("after paused burnFrom revert");
    }

    function testPauseOnlyOwner() public {
        logState("before non-owner pause");

        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        dust.pause();

        logState("after non-owner pause revert");
    }

    function testUnpauseOnlyOwner() public {
        vm.prank(owner);
        dust.pause();

        logState("after pause");
        emit log_string("attempt unpause as non-owner");

        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        dust.unpause();

        logState("after non-owner unpause revert");
    }

    function testBurnEntireBalance() public {
        uint256 aliceBalance = dust.balanceOf(alice);

        logState("before burn entire balance");

        vm.prank(alice);
        dust.burn(aliceBalance);

        assertEq(dust.balanceOf(alice), 0, "Alice balance should be zero after burning all");
        logState("after burn entire balance");
    }

    function testBurnRevertsOnInsufficientBalance() public {
        uint256 aliceBalance = dust.balanceOf(alice);

        logState("before insufficient burn");
        emit log_named_uint("attempt burn amount", aliceBalance + 1);

        vm.prank(alice);
        vm.expectRevert("ERC20: burn amount exceeds balance");
        dust.burn(aliceBalance + 1);

        logState("after insufficient burn revert");
    }

    function testBurnFromWithApproval() public {
        uint256 burnAmount = 200 * 1e18;

        logState("before approve for burnFrom");

        // Alice approves Bob to burn her tokens
        vm.prank(alice);
        dust.approve(bob, burnAmount);

        logAllowance("allowance after approve", alice, bob);

        uint256 aliceBalanceBefore = dust.balanceOf(alice);
        uint256 totalSupplyBefore = dust.totalSupply();

        // Bob burns from Alice's balance
        vm.prank(bob);
        dust.burnFrom(alice, burnAmount);

        uint256 aliceBalanceAfter = dust.balanceOf(alice);
        uint256 totalSupplyAfter = dust.totalSupply();

        // Verify balance reduced
        assertEq(aliceBalanceAfter, aliceBalanceBefore - burnAmount, "Alice balance should decrease");

        // Verify total supply reduced
        assertEq(totalSupplyAfter, totalSupplyBefore - burnAmount, "Total supply should decrease");

        // Verify allowance consumed
        assertEq(dust.allowance(alice, bob), 0, "Allowance should be consumed");

        emit log_named_uint("Alice balance before", aliceBalanceBefore);
        emit log_named_uint("Alice balance after", aliceBalanceAfter);
        emit log_named_uint("Total supply reduced by", totalSupplyBefore - totalSupplyAfter);
        logAllowance("allowance after burnFrom", alice, bob);
        logState("after burnFrom");
    }

    function testBurnFromRevertsWithoutApproval() public {
        logAllowance("allowance before burnFrom", alice, bob);
        emit log_string("attempt burnFrom without approval");

        vm.prank(bob);
        vm.expectRevert("ERC20: insufficient allowance");
        dust.burnFrom(alice, 100 * 1e18);

        logState("after burnFrom without approval revert");
    }

    function testBurnFromRevertsOnInsufficientAllowance() public {
        // Alice approves Bob for 50 tokens
        vm.prank(alice);
        dust.approve(bob, 50 * 1e18);

        logAllowance("allowance after approve", alice, bob);
        emit log_string("attempt burnFrom above allowance");

        // Bob tries to burn 100 tokens
        vm.prank(bob);
        vm.expectRevert("ERC20: insufficient allowance");
        dust.burnFrom(alice, 100 * 1e18);

        logAllowance("allowance after burnFrom revert", alice, bob);
    }

    function testBurnFromWithMaxApproval() public {
        // Alice gives max approval
        vm.prank(alice);
        dust.approve(bob, type(uint256).max);

        logAllowance("allowance after max approve", alice, bob);

        uint256 burnAmount = 100 * 1e18;
        uint256 aliceBalanceBefore = dust.balanceOf(alice);

        vm.prank(bob);
        dust.burnFrom(alice, burnAmount);

        // With max approval, allowance should remain max (not decrease)
        assertEq(dust.allowance(alice, bob), type(uint256).max, "Max allowance should remain unchanged");
        assertEq(dust.balanceOf(alice), aliceBalanceBefore - burnAmount, "Balance should decrease");

        logAllowance("allowance after burnFrom", alice, bob);
        logState("after burnFrom with max approval");
    }

    function testBurnFromEmitsTransferEvent() public {
        uint256 burnAmount = 75 * 1e18;

        vm.prank(alice);
        dust.approve(bob, burnAmount);

        logAllowance("allowance after approve", alice, bob);

        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, address(0), burnAmount);

        vm.prank(bob);
        dust.burnFrom(alice, burnAmount);

        logState("after burnFrom emit check");
    }

    function testMultipleBurnsAccumulate() public {
        uint256 totalSupplyBefore = dust.totalSupply();

        logState("before multiple burns");

        // Multiple burns from different users
        vm.prank(alice);
        dust.burn(100 * 1e18);

        vm.prank(bob);
        dust.burn(50 * 1e18);

        vm.prank(owner);
        dust.burn(200 * 1e18);

        uint256 totalBurned = 350 * 1e18;
        uint256 totalSupplyAfter = dust.totalSupply();

        assertEq(totalSupplyAfter, totalSupplyBefore - totalBurned, "Total supply should reflect all burns");

        emit log_named_uint("Total burned", totalBurned);
        emit log_named_uint("Final total supply", totalSupplyAfter);
        logState("after multiple burns");
    }

    function testBurnZeroAmount() public {
        uint256 balanceBefore = dust.balanceOf(alice);
        uint256 totalSupplyBefore = dust.totalSupply();

        logState("before zero burn");

        vm.prank(alice);
        dust.burn(0);

        assertEq(dust.balanceOf(alice), balanceBefore, "Balance should not change");
        assertEq(dust.totalSupply(), totalSupplyBefore, "Total supply should not change");
        logState("after zero burn");
    }

    function testFuzzBurn(uint256 burnAmount) public {
        uint256 aliceBalance = dust.balanceOf(alice);
        burnAmount = bound(burnAmount, 0, aliceBalance);

        uint256 totalSupplyBefore = dust.totalSupply();

        vm.prank(alice);
        dust.burn(burnAmount);

        assertEq(dust.balanceOf(alice), aliceBalance - burnAmount);
        assertEq(dust.totalSupply(), totalSupplyBefore - burnAmount);
    }
}
