export const HOUR = 60 * 60;
export const DAY = 24 * HOUR;

export type NetworkName = "mainnet" | "fork";

export type NetworkAlias = NetworkName | "hardhat" | "localhost" | "tenderly";

export interface ExplorerConfig {
  /// Primary explorer. Named for Monad's; on another chain it carries that chain's primary.
  monadscan: string;
  /// Secondary explorer, or the primary again on a chain that publishes only one.
  monadvision: string;
}

/**
 * The verification backends hardhat-verify can drive. This is the mechanism, not the brand:
 * MonadVision (BlockVision) is reached over `sourcify`, and MonadScan is reached over
 * `etherscan`. The brand is in `label`.
 */
export type VerifierKind = "etherscan" | "sourcify" | "blockscout";

export interface VerifierConfig {
  kind: VerifierKind;
  /// Explorer brand, for logs and for the links a deploy prints.
  label: string;
  /// Endpoint hardhat-verify posts to.
  apiUrl: string;
  /// Human-facing explorer root.
  browserUrl: string;
  /// Env var carrying this backend's API key, when it needs one. The key itself never lives here.
  apiKeyEnv?: string;
  /// Tools that can submit to this endpoint today. The two disagree: hardhat-verify 2.1.1 calls
  /// Sourcify's v1 API and hardcodes the Blockscout key, while forge speaks Sourcify v2 and takes
  /// a Blockscout key. A chain declares every explorer it is published on either way; this only
  /// decides which tool is pointed at it.
  drivers: VerifierDriver[];
  /// Why a tool is absent from `drivers`.
  driverNote?: string;
}

export type VerifierDriver = "hardhat" | "forge";

const MONADSCAN: VerifierConfig = {
  kind: "etherscan",
  label: "MonadScan",
  // The chain id is appended by hardhat-verify for a V2 chain, so it is not spelled out here.
  apiUrl: "https://api.etherscan.io/v2/api",
  browserUrl: "https://monadscan.com",
  apiKeyEnv: "ETHERSCAN_KEY",
  drivers: ["hardhat", "forge"],
};

const MONADVISION: VerifierConfig = {
  kind: "sourcify",
  label: "MonadVision",
  apiUrl: "https://sourcify-api-monad.blockvision.org",
  browserUrl: "https://monadvision.com",
  drivers: ["hardhat"],
  driverNote:
    "BlockVision's instance still serves the v1 API hardhat-verify calls; forge speaks Sourcify v2",
};

export interface CommonNetworkConfig {
  chainId: number;
  displayName: string;
  defaultConfirmations: number;
  explorers: ExplorerConfig;
  /// Every explorer that publishes this chain. A chain carried by several verifiers lists them
  /// all, and a verifier carrying several chains appears under each.
  verifiers: VerifierConfig[];
}

export const NETWORK_COMMON_CONFIG: Record<NetworkName, CommonNetworkConfig> = {
  mainnet: {
    chainId: 143,
    displayName: "Monad Mainnet",
    defaultConfirmations: 5,
    explorers: {
      monadscan: "https://monadscan.com",
      monadvision: "https://monadvision.com",
    },
    verifiers: [MONADSCAN, MONADVISION],
  },
  fork: {
    chainId: 143,
    displayName: "Monad Mainnet Fork",
    defaultConfirmations: 1,
    explorers: {
      monadscan: "https://monadscan.com",
      monadvision: "https://monadvision.com",
    },
    verifiers: [MONADSCAN, MONADVISION],
  },
};

// Every rehearsal alias must map to "fork"; inheriting mainnet's 5-confirmation wait on a
// mine-on-demand network blocks forever, and confirmed-block reads resolve before the deployment.
const NETWORK_ALIASES: Record<NetworkAlias, NetworkName> = {
  mainnet: "mainnet",
  fork: "fork",
  hardhat: "fork",
  localhost: "fork",
  tenderly: "fork",
};

// The chain a fork network rehearses, so a fork inherits its own chain's deployments and never
// another chain's. Live networks map to themselves.
const NETWORK_BASE: Record<NetworkName, NetworkName> = {
  mainnet: "mainnet",
  fork: "mainnet",
};

export const resolveNetworkBase = (networkName: string): NetworkName =>
  NETWORK_BASE[resolveNetwork(networkName)];

export const isKnownNetwork = (
  networkName: string
): networkName is NetworkAlias =>
  Object.prototype.hasOwnProperty.call(NETWORK_ALIASES, networkName);

export const resolveNetwork = (networkName: string): NetworkName => {
  if (!isKnownNetwork(networkName)) {
    throw new Error(
      `Unknown network "${networkName}". Add it to NETWORK_ALIASES in config/common.ts.`
    );
  }
  return NETWORK_ALIASES[networkName];
};

/// Backends the given tool can submit to for this chain.
export const getDrivableVerifiers = (
  networkName: string,
  driver: VerifierDriver
): VerifierConfig[] =>
  getNetworkVerifiers(networkName).filter((verifier) =>
    verifier.drivers.includes(driver)
  );

/// Every explorer that publishes the chain behind `networkName`.
export const getNetworkVerifiers = (networkName: string): VerifierConfig[] =>
  NETWORK_COMMON_CONFIG[resolveNetwork(networkName)].verifiers;

/// The chain's entry for one verification backend, or undefined when that backend does not
/// carry it. Reachability is not consulted: a declared-but-unreachable endpoint still returns.
export const getNetworkVerifier = (
  networkName: string,
  kind: VerifierKind
): VerifierConfig | undefined =>
  getNetworkVerifiers(networkName).find((verifier) => verifier.kind === kind);

/// Every chain this repo knows that one verification backend carries, as hardhat-verify's
/// customChains shape. Driven by the per-chain lists, so adding a chain needs no change here.
export const getVerifierChains = (
  kind: VerifierKind
): {
  network: NetworkName;
  chainId: number;
  urls: { apiURL: string; browserURL: string };
}[] =>
  (Object.keys(NETWORK_COMMON_CONFIG) as NetworkName[]).flatMap((network) => {
    const verifier = NETWORK_COMMON_CONFIG[network].verifiers.find(
      (candidate) => candidate.kind === kind
    );

    return verifier
      ? [
          {
            network,
            chainId: NETWORK_COMMON_CONFIG[network].chainId,
            urls: { apiURL: verifier.apiUrl, browserURL: verifier.browserUrl },
          },
        ]
      : [];
  });
