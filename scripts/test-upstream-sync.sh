#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/upstream-sync.yml"

grep -q 'token: \${{ secrets.SYNC_TOKEN }}' "$WORKFLOW"
grep -q 'SYNC_TOKEN' "$WORKFLOW"
grep -q 'git merge upstream/main --no-commit --no-ff' "$WORKFLOW"
grep -q 'git push origin HEAD:main' "$WORKFLOW"

if grep -q 'token: \${{ secrets.SYNC_TOKEN || github.token }}' "$WORKFLOW"; then
  echo "upstream-sync must use SYNC_TOKEN for workflow-file pushes" >&2
  exit 1
fi

if grep -q 'Hold back upstream workflow changes' "$WORKFLOW"; then
  echo "upstream-sync must not silently hold back upstream workflow changes" >&2
  exit 1
fi

if grep -q 'actions/create-github-app-token' "$WORKFLOW"; then
  echo "upstream-sync must not require an unconfigured GitHub App token" >&2
  exit 1
fi

echo "upstream-sync workflow checks passed"
