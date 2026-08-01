#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/opencode-auto-tag.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

WORKFLOW="$ROOT/.github/workflows/auto-tag-stable.yml"
SCRIPT="$ROOT/scripts/auto-tag-stable.sh"
FORCE_PUSH='git[[:space:]]+push.*[[:space:]](--force-with-lease|--force|-f)([[:space:]=]|$)'

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local pattern="$1" file="$2"
    grep -Eq "$pattern" "$file" || fail "expected $file to contain: $pattern"
}

normalize_shell_commands() {
    tr '\n' ' ' | sed -E 's/\\[[:space:]]+/ /g; s/[[:space:]]+/ /g'
}

assert_no_force_push() {
    local file="$1" contents="$2"
    if printf '%s\n' "$contents" | normalize_shell_commands | grep -Eq "$FORCE_PUSH"; then
        fail "expected $file not to contain a force-push command"
    fi
}

if [ ! -f "$SCRIPT" ]; then
    fail "tag helper is missing: $SCRIPT (Task 2 must add it before functional checks)"
fi

REMOTE="$WORK/remote.git"
REPO="$WORK/repo"
FAKE_BIN="$WORK/fake-bin"
ISSUE_LOG="$WORK/gh-issues.log"
git init --bare "$REMOTE" >/dev/null
git init "$REPO" >/dev/null
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" remote add origin "$REMOTE"
mkdir -p "$REPO/ha_opencode"

write_version() {
    local version="$1"
    printf '%s\n' '---' "version: \"$version\"" > "$REPO/ha_opencode/config.yaml"
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

run_collision_tag_script() {
    local sha="$1" before="$2"
    (cd "$REPO" && \
        PATH="$FAKE_BIN:$PATH" \
        GH_TOKEN=test-token \
        GH_ISSUE_LOG="$ISSUE_LOG" \
        GITHUB_SHA="$sha" \
        GITHUB_EVENT_BEFORE="$before" \
        bash "$SCRIPT")
}

setup_fake_gh() {
    mkdir -p "$FAKE_BIN"
    : > "$ISSUE_LOG"
    cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log="${GH_ISSUE_LOG:?GH_ISSUE_LOG is required}"
case "${1:-} ${2:-}" in
    "issue list")
        if [ -s "$log" ]; then
            printf '1\n'
        else
            printf '0\n'
        fi
        ;;
    "issue create")
        printf 'create\n' >> "$log"
        ;;
    *)
        printf 'unexpected gh invocation: %s\n' "$*" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$FAKE_BIN/gh"
}

remote_tag_list() {
    git -C "$REPO" ls-remote --tags origin | sort
}

