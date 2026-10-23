# Neverland Tokenomics

<p>
  <a href="./README.md"><img src="https://img.shields.io/badge/Neverland%20Tokenomics-v1.2.0%20%C2%B7%20Monad%20mainnet%20%28143%29%20%C2%B7%20Public%20mirror%20%C2%B7%20BUSL--1.1-192170?style=for-the-badge" alt="Neverland Tokenomics v1.2.0 - Monad mainnet (143) - Public mirror - BUSL-1.1"/></a>
</p>

Public source and package repository for Neverland tokenomics.

This repository contains the first-party Solidity contracts, interfaces, public tests, architecture context, and public address book needed to review the Neverland tokenomics, vote-escrow, revenue, oracle, leaderboard, and self-repaying vault surfaces. Operational deployment scripts, Hardhat deployment tasks, Ignition modules, generated Safe payloads, Tenderly runbooks, private audit workpapers, and hotfix workflow artifacts are intentionally outside this repository.

## Package

`@neverland-money/tokenomics-core` provides contract ABIs, ethers v6 types and factories, Solidity sources, compiled artifacts, and the recorded Monad mainnet address book.

```bash
npm install @neverland-money/tokenomics-core
```

```typescript
import { addresses, dustAbi } from "@neverland-money/tokenomics-core";
import { Dust__factory, type Dust } from "@neverland-money/tokenomics-core/types";
```

The root exports ABI constants and the complete address book as `addresses`. The ethers runtime dependency installs automatically with the package. The `/types` entry exports ethers v6 contract types and factories. `/artifacts/*` exposes the first-party Hardhat artifacts, and `/src/*` exposes the original Solidity files.

Load a compiled artifact from CommonJS:

```javascript
const dustArtifact = require("@neverland-money/tokenomics-core/artifacts/src/tokens/Dust.sol/Dust.json");
```

TypeScript projects importing raw JSON artifacts can enable `resolveJsonModule`; the root ABI, address, and factory imports work without it.

The npm runtime supports Node `22` and newer and uses ethers v6. CommonJS, ESM, type declarations, factory bytecode, and library linking are checked against a production-only package installation.

Solidity imports retain their development paths. The package includes the exact dependency sources they need under `vendor/`, with upstream license notices. For a Foundry project using an npm installation, add the package mapping and its dependency mappings:

```bash
printf '@neverland-money/tokenomics-core/=node_modules/@neverland-money/tokenomics-core/\n' >> remappings.txt
awk -F= '{print $1 "=node_modules/@neverland-money/tokenomics-core/" $2}' \
  node_modules/@neverland-money/tokenomics-core/remappings.package.txt >> remappings.txt
```

```solidity
import {IDustLock} from "@neverland-money/tokenomics-core/src/interfaces/IDustLock.sol";
```

Source compilation uses Solidity `0.8.30` and the bundled remappings. Other build systems, including Hardhat source projects, need a resolver for those import aliases; the prebuilt artifacts and ethers bindings work directly from the npm installation.

`package.json` records the development sync base commit and current Solidity source hash in `neverland`. The commit identifies the synchronization baseline; the hash identifies the exact packaged source content.

## Address book

[ADDRESS_BOOK.md](./ADDRESS_BOOK.md) records the Monad mainnet contracts, implementations, linked libraries, and governance addresses for chain ID `143`. It distinguishes current and historical oracle and market entries.

The Markdown tables are the maintained address source. The build generates the machine-readable address book for npm; `addresses.addresses.Dust` accesses the DUST address, and `@neverland-money/tokenomics-core/addresses` exposes the complete JSON document. Recorded addresses do not establish current on-chain configuration or source/bytecode equivalence.

## Build from source

To build the package from a source checkout, use Node `24.22.1` (pinned in `.nvmrc`), Yarn `4.18.1`, and Foundry `1.5.1`. Install [Foundry's `foundryup`](https://getfoundry.sh/introduction/installation/) first and make sure it is on your `PATH`. The contracts compile with Solidity `0.8.30`; the compiler and dependency versions are pinned for reproducibility.

```bash
foundryup --install v1.5.1
git submodule update --init --recursive
corepack enable
yarn install --immutable
yarn build
```

The build produces the contract artifacts, ABI exports, ethers v6 bindings, typed addresses, and bundled Solidity dependencies described above.

## Deployment Shape

This public mirror exposes the canonical Monad mainnet address book and the contract/test surface needed for review. Production deployment, upgrade execution, governance payload generation, Safe batch export, Tenderly simulation, and hotfix workflows are maintained outside this repository.

The repository should be read as a public architecture and validation package:

1. `src/`: first-party contract implementations and interfaces.
2. `test/`: local contract regressions, integration tests, and installed-package checks.
3. `ADDRESS_BOOK.md`: recorded mainnet address context and the source for generated npm addresses.
4. `ARCHITECTURE.md` and `CONTEXT.md`: reviewer notes for topology, trust boundaries, and production assumptions.

## Layout

- `src/`: Neverland Solidity contracts and interfaces, including `src/leaderboard/SpecialEditionRegistry.sol`, `src/oracles/HardcodedPriceOracle.sol`, `src/oracles/PendlePtDiscountOracleAdapter.sol`, `src/utils/NeverlandProfileItemsSeller.sol`, and `src/utils/libraries/NeverlandUiEmissionLibrary.sol`.
- `test/`: local Foundry unit, regression, and integration tests, plus `test/package/` consumer checks.
- `config/`: public read-only TypeScript configuration helpers.
- `ADDRESS_BOOK.md`: canonical recorded Monad mainnet address book.
- `.github/workflows/`: public contract/package CI and automated versioned releases.
- `tools/package.cjs`: package dependency preparation and release validation.
- `tools/release.cjs`: version gating, verified-archive publication, and GitHub release creation.
- `generated/`, `dist/`, and `vendor/`: ignored build outputs for bindings, package exports, and pinned dependency sources.
- `lib/`: Git submodules for Foundry, OpenZeppelin, Aave, Chainlink, PRB Math, and Uniswap dependencies.
- `ARCHITECTURE.md`: protocol topology and integration-boundary overview.
- `CONTEXT.md`: durable context for humans, reviewers, and scanners.

Private deployment, upgrade, Safe, Tenderly, audit-workpaper, and hotfix operations remain outside this repository.

## License And Notices

See [LICENSE](./LICENSE). SPDX identifiers in individual files are authoritative.

Neverland-authored code is generally licensed under Business Source License 1.1 and changes to MIT on `2028-07-20`. Aave-derived reward surfaces, Uniswap-dependent helper/oracle surfaces, interfaces, tests, and upstream submodules retain their respective SPDX and upstream licenses.

Security researchers should responsibly disclose vulnerabilities to `security@neverland.money`.

<p>
  <a href="https://neverland.money"><img src="https://img.shields.io/badge/Website-neverland.money-480052?style=for-the-badge&logo=safari&logoColor=white" height="22" alt="Website"/></a>
  <a href="https://app.neverland.money"><img src="https://img.shields.io/badge/App-app.neverland.money-192170?style=for-the-badge&logo=ethereum&logoColor=white" height="22" alt="App"/></a>
  <a href="https://x.com/Neverland_Money"><img src="https://img.shields.io/badge/%F0%9D%95%8F-%40Neverland__Money-1DA1F2?style=for-the-badge" height="22" alt="X"/></a>
  <a href="https://discord.com/invite/neverland"><img src="https://img.shields.io/badge/Discord-Join%20Server-5865F2?style=for-the-badge&logo=discord&logoColor=white" height="22" alt="Discord"/></a>
</p>
