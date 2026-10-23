// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IACLManager} from "@neverland-money/lending-core/contracts/interfaces/IACLManager.sol";
import {
    IAaveIncentivesController
} from "@neverland-money/lending-core/contracts/interfaces/IAaveIncentivesController.sol";
import {IPool} from "@neverland-money/lending-core/contracts/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@neverland-money/lending-core/contracts/interfaces/IPoolAddressesProvider.sol";
import {
    ReserveConfiguration
} from "@neverland-money/lending-core/contracts/protocol/libraries/configuration/ReserveConfiguration.sol";
import {Errors} from "@neverland-money/lending-core/contracts/protocol/libraries/helpers/Errors.sol";
import {DataTypes} from "@neverland-money/lending-core/contracts/protocol/libraries/types/DataTypes.sol";
import {AToken} from "@neverland-money/lending-core/contracts/protocol/tokenization/AToken.sol";
import {StableDebtToken} from "@neverland-money/lending-core/contracts/protocol/tokenization/StableDebtToken.sol";
import {VariableDebtToken} from "@neverland-money/lending-core/contracts/protocol/tokenization/VariableDebtToken.sol";

/**
 * @title TestPoolConfigurator
 * @author Neverland
 * @notice Configurator for integration tests that drives the real Pool through the entry points the lending
 *         core's PoolConfigurator uses
 * @dev NOT FOR PRODUCTION USE. The core's PoolConfigurator cannot be compiled with the optimizer disabled, which
 *      is the configuration Forge coverage and the unoptimized CI build use, so this harness stands in for it.
 *      Reserve initialization mirrors ConfiguratorLogic.executeInitReserve with directly initialized token
 *      instances instead of proxies, and every setter keeps the core's risk-or-pool-admin gate on the real
 *      ACLManager so freeze calls are exercised against the actual configurator role check.
 */
contract TestPoolConfigurator {
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev The pool's addresses provider, resolved for the ACLManager on every call
    IPoolAddressesProvider private immutable _provider;

    /// @dev The real pool this configurator drives
    IPool private immutable _pool;

    /*//////////////////////////////////////////////////////////////
                             ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts the caller to risk or pool admins, exactly as the core's configurator does
    modifier onlyRiskOrPoolAdmins() {
        IACLManager acl = IACLManager(_provider.getACLManager());
        require(acl.isRiskAdmin(msg.sender) || acl.isPoolAdmin(msg.sender), Errors.CALLER_NOT_RISK_OR_POOL_ADMIN);

        _;
    }

    /**
     * @notice Binds the configurator to a provider and its pool
     * @param provider The pool's addresses provider
     */
    constructor(IPoolAddressesProvider provider) {
        _provider = provider;
        _pool = IPool(provider.getPool());
    }

    /*//////////////////////////////////////////////////////////////
                           RESERVE LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes one reserve with fresh token instances and the zero-rate strategy
     * @dev Mirrors ConfiguratorLogic.executeInitReserve: initialize the three tokens, register the reserve on
     *      the pool, then write the decimals and active flag.
     * @param asset The underlying asset
     * @param decimals The underlying asset's decimals
     * @param strategy The interest rate strategy
     * @param treasury The treasury receiving the reserve factor
     */
    function initReserve(address asset, uint8 decimals, address strategy, address treasury)
        external
        onlyRiskOrPoolAdmins
    {
        AToken aToken = new AToken(_pool);
        aToken.initialize(
            _pool, treasury, asset, IAaveIncentivesController(address(0)), decimals, "Receipt", "aToken", ""
        );
        StableDebtToken stableDebt = new StableDebtToken(_pool);
        stableDebt.initialize(_pool, asset, IAaveIncentivesController(address(0)), decimals, "Stable debt", "sDebt", "");
        VariableDebtToken variableDebt = new VariableDebtToken(_pool);
        variableDebt.initialize(
            _pool, asset, IAaveIncentivesController(address(0)), decimals, "Variable debt", "vDebt", ""
        );
        _pool.initReserve(asset, address(aToken), address(stableDebt), address(variableDebt), strategy);

        DataTypes.ReserveConfigurationMap memory config = DataTypes.ReserveConfigurationMap(0);
        config.setDecimals(decimals);
        config.setActive(true);
        config.setPaused(false);
        config.setFrozen(false);
        _pool.setConfiguration(asset, config);
    }

    /*//////////////////////////////////////////////////////////////
                           RESERVE SETTINGS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets a reserve's collateral parameters
     * @param asset The reserve asset
     * @param ltv The loan-to-value in basis points
     * @param liquidationThreshold The liquidation threshold in basis points
     * @param liquidationBonus The liquidation bonus in basis points, above 10,000
     */
    function configureReserveAsCollateral(
        address asset,
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 liquidationBonus
    ) external onlyRiskOrPoolAdmins {
        DataTypes.ReserveConfigurationMap memory config = _pool.getConfiguration(asset);
        config.setLtv(ltv);
        config.setLiquidationThreshold(liquidationThreshold);
        config.setLiquidationBonus(liquidationBonus);
        _pool.setConfiguration(asset, config);
    }

    /**
     * @notice Enables or disables borrowing of a reserve
     * @param asset The reserve asset
     * @param enabled Whether variable borrowing is enabled
     */
    function setReserveBorrowing(address asset, bool enabled) external onlyRiskOrPoolAdmins {
        DataTypes.ReserveConfigurationMap memory config = _pool.getConfiguration(asset);
        config.setBorrowingEnabled(enabled);
        _pool.setConfiguration(asset, config);
    }

    /**
     * @notice Freezes or unfreezes a reserve through the real configurator role gate
     * @param asset The reserve asset
     * @param freeze The new frozen flag
     */
    function setReserveFreeze(address asset, bool freeze) external onlyRiskOrPoolAdmins {
        DataTypes.ReserveConfigurationMap memory config = _pool.getConfiguration(asset);
        config.setFrozen(freeze);
        _pool.setConfiguration(asset, config);
    }

    /*//////////////////////////////////////////////////////////////
                                 E-MODE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates or updates an efficiency-mode category
     * @param categoryId The category id
     * @param ltv The category loan-to-value in basis points
     * @param liquidationThreshold The category liquidation threshold in basis points
     * @param liquidationBonus The category liquidation bonus in basis points
     * @param oracle The category price source, or the zero address for none
     * @param label The category label
     */
    function setEModeCategory(
        uint8 categoryId,
        uint16 ltv,
        uint16 liquidationThreshold,
        uint16 liquidationBonus,
        address oracle,
        string calldata label
    ) external onlyRiskOrPoolAdmins {
        _pool.configureEModeCategory(
            categoryId,
            DataTypes.EModeCategory({
                ltv: ltv,
                liquidationThreshold: liquidationThreshold,
                liquidationBonus: liquidationBonus,
                priceSource: oracle,
                label: label
            })
        );
    }

    /**
     * @notice Assigns a reserve to an efficiency-mode category
     * @param asset The reserve asset
     * @param categoryId The category id, or 0 for none
     */
    function setAssetEModeCategory(address asset, uint8 categoryId) external onlyRiskOrPoolAdmins {
        DataTypes.ReserveConfigurationMap memory config = _pool.getConfiguration(asset);
        config.setEModeCategory(categoryId);
        _pool.setConfiguration(asset, config);
    }
}
