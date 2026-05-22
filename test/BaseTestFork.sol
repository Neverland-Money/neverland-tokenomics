// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseTest} from "./BaseTest.sol";

abstract contract BaseTestFork is BaseTest {
    string internal FORK_RPC_URL = vm.envOr("FORK_RPC_URL", string("https://rpc-mainnet.monadinfra.com"));

    function _testSetup() internal virtual override {
        // Fork current mainnet block
        uint256 forkId = vm.createFork(FORK_RPC_URL);
        vm.selectFork(forkId);

        // deploy contracts
        super._testSetup();
    }
}
