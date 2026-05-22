# Neverland Contracts Architecture

This public mirror gives auditors, integrators, and reviewers the architecture context needed to understand the contracts without exposing private deployment automation.

## Protocol layers

### Token and veNFT layer

- `Dust` is the protocol ERC20 token.
- `DustLock` escrows DUST and mints ERC721 veDUST positions.
- Locks support standard time decay, permanent locks, early exit paths, split/merge flows, transfer hooks, and historical voting-power checkpoints.

### Revenue reward layer

- `RevenueReward` distributes ERC20 rewards to veDUST holders across epoch windows.
- `DustLock` notifies `RevenueReward` on mint, burn, transfer, split, and merge so reward accounting follows NFT ownership and lock state.
- Rewards may be claimed directly or routed into self-repaying vault flows.

### Emissions layer

- `DustRewardsController` adapts Aave-style reward accrual for DUST emissions.
- `DustLockTransferStrategy` delivers claimed DUST either by locking it into veDUST or paying it out liquid with protocol-defined penalty semantics.

### Self-repaying loan layer

- `UserVaultFactory` creates one beacon-proxy `UserVault` per user.
- `UserVaultRegistry` stores executor, aggregator allowlist, and slippage policy.
- `UserVault` instances can claim redirected rewards, swap through allowed aggregators, and repay or supply into the external lending market.

### Oracle, UI, and leaderboard layer

- `RatioOracleAggregator` and `YieldBearingOracleAdapter` are Chainlink-compatible oracle adapter surfaces.
- `NeverlandDustHelper` and `NeverlandUiProvider` are read-only helper surfaces for UI, analytics, and visibility.
- `EpochManager`, `LeaderboardConfig`, `NFTPartnershipRegistry`, `VotingPowerMultiplier`, and `LeaderboardKeeper` provide the leaderboard and partner multiplier system.

## External integration boundary

Aave V3 lending contracts are external dependencies. This repository contains Neverland wrappers, tokenomics, helper contracts, oracle adapters, and tests for those integration boundaries; it does not contain the full Aave market deployment stack.

## Upgrade and trust boundaries

Several contracts are written for proxy or beacon deployment and retain storage gaps or initializer patterns. Public reviewers should treat privileged owner, timelock, proxy-admin, beacon-owner, keeper, executor, treasury, and reward-distributor paths as intentional protocol governance surfaces, then verify whether a finding is about an accidental bug or an intended trust boundary.

Operational calldata generation, rehearsal, deployment, upgrade execution, audit triage, and hotfix workflow artifacts are intentionally private and are not part of this mirror.

## Public reviewer notes

- Reward epoch settlement must preserve conservation across lock, unlock, transfer, burn, split, merge, direct NFT transfer, and self-repay routing.
- Oracle adapters should be reviewed against their intended production integration mode and network assumptions.
- Self-repaying vaults rely on executor gating, registry allowlists, oracle-bounded slippage checks, and Aave integration behavior.
- UI/helper contracts should not be modeled as collateral or liquidation oracles unless the consuming integration explicitly does so.
