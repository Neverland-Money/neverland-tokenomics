// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockOwnableBeacon is Ownable {
    address public implementation;

    constructor(address initialOwner, address initialImplementation) {
        if (initialOwner != _msgSender()) {
            transferOwnership(initialOwner);
        }
        implementation = initialImplementation;
    }

    function upgradeTo(address newImplementation) external onlyOwner {
        require(newImplementation != address(0), "OwnableBeacon: new implementation is the zero address");
        implementation = newImplementation;
    }
}
