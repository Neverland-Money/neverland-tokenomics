const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const { createHash } = require("node:crypto");
const {
  constants,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const { join, relative, resolve, sep } = require("node:path");
const { test } = require("node:test");

const files = (directory) =>
  readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const file = join(directory, entry.name);
    return entry.isDirectory() ? files(file) : [file];
  });

test("the installed release supports JS, TypeScript, and every Solidity source", (t) => {
  const directory = mkdtempSync(join(tmpdir(), "tokenomics-pack-"));

  try {
    const packResult = JSON.parse(
      execFileSync(
        "npm",
        ["pack", "--ignore-scripts", "--json", "--pack-destination", directory],
        { encoding: "utf8", maxBuffer: 16 * 1024 * 1024 }
      )
    );
    // npm 12 keys JSON results by package name; older CLIs return an array.
    const packages = Array.isArray(packResult)
      ? packResult
      : Object.values(packResult);
    assert.equal(packages.length, 1, "expected exactly one packed package");
    const [packed] = packages;
    const paths = packed.files.map(({ path }) => path);
    for (const [directory, matches] of [
      ["src", (file) => file.endsWith(".sol")],
      [
        "artifacts/src",
        (file) => file.endsWith(".json") && !file.endsWith(".dbg.json"),
      ],
    ]) {
      const expected = files(resolve(directory))
        .filter(matches)
        .map((file) => relative(process.cwd(), file).split(sep).join("/"))
        .sort();
      assert(
        expected.length,
        `missing repository release inputs: ${directory}`
      );
      assert.deepEqual(
        paths
          .filter((file) => file.startsWith(`${directory}/`) && matches(file))
          .sort(),
        expected,
        `published ${directory} files differ from the repository release inputs`
      );
    }

    assert(paths.includes("dist/index.js"), "missing package entry point");
    assert(paths.includes("dist/index.d.ts"), "missing package declarations");
    assert(paths.includes("ADDRESS_BOOK.md"), "missing address book");
    assert(paths.includes("src/tokens/Dust.sol"), "missing Solidity source");
    assert(
      paths.includes("artifacts/src/tokens/Dust.sol/Dust.json"),
      "missing contract artifact"
    );
    assert(
      paths.includes("remappings.package.txt"),
      "missing pinned Solidity dependency remappings"
    );
    assert(
      !paths.some((path) =>
        /^(test|tools|out|cache|node_modules)\//.test(path)
      ),
      "development files leaked into the release tarball"
    );
    assert(
      !paths.some((path) => /(^|\/)\.env(?:\.|$)/.test(path)),
      "environment file leaked into the release tarball"
    );
    assert(
      !paths.some(
        (path) =>
          path.endsWith(".dbg.json") ||
          (path.startsWith("artifacts/") && path.endsWith(".d.ts")) ||
          path.includes("/build-info/")
      ),
      "local compiler tooling leaked into the release tarball"
    );
    assert.equal(packed.name, "@neverland-money/tokenomics-core");
    assert.equal(
      packed.version,
      JSON.parse(readFileSync("package.json", "utf8")).version
    );

    writeFileSync(join(directory, "package.json"), '{"private":true}\n');
    const run = (command, args) =>
      execFileSync(command, args, {
        cwd: directory,
        encoding: "utf8",
        maxBuffer: 16 * 1024 * 1024,
        timeout: 120_000,
      });
    run("npm", [
      "install",
      "--omit=dev",
      "--no-audit",
      "--no-fund",
      "--package-lock=false",
      join(directory, packed.filename),
    ]);
    run("npm", ["ls", "--omit=dev", "--all"]);
    for (const name of ["typescript", "hardhat", "@wagmi/cli"]) {
      assert(
        !existsSync(join(directory, "node_modules", name)),
        `development dependency installed for a production consumer: ${name}`
      );
    }
    for (const name of ["consumer.cjs", "consumer.mjs", "consumer.mts"]) {
      copyFileSync(join(__dirname, name), join(directory, name));
    }
    t.diagnostic(run(process.execPath, ["consumer.cjs"]).trim());
    run(process.execPath, ["consumer.mjs"]);
    run(process.execPath, [
      resolve("node_modules/typescript/bin/tsc"),
      "--noEmit",
      "--module",
      "node16",
      "--moduleResolution",
      "node16",
      "--target",
      "es2022",
      "--strict",
      "consumer.mts",
    ]);

    copyFileSync(
      join(directory, "consumer.mts"),
      join(directory, "consumer.cts")
    );
    run(process.execPath, [
      resolve("node_modules/typescript/bin/tsc"),
      "--noEmit",
      "--module",
      "node16",
      "--moduleResolution",
      "node16",
      "--target",
      "es2022",
      "--strict",
      "consumer.cts",
    ]);
    run(process.execPath, [
      resolve("node_modules/typescript/bin/tsc"),
      "--noEmit",
      "--module",
      "commonjs",
      "--moduleResolution",
      "node",
      "--target",
      "es2022",
      "--strict",
      "consumer.cts",
    ]);

    const packageRoot = join(
      directory,
      "node_modules/@neverland-money/tokenomics-core"
    );
    const remappings = readFileSync(
      join(packageRoot, "remappings.package.txt"),
      "utf8"
    )
      .trim()
      .split("\n")
      .map((line) => {
        const [prefix, destination] = line.split("=");
        return `${prefix}=${join(packageRoot, destination)}`;
      });
    remappings.push(`@neverland-money/tokenomics-core/=${packageRoot}/`);
    writeFileSync(
      join(directory, "foundry.toml"),
      [
        "[profile.default]",
        'solc = "0.8.30"',
        'evm_version = "cancun"',
        "optimizer = true",
        "optimizer_runs = 200",
        `remappings = ${JSON.stringify(remappings)}`,
      ].join("\n") + "\n"
    );
    mkdirSync(join(directory, "src"));
    const imports = paths
      .filter((path) => path.startsWith("src/") && path.endsWith(".sol"))
      .map(
        (path, index) =>
          `import * as Public${index} from "@neverland-money/tokenomics-core/${path}";`
      );
    writeFileSync(
      join(directory, "src/Imports.sol"),
      [
        "// SPDX-License-Identifier: MIT",
        "pragma solidity 0.8.30;",
        ...imports,
      ].join("\n") + "\n"
    );
    run("forge", ["build"]);

    if (process.env.TOKENOMICS_RELEASE_OUTPUT !== undefined) {
      const output = process.env.TOKENOMICS_RELEASE_OUTPUT;
      const sha = process.env.GITHUB_SHA;
      assert(output.trim(), "TOKENOMICS_RELEASE_OUTPUT must name a directory");
      assert(
        /^[a-f0-9]{40}$/i.test(sha || ""),
        "GITHUB_SHA must be a 40-character hexadecimal commit SHA when exporting a release"
      );
      assert(
        typeof packed.filename === "string" &&
          /^[a-zA-Z0-9][a-zA-Z0-9._-]*\.tgz$/.test(packed.filename),
        "npm pack returned an unsafe release archive filename"
      );
      const archive = join(directory, packed.filename);
      const integrity = `sha512-${createHash("sha512")
        .update(readFileSync(archive))
        .digest("base64")}`;
      assert.equal(
        integrity,
        packed.integrity,
        "release archive integrity differs from npm pack metadata"
      );
      const destination = resolve(output);
      mkdirSync(destination, { recursive: true });
      assert.equal(
        readdirSync(destination).length,
        0,
        `release output directory must be new or empty: ${destination}`
      );
      copyFileSync(
        archive,
        join(destination, packed.filename),
        constants.COPYFILE_EXCL
      );
      writeFileSync(
        join(destination, "release.json"),
        JSON.stringify(
          {
            name: packed.name,
            version: packed.version,
            filename: packed.filename,
            integrity: packed.integrity,
            sha,
          },
          null,
          2
        ) + "\n",
        { flag: "wx" }
      );
      t.diagnostic(`release candidate exported to ${destination}`);
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
