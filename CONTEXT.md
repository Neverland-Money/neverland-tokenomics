# Neverland Tokenomics Public Context

This file describes the public release repository, contract behavior, and trust boundaries for humans, auditors, security scanners, and code reviewers. [ARCHITECTURE.md](./ARCHITECTURE.md) maps the components and their connections.

[threat-model.yaml](./threat-model.yaml) records known limitations and security assumptions. Apply a known-issue exclusion only when its mechanism, preconditions, and impact match the finding; current source remains authoritative.

## Repository and package scope

This repository contains Neverland-authored Solidity contracts and interfaces under [src/](./src/), a focused public test suite under [test/](./test/), and the recorded Monad mainnet address book. It prepares the first `@neverland-money/tokenomics-core` package release as version `1.2.0`.

[package.json](./package.json) records development sync base commit `71c2d0658d6e12e61018156808f1bd6e9a24675c` and the current Solidity source hash in `neverland.developmentCommit` and `neverland.sourceHash`. The commit identifies the synchronization baseline; the hash identifies the exact packaged source content. These fields do not identify deployed bytecode or establish publication status.

The package exposes:

- Root: ABI constants and the complete address-book document as `addresses`, including its nested deployment, implementation, library, and governance records.
- `/types` and `/types/*`: ethers v6 contract types and factories.
- `/artifacts/*` and `/src/*`: first-party compiled artifacts and original Solidity sources.
- `/vendor/*` and `/remappings`: the exact production Solidity import closure, upstream license notices, and package-relative dependency mappings.
- `/addresses`: the address-book JSON directly.

[tools/package.cjs](./tools/package.cjs) prepares the dependency bundle and verifies source identity, artifacts, exports, and dependency pins. Individual SPDX headers and upstream notices remain authoritative; licensing is mixed by file.

Deployment scripts, Hardhat deployment tasks, Ignition modules, generated Safe payloads, Tenderly runbooks, private audit workpapers, operational logs, and hotfix workflows are maintained outside this public repository. The production lending deployment stack is also separate: dependencies bundled for compilation and local integration tests are not a deployment package for Neverland's full Aave-derived lending system.

## Network and address evidence

[ADDRESS_BOOK.md](./ADDRESS_BOOK.md) records `monadMainnet`, chain ID `143`. Its Markdown tables are the maintained address source; the package build generates the machine-readable JSON export from them. It includes core proxies and implementations, vault beacon infrastructure, helpers, oracle instances, gateways, linked libraries, and governance/admin addresses.

The address book is recorded repository context. Its entries do not establish current ownership, proxy implementation, configuration, contract code, or deployment/source equivalence. The market-hours contracts have source and local tests but no deployment entries in this address book. Network ports require a fresh review of oracle, uptime, and dependency assumptions.

## Contract behavior

### DUST, vote escrow, revenue, and emissions

- [Dust](./src/tokens/Dust.sol) is the protocol ERC20. [DustLock](./src/tokens/DustLock.sol) represents timed and permanent DUST locks as transferable ERC721 veNFTs, records voting-power history, and notifies reward accounting about lifecycle changes. `balanceOf(owner)` counts NFTs; `balanceOfNFT(tokenId)` and `balanceOfNFTAt(tokenId, timestamp)` report voting power.
- [RevenueReward](./src/rewards/RevenueReward.sol) distributes supported reward tokens using seven-day epochs and historical veNFT voting power. Mint, transfer, burn, merge, and split hooks affect reward ownership and settlement. Owners can route eligible rewards to their canonical self-repay vault.
- [DustRewardsController](./src/emissions/DustRewardsController.sol), [DustTransferStrategyBase](./src/emissions/DustTransferStrategyBase.sol), and [DustLockTransferStrategy](./src/emissions/DustLockTransferStrategy.sol) implement emissions and DUST claim delivery, including lock-based delivery and claim penalties.
- [DustLockLegendaryLedger](./src/tokens/DustLockLegendaryLedger.sol) creates user-owned locks and records legendary-attempt flags. Legendary outcomes are cosmetic off-chain metadata and do not change voting power, rewards, or custody. [NeverlandProfileItemsSeller](./src/utils/NeverlandProfileItemsSeller.sol) sells configured profile items for DUST.

