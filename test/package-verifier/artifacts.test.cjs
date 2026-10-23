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
const linkedArtifactPath = path.resolve(
  "artifacts/src/utils/NeverlandUiProvider.sol/NeverlandUiProvider.json"
);
const vendorPath = path.resolve(
  "vendor/openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol"
);

// Run serially so each tamper is restored before another verifier or consumer reads it.
test("the package verifier rejects corrupted source, dependency, and compiler evidence", async (t) => {
  await verify();
  const cases = [
    [
      "wrong recorded source hash",
      path.resolve("package.json"),
      (manifest) => {
        manifest.neverland.sourceHash = `sha256:${"0".repeat(64)}`;
      },
      /Solidity sources changed since the recorded sync/,
    ],
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
      "missing creation library links",
      linkedArtifactPath,
      (a) => {
        assert(
          Object.keys(a.linkReferences).length,
          "fixture must use libraries"
        );
        a.linkReferences = {};
      },
      /stale library link references/,
    ],
    [
      "missing runtime library links",
      linkedArtifactPath,
      (a) => {
        assert(
          Object.keys(a.deployedLinkReferences).length,
          "fixture must use runtime libraries"
        );
        a.deployedLinkReferences = {};
      },
      /stale runtime link references/,
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
  await t.test(
    "vendored Solidity differs from the pinned dependency",
    async () => {
      const original = fs.readFileSync(vendorPath);
      try {
        fs.appendFileSync(vendorPath, "\n// corrupted package dependency\n");
        await assert.rejects(verify(), /vendored dependency drift/);
      } finally {
        fs.writeFileSync(vendorPath, original);
      }
    }
  );
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
