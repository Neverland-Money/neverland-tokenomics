// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @notice Raised when zero is supplied as an addresses-provider id.
error InvalidAddressesProviderId();

/**
 * @title MockPoolAddressesProviderRegistry
 * @notice Minimal test double for `IPoolAddressesProviderRegistry`, shared across the
 *         NeverlandUiProvider test files that construct a provider needing a registry address.
 * @dev Implements the real interface shape (including the mutator) rather than a partial stub, so
 *      tests exercise the same selectors `NeverlandUiProvider` calls in production:
 *      `getAddressesProvidersList`, `getAddressesProviderIdByAddress`, `getAddressesProviderAddressById`.
 */
contract MockPoolAddressesProviderRegistry {
    address[] private _providers;
    mapping(address => uint256) private _providerToId;
    mapping(uint256 => address) private _idToProvider;

    function registerAddressesProvider(address provider, uint256 id) external {
        if (id == 0) revert InvalidAddressesProviderId();

        if (_providerToId[provider] == 0) {
            _providers.push(provider);
        }
        _providerToId[provider] = id;
        _idToProvider[id] = provider;
    }

    function unregisterAddressesProvider(address provider) external {
        uint256 id = _providerToId[provider];
        delete _providerToId[provider];
        delete _idToProvider[id];

        uint256 len = _providers.length;
        for (uint256 i; i < len; ++i) {
            if (_providers[i] == provider) {
                _providers[i] = _providers[len - 1];
                _providers.pop();
                break;
            }
        }
    }

    function getAddressesProvidersList() external view returns (address[] memory) {
        return _providers;
    }

    function getAddressesProviderIdByAddress(address provider) external view returns (uint256) {
        return _providerToId[provider];
    }

    function getAddressesProviderAddressById(uint256 id) external view returns (address) {
        return _idToProvider[id];
    }
}
