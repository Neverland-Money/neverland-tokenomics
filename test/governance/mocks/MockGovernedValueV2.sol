// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockGovernedValue} from "./MockGovernedValue.sol";

contract MockGovernedValueV2 is MockGovernedValue {
    function setValue(uint256 newValue) external {
        value = newValue;
    }

    function version() external pure override returns (uint256) {
        return 2;
    }
}
