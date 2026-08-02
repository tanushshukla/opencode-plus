#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

fail() {
    printf '    FAIL  %s\n' "$1"
    FAILURES=$((FAILURES + 1))
}

pass() {
    printf '    PASS  %s\n' "$1"
}

check() {
    local description="$1"
    shift
    if "$@"; then
        pass "$description"
    else
        fail "$description"
    fi
}

assert_build_workflow() {
    local workflow="$1" channel="$2" expected_context="$3" expected_file="$4"

    ruby - "$workflow" "$channel" "$expected_context" "$expected_file" <<'RUBY'
require 'yaml'

path, channel, expected_context, expected_file = ARGV
document = YAML.load_file(path)
abort 'workflow root must be a mapping' unless document.is_a?(Hash)

jobs = document['jobs']
abort 'workflow must define jobs.build' unless jobs.is_a?(Hash) && jobs['build'].is_a?(Hash)
steps = jobs['build']['steps']
abort 'build job must define steps' unless steps.is_a?(Array)

build_step = steps.find { |step| step.is_a?(Hash) && step['uses'] == 'docker/build-push-action@v7' }
abort 'build job must use docker/build-push-action@v7' unless build_step

with = build_step['with']
abort 'build step must define with' unless with.is_a?(Hash)
abort "build context must be #{expected_context}" unless with['context'] == expected_context
abort "Dockerfile must be #{expected_file}" unless with['file'] == expected_file

build_args = with['build-args']
abort 'build step must define build-args' unless build_args.is_a?(String)
expected_arg = "ADDON_CHANNEL=#{channel}"
channel_args = build_args.lines.map(&:strip).grep(/\AADDON_CHANNEL=/)
abort "build args must define exactly #{expected_arg}" unless channel_args == [expected_arg]
RUBY
}

assert_non_main_promotion_is_rejected() {
    local work output
    work="$(mktemp -d "${TMPDIR:-/tmp}/opencode-promotion-contract.XXXXXX")"

    mkdir -p "$work/scripts" \
        "$work/ha_opencode/rootfs" "$work/ha_opencode/test" \
        "$work/ha_opencode_beta/rootfs" "$work/ha_opencode_beta/test"
    cp "$ROOT/scripts/promote-beta-to-stable.sh" "$work/scripts/promote-beta-to-stable.sh"
    chmod +x "$work/scripts/promote-beta-to-stable.sh"

    printf '%s\n' stable > "$work/ha_opencode/rootfs/marker"
    printf '%s\n' beta > "$work/ha_opencode_beta/rootfs/marker"
    touch "$work/ha_opencode/Dockerfile" "$work/ha_opencode/.dockerignore"
    touch "$work/ha_opencode_beta/Dockerfile" "$work/ha_opencode_beta/.dockerignore"
    printf '%s\n' 'OPENCHAMBER_VERSION: "stable"' > "$work/ha_opencode/build.yaml"
    printf '%s\n' 'OPENCHAMBER_VERSION: "beta"' > "$work/ha_opencode_beta/build.yaml"

    git init -q "$work" || return 1
    git -C "$work" config user.name contract-test
    git -C "$work" config user.email contract-test@example.invalid
    git -C "$work" add .
    git -C "$work" commit -qm initial
    git -C "$work" branch -M release-test

    output="$work/promotion-output.log"
    if (cd "$work" && bash scripts/promote-beta-to-stable.sh >"$output" 2>&1); then
        rm -rf "$work"
        return 1
    fi
    if ! grep -Eiq 'main|branch' "$output"; then
        rm -rf "$work"
        return 1
    fi
    grep -qx 'stable' "$work/ha_opencode/rootfs/marker"
    local result=$?
    rm -rf "$work"
    return "$result"
}

assert_promotion_docs_require_main() {
    ruby - "$ROOT/RELEASING.md" <<'RUBY'
path = ARGV.fetch(0)
text = File.read(path)
start = text.index("### Promoting beta to stable")
abort 'promotion section is missing' unless start

section = text[start..]
section = section[0, section.index("\n## ")] || section
abort 'promotion section must tell operators to checkout main' unless section.include?('git checkout main')
abort 'promotion section must tell operators to fast-forward pull main' unless section.match?(/git pull --ff-only (origin )?main/)
RUBY
}

printf '=== release pipeline contract ===\n'

check 'stable workflow uses stable context/file and channel arg' \
    assert_build_workflow \
    "$ROOT/.github/workflows/build.yaml" stable ha_opencode ha_opencode/Dockerfile
check 'beta workflow uses beta context/file and channel arg' \
    assert_build_workflow \
    "$ROOT/.github/workflows/build-beta.yaml" beta ha_opencode_beta ha_opencode_beta/Dockerfile
check 'promotion script is executable' test -x "$ROOT/scripts/promote-beta-to-stable.sh"
check 'promotion rejects a non-main branch' assert_non_main_promotion_is_rejected
check 'promotion docs require main checkout and synchronization' assert_promotion_docs_require_main

printf '\n=== %d contract checks failed ===\n' "$FAILURES"
[ "$FAILURES" = 0 ]
