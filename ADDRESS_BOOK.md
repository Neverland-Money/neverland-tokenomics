# Address Book

Recorded deployments for Monad mainnet (chain ID 143), carried forward from the development repository for the 1.2.0 public release. These entries describe the recorded configuration; they are not a fresh verification of live contract state or current role membership.

The tables below are the canonical address source. `yarn build:addresses` generates the package's machine-readable JSON from these rows. Keys preserve the complete existing export schema, including `addresses.Dust`; an `@` value refers to another key, so compatibility aliases do not maintain a second address value.

The retired loAZND yield-bearing and fixed-price feeds remain recorded as historical entries. `GovernedPriceOracle-LOAZND` is the current recorded loAZND feed. Expired PT markets are labeled historical; an address remaining in this book does not imply that opening new positions is supported.

## Network

| Key | Value | Status / notes |
| --- | --- | --- |
| `networkName` | `monadMainnet` |  |
| `chainId` | `143` |  |

## Contracts

| Key | Value | Status / notes |
| --- | --- | --- |
| `addresses.Dust` | `0xAD96C3dffCD6374294e2573A7fBBA96097CC8d7c` |  |
| `addresses.DustLock` | `0xBB4738D05AD1b3Da57a4881baE62Ce9bb1eEeD6C` |  |
| `addresses.DustRewardsController` | `0x57ea245cCbFAb074baBb9d01d1F0c60525E52cec` |  |
| `addresses.UserVaultRegistry` | `0x794CCdb375Ab08C340528a71Ba433a9016c657A5` |  |
| `addresses.UserVaultImplementation` | `0x0904B276a467CfCBD7B2F900aDaAAD783AEeC98F` |  |
| `addresses.UserVaultBeacon` | `0xc9Fe3Db9b14A538FaB2eeBa33a8FeaB6ED7DdCeb` |  |
| `addresses.UserVaultFactory` | `0xe82f2fa836BC5DB42a36C66027c0113BcAA28143` |  |
| `addresses.RevenueReward` | `0xff20ac10eb808B1e31F5CfCa58D80eDE2Ba71c43` |  |
| `addresses.DustLockTransferStrategy` | `0xa966190d7BD099718110103d1778bb232Bd1661E` |  |
| `addresses.NeverlandDustHelper` | `0x4b80e62364Ee452e8C9d3ea342E445f515A2CD9b` |  |
| `addresses.NeverlandUiProvider` | `0x74132CE97c02E286d221715B3df6094790A1DEc1` |  |
| `addresses.NeverlandUiEmissionLibrary` | `0x01E0fbB8edA41bEFB76645B94A1fcaE308410381` |  |
| `addresses.DustLockLegendaryLedger` | `0x367973382fa8Fc9508B5C8f4B0F9EEd462aF3185` |  |
| `addresses.NeverlandProfileItemsSeller` | `0xcEE8d6d42a37a9d721B41CeFa16DaB7F0d0a14EB` |  |
| `addresses.HardcodedPriceOracle-loAZND-103500000` | `0x63B54daC13CD84bb92Ef24007F4E41c188f28424` | Historical loAZND feed; replaced by GovernedPriceOracle-LOAZND. |
| `addresses.PendlePtDiscountOracleAdapter-AUSD-1791417600` | `0x1Df73A14709FeEAc83386fd1b8099dEc4B00f789` | Historical market; PT maturity was October 8, 2026. |
| `addresses.EpochManager` | `0xdA27A7745CBE958B0d00268cf63394A0d09c0216` |  |
| `addresses.LeaderboardConfig` | `0xDff18C7a928544449eF2Bb84c609f95427d7fcc8` |  |
| `addresses.LeaderboardKeeper` | `0x550eAaD1Ddc5Fd13Bc9818D99f985E7367D5D2B9` |  |
| `addresses.SpecialEditionRegistry` | `0x9A0231CeaB25EA0D820cfE73bFC3cd2D7681d532` |  |
| `addresses.NFTPartnershipRegistry` | `0xAB71Ce6910F255CC61fAf78EBd69A2B3dbC26Cd9` |  |
| `addresses.VotingPowerMultiplier` | `0x9b203C61d03e64550BFbC17EF56438D1a67D80b7` |  |
| `addresses.PendlePtDiscountOracleAdapter-sUSDE-1792627200` | `0xe976282Bf72b8c537f07e1e22664fBd1D2C30B0d` | Historical market; PT maturity was October 22, 2026. |
| `addresses.GovernedPriceOracle-LOAZND` | `0x9eF202F1A9962138a5918721Aa36b4665634975F` | Current recorded loAZND governed feed. |
| `addresses.NeverlandAssetRedemption-nLOAZND-USDC` | `0xd1B443f2601C09b165C837d3875156599cd86164` |  |
| `addresses.PendlePtDiscountOracleAdapter-shMON-1805328000` | `0x6db6a7b0f7Ac248226aF14997223fe9D3088f204` |  |
| `addresses.NeverlandNativeGateway-shMON` | `0x05e61c923093e569401Edc2ac6AeAE01E7e60a53` |  |
| `addresses.NeverlandUiEnumerationLibrary` | `0x74611cDd50a3b4009dE671F626308659FBD93667` |  |
| `addresses.NeverlandUiPriceMarketLibrary` | `0x2bA6Cf5d5595D6065B6F94dE370beB4c18d3bFec` |  |
| `addresses.NeverlandUiRewardsSummaryLibrary` | `0x4150513ED9E28a8707f89E057aFddb69F42a5E4c` |  |
| `addresses.PendlePtDiscountOracleAdapter-AUSD-1797465600` | `0x7B6230315d4a296E226a1fbfb301D9203cc5e7Cf` |  |
| `addresses.NeverlandPendleMaturityGateway-PendleAUSD` | `0x6bd37B72ADF69016589724c1425AE923edD29C8d` |  |
| `addresses.NeverlandPendleLeverager-PendleAUSD-8OCT2026` | `0x780E2BF8f86a3709bB59A4E1D995cD7cb24035b4` | Historical market; PT maturity was October 8, 2026. |
| `addresses.NeverlandPendleLeverager-PendleAUSD-17DEC2026` | `0xAEe599eEcf60F7979eCD6797431A52343FB53A45` |  |

