# Automatic Stable Tagging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically create a stable `v<version>` tag when the version in `ha_opencode/config.yaml` changes on `main`, allowing the existing build and release workflows to publish without a manual release command.

**Architecture:** Keep the existing tag-triggered build and release workflows unchanged. Put the tag decision and idempotent collision handling in a testable shell script, and use a small GitHub Actions workflow to provide the `main`/path trigger, checkout credentials, and issue permissions.

**Tech Stack:** GitHub Actions YAML, Bash, Git, GitHub CLI, Ruby YAML parser for validation.

---

## File Map

- Create `.github/workflows/auto-tag-stable.yml`: Trigger only on `main` pushes that change the stable config; provide `SYNC_TOKEN` checkout and issue permissions; invoke the tag script.
- Create `scripts/auto-tag-stable.sh`: Parse and validate the stable version, compare it with the pre-push commit, inspect the remote tag, create a non-forced tag, and report collisions.
- Create `scripts/test-auto-tag-stable.sh`: Functional test against a temporary bare Git remote plus static workflow contract checks.
- Modify `RELEASING.md`: Replace manual stable tag instructions with the automatic version-change flow and document the new workflow.
- Do not modify `.github/workflows/build.yaml` or `.github/workflows/release.yaml`: Their existing `v*` triggers are the downstream release pipeline.

## Task 1: Add Failing Automatic-Tag Tests

**Files:**
- Create: `scripts/test-auto-tag-stable.sh`
- Test: `scripts/test-auto-tag-stable.sh`

- [ ] **Step 1: Write the failing test harness and workflow contract checks**

Create an executable test that first verifies the workflow contract and then
exercises the tag script in a temporary repository. The test intentionally
references files that do not exist yet, so it must fail before implementation.

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/opencode-auto-tag.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

WORKFLOW="$ROOT/.github/workflows/auto-tag-stable.yml"
SCRIPT="$ROOT/scripts/auto-tag-stable.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local pattern="$1" file="$2"
    grep -Eq "$pattern" "$file" || fail "expected $file to contain: $pattern"
}

assert_not_contains() {
    local pattern="$1" file="$2"
    if grep -Eq "$pattern" "$file"; then
        fail "expected $file not to contain: $pattern"
    fi
}

REMOTE="$WORK/remote.git"
REPO="$WORK/repo"
git init --bare "$REMOTE" >/dev/null
git init "$REPO" >/dev/null
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" remote add origin "$REMOTE"
mkdir -p "$REPO/ha_opencode"

write_version() {
    printf '%s\n' '---' 'version: "'$1'"' > "$REPO/ha_opencode/config.yaml"
}

commit_version() {
    local version="$1" message="$2"
    write_version "$version"
    git -C "$REPO" add ha_opencode/config.yaml
    git -C "$REPO" commit -m "$message" >/dev/null
    git -C "$REPO" push origin HEAD:main >/dev/null
}

run_tag_script() {
    local sha="$1" before="$2"
    (cd "$REPO" && \
        GITHUB_SHA="$sha" \
        GITHUB_EVENT_BEFORE="$before" \
        bash "$SCRIPT")
}

commit_version 1.0.0.1 'test: initial stable version'
first_sha="$(git -C "$REPO" rev-parse HEAD)"
zero_sha=0000000000000000000000000000000000000000
run_tag_script "$first_sha" "$zero_sha"
test "$(git -C "$REPO" ls-remote origin refs/tags/v1.0.0.1 | cut -f1)" = "$first_sha" \
    || fail "new version did not create v1.0.0.1 at the current commit"

# A rerun after a successful tag push is a no-op.
run_tag_script "$first_sha" "$zero_sha"

# A config-only-unrelated commit with the same version does not create a new tag.
printf 'unrelated\n' > "$REPO/README.test"
git -C "$REPO" add README.test
git -C "$REPO" commit -m 'test: unrelated main change' >/dev/null
git -C "$REPO" push origin HEAD:main >/dev/null
unchanged_sha="$(git -C "$REPO" rev-parse HEAD)"
run_tag_script "$unchanged_sha" "$first_sha"

# A new version creates exactly its own tag.
commit_version 1.0.0.2 'test: bump stable version'
second_sha="$(git -C "$REPO" rev-parse HEAD)"
run_tag_script "$second_sha" "$unchanged_sha"
test "$(git -C "$REPO" ls-remote origin refs/tags/v1.0.0.2 | cut -f1)" = "$second_sha" \
    || fail "new version did not create v1.0.0.2 at the current commit"

