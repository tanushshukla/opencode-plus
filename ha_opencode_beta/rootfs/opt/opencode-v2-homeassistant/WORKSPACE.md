# Home Assistant V2 workspace

The Home Assistant configuration is mounted at `/homeassistant`.
Use that absolute path for file reads, edits, searches, and shell commands.

The current working directory is a root-owned isolation boundary, not the
configuration directory. Do not create project configuration or plugins there.

When the `ha_yaml_*` tools are available, use their credential-isolated language
server for Home Assistant YAML diagnostics, completion, hover and definitions.
They accept an existing YAML path or optional in-memory draft text and never
write files. Check drafts before approved changes and request fresh diagnostics
after edits; report a failed HA/LSP connection rather than treating it as a clean
validation. The `ha_yaml_status` tool verifies the worker's live HA connection.
