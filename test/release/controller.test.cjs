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
    { GITHUB_REF: "refs/heads/feature" },
    {
      GITHUB_EVENT_NAME: "workflow_dispatch",
      GITHUB_REF: "refs/heads/feature",
    },
    {
      GITHUB_EVENT_NAME: "workflow_dispatch",
      GITHUB_REPOSITORY: "someone/neverland-tokenomics",
    },
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
    let gitCalled = false;
    assert.throws(
      () =>
        planRelease({
          cwd,
          env: environment({ GITHUB_EVENT_BEFORE: before }),
          execFile() {
            gitCalled = true;
            return JSON.stringify({ name, version: "1.1.0" });
          },
        }),
      /full, nonzero Git commit SHA/
    );
    assert.equal(gitCalled, false);
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
    { GITHUB_EVENT_NAME: "pull_request" },
    { GITHUB_REPOSITORY: "someone/neverland-tokenomics" },
    { GITHUB_EVENT_NAME: "workflow_dispatch", GITHUB_REF: "refs/heads/other" },
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

test("main dispatch requests recovery even without a version change, without reading before SHA", (t) => {
  const cwd = fixture(t);
  const result = planRelease({
    cwd,
    env: environment({
      GITHUB_EVENT_NAME: "workflow_dispatch",
      GITHUB_EVENT_BEFORE: undefined,
    }),
    execFile() {
      assert.fail("dispatch has no before commit");
    },
  });
  assert.equal(result.release_requested, true);
});

test("publish phase never executes consumers or creates GitHub records", async (t) => {
  const c = candidate(t);
  const ops = operations(c);
  const output = join(c.cwd, "output");
  const result = await runRelease({
    ...c,
    phase: "publish",
    env: environment({ GITHUB_OUTPUT: output }),
    operations: ops,
  });
  assert.equal(result.status, "published");
  assert.equal(result.published, true);
  assert.deepEqual(ops.events, [
    "read-tag",
    "read-release",
    "read-version",
    "read-package",
    "publish",
    "read-version",
  ]);
  assert.equal(readFileSync(output, "utf8"), "release_ready=true\n");
});

test("registry phase verifies consumers without publishing or creating GitHub records", async (t) => {
  const c = candidate(t);
  const ops = operations(c, {
    async getVersion() {
      return { dist: { integrity: c.integrity } };
    },
  });
  const result = await runRelease({
    ...c,
    phase: "registry-check",
    env: environment(),
    operations: ops,
  });
  assert.equal(result.status, "verified");
  assert.deepEqual(ops.events, ["read-tag", "read-release", "install"]);
});

test("finalize phase creates matching GitHub records without executing package code", async (t) => {
  const c = candidate(t);
  const ops = operations(c, {
    async getVersion() {
      return { dist: { integrity: c.integrity } };
    },
  });
  const result = await runRelease({
    ...c,
    phase: "finalize",
    env: environment(),
    operations: ops,
  });
  assert.equal(result.status, "released");
  assert.deepEqual(ops.events, [
    "read-tag",
    "read-release",
    "create-tag",
    "create-release",
  ]);
});

test("unknown phases and OIDC credentials outside publication fail before remote operations", async (t) => {
  const c = candidate(t);
  for (const [phase, changes] of [
    ["all", {}],
    ["registry-check", { ACTIONS_ID_TOKEN_REQUEST_TOKEN: "unexpected" }],
    ["finalize", { ACTIONS_ID_TOKEN_REQUEST_URL: "https://oidc.example" }],
  ]) {
    const ops = operations(c);
    await assert.rejects(
      runRelease({ ...c, phase, env: environment(changes), operations: ops }),
      /phase|OIDC/
    );
    assert.deepEqual(ops.events, []);
  }
});

test("matching registry and GitHub identities make every phase safe to rerun", async (t) => {
  const c = candidate(t);
  for (const phase of ["publish", "registry-check", "finalize"]) {
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
    });
    await runRelease({ ...c, phase, env: environment(), operations: ops });
    assert.deepEqual(ops.events, phase === "registry-check" ? ["install"] : []);
  }
});

