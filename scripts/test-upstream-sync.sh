#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/upstream-sync.yml"

grep -q 'git merge upstream/main --no-commit --no-ff' "$WORKFLOW"
grep -q 'Preserve fork workflow files' "$WORKFLOW"
grep -q 'git checkout "$BASE" -- "$file"' "$WORKFLOW"
grep -q 'git push origin HEAD:main' "$WORKFLOW"

if grep -q 'SYNC_TOKEN' "$WORKFLOW"; then
  echo "upstream-sync must not depend on a PAT" >&2
  exit 1
fi

if grep -q 'token:' "$WORKFLOW"; then
  echo "upstream-sync checkout must use the built-in GITHUB_TOKEN" >&2
  exit 1
fi

if grep -q 'actions/create-github-app-token' "$WORKFLOW"; then
  echo "upstream-sync must not require an unconfigured GitHub App token" >&2
  exit 1
fi

echo "upstream-sync workflow checks passed"
