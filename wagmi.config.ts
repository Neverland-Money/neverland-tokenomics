import { defineConfig } from "@wagmi/cli";
import { hardhat } from "@wagmi/cli/plugins";

export default defineConfig({
  out: "generated/abis.ts",
  contracts: [],
  plugins: [
    hardhat({
      artifacts: "./artifacts",
      project: ".",
      include: ["src/**/*.json"],
      exclude: ["**/*.dbg.json", "src/libraries/**", "src/utils/libraries/**"],
    }),
  ],
});
