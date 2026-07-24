// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

abstract contract GovernanceAddressBookReader is Test {
    using stdJson for string;

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
        address hardcodedPriceOracleLoAznd;
        address pendlePtDiscountOracleAdapter;
        address specialEditionRegistry;
        address specialEditionRegistryImplementation;
        address userVaultBeacon;
        address dustLockTransferStrategy;
        address tokenomicsDustHelper;
        address tokenomicsUiProvider;
        address tokenomicsUiEmissionLibrary;
    }

    function _loadGovernanceAddressBook(string memory network)
        internal
        view
        returns (GovernanceAddressBook memory book)
    {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", network, "/addresses.json"));

        book.governanceSafe = _readOptionalAddress(json, ".governance.governanceSafe");
        if (book.governanceSafe == address(0)) {
            book.governanceSafe = json.readAddress(".governance.foundationSafe");
        }
        book.sentinelSafe = _readOptionalAddress(json, ".governance.sentinelSafe");
        book.governanceTimelock = _readOptionalAddress(json, ".governance.timelocks.governance");
        book.riskTimelock = _readOptionalAddress(json, ".governance.timelocks.risk");
        book.lendingPoolAddressesProvider = _readOptionalAddress(json, ".governance.lending.poolAddressesProvider");
        if (book.lendingPoolAddressesProvider == address(0)) {
            book.lendingPoolAddressesProvider = json.readAddress(".governance.aave.poolAddressesProvider");
        }
        book.lendingPoolAddressesProviderRegistry =
            _readOptionalAddress(json, ".governance.lending.poolAddressesProviderRegistry");
        if (book.lendingPoolAddressesProviderRegistry == address(0)) {
            book.lendingPoolAddressesProviderRegistry =
                json.readAddress(".governance.aave.poolAddressesProviderRegistry");
        }
        book.lendingReservesSetupHelper = _readOptionalAddress(json, ".governance.lending.reservesSetupHelper");
        if (book.lendingReservesSetupHelper == address(0)) {
            book.lendingReservesSetupHelper = json.readAddress(".governance.aave.reservesSetupHelper");
        }
        book.lendingWrappedTokenGateway = _readOptionalAddress(json, ".governance.lending.wrappedTokenGateway");
        if (book.lendingWrappedTokenGateway == address(0)) {
            book.lendingWrappedTokenGateway = json.readAddress(".governance.aave.wrappedTokenGateway");
        }
        book.coreProxyAdmin = _readOptionalAddress(json, ".governance.tokenomics.upgradeability.coreProxyAdmin");
        if (book.coreProxyAdmin == address(0)) {
            book.coreProxyAdmin = _readOptionalAddress(json, ".governance.neverland.upgradeability.coreProxyAdmin");
        }
        if (book.coreProxyAdmin == address(0)) {
            book.coreProxyAdmin = _readOptionalAddress(json, ".proxyAdmin");
        }
        book.leaderboardProxyAdmin =
            _readOptionalAddress(json, ".governance.tokenomics.upgradeability.leaderboardProxyAdmin");
        if (book.leaderboardProxyAdmin == address(0)) {
            book.leaderboardProxyAdmin =
                _readOptionalAddress(json, ".governance.neverland.upgradeability.leaderboardProxyAdmin");
        }
        book.hardcodedPriceOracleLoAznd = _readOptionalAddress(json, ".addresses.HardcodedPriceOracle-loAZND-103500000");
        book.pendlePtDiscountOracleAdapter =
            _readOptionalAddress(json, ".addresses.PendlePtDiscountOracleAdapter-AUSD-1791417600");
        book.specialEditionRegistry = _readOptionalAddress(json, ".addresses.SpecialEditionRegistry");
        book.specialEditionRegistryImplementation =
            _readOptionalAddress(json, ".implementations.SpecialEditionRegistry");
        book.userVaultBeacon = _readOptionalAddress(json, ".governance.tokenomics.upgradeability.userVaultBeacon");
        if (book.userVaultBeacon == address(0)) {
            book.userVaultBeacon = _readOptionalAddress(json, ".governance.neverland.upgradeability.userVaultBeacon");
        }
        if (book.userVaultBeacon == address(0)) {
            book.userVaultBeacon = _readOptionalAddress(json, ".addresses.UserVaultBeacon");
        }
        book.dustLockTransferStrategy = _readOptionalAddress(json, ".addresses.DustLockTransferStrategy");
        book.tokenomicsDustHelper = _readOptionalAddress(json, ".addresses.NeverlandDustHelper");
        book.tokenomicsUiProvider = _readOptionalAddress(json, ".addresses.NeverlandUiProvider");
        book.tokenomicsUiEmissionLibrary = _readOptionalAddress(json, ".addresses.NeverlandUiEmissionLibrary");
    }

    function readOptionalAddress(string memory json, string memory path) external pure returns (address) {
        string memory raw = json.readString(path);
        if (bytes(raw).length == 0) {
            return address(0);
        }

        return vm.parseAddress(raw);
    }

    function _readOptionalAddress(string memory json, string memory path) internal view returns (address) {
        try this.readOptionalAddress(json, path) returns (address value) {
            return value;
        } catch {
            return address(0);
        }
    }
}
