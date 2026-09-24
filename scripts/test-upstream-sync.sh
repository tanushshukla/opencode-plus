#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/upstream-sync.yml"

grep -q 'git merge upstream/main --no-commit --no-ff' "$WORKFLOW"
grep -q 'token: \${{ secrets.SYNC_TOKEN }}' "$WORKFLOW"
grep -q 'FORK_FILES:' "$WORKFLOW"
grep -q '^        RELEASING.md$' "$WORKFLOW"
grep -q '^        scripts/promote-beta-to-stable.sh$' "$WORKFLOW"
grep -q 'Preserve fork policy files' "$WORKFLOW"
grep -q 'git checkout "$BASE" -- "$file"' "$WORKFLOW"
grep -q 'git push origin HEAD:main' "$WORKFLOW"
grep -q 'Report manual conflict resolution required' "$WORKFLOW"
grep -q 'conflicts<<EOF' "$WORKFLOW"
grep -q 'git cat-file -e "MERGE_HEAD:$file"' "$WORKFLOW"

# Every upstream-owned file apply-plus.sh edits must auto-resolve on conflict.
while IFS= read -r file; do
  [ "$file" = "ha_opencode/CHANGELOG-PLUS.md" ] && continue # fork-only
  if ! grep -qxF "        $file" "$WORKFLOW"; then
    echo "apply-plus.sh edits $file but upstream-sync MANAGED_FILES omits it" >&2
    exit 1
  fi
done < <(grep -o '"\$ROOT/[^"]*"' "$ROOT/scripts/apply-plus.sh" | sed 's|^"\$ROOT/||; s|"$||' | sort -u)

if grep -q 'gh issue create' "$WORKFLOW"; then
  echo "upstream-sync manual-conflict reporting must not depend on the Issues API" >&2
  exit 1
fi

if grep -q 'issues: write' "$WORKFLOW"; then
  echo "upstream-sync must not request unused issue-write permission" >&2
  exit 1
fi

if grep -q 'actions/create-github-app-token' "$WORKFLOW"; then
  echo "upstream-sync must not require an unconfigured GitHub App token" >&2
  exit 1
fi

echo "upstream-sync workflow checks passed"
