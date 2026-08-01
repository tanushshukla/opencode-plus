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

REMOTE="$WORK/remote.git"
REPO="$WORK/repo"
FAKE_BIN="$WORK/fake-bin"
ISSUE_LOG="$WORK/gh-issues.log"
FAKE_ERROR_LOG="$WORK/gh-errors.log"
GIT_PUSH_LOG="$WORK/git-push-guard.log"

if ! REAL_GIT="$(command -v git)"; then
    fail "could not locate the real git executable before installing the test wrapper"
fi

setup_git_guard() {
    mkdir -p "$FAKE_BIN"
    : > "$GIT_PUSH_LOG"
    cat > "$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

real_git="${REAL_GIT:?REAL_GIT is required}"
log="${GIT_PUSH_LOG:?GIT_PUSH_LOG is required}"
seen_push=false

reject_force_push() {
    printf 'rejected force push: %s\n' "$*" >> "$log"
    printf 'FAIL: runtime git wrapper rejected force push: %s\n' "$*" >&2
    exit 1
}

for arg in "$@"; do
    if [ "$arg" = "push" ]; then
        seen_push=true
        continue
    fi
    if [ "$seen_push" = true ]; then
        case "$arg" in
            -f|--force|--force-with-lease|-f=*|--force=*|--force-with-lease=*)
                reject_force_push "$@"
                ;;
            -[!-]*)
                case "$arg" in
                    *f*) reject_force_push "$@" ;;
                esac
                ;;
        esac
    fi
done

exec "$real_git" "$@"
EOF
    chmod +x "$FAKE_BIN/git"
}

setup_git_guard

assert_force_push_rejected() {
    local option="$1"
    : > "$GIT_PUSH_LOG"
    if PATH="$FAKE_BIN:$PATH" \
        REAL_GIT="$REAL_GIT" \
        GIT_PUSH_LOG="$GIT_PUSH_LOG" \
        "$FAKE_BIN/git" push origin "$option" 2> "$WORK/force-option-error.log"; then
        fail "runtime git guard accepted force option ${option}"
    fi
    test -s "$GIT_PUSH_LOG" || fail "runtime git guard did not record force option ${option}"
}

for force_option in -f -fn -vf --force --force-with-lease; do
    assert_force_push_rejected "$force_option"
done

if [ ! -f "$SCRIPT" ]; then
    fail "tag helper is missing: $SCRIPT (Task 2 must add it before functional checks)"
fi

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
        PATH="$FAKE_BIN:$PATH" \
        REAL_GIT="$REAL_GIT" \
        GIT_PUSH_LOG="$GIT_PUSH_LOG" \
        GITHUB_SHA="$sha" \
        GITHUB_EVENT_BEFORE="$before" \
        bash "$SCRIPT")
}

run_collision_tag_script() {
    local sha="$1" before="$2"
    (cd "$REPO" && \
        PATH="$FAKE_BIN:$PATH" \
        REAL_GIT="$REAL_GIT" \
        GIT_PUSH_LOG="$GIT_PUSH_LOG" \
        GH_TOKEN=test-token \
        GH_ISSUE_LOG="$ISSUE_LOG" \
        GH_FAKE_ERROR_LOG="$FAKE_ERROR_LOG" \
        EXPECTED_ISSUE_TITLE="$EXPECTED_ISSUE_TITLE" \
        EXPECTED_ISSUE_BODY="$EXPECTED_ISSUE_BODY" \
        GITHUB_SHA="$sha" \
        GITHUB_EVENT_BEFORE="$before" \
        bash "$SCRIPT")
}

setup_fake_gh() {
    mkdir -p "$FAKE_BIN"
    : > "$ISSUE_LOG"
    : > "$FAKE_ERROR_LOG"
    cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log="${GH_ISSUE_LOG:?GH_ISSUE_LOG is required}"
error_log="${GH_FAKE_ERROR_LOG:?GH_FAKE_ERROR_LOG is required}"
title="${EXPECTED_ISSUE_TITLE:?EXPECTED_ISSUE_TITLE is required}"
body="${EXPECTED_ISSUE_BODY:?EXPECTED_ISSUE_BODY is required}"

reject() {
    printf '%s\n' "$*" > "$error_log"
    printf 'fake gh validation failed: %s\n' "$*" >&2
    exit 1
}

expected_search="in:title \"$title\""
if [ "${1:-}" = issue ] && [ "${2:-}" = list ]; then
    expected=(issue list --state open --search "$expected_search" --json number --jq length)
    actual=("$@")
    [ "$#" -eq "${#expected[@]}" ] || reject "unexpected issue list argument count"
    for index in "${!expected[@]}"; do
        [ "${actual[$index]}" = "${expected[$index]}" ] || reject "unexpected issue list argument at index ${index}"
    done
    if [ -s "$log" ]; then
        printf '1\n'
    else
        printf '0\n'
    fi
elif [ "${1:-}" = issue ] && [ "${2:-}" = create ]; then
    expected=(issue create --title "$title" --body "$body")
    actual=("$@")
    [ "$#" -eq "${#expected[@]}" ] || reject "unexpected issue create argument count"
    for index in "${!expected[@]}"; do
        [ "${actual[$index]}" = "${expected[$index]}" ] || reject "unexpected issue create argument at index ${index}"
    done
    printf 'create\n' >> "$log"
else
    reject "unexpected gh invocation: $*"
fi
EOF
    chmod +x "$FAKE_BIN/gh"
}

