const { execFileSync } = require("node:child_process");
const { createHash } = require("node:crypto");
const {
  appendFileSync,
  copyFileSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const { basename, join, resolve } = require("node:path");
const { setTimeout: sleep } = require("node:timers/promises");

const repository = "Neverland-Money/neverland-tokenomics";
const packageName = "@neverland-money/tokenomics-core";
const registry = "https://registry.npmjs.org";
const root = resolve(__dirname, "..");
const json = (path) => JSON.parse(readFileSync(path, "utf8"));

function stableVersion(version) {
  if (
    typeof version !== "string" ||
    !/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(version)
  ) {
    throw new Error(`Expected an explicit stable version, received ${version}`);
  }
  return version.split(".").map(BigInt);
}

function commitSha(sha) {
  if (
    typeof sha !== "string" ||
    !/^[a-f0-9]{40}$/.test(sha) ||
    /^0+$/.test(sha)
  ) {
    throw new Error("Expected a full, nonzero Git commit SHA");
  }
  return sha;
}

function mainPush(env) {
  return (
    env.GITHUB_REPOSITORY === repository &&
    env.GITHUB_EVENT_NAME === "push" &&
    env.GITHUB_REF === "refs/heads/main"
  );
}

function manifest(cwd) {
  const value = json(join(cwd, "package.json"));
  if (value.name !== packageName)
    throw new Error("Unexpected release package name");
  stableVersion(value.version);
  return value;
}

function planRelease({
  env = process.env,
  cwd = root,
  execFile = execFileSync,
} = {}) {
  const current = manifest(cwd);
  let requested = false;
  if (mainPush(env)) {
    const before = commitSha(env.GITHUB_EVENT_BEFORE);
    const previous = JSON.parse(
      execFile("git", ["show", `${before}:package.json`], {
        cwd,
        encoding: "utf8",
      })
    );
    const firstPublicRelease =
      previous.name === "neverland-contracts" &&
      previous.version === "1.1.0" &&
      current.version === "1.2.0";
    if (previous.name !== current.name && !firstPublicRelease)
      throw new Error("Release package name changed");
    const previousVersion = stableVersion(previous.version);
    const currentVersion = stableVersion(current.version);
    const changed = currentVersion.findIndex(
      (part, index) => part !== previousVersion[index]
    );
    if (changed !== -1) {
      if (currentVersion[changed] < previousVersion[changed])
        throw new Error("Package version cannot decrease");
      requested = true;
    }
  }
  const result = { release_requested: requested, version: current.version };
  if (env.GITHUB_OUTPUT)
    appendFileSync(
      env.GITHUB_OUTPUT,
      `release_requested=${requested}\nversion=${current.version}\n`
    );
  return result;
}

function readCandidate(artifactDirectory, cwd, sha) {
  commitSha(sha);
  const directory = resolve(artifactDirectory);
  const value = json(join(directory, "release.json"));
  const current = manifest(cwd);
  if (value.name !== current.name || value.version !== current.version)
    throw new Error("Release metadata differs from package.json");
  if (value.sha !== sha)
    throw new Error("Release candidate SHA differs from GITHUB_SHA");
  if (
    typeof value.filename !== "string" ||
    basename(value.filename) !== value.filename ||
    !value.filename.endsWith(".tgz")
  ) {
    throw new Error("Invalid release tarball filename");
  }
  const entries = readdirSync(directory, { withFileTypes: true });
  if (
    entries.length !== 2 ||
    entries.some(
      (entry) =>
        !entry.isFile() ||
        !["release.json", value.filename].includes(entry.name)
    )
  ) {
    throw new Error(
      "Release artifact must contain exactly release.json and its candidate tarball"
    );
  }
  const path = join(directory, value.filename);
  const integrity = `sha512-${createHash("sha512").update(readFileSync(path)).digest("base64")}`;
  if (value.integrity !== integrity)
    throw new Error("Release candidate integrity mismatch");
  return { ...value, path };
}

function isolatedNpm(env, operation, { publishing = false } = {}) {
  const directory = mkdtempSync(join(tmpdir(), "tokenomics-npm-"));
  try {
    const childEnv = { ...env };
    for (const key of Object.keys(childEnv)) {
      if (
        /^(NODE_AUTH_TOKEN|NPM_.*TOKEN|GITHUB_TOKEN|GH_TOKEN)$/i.test(key) ||
        /^npm_config_/i.test(key)
      )
        delete childEnv[key];
      if (!publishing && /^ACTIONS_ID_TOKEN_REQUEST_(URL|TOKEN)$/.test(key))
        delete childEnv[key];
    }
    const userconfig = join(directory, "npmrc");
    const globalconfig = join(directory, "global-npmrc");
    const config = `registry=${registry}/\n@neverland-money:registry=${registry}/\n`;
    writeFileSync(userconfig, config, { mode: 0o600 });
    writeFileSync(globalconfig, "", { mode: 0o600 });
    childEnv.NPM_CONFIG_USERCONFIG = userconfig;
    childEnv.NPM_CONFIG_GLOBALCONFIG = globalconfig;
    writeFileSync(join(directory, "package.json"), '{"private":true}\n');
    return operation(directory, childEnv);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

function publishTarball(
  candidate,
  { env = process.env, execFile = execFileSync } = {}
) {
  if (
    !env.ACTIONS_ID_TOKEN_REQUEST_URL ||
    !env.ACTIONS_ID_TOKEN_REQUEST_TOKEN
  ) {
    throw new Error("OIDC is required for automated npm publication");
  }
  return isolatedNpm(
    env,
    (cwd, childEnv) =>
      execFile(
        "npm",
        [
          "publish",
          candidate.path,
          "--ignore-scripts",
          "--access",
          "public",
          "--provenance",
          "--registry",
          registry,
        ],
        { cwd, env: childEnv, stdio: "inherit", timeout: 180_000 }
      ),
    { publishing: true }
  );
}

function verifyInstall(
  candidate,
  { env = process.env, cwd = root, execFile = execFileSync } = {}
) {
  return isolatedNpm(env, (directory, childEnv) => {
    const run = (command, args) =>
      execFile(command, args, {
        cwd: directory,
        env: childEnv,
        stdio: "inherit",
        timeout: 180_000,
      });
    run("npm", [
      "install",
      `${candidate.name}@${candidate.version}`,
      "--omit=dev",
      "--ignore-scripts",
      "--no-audit",
      "--no-fund",
      "--registry",
      registry,
    ]);
    const installed = json(join(directory, "package-lock.json")).packages?.[
      `node_modules/${candidate.name}`
    ];
    if (
      installed?.version !== candidate.version ||
      installed?.integrity !== candidate.integrity
    )
      throw new Error(
        "Registry install differs from the tested candidate integrity"
      );
    run("npm", ["ls", "--omit=dev", "--all"]);
    for (const filename of ["consumer.cjs", "consumer.mjs"]) {
      copyFileSync(
        join(cwd, "test/package", filename),
        join(directory, filename)
      );
      run(process.execPath, [filename]);
    }
  });
}

function createOperations({
  env = process.env,
  cwd = root,
  fetchImpl = fetch,
  execFile = execFileSync,
} = {}) {
  async function request(url, { github = false, method = "GET", body } = {}) {
    const headers = { Accept: "application/json" };
    if (github) {
      headers.Authorization = `Bearer ${env.GITHUB_TOKEN}`;
      headers["X-GitHub-Api-Version"] = "2022-11-28";
    }
    if (body) headers["Content-Type"] = "application/json";
    const response = await fetchImpl(url, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(30_000),
    });
    if (response.status === 404 && method === "GET") return null;
    if (!response.ok) {
      const error = new Error(
        `${github ? "GitHub" : "Registry"} ${method} failed with HTTP ${response.status}`
      );
      error.status = response.status;
      throw error;
    }
    const value = await response.json();
    if (!value || typeof value !== "object" || Array.isArray(value))
      throw new Error("Invalid API metadata response");
    return value;
  }
  const github = (path, options) =>
    request(`https://api.github.com/repos/${repository}${path}`, {
      ...options,
      github: true,
    });
  return {
    getVersion: (name, version) =>
      request(
        `${registry}/${encodeURIComponent(name)}/${encodeURIComponent(version)}`
      ),
    packageExists: async (name) =>
      (await request(`${registry}/${encodeURIComponent(name)}`)) !== null,
    async getTag(tag) {
      const ref = await github(`/git/ref/tags/${encodeURIComponent(tag)}`);
      if (!ref) return null;
      let object = ref.object;
      for (let depth = 0; object?.type === "tag" && depth < 5; depth++) {
        const annotated = await github(`/git/tags/${commitSha(object.sha)}`);
        object = annotated?.object;
      }
      if (object?.type !== "commit")
        throw new Error("Release tag does not resolve to a commit SHA");
      return commitSha(object.sha);
    },
    getRelease: (tag) => github(`/releases/tags/${encodeURIComponent(tag)}`),
    publish: (candidate) => publishTarball(candidate, { env, execFile }),
    verifyInstall: (candidate) =>
      verifyInstall(candidate, { env, cwd, execFile }),
    createTag: (tag, sha) =>
      github("/git/refs", {
        method: "POST",
        body: { ref: `refs/tags/${tag}`, sha },
      }),
    createRelease: (tag, sha) =>
      github("/releases", {
        method: "POST",
        body: {
          tag_name: tag,
          target_commitish: sha,
          name: tag,
          generate_release_notes: true,
          draft: false,
          prerelease: false,
        },
      }),
  };
}

async function checkGitHub(operations, tag, sha) {
  const [existingTag, existingRelease] = await Promise.all([
    operations.getTag(tag),
    operations.getRelease(tag),
  ]);
  if (existingTag && existingTag !== sha)
    throw new Error("Existing release tag points to a different SHA");
  if (existingRelease) {
    if (!existingTag)
      throw new Error("Existing GitHub release has no matching commit tag");
    if (
      existingRelease.tag_name !== tag ||
      typeof existingRelease.target_commitish !== "string"
    )
      throw new Error("Existing GitHub release identity is invalid");
    // A branch in target_commitish can move after release creation; the tag is authoritative.
    if (
      /^[a-f0-9]{40}$/.test(existingRelease.target_commitish) &&
      existingRelease.target_commitish !== sha
    )
      throw new Error("Existing GitHub release targets a different commit SHA");
    if (existingRelease.draft || existingRelease.prerelease)
      throw new Error(
        "Existing GitHub release is not a published stable release"
      );
  }
  return { tag: Boolean(existingTag), release: Boolean(existingRelease) };
}

function checkIntegrity(version, candidate) {
  if (version.dist?.integrity !== candidate.integrity)
    throw new Error(
      "Registry version integrity differs from the tested candidate"
    );
}

async function runRelease({
  artifactDirectory,
  env = process.env,
  cwd = root,
  operations,
  maxAttempts = 6,
  delayMs = 5_000,
  sleep: wait = sleep,
} = {}) {
  if (!mainPush(env))
    throw new Error(
      "Releases require a push to the public repository main branch"
    );
  const sha = commitSha(env.GITHUB_SHA);
  if (!env.GITHUB_TOKEN)
    throw new Error("GITHUB_TOKEN is required for release verification");
  if (!Number.isInteger(maxAttempts) || maxAttempts < 1 || maxAttempts > 12)
    throw new Error("Registry retry count is invalid");
  const candidate = readCandidate(artifactDirectory, cwd, sha);
  const ops = operations || createOperations({ env, cwd });
  const tag = `v${candidate.version}`;
  const existing = await checkGitHub(ops, tag, sha);
  const registered = await ops.getVersion(candidate.name, candidate.version);
  if (registered) checkIntegrity(registered, candidate);
  else {
    if (!(await ops.packageExists(candidate.name))) {
      const artifact =
        /^\d+$/.test(env.GITHUB_RUN_ID || "") &&
        /^\d+$/.test(env.TOKENOMICS_RELEASE_ARTIFACT_ID || "")
          ? `[verified release candidate](https://github.com/${repository}/actions/runs/${env.GITHUB_RUN_ID}/artifacts/${env.TOKENOMICS_RELEASE_ARTIFACT_ID})`
          : "this run's `tokenomics-release-<commit>-<attempt>` artifact";
      const summary = [
        "## Package publication pending",
        "",
        `Status: \`awaiting-first-publication\` for ${candidate.name}@${candidate.version}.`,
        "",
        `Commit: \`${sha}\`.`,
        "",
        `Archive: \`${candidate.filename}\` in ${artifact}.`,
        "",
        `Integrity: \`${candidate.integrity}\`.`,
        "",
        "Package checks passed. This job made no npm, tag, or GitHub release changes.",
        "",
      ].join("\n");
      if (env.GITHUB_STEP_SUMMARY)
        appendFileSync(env.GITHUB_STEP_SUMMARY, summary);
      return {
        name: candidate.name,
        version: candidate.version,
        sha,
        status: "awaiting-first-publication",
        published: false,
      };
    }
    await ops.publish(candidate);
  }
  let visible = false;
  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    const version = await ops.getVersion(candidate.name, candidate.version);
    if (version) {
      checkIntegrity(version, candidate);
      visible = true;
      break;
    }
    if (attempt + 1 < maxAttempts) await wait(delayMs);
  }
  if (!visible)
    throw new Error("Published version did not become visible in the registry");
  await ops.verifyInstall(candidate);
  if (!existing.tag) {
    try {
      await ops.createTag(tag, sha);
    } catch (error) {
      if (![409, 422].includes(error.status) || (await ops.getTag(tag)) !== sha)
        throw error;
    }
  }
  if (!existing.release) {
    try {
      await ops.createRelease(tag, sha);
    } catch (error) {
      if (![409, 422].includes(error.status)) throw error;
      const current = await checkGitHub(ops, tag, sha);
      if (!current.release) throw error;
    }
  }
  return {
    name: candidate.name,
    version: candidate.version,
    sha,
    status: "released",
    published: !registered,
  };
}

async function main() {
  const [command, artifactDirectory, ...extra] = process.argv.slice(2);
  if (command === "plan" && !artifactDirectory)
    console.log(JSON.stringify(planRelease()));
  else if (command === "publish" && artifactDirectory && !extra.length)
    console.log(JSON.stringify(await runRelease({ artifactDirectory })));
  else if (command === "verify" && artifactDirectory && extra.length === 1)
    console.log(
      JSON.stringify(readCandidate(artifactDirectory, root, extra[0]))
    );
  else
    throw new Error(
      "Usage: node tools/release.cjs plan | publish <artifact-directory> | verify <artifact-directory> <commit-sha>"
    );
}

module.exports = {
  createOperations,
  planRelease,
  publishTarball,
  runRelease,
  verifyInstall,
};
if (require.main === module)
  main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
