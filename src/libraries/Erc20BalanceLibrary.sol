// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Erc20BalanceLibrary
 * @author Neverland
 * @notice Shared helpers for reading ERC20 balances defensively, without bubbling reverts on
 *         non-conforming or non-callable tokens. The read is a neutral `(ok, balance)` primitive:
 *         callers decide how to treat an unreadable balance (fail-soft, defer, or revert).
 */
library Erc20BalanceLibrary {
    /**
     * @notice Reads `balanceOf(account)` via a low-level staticcall without bubbling token reverts.
     * @dev Returns `ok = false` (and `bal = 0`) when the token has no code, the call reverts,
     *      or the returndata is shorter than 32 bytes. On success returns the first returndata word as
     *      the balance. The staticcall copies at most one word of returndata, so a non-conforming token
     *      cannot force an out-of-gas in the caller by returning an oversized payload ("return bomb").
     *      This helper still forwards the remaining gas to the token; malicious gas-burning implementations
     *      can make the caller run out of gas.
     * @param token The ERC20 token to query
     * @param account The account whose balance is read
     * @return ok True when the balance was read successfully
     * @return bal The balance, or zero when `ok` is false
     */
    function tryBalanceOf(address token, address account) internal view returns (bool ok, uint256 bal) {
        if (token.code.length == 0) return (false, 0);

        bytes4 selector = IERC20.balanceOf.selector;
        // Bounded staticcall: the returndata copy is capped at one word, so an oversized return cannot OOG the caller.
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            mstore(add(ptr, 0x04), and(account, 0xffffffffffffffffffffffffffffffffffffffff))
            let out := add(ptr, 0x24)
            let success := staticcall(gas(), token, ptr, 0x24, out, 0x20)
            if and(success, iszero(lt(returndatasize(), 0x20))) {
                bal := mload(out)
                ok := 1
            }
            let end := add(out, 0x20)
            mstore(0x40, and(add(end, 0x1f), not(0x1f)))
        }
    }
}
