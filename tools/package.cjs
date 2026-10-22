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
  // Debug pointers refer to local compiler build-info, which is excluded from the tarball.
  fs.writeFileSync(
    path.join(root, "artifacts/src/.npmignore"),
    "**/*.dbg.json\n"
  );
  console.log(
    `Prepared ${dependencies.length} pinned dependency sources from ${libraries.size} libraries.`
  );
}

function verify() {
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

  const { sources, remappings } = productionSources();
  const sourceSet = new Set(sources);
  require("hardhat/register");
  const { compilers, overrides } = require("hardhat").config.solidity;
  let contracts = 0;
  const builds = new Map();
  for (const file of files(path.join(root, "artifacts/src"))) {
    if (!file.endsWith(".json") || file.endsWith(".dbg.json")) continue;
    const artifact = JSON.parse(fs.readFileSync(file, "utf8"));
    assert(Array.isArray(artifact.abi), `missing ABI: ${file}`);
    assert(
      fs.existsSync(path.join(root, artifact.sourceName)),
      `missing artifact source: ${artifact.sourceName}`
    );
    const debug = JSON.parse(
      fs.readFileSync(file.replace(/\.json$/, ".dbg.json"), "utf8")
    );
    const buildPath = path.resolve(path.dirname(file), debug.buildInfo);
    if (!builds.has(buildPath)) {
      const build = JSON.parse(fs.readFileSync(buildPath, "utf8"));
      for (const [name, source] of Object.entries(build.input.sources)) {
        const mapping = remappings.find(([prefix]) => name.startsWith(prefix));
        const local = mapping
          ? path.resolve(root, mapping[1], name.slice(mapping[0].length))
          : path.resolve(root, name);
        assert(sourceSet.has(local), `unexpected compiled source: ${name}`);
        assert.equal(
          source.content,
          fs.readFileSync(local, "utf8"),
          `stale compiled source: ${name}`
        );
      }
      builds.set(buildPath, build);
    }
    const build = builds.get(buildPath);
    const compiler =
      overrides[artifact.sourceName] ??
      compilers.find(({ version }) => version === build.solcVersion);
    assert(compiler, `unconfigured compiler: ${build.solcVersion}`);
    assert.equal(build.solcVersion, compiler.version, "stale compiler version");
    assert.deepEqual(
      build.input.settings,
      compiler.settings,
      `stale compiler settings: ${artifact.sourceName}`
    );
    const compiled =
      build.output.contracts[artifact.sourceName][artifact.contractName];
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
    contracts++;
  }
  assert(contracts > 0, "no first-party artifacts found");

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
  else if (command === "verify") verify();
  else if (command === "hash") console.log(sourceHash());
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
