// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/**
 * @title TestERC721Receiver
 * @author Neverland
 * @notice Minimal ERC721 receiver used in tests and local tooling
 */
contract TestERC721Receiver is IERC721Receiver {
    /**
     * @notice Accepts all ERC721 transfers
     * @param operator Address that initiated the transfer
     * @param from Previous owner of the token
     * @param tokenId ERC721 token ID
     * @param data Opaque callback payload
     * @return selector IERC721Receiver acceptance magic value
     */
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        pure
        override
        returns (bytes4 selector)
    {
        operator;
        from;
        tokenId;
        data;
        selector = IERC721Receiver.onERC721Received.selector;
    }
}
