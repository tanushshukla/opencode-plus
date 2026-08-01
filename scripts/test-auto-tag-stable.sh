#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/opencode-auto-tag.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

WORKFLOW="$ROOT/.github/workflows/auto-tag-stable.yml"
SCRIPT="$ROOT/scripts/auto-tag-stable.sh"
CHECKOUT_BLOCK="$WORK/checkout-block.yml"
FORCE_PUSH='git[[:space:]]+push.*[[:space:]](--force-with-lease|--force|-f)([[:space:]=]|$)'

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

assert_followed_by() {
    local anchor="$1" expected="$2" file="$3"
    grep -A1 -E "$anchor" "$file" | grep -Eq "$expected" \
        || fail "expected $file to have $expected immediately after $anchor"
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

remote_tag_count() {
    git -C "$REPO" ls-remote --tags origin | wc -l | tr -d ' '
}

commit_version 1.0.0.1 'test: initial stable version'
first_sha="$(git -C "$REPO" rev-parse HEAD)"
zero_sha=0000000000000000000000000000000000000000
run_tag_script "$first_sha" "$zero_sha"
test "$(git -C "$REPO" ls-remote origin refs/tags/v1.0.0.1 | cut -f1)" = "$first_sha" \
    || fail "new version did not create v1.0.0.1 at the current commit"

# A rerun after a successful tag push is a no-op.
run_tag_script "$first_sha" "$zero_sha"
test "$(git -C "$REPO" ls-remote origin refs/tags/v1.0.0.1 | cut -f1)" = "$first_sha" \
    || fail "rerun changed the v1.0.0.1 tag"
test "$(remote_tag_count)" = "1" \
    || fail "rerun created an extra remote tag"

# A config-only-unrelated commit with the same version does not create a new tag.
printf 'unrelated\n' > "$REPO/README.test"
git -C "$REPO" add README.test
git -C "$REPO" commit -m 'test: unrelated main change' >/dev/null
git -C "$REPO" push origin HEAD:main >/dev/null
unchanged_sha="$(git -C "$REPO" rev-parse HEAD)"
run_tag_script "$unchanged_sha" "$first_sha"
test "$(git -C "$REPO" ls-remote origin refs/tags/v1.0.0.1 | cut -f1)" = "$first_sha" \
    || fail "unchanged version changed the v1.0.0.1 tag"
test "$(remote_tag_count)" = "1" \
    || fail "unchanged version created an extra remote tag"

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
invalid_tags_before="$(git -C "$REPO" tag --list)"
invalid_remote_tags_before="$(git -C "$REPO" ls-remote --tags origin | sort)"
if run_tag_script "$invalid_sha" "$collision_sha"; then
    fail "invalid version unexpectedly succeeded"
fi
invalid_tags_after="$(git -C "$REPO" tag --list)"
invalid_remote_tags_after="$(git -C "$REPO" ls-remote --tags origin | sort)"
test "$invalid_tags_after" = "$invalid_tags_before" \
    || fail "invalid version changed the local tag list"
test "$invalid_remote_tags_after" = "$invalid_remote_tags_before" \
    || fail "invalid version changed the remote tag list"
test -z "$(git -C "$REPO" ls-remote origin refs/tags/vinvalid)" \
    || fail "invalid version created a tag"

test -x "$SCRIPT" || fail "tag script is not executable"
test -f "$WORKFLOW" || fail "automatic tag workflow is missing"
assert_followed_by '^[[:space:]]*branches:[[:space:]]*$' '^[[:space:]]*-[[:space:]]+main[[:space:]]*$' "$WORKFLOW"
assert_followed_by '^[[:space:]]*paths:[[:space:]]*$' '^[[:space:]]*-[[:space:]]+ha_opencode/config\.yaml[[:space:]]*$' "$WORKFLOW"
assert_contains '^[[:space:]]*run:[[:space:]]*bash[[:space:]]+scripts/auto-tag-stable\.sh[[:space:]]*$' "$WORKFLOW"
assert_contains 'issues:[[:space:]]*write' "$WORKFLOW"
assert_not_contains 'workflow_dispatch' "$WORKFLOW"
assert_not_contains "$FORCE_PUSH" "$WORKFLOW"
assert_contains 'GITHUB_EVENT_BEFORE' "$SCRIPT"
assert_contains 'git ls-remote origin' "$SCRIPT"
assert_contains '^[[:space:]]*git[[:space:]]+push[[:space:]]+origin[[:space:]]+"\$TAG"[[:space:]]*$' "$SCRIPT"
assert_not_contains "$FORCE_PUSH" "$SCRIPT"

awk '
    /uses:[[:space:]]*actions\/checkout@v6[[:space:]]*$/ { in_checkout=1 }
    in_checkout && /^[[:space:]]*-[[:space:]]+/ { exit }
    in_checkout { print }
' "$WORKFLOW" > "$CHECKOUT_BLOCK"
test -s "$CHECKOUT_BLOCK" || fail "actions/checkout@v6 block is missing"
assert_contains '^[[:space:]]*uses:[[:space:]]*actions\/checkout@v6[[:space:]]*$' "$CHECKOUT_BLOCK"
assert_contains '^[[:space:]]*token:[[:space:]]*\$\{\{ secrets\.SYNC_TOKEN \}\}[[:space:]]*$' "$CHECKOUT_BLOCK"

printf 'automatic stable tagging tests passed\n'
