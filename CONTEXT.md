# Neverland Contracts Public Context

This file is durable repository context for humans, auditors, security scanners, and code reviewers. It describes the public mirror and the contract model without exposing private deployment automation.

## What this repository is

This repository contains Neverland-authored Solidity contracts for:

- the DUST token
- the veDUST vote-escrow NFT system
- revenue sharing
- emissions and transfer strategies
- self-repaying loan helper contracts
- oracle adapters and UI helpers
- governance/timelock contract surfaces
- leaderboard and partner multiplier contracts

The primary contract source tree is `src/`. Public tests live under `test/`.

## What this repository is not

This repository is not the private development, audit, deployment, or hotfix operations repository. It intentionally excludes:

- deployment scripts and Hardhat deployment tasks
- Ignition modules and generated deployment journals
- Tenderly/Gnosis/Safe operation builders and generated payloads
- private audit notes and workpapers
- generated rehearsal workspaces and operational logs
- private agent memory or internal triage state

This repository also does not contain Neverland's full Aave V3 core lending deployment stack. Aave Pool, Configurator, reserve logic, liquidation math, and aToken logic are external dependencies or live in separate operational repositories.

## Network assumptions

The canonical production network is Monad Mainnet, chain id `143`. Public tests may use local mocks, local forks, or the public address book in `deployments/mainnet/addresses.json`.

If these contracts are ported to a different network, especially an L2 rollup, oracle and uptime assumptions must be re-evaluated.

## Contract surfaces

### Token and vote escrow

- `src/tokens/Dust.sol`
- `src/tokens/DustLock.sol`
- `src/tokens/DustLockLegendaryLedger.sol`

`DustLock` tokenizes lock positions as ERC721s, records voting-power history, and reports lock lifecycle events into reward accounting.

### Revenue and emissions

- `src/rewards/RevenueReward.sol`
- `src/emissions/DustRewardsController.sol`
- `src/emissions/DustTransferStrategyBase.sol`
- `src/emissions/DustLockTransferStrategy.sol`

These contracts adapt reward distribution and DUST delivery semantics around veDUST ownership and lock state.

### Self-repaying loans

- `src/self-repaying-loans/UserVault.sol`
- `src/self-repaying-loans/UserVaultFactory.sol`
- `src/self-repaying-loans/UserVaultRegistry.sol`

The vault system routes eligible rewards through owner-specific vaults, bounded executor policy, aggregator allowlists, and slippage validation.

### Oracles, UI, and leaderboard

- `src/oracles/*`
- `src/utils/*`
- `src/leaderboard/*`

Oracle adapters are security-sensitive integration surfaces. UI helpers are read-only surfaces and should not be treated as liquidation or collateral sources unless a consuming system explicitly uses them that way.

## Reviewer guidance

- Distinguish first-party Neverland logic from Aave, OpenZeppelin, Chainlink, Uniswap, and PRB Math dependencies.
- Respect SPDX headers; licensing is mixed by file.
- Treat upgrade/admin powers as real privileged surfaces, but separate intended governance power from accidental access-control bugs.
- Revenue epoch boundaries are high-value review points. Check exact-boundary behavior for lock mutation, NFT transfer, split, merge, burn, reward injection, claim, and self-repay routing.
- Fork tests and public address-book tests are context checks, not deployment instructions.
