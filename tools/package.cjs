const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const { createHash } = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const readJson = (file) =>
  JSON.parse(fs.readFileSync(path.join(root, file), "utf8"));
const slash = (file) => file.split(path.sep).join("/");

function readAddressBook() {
  const markdown = fs.readFileSync(path.join(root, "ADDRESS_BOOK.md"), "utf8");
  const entries = new Map();
  for (const [, key, raw] of markdown.matchAll(
    /^\|\s*`([^`]+)`\s*\|\s*`([^`]+)`\s*\|/gm
  )) {
    assert(
      /^(?:[A-Za-z0-9_-]+\.)*[A-Za-z0-9_-]+$/.test(key),
      `invalid address-book key: ${key}`
    );
    assert(
      !key
        .split(".")
        .some((part) =>
          ["__proto__", "constructor", "prototype"].includes(part)
        ),
      `reserved address-book key: ${key}`
    );
    assert(!entries.has(key), `duplicate address-book key: ${key}`);
    entries.set(key, raw);
  }
  assert(entries.size, "address book contains no data rows");

  function resolve(key, visited = new Set()) {
    assert(entries.has(key), `missing address-book key: ${key}`);
    assert(!visited.has(key), `circular address-book alias: ${key}`);
    visited.add(key);
    const raw = entries.get(key);
    if (raw.startsWith("@")) return resolve(raw.slice(1), visited);
    if (key === "chainId") {
      assert(/^\d+$/.test(raw) && Number(raw) > 0, "invalid chain ID");
      return Number(raw);
    }
    if (
      key !== "networkName" &&
      !key.startsWith("governance.tokenomics.runtimeSurfaceHints.")
    )
      assert(/^0x[0-9a-fA-F]{40}$/.test(raw), `invalid address: ${key}`);
    return raw;
  }

  const book = {};
  for (const key of entries.keys()) {
    const parts = key.split(".");
    const leaf = parts.pop();
    let target = book;
    for (const part of parts) {
      target[part] ??= {};
      assert.equal(typeof target[part], "object", `conflicting key: ${key}`);
      target = target[part];
    }
    assert(!(leaf in target), `conflicting key: ${key}`);
    target[leaf] = resolve(key);
  }
  assert.equal(typeof book.networkName, "string", "missing network name");
  assert.equal(typeof book.chainId, "number", "missing chain ID");
  return book;
}

function prepareAddresses() {
  const book = readAddressBook();
  fs.mkdirSync(path.join(root, "generated"), { recursive: true });
  fs.writeFileSync(
    path.join(root, "generated/addresses.json"),
    JSON.stringify(book, null, 2) + "\n"
  );
  fs.writeFileSync(
    path.join(root, "generated/addresses.ts"),
    `export const addresses = ${JSON.stringify(book, null, 2)} as const;\n`
  );
  console.log(`Generated ${book.networkName} addresses from ADDRESS_BOOK.md.`);
}

function files(directory, excluded = new Set()) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const file = path.join(directory, entry.name);
    return entry.isDirectory()
      ? excluded.has(entry.name)
        ? []
        : files(file, excluded)
      : [file];
  });
}

function sourceHash() {
  const hash = createHash("sha256");
  for (const file of files(path.join(root, "src")).sort()) {
    if (!file.endsWith(".sol")) continue;
    hash.update(`${slash(path.relative(root, file))}\0`);
    hash.update(fs.readFileSync(file));
    hash.update("\0");
  }
  return `sha256:${hash.digest("hex")}`;
}

