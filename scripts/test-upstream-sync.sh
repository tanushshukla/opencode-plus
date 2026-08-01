#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/upstream-sync.yml"

grep -q 'token: \${{ secrets.SYNC_TOKEN || github.token }}' "$WORKFLOW"
grep -q 'SYNC_TOKEN' "$WORKFLOW"
grep -q 'git merge upstream/main --no-commit --no-ff' "$WORKFLOW"
grep -q 'git diff --name-only --cached "\$BASE" -- .github/workflows' "$WORKFLOW"
grep -q 'git checkout "\$BASE" -- "\$file"' "$WORKFLOW"
grep -q 'git push origin HEAD:main' "$WORKFLOW"

if grep -q 'actions/create-github-app-token' "$WORKFLOW"; then
  echo "upstream-sync must not require an unconfigured GitHub App token" >&2
  exit 1
fi

echo "upstream-sync workflow checks passed"
