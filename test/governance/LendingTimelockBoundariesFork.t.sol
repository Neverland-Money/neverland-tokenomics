// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {LendingGovernanceReader} from "./_utils/LendingGovernanceReader.sol";

contract LendingTimelockBoundariesForkTest is LendingGovernanceReader {
    function setUp() public {
        string memory forkRpcUrl = vm.envOr("MAINNET_RPC", string("https://rpc.monad.xyz"));
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