function productionSources() {
  const remappings = fs
    .readFileSync(path.join(root, "remappings.txt"), "utf8")
    .trim()
    .split("\n")
    .map((line) => line.trim().split("="))
    .sort(([a], [b]) => b.length - a.length);
  const pending = files(path.join(root, "src")).filter((file) =>
    file.endsWith(".sol")
  );
  const sources = new Set();
  const used = new Map();

  while (pending.length) {
    const file = pending.pop();
    if (sources.has(file)) continue;
    sources.add(file);
    const text = fs.readFileSync(file, "utf8");
    const imports = text.matchAll(
      /\bimport\s+(?:[^;]*?\s+from\s+)?["']([^"']+)["'](?:\s+as\s+\w+)?\s*;/g
    );
    for (const [, name] of imports) {
      let target;
      if (name.startsWith(".")) {
        target = path.resolve(path.dirname(file), name);
      } else {
        const mapping = remappings.find(([prefix]) => name.startsWith(prefix));
        assert(mapping, `unmapped Solidity import ${name}`);
        const [prefix, destination] = mapping;
        target = path.resolve(root, destination, name.slice(prefix.length));
        if (destination.startsWith("lib/")) used.set(prefix, destination);
      }
      assert(
        target.startsWith(`${root}${path.sep}`),
        `import escapes repository: ${name}`
      );
      assert(fs.existsSync(target), `missing Solidity dependency: ${name}`);
      pending.push(target);
    }
  }
  return { sources: [...sources].sort(), remappings: [...used].sort() };
}

function prepare() {
  const { sources, remappings } = productionSources();
  const dependencies = sources.filter((file) =>
    file.startsWith(path.join(root, "lib") + path.sep)
  );
  const libraries = new Set(
    dependencies.map((file) => path.relative(root, file).split(path.sep)[1])
  );
  const lock = readJson("foundry.lock");

  for (const library of libraries) {
    const directory = path.join(root, "lib", library);
    const expected = lock[`lib/${library}`];
    const pin = expected.rev ?? expected.tag?.rev ?? expected.branch?.rev;
    const actual = execFileSync("git", ["rev-parse", "HEAD"], {
      cwd: directory,
      encoding: "utf8",
    }).trim();
    assert.equal(actual, pin, `dependency pin mismatch: ${library}`);
    assert.equal(
      execFileSync("git", ["status", "--porcelain"], {
        cwd: directory,
        encoding: "utf8",
      }),
      "",
      `dirty dependency: ${library}`
    );
  }

  fs.rmSync(path.join(root, "vendor"), { recursive: true, force: true });
  for (const file of dependencies) {
    const destination = path.join(
      root,
      "vendor",
      path.relative(path.join(root, "lib"), file)
    );
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.copyFileSync(file, destination);
  }
  for (const library of libraries) {
    const directory = path.join(root, "lib", library);
    const notices = files(
      directory,
      new Set([".git", "node_modules", "lib", "out", "cache", "artifacts"])
    ).filter(
      (file) =>
        /^(license|notice)([-_.]|$)/i.test(path.basename(file)) ||
        path.relative(directory, file).split(path.sep).includes("licenses")
    );
    assert(notices.length, `dependency license missing: ${library}`);
    for (const file of notices) {
      const destination = path.join(
        root,
        "vendor",
        library,
        path.relative(directory, file)
      );
      fs.mkdirSync(path.dirname(destination), { recursive: true });
      fs.copyFileSync(file, destination);
    }
  }
  fs.writeFileSync(
    path.join(root, "remappings.package.txt"),
    remappings
      .map(
        ([prefix, destination]) =>
          `${prefix}=${destination.replace(/^lib\//, "vendor/")}`
      )
      .join("\n") + "\n"
  );
  // Debug pointers and Hardhat-only declarations are local compiler tooling.
  fs.writeFileSync(
    path.join(root, "artifacts/src/.npmignore"),
    "**/*.dbg.json\n**/*.d.ts\n"
  );
  console.log(
    `Prepared ${dependencies.length} pinned dependency sources from ${libraries.size} libraries.`
  );
}