test("all phases reject mismatched registry integrity and missing versions outside publication", async (t) => {
  const c = candidate(t);
  for (const phase of ["publish", "registry-check", "finalize"]) {
    const ops = operations(c, {
      async getVersion() {
        return { dist: { integrity: "sha512-different" } };
      },
    });
    await assert.rejects(
      runRelease({ ...c, phase, env: environment(), operations: ops }),
      /integrity/
    );
    assert(
      !ops.events.some((event) =>
        ["publish", "install", "create-tag", "create-release"].includes(event)
      )
    );
  }
  for (const phase of ["registry-check", "finalize"]) {
    const ops = operations(c);
    await assert.rejects(
      runRelease({ ...c, phase, env: environment(), operations: ops }),
      /not.*registry|absent|missing/i
    );
    assert.deepEqual(ops.events, ["read-tag", "read-release", "read-version"]);
  }
});

test("conflicting tags, targets, draft/prerelease, and releases without tags fail before publication", async (t) => {
  const c = candidate(t);
  const release = { tag_name: "v1.2.0", target_commitish: sha };
  for (const [tag, record, expected] of [
    [previousSha, null, /SHA/],
    [sha, { ...release, target_commitish: previousSha }, /commit SHA/],
    [sha, { ...release, draft: true }, /published stable/],
    [sha, { ...release, prerelease: true }, /published stable/],
    [null, release, /no matching commit tag/],
    [sha, { ...release, tag_name: "v9.9.9" }, /identity/],
    [sha, { ...release, target_commitish: null }, /identity/],
  ]) {
    const ops = operations(c, {
      async getTag() {
        return tag;
      },
      async getRelease() {
        return record;
      },
    });
    await assert.rejects(
      runRelease({ ...c, env: environment(), operations: ops }),
      expected
    );
    assert.deepEqual(ops.events, []);
  }
});

test("an advisory target branch may move while the authoritative tag matches", async (t) => {
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
  });
  assert.equal(
    (
      await runRelease({
        ...c,
        phase: "finalize",
        env: environment(),
        operations: ops,
      })
    ).status,
    "released"
  );
  assert.deepEqual(ops.events, []);
});

test("publication visibility retries are bounded and integrity checked after publication", async (t) => {
  const c = candidate(t);
  let reads = 0,
    waits = 0;
  const ops = operations(c, {
    async getVersion() {
      return ++reads < 4 ? null : { dist: { integrity: c.integrity } };
    },
  });
  await runRelease({
    ...c,
    env: environment(),
    operations: ops,
    maxAttempts: 3,
    sleep: async () => waits++,
  });
  assert.equal(waits, 2);
  for (const answer of [null, { dist: { integrity: "sha512-wrong" } }]) {
    let reads = 0;
    const ops = operations(c, {
      async getVersion() {
        return ++reads === 1 ? null : answer;
      },
    });
    await assert.rejects(
      runRelease({
        ...c,
        env: environment(),
        operations: ops,
        maxAttempts: 2,
        sleep: async () => {},
      }),
      /registry|integrity/
    );
    assert(!ops.events.includes("create-tag"));
  }
});

test("a missing first package waits and explains exact archive publication and recovery", async (t) => {
  const c = candidate(t);
  const summary = join(c.cwd, "summary.md");
  const output = join(c.cwd, "output");
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
      GITHUB_OUTPUT: output,
      GITHUB_RUN_ID: "123",
      TOKENOMICS_RELEASE_ARTIFACT_ID: "456",
    }),
    operations: ops,
  });
  assert.equal(result.status, "awaiting-first-publication");
  assert.equal(result.published, false);
  assert.deepEqual(ops.events, [
    "read-tag",
    "read-release",
    "read-version",
    "read-package",
  ]);
  const text = readFileSync(summary, "utf8");
  for (const value of [
    sha,
    c.filename,
    c.integrity,
    "/actions/runs/123/artifacts/456",
    "node tools/release.cjs verify",
    "npm publish",
    "--ignore-scripts",
    "exact",
    "30 days",
    "rerun",
    "environment",
    "direct publishing",
    "stage-only",
    "main",
  ])
    assert(text.includes(value), value);
  assert(!existsSync(output));
});

