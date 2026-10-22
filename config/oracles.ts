import { HOUR, DAY, NetworkName, resolveNetwork } from "./common";

export type OracleVerifyMode = "none" | "etherscan" | "sourcify" | "both";

const ORACLE_STALENESS_BUFFER = 12 * HOUR;
const ORACLE_MAX_DELAY = DAY + ORACLE_STALENESS_BUFFER;

export interface OracleNetworkDefaults {
  maxDelay: number;
  minimumSnapshotDelay: number;
  maximumSnapshotAge: number;
}

export const ORACLE_TARGET_DECIMALS = 8;

export const ORACLE_DEFAULTS_BY_NETWORK: Record<
  NetworkName,
  OracleNetworkDefaults
> = {
  mainnet: {
    maxDelay: ORACLE_MAX_DELAY,
    minimumSnapshotDelay: HOUR,
    maximumSnapshotAge: 30 * DAY,
  },
  fork: {
    maxDelay: ORACLE_MAX_DELAY,
    minimumSnapshotDelay: HOUR,
    maximumSnapshotAge: 30 * DAY,
  },
};

export const DEFAULT_VERIFY_MODE: OracleVerifyMode = "none";

export interface OracleFeedConfig {
  id: string;
  symbol: string;
  address: string;
  decimals: number;
  description: string;
}

export interface OracleReserveConfig {
  symbol: string;
  reserveAddress: string;
  reserveDecimals: number;
}

export interface RatioOraclePreset {
  id: string;
  label: string;
  reserveSymbol: string;
  ratioFeed: OracleFeedConfig;
  baseFeed: OracleFeedConfig;
  source: "aave-v3-neverland";
  maxDelay?: number;
}

export interface YieldOraclePreset {
  id: string;
  label: string;
  reserveSymbol: string;
  baseFeed: OracleFeedConfig;
  sharesContract: string;
  sharesDecimals: number;
  assetDecimals: number;
  source: "aave-v3-neverland";
  maxDelay?: number;
  minimumSnapshotDelay?: number;
  maximumSnapshotAge?: number;
  description: string;
  initialGrowthCapBps?: number;
  initialRejectionGraceBps?: number;
}

/** A recorded deployed governed source; its mutable price is read from the oracle. */
export interface GovernedOracleSource {
  id: string;
  label: string;
  reserveSymbol: string;
  feed: OracleFeedConfig;
  source: "aave-v3-neverland";
}

export interface OracleNetworkConfig {
  poolAddressesProvider: string;
  feeds: Record<string, OracleFeedConfig>;
  reserves: Record<string, OracleReserveConfig>;
  ratioPresets: RatioOraclePreset[];
  yieldPresets: YieldOraclePreset[];
  governedSources: GovernedOracleSource[];
}

const MAINNET_FEEDS: Record<string, OracleFeedConfig> = {
  MON_USD: {
    id: "MON_USD",
    symbol: "MON/USD",
    address: "0xBcD78f76005B7515837af6b50c7C52BCf73822fb",
    decimals: 8,
    description: "Chainlink MON / USD",
  },
  AUSD_USD: {
    id: "AUSD_USD",
    symbol: "AUSD/USD",
    address: "0xE20751C7B5867bCBef815ffc1b284c3f412a9e13",
    decimals: 8,
    description: "Chainlink AUSD / USD",
  },
  EARNAUSD_AUSD: {
    id: "EARNAUSD_AUSD",
    symbol: "earnAUSD/AUSD",
    address: "0x66608681545aaa50D9ebdBd9542fEeA4e49B85da",
    decimals: 18,
    description: "Chainlink earnAUSD / AUSD",
  },
  SMON_MON: {
    id: "SMON_MON",
    symbol: "sMON/MON",
    address: "0x056d0eF95A4e046D028b00E6eC00bB4A8b1eBb96",
    decimals: 18,
    description: "Chainlink sMON / MON",
  },
  SHMON_MON: {
    id: "SHMON_MON",
    symbol: "shMON/MON",
    address: "0x54a1020D118B9BeF3F3A4ec8E24AeEc9DFdBe4c3",
    decimals: 18,
    description: "Chainlink shMON / MON",
  },
  GMON_MON: {
    id: "GMON_MON",
    symbol: "gMON/MON",
    address: "0xf97dfEd6Aa4cc387aBC5d47F0062A91CB4E4A755",
    decimals: 18,
    description: "Chainlink gMON / MON",
  },
  LOAZND_USD: {
    id: "LOAZND_USD",
    symbol: "loAZND/USD",
    address: "0x9eF202F1A9962138a5918721Aa36b4665634975F",
    decimals: 8,
    description: "Governed loAZND / USD settlement price",
  },
  YZUSD_USD: {
    id: "YZUSD_USD",
    symbol: "yzUSD/USD",
    address: "0xA0E2bEC2B69dAf7e1037bb9999110CAfBd779Ab5",
    decimals: 18,
    description: "Chainlink yzUSD / USD",
  },
  SYZUSD_YZUSD: {
    id: "SYZUSD_YZUSD",
    symbol: "syzUSD/yzUSD",
    address: "0x1Bd7e3865Bba838524bCCAe84A7a0cA635D65071",
    decimals: 18,
    description: "Chainlink syzUSD / yzUSD",
  },
};