## Implementations

| Key | Value | Status / notes |
| --- | --- | --- |
| `implementations.Dust` | `0xF59df2e38e23406c80ac778CCAA4319BAbe0D0d3` |  |
| `implementations.DustLock` | `0xf7533D3bfC31F0D3F6292e2336DA84434435f3b5` |  |
| `implementations.DustRewardsController` | `0x6aD1EcdA817ECB7696D21f6e600C7ec44AcFB1e6` |  |
| `implementations.UserVaultFactory` | `0x95AF995C9dcB1b6cFFEe6d81631dab5527884370` |  |
| `implementations.RevenueReward` | `0x7E5E603DF59278aF2B2d12521c0EC6f14fD2df8d` |  |
| `implementations.EpochManager` | `0x0E96e794F1e44Be76AdD3d089C90B1bBfA408dfE` |  |
| `implementations.LeaderboardConfig` | `0xb6f9F867E36c80aE77E9B415984A5529d9e62183` |  |
| `implementations.LeaderboardKeeper` | `0x7c79be563d002DBbe01Bc43667fe2d644674f52B` |  |
| `implementations.SpecialEditionRegistry` | `0xC1Ab101608a493dbcf91Af13ba9436802Dc8cdcf` |  |
| `implementations.NFTPartnershipRegistry` | `0x73921d9CD1397B8a81091d24227Ed587ef652dd0` |  |
| `implementations.VotingPowerMultiplier` | `0xaDDd72d36553B43E376a81e6a62dBA131b516dAb` |  |
| `implementations.NeverlandProfileItemsSeller` | `0x81882ce65044073F005cb6d3180A36fe1ef898F9` |  |

## Governance and administration

