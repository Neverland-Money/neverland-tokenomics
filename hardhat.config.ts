import "@nomicfoundation/hardhat-ethers";
import "@nomicfoundation/hardhat-foundry";
import "@typechain/hardhat";
export default {
  paths: {
    sources: "./src",
    cache: "./cache_hardhat",
  },
  solidity: {
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
      chainId: 31337,
    },
  },
  typechain: {
    outDir: "generated/types",
    target: "ethers-v6",
  },
};
