// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/**
 * @title MockPoolAddressesProvider
 * @notice Shared test double with configurable pool-data-provider and price-oracle pointers.
 */
contract MockPoolAddressesProvider {
    address private _poolDataProvider;
    address private _priceOracle;

    function setPoolDataProvider(address provider) external {
        _poolDataProvider = provider;
    }

    function setPriceOracle(address oracle) external {
        _priceOracle = oracle;
    }

    function getPoolDataProvider() external view returns (address) {
        return _poolDataProvider;
    }

    function getPriceOracle() external view returns (address) {
        return _priceOracle;
    }
}
