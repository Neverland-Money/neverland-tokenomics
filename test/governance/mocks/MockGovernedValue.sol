// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract MockGovernedValue is Initializable {
    uint256 public value;

    function initialize(uint256 initialValue) external initializer {
        value = initialValue;
    }

    function version() external pure virtual returns (uint256) {
        return 1;
    }
}
