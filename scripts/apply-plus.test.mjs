import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("..", import.meta.url));

const BEGIN_MARK = "<!-- opencode-plus overlay: begin -->";
const END_MARK = "<!-- opencode-plus overlay: end -->";

// A synthetic "upstream took the file" changelog: no fork entry, no markers.
const UPSTREAM_CHANGELOG = `# Changelog
All notable changes to this project will be documented in this file.

## [Unreleased]

## 2.5.6

- Fixed screenshot authentication and now report login, navigation, or frontend-readiness failures instead of successful dashboard captures (#121).
- Devcontainer builds now tolerate Windows line endings in build metadata.

## 2.5.5

- **Quit OpenCode from the browser terminal (#113)** — added a compact top-right quit button.
`;

const UPSTREAM_GITIGNORE = `# Dependencies (installed during Docker build)
node_modules/

# Build artifacts
*.tgz

# Local maintainer guidance and implementation plans
/AGENTS.md
/plans/
`;

function quote(path) {
  return JSON.stringify(path);
}

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), "apply-plus-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  execFileSync("bash", [
    "-c",
    `cd ${quote(repoRoot)} && tar \
      --exclude=./.git --exclude=.git \
      --exclude=./.worktrees --exclude=.worktrees \
      --exclude=./node_modules --exclude=node_modules \
      --exclude='*.plusbak' \
      -cf - . | tar -xf - -C ${quote(root)}`,
  ]);
  // Reset the files upstream owns to their upstream form, as the sync
  // workflow's conflict resolution (git checkout --theirs) would leave them.
  writeFileSync(join(root, "ha_opencode/CHANGELOG.md"), UPSTREAM_CHANGELOG);
  writeFileSync(join(root, ".gitignore"), UPSTREAM_GITIGNORE);
  const configPath = join(root, "ha_opencode/config.yaml");
  writeFileSync(
    configPath,
    readFileSync(configPath, "utf8").replace(/^version:.*$/m, 'version: "2.5.6"'),
  );
  return root;
}

function runApplyPlus(root) {
  execFileSync("bash", [join(root, "scripts/apply-plus.sh")], { cwd: root });
}

function occurrences(haystack, needle) {
  return haystack.split(needle).length - 1;
}

function headingCount(markdown, title) {
  const escaped = title.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return (markdown.match(new RegExp(`^## ${escaped}$`, "gm")) || []).length;
}

test("re-injects fork changelog entries and ignores after an upstream takeover", () => {
  const root = fixture(test);
  runApplyPlus(root);

  const changelog = readFileSync(join(root, "ha_opencode/CHANGELOG.md"), "utf8");
  const gitignore = readFileSync(join(root, ".gitignore"), "utf8");
  const config = readFileSync(join(root, "ha_opencode/config.yaml"), "utf8");

  // Fork entry restored from the fragment, exactly once.
  assert.equal(headingCount(changelog, "2.5.5.2"), 1);
  assert.match(changelog, /Fix add-on crash loop on port 8099/);
  // Marked block sits between [Unreleased] and the first upstream heading.
  assert.equal(occurrences(changelog, BEGIN_MARK), 1);
  assert.equal(occurrences(changelog, END_MARK), 1);
  const unreleased = changelog.indexOf("## [Unreleased]");
  const begin = changelog.indexOf(BEGIN_MARK);
  const end = changelog.indexOf(END_MARK);
  const upstream260 = changelog.indexOf("## 2.5.6");
  assert.ok(unreleased < begin && begin < end && end < upstream260, "block is out of order");
  // Upstream sections are untouched.
  assert.equal(headingCount(changelog, "2.5.6"), 1);
  assert.equal(headingCount(changelog, "2.5.5"), 1);

  // Fork ignore rules restored.
  assert.match(gitignore, /^\.worktrees\/$/m);
  // Upstream ignore rules kept.
  assert.match(gitignore, /^\/AGENTS\.md$/m);

  // Overlay version suffix applied on the upstream three-part version.
  assert.match(config, /^version: "2\.5\.6\.1"$/m);
});

test("idempotent: a second run changes nothing", () => {
  const root = fixture(test);
  runApplyPlus(root);

  const paths = ["ha_opencode/CHANGELOG.md", ".gitignore", "ha_opencode/config.yaml"];
  const before = Object.fromEntries(
    paths.map((p) => [p, readFileSync(join(root, p), "utf8")]),
  );

  runApplyPlus(root);

  for (const p of paths) {
    assert.equal(readFileSync(join(root, p), "utf8"), before[p], `${p} changed on re-run`);
  }
});

test("new fragment entries flow into the marked block on the next run", () => {
  const root = fixture(test);
  runApplyPlus(root);

  const fragmentPath = join(root, "ha_opencode/CHANGELOG-PLUS.md");
  const fragment = readFileSync(fragmentPath, "utf8");
  writeFileSync(
    fragmentPath,
    `## 2.5.6.2

- **New overlay fix (test)** — verifies fragment updates reach the changelog.

${fragment}`,
  );
  runApplyPlus(root);

  const changelog = readFileSync(join(root, "ha_opencode/CHANGELOG.md"), "utf8");
  assert.equal(headingCount(changelog, "2.5.6.2"), 1);
  assert.equal(headingCount(changelog, "2.5.5.2"), 1);
  assert.ok(changelog.indexOf("## 2.5.6.2") < changelog.indexOf("## 2.5.5.2"));
  assert.equal(occurrences(changelog, BEGIN_MARK), 1);
});