remote_ref_record() {
    git -C "$REPO" ls-remote origin "$1"
}

remote_tag_inventory() {
    local listing
    if ! listing="$(git -C "$REPO" ls-remote --tags origin)"; then
        return 1
    fi
    if ! printf '%s\n' "$listing" | sort; then
        return 1
    fi
}

commit_version 1.0.0.1 'test: initial stable version'
first_sha="$(git -C "$REPO" rev-parse HEAD)"
zero_sha=0000000000000000000000000000000000000000
run_tag_script "$first_sha" "$zero_sha"
if ! first_tag_record="$(remote_ref_record refs/tags/v1.0.0.1)"; then
    fail "could not inspect the v1.0.0.1 remote tag"
fi
test "$(printf '%s' "$first_tag_record" | cut -f1)" = "$first_sha" \
    || fail "new version did not create v1.0.0.1 at the current commit"
if ! first_remote_tags="$(remote_tag_inventory)"; then
    fail "could not snapshot remote tags after creating v1.0.0.1"
fi

# A rerun after a successful tag push is a no-op.
run_tag_script "$first_sha" "$zero_sha"
if ! rerun_tag_record="$(remote_ref_record refs/tags/v1.0.0.1)"; then
    fail "could not inspect the v1.0.0.1 remote tag after rerun"
fi
test "$(printf '%s' "$rerun_tag_record" | cut -f1)" = "$first_sha" \
    || fail "rerun changed the v1.0.0.1 tag"
if ! rerun_remote_tags="$(remote_tag_inventory)"; then
    fail "could not snapshot remote tags after rerun"
fi
test "$rerun_remote_tags" = "$first_remote_tags" \
    || fail "rerun created an extra remote tag"

# A config-only-unrelated commit with the same version does not create a new tag.
printf 'unrelated\n' > "$REPO/README.test"
git -C "$REPO" add README.test
git -C "$REPO" commit -m 'test: unrelated main change' >/dev/null
git -C "$REPO" push origin HEAD:main >/dev/null
unchanged_sha="$(git -C "$REPO" rev-parse HEAD)"
run_tag_script "$unchanged_sha" "$first_sha"
if ! unchanged_tag_record="$(remote_ref_record refs/tags/v1.0.0.1)"; then
    fail "could not inspect the v1.0.0.1 remote tag after unchanged-version run"
fi
test "$(printf '%s' "$unchanged_tag_record" | cut -f1)" = "$first_sha" \
    || fail "unchanged version changed the v1.0.0.1 tag"
if ! unchanged_remote_tags="$(remote_tag_inventory)"; then
    fail "could not snapshot remote tags after unchanged-version run"
fi
test "$unchanged_remote_tags" = "$first_remote_tags" \
    || fail "unchanged version created an extra remote tag"

# A new version creates exactly its own tag.
if ! new_version_tags_before="$(remote_tag_inventory)"; then
    fail "could not snapshot remote tags before v1.0.0.2"
fi
commit_version 1.0.0.2 'test: bump stable version'
second_sha="$(git -C "$REPO" rev-parse HEAD)"
run_tag_script "$second_sha" "$unchanged_sha"
if ! new_version_tag="$(remote_ref_record refs/tags/v1.0.0.2)"; then
    fail "could not inspect the v1.0.0.2 remote tag"
fi
test "$(printf '%s' "$new_version_tag" | cut -f1)" = "$second_sha" \
    || fail "new version did not create v1.0.0.2 at the current commit"
if ! new_version_tags_after="$(remote_tag_inventory)"; then
    fail "could not snapshot remote tags after v1.0.0.2"
