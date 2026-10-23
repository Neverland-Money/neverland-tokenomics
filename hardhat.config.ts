import hardhatEthers from "@nomicfoundation/hardhat-ethers";
import hardhatFoundry from "@nomicfoundation/hardhat-foundry";
import { defineConfig } from "hardhat/config";

export default defineConfig({
  plugins: [hardhatEthers, hardhatFoundry],
  paths: {
    sources: "./src",
    cache: "./cache_hardhat",
  },
  solidity: {
    splitTestsCompilation: true,
    version: "0.8.30",
    settings: {
      evmVersion: "cancun",
      optimizer: {
        enabled: true,
        runs: 200,
      },
      metadata: {
        bytecodeHash: "none",
        useLiteralContent: true,
      },
    },
  },
  networks: {
    hardhat: {
      type: "edr-simulated",
      chainId: 31337,
    },
  },
});
