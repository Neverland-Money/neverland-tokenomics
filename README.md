# Neverland Contracts

<p>
  <a href="./README.md"><img src="https://img.shields.io/badge/Neverland%20Contracts-v1.0.2%20%C2%B7%20Monad%20mainnet%20%28143%29%20%C2%B7%20Public%20mirror%20%C2%B7%20BUSL--1.1-192170?style=for-the-badge" alt="Neverland Contracts v1.0.2 - Monad mainnet (143) - Public mirror - BUSL-1.1"/></a>
</p>

Public smart-contract mirror for Neverland Protocol.

This repository contains the first-party Solidity contracts, interfaces, public tests, architecture context, and public address book needed to review the Neverland tokenomics, vote-escrow, revenue, oracle, leaderboard, and self-repaying vault surfaces. Operational deployment scripts, Hardhat deployment tasks, Ignition modules, generated Safe payloads, Tenderly runbooks, private audit workpapers, and hotfix workflow artifacts are intentionally outside this repository.

## Deployed Contracts

Monad mainnet:

- Chain ID: `143`
- Network name: `monadMainnet`
- Address book: [`deployments/mainnet/addresses.json`](./deployments/mainnet/addresses.json)


| Contract                    | Address                                      | Purpose                                           |
| --------------------------- | -------------------------------------------- | ------------------------------------------------- |
| `Dust` proxy                | `0xAD96C3dffCD6374294e2573A7fBBA96097CC8d7c` | Protocol token                                    |
| `DustLock` proxy            | `0xBB4738D05AD1b3Da57a4881baE62Ce9bb1eEeD6C` | Vote-escrow `veDUST` NFT                          |
| `RevenueReward` proxy       | `0xff20ac10eb808B1e31F5CfCa58D80eDE2Ba71c43` | Epoch-based revenue distribution                  |
| `DustRewardsController`     | `0x57ea245cCbFAb074baBb9d01d1F0c60525E52cec` | Aave-style DUST emissions controller              |
| `DustLockTransferStrategy`  | `0x958192C6208b3289951342eDDE1a051dE4E955bb` | DUST claim delivery and lock strategy             |
| `UserVaultRegistry`         | `0x794CCdb375Ab08C340528a71Ba433a9016c657A5` | Executor, aggregator, and slippage policy         |
| `UserVaultFactory` proxy    | `0xe82f2fa836BC5DB42a36C66027c0113BcAA28143` | Per-user vault factory                            |
| `UserVaultBeacon`           | `0xc9Fe3Db9b14A538FaB2eeBa33a8FeaB6ED7DdCeb` | Beacon for `UserVault` instances                  |
| `UserVaultImplementation`   | `0x49f745b5265b6CA695E60e89dc50FD36edD252AB` | Current vault implementation                      |
| `NeverlandDustHelper`       | `0x4b80e62364Ee452e8C9d3ea342E445f515A2CD9b` | Read-only DUST price helper                       |
| `NeverlandUiProvider`       | `0x1Aa6CECB9E2e62aBAfcc82Cf2F2f4b8793ABbC4c` | Read-only protocol/user aggregation               |
| `DustLockLegendaryLedger`   | `0x367973382fa8Fc9508B5C8f4B0F9EEd462aF3185` | Legendary-ledger lock gateway                     |


## Leaderboard And Oracle Contracts


| Contract / Feed                    | Address                                      | Purpose                                |
| ---------------------------------- | -------------------------------------------- | -------------------------------------- |
| `EpochManager`                     | `0xdA27A7745CBE958B0d00268cf63394A0d09c0216` | Leaderboard epoch lifecycle            |
| `LeaderboardConfig`                | `0xDff18C7a928544449eF2Bb84c609f95427d7fcc8` | Dynamic scoring configuration          |
| `NFTPartnershipRegistry`           | `0xAB71Ce6910F255CC61fAf78EBd69A2B3dbC26Cd9` | Partner NFT multiplier registry        |
| `VotingPowerMultiplier`            | `0x9b203C61d03e64550BFbC17EF56438D1a67D80b7` | `veDUST` voting-power multiplier tiers |
| `RatioOracleAggregator-SMON`       | `0xF285a4B6e38151E27bBb846197707C8B9BAf8D55` | sMON price adapter                     |
| `RatioOracleAggregator-SHMON`      | `0x39B76F22dcf8A93b68C72Fe2e63B3530168D0579` | shMON price adapter                    |
| `RatioOracleAggregator-GMON`       | `0xbFc4Fc9376a0DA7929475379EB37DFCb9C553B9c` | gMON price adapter                     |
| `RatioOracleAggregator-EARNAUSD`   | `0xF25c84187a7608036b6660205B6068DBc9560dB6` | earnAUSD price adapter                 |
| `YieldBearingOracleAdapter-LOAZND` | `0x72e994F1EC71a0cdc74913534690510257e895F0` | loAZND yield-bearing price adapter     |


