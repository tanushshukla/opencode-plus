#!/usr/bin/env bash
# OpenCode Plus overlay applier.
#
# Re-applies every "plus" change to upstream-owned files. Idempotent: safe to
# run any number of times. The upstream-sync workflow resolves any merge
# conflict in these files by taking upstream's version and re-running this
# script, so keep ALL edits to upstream-owned files in here.
#
# Usage:
#   scripts/apply-plus.sh          # ensure overlay; version becomes <upstream>.1 if not yet suffixed
#   scripts/apply-plus.sh --bump   # additionally bump the overlay suffix (overlay-only release)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/ha_opencode/config.yaml"
DOCKERFILE="$ROOT/ha_opencode/Dockerfile"
CHANGELOG="$ROOT/ha_opencode/CHANGELOG.md"
README="$ROOT/README.md"
REPOYAML="$ROOT/repository.yaml"
HA_OPENCODE_RUN="$ROOT/ha_opencode/rootfs/etc/s6-overlay/s6-rc.d/ha-opencode/run"
HA_OPENCHAMBER_RUN="$ROOT/ha_opencode/rootfs/etc/s6-overlay/s6-rc.d/ha-openchamber/run"
MARKER='# --- opencode-plus overlay ---'
BUMP="${1:-}"

sedi() { sed -i.plusbak "$@" && rm -f "${@: -1}.plusbak"; }

changed=0

# --- config.yaml: version = <upstream base>.<overlay n> -----------------------
# Parse version FIRST so we fail early if config.yaml is unparseable,
# before any partial writes have been committed.
current="$(sed -n 's/^version: *"\{0,1\}\([0-9][0-9.]*\)"\{0,1\}.*/\1/p' "$CONFIG" | head -1)"
if [ -z "$current" ]; then
  echo "ERROR: could not parse version from $CONFIG" >&2
  exit 1
fi
# Upstream uses 3-segment versions (e.g. 2.3.7). If the version already has
# 4+ segments it has already been through this script.
dots="$(printf '%s' "$current" | tr -cd '.' | wc -c | tr -d ' ')"
if [ "$dots" -le 2 ]; then
  base="$current"
  n=1
else
  base="${current%.*}"
  n="${current##*.}"
  if [ "$BUMP" = "--bump" ]; then n=$((n + 1)); fi
fi
newver="$base.$n"

# --- config.yaml: naming ------------------------------------------------------
if grep -q '^name: "OpenCode"$' "$CONFIG"; then
  sedi 's/^name: "OpenCode"$/name: "OpenCode+"/' "$CONFIG"
  changed=1
fi
if grep -q '^panel_title: OpenCode$' "$CONFIG"; then
  sedi 's/^panel_title: OpenCode$/panel_title: OpenCode+/' "$CONFIG"
  changed=1
fi
if grep -q '^url: "https://github.com/magnusoverli/opencode"$' "$CONFIG"; then
  sedi 's|^url: "https://github.com/magnusoverli/opencode"$|url: "https://github.com/tanushshukla/opencode-plus"|' "$CONFIG"
  changed=1
fi

# --- config.yaml: version write -----------------------------------------------
if [ "$newver" != "$current" ]; then
  sedi "s/^version: .*/version: \"$newver\"/" "$CONFIG"
  changed=1
fi

# --- ha-opencode/run: move ttyd from 8099 to 8089 -----------------------------
if grep -q ' -p 8099 \\$' "$HA_OPENCODE_RUN"; then
  sedi 's/ -p 8099 \\/ -p 8089 \\/' "$HA_OPENCODE_RUN"
  changed=1
fi
# Fix the log message to match the new port.
if grep -q 'Starting ttyd on port 8099' "$HA_OPENCODE_RUN"; then
  sedi 's/Starting ttyd on port 8099/Starting ttyd on port 8089/' "$HA_OPENCODE_RUN"
  changed=1
fi

# --- ha-openchamber/run: move OC ingress proxy from 8099 to 8090 --------------
if grep -q '^OPENCHAMBER_INGRESS_PORT=8099$' "$HA_OPENCHAMBER_RUN"; then
  sedi 's/^OPENCHAMBER_INGRESS_PORT=8099$/OPENCHAMBER_INGRESS_PORT=8090/' "$HA_OPENCHAMBER_RUN"
  changed=1
fi

# --- Dockerfile: append overlay block -----------------------------------------
if ! grep -qF "$MARKER" "$DOCKERFILE"; then
  cat >> "$DOCKERFILE" <<'EOF'

# --- opencode-plus overlay ---
# Image upload wrapper: serves the ingress UI on 8099, proxies the terminal
# to 8089 (terminal mode) or the OpenChamber proxy to 8090 (OpenChamber mode),
# saves pasted images to /data/images. Kept as an append-only block so upstream
# merges never conflict here.
RUN chmod +x /opt/image-service/server.js \
    && chmod +x /etc/s6-overlay/s6-rc.d/image-service/run
EOF
  changed=1
fi

# --- README: plus banner section ----------------------------------------------
if ! grep -q 'opencode-plus overlay marker' "$README"; then
  tmp="$(mktemp)"
  {
    head -1 "$README"
    cat <<'BANNER'

<!-- opencode-plus overlay marker -->
> **OpenCode+** — this is a fork of [magnusoverli/opencode](https://github.com/magnusoverli/opencode) that adds **image paste** (paste, drag-drop, or upload an image in the web terminal and get a file path for OpenCode) and **voice input**, ported from [claude-terminal-plus](https://github.com/tanushshukla/claude-terminal-plus).
BANNER
    tail -n +2 "$README"
  } > "$tmp"
  mv "$tmp" "$README"
  changed=1
fi

# --- repository.yaml ----------------------------------------------------------
if grep -q '^name: OpenCode$' "$REPOYAML"; then
  sedi 's/^name: OpenCode$/name: OpenCode Plus/' "$REPOYAML"
  changed=1
fi
if grep -q '^url: https://github.com/magnusoverli/opencode$' "$REPOYAML"; then
  sedi 's|^url: https://github.com/magnusoverli/opencode$|url: https://github.com/tanushshukla/opencode-plus|' "$REPOYAML"
  changed=1
fi
if grep -q '^maintainer: magnusoverli$' "$REPOYAML"; then
  sedi 's/^maintainer: magnusoverli$/maintainer: tanushshukla/' "$REPOYAML"
  changed=1
fi

if [ "$changed" -eq 1 ]; then
  echo "apply-plus: overlay applied, version $newver"
else
  echo "apply-plus: nothing to do, version $newver"
fi