remote_tag_count() {
    remote_tag_list | wc -l | tr -d ' '
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
new_version_tags_before="$(remote_tag_list)"
commit_version 1.0.0.2 'test: bump stable version'
second_sha="$(git -C "$REPO" rev-parse HEAD)"
run_tag_script "$second_sha" "$unchanged_sha"
new_version_tag="$(git -C "$REPO" ls-remote origin refs/tags/v1.0.0.2)"
test "$(printf '%s' "$new_version_tag" | cut -f1)" = "$second_sha" \
    || fail "new version did not create v1.0.0.2 at the current commit"
new_version_tags_after="$(remote_tag_list)"
expected_new_version_tags="$(printf '%s\n%s' "$new_version_tags_before" "$new_version_tag" | sort)"
test "$new_version_tags_after" = "$expected_new_version_tags" \
    || fail "new version changed the remote tags beyond v1.0.0.2"

# A valid three-component version is accepted too.
commit_version 1.2.3 'test: accept three-component stable version'
third_sha="$(git -C "$REPO" rev-parse HEAD)"
run_tag_script "$third_sha" "$second_sha"
test "$(git -C "$REPO" ls-remote origin refs/tags/v1.2.3 | cut -f1)" = "$third_sha" \
    || fail "three-component version did not create v1.2.3 at the current commit"

# A changed version cannot move an existing tag.
git -C "$REPO" tag v1.0.0.3 "$second_sha"
git -C "$REPO" push origin v1.0.0.3 >/dev/null
setup_fake_gh
commit_version 1.0.0.3 'test: collide with existing stable tag'
collision_sha="$(git -C "$REPO" rev-parse HEAD)"
if run_collision_tag_script "$collision_sha" "$third_sha"; then
    fail "existing tag collision unexpectedly succeeded"
fi
test "$(wc -l < "$ISSUE_LOG" | tr -d ' ')" = "1" \
    || fail "first collision did not create exactly one issue"
if run_collision_tag_script "$collision_sha" "$third_sha"; then
    fail "repeated existing tag collision unexpectedly succeeded"
fi
test "$(wc -l < "$ISSUE_LOG" | tr -d ' ')" = "1" \
    || fail "repeated collision created a duplicate issue"
test "$(git -C "$REPO" ls-remote origin refs/tags/v1.0.0.3 | cut -f1)" = "$second_sha" \
    || fail "existing tag was moved"

# Malformed versions fail without changing local or remote tags.
assert_invalid_version() {
    local version="$1" message="$2" before="$3"
    commit_version "$version" "$message"
    local invalid_sha="$(git -C "$REPO" rev-parse HEAD)"
    local local_tags_before="$(git -C "$REPO" tag --list)"
    local remote_tags_before="$(remote_tag_list)"
    if run_tag_script "$invalid_sha" "$before"; then
        fail "invalid version ${version} unexpectedly succeeded"
    fi
    local local_tags_after="$(git -C "$REPO" tag --list)"
    local remote_tags_after="$(remote_tag_list)"
    test "$local_tags_after" = "$local_tags_before" \
        || fail "invalid version ${version} changed the local tag list"
    test "$remote_tags_after" = "$remote_tags_before" \
        || fail "invalid version ${version} changed the remote tag list"
    test -z "$(git -C "$REPO" ls-remote origin "refs/tags/v${version}")" \
        || fail "invalid version ${version} created a tag"
    INVALID_SHA="$invalid_sha"
}

assert_invalid_version 1.0 'test: reject two-component stable version' "$collision_sha"
assert_invalid_version 1.0.foo 'test: reject non-numeric stable version' "$INVALID_SHA"

test -x "$SCRIPT" || fail "tag script is not executable"
test -f "$WORKFLOW" || fail "automatic tag workflow is missing"
if ! workflow_shell_commands="$(
    ruby - "$WORKFLOW" <<'RUBY'
require 'yaml'

path = ARGV.fetch(0)
doc = YAML.load_file(path)
abort 'workflow YAML root must be a mapping' unless doc.is_a?(Hash)

trigger = doc['on'] || doc[true]
abort 'workflow must define an on trigger' unless trigger.is_a?(Hash)
push = trigger['push']
abort 'workflow must define on.push' unless push.is_a?(Hash)
abort 'on.push.branches must be exactly [main]' unless push['branches'] == ['main']
abort 'on.push.paths must be exactly [ha_opencode/config.yaml]' unless push['paths'] == ['ha_opencode/config.yaml']
abort 'workflow must not define workflow_dispatch' if trigger.key?('workflow_dispatch')
permissions = doc['permissions']
abort 'workflow must grant issues: write' unless permissions.is_a?(Hash) && permissions['issues'] == 'write'

def collect_hashes(value, hashes)
  case value
  when Hash
    hashes << value
    value.each_value { |child| collect_hashes(child, hashes) }
  when Array
    value.each { |child| collect_hashes(child, hashes) }
  end
end

hashes = []
collect_hashes(doc, hashes)
checkout_steps = hashes.select { |hash| hash['uses'] == 'actions/checkout@v6' }
abort 'workflow must contain exactly one actions/checkout@v6 step' unless checkout_steps.length == 1
checkout_with = checkout_steps.first['with']
checkout_token = checkout_with.is_a?(Hash) ? checkout_with['token'] : nil
abort 'actions/checkout@v6 must use SYNC_TOKEN' unless checkout_token == '${{ secrets.SYNC_TOKEN }}'

run_steps = hashes.select { |hash| hash['run'].is_a?(String) }
helper_runs = run_steps.count { |step| step['run'] == 'bash scripts/auto-tag-stable.sh' }
abort 'workflow must contain exactly one helper invocation step' unless helper_runs == 1

run_steps.each { |step| puts step['run'] }
RUBY
)"; then
    fail "workflow YAML contract assertion failed"
fi
assert_no_force_push "$WORKFLOW" "$workflow_shell_commands"

assert_contains 'GITHUB_EVENT_BEFORE' "$SCRIPT"
assert_contains 'git ls-remote origin' "$SCRIPT"
assert_contains '^[[:space:]]*git[[:space:]]+push[[:space:]]+origin[[:space:]]+"\$TAG"[[:space:]]*$' "$SCRIPT"
helper_shell_commands="$(<"$SCRIPT")"
assert_no_force_push "$SCRIPT" "$helper_shell_commands"

printf 'automatic stable tagging tests passed\n'