### Self-repaying vaults

[UserVaultFactory](./src/self-repaying-loans/UserVaultFactory.sol) creates owner-specific beacon-proxy [UserVault](./src/self-repaying-loans/UserVault.sol) instances. [UserVaultRegistry](./src/self-repaying-loans/UserVaultRegistry.sol) controls the executor, supported swap aggregators, and maximum swap slippage. Vaults collect eligible rewards, swap through approved aggregators, and repay variable-rate lending debt or deposit collateral. Reward routing, executor permissions, registry policy, provider validation, and beacon upgrades are separate trust boundaries.

### Lending and Pendle gateways

- [NeverlandNativeGateway](./src/utils/NeverlandNativeGateway.sol) wraps and unwraps the native asset for supply, withdrawal, borrowing, and repayment in one fixed lending pool. Its owner can recover native assets and ERC20s.
- [NeverlandAssetRedemption](./src/utils/NeverlandAssetRedemption.sol) exchanges one bearer token for a fixed destination token using an owner-managed rate and available payout liquidity. Payouts round down. Rate changes require a pause; source-token recovery requires zero destination liquidity. Both tokens must have exact-transfer, non-rebasing behavior.
- [NeverlandPendleLeverager](./src/utils/NeverlandPendleLeverager.sol) creates and adjusts caller-owned positions in one fixed Pendle PT market. Position-pool mode-2 flash loans open variable debt; decreases use external fee-free flash liquidity. Dependencies are fixed, and the owner has recovery authority.
- [NeverlandPendleMaturityGateway](./src/utils/NeverlandPendleMaturityGateway.sol) closes matured PT positions or migrates them into owner-enabled target markets using bounded flash-loan rounds. It requires compatible par-redemption assets and a PT reserve normalized-income index of `RAY`. The owner manages migration targets and token recovery.

Both Pendle helpers are non-upgradeable and keep no persistent user-position ledger. Their behavior depends on lending reserve configuration, flash capacity and permissions, Pendle redemption/swap behavior, user allowances or delegation, and output and health-factor limits.

### Oracles and market hours

[RatioOracleAggregator](./src/oracles/RatioOracleAggregator.sol), [YieldBearingOracleAdapter](./src/oracles/YieldBearingOracleAdapter.sol), and [PendlePtDiscountOracleAdapter](./src/oracles/PendlePtDiscountOracleAdapter.sol) compose upstream feeds, token ratios, or PT discount inputs. [HardcodedPriceOracle](./src/oracles/HardcodedPriceOracle.sol) reports a fixed price. [GovernedPriceOracle](./src/oracles/GovernedPriceOracle.sol) reports the owner's latest positive eight-decimal USD price; it has no automatic staleness gate and stores only the latest round. Posted-price freshness is a governance and monitoring duty.

The stock-market-hours surfaces implement a separate model:

- [SessionCalendar](./src/oracles/SessionCalendar.sol) stores owner-managed, ordered UTC trading windows. The owner can append windows, remove future windows, and shorten the current window.
- [MarketHoursPriceAdapter](./src/oracles/MarketHoursPriceAdapter.sol) reads a fixed feed and calendar. It applies separate session and closure age limits, allowing a valid last print to price through a closure and reopening until a new print arrives. A print already stale at the close remains invalid; unusable answers return zero.
- [MarketHoursSentinel](./src/risk/MarketHoursSentinel.sol) always permits borrowing and holds liquidation only during a configurable grace after a session opens, bounded by the session end. Risk or pool admins set the grace. In the integrated lending core, the sentinel check applies to the `[0.95, 1)` health-factor band; deeper insolvency bypasses it. A market closure alone does not impose a liquidation hold.