## Governance And Admin Addresses


| Role / Contract             | Address                                      | Notes                                                 |
| --------------------------- | -------------------------------------------- | ----------------------------------------------------- |
| Governance Timelock         | `0x3e4749D9Df7EC5ecd9184c301592bAc058a6F82f` | Delayed lending governance and tokenomics upgrade lane |
| Risk Timelock               | `0x7fa9e0E4dA21d5e92c70815B1B25F39726fD963b` | Lending `RISK_ADMIN` lane                             |
| Governance Safe             | `0x57976e192C45461F5958045a0bC57102e90440eD` | Governance proposer / executor / canceller            |
| Sentinel Safe               | `0x06Fe1d4F4B7cA7D3d1fB3164968F0F7383D02e0E` | Direct emergency admin                                |
| Core ProxyAdmin             | `0x6400650cED1eD7179143D40b4431c3cC8c068D90` | Core tokenomics proxy-admin surface                   |
| Leaderboard ProxyAdmin      | `0x400916532d9298acfFD49B826258738115CF23f1` | Leaderboard proxy-admin surface                       |
| UserVaultBeacon             | `0xc9Fe3Db9b14A538FaB2eeBa33a8FeaB6ED7DdCeb` | Beacon owner / upgrade surface                        |
| StaticAToken ProxyAdmin     | `0x0cBe49645BCC84eD90A6aA4D93dfEb2Cc836F721` | Static aToken proxy-admin surface                     |


## Development

```bash
git submodule update --init --recursive
yarn install
forge build
forge test
yarn hardhat compile
```

Public CI runs:

```bash
forge fmt --check
forge build --sizes
forge test -vvv
```

Useful local commands:

```bash
yarn tests
yarn tsc --noEmit --pretty false
forge test --match-contract DustLock -vv
forge test --match-path "test/flow/*" -vv
```

Hardhat is present for compilation and TypeChain generation only. Deployment tasks and operational scripts are not part of this public mirror.

## Deployment Shape

This public mirror exposes the canonical Monad mainnet address book and the contract/test surface needed for review. Production deployment, upgrade execution, governance payload generation, Safe batch export, Tenderly simulation, and hotfix workflows are maintained outside this repository.

The repository should be read as a public architecture and validation package:

1. `src/`: first-party contract implementations and interfaces.
2. `test/`: public Foundry validation surface.
3. `deployments/mainnet/addresses.json`: public live-address context.
4. `ARCHITECTURE.md` and `CONTEXT.md`: reviewer notes for topology, trust boundaries, and production assumptions.

## Layout

- `src/`: Neverland Solidity contracts and interfaces.
- `test/`: Foundry tests for unit, flow, governance, oracle, fork-aware, leaderboard, and regression coverage.
- `config/`: public read-only TypeScript configuration helpers.
- `deployments/`: public Monad mainnet address book.
- `.github/workflows/`: public Foundry CI workflow.
- `lib/`: Git submodules for Foundry, OpenZeppelin, Aave, Chainlink, PRB Math, and Uniswap dependencies.
- `ARCHITECTURE.md`: protocol topology and integration-boundary overview.
- `CONTEXT.md`: durable context for humans, reviewers, and scanners.

Private deployment, upgrade, Safe, Tenderly, audit-workpaper, and hotfix operations remain outside this repository.

## License And Notices

See [LICENSE](./LICENSE). SPDX identifiers in individual files are authoritative.

Neverland-authored code is generally licensed under Business Source License 1.1 and changes to MIT on `2028-07-20`. Aave-derived reward surfaces, Uniswap-dependent helper/oracle surfaces, interfaces, tests, and upstream submodules retain their respective SPDX and upstream licenses.

Security researchers should responsibly disclose vulnerabilities to `security@neverland.money`.

> **Note:** This repository is the public Neverland contracts mirror for review, testing, and architecture context. Production deployment and upgrade execution workflows are maintained outside this repository.

<p>
  <a href="https://neverland.money"><img src="https://img.shields.io/badge/Website-neverland.money-480052?style=for-the-badge&logo=safari&logoColor=white" height="22" alt="Website"/></a>
  <a href="https://app.neverland.money"><img src="https://img.shields.io/badge/App-app.neverland.money-192170?style=for-the-badge&logo=ethereum&logoColor=white" height="22" alt="App"/></a>
  <a href="https://x.com/Neverland_Money"><img src="https://img.shields.io/badge/%F0%9D%95%8F-%40Neverland__Money-1DA1F2?style=for-the-badge" height="22" alt="X"/></a>
  <a href="https://discord.com/invite/neverland"><img src="https://img.shields.io/badge/Discord-Join%20Server-5865F2?style=for-the-badge&logo=discord&logoColor=white" height="22" alt="Discord"/></a>
</p>
