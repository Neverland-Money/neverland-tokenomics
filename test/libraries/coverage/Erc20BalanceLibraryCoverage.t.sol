// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Erc20BalanceLibrary} from "../../../src/libraries/Erc20BalanceLibrary.sol";

contract ConformingErc20 {
    uint256 internal _balance;

    constructor(uint256 balance_) {
        _balance = balance_;
    }

    function balanceOf(address) external view returns (uint256) {
        return _balance;
    }
}

contract Erc20BalanceHarness {
    function tryBalanceOf(address token, address account) external view returns (bool ok, uint256 balance) {
        return Erc20BalanceLibrary.tryBalanceOf(token, account);
    }

    function freeMemoryPointerAfterTryBalanceOf(address token, address account)
        external
        view
        returns (uint256 freePtr)
    {
        Erc20BalanceLibrary.tryBalanceOf(token, account);
        assembly ("memory-safe") {
            freePtr := mload(0x40)
        }
    }
}

contract RevertingErc20 {
    function balanceOf(address) external pure returns (uint256) {
        revert("BALANCE_UNAVAILABLE");
    }
}

contract ShortReturnErc20 {
    /// @dev Returns 4 bytes (< 32) for any call so `tryBalanceOf` hits the malformed-returndata arm.
    fallback() external {
        assembly {
            mstore(0x00, 1)
            return(0x00, 4)
        }
    }
}

contract ReturnBombErc20 {
    uint256 internal immutable _balance;

    constructor(uint256 balance_) {
        _balance = balance_;
    }

    /// @dev Returns a 512KB payload (first word = balance) so an unbounded returndata copy would OOG the caller.
    fallback() external {
        uint256 bal = _balance;
        assembly {
            mstore(0x00, bal)
            return(0x00, 0x80000)
        }
    }
}

/**
 * @title Erc20BalanceLibraryCoverageTest
 * @notice Exercises every arm of Erc20BalanceLibrary.tryBalanceOf — the conforming read, fail-soft
 *         paths (reverting token, malformed short returndata, non-contract, and precompile), the
 *         aligned-memory postcondition, and the bounded-returndata guard against an oversized
 *         "return bomb" payload.
 * @dev Wraps the internal library in a harness so the staticcall path is reachable from the public ABI.
 */
contract Erc20BalanceLibraryCoverageTest is Test {
    Erc20BalanceHarness internal harness;

    address internal constant ACCOUNT = address(0xBEEF);

    function setUp() public {
        harness = new Erc20BalanceHarness();
    }

    function testTryBalanceOfFailsSoftOnMalformedReturnData() public {
        ShortReturnErc20 token = new ShortReturnErc20();

        (bool ok, uint256 balance) = harness.tryBalanceOf(address(token), ACCOUNT);

        assertFalse(ok);
        assertEq(balance, 0);
    }

    function testTryBalanceOfFailsSoftOnNonContract() public view {
        (bool ok, uint256 balance) = harness.tryBalanceOf(address(0xDEAD), ACCOUNT);

        assertFalse(ok);
        assertEq(balance, 0);
    }

    function testTryBalanceOfFailsSoftOnPrecompile() public view {
        (bool ok, uint256 balance) = harness.tryBalanceOf(address(0x04), ACCOUNT);

        assertFalse(ok);
        assertEq(balance, 0);
    }

    function testTryBalanceOfFailsSoftOnRevertingToken() public {
        RevertingErc20 token = new RevertingErc20();

        (bool ok, uint256 balance) = harness.tryBalanceOf(address(token), ACCOUNT);

        assertFalse(ok);
        assertEq(balance, 0);
    }

    function testTryBalanceOfReadsConformingToken() public {
        ConformingErc20 token = new ConformingErc20(123e18);

        (bool ok, uint256 balance) = harness.tryBalanceOf(address(token), ACCOUNT);

        assertTrue(ok);
        assertEq(balance, 123e18);
    }

    function testTryBalanceOfLeavesFreeMemoryPointerWordAligned() public {
        ConformingErc20 token = new ConformingErc20(123e18);

        uint256 freePtr = harness.freeMemoryPointerAfterTryBalanceOf(address(token), ACCOUNT);

        assertEq(freePtr % 32, 0);
    }

    function testTryBalanceOfBoundsOversizedReturndata() public {
        ReturnBombErc20 token = new ReturnBombErc20(77e18);

        // The bounded staticcall copies a single word, so the forwarded call survives this tight stipend.
        // The gas cap, not the asserts, is what makes this a true return-bomb regression pin.
        (bool ok, uint256 balance) = harness.tryBalanceOf{gas: 850_000}(address(token), ACCOUNT);

        assertTrue(ok);
        assertEq(balance, 77e18);
    }
}
