# Beta caller-credential reload regression (#112)

## Contract

The peer-validated credential broker still delivers credentials exactly once to
the registered V2 server PID/start-time identity. The non-dumpable preload library
retains the MCP caller credential in native process memory. Each plugin setup
copies it through `opencode_v2_copy_caller_secret`; it neither consumes nor closes
FD 3. The getter rejects a forked PID or a fresh process without a broker handoff.
The JavaScript copy buffer is wiped after validation. Returned credential strings
remain private in the MCP registration, as before.

The library is loaded before JavaScript and stays loaded for the server process's
lifetime. Consequently, local source-loader invalidation and plugin re-evaluation
do not discard the credential, unlike a cache inside a plugin module or setup
closure. Restart the beta app when deploying the matching native and JS changes.

## Verification — 2026-09-13

- **29 focused Node tests passed:** plugin configuration, repeated setup/disposal,
  failed-registration recovery, invalid native results, temporary-buffer wiping,
  redacted errors, and existing beta state-isolation contracts.
- Built `ha_opencode_beta` with `scripts/devcontainer-build-app.sh` inside the
  official Home Assistant Apps devcontainer, using native amd64 and the pinned
  CLI/plugin **0.0.0-beta-19242**. Native compilation uses `-Wall -Werror`.
- The native `boundary-test` image target passed. Its regression fixtures verify:
  - Repeated copies from the real preloaded library with an unrelated idle,
    nonblocking socket occupying FD 3. The socket remains open and still returns
    EAGAIN when intentionally read by the fixture.
  - Rejection of invalid buffer sizes, forked callers, and fresh execs without
    broker initialization; one-shot broker marker consumption and denial of an
    unregistered process remain intact.
  - Six setup/disposal cycles across three actual local module generations,
    using the pinned Bun plugin source loader, then the real MCP registration.
    Authenticated V2 policy checks and both MCP/native-MCP tool catalogues pass.
- Supervisor installed and started the working-tree beta image. On Core
  **2026.9.2**, Supervisor **2026.09.0**, Node **24.15.0**,
  `scripts/devcontainer-acceptance.sh ha_opencode_beta` passed with HA-facing MCP
  disabled and again after a restart with it enabled: **37 smoke checks per run**,
  plus the script's s6, credential/permission, sidecar-recovery, TUI-attachment,
  and real Core Ingress checks.

The added fixtures are read-only BuildKit mounts for the existing native ARM/x64
CI boundary target; they are not installed in the released app. No stable-channel
files were changed. Local arm64, physical HAOS, and a multi-day soak of the
reporter's installation were not performed.