These contracts trust their configured feeds, calendar maintenance, and consuming lending-core behavior. Source comments describing intended production roles or launch parameters are not deployment evidence.

### UI data and leaderboard

[NeverlandUiProvider](./src/utils/NeverlandUiProvider.sol) is ownerless, read-only aggregation over immutable dependencies, with linked helpers under [src/utils/libraries/](./src/utils/libraries/). [NeverlandDustHelper](./src/utils/NeverlandDustHelper.sol) is a stateful, owner-configured pricing and supply helper: the owner selects sources, updates the cache, sets manual pricing and bounds, and manages team-address exclusions. Its spot-price and cache model is intended for UI information and provides no TWAP or general freshness guarantee; it is unsuitable for collateral valuation or liquidation logic.

[EpochManager](./src/leaderboard/EpochManager.sol), [LeaderboardConfig](./src/leaderboard/LeaderboardConfig.sol), [NFTPartnershipRegistry](./src/leaderboard/NFTPartnershipRegistry.sol), and [SpecialEditionRegistry](./src/leaderboard/SpecialEditionRegistry.sol) define leaderboard epochs, scoring configuration, and multiplier inputs. [VotingPowerMultiplier](./src/leaderboard/VotingPowerMultiplier.sol) selects a tier from the highest voting power of an individual NFT owned by a user; it does not sum the user's NFTs.

[LeaderboardKeeper](./src/leaderboard/LeaderboardKeeper.sol) publishes keeper/owner-supplied voting power, NFT balances, and LP positions as events after structural batch checks. It does not independently verify those supplied values on-chain. Settlement and self-sync calls publish signals for downstream consumers; consumers must preserve the keeper trust assumption.

### Governance and upgrades

[NeverlandTimelockController](./src/governance/NeverlandTimelockController.sol) extends OpenZeppelin's timelock with an immutable minimum-delay floor. Proxy-admin, beacon, owner, reward-distributor, emission-manager, keeper, and lending ACL roles remain distinct authorities. A recorded governance timelock does not imply that every runtime admin action is delayed; the address book explicitly records immediate runtime surfaces separately from upgrade lanes.

## Public validation and review boundaries

The retained Foundry suite covers local unit behavior, regressions, integrations with mocks and local lending contracts, and bounded fuzz properties. Areas include lock/revenue epoch transitions, claim and exit pricing, vault policy, gateway accounting, oracle/calendar behavior, leaderboard configuration, and governance. Files named as economic invariants contain bounded fuzz properties; stateful invariant campaigns are maintained in the development repository.

[test/package/](./test/package/) exercises an installed tarball through CommonJS, ESM, TypeScript, and Solidity imports. The package-consumer test compiles every published first-party Solidity source using the installed dependency bundle. [package.json](./package.json) defines `yarn check` for formatting, lint, builds, type checks, size checks, local Foundry tests, package verification, consumer tests, and release-control tests under [test/release/](./test/release/).

[CI](./.github/workflows/test.yml) checks the package archive and production consumer installation. Validation jobs have read-only repository permissions; the gated publishing job has separate write and OIDC permissions. The validation environment uses Node `24.22.1`, npm `12.2.1`, Yarn `4.18.1`, Foundry `1.5.1`, Solidity `0.8.30`, and Ubuntu `26.04`. GitHub Actions are pinned to release commit SHAs. Foundry, compiler, and locked dependency versions are retained for reproducibility.

Fork suites, historical upgrade replays, rehearsals, exhaustive workbooks, and extended security/coverage campaigns are outside this public release suite. A passing public gate establishes local behavior and package integrity within its tested scope. Live deployment checks, operational rehearsal, audit conclusions, and release execution require their own evidence.

Review lock mutations, transfers, merges, splits, burns, reward notification, claims, and self-repay routing together at exact epoch boundaries. Trace external token semantics, oracle validity, reserve configuration, flash permissions, and upgrade authority through the actual consumer before drawing a security conclusion.