const MAINNET_RESERVES: Record<string, OracleReserveConfig> = {
  WMON: {
    symbol: "WMON",
    reserveAddress: "0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A",
    reserveDecimals: 18,
  },
  SMON: {
    symbol: "sMON",
    reserveAddress: "0xA3227C5969757783154C60bF0bC1944180ed81B9",
    reserveDecimals: 18,
  },
  SHMON: {
    symbol: "shMON",
    reserveAddress: "0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c",
    reserveDecimals: 18,
  },
  GMON: {
    symbol: "gMON",
    reserveAddress: "0x8498312A6B3CbD158bf0c93AbdCF29E6e4F55081",
    reserveDecimals: 18,
  },
  AUSD: {
    symbol: "AUSD",
    reserveAddress: "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a",
    reserveDecimals: 6,
  },
  SUSDE: {
    // Accounting asset of SY-sUSDE (0x06fC2568fa3C8A9862D8f35bc6758355b3A32F51): assetInfo()
    // reports USDe, not sUSDe, so PT-sUSDE prices off the USDe reserve. Consumed by the
    // Pendle PT deploy gate (resolvePendlePtExpectedAccountingAsset).
    symbol: "sUSDE",
    reserveAddress: "0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34",
    reserveDecimals: 18,
  },
  EARNAUSD: {
    symbol: "earnAUSD",
    reserveAddress: "0x103222f020e98Bba0AD9809A011FDF8e6F067496",
    reserveDecimals: 6,
  },
  SYZUSD: {
    symbol: "syzUSD",
    reserveAddress: "0x484be0540aD49f351eaa04eeB35dF0f937D4E73f",
    reserveDecimals: 18,
  },
  LOAZND: {
    symbol: "loAZND",
    reserveAddress: "0x9c82eB49B51F7Dc61e22Ff347931CA32aDc6cd90",
    reserveDecimals: 18,
  },
};

// Addresses are recorded configuration, not a live chain check. The governed loAZND
// source matches the deployment manifest and lending market configuration; no historical
// posted answer is copied because governance can update it without changing the address.
const MAINNET_ORACLE_CONFIG: OracleNetworkConfig = {
  poolAddressesProvider: "0x49D75170F55C964dfdd6726c74fdEDEe75553A0f",
  feeds: MAINNET_FEEDS,
  reserves: MAINNET_RESERVES,
  ratioPresets: [
    {
      id: "smon-usd",
      label: "SMON/USD via SMON/MON * MON/USD",
      reserveSymbol: "SMON",
      ratioFeed: MAINNET_FEEDS.SMON_MON,
      baseFeed: MAINNET_FEEDS.MON_USD,
      source: "aave-v3-neverland",
      maxDelay: ORACLE_MAX_DELAY,
    },
    {
      id: "shmon-usd",
      label: "SHMON/USD via SHMON/MON * MON/USD",
      reserveSymbol: "SHMON",
      ratioFeed: MAINNET_FEEDS.SHMON_MON,
      baseFeed: MAINNET_FEEDS.MON_USD,
      source: "aave-v3-neverland",
      maxDelay: ORACLE_MAX_DELAY,
    },
    {
      id: "gmon-usd",
      label: "GMON/USD via GMON/MON * MON/USD",
      reserveSymbol: "GMON",
      ratioFeed: MAINNET_FEEDS.GMON_MON,
      baseFeed: MAINNET_FEEDS.MON_USD,
      source: "aave-v3-neverland",
      maxDelay: ORACLE_MAX_DELAY,
    },
    {
      id: "earnausd-usd",
      label: "EARNAUSD/USD via EARNAUSD/AUSD * AUSD/USD",
      reserveSymbol: "EARNAUSD",
      ratioFeed: MAINNET_FEEDS.EARNAUSD_AUSD,
      baseFeed: MAINNET_FEEDS.AUSD_USD,
      source: "aave-v3-neverland",
      maxDelay: ORACLE_MAX_DELAY,
    },
    {
      id: "syzusd-usd",
      label: "SYZUSD/USD via SYZUSD/YZUSD * YZUSD/USD",
      reserveSymbol: "SYZUSD",
      ratioFeed: MAINNET_FEEDS.SYZUSD_YZUSD,
      baseFeed: MAINNET_FEEDS.YZUSD_USD,
      source: "aave-v3-neverland",
      maxDelay: ORACLE_MAX_DELAY,
    },
  ],
  // loAZND no longer uses vault-share conversion. The historical yield adapter and
  // hardcoded feed are retired sources, not deployment presets for the current market.
  yieldPresets: [],
  governedSources: [
    {
      id: "loaznd-usd",
      label: "loAZND/USD via GovernedPriceOracle",
      reserveSymbol: "LOAZND",
      feed: MAINNET_FEEDS.LOAZND_USD,
      source: "aave-v3-neverland",
    },
  ],
};

export const ORACLE_CONFIG_BY_NETWORK: Record<
  NetworkName,
  OracleNetworkConfig
> = {
  mainnet: MAINNET_ORACLE_CONFIG,
  fork: MAINNET_ORACLE_CONFIG,
};

export const resolveOracleConfig = (networkName: string): OracleNetworkConfig =>
  ORACLE_CONFIG_BY_NETWORK[resolveNetwork(networkName)];

export const getRatioPresetById = (
  networkName: string,
  id: string
): RatioOraclePreset | undefined =>
  resolveOracleConfig(networkName).ratioPresets.find(
    (preset) => preset.id === id
  );

export const getYieldPresetById = (
  networkName: string,
  id: string
): YieldOraclePreset | undefined =>
  resolveOracleConfig(networkName).yieldPresets.find(
    (preset) => preset.id === id
  );

export const getGovernedSourceById = (
  networkName: string,
  id: string
): GovernedOracleSource | undefined =>
  resolveOracleConfig(networkName).governedSources.find(
    (source) => source.id === id
  );