fi
expected_new_version_tags="$(printf '%s\n%s' "$new_version_tags_before" "$new_version_tag" | sort)"
test "$new_version_tags_after" = "$expected_new_version_tags" \
    || fail "new version changed the remote tags beyond v1.0.0.2"

# A valid three-component version is accepted too.
valid_version_local_tags_before="$(git -C "$REPO" tag --list)"
if ! valid_version_remote_tags_before="$(remote_tag_inventory)"; then
    fail "could not snapshot remote tags before v1.2.3"
fi
commit_version 1.2.3 'test: accept three-component stable version'
third_sha="$(git -C "$REPO" rev-parse HEAD)"
run_tag_script "$third_sha" "$second_sha"
if ! valid_version_tag="$(remote_ref_record refs/tags/v1.2.3)"; then
    fail "could not inspect the v1.2.3 remote tag"
fi
test "$(printf '%s' "$valid_version_tag" | cut -f1)" = "$third_sha" \
    || fail "three-component version did not create v1.2.3 at the current commit"
valid_version_local_tags_after="$(git -C "$REPO" tag --list)"
if ! valid_version_remote_tags_after="$(remote_tag_inventory)"; then
    fail "could not snapshot remote tags after v1.2.3"
fi
expected_valid_version_local_tags="$(printf '%s\nv1.2.3' "$valid_version_local_tags_before" | sort)"
expected_valid_version_remote_tags="$(printf '%s\n%s' "$valid_version_remote_tags_before" "$valid_version_tag" | sort)"
test "$valid_version_local_tags_after" = "$expected_valid_version_local_tags" \
    || fail "three-component version changed local tags beyond v1.2.3"
test "$valid_version_remote_tags_after" = "$expected_valid_version_remote_tags" \
    || fail "three-component version changed remote tags beyond v1.2.3"

# A changed version cannot move an existing tag.
git -C "$REPO" tag v1.0.0.3 "$second_sha"
git -C "$REPO" push origin v1.0.0.3 >/dev/null
setup_fake_gh
commit_version 1.0.0.3 'test: collide with existing stable tag'
collision_sha="$(git -C "$REPO" rev-parse HEAD)"
EXPECTED_ISSUE_TITLE='Automatic stable tag collision: v1.0.0.3'
EXPECTED_ISSUE_BODY="Automatic stable tagging found version 1.0.0.3 on commit ${collision_sha}, but v1.0.0.3 already points to ${second_sha}. The existing tag was not moved. Bump the stable version or resolve this collision manually."
collision_local_tags_before="$(git -C "$REPO" tag --list)"
if ! collision_remote_tags_before="$(remote_tag_inventory)"; then
    fail "could not snapshot remote tags before collision"
fi
if run_collision_tag_script "$collision_sha" "$third_sha"; then
    fail "existing tag collision unexpectedly succeeded"
fi
test ! -s "$FAKE_ERROR_LOG" || fail "fake gh rejected the collision issue-list request"
test ! -s "$GIT_PUSH_LOG" || fail "runtime git guard rejected a force push during collision"
test "$(wc -l < "$ISSUE_LOG" | tr -d ' ')" = "1" \
    || fail "first collision did not create exactly one issue"
collision_local_tags_after_first="$(git -C "$REPO" tag --list)"
if ! collision_remote_tags_after_first="$(remote_tag_inventory)"; then
    fail "could not snapshot remote tags after first collision"
fi
test "$collision_local_tags_after_first" = "$collision_local_tags_before" \
    || fail "first collision changed the local tag inventory"
test "$collision_remote_tags_after_first" = "$collision_remote_tags_before" \
    || fail "first collision changed the remote tag inventory"
if run_collision_tag_script "$collision_sha" "$third_sha"; then
    fail "repeated existing tag collision unexpectedly succeeded"
fi
test ! -s "$FAKE_ERROR_LOG" || fail "fake gh rejected the repeated collision issue-list request"
test ! -s "$GIT_PUSH_LOG" || fail "runtime git guard rejected a force push during repeated collision"
test "$(wc -l < "$ISSUE_LOG" | tr -d ' ')" = "1" \
    || fail "repeated collision created a duplicate issue"
collision_local_tags_after_second="$(git -C "$REPO" tag --list)"
if ! collision_remote_tags_after_second="$(remote_tag_inventory)"; then
    fail "could not snapshot remote tags after repeated collision"
fi
test "$collision_local_tags_after_second" = "$collision_local_tags_before" \
    || fail "repeated collision changed the local tag inventory"