| Key | Value | Status / notes |
| --- | --- | --- |
| `governance.governanceSafe` | `0x57976e192C45461F5958045a0bC57102e90440eD` |  |
| `governance.sentinelSafe` | `0x06Fe1d4F4B7cA7D3d1fB3164968F0F7383D02e0E` |  |
| `governance.deployer` | `0x0000B06460777398083CB501793a4d6393900000` |  |
| `governance.timelocks.governance` | `0x3e4749D9Df7EC5ecd9184c301592bAc058a6F82f` |  |
| `governance.timelocks.risk` | `0x7fa9e0E4dA21d5e92c70815B1B25F39726fD963b` |  |
| `governance.lending.poolAddressesProvider` | `0x49D75170F55C964dfdd6726c74fdEDEe75553A0f` |  |
| `governance.lending.poolAddressesProviderRegistry` | `0xD0CCDe10CAcd12f1c839Db6400B82a82ab90fa9B` |  |
| `governance.lending.reservesSetupHelper` | `0xE7D17A88C66b4ED0b73872937cdC5e081C118DcD` |  |
| `governance.lending.wrappedTokenGateway` | `0x800409dBd7157813BB76501c30e04596Cc478f25` |  |
| `governance.tokenomics.upgradeability.coreProxyAdmin` | `0x6400650cED1eD7179143D40b4431c3cC8c068D90` |  |
| `governance.tokenomics.upgradeability.leaderboardProxyAdmin` | `0x400916532d9298acfFD49B826258738115CF23f1` |  |
| `governance.tokenomics.upgradeability.userVaultBeacon` | `0xc9Fe3Db9b14A538FaB2eeBa33a8FeaB6ED7DdCeb` |  |
| `governance.tokenomics.upgradeability.staticATokenProxyAdmin` | `0x0cBe49645BCC84eD90A6aA4D93dfEb2Cc836F721` |  |

## Runtime authority notes

| Key | Value | Status / notes |
| --- | --- | --- |
| `governance.tokenomics.runtimeSurfaceHints.Dust` | `Direct runtime owner/admin remains immediate in phase 1.` |  |
| `governance.tokenomics.runtimeSurfaceHints.DustLock` | `Direct runtime owner/admin remains immediate in phase 1.` |  |
| `governance.tokenomics.runtimeSurfaceHints.RevenueReward` | `Reward distributor remains direct and immediate in phase 1.` |  |
| `governance.tokenomics.runtimeSurfaceHints.DustRewardsController` | `Emission manager remains direct and immediate in phase 1.` |  |
| `governance.tokenomics.runtimeSurfaceHints.UserVaultRegistry` | `Direct runtime owner/admin remains immediate in phase 1.` |  |

## Linked libraries

| Key | Value | Status / notes |
| --- | --- | --- |
| `libraries.BalanceLogicLibrary` | `0xDb4C5406E178004FFe14D91eC7d536fF25396E98` |  |
| `libraries.NeverlandUiEmissionLibrary` | `0x01E0fbB8edA41bEFB76645B94A1fcaE308410381` |  |
| `libraries.CreatorTokenLibrary` | `0xDd96B606b8808688A5Be9EE324f8CA23534ad70A` |  |
| `libraries.NeverlandUiEnumerationLibrary` | `0x74611cDd50a3b4009dE671F626308659FBD93667` |  |
| `libraries.NeverlandUiPriceMarketLibrary` | `0x2bA6Cf5d5595D6065B6F94dE370beB4c18d3bFec` |  |
| `libraries.NeverlandUiRewardsSummaryLibrary` | `0x4150513ED9E28a8707f89E057aFddb69F42a5E4c` |  |

## Additional recorded oracles

| Key | Value | Status / notes |
| --- | --- | --- |
| `RatioOracleAggregator-SMON` | `0xF285a4B6e38151E27bBb846197707C8B9BAf8D55` |  |
| `RatioOracleAggregator-SHMON` | `0x39B76F22dcf8A93b68C72Fe2e63B3530168D0579` |  |
| `RatioOracleAggregator-GMON` | `0xbFc4Fc9376a0DA7929475379EB37DFCb9C553B9c` |  |
| `RatioOracleAggregator-EARNAUSD` | `0xF25c84187a7608036b6660205B6068DBc9560dB6` |  |
| `YieldBearingOracleAdapter-LOAZND` | `0x72e994F1EC71a0cdc74913534690510257e895F0` | Historical loAZND feed; replaced by GovernedPriceOracle-LOAZND. |
| `RatioOracleAggregator-SYZUSD` | `0x4D89F82C66b8B711B9f41f8152F5AaC1694B2F6D` |  |

## Compatibility aliases

