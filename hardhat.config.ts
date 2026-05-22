import "@nomicfoundation/hardhat-ethers";
import "@nomicfoundation/hardhat-chai-matchers";
import "@nomicfoundation/hardhat-foundry";
import "@typechain/hardhat";
require("dotenv").config();

const ETHERS_V5 = process.env.ETHERS_V5 === "true";

export default {
  solidity: {
    version: "0.8.30",
    settings: {
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
    outDir: ETHERS_V5 ? "typechain-v5" : "typechain-v6",
    target: ETHERS_V5 ? "ethers-v5" : "ethers-v6",
  },
};
