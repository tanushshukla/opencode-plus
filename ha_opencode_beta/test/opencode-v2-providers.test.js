import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";
import { buildManagedConfig, READ_ONLY_AGENT_ID } from "../rootfs/opt/opencode-v2-homeassistant/managed-config.js";
import { prepareUserConfig, isProviderEnvironmentName, ppqProvider } from "../rootfs/opt/opencode-v2-homeassistant/user-config.js";

const generator = fileURLToPath(new URL("../rootfs/opt/opencode-v2-homeassistant/managed-config.js", import.meta.url));
const fixtureKey = "fixture-key-$'`\\\"-never-log";
const nativeProvider = () => ({
  name: "Fixture", env: ["FIXTURE_API_KEY"],
  package: "@opencode/ai/providers/openai-compatible",
  settings: { baseURL: "http://127.0.0.1:12345/v1", timeout: 1000 },
  models: { coding: { modelID: "upstream/coder", capabilities: { tools: true, input: ["text"], output: ["text"] }, limit: { context: 8192, output: 1000 } } },
});
const options = (config, extra = {}) => ({
  opencode_config: JSON.stringify(config),
  env_vars: [{ name: "FIXTURE_API_KEY", value: fixtureKey }], ...extra,
});

describe("bounded native V2 provider configuration", () => {
  it("preserves native providers, aliases, overlays and variants using the pinned schema", () => {
    const provider = nativeProvider();
    provider.models.coding.variants = [{ id: "low", settings: { reasoningEffort: "low" }, body: { service_tier: "flex" } }];
    provider.models.coding.compatibility = { reasoningField: "reasoning_content" };
    provider.headers = { Authorization: "Bearer {env:FIXTURE_API_KEY}" };
    const config = { model: "fixture/coding", providers: { fixture: provider }, formatter: false, compaction: { auto: false } };
    const result = prepareUserConfig(options(config));
    assert.deepEqual(result.config, config);
    assert.equal(result.providerEnvironment.toString(), `FIXTURE_API_KEY=${fixtureKey}\0`);
    assert.ok(!JSON.stringify(result.config).includes(fixtureKey));
  });

  it("retains no stale providers or environment entries when options are cleared", () => {
    prepareUserConfig(options({ providers: { fixture: nativeProvider() } }));
    const empty = prepareUserConfig();
    assert.deepEqual(empty.config, {});
    assert.equal(empty.providerEnvironment.length, 0);
  });

  it("uses last duplicate env value without shell evaluation and warns on unsupported backend variables", () => {
    const warnings = [];
    const prepared = prepareUserConfig({ env_vars: [
      { name: "FIXTURE_API_KEY", value: "old" }, { name: "FIXTURE_API_KEY", value: fixtureKey },
      { name: "HTTPS_PROXY", value: "sensitive-proxy-value" },
      { name: "OPENCODE_CONFIG_CONTENT", value: "sensitive-policy-value" },
      { name: "SUPERVISOR_TOKEN", value: "sensitive-token-value" },
    ] }, { warn: (message) => warnings.push(message) });
    assert.equal(prepared.providerEnvironment.toString(), `FIXTURE_API_KEY=${fixtureKey}\0`);
    assert.equal(warnings.length, 1);
    assert.match(warnings[0], /not forwarded/);
    assert.doesNotMatch(warnings[0], /sensitive-|fixture-key/);
  });

  it("never forwards reserved policy or integration credentials", () => {
    for (const name of ["SUPERVISOR_API_KEY", "HA_API_KEY", "HAB_API_KEY", "PPQ_API_KEY", "OPENCODE_API_KEY", "NODE_API_KEY", "BUN_API_KEY", "LD_API_KEY", "NODE_OPTIONS", "BASH_ENV", "AWS_SECRET_ACCESS_KEY", "SUPERVISOR_TOKEN", "HA_ACCESS_TOKEN", "API_KEY", "bad\n_API_KEY"]) {
      assert.equal(isProviderEnvironmentName(name), false, name);
    }
    for (const name of ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "OPENROUTER_API_KEY", "CUSTOM_2_API_KEY"]) {
      assert.equal(isProviderEnvironmentName(name), true, name);
    }
  });

  for (const [label, config] of [
    ["legacy provider", { provider: { fixture: {} } }],
    ["legacy provider npm", { providers: { fixture: { npm: "@ai-sdk/openai-compatible" } } }],
    ["legacy provider options", { providers: { fixture: { options: { apiKey: fixtureKey } } } }],
    ["malformed nested model", { providers: { fixture: { models: { coding: { limit: { output: "100" } } } } } }],
    ["malformed native control", { providers: { fixture: { settings: { timeout: "fast" } } } }],
    ["unknown nested model field", { providers: { fixture: { models: { coding: { invented: fixtureKey } } } } }],
    ["plugin disable", { plugins: ["-homeassistant.runtime-guard"] }],
    ["permission bypass", { permissions: [{ action: "*", resource: "*", effect: "allow" }] }],
    ["read-only agent override", { agents: { [READ_ONLY_AGENT_ID]: { permissions: [] } } }],
    ["runtime update", { update: "auto" }],
    ["LSP enable", { lsp: true }],
    ["external provider code", { providers: { fixture: { package: "file:///tmp/plugin" } } }],
    ["external model code", { providers: { fixture: { models: { coding: { package: "evil-package" } } } } }],
    ["file expansion", { providers: { fixture: { settings: { apiKey: "{file:/run/opencode-v2/server-password}" } } } }],
    ["ambient credential expansion", { providers: { fixture: { settings: { apiKey: "{env:SUPERVISOR_TOKEN}" } } } }],
    ["managed PPQ route override", { providers: { "ppq-private": { settings: { baseURL: "https://example.invalid" } } } }],
    ["shell formatter", { formatter: { custom: { command: ["sh", "-c", "echo unsafe"] } } }],
    ["URL credentials", { providers: { fixture: { settings: { baseURL: "https://user:secret@example.invalid" } } } }],
    ["invalid header", { providers: { fixture: { headers: { Authorization: "first\r\nsecond" } } } }],
  ]) {
    it(`rejects ${label} without echoing supplied values`, () => {
      assert.throws(() => prepareUserConfig(options(config)), (error) => {
        assert.match(error.message, /opencode_config:/);
        assert.ok(!error.message.includes(fixtureKey));
        assert.doesNotMatch(error.message, /server-password|example\.invalid|evil-package/);
        return true;
      });
    });
  }

  it("requires explicit environment substitutions to exist but allows native account sign-in for env declarations", () => {
    const warnings = [];
    const config = { providers: { fixture: nativeProvider() } };
    prepareUserConfig(options(config, { env_vars: [] }), { warn: (message) => warnings.push(message) });
    assert.match(warnings.join("\n"), /credential is missing.*connect a provider account/);
    config.providers.fixture.settings.apiKey = "{env:FIXTURE_API_KEY}";
    assert.throws(() => prepareUserConfig(options(config, { env_vars: [] })), /referenced provider API key is missing/);
  });

  it("rejects secret-valued parser errors, prototype keys, recursive substitutions and excessive input", () => {
    for (const raw of [`{"${fixtureKey}`, "null", "[]", '{"providers":{"__proto__":{}}}', '{"providers":{"fixture":{"settings":{"constructor":{}}}}}']) {
      assert.throws(() => prepareUserConfig({ opencode_config: raw }), (error) => !error.message.includes(fixtureKey));
    }
    for (const value of ["a\0b", "a\nb", "{file:/secret}", "{env:SUPERVISOR_TOKEN}"]) {
      assert.throws(() => prepareUserConfig({ env_vars: [{ name: "FIXTURE_API_KEY", value }] }));
    }
    assert.throws(() => prepareUserConfig({ opencode_config: " ".repeat(1024 * 1024 + 1) }), /1 MiB/);
    assert.throws(() => prepareUserConfig({ env_vars: [{ name: "FIXTURE_API_KEY", value: "x".repeat(65536) }] }), /64 KiB/);
  });

  it("wires PPQ only with a key and never forwards its upstream credential", () => {
    for (const ppqOptions of [{ ppq_api_key: fixtureKey }, { env_vars: [{ name: "PPQ_API_KEY", value: fixtureKey }] }]) {
      const warnings = [];
      const result = prepareUserConfig({ ppq_private_enabled: true, ...ppqOptions }, { warn: (message) => warnings.push(message) });
      assert.deepEqual(result.config.providers["ppq-private"], ppqProvider());
      assert.equal(result.config.model, undefined, "enabling PPQ never silently changes the selected model");
      assert.equal(result.providerEnvironment.length, 0);
      assert.ok(!JSON.stringify(result.config).includes(fixtureKey));
      assert.ok(!warnings.join("\n").includes(fixtureKey));
      assert.match(warnings.join("\n"), /readiness.*not verified/);
    }
    const warnings = [];
    assert.deepEqual(prepareUserConfig({ ppq_private_enabled: true }, { warn: (message) => warnings.push(message) }).config, {});
    assert.match(warnings.join("\n"), /no API key/);
    assert.throws(() => prepareUserConfig(options({ model: "ppq-private/private/kimi-k2-5" })), /needs private mode/);
    assert.throws(() => prepareUserConfig(options({ model: "ppq-private/unknown" }, { ppq_private_enabled: true, ppq_api_key: fixtureKey })), /not in the managed model list/);
  });

  it("stages raw config and literal environment separately without losing mandatory managed policy", async () => {
    const root = await mkdtemp(join(tmpdir(), "ha-v2-user-config-"));
    try {
      const input = join(root, "options.json");
      const output = join(root, "provider-env");
      const raw = options({ model: "fixture/coding", providers: { fixture: nativeProvider() }, formatter: false });
      await writeFile(input, JSON.stringify(raw));
      const run = () => spawnSync(process.execPath, [generator, "--options-file", input, "--environment-output", output], { encoding: "utf8" });
      const result = run();
      assert.equal(result.status, 0, result.stderr);
      const config = JSON.parse(result.stdout);
      const base = buildManagedConfig();
      for (const field of ["plugins", "permissions", "agents", "snapshots", "lsp", "skills", "autoupdate", "share"]) assert.deepEqual(config[field], base[field]);
      assert.equal(config.model, "fixture/coding");
      assert.equal(config.formatter, false);
      assert.equal(await readFile(output, "utf8"), `FIXTURE_API_KEY=${fixtureKey}\0`);
      assert.ok(!(result.stdout + result.stderr).includes(fixtureKey));
      assert.deepEqual(JSON.parse(await readFile(input, "utf8")), raw);

      await writeFile(input, JSON.stringify(options({ plugins: [fixtureKey] })));
      const rejected = run();
      assert.equal(rejected.status, 1);
      assert.equal(rejected.stdout, "");
      assert.ok(!rejected.stderr.includes(fixtureKey));
      // Init's fresh temp files + ready marker gate prevent this earlier artifact
      // from being activated; failed validation does not overwrite any input.
      assert.equal(await readFile(output, "utf8"), `FIXTURE_API_KEY=${fixtureKey}\0`);

      await writeFile(input, "{}");
      assert.equal(run().status, 0);
      assert.equal((await readFile(output)).length, 0);
    } finally { await rm(root, { recursive: true, force: true }); }
  });
});
