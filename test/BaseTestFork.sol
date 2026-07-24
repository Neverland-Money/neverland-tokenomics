// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseTest} from "./BaseTest.sol";

abstract contract BaseTestFork is BaseTest {
    string internal MAINNET_RPC_URL = vm.envOr("MAINNET_RPC", string("https://rpc.monad.xyz"));

    function _testSetup() internal virtual override {
        // Fork current mainnet block by default; release runs may pin MAINNET_FORK_BLOCK for deterministic evidence.
        uint256 forkBlock = vm.envOr("MAINNET_FORK_BLOCK", uint256(0));
        uint256 forkId = forkBlock == 0 ? vm.createFork(MAINNET_RPC_URL) : vm.createFork(MAINNET_RPC_URL, forkBlock);
        vm.selectFork(forkId);

        // deploy contracts
        super._testSetup();
    }
}
