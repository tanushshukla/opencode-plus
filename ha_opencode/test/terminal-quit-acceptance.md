# Terminal quit acceptance (stable)

Run in the official Home Assistant Apps devcontainer configured by
`.devcontainer/devcontainer.json`, selecting **ha_opencode**. Use **Start Home
Assistant → Install App → Start App**, or **Rebuild and Start App** for an existing
installation. Host process tests are not Supervisor/s6 lifecycle evidence.

1. Select Terminal mode and open the app via real HA Core Ingress. Check the
   top-right **Quit OpenCode** button at desktop and narrow/mobile widths: it must
   remain reachable alongside the existing clipboard control. Check keyboard
   focus and the confirmation dialog, including cancelling it.
2. Start a disposable conversation and note its ID. Record the terminal's native
   OpenCode PID and its owned MCP/LSP child PIDs. Close and reopen the browser:
   the native PID and conversation must be unchanged.
3. Open a second browser on the shared terminal. Click Quit and confirm in the
   first. Both views must return to a usable shell. The native process and its
   owned children must exit; no raw mouse-reporting sequences should appear when
   moving the mouse. The button reports success only after native exit.
4. Click Quit at the shell: it must report no managed standalone instance and
   leave the shell intact. Run a different foreground program and repeat; it must
   remain running. Type `opencode`, reopen the saved conversation, and quit again.
5. Repeat with customized OpenCode exit keybindings. The result must be identical.
6. If the optional LAN server is enabled, record its PID before quitting the
   terminal and confirm it remains running and reachable afterward. Confirm ttyd,
   the ingress proxy, and tmux remain running too. Measure memory rather than
   expecting any fixed amount to be released.
7. Confirm changing the terminal instance while a quit confirmation is open does
   not quit the replacement instance; retrying gets a fresh confirmation.
8. Run **Run App Acceptance** (`scripts/devcontainer-acceptance.sh ha_opencode`).

The control helper uses Linux pidfds and requires a caught SIGHUP before it sends
the signal. For the certified **1.18.29** runtime, the upstream source contract is:

- `packages/tui/src/app.tsx`: `onSighup` calls `destroyRenderer`, the same teardown
  as `ExitProvider`; renderer destruction resolves the shutdown deferred and
  disposes the scoped TUI resources.
- `packages/opencode/src/cli/cmd/tui.ts`: the TUI's `finally` invokes `stop()`,
  requesting worker shutdown before terminating the worker and exiting.

Sources: https://github.com/anomalyco/opencode/tree/v1.18.29

Recheck that contract and repeat live acceptance when changing the runtime pin.
Never replace it with unverified SIGTERM semantics or add force-kill escalation.

## Verification record — 2026-09-13

Passed in the official `ghcr.io/home-assistant/devcontainer:5-apps` environment:

- Native amd64; Supervisor **2026.09.0**, Home Assistant Core **2026.9.2**.
- Stable working-tree image, version **2.5.4**, OpenCode **1.18.29**, Node
  **24.15.0**. Installed by Supervisor, built with
  `scripts/devcontainer-build-app.sh ha_opencode`, and started by Supervisor.
- Image ID: `sha256:4461e5c912550f8e20982a7aa3f6eb280cea234ab270a38700c6afa560142f86`.
- Browser requests traversed actual Core Ingress using a disposable owner's
  session created by the authenticated `supervisor/api` WebSocket command for
  `/ingress/session`. No spoofed Ingress peer or user headers were used.
- Desktop **1280×850**, narrow viewport **390×844**, and mobile/touch emulation
  tested with Chromium. The narrow viewport button measured approximately
  **121×44 CSS pixels**, wholly inside the viewport. Touch activation passed.
- Closing/reopening a browser retained the same native instance. Cancelling the
  confirmation retained it too.
- Confirmed quit returned HTTP 200 after native exit and left the same shell
  usable in two connected browsers. Repeated clicks at the shell and a click
  while `sleep` was foreground did not terminate either shell or foreground app.
- A real conversation was saved, survived quit, and was reopened with its user
  message and response visible in the TUI.
- Default `opencode` relaunch was recognized. A previous instance's quit request
  received HTTP 409 (`changed`) and did not stop the replacement.
- With `leader: ctrl+a` and `app_exit: ctrl+alt+q`, the old exit sequence no
  longer exited; the button still quit successfully. The temporary bindings were
  restored after testing.
- A separate live read-only request opened `configuration.yaml` and started both
  `yaml-ls` and `ha-yaml`. Quitting during that request removed native PID 1108
  and all three owned child PIDs (1157, 1228, 1240), including the MCP server and
  `/opt/ha-lsp-server/server.js`. Their summed RSS immediately before quitting
  was about **1.19 GiB**; this is process accounting, not a guaranteed physical
  memory saving. All four PIDs were absent afterward.
- The independent LAN server retained its PID and answered `/global/health` with
  HTTP 200. The separately enabled HA-facing MCP service retained its PID too;
  ttyd, ingress, tmux and the shell remained running. A direct loopback POST to
  `/terminal/quit` was denied with HTTP 403.
- `scripts/devcontainer-acceptance.sh ha_opencode` passed with HA-facing MCP
  **disabled**, then **enabled**. Each run passed all **31 smoke checks**, plus
  the script's Supervisor, s6, binding, and real Core Ingress assertions.

Fresh Core 2026.9 initially selected HTTP port 80. The disposable development
instance was moved to 8123 (matching the repository's 7123:8123 forwarding) using
the supported `http/config/configure` and `http/config/promote` WebSocket APIs.
After the HTTP configuration has migrated, a YAML `server_port` edit does not
replace this stored configuration. This was environment setup, not an app fix.

No production-code correction was required by live testing. Browser artifacts
were saved under `/tmp/opencode/` (`quit-desktop.png`, `quit-mobile.png`, and
`quit-touch-conversation.png`); disposable credentials remain outside the repo.

These results cover the actual Ingress app page, including emulated touch, not
physical Android/iOS devices or the full HA sidebar layout. The devcontainer
runs the host Linux kernel and is not HAOS; native arm64 and host-level HAOS
behaviour remain outside this verification.
