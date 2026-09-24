// Bounded native V2 configuration, based on /v2/docs/config, /providers and
// /models. Do not fall back to the public (potentially V1) config.json schema.
// Unsupported fields fail visibly instead of silently bypassing managed policy.
import { Config } from "@opencode/schema/config";
import { Schema } from "effect";

// These are locked dependencies of the pinned plugin package already shipped in
// the image. The actual V2 decoder validates nested fields, not a V1 facsimile.
const decodeConfig = Schema.decodeUnknownSync(Config.Info, { onExcessProperty: "error" });
const ROOT_FIELDS = ["$schema", "model", "default_agent", "providers", "formatter", "compaction", "media", "tool_output", "websearch"];
const PACKAGES = new Set([
  "openai", "openai/chat", "openai/responses", "openai-compatible",
  "openai-compatible/responses", "anthropic", "anthropic-compatible", "google",
  "google-vertex", "google-vertex/gemini", "google-vertex/chat", "google-vertex/responses",
  "google-vertex/messages", "azure", "azure/chat", "azure/responses", "amazon-bedrock",
  "amazon-bedrock/mantle", "amazon-bedrock/mantle/chat", "amazon-bedrock/mantle/responses",
  "openrouter", "xai",
].map((name) => `@opencode/ai/providers/${name}`));

// No inherited environment is copied. In particular, never forward HA, PPQ,
// Supervisor, launcher/config, loader, or policy variables to the model server.
// API-key names cover custom providers; cloud chains and generic process knobs
// require separate qualification and deliberately remain unsupported here.
export function isProviderEnvironmentName(name) {
  return typeof name === "string"
    && /^[A-Z][A-Z0-9_]*_API_KEY$/.test(name)
    && !/^(?:OPENCODE|SUPERVISOR|HA|HAB|PPQ|NODE|BUN|LD)_/.test(name);
}

function invalid(message) {
  // Never include raw values, unknown keys, parse exceptions, or credentials.
  throw new TypeError(`opencode_config: ${message}`);
}

function object(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) invalid(`${label} must be an object`);
}

function fields(value, allowed, label) {
  object(value, label);
  if (Object.keys(value).some((key) => !allowed.includes(key))) {
    invalid(`${label} contains unsupported fields; supported: ${allowed.join(", ")}`);
  }
}

function text(value, label) {
  if (typeof value !== "string" || !value.trim() || /[\x00-\x1f]/.test(value)) invalid(`${label} must be a nonempty string without control characters`);
}

function jsonValues(value, environment, depth = 0) {
  if (depth > 32) invalid("nesting exceeds the supported limit");
  if (typeof value === "string") {
    if (value.includes("{file:")) invalid("file substitutions are not supported; use provider API keys in env_vars");
    for (const match of value.matchAll(/\{env:([^}]*)\}/g)) {
      if (!isProviderEnvironmentName(match[1])) invalid("environment substitutions require a supported provider *_API_KEY variable");
      if (!environment.has(match[1]) || !environment.get(match[1]).trim()) invalid("a referenced provider API key is missing; set its env_vars value and restart");
    }
  } else if (Array.isArray(value)) {
    value.forEach((item) => jsonValues(item, environment, depth + 1));
  } else if (value && typeof value === "object") {
    for (const [key, item] of Object.entries(value)) {
      if (["__proto__", "constructor", "prototype"].includes(key)) invalid("unsafe object key");
      // Config substitution also runs on JSON keys in some runtime versions.
      if (key.includes("{env:") || key.includes("{file:")) invalid("substitutions in object keys are not supported");
      jsonValues(item, environment, depth + 1);
    }
  }
}

function requestOptions(value) {
  if (value.headers && Object.values(value.headers).some((header) => typeof header !== "string" || /[\r\n]/.test(header))) {
    invalid("headers must contain single-line string values");
  }
  if (value.settings?.baseURL !== undefined) {
    try {
      const url = new URL(value.settings.baseURL);
      if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.hash) throw new Error();
    } catch { invalid("settings.baseURL must be an absolute HTTP(S) URL without credentials or a fragment"); }
  }
  if (value.settings?.apiKey !== undefined) text(value.settings.apiKey, "settings.apiKey");
  if (value.package !== undefined && !PACKAGES.has(value.package)) invalid("provider/model package must be a documented built-in @opencode/ai/providers runtime; external packages are not supported");
}

export function ppqProvider() {
  return {
    name: "PPQ Private (TEE)",
    package: "@opencode/ai/providers/openai-compatible",
    // The upstream key belongs exclusively to the proxy, not the model server.
    settings: { apiKey: "unused", baseURL: "http://127.0.0.1:8787/v1", timeout: 600000, chunkTimeout: 60000 },
    models: Object.fromEntries([
      ["kimi-k2-5", "Kimi K2.5", 262144, false],
      ["deepseek-r1-0528", "DeepSeek R1", 131072, false],
      ["gpt-oss-120b", "GPT-OSS 120B", 131072, false],
      ["llama3-3-70b", "Llama 3.3 70B", 131072, false],
      ["qwen3-vl-30b", "Qwen3-VL 30B", 262144, true],
    ].map(([id, name, context, image]) => [`private/${id}`, {
      modelID: `private/${id}`, name: `${name} (Private)`,
      capabilities: { tools: true, input: image ? ["text", "image"] : ["text"], output: ["text"] },
      limit: { context, output: 8192 },
    }])),
  };
}