# A changed version cannot move an existing tag.
git -C "$REPO" tag v1.0.0.3 "$second_sha"
git -C "$REPO" push origin v1.0.0.3 >/dev/null
commit_version 1.0.0.3 'test: collide with existing stable tag'
collision_sha="$(git -C "$REPO" rev-parse HEAD)"
if run_tag_script "$collision_sha" "$second_sha"; then
    fail "existing tag collision unexpectedly succeeded"
fi
test "$(git -C "$REPO" ls-remote origin refs/tags/v1.0.0.3 | cut -f1)" = "$second_sha" \
    || fail "existing tag was moved"

# Invalid versions fail before creating a tag.
commit_version invalid 'test: invalid stable version'
invalid_sha="$(git -C "$REPO" rev-parse HEAD)"
if run_tag_script "$invalid_sha" "$collision_sha"; then
    fail "invalid version unexpectedly succeeded"
fi
test -z "$(git -C "$REPO" ls-remote origin refs/tags/vinvalid)" \
    || fail "invalid version created a tag"

test -x "$SCRIPT" || fail "tag script is not executable"
test -f "$WORKFLOW" || fail "automatic tag workflow is missing"
assert_contains 'branches:[[:space:]]*\[main\]|branches:' "$WORKFLOW"
assert_contains 'ha_opencode/config\.yaml' "$WORKFLOW"
assert_contains 'secrets\.SYNC_TOKEN' "$WORKFLOW"
assert_contains 'scripts/auto-tag-stable\.sh' "$WORKFLOW"
assert_contains 'issues:[[:space:]]*write' "$WORKFLOW"
assert_not_contains 'workflow_dispatch' "$WORKFLOW"
assert_not_contains 'git push[^\n]*--force' "$WORKFLOW"
assert_contains 'GITHUB_EVENT_BEFORE' "$SCRIPT"
assert_contains 'git ls-remote origin' "$SCRIPT"
assert_contains 'git push origin "\$TAG"' "$SCRIPT"

printf 'automatic stable tagging tests passed\n'
```

- [ ] **Step 2: Run the test and verify it fails for the missing implementation**

Run:

```bash
bash scripts/test-auto-tag-stable.sh
```

Expected: FAIL because `.github/workflows/auto-tag-stable.yml` and
`scripts/auto-tag-stable.sh` do not exist yet.

- [ ] **Step 3: Commit the failing test contract**

```bash
chmod +x scripts/test-auto-tag-stable.sh
git add scripts/test-auto-tag-stable.sh
git commit -m "test: specify automatic stable tagging"
```

## Task 2: Implement the Idempotent Tag Script

**Files:**
- Create: `scripts/auto-tag-stable.sh`
- Test: `scripts/test-auto-tag-stable.sh`

- [ ] **Step 1: Add version parsing, pre-push comparison, and tag handling**

Create the executable script below. It uses the checkout's persisted
`SYNC_TOKEN` credential for the tag push and uses `GH_TOKEN` only when it needs
to open a collision issue.

```bash
#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${CONFIG_PATH:-ha_opencode/config.yaml}"
BEFORE="${GITHUB_EVENT_BEFORE:-}"
CURRENT_SHA="${GITHUB_SHA:?GITHUB_SHA is required}"
ZERO_SHA=0000000000000000000000000000000000000000

extract_version() {
    sed -n 's/^version:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

current_version="$(extract_version < "$CONFIG_PATH")"
if [[ ! "$current_version" =~ ^[0-9]+(\.[0-9]+){2,}$ ]]; then
    echo "::error::Invalid stable version: ${current_version:-<empty>}"
    exit 1
fi

previous_version=""
if [[ -n "$BEFORE" && "$BEFORE" != "$ZERO_SHA" ]]; then
    previous_version="$(
        git show "${BEFORE}:${CONFIG_PATH}" 2>/dev/null \
            | extract_version \
            || true
    )"
fi

version_changed=true
if [[ -n "$previous_version" && "$previous_version" == "$current_version" ]]; then
    version_changed=false
fi

TAG="v${current_version}"
remote_sha="$(git ls-remote origin "refs/tags/${TAG}" | awk 'NR == 1 { print $1 }')"

