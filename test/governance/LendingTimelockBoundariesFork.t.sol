// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LendingGovernanceReader} from "./_utils/LendingGovernanceReader.sol";

contract LendingTimelockBoundariesForkTest is LendingGovernanceReader {
    bool internal runLendingForkGovernanceTests;

    function setUp() public {
        runLendingForkGovernanceTests =
            vm.envOr("RUN_LENDING_FORK_GOVERNANCE_TESTS", vm.envOr("RUN_AAVE_FORK_GOVERNANCE_TESTS", false));
        if (!runLendingForkGovernanceTests) {
            vm.skip(true);
        }

        string memory forkRpcUrl = vm.envOr("FORK_RPC_URL", string("https://rpc-mainnet.monadinfra.com"));
        uint256 forkId = vm.createFork(forkRpcUrl);
        vm.selectFork(forkId);
    }

    function test_readsCurrentLiveLendingRoleAndOwnerStateFromCanonicalAddressBook() public view {
        GovernanceAddressBook memory addressBook = _loadGovernanceAddressBook("mainnet");
        LendingGovernanceSnapshot memory snapshot = _buildLendingGovernanceSnapshot(addressBook);

        assertEq(snapshot.aclAdmin, addressBook.governanceTimelock);
        assertTrue(_containsAddress(snapshot.defaultAdminMembers, addressBook.governanceTimelock));
        assertTrue(_containsAddress(snapshot.riskAdminMembers, addressBook.riskTimelock));
        assertEq(snapshot.providerOwner, addressBook.governanceTimelock);
    }
}
