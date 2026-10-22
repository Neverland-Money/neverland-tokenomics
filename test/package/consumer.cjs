const assert = require("node:assert/strict");
const { readFileSync, readdirSync } = require("node:fs");
const { isBuiltin } = require("node:module");
const { basename, dirname, join } = require("node:path");
const { isDeepStrictEqual } = require("node:util");
const { Interface } = require("ethers");
const publicExports = require("@neverland-money/tokenomics-core");
const {
  dustAbi,
  dustLockAbi,
  addresses,
} = require("@neverland-money/tokenomics-core");
const { Dust__factory } = require("@neverland-money/tokenomics-core/types");
const {
  Dust__factory: NestedDustFactory,
} = require("@neverland-money/tokenomics-core/types/factories/src/tokens/Dust__factory");
const artifact = require("@neverland-money/tokenomics-core/artifacts/src/tokens/Dust.sol/Dust.json");
const addressBook = require("@neverland-money/tokenomics-core/addresses");
const manifest = require("@neverland-money/tokenomics-core/package.json");
const packageRoot = dirname(
  require.resolve("@neverland-money/tokenomics-core/package.json")
);

assert(manifest.dependencies.ethers, "ethers is missing at runtime");
assert(!manifest.devDependencies.ethers, "ethers is a dev-only dependency");
assert.deepEqual(addresses, addressBook);
assert.equal(NestedDustFactory, Dust__factory);
assert(
  readFileSync(
    require.resolve("@neverland-money/tokenomics-core/remappings"),
    "utf8"
  ).includes("=vendor/")
);
for (const file of [
  "src/tokens/Dust.sol",
  "vendor/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol",
]) {
  assert(
    readFileSync(
      require.resolve(`@neverland-money/tokenomics-core/${file}`),
      "utf8"
    ).includes("pragma solidity"),
    `unusable Solidity subpath: ${file}`
  );
}

assert.deepEqual(dustAbi, artifact.abi);
assert(new Interface(dustLockAbi).getFunction("createLock"));
assert.equal(
  Dust__factory.connect(addresses.addresses.Dust).target,
  addresses.addresses.Dust
);
assert.equal(
  Dust__factory.createInterface().getFunction("transfer").selector,
  "0xa9059cbb"
);
assert.notEqual(artifact.bytecode, "0x");

const files = (directory) =>
  readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const file = join(directory, entry.name);
    return entry.isDirectory() ? files(file) : [file];
  });
const runtimeDependencies = new Set();
for (const file of files(join(packageRoot, "dist"))) {
  if (!file.endsWith(".js")) continue;
  const imported = readFileSync(file, "utf8").matchAll(
    /\brequire\(["']([^"']+)["']\)/g
  );
  for (const [, dependency] of imported) {
    if (dependency.startsWith(".") || isBuiltin(dependency)) continue;
    const name = dependency
      .split("/")
      .slice(0, dependency.startsWith("@") ? 2 : 1)
      .join("/");
    assert(
      manifest.dependencies[name],
      `exported JavaScript imports undeclared runtime dependency: ${dependency}`
    );
    assert(require.resolve(dependency, { paths: [dirname(file)] }));
    runtimeDependencies.add(name);
  }
}
assert(runtimeDependencies.has("ethers"));
const factories = files(
  join(packageRoot, "dist/generated/types/factories/src")
).filter((file) => file.endsWith("__factory.js"));
const abis = Object.values(publicExports).filter(Array.isArray);
for (const abi of abis) {
  assert.equal(new Interface(abi).fragments.length, abi.length);
}
let checkedFactories = 0;
let checkedLinks = 0;
for (const file of files(join(packageRoot, "artifacts/src"))) {
  if (!file.endsWith(".json")) continue;
  const current = JSON.parse(readFileSync(file, "utf8"));
  // TypeChain omits libraries with an empty ABI.
  if (!current.abi.length) continue;
  const name = `${current.contractName}__factory`;
  const candidate = factories
    .filter((file) => basename(file) === `${name}.js`)
    .map((file) => require(file)[name])
    .find((factory) => isDeepStrictEqual(factory.abi, current.abi));
  assert(candidate, `missing or stale factory for ${current.sourceName}`);
  checkedFactories++;
  const isLibrary = /^(src\/libraries|src\/utils\/libraries)\//.test(
    current.sourceName
  );
  if (!isLibrary) {
    assert(
      abis.some((abi) => isDeepStrictEqual(abi, current.abi)),
      `missing root ABI export for ${current.sourceName}:${current.contractName}`
    );
    assert.equal(
      candidate.createInterface().fragments.length,
      current.abi.length
    );
    assert.equal(
      candidate.connect(addresses.addresses.Dust).target,
      addresses.addresses.Dust
    );
  }
  if (current.bytecode !== "0x") {
    assert.equal(candidate.bytecode, current.bytecode);
    const links = Object.entries(current.linkReferences).flatMap(
      ([source, libraries]) =>
        Object.keys(libraries).map((name) => [
          `${source}:${name}`,
          addresses.addresses.Dust,
        ])
    );
    if (links.length) {
      assert.match(
        candidate.linkBytecode(Object.fromEntries(links)),
        /^0x[0-9a-f]+$/i
      );
      if (!isLibrary) new candidate(Object.fromEntries(links));
      checkedLinks++;
    } else if (!isLibrary) {
      new candidate();
    }
  }
}
assert(checkedFactories > 0);
assert(checkedLinks > 0);
console.log(
  `Production install verified ${abis.length} root ABIs, ${checkedFactories} first-party factories, and ${checkedLinks} linked factories.`
);
