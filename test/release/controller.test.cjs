const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const { createHash } = require("node:crypto");
const {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");
const {
  createOperations,
  planRelease,
  publishTarball,
  runRelease,
  verifyInstall,
} = require("../../tools/release.cjs");

const sha = "a".repeat(40);
const previousSha = "b".repeat(40);
const name = "@neverland-money/tokenomics-core";
const environment = (changes = {}) => ({
  GITHUB_REPOSITORY: "Neverland-Money/neverland-tokenomics",
  GITHUB_EVENT_NAME: "push",
  GITHUB_REF: "refs/heads/main",
  GITHUB_SHA: sha,
  GITHUB_EVENT_BEFORE: previousSha,
  GITHUB_TOKEN: "github-secret",
  ...changes,
});

function fixture(t, version = "1.2.0") {
  const directory = mkdtempSync(join(tmpdir(), "tokenomics-release-test-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  writeFileSync(
    join(directory, "package.json"),
    JSON.stringify({ name, version })
  );
  return directory;
}

function candidate(t) {
  const cwd = fixture(t);
  const artifactDirectory = fixture(t);
  rmSync(join(artifactDirectory, "package.json"));
  const filename = "neverland-money-tokenomics-core-1.2.0.tgz";
  const bytes = Buffer.from("the exact consumer-tested candidate");
  const integrity = `sha512-${createHash("sha512").update(bytes).digest("base64")}`;
  const metadata = { name, version: "1.2.0", filename, integrity, sha };
  writeFileSync(join(artifactDirectory, filename), bytes);
  writeFileSync(
    join(artifactDirectory, "release.json"),
    JSON.stringify(metadata)
  );
  return { cwd, artifactDirectory, ...metadata };
}

function operations(candidate, changes = {}) {
  const events = [];
  let published = false;
  return {
    events,
    async getTag() {
      events.push("read-tag");
      return null;
    },
    async getRelease() {
      events.push("read-release");
      return null;
    },
    async getVersion() {
      events.push("read-version");
      return published ? { dist: { integrity: candidate.integrity } } : null;
    },
    async packageExists() {
      events.push("read-package");
      return true;
    },
    async publish(value) {
      events.push("publish");
      assert.equal(value.integrity, candidate.integrity);
      published = true;
    },
    async verifyInstall() {
      events.push("install");
    },
    async createTag(tag, target) {
      events.push("create-tag");
      assert.equal(tag, "v1.2.0");
      assert.equal(target, sha);
    },
    async createRelease(tag, target) {
      events.push("create-release");
      assert.equal(tag, "v1.2.0");
      assert.equal(target, sha);
    },
    async resolveCommit() {
      throw new Error("unexpected commit resolution");
    },
    ...changes,
  };
}

test("plan requests only an explicit stable version increase and writes GitHub outputs", (t) => {
  const cwd = fixture(t);
  const output = join(cwd, "outputs");
  let gitArgs;
  const result = planRelease({
    cwd,
    env: environment({ GITHUB_OUTPUT: output }),
    execFile(command, args) {
      assert.equal(command, "git");
      gitArgs = args;
      return JSON.stringify({ name, version: "1.1.9" });
    },
  });
  assert.deepEqual(result, { release_requested: true, version: "1.2.0" });
  assert.deepEqual(gitArgs, ["show", `${previousSha}:package.json`]);
  assert.equal(
    readFileSync(output, "utf8"),
    "release_requested=true\nversion=1.2.0\n"
  );
});

test("plan skips an unchanged version", (t) => {
  const cwd = fixture(t);
  assert.equal(
    planRelease({
      cwd,
      env: environment(),
      execFile: () => JSON.stringify({ name, version: "1.2.0" }),
    }).release_requested,
    false
  );
});

test("plan recognizes only the reviewed first public package rename", (t) => {
  const cwd = fixture(t);
  assert.equal(
    planRelease({
      cwd,
      env: environment(),
      execFile: () =>
        JSON.stringify({ name: "neverland-contracts", version: "1.1.0" }),
    }).release_requested,
    true
  );
  for (const previous of [
    { name: "other-package", version: "1.1.0" },
    { name: "neverland-contracts", version: "1.0.0" },
  ])
    assert.throws(
      () =>
        planRelease({
          cwd,
          env: environment(),
          execFile: () => JSON.stringify(previous),
        }),
      /name/i
    );
  assert.throws(
    () =>
      planRelease({
        cwd: fixture(t, "1.3.0"),
        env: environment(),
        execFile: () =>
          JSON.stringify({ name: "neverland-contracts", version: "1.1.0" }),
      }),
    /name/i
  );
});

test("plan cannot release a pull request, another branch, or a repository fork", (t) => {
  const cwd = fixture(t);
  for (const changes of [
    { GITHUB_EVENT_NAME: "pull_request" },
    { GITHUB_EVENT_NAME: "workflow_dispatch" },
    { GITHUB_REF: "refs/heads/feature" },
    { GITHUB_REPOSITORY: "someone/neverland-tokenomics" },
  ]) {
    assert.equal(
      planRelease({
        cwd,
        env: environment(changes),
        execFile() {
          assert.fail("must not read git");
        },
      }).release_requested,
      false
    );
  }
});

test("plan rejects downgrades, prereleases, leading zeroes, and unsafe before revisions", (t) => {
  for (const version of [
    "1.1.0",
    "1.2.1-rc.1",
    "01.2.1",
    "1.2",
    "1.2.1+build",
  ]) {
    const cwd = fixture(t, version);
    assert.throws(() =>
      planRelease({
        cwd,
        env: environment(),
        execFile: () => JSON.stringify({ name, version: "1.2.0" }),
      })
    );
  }
  const cwd = fixture(t);
  for (const before of [
    "--output=/tmp/x",
    "HEAD",
    "0".repeat(40),
    "a".repeat(40) + ":other",
  ]) {
    assert.throws(() =>
      planRelease({
        cwd,
        env: environment({ GITHUB_EVENT_BEFORE: before }),
        execFile() {
          assert.fail("unsafe revision reached git");
        },
      })
    );
  }
});

test("release validates candidate identity and exact bytes before any remote operation", async (t) => {
  for (const corrupt of [
    (c) =>
      writeFileSync(join(c.artifactDirectory, c.filename), "different bytes"),
    (c) => writeFileSync(join(c.artifactDirectory, "extra.tgz"), "extra"),
    (c) =>
      writeFileSync(
        join(c.artifactDirectory, "release.json"),
        JSON.stringify({ ...c, sha: previousSha })
      ),
    (c) =>
      writeFileSync(
        join(c.cwd, "package.json"),
        JSON.stringify({ name, version: "1.3.0" })
      ),
  ]) {
    const c = candidate(t);
    corrupt(c);
    const ops = operations(c);
    await assert.rejects(
      runRelease({ ...c, env: environment(), operations: ops })
    );
    assert.deepEqual(ops.events, []);
  }
});

test("release rejects unauthorized GitHub contexts before remote operations", async (t) => {
  const c = candidate(t);
  for (const changes of [
    { GITHUB_REF: "refs/heads/other" },
    { GITHUB_TOKEN: "" },
    { GITHUB_SHA: "HEAD" },
  ]) {
    const ops = operations(c);
    await assert.rejects(
      runRelease({ ...c, env: environment(changes), operations: ops })
    );
    assert.deepEqual(ops.events, []);
  }
});

test("release publishes the tested tarball, verifies the registry install, then creates matching GitHub records", async (t) => {
  const c = candidate(t);
  const ops = operations(c);
  const result = await runRelease({
    ...c,
    env: environment(),
    operations: ops,
  });
  assert.equal(result.published, true);
  assert.deepEqual(ops.events, [
    "read-tag",
    "read-release",
    "read-version",
    "read-package",
    "publish",
    "read-version",
    "install",
    "create-tag",
    "create-release",
  ]);
});

test("equal registry integrity and existing matching GitHub records make a rerun safe", async (t) => {
  const c = candidate(t);
  const ops = operations(c, {
    async getTag() {
      return sha;
    },
    async getRelease() {
      return { tag_name: "v1.2.0", target_commitish: sha };
    },
    async getVersion() {
      return { dist: { integrity: c.integrity } };
    },
    async packageExists() {
      assert.fail("existing version does not need package creation detection");
    },
    async publish() {
      assert.fail("must not publish existing bytes");
    },
    async createTag() {
      assert.fail("must not recreate tag");
    },
    async createRelease() {
      assert.fail("must not recreate release");
    },
  });
  assert.equal(
    (await runRelease({ ...c, env: environment(), operations: ops })).published,
    false
  );
  assert.deepEqual(ops.events, ["install"]);
});

test("a conflicting registry integrity cannot be overwritten", async (t) => {
  const c = candidate(t);
  const ops = operations(c, {
    async getVersion() {
      return { dist: { integrity: "sha512-different" } };
    },
  });
  await assert.rejects(
    runRelease({ ...c, env: environment(), operations: ops }),
    /integrity/i
  );
  assert(!ops.events.includes("publish"));
  assert(!ops.events.includes("create-tag"));
});

test("conflicting tags and release commits stop before an npm write", async (t) => {
  for (const changes of [
    {
      async getTag() {
        return previousSha;
      },
    },
    {
      async getTag() {
        return sha;
      },
      async getRelease() {
        return { tag_name: "v1.2.0", target_commitish: previousSha };
      },
    },
  ]) {
    const c = candidate(t);
    const ops = operations(c, changes);
    await assert.rejects(
      runRelease({ ...c, env: environment(), operations: ops }),
      /SHA|commit/i
    );
    assert(!ops.events.includes("publish"));
  }
});

test("a release keeps its actual tag identity when its advisory target branch moves", async (t) => {
  const c = candidate(t);
  const ops = operations(c, {
    async getTag() {
      return sha;
    },
    async getRelease() {
      return { tag_name: "v1.2.0", target_commitish: "main" };
    },
    async getVersion() {
      return { dist: { integrity: c.integrity } };
    },
    async createRelease() {
      assert.fail("matching release already exists");
    },
  });
  assert.equal(
    (await runRelease({ ...c, env: environment(), operations: ops })).published,
    false
  );
});

test("registry visibility retries are bounded and tags wait for a successful install", async (t) => {
  const c = candidate(t);
  let reads = 0;
  let waits = 0;
  const ops = operations(c, {
    async getVersion() {
      return ++reads < 4 ? null : { dist: { integrity: c.integrity } };
    },
  });
  await runRelease({
    ...c,
    env: environment(),
    operations: ops,
    sleep: async () => waits++,
    maxAttempts: 3,
  });
  assert.equal(waits, 2);
  assert(ops.events.indexOf("install") < ops.events.indexOf("create-tag"));
  const neverVisible = operations(c, {
    async getVersion() {
      return null;
    },
  });
  await assert.rejects(
    runRelease({
      ...c,
      env: environment(),
      operations: neverVisible,
      sleep: async () => {},
      maxAttempts: 2,
    }),
    /visible|registry/i
  );
  assert(!neverVisible.events.includes("create-tag"));
  const failedInstall = operations(c, {
    async verifyInstall() {
      throw new Error("consumer failed");
    },
  });
  await assert.rejects(
    runRelease({ ...c, env: environment(), operations: failedInstall }),
    /consumer failed/
  );
  assert(!failedInstall.events.includes("create-tag"));
});

test("a missing package waits for manual publication without npm or GitHub writes", async (t) => {
  const c = candidate(t);
  const summary = join(c.cwd, "summary.md");
  const ops = operations(c, {
    async packageExists() {
      this.events.push("read-package");
      return false;
    },
  });
  const result = await runRelease({
    ...c,
    env: environment({
      GITHUB_STEP_SUMMARY: summary,
      GITHUB_RUN_ID: "123",
      GITHUB_RUN_ATTEMPT: "2",
      TOKENOMICS_RELEASE_ARTIFACT_ID: "456",
    }),
    operations: ops,
  });
  assert.equal(result.status, "awaiting-first-publication");
  assert.equal(result.published, false);
  assert.equal(result.sha, sha);
  assert.deepEqual(ops.events, [
    "read-tag",
    "read-release",
    "read-version",
    "read-package",
  ]);
  const status = readFileSync(summary, "utf8");
  assert(status.includes(sha));
  assert(status.includes(c.filename));
  assert(status.includes(c.integrity));
  assert(status.includes("/actions/runs/123/artifacts/456"));
});

test("rerunning after manual publication verifies the exact version before creating GitHub records", async (t) => {
  const c = candidate(t);
  const ops = operations(c, {
    async getVersion() {
      this.events.push("read-version");
      return { dist: { integrity: c.integrity } };
    },
    async packageExists() {
      assert.fail("the manually published version already exists");
    },
    async publish() {
      assert.fail("the manually published archive must not be republished");
    },
  });
  const result = await runRelease({
    ...c,
    env: environment(),
    operations: ops,
  });
  assert.equal(result.status, "released");
  assert.equal(result.published, false);
  assert.deepEqual(ops.events, [
    "read-tag",
    "read-release",
    "read-version",
    "read-version",
    "install",
    "create-tag",
    "create-release",
  ]);
});

test("local archive verification accepts the tested identity and rejects changed bytes or SHA", (t) => {
  const c = candidate(t);
  const script = join(c.cwd, "tools/release.cjs");
  mkdirSync(join(c.cwd, "tools"));
  copyFileSync(join(__dirname, "../../tools/release.cjs"), script);
  const verify = (target = sha) =>
    execFileSync(
      process.execPath,
      [script, "verify", c.artifactDirectory, target],
      { encoding: "utf8", stdio: "pipe" }
    );
  assert.equal(JSON.parse(verify()).integrity, c.integrity);
  assert.throws(() => verify(previousSha), /SHA/);
  assert.throws(() => verify("main"), /commit SHA/);
  writeFileSync(join(c.artifactDirectory, c.filename), "changed archive");
  assert.throws(() => verify(), /integrity/);
});

test("registry 404 is absence, while auth failures, server errors, and bad JSON are failures", async () => {
  for (const status of [401, 403, 429, 500]) {
    const ops = createOperations({
      env: environment(),
      fetchImpl: async () => new Response("failure", { status }),
    });
    await assert.rejects(
      ops.getVersion(name, "1.2.0"),
      new RegExp(String(status))
    );
    await assert.rejects(ops.packageExists(name), new RegExp(String(status)));
  }
  const absent = createOperations({
    env: environment(),
    fetchImpl: async () => new Response("missing", { status: 404 }),
  });
  assert.equal(await absent.getVersion(name, "1.2.0"), null);
  assert.equal(await absent.packageExists(name), false);
  const invalid = createOperations({
    env: environment(),
    fetchImpl: async () => new Response("not JSON"),
  });
  await assert.rejects(invalid.getVersion(name, "1.2.0"));
  const nullMetadata = createOperations({
    env: environment(),
    fetchImpl: async () => Response.json(null),
  });
  await assert.rejects(nullMetadata.getVersion(name, "1.2.0"));
  await assert.rejects(nullMetadata.packageExists(name));
});

test("concurrent matching tag and release creation is safe to retry", async (t) => {
  const c = candidate(t);
  let tagExists = false;
  let releaseExists = false;
  const ops = operations(c, {
    async getTag() {
      return tagExists ? sha : null;
    },
    async getRelease() {
      return releaseExists
        ? { tag_name: "v1.2.0", target_commitish: sha }
        : null;
    },
    async createTag() {
      tagExists = true;
      throw Object.assign(new Error("already exists"), { status: 422 });
    },
    async createRelease() {
      releaseExists = true;
      throw Object.assign(new Error("already exists"), { status: 422 });
    },
  });
  await runRelease({ ...c, env: environment(), operations: ops });
  assert(tagExists && releaseExists);
});

test("a failed npm publication cannot create a GitHub release", async (t) => {
  const c = candidate(t);
  const ops = operations(c, {
    async publish() {
      throw new Error("npm failed");
    },
  });
  await assert.rejects(
    runRelease({ ...c, env: environment(), operations: ops }),
    /npm failed/
  );
  assert(!ops.events.includes("create-tag"));
  assert(!ops.events.includes("create-release"));
});

test("GitHub API resolves annotated tags and sends structured release data on the same SHA", async () => {
  const requests = [];
  const ops = createOperations({
    env: environment(),
    fetchImpl: async (url, options) => {
      requests.push({ url, options });
      if (url.includes("/git/ref/"))
        return Response.json({ object: { type: "tag", sha: previousSha } });
      if (url.includes("/git/tags/"))
        return Response.json({ object: { type: "commit", sha } });
      return Response.json({});
    },
  });
  assert.equal(await ops.getTag("v1.2.0"), sha);
  await ops.createTag("v1.2.0", sha);
  await ops.createRelease("v1.2.0", sha);
  assert.equal(
    requests[0].options.headers.Authorization,
    "Bearer github-secret"
  );
  assert.deepEqual(JSON.parse(requests[2].options.body), {
    ref: "refs/tags/v1.2.0",
    sha,
  });
  assert.equal(JSON.parse(requests[3].options.body).target_commitish, sha);
});

test("OIDC publication strips token credentials and uses only the exact tarball without lifecycle scripts", (t) => {
  const c = candidate(t);
  let npmrc;
  publishTarball(
    { ...c, path: join(c.artifactDirectory, c.filename) },
    {
      env: environment({
        NODE_AUTH_TOKEN: "node-secret",
        NPM_TOKEN: "npm-secret",
        NPM_OTHER_TOKEN: "other-secret",
        NPM_ID_TOKEN: "wrong-oidc-token",
        ACTIONS_ID_TOKEN_REQUEST_URL: "https://oidc.example",
        ACTIONS_ID_TOKEN_REQUEST_TOKEN: "oidc-secret",
        NPM_CONFIG_USERCONFIG: "/bad/npmrc",
      }),
      execFile(command, args, options) {
        assert.equal(command, "npm");
        assert.deepEqual(args, [
          "publish",
          join(c.artifactDirectory, c.filename),
          "--ignore-scripts",
          "--access",
          "public",
          "--provenance",
          "--registry",
          "https://registry.npmjs.org",
        ]);
        for (const key of [
          "NODE_AUTH_TOKEN",
          "NPM_TOKEN",
          "NPM_OTHER_TOKEN",
          "NPM_ID_TOKEN",
          "GITHUB_TOKEN",
        ])
          assert.equal(options.env[key], undefined);
        assert.equal(options.env.ACTIONS_ID_TOKEN_REQUEST_TOKEN, "oidc-secret");
        npmrc = options.env.NPM_CONFIG_USERCONFIG;
        assert(!readFileSync(npmrc, "utf8").includes("secret"));
        assert.notEqual(options.cwd, c.cwd);
      },
    }
  );
  assert(!existsSync(npmrc));
});

test("publication requires OIDC and cleans isolated configuration after failure", (t) => {
  const c = candidate(t);
  let npmrc;
  assert.throws(
    () =>
      publishTarball(
        { ...c, path: join(c.artifactDirectory, c.filename) },
        {
          env: environment({
            NODE_AUTH_TOKEN: "wrong-secret",
            ACTIONS_ID_TOKEN_REQUEST_URL: "https://oidc.example",
            ACTIONS_ID_TOKEN_REQUEST_TOKEN: "oidc-secret",
          }),
          execFile(command, args, options) {
            npmrc = options.env.NPM_CONFIG_USERCONFIG;
            assert(!readFileSync(npmrc, "utf8").includes("_authToken"));
            assert(!args.some((value) => value.includes("secret")));
            assert.equal(options.env.NODE_AUTH_TOKEN, undefined);
            throw new Error("publication failed");
          },
        }
      ),
    /publication failed/
  );
  assert(!existsSync(npmrc));
  assert.throws(
    () => publishTarball(c, { env: environment({ NPM_TOKEN: "npm-secret" }) }),
    /OIDC/i
  );
});

test("registry consumer verification installs the exact version, checks lock integrity, and executes both consumers", (t) => {
  const c = candidate(t);
  const commands = [];
  let installDirectory;
  verifyInstall(c, {
    cwd: process.cwd(),
    env: environment({
      NODE_AUTH_TOKEN: "never-use-this",
      NPM_ID_TOKEN: "wrong-oidc-token",
      ACTIONS_ID_TOKEN_REQUEST_URL: "https://oidc.example",
      ACTIONS_ID_TOKEN_REQUEST_TOKEN: "oidc-secret",
    }),
    execFile(command, args, options) {
      commands.push([command, args]);
      installDirectory = options.cwd;
      assert.equal(options.env.NODE_AUTH_TOKEN, undefined);
      assert.equal(options.env.NPM_ID_TOKEN, undefined);
      assert.equal(options.env.ACTIONS_ID_TOKEN_REQUEST_URL, undefined);
      assert.equal(options.env.ACTIONS_ID_TOKEN_REQUEST_TOKEN, undefined);
      if (args[0] === "install") {
        assert(args.includes(`${name}@1.2.0`));
        assert(args.includes("--omit=dev"));
        assert(args.includes("--ignore-scripts"));
        writeFileSync(
          join(options.cwd, "package-lock.json"),
          JSON.stringify({
            packages: {
              [`node_modules/${name}`]: {
                version: "1.2.0",
                integrity: c.integrity,
              },
            },
          })
        );
      }
      if (command === process.execPath)
        assert(existsSync(join(options.cwd, args[0])));
      return "";
    },
  });
  assert.deepEqual(
    commands.map(([command, args]) => (command === "npm" ? args[0] : args[0])),
    ["install", "ls", "consumer.cjs", "consumer.mjs"]
  );
  assert(!existsSync(installDirectory));
});