export function prepareUserConfig(options = {}, { warn = () => {} } = {}) {
  object(options, "add-on options");
  const environment = new Map();
  let unsupportedEnvironment = false;
  if (options.env_vars !== undefined && !Array.isArray(options.env_vars)) invalid("env_vars must be an array");
  for (const entry of options.env_vars ?? []) {
    if (!entry || typeof entry.name !== "string" || typeof entry.value !== "string" || entry.value.includes("\0")) invalid("env_vars entries require string names and values without NUL characters");
    if (isProviderEnvironmentName(entry.name)) {
      if (/[\r\n]/.test(entry.value) || /\{(?:file|env):/.test(entry.value)) invalid("provider API keys must be single-line literal values, not substitutions");
      environment.set(entry.name, entry.value);
    }
    else if (entry.name !== "PPQ_API_KEY") unsupportedEnvironment = true;
  }
  if (unsupportedEnvironment) warn("Some env_vars are not forwarded to the V2 backend: only non-reserved provider *_API_KEY variables are supported. Existing shell/service handling is separate.");

  let raw = options.opencode_config ?? "";
  if (typeof raw !== "string") invalid("the saved option must be a JSON string");
  if (Buffer.byteLength(raw) > 1024 * 1024) invalid("the saved option exceeds 1 MiB");
  let config = {};
  if (raw.trim()) {
    try { config = JSON.parse(raw); } catch { invalid("invalid JSON; correct the saved option and restart (JSONC is not supported here)"); }
  }
  fields(config, ROOT_FIELDS, "root (managed plugins, permissions, agents, runtime and integration policy cannot be overridden)");
  jsonValues(config, environment);
  try { decodeConfig(config); }
  catch { invalid("native V2 schema validation failed; check field names and value types against /v2/docs/config and /v2/docs/providers (legacy provider/npm/options fields are not accepted)"); }
  if (config.$schema !== undefined && config.$schema !== "https://opencode.ai/config.json") invalid("$schema must be https://opencode.ai/config.json");
  if (config.model !== undefined && (typeof config.model !== "string" || !/^[^\s/#]+\/[^\s#]+$/.test(config.model))) invalid("model must be a provider/model string without a variant");
  if (config.default_agent !== undefined && !["build", "plan", "home-assistant-read-only"].includes(config.default_agent)) invalid("default_agent must be build, plan, or home-assistant-read-only");
  if (config.formatter !== undefined && typeof config.formatter !== "boolean") invalid("only boolean formatter overrides are currently supported");
  // Native WebSearch.ID is an extensible string; this image ships only these
  // documented providers and does not permit user-loaded provider plugins.
  if (config.websearch && !["exa", "firecrawl", "parallel", "tavily", "random"].includes(config.websearch.provider)) {
    invalid("websearch.provider must be exa, firecrawl, parallel, tavily or random; use websearch: false to disable search");
  }
  if (config.providers !== undefined) {
    object(config.providers, "providers");
    for (const [id, provider] of Object.entries(config.providers)) {
      if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(id)) invalid("provider IDs must use letters, digits, dots, underscores or hyphens");
      if (id === "ppq-private") invalid("ppq-private is managed; use the PPQ options instead of overriding its routing");
      if (provider.env !== undefined) {
        if (provider.env.some((name) => !isProviderEnvironmentName(name))) invalid("provider env accepts only non-reserved *_API_KEY variable names");
        if (provider.env.length && !provider.env.some((name) => environment.get(name)?.trim()) && !provider.settings?.apiKey) {
          warn("A provider's env credential is missing: set its *_API_KEY in env_vars or connect a provider account in V2. No account availability was checked.");
        }
      }
      requestOptions(provider);
      if (provider.models !== undefined) {
        object(provider.models, "provider models");
        for (const [id, entry] of Object.entries(provider.models)) {
          if (!id || /[\s#]/.test(id)) invalid("model IDs must be nonempty without whitespace or #");
          requestOptions(entry);
          if (entry.limit && Object.values(entry.limit).some((n) => !Number.isSafeInteger(n) || n <= 0)) invalid("model limits must be positive integers");
          const variants = new Set();
          for (const variant of entry.variants ?? []) {
            if (variants.has(variant.id)) invalid("variant IDs must be unique");
            variants.add(variant.id);
            requestOptions(variant);
          }
        }
      }
    }
  }

  const ppqEnabled = options.ppq_private_enabled === true;
  const ppqKey = options.ppq_api_key || [...(options.env_vars ?? [])].reverse().find((entry) => entry.name === "PPQ_API_KEY")?.value;
  if (ppqEnabled && typeof ppqKey === "string" && ppqKey.trim()) {
    config.providers = { ...config.providers, "ppq-private": ppqProvider() };
    warn("PPQ private models are configured through the local proxy; select a ppq-private model explicitly. Proxy readiness and upstream availability are not verified at startup.");
  } else if (ppqEnabled) {
    warn("PPQ private mode has no API key; its managed provider is inactive. Set ppq_api_key or PPQ_API_KEY in env_vars and restart.");
  }
  if (config.model?.startsWith("ppq-private/") && !config.providers?.["ppq-private"]) invalid("the selected PPQ model needs private mode enabled and a PPQ API key");
  if (config.model?.startsWith("ppq-private/") && !config.providers["ppq-private"].models[config.model.slice("ppq-private/".length)]) invalid("the selected PPQ model is not in the managed model list");

  const providerEnvironment = Buffer.from([...environment].map(([name, value]) => `${name}=${value}\0`).join(""));
  if (providerEnvironment.length > 65536) invalid("provider environment exceeds 64 KiB");
  return { config, providerEnvironment };
}