async function verify() {
  const manifest = readJson("package.json");
  assert.equal(manifest.name, "@neverland-money/tokenomics-core");
  assert(
    /^[0-9a-f]{40}$/.test(manifest.neverland.developmentCommit),
    "missing development commit"
  );
  assert.equal(
    manifest.neverland.sourceHash,
    sourceHash(),
    "Solidity sources changed since the recorded sync"
  );
  assert(
    manifest.dependencies?.ethers,
    "ethers must be a runtime dependency for generated factories"
  );
  for (const file of [
    "generated/addresses.json",
    "dist/generated/addresses.json",
  ])
    assert.deepEqual(
      readJson(file),
      readAddressBook(),
      `stale generated address book: ${file}`
    );
  assert.deepEqual(
    require(path.join(root, "dist/generated/addresses.js")).addresses,
    readAddressBook(),
    "stale compiled address module"
  );

  for (const entry of Object.values(manifest.exports)) {
    for (const target of typeof entry === "string"
      ? [entry]
      : Object.values(entry)) {
      if (target.includes("*")) continue;
      assert(
        fs.existsSync(path.join(root, target)),
        `missing package export: ${target}`
      );
    }
  }

  const { sources } = productionSources();
  const sourceSet = new Set(sources);
  const { solidity } = await import("hardhat");
  const rootFiles = await solidity.getRootFilePaths({ scope: "contracts" });
  const result = await solidity.getCompilationJobs(rootFiles, {
    force: true,
    quiet: true,
    scope: "contracts",
    buildProfile: "default",
  });
  assert(result.success, "unable to reconstruct current compiler inputs");
  const expectedBuilds = new Map();
  for (const job of new Set(result.compilationJobsPerFile.values())) {
    const input = await job.getSolcInput();
    for (const resolved of job.dependencyGraph.getAllFiles()) {
      assert(
        sourceSet.has(resolved.fsPath),
        `unexpected compiled source: ${resolved.inputSourceName}`
      );
      assert.equal(
        input.sources[resolved.inputSourceName].content,
        fs.readFileSync(resolved.fsPath, "utf8"),
        `stale compiled source: ${resolved.inputSourceName}`
      );
    }
    expectedBuilds.set(await job.getBuildId(), {
      input,
      mapping: job.dependencyGraph.getRootsUserSourceNameMap(),
      version: job.solcConfig.version,
      longVersion: job.solcLongVersion,
    });
  }
  let contracts = 0;
  const builds = new Map();
  const identities = new Set();
  for (const file of files(path.join(root, "artifacts/src"))) {
    if (!file.endsWith(".json") || file.endsWith(".dbg.json")) continue;
    const artifact = JSON.parse(fs.readFileSync(file, "utf8"));
    assert.equal(
      artifact._format,
      "hh3-artifact-1",
      `invalid artifact: ${file}`
    );
    assert(Array.isArray(artifact.abi), `missing ABI: ${file}`);
    assert(
      sourceSet.has(path.resolve(root, artifact.sourceName)),
      `missing artifact source: ${artifact.sourceName}`
    );
    assert.equal(
      file,
      path.join(
        root,
        "artifacts",
        artifact.sourceName,
        `${artifact.contractName}.json`
      ),
      "artifact path does not match its contract identity"
    );
    const expected = expectedBuilds.get(artifact.buildInfoId);
    assert(
      expected,
      `stale or unknown compiler build: ${artifact.buildInfoId}`
    );
    assert.equal(
      artifact.inputSourceName,
      expected.mapping[artifact.sourceName],
      `invalid compiler source mapping: ${artifact.sourceName}`
    );
    assert(artifact.inputSourceName, "missing compiler source name");
    if (!builds.has(artifact.buildInfoId)) {
      // Hardhat 3 stores the compiler input and output in separate paired files.
      const build = readJson(
        `artifacts/build-info/${artifact.buildInfoId}.json`
      );
      const output = readJson(
        `artifacts/build-info/${artifact.buildInfoId}.output.json`
      );
      assert.equal(build._format, "hh3-sol-build-info-1");
      assert.equal(output._format, "hh3-sol-build-info-output-1");
      assert.equal(build.id, artifact.buildInfoId, "mismatched build input id");
      assert.equal(output.id, build.id, "mismatched build output id");
      assert.equal(
        build.compilerType ?? "solc",
        "solc",
        "unexpected compiler type"
      );
      assert.equal(
        build.solcVersion,
        expected.version,
        "stale compiler version"
      );
      assert.equal(
        build.solcLongVersion,
        expected.longVersion,
        "stale compiler long version"
      );
      assert.deepEqual(
        build.input,
        expected.input,
        "stale compiler sources or settings"
      );
      assert.deepEqual(
        build.userSourceNameMap,
        expected.mapping,
        "stale compiler source map"
      );
      assert(
        !(output.output.errors ?? []).some(
          ({ severity }) => severity === "error"
        ),
        "compiler output contains errors"
      );
      builds.set(build.id, output.output);
    }
    const compiled = builds.get(artifact.buildInfoId).contracts[
      artifact.inputSourceName
    ]?.[artifact.contractName];
    assert(
      compiled,
      `missing compiler output: ${artifact.sourceName}:${artifact.contractName}`
    );
    assert.deepEqual(
      artifact.abi,
      compiled.abi,
      `stale ABI: ${artifact.contractName}`
    );
    assert.equal(
      artifact.bytecode,
      `0x${compiled.evm.bytecode.object}`,
      `stale bytecode: ${artifact.contractName}`
    );
    assert.equal(
      artifact.deployedBytecode,
      `0x${compiled.evm.deployedBytecode.object}`,
      `stale runtime bytecode: ${artifact.contractName}`
    );
    assert.deepEqual(
      artifact.linkReferences,
      compiled.evm.bytecode.linkReferences,
      `stale library link references: ${artifact.contractName}`
    );
    assert.deepEqual(
      artifact.deployedLinkReferences,
      compiled.evm.deployedBytecode.linkReferences,
      `stale runtime link references: ${artifact.contractName}`
    );
    assert.deepEqual(
      artifact.immutableReferences,
      compiled.evm.deployedBytecode.immutableReferences ?? {},
      `stale immutable references: ${artifact.contractName}`
    );
    identities.add(`${artifact.sourceName}:${artifact.contractName}`);
    contracts++;
  }
  assert(contracts > 0, "no first-party artifacts found");
  for (const [buildId, expected] of expectedBuilds) {
    const output = builds.get(buildId);
    assert(output, `missing artifacts for compiler build: ${buildId}`);
    for (const [source, inputSource] of Object.entries(expected.mapping)) {
      for (const name of Object.keys(output.contracts[inputSource] ?? {})) {
        assert(
          identities.has(`${source}:${name}`),
          `missing artifact: ${source}:${name}`
        );
      }
    }
  }

  for (const file of sources.filter((file) =>
    file.startsWith(path.join(root, "lib") + path.sep)
  )) {
    const shipped = path.join(
      root,
      "vendor",
      path.relative(path.join(root, "lib"), file)
    );
    assert(fs.existsSync(shipped), `missing vendored dependency: ${shipped}`);
    assert.deepEqual(
      fs.readFileSync(shipped),
      fs.readFileSync(file),
      `vendored dependency drift: ${shipped}`
    );
  }
  console.log(
    `Verified ${contracts} first-party artifacts, package exports, source identity, and dependency contents.`
  );
}

if (require.main === module) {
  const command = process.argv[2];
  if (command === "prepare") prepare();
  else if (command === "addresses") prepareAddresses();
  else if (command === "verify")
    verify().catch((error) => {
      console.error(error);
      process.exitCode = 1;
    });
  else if (command === "dist") {
    // Keep published JavaScript and declarations CommonJS under the ESM toolchain root.
    fs.writeFileSync(
      path.join(root, "dist/package.json"),
      '{"type":"commonjs"}\n'
    );
  } else if (command === "hash") console.log(sourceHash());
  else if (command === "clean-dist")
    fs.rmSync(path.join(root, "dist"), { recursive: true, force: true });
  else if (command === "clean") {
    for (const entry of [
      "dist",
      "generated",
      "vendor",
      "remappings.package.txt",
    ])
      fs.rmSync(path.join(root, entry), { recursive: true, force: true });
  } else throw new Error(`unknown package command: ${command}`);
}

module.exports = { sourceHash, productionSources, verify, readAddressBook };