test("failed registry consumers cannot produce a successful verification result", async (t) => {
  const c = candidate(t);
  const ops = operations(c, {
    async getVersion() {
      return { dist: { integrity: c.integrity } };
    },
    async verifyInstall() {
      throw new Error("consumer failed");
    },
  });
  await assert.rejects(
    runRelease({
      ...c,
      phase: "registry-check",
      env: environment(),
      operations: ops,
    }),
    /consumer failed/
  );
  assert(!ops.events.includes("create-tag"));
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

test("concurrent tag creation accepts only a rechecked matching commit", async (t) => {
  const c = candidate(t);
  for (const status of [409, 422])
    for (const concurrent of [sha, previousSha, null]) {
      let reads = 0;
      const ops = operations(c, {
        async getVersion() {
          return { dist: { integrity: c.integrity } };
        },
        async getTag() {
          return ++reads === 1 ? null : concurrent;
        },
        async createTag() {
          throw Object.assign(new Error("concurrent tag"), { status });
        },
      });
      const result = runRelease({
        ...c,
        phase: "finalize",
        env: environment(),
        operations: ops,
      });
      if (concurrent === sha) await result;
      else await assert.rejects(result, /concurrent tag/);
      assert.equal(reads, 2);
      assert.equal(ops.events.includes("create-release"), concurrent === sha);
    }
});

test("concurrent release creation rechecks identity, publication status, and presence", async (t) => {
  const c = candidate(t);
  for (const status of [409, 422])
    for (const record of [
      null,
      { tag_name: "v1.2.0", target_commitish: previousSha },
      { tag_name: "v1.2.0", target_commitish: sha, draft: true },
      { tag_name: "v1.2.0", target_commitish: sha },
    ]) {
      let reads = 0;
      const ops = operations(c, {
        async getVersion() {
          return { dist: { integrity: c.integrity } };
        },
        async getTag() {
          return sha;
        },
        async getRelease() {
          return ++reads === 1 ? null : record;
        },
        async createRelease() {
          throw Object.assign(new Error("concurrent release"), { status });
        },
      });
      const result = runRelease({
        ...c,
        phase: "finalize",
        env: environment(),
        operations: ops,
      });
      if (record?.target_commitish === sha && !record.draft) await result;
      else
        await assert.rejects(
          result,
          /concurrent release|commit SHA|published stable/
        );
      assert.equal(reads, 2);
    }
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

test("registry lock integrity or version mismatches fail before executing any installed code", (t) => {
  const c = candidate(t);
  for (const installed of [
    undefined,
    { version: "1.2.0", integrity: "sha512-wrong" },
    { version: "1.3.0", integrity: c.integrity },
  ]) {
    const commands = [];
    assert.throws(
      () =>
        verifyInstall(c, {
          env: environment(),
          execFile(command, args, options) {
            commands.push(args[0]);
            if (args[0] === "install")
              writeFileSync(
                join(options.cwd, "package-lock.json"),
                JSON.stringify({
                  packages: { [`node_modules/${name}`]: installed },
                })
              );
          },
        }),
      /tested candidate integrity/
    );
    assert.deepEqual(commands, ["install"]);
  }
});

test("registry gitHead, when present, must match the same full candidate SHA in every phase", async (t) => {
  const c = candidate(t);
  for (const phase of ["publish", "registry-check", "finalize"])
    for (const gitHead of [previousSha, "main", "0".repeat(40), sha]) {
      const ops = operations(c, {
        async getVersion() {
          return { gitHead, dist: { integrity: c.integrity } };
        },
      });
      const result = runRelease({
        ...c,
        phase,
        env: environment(),
        operations: ops,
      });
      if (gitHead === sha) await result;
      else {
        await assert.rejects(result, /gitHead|commit SHA/);
        assert(
          !ops.events.some((value) =>
            ["publish", "install", "create-tag", "create-release"].includes(
              value
            )
          )
        );
      }
    }
});

test("registry consumers require no GitHub token and public metadata sends no authorization", async (t) => {
  const c = candidate(t);
  const ops = operations(c, {
    async getVersion() {
      return { dist: { integrity: c.integrity } };
    },
  });
  assert.equal(
    (
      await runRelease({
        ...c,
        phase: "registry-check",
        env: environment({ GITHUB_TOKEN: undefined }),
        operations: ops,
      })
    ).status,
    "verified"
  );
  const publicOps = createOperations({
    env: environment({ GITHUB_TOKEN: undefined }),
    fetchImpl: async (url, options) => {
      assert.equal(options.headers.Authorization, undefined);
      return new Response("missing", { status: 404 });
    },
  });
  assert.equal(await publicOps.getTag("v1.2.0"), null);
});