| Key | Value | Status / notes |
| --- | --- | --- |
| `proxyAdmin` | `@governance.tokenomics.upgradeability.coreProxyAdmin` | Compatibility alias; generated from the canonical key. |
| `NeverlandDustHelper` | `@addresses.NeverlandDustHelper` | Compatibility alias; generated from the canonical key. |
| `NeverlandUiProvider` | `@addresses.NeverlandUiProvider` | Compatibility alias; generated from the canonical key. |
| `NeverlandUiEmissionLibrary` | `@addresses.NeverlandUiEmissionLibrary` | Compatibility alias; generated from the canonical key. |
| `EpochManager` | `@addresses.EpochManager` | Compatibility alias; generated from the canonical key. |
| `LeaderboardConfig` | `@addresses.LeaderboardConfig` | Compatibility alias; generated from the canonical key. |
| `NFTPartnershipRegistry` | `@addresses.NFTPartnershipRegistry` | Compatibility alias; generated from the canonical key. |
| `VotingPowerMultiplier` | `@addresses.VotingPowerMultiplier` | Compatibility alias; generated from the canonical key. |
| `LeaderboardKeeper` | `@addresses.LeaderboardKeeper` | Compatibility alias; generated from the canonical key. |
| `SpecialEditionRegistry` | `@addresses.SpecialEditionRegistry` | Compatibility alias; generated from the canonical key. |
| `EpochManagerImplementation` | `@implementations.EpochManager` | Compatibility alias; generated from the canonical key. |
| `LeaderboardConfigImplementation` | `@implementations.LeaderboardConfig` | Compatibility alias; generated from the canonical key. |
| `LeaderboardKeeperImplementation` | `@implementations.LeaderboardKeeper` | Compatibility alias; generated from the canonical key. |
| `SpecialEditionRegistryImplementation` | `@implementations.SpecialEditionRegistry` | Compatibility alias; generated from the canonical key. |
| `NFTPartnershipRegistryImplementation` | `@implementations.NFTPartnershipRegistry` | Compatibility alias; generated from the canonical key. |
| `VotingPowerMultiplierImplementation` | `@implementations.VotingPowerMultiplier` | Compatibility alias; generated from the canonical key. |
| `DustLockTransferStrategy` | `@addresses.DustLockTransferStrategy` | Compatibility alias; generated from the canonical key. |
| `HardcodedPriceOracle-loAZND-103500000` | `@addresses.HardcodedPriceOracle-loAZND-103500000` | Historical loAZND feed; replaced by GovernedPriceOracle-LOAZND. |
| `PendlePtDiscountOracleAdapter-AUSD-1791417600` | `@addresses.PendlePtDiscountOracleAdapter-AUSD-1791417600` | Historical market; PT maturity was October 8, 2026. |
| `PendlePtDiscountOracleAdapter-sUSDE-1792627200` | `@addresses.PendlePtDiscountOracleAdapter-sUSDE-1792627200` | Historical market; PT maturity was October 22, 2026. |
| `GovernedPriceOracle-LOAZND` | `@addresses.GovernedPriceOracle-LOAZND` | Current recorded loAZND governed feed. |
| `NeverlandAssetRedemption-nLOAZND-USDC` | `@addresses.NeverlandAssetRedemption-nLOAZND-USDC` | Compatibility alias; generated from the canonical key. |
| `PendlePtDiscountOracleAdapter-shMON-1805328000` | `@addresses.PendlePtDiscountOracleAdapter-shMON-1805328000` | Compatibility alias; generated from the canonical key. |
| `NeverlandNativeGateway-shMON` | `@addresses.NeverlandNativeGateway-shMON` | Compatibility alias; generated from the canonical key. |
| `NeverlandUiEnumerationLibrary` | `@addresses.NeverlandUiEnumerationLibrary` | Compatibility alias; generated from the canonical key. |
| `NeverlandUiPriceMarketLibrary` | `@addresses.NeverlandUiPriceMarketLibrary` | Compatibility alias; generated from the canonical key. |
| `NeverlandUiRewardsSummaryLibrary` | `@addresses.NeverlandUiRewardsSummaryLibrary` | Compatibility alias; generated from the canonical key. |
| `PendlePtDiscountOracleAdapter-AUSD-1797465600` | `@addresses.PendlePtDiscountOracleAdapter-AUSD-1797465600` | Compatibility alias; generated from the canonical key. |
| `NeverlandPendleMaturityGateway-PendleAUSD` | `@addresses.NeverlandPendleMaturityGateway-PendleAUSD` | Compatibility alias; generated from the canonical key. |
| `NeverlandPendleLeverager-PendleAUSD-8OCT2026` | `@addresses.NeverlandPendleLeverager-PendleAUSD-8OCT2026` | Historical market; PT maturity was October 8, 2026. |
| `NeverlandPendleLeverager-PendleAUSD-17DEC2026` | `@addresses.NeverlandPendleLeverager-PendleAUSD-17DEC2026` | Compatibility alias; generated from the canonical key. |
