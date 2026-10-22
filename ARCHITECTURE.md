# Neverland Tokenomics Architecture

This repository is the public source and package mirror for Neverland tokenomics and lending integrations. The first `@neverland-money/tokenomics-core` package release is `1.2.0`, prepared against development sync base commit `71c2d0658d6e12e61018156808f1bd6e9a24675c`. The source hash in [package.json](package.json) identifies the exact packaged Solidity content. [CONTEXT.md](CONTEXT.md) describes behavior and integration assumptions; this page maps components, asset flows, and authority boundaries.

## Protocol layers

### Token and veNFT layer

- `Dust` is the protocol ERC20 token.
- `DustLock` escrows DUST and mints ERC721 veDUST positions.
- Locks support standard time decay, permanent locks, early exit paths, split/merge flows, transfer hooks, and historical voting-power checkpoints.
- `DustLockLegendaryLedger` routes DUST into canonical locks and records legendary-attempt metadata. Outcomes are resolved off chain and do not change voting power, rewards, or lock accounting.

### Revenue reward layer

- `RevenueReward` distributes ERC20 rewards to veDUST holders across epoch windows.
- `DustLock` notifies `RevenueReward` on mint, burn, transfer, split, and merge so reward accounting follows NFT ownership and lock state.
- Rewards may be claimed directly or routed into self-repaying vault flows.

### Emissions layer

- `DustRewardsController` adapts Aave-style reward accrual for DUST emissions.
- `DustLockTransferStrategy` delivers claimed DUST to a wallet or veDUST lock. Gross accrual is preserved; the realized commitment determines the release penalty, which is sent to the configured early-exit burn wallet.

### Self-repaying loan layer

- `UserVaultFactory` creates one beacon-proxy `UserVault` per user.
- `UserVaultRegistry` stores executor, aggregator allowlist, and slippage policy.
- Executor-gated `UserVault` actions claim redirected rewards, swap through allowed aggregators with lending-oracle slippage checks, and repay variable-rate debt or supply collateral for the user. The user and executor can recover assets to the user.

### Lending gateways and redemption

- `NeverlandNativeGateway` binds one wrapped native token and one lending pool at construction. It wraps native currency for supply and repayment, and unwraps it for borrowing and withdrawal. Its owner has emergency asset-recovery authority.
- `NeverlandPendleLeverager` creates, increases, or decreases the caller's position in one immutable Pendle PT market. Creates and increases use position-pool flash loans that open variable-rate debt after PT supply; decreases use fee-free Morpho or a distinct external pool to repay before withdrawing collateral. Positions remain in the lending pool; the helper keeps no persistent user-position accounting. The owner controls asset recovery, while the market, pools, router, debt asset, and lenders are fixed.
- `NeverlandPendleMaturityGateway` closes matured PT positions or migrates them into owner-enabled, unexpired Pendle markets. Flash liquidity funds repayment before matured PT is withdrawn and redeemed. Settlement requires equal token decimals, one-to-one SY/PY indices, redemption proceeds of at least par, and a PT reserve normalized-income index of `RAY`. Dependencies are immutable; migration targets and asset recovery are owner-controlled.
- `NeverlandAssetRedemption` exchanges a fixed bearer-token pair against funded destination-token liquidity. Holding the source token supplies entitlement; there is no claim list. Payouts round down at the owner-managed rate. The owner can pause, update the rate while paused, and withdraw assets; source-token recovery requires zero destination liquidity. Recovered source units remain redeemable if recirculated.

### Oracle and market-hours layer

- `RatioOracleAggregator` and `YieldBearingOracleAdapter` are Chainlink-compatible oracle adapter surfaces.
- `HardcodedPriceOracle` is a non-upgradeable, ungoverned fixed-price feed adapter.
- `PendlePtDiscountOracleAdapter` prices Pendle Principal Tokens used as money-market collateral.
- `GovernedPriceOracle` is a non-upgradeable feed whose owner posts a positive, eight-decimal USD price. Reads return the last posted price without an automatic staleness rejection; price maintenance is a governance responsibility.
- `SessionCalendar` stores owner-managed UTC trading windows. `MarketHoursPriceAdapter` is ownerless and applies session/closure age limits to an immutable feed and calendar. `MarketHoursSentinel` reads that calendar to gate liquidation during a configurable post-open grace period; borrowing remains allowed, and the lending core can bypass the sentinel below its severe-health threshold. Risk or pool admins can change the grace period. These three contracts have source and artifacts but no entries in the recorded mainnet address book.

### UI, profile, and leaderboard layer

