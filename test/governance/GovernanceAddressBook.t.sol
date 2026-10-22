// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {GovernanceAddressBookReader} from "./_utils/GovernanceAddressBookReader.sol";

contract GovernanceAddressBookTest is GovernanceAddressBookReader {
    function test_loadsCanonicalMainnetGovernanceSurfaces() public view {
        GovernanceAddressBook memory addressBook = _loadGovernanceAddressBook();

        assertEq(addressBook.governanceSafe, 0x57976e192C45461F5958045a0bC57102e90440eD);
        assertEq(addressBook.sentinelSafe, 0x06Fe1d4F4B7cA7D3d1fB3164968F0F7383D02e0E);
        assertEq(addressBook.governanceTimelock, 0x3e4749D9Df7EC5ecd9184c301592bAc058a6F82f);
        assertEq(addressBook.riskTimelock, 0x7fa9e0E4dA21d5e92c70815B1B25F39726fD963b);
        assertEq(addressBook.lendingPoolAddressesProvider, 0x49D75170F55C964dfdd6726c74fdEDEe75553A0f);
        assertEq(addressBook.coreProxyAdmin, 0x6400650cED1eD7179143D40b4431c3cC8c068D90);
        assertEq(addressBook.leaderboardProxyAdmin, 0x400916532d9298acfFD49B826258738115CF23f1);
        assertEq(addressBook.historicalHardcodedPriceOracleLoAznd, 0x63B54daC13CD84bb92Ef24007F4E41c188f28424);
        assertEq(addressBook.governedPriceOracleLoAznd, 0x9eF202F1A9962138a5918721Aa36b4665634975F);
        assertEq(addressBook.pendlePtDiscountOracleAdapter, 0x7B6230315d4a296E226a1fbfb301D9203cc5e7Cf);
        assertEq(addressBook.specialEditionRegistry, 0x9A0231CeaB25EA0D820cfE73bFC3cd2D7681d532);
        assertEq(addressBook.specialEditionRegistryImplementation, 0xC1Ab101608a493dbcf91Af13ba9436802Dc8cdcf);
        assertEq(addressBook.userVaultBeacon, 0xc9Fe3Db9b14A538FaB2eeBa33a8FeaB6ED7DdCeb);
        assertEq(addressBook.dustLockTransferStrategy, 0xa966190d7BD099718110103d1778bb232Bd1661E);
        assertEq(addressBook.tokenomicsDustHelper, 0x4b80e62364Ee452e8C9d3ea342E445f515A2CD9b);
        assertNotEq(addressBook.tokenomicsUiProvider, address(0));
        assertNotEq(addressBook.tokenomicsUiEmissionLibrary, address(0));
    }
}