if [[ -z "$remote_sha" ]]; then
    if [[ "$version_changed" != true ]]; then
        echo "Stable version ${current_version} is unchanged and not tagged; no release action taken."
        exit 0
    fi

    git tag "$TAG" "$CURRENT_SHA"
    git push origin "$TAG"
    echo "Created stable release tag ${TAG} at ${CURRENT_SHA}."
    exit 0
fi

# Resolve lightweight or annotated tags to the commit they identify before
# deciding whether this run is a safe rerun or a real collision.
git fetch --no-tags origin "refs/tags/${TAG}:refs/tags/${TAG}" >/dev/null
tag_sha="$(git rev-parse "${TAG}^{commit}")"

if [[ "$tag_sha" == "$CURRENT_SHA" ]]; then
    echo "Stable release tag ${TAG} already points at ${CURRENT_SHA}; no-op."
    exit 0
fi

if [[ "$version_changed" != true ]]; then
    echo "Stable version ${current_version} is unchanged; existing ${TAG} is preserved."
    exit 0
fi

title="Automatic stable tag collision: ${TAG}"
body="Automatic stable tagging found version ${current_version} on commit ${CURRENT_SHA}, but ${TAG} already points to ${tag_sha}. The existing tag was not moved. Bump the stable version or resolve this collision manually."