- `NeverlandDustHelper` is a stateful informational helper. Its owner configures team-address accounting, price sources, manual price, limits, and cache updates. Spot-price reads and cached values serve UI displays and are unsuitable for collateral, liquidation, or other financial decisions.
- `NeverlandUiProvider` is an ownerless, read-only aggregator with immutable dependencies. It combines lock, revenue, emission, price, and registered-market data for UI queries.
- `NeverlandProfileItemsSeller` accepts DUST for configured profile items, with owner-managed item configuration, pause state, and funds recipient.
- `EpochManager`, `LeaderboardConfig`, `NFTPartnershipRegistry`, `VotingPowerMultiplier`, and `LeaderboardKeeper` provide the leaderboard and partner multiplier system.
- `SpecialEditionRegistry` is the token-bound special-edition multiplier registry alongside `NFTPartnershipRegistry`.
- Keeper/owner batch sync calls emit supplied voting-power, NFT-balance, and LP-position data after structural checks; they do not independently verify those values on chain. Consumers trust the authorized publisher. `syncMyState` only emits a cooldown-gated settlement event and updates the caller's settlement timestamp.

## Linked libraries

The generated compiler artifacts record these external links:

| Contract or library                | Linked libraries                                                                                                                   |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `DustLock`                         | `BalanceLogicLibrary`, `CreatorTokenLibrary`                                                                                       |
| `NeverlandUiProvider`              | `NeverlandUiEmissionLibrary`, `NeverlandUiEnumerationLibrary`, `NeverlandUiPriceMarketLibrary`, `NeverlandUiRewardsSummaryLibrary` |
| `NeverlandUiRewardsSummaryLibrary` | `NeverlandUiEmissionLibrary`                                                                                                       |

`NeverlandUiArrayLibrary` contains internal helpers and requires no separate deployment link. Library addresses are recorded under `libraries` in the [mainnet address book](ADDRESS_BOOK.md).

## External integration boundary

Lending pools, their risk configuration and price oracles, Pendle markets and routers, Morpho liquidity, and allowed swap aggregators are external integration dependencies. This repository contains the Neverland tokenomics and integration surfaces, rather than the full lending-market deployment stack. Bundled dependency sources support compilation; their presence does not establish a deployed dependency's identity or configuration.

## Upgrade and trust boundaries

The address book records Monad mainnet (`chainId: 143`) addresses, implementation entries, proxy administrators, the user-vault beacon, governance safes, and timelocks. It includes the native gateway, maturity gateway, per-market leveragers, bearer redemption, and governed-price feed. These are recorded deployment metadata, not a fresh live-state verification.

Upgrade authority and runtime authority are separate:

- Proxy administration controls implementation replacement for the recorded core and leaderboard proxy deployments. The user-vault beacon's upgrade authority controls the implementation shared by user vaults. These powers are distinct from each contract's runtime permissions.
- `Dust` has an owner; `DustLock` uses its team role; `RevenueReward` uses a reward distributor; emissions use an emission manager and transfer-strategy rewards admin. `UserVaultRegistry` has an owner, and its executor controls vault automation. The address book explicitly records immediate phase-one runtime authority for these core surfaces; a recorded timelock address does not make every call delayed.
- Leaderboard owners configure policy and authorized keepers. Direct utilities use their source-defined owner permissions, including redemption lifecycle controls, posted oracle prices, gateway recovery, and maturity migration targets. The UI provider has no owner or configuration setters.

`NeverlandTimelockController` supplies the governance timelock implementation. Deployment, upgrade execution, rehearsals, and operational automation remain in the development repository.

## Public reviewer notes

- Reward epoch settlement must preserve conservation across lock, unlock, transfer, burn, split, merge, direct NFT transfer, and self-repay routing.
- Oracle adapters should be reviewed against their intended production integration mode and network assumptions.
- Self-repaying vaults rely on executor gating, registry allowlists, oracle-bounded slippage checks, and Aave integration behavior.
- Keep informational UI prices separate from financial oracle integrations; `NeverlandDustHelper` spot/cache pricing does not provide financial-oracle safety guarantees.

## Public package boundary

The package exposes ABI constants and the full address book at its root, ethers v6 bindings under `/types`, first-party artifacts under `/artifacts/*`, and byte-identical mirrored Solidity under `/src/*`. `/addresses` exposes the generated JSON address book. The maintained source is [ADDRESS_BOOK.md](ADDRESS_BOOK.md); the build derives the JSON from its tables. The `vendor/` output contains the pinned transitive Solidity source closure and upstream license notices; `remappings.package.txt` resolves package-source imports into that closure.

The development commit and source hash in [package.json](package.json) identify the source snapshot. Package verification checks source identity, compiler artifacts, exports, and bundled dependency contents. Public CI is configured to run local contract regressions, formatting, lint, type checks, builds, size checks, source/artifact verification, installed-package consumer tests, and release-control tests. The publishing job has separate permissions from the read-only validation job and uses OIDC authentication. Fork suites and long-running invariant, coverage, security, and rehearsal campaigns remain in the development repository.
