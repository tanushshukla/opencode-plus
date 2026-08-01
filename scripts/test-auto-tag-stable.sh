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
