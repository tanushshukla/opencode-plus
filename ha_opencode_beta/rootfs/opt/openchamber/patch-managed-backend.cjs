// Exact preview-source patches: app supervision, credentials and Ingress HTTP.
const fs = require("node:fs");
const path = require("node:path");
const root = process.argv[2];
function patch(file, before, after) {
  const target = path.join(root, "server/lib/opencode", file);
  const source = fs.readFileSync(target, "utf8");
  if (source.split(before).length !== 2) throw new Error(`Unexpected preview source: ${file}`);
  fs.writeFileSync(target, source.replace(before, after));
}
patch("hmr-state-runtime.js", `const initialPassword = typeof processLike.env.OPENCODE_SERVER_PASSWORD === 'string'
      ? processLike.env.OPENCODE_SERVER_PASSWORD.trim()
      : '';`, `const initialPassword = globalThis[Symbol.for("ha.openchamber.credential")] || '';`);
patch("auth-state-runtime.js", "process.env.OPENCODE_SERVER_PASSWORD = normalized;",
  "// The HA app keeps this credential in process-owned state only.");
patch("lifecycle.js", "const startOpenCode = async () => {",
  `const startOpenCode = async () => {
    throw new Error('OpenCode is managed by Home Assistant; use the app controls');`);
// Core/Supervisor Ingress streams POST bodies using chunked transfer encoding.
// Express consumes those chunks; the preview serializes the parsed body again.
// That new fixed-length body must not retain the incoming transfer framing.
patch("proxy.js", "if (!hasParsedBodyValue(req.body) && originalContentLength <= 0) return null;",
  "if (!hasParsedBodyValue(req.body) && originalContentLength <= 0 && !req.headers?.['transfer-encoding']) return null;");
patch("proxy.js", "proxyReq.setHeader('content-length', String(body.length));",
  "proxyReq.removeHeader('transfer-encoding');\n    proxyReq.setHeader('content-length', String(body.length));");
console.log("OpenChamber uses the app-owned backend and process-private authentication");
