import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { id } from "ethers";
import { glob as typechainGlob, runTypeChain } from "typechain";
import packaging from "./package.cjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const readJson = (file) => JSON.parse(fs.readFileSync(file, "utf8"));
const slash = (file) => file.split(path.sep).join("/");
// Preserve the POSIX paths expected by TypeChain when glob returns Windows paths.
const glob = (...args) => typechainGlob(...args).map(slash);
const { sources, remappings } = packaging.productionSources();
const names = new Map();
const legacyNames = new Set();
for (const source of sources) {
  const relative = slash(path.relative(root, source));
  const mapping = remappings.find(([, destination]) =>
    relative.startsWith(destination)
  );
  const legacy = mapping
    ? `${mapping[0]}${relative.slice(mapping[1].length)}`
    : relative;
  assert(!legacyNames.has(legacy), `ambiguous legacy source name: ${legacy}`);
  legacyNames.add(legacy);
  names.set(`project/${relative}`, legacy);
}

// Hardhat 3 changes compiler source names and only emits root artifacts. Generate
// bindings from the complete compiler output in the established public namespaces.
// This generated compatibility view also feeds Wagmi without changing native artifacts.
const artifacts = path.join(root, "generated/artifacts");
fs.rmSync(artifacts, { recursive: true, force: true });
async function buildBindings() {
  const seen = new Set();
  const libraryKeys = new Map();
  const buildIds = new Set(
    glob(root, ["artifacts/src/**/*.json"])
      .filter((file) => !file.endsWith(".dbg.json"))
      .map((file) => {
        const artifact = readJson(file);
        assert.equal(artifact._format, "hh3-artifact-1");
        assert(artifact.buildInfoId, `missing build id: ${file}`);
        return artifact.buildInfoId;
      })
  );
  for (const buildId of buildIds) {
    assert(/^[a-zA-Z0-9_-]+$/.test(buildId), "invalid compiler build id");
    const file = `${buildId}.json`;
    const build = readJson(path.join(root, "artifacts/build-info", file));
    const paired = readJson(
      path.join(
        root,
        "artifacts/build-info",
        file.replace(/\.json$/, ".output.json")
      )
    );
    assert.equal(build._format, "hh3-sol-build-info-1");
    assert.equal(paired._format, "hh3-sol-build-info-output-1");
    assert.equal(build.id, file.slice(0, -5));
    assert.equal(paired.id, build.id);
    for (const [source, contracts] of Object.entries(paired.output.contracts)) {
      const legacy = names.get(source);
      assert(legacy, `unexpected compiled source: ${source}`);
      assert.equal(
        build.input.sources[source].content,
        fs.readFileSync(
          path.join(root, source.slice("project/".length)),
          "utf8"
        ),
        `stale compiled source: ${source}`
      );
      for (const [name, compiled] of Object.entries(contracts)) {
        const identity = `${legacy}:${name}`;
        assert(!seen.has(identity), `duplicate compiled contract: ${identity}`);
        seen.add(identity);
        const bytecode = `0x${compiled.evm.bytecode.object}`;
        for (const [librarySource, libraries] of Object.entries(
          compiled.evm.bytecode.linkReferences
        )) {
          const legacySource = names.get(librarySource);
          assert(legacySource, `unknown library source: ${librarySource}`);
          for (const [library, positions] of Object.entries(libraries)) {
            const key = `${librarySource}:${library}`;
            const placeholder = `__$${id(key).slice(2, 36)}$__`;
            for (const { start, length } of positions) {
              assert.equal(
                length,
                20,
                `unexpected library address length: ${key}`
              );
              assert.equal(
                bytecode.slice(2 + start * 2, 2 + (start + length) * 2),
                placeholder
              );
            }
            libraryKeys.set(key, `${legacySource}:${library}`);
          }
        }
        const destination = path.join(artifacts, legacy, `${name}.json`);
        fs.mkdirSync(path.dirname(destination), { recursive: true });
        fs.writeFileSync(
          destination,
          JSON.stringify({
            contractName: name,
            sourceName: legacy,
            abi: compiled.abi,
            bytecode,
            linkReferences: compiled.evm.bytecode.linkReferences,
          })
        );
      }
    }
  }
  assert(seen.size, "no compiled contracts available for bindings");
  // Match the former Hardhat TypeChain plugin's glob and ordering, including
  // duplicate contract names whose top-level export selects the first source.
  const allFiles = glob(root, [
    `${slash(artifacts)}/!(build-info)/**/+([a-zA-Z0-9_]).json`,
  ]).sort((a, b) => a.localeCompare(b, "en"));
  const outDir = path.join(root, "generated/types");
  fs.rmSync(outDir, { recursive: true, force: true });
  await runTypeChain({
    cwd: root,
    allFiles,
    filesToProcess: allFiles,
    outDir,
    target: "ethers-v6",
    flags: { node16Modules: true },
  });
  // Keep the established typed library-address keys. TypeChain still substitutes
  // the original HH3 placeholder, so raw native bytecode remains unchanged.
  for (const file of glob(root, [`${slash(outDir)}/factories/**/*.ts`])) {
    let contents = fs.readFileSync(file, "utf8");
    for (const [canonical, legacy] of libraryKeys) {
      contents = contents.replaceAll(
        JSON.stringify(canonical),
        JSON.stringify(legacy)
      );
    }
    fs.writeFileSync(file, contents);
  }
  console.log(
    `Generated compatible ethers v6 bindings from ${seen.size} compiler outputs.`
  );
}

await buildBindings();