if [[ -n "${GH_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
    existing="$(gh issue list --state open --search "in:title \"${title}\"" --json number --jq 'length')"
    if [[ "$existing" == 0 ]]; then
        gh issue create --title "$title" --body "$body"
    else
        echo "An open collision issue already exists for ${TAG}."
    fi
else
    echo "::warning::GH_TOKEN or gh is unavailable; no collision issue was opened."
fi

echo "::error::Refusing to move existing ${TAG} from ${tag_sha} to ${CURRENT_SHA}."
exit 1
```

- [ ] **Step 2: Run the functional test and verify it passes**

Run:

```bash
chmod +x scripts/auto-tag-stable.sh
bash scripts/test-auto-tag-stable.sh
```

Expected: the functional scenarios pass through the script, but the test may
still fail its workflow contract checks because the Actions workflow has not
been added yet. The tag-script scenarios must pass before continuing.

- [ ] **Step 3: Commit the tag script**

```bash
git add scripts/auto-tag-stable.sh
git commit -m "feat: add idempotent stable tag script"
```

## Task 3: Add the GitHub Actions Trigger

**Files:**
- Create: `.github/workflows/auto-tag-stable.yml`
- Test: `scripts/test-auto-tag-stable.sh`

- [ ] **Step 1: Add the automatic stable tag workflow**

Create the workflow below. The workflow itself has only read access through the
default token; checkout and tag pushing use `SYNC_TOKEN`. The default token's
issue permission is used only for collision reporting.

```yaml
---
name: Auto-tag Stable

on:
  push:
    branches:
      - main
    paths:
      - ha_opencode/config.yaml

permissions:
  contents: read
  issues: write

concurrency:
  group: auto-tag-stable
  cancel-in-progress: false

jobs:
  auto-tag:
    name: Create stable release tag
    runs-on: ubuntu-latest
    steps:
      - name: Detect sync token
        env:
          SYNC_TOKEN: ${{ secrets.SYNC_TOKEN }}
        run: |
          if [ -z "$SYNC_TOKEN" ]; then
            echo "::error::SYNC_TOKEN is required to create release tags that trigger downstream workflows."
            exit 1
          fi

      - name: Checkout repository
        uses: actions/checkout@v6
        with:
          fetch-depth: 0
          persist-credentials: true
          token: ${{ secrets.SYNC_TOKEN }}

      - name: Create stable release tag when the version changes
        env:
          GITHUB_EVENT_BEFORE: ${{ github.event.before }}
          GITHUB_SHA: ${{ github.sha }}
          GH_TOKEN: ${{ github.token }}
        run: bash scripts/auto-tag-stable.sh
```

- [ ] **Step 2: Run the complete contract test**

Run:

```bash
bash scripts/test-auto-tag-stable.sh
```

Expected: PASS, including workflow trigger, secret, no-force-push, version
comparison, new-tag, rerun, unchanged-version, collision, and invalid-version
checks.

- [ ] **Step 3: Validate all workflow YAML and shell syntax**

Run:

```bash
bash -n scripts/auto-tag-stable.sh scripts/test-auto-tag-stable.sh scripts/test-upstream-sync.sh
ruby -e 'require "yaml"; Dir[".github/workflows/*.{yml,yaml}"].sort.each { |path| YAML.load_file(path); puts "parsed #{path}" }'
git diff --check
```

Expected: all shell checks exit zero, every workflow parses, and `git diff --check`
prints no errors.

- [ ] **Step 4: Commit the workflow**

```bash
git add .github/workflows/auto-tag-stable.yml
git commit -m "feat: automate stable release tags"
```

## Task 4: Update Release Documentation

**Files:**
- Modify: `RELEASING.md:44-85,106-116`
- Test: `RELEASING.md` review plus existing workflow tests

- [ ] **Step 1: Replace manual stable tag commands**

Update the stable release example so it explicitly changes
`ha_opencode/config.yaml` to the new version, commits that change, and pushes
`main`. Remove the manual `git tag v... && git push origin v...` line. Explain
that `auto-tag-stable.yml` creates the tag automatically and the existing
`build.yaml`/`release.yaml` workflows then publish the image and release.

The stable example should communicate this flow:

```text
edit ha_opencode/ and ha_opencode/config.yaml version
git commit -am "fix: the thing"
git push origin main
# Actions creates v<version>, builds GHCR images, and creates the Release.
```

Leave beta's manual `beta-v*` tag process unchanged because beta automation is
outside this feature's scope.

- [ ] **Step 2: Update the CI table**

Add this row before the existing stable build row:

```text
| `auto-tag-stable.yml` | push to `main` changing `ha_opencode/config.yaml` | Creates `v<version>` with `SYNC_TOKEN`; the tag starts the stable pipeline |
```

Change the section heading/text from “Tagging is the trigger for everything” to
explain that a stable version change creates the tag and the tag triggers the
existing build/release workflows.

- [ ] **Step 3: Check documentation consistency**

Run:

```bash
grep -n "git tag v\|auto-tag-stable\|Tagging is the trigger\|version change" RELEASING.md
```

Expected: stable instructions no longer require a manual `git tag v...` command,
the automatic workflow is documented, and beta instructions still contain the
manual `beta-v*` flow.

- [ ] **Step 4: Commit the documentation**

```bash
git add RELEASING.md
git commit -m "docs: document automatic stable releases"
```

## Task 5: Final Verification and Handoff

**Files:**
- Verify: `.github/workflows/auto-tag-stable.yml`
- Verify: `scripts/auto-tag-stable.sh`
- Verify: `scripts/test-auto-tag-stable.sh`
- Verify: `scripts/test-upstream-sync.sh`
- Verify: `scripts/test-channel-separation.sh`
- Verify: `RELEASING.md`

- [ ] **Step 1: Run the focused and existing regression checks**

Run:

```bash
bash scripts/test-auto-tag-stable.sh
bash scripts/test-upstream-sync.sh
bash scripts/test-channel-separation.sh
bash -n scripts/auto-tag-stable.sh scripts/test-auto-tag-stable.sh
ruby -e 'require "yaml"; Dir[".github/workflows/*.{yml,yaml}"].each { |path| YAML.load_file(path) }'
git diff --check
```

Expected: every command exits zero.

- [ ] **Step 2: Verify only intended files changed**

Run:

```bash
git status --short
git show --stat --oneline HEAD
git show --stat --oneline HEAD~1
git show --stat --oneline HEAD~2
```

Expected: the feature commits contain only the automatic tag workflow, tag
script, tag test, and `RELEASING.md`; the existing stable tag and release
workflows are unchanged. Any known design/plan documentation files are reviewed
separately rather than mistaken for implementation changes.

- [ ] **Step 3: Push the automation to `main`**

After the checks pass, push the implementation commits:

```bash
git push origin main
```

The push itself does not create a release unless it changes
`ha_opencode/config.yaml`'s version. The next stable version change on `main`
will create the tag automatically, and the existing stable build/release
workflows will publish it.

## Plan Self-Review

- The spec's trigger requirement is covered by Task 3's `main` branch and
  `ha_opencode/config.yaml` path filters.
- Version validation and pre-push comparison are covered by Task 2's script and
  Task 1's functional scenarios.
- New tag creation, reruns, unchanged versions, collisions, and no tag movement
  are covered by Task 1's temporary bare-remote tests.
- `SYNC_TOKEN` use and issue permissions are covered by Task 3's workflow and
  static contract checks.
- Existing stable build/release workflows remain unchanged and are verified in
  Task 5.
- Beta behavior is explicitly preserved in Task 4 and is not touched by any
  implementation task.
