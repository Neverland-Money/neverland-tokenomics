// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {GovernanceAddressBookReader} from "./_utils/GovernanceAddressBookReader.sol";

contract GovernanceAddressBookTest is GovernanceAddressBookReader {
    function test_loadsCanonicalMainnetGovernanceSurfaces() public view {
        GovernanceAddressBook memory addressBook = _loadGovernanceAddressBook("mainnet");

        assertEq(addressBook.governanceSafe, 0x57976e192C45461F5958045a0bC57102e90440eD);
        assertEq(addressBook.sentinelSafe, 0x06Fe1d4F4B7cA7D3d1fB3164968F0F7383D02e0E);
        assertEq(addressBook.governanceTimelock, 0x3e4749D9Df7EC5ecd9184c301592bAc058a6F82f);
        assertEq(addressBook.riskTimelock, 0x7fa9e0E4dA21d5e92c70815B1B25F39726fD963b);
        assertEq(addressBook.lendingPoolAddressesProvider, 0x49D75170F55C964dfdd6726c74fdEDEe75553A0f);
        assertEq(addressBook.coreProxyAdmin, 0x6400650cED1eD7179143D40b4431c3cC8c068D90);
        assertEq(addressBook.leaderboardProxyAdmin, 0x400916532d9298acfFD49B826258738115CF23f1);
        assertEq(addressBook.userVaultBeacon, 0xc9Fe3Db9b14A538FaB2eeBa33a8FeaB6ED7DdCeb);
        assertEq(addressBook.dustLockTransferStrategy, 0x958192C6208b3289951342eDDE1a051dE4E955bb);
        assertEq(addressBook.tokenomicsDustHelper, 0x4b80e62364Ee452e8C9d3ea342E445f515A2CD9b);
        assertEq(addressBook.tokenomicsUiProvider, 0x1Aa6CECB9E2e62aBAfcc82Cf2F2f4b8793ABbC4c);
    }
}
