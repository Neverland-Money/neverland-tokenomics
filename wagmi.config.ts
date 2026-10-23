import { defineConfig } from "@wagmi/cli";
import { hardhat } from "@wagmi/cli/plugins";

export default defineConfig({
  out: "generated/abis.ts",
  contracts: [],
  plugins: [
    hardhat({
      artifacts: "./generated/artifacts",
      project: ".",
      sources: "src",
      commands: {
        build: "yarn hardhat build --no-tests && node tools/bindings.mjs",
        rebuild: "yarn hardhat build --no-tests && node tools/bindings.mjs",
      },
      include: ["src/**/*.json"],
      exclude: ["**/*.dbg.json", "src/libraries/**", "src/utils/libraries/**"],
    }),
  ],
});
