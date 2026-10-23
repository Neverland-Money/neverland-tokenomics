// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

abstract contract GovernanceAddressBookReader is Test {
    struct GovernanceAddressBook {
        address governanceSafe;
        address sentinelSafe;
        address governanceTimelock;
        address riskTimelock;
        address lendingPoolAddressesProvider;
        address lendingPoolAddressesProviderRegistry;
        address lendingReservesSetupHelper;
        address lendingWrappedTokenGateway;
        address coreProxyAdmin;
        address leaderboardProxyAdmin;
        address historicalHardcodedPriceOracleLoAznd;
        address governedPriceOracleLoAznd;
        address pendlePtDiscountOracleAdapter;
        address specialEditionRegistry;
        address specialEditionRegistryImplementation;
        address userVaultBeacon;
        address dustLockTransferStrategy;
        address tokenomicsDustHelper;
        address tokenomicsUiProvider;
        address tokenomicsUiEmissionLibrary;
    }

    function _loadGovernanceAddressBook() internal view returns (GovernanceAddressBook memory book) {
        string memory markdown = vm.readFile(string.concat(vm.projectRoot(), "/ADDRESS_BOOK.md"));

        book.governanceSafe = _readAddress(markdown, "governance.governanceSafe");
        book.sentinelSafe = _readAddress(markdown, "governance.sentinelSafe");
        book.governanceTimelock = _readAddress(markdown, "governance.timelocks.governance");
        book.riskTimelock = _readAddress(markdown, "governance.timelocks.risk");
        book.lendingPoolAddressesProvider = _readAddress(markdown, "governance.lending.poolAddressesProvider");
        book.lendingPoolAddressesProviderRegistry =
            _readAddress(markdown, "governance.lending.poolAddressesProviderRegistry");
        book.lendingReservesSetupHelper = _readAddress(markdown, "governance.lending.reservesSetupHelper");
        book.lendingWrappedTokenGateway = _readAddress(markdown, "governance.lending.wrappedTokenGateway");
        book.coreProxyAdmin = _readAddress(markdown, "governance.tokenomics.upgradeability.coreProxyAdmin");
        book.leaderboardProxyAdmin =
            _readAddress(markdown, "governance.tokenomics.upgradeability.leaderboardProxyAdmin");
        book.historicalHardcodedPriceOracleLoAznd =
            _readAddress(markdown, "addresses.HardcodedPriceOracle-loAZND-103500000");
        book.governedPriceOracleLoAznd = _readAddress(markdown, "addresses.GovernedPriceOracle-LOAZND");
        book.pendlePtDiscountOracleAdapter =
            _readAddress(markdown, "addresses.PendlePtDiscountOracleAdapter-AUSD-1797465600");
        book.specialEditionRegistry = _readAddress(markdown, "addresses.SpecialEditionRegistry");
        book.specialEditionRegistryImplementation = _readAddress(markdown, "implementations.SpecialEditionRegistry");
        book.userVaultBeacon = _readAddress(markdown, "governance.tokenomics.upgradeability.userVaultBeacon");
        book.dustLockTransferStrategy = _readAddress(markdown, "addresses.DustLockTransferStrategy");
        book.tokenomicsDustHelper = _readAddress(markdown, "addresses.NeverlandDustHelper");
        book.tokenomicsUiProvider = _readAddress(markdown, "addresses.NeverlandUiProvider");
        book.tokenomicsUiEmissionLibrary = _readAddress(markdown, "addresses.NeverlandUiEmissionLibrary");
    }

    function _readAddress(string memory markdown, string memory key) internal pure returns (address) {
        string memory prefix = string.concat("| `", key, "` | `");
        uint256 position = vm.indexOf(markdown, prefix);
        require(position != type(uint256).max, string.concat("Missing address-book key: ", key));
        position += bytes(prefix).length;

        bytes memory document = bytes(markdown);
        require(position + 42 < document.length && document[position + 42] == bytes1("`"), "Invalid address row");
        bytes memory value = new bytes(42);
        for (uint256 i; i < value.length; ++i) {
            value[i] = document[position + i];
        }
        return vm.parseAddress(string(value));
    }
}