test "$collision_remote_tags_after_second" = "$collision_remote_tags_before" \
    || fail "repeated collision changed the remote tag inventory"
if ! collision_tag_record="$(remote_ref_record refs/tags/v1.0.0.3)"; then
    fail "could not inspect the v1.0.0.3 remote tag after collision"
fi
test "$(printf '%s' "$collision_tag_record" | cut -f1)" = "$second_sha" \
    || fail "existing tag was moved"

# Malformed versions fail without changing local or remote tags.
assert_invalid_version() {
    local version="$1" message="$2" before="$3"
    commit_version "$version" "$message"
    local invalid_sha local_tags_before remote_tags_before local_tags_after remote_tags_after invalid_tag_record
    if ! invalid_sha="$(git -C "$REPO" rev-parse HEAD)"; then
        fail "could not determine commit for invalid version ${version}"
    fi
    if ! local_tags_before="$(git -C "$REPO" tag --list)"; then
        fail "could not snapshot local tags before invalid version ${version}"
    fi
    if ! remote_tags_before="$(remote_tag_inventory)"; then
        fail "could not snapshot remote tags before invalid version ${version}"
    fi
    if run_tag_script "$invalid_sha" "$before"; then
        fail "invalid version ${version} unexpectedly succeeded"
    fi
    if ! local_tags_after="$(git -C "$REPO" tag --list)"; then
        fail "could not snapshot local tags after invalid version ${version}"
    fi
    if ! remote_tags_after="$(remote_tag_inventory)"; then
        fail "could not snapshot remote tags after invalid version ${version}"
    fi
    test "$local_tags_after" = "$local_tags_before" \
        || fail "invalid version ${version} changed the local tag list"
    test "$remote_tags_after" = "$remote_tags_before" \
        || fail "invalid version ${version} changed the remote tag list"
    if ! invalid_tag_record="$(remote_ref_record "refs/tags/v${version}")"; then
        fail "could not inspect the v${version} remote tag"
    fi
    test -z "$invalid_tag_record" \
        || fail "invalid version ${version} created a tag"
    INVALID_SHA="$invalid_sha"
}

assert_invalid_version 1.0 'test: reject two-component stable version' "$collision_sha"
assert_invalid_version 1.0.foo 'test: reject non-numeric stable version' "$INVALID_SHA"
assert_invalid_version 1.0.0.foo 'test: reject four-component non-numeric stable version' "$INVALID_SHA"

test -x "$SCRIPT" || fail "tag script is not executable"
test -f "$WORKFLOW" || fail "automatic tag workflow is missing"
if ! command -v ruby >/dev/null 2>&1; then
    fail "Ruby is required for structured workflow YAML assertions"
fi
if ! ruby - "$WORKFLOW" <<'RUBY'
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

jobs = doc['jobs']
abort 'workflow must define jobs' unless jobs.is_a?(Hash)
steps = []
jobs.each do |job_name, job|
  abort "job #{job_name} must define steps" unless job.is_a?(Hash) && job['steps'].is_a?(Array)
  abort "job #{job_name} steps must be mappings" unless job['steps'].all? { |step| step.is_a?(Hash) }
  steps.concat(job['steps'])
end
abort 'workflow must contain exactly three planned steps' unless steps.length == 3

token_steps = steps.select { |step| step['name'] == 'Detect sync token' }
abort 'workflow must contain exactly one Detect sync token step' unless token_steps.length == 1

checkout_steps = steps.select { |step| step['uses'] == 'actions/checkout@v6' }
abort 'workflow must contain exactly one actions/checkout@v6 step' unless checkout_steps.length == 1
checkout_with = checkout_steps.first['with']
checkout_token = checkout_with.is_a?(Hash) ? checkout_with['token'] : nil
abort 'actions/checkout@v6 must use SYNC_TOKEN' unless checkout_token == '${{ secrets.SYNC_TOKEN }}'

helper_runs = steps.count { |step| step['run'] == 'bash scripts/auto-tag-stable.sh' }
abort 'workflow must contain exactly one helper invocation step' unless helper_runs == 1
RUBY
then
    fail "workflow YAML contract assertion failed"
fi

assert_contains 'GITHUB_EVENT_BEFORE' "$SCRIPT"
assert_contains 'git ls-remote origin' "$SCRIPT"
assert_contains '^[[:space:]]*git[[:space:]]+push[[:space:]]+origin[[:space:]]+"\$TAG"[[:space:]]*$' "$SCRIPT"

printf 'automatic stable tagging tests passed\n'
