const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const { verify } = require("../../tools/package.cjs");

const artifactPath = path.resolve("artifacts/src/tokens/Dust.sol/Dust.json");
const originalArtifact = fs.readFileSync(artifactPath);
const artifact = JSON.parse(originalArtifact);
const inputPath = path.resolve(
  `artifacts/build-info/${artifact.buildInfoId}.json`
);
const outputPath = inputPath.replace(/\.json$/, ".output.json");

// Run serially so each tamper is restored before another verifier or consumer reads it.
test("the package verifier rejects stale or mismatched Hardhat 3 compiler evidence", async (t) => {
  await verify();
  const cases = [
    [
      "unknown build id",
      artifactPath,
      (a) => {
        a.buildInfoId = "foreign";
      },
      /stale or unknown compiler build/,
    ],
    [
      "wrong input source",
      artifactPath,
      (a) => {
        a.inputSourceName = "project/src/foreign.sol";
      },
      /invalid compiler source mapping/,
    ],
    [
      "stale source",
      inputPath,
      (b) => {
        b.input.sources[artifact.inputSourceName].content += "\n// stale";
      },
      /stale compiler sources or settings/,
    ],
    [
      "stale settings",
      inputPath,
      (b) => {
        b.input.settings.optimizer.runs += 1;
      },
      /stale compiler sources or settings/,
    ],
    [
      "wrong source map",
      inputPath,
      (b) => {
        b.userSourceNameMap[artifact.sourceName] = "project/src/foreign.sol";
      },
      /stale compiler source map/,
    ],
    [
      "wrong paired id",
      outputPath,
      (b) => {
        b.id = "foreign";
      },
      /mismatched build output id/,
    ],
    [
      "wrong paired format",
      outputPath,
      (b) => {
        b._format = "hh-sol-build-info-1";
      },
      /hh3-sol-build-info-output-1/,
    ],
    [
      "stale ABI",
      artifactPath,
      (a) => {
        a.abi.pop();
      },
      /stale ABI/,
    ],
    [
      "stale bytecode",
      artifactPath,
      (a) => {
        a.bytecode += "00";
      },
      /stale bytecode/,
    ],
    [
      "stale runtime",
      artifactPath,
      (a) => {
        a.deployedBytecode += "00";
      },
      /stale runtime bytecode/,
    ],
  ];
  for (const [name, file, mutate, error] of cases) {
    await t.test(name, async () => {
      const original = fs.readFileSync(file);
      try {
        const data = JSON.parse(original);
        mutate(data);
        fs.writeFileSync(file, JSON.stringify(data));
        await assert.rejects(verify(), error);
      } finally {
        fs.writeFileSync(file, original);
      }
    });
  }
  await t.test("missing artifact", async () => {
    fs.rmSync(artifactPath);
    try {
      await assert.rejects(verify(), /missing artifact/);
    } finally {
      fs.writeFileSync(artifactPath, originalArtifact);
    }
  });
  await verify();
});
