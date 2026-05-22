export const HOUR = 60 * 60;
export const DAY = 24 * HOUR;

export type NetworkName = "mainnet" | "fork";

export type NetworkAlias = NetworkName | "hardhat";

export interface ExplorerConfig {
  monadscan: string;
  monadvision: string;
}

export interface CommonNetworkConfig {
  chainId: number;
  displayName: string;
  defaultConfirmations: number;
  explorers: ExplorerConfig;
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
  },
  fork: {
    chainId: 143,
    displayName: "Monad Mainnet Fork",
    defaultConfirmations: 1,
    explorers: {
      monadscan: "https://monadscan.com",
      monadvision: "https://monadvision.com",
    },
  },
};

const NETWORK_ALIASES: Record<NetworkAlias, NetworkName> = {
  mainnet: "mainnet",
  fork: "fork",
  hardhat: "fork",
};

export const resolveNetwork = (networkName: string): NetworkName => {
  return NETWORK_ALIASES[networkName as NetworkAlias] ?? "mainnet";
};
