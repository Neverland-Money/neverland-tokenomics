const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");

const workflow = readFileSync(
  join(__dirname, "../../.github/workflows/test.yml"),
  "utf8"
);
const jobs = Object.fromEntries(
  [
    ...workflow.matchAll(
      /^  ([a-z][a-z-]*):\n([\s\S]*?)(?=^  [a-z][a-z-]*:|$(?![\s\S]))/gm
    ),
  ]
    .filter(([, , body]) => body.includes("runs-on:"))
    .map(([, name, body]) => [name, body])
);
const permissions = (job) =>
  job.match(/^    permissions:\n((?:      [^\n]+\n)+)/m)?.[1];

test("only the protected npm publisher can request OIDC; only finalization can write GitHub", () => {
  assert.deepEqual(Object.keys(jobs), [
    "check",
    "publish",
    "registry-check",
    "finalize",
  ]);
  assert.equal(
    permissions(jobs.publish),
    "      contents: read\n      id-token: write\n"
  );
  assert.equal(permissions(jobs["registry-check"]), "      contents: read\n");
  assert.equal(permissions(jobs.finalize), "      contents: write\n");
  assert.match(jobs.publish, /^    environment: npm$/m);
  assert.doesNotMatch(
    jobs["registry-check"],
    /secrets\.|GITHUB_TOKEN|ACTIONS_ID_TOKEN/
  );
  for (const condition of [
    "github.event_name == 'push'",
    "github.event_name == 'workflow_dispatch'",
    "github.ref == 'refs/heads/main'",
    "github.repository == 'Neverland-Money/neverland-tokenomics'",
    "needs.check.outputs.release_requested == 'true'",
  ])
    assert(jobs.publish.includes(condition), condition);
  assert.match(jobs.publish, /run: node tools\/release\.cjs publish /);
  assert.doesNotMatch(jobs.publish, /release\.cjs (registry-check|finalize) /);
  assert.match(
    jobs["registry-check"],
    /run: node tools\/release\.cjs registry-check /
  );
  assert.match(jobs.finalize, /run: node tools\/release\.cjs finalize /);
  assert.doesNotMatch(
    jobs.finalize,
    /npm |yarn |consumer\.(cjs|mjs)|registry-check "/
  );
});

test("all release jobs consume the same immutable artifact and finalization waits for consumers", () => {
  assert.match(jobs["registry-check"], /^    needs: \[check, publish\]$/m);
  assert.match(
    jobs["registry-check"],
    /^    if: needs\.publish\.outputs\.release_ready == 'true'$/m
  );
  assert.match(jobs.finalize, /^    needs: \[check, registry-check\]$/m);
  assert.doesNotMatch(jobs.finalize, /always\(\)|continue-on-error/);
  for (const name of ["publish", "registry-check", "finalize"]) {
    assert.match(
      jobs[name],
      /artifact-ids: \$\{\{ needs\.check\.outputs\.artifact_id \}\}/
    );
    assert.match(jobs[name], /digest-mismatch: error/);
  }
  for (const line of workflow
    .split("\n")
    .filter((line) => line.includes("uses:")))
    assert.match(line, /@[a-f0-9]{40}(?:\s|$)/);
  assert.equal((workflow.match(/persist-credentials: false/g) || []).length, 4);
  assert.doesNotMatch(workflow, /persist-credentials: true/);
});

test("main push and recovery dispatch share a queued pipeline and preserve candidates for 30 days", () => {
  assert.match(
    workflow,
    /on:\n  push:\n    branches: \[main\]\n  pull_request:\n  workflow_dispatch:/
  );
  const concurrency = workflow.match(
    /^concurrency:\n([\s\S]*?)\n\njobs:/m
  )?.[1];
  assert.equal(
    concurrency,
    "  group: tokenomics-ci-${{ github.ref }}\n  cancel-in-progress: false\n  queue: max"
  );
  assert.match(jobs.check, /retention-days: 30/);
});

test("build and package checks inherit only read access and cannot request OIDC", () => {
  assert.equal(
    workflow.match(/^permissions:\n((?:  [^\n]+\n)+)/m)?.[1],
    "  contents: read\n"
  );
  if (/^    permissions:/m.test(jobs.check))
    assert.equal(permissions(jobs.check), "      contents: read\n");
});
