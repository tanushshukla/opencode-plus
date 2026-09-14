const { execFile } = require("node:child_process");
const { randomBytes, createHmac, timingSafeEqual } = require("node:crypto");

const secret = randomBytes(32);
let quitting = false;

function invoke(action, instance) {
  return new Promise((resolve, reject) => {
    execFile("/usr/bin/python3", ["/usr/local/bin/terminal-control.py", action, ...(instance ? [instance] : [])], {
      timeout: 12000, maxBuffer: 4096, env: { PATH: "/usr/bin:/bin" },
    }, (error, stdout) => {
      if (error) return reject(error);
      try { resolve(JSON.parse(stdout)); } catch (parseError) { reject(parseError); }
    });
  });
}

function send(res, status, value) {
  res.writeHead(status, { "content-type": "application/json", "cache-control": "no-store", "x-content-type-options": "nosniff" });
  res.end(JSON.stringify(value));
}

function routeTerminalControl(req, res, { ingressPath, upstreamPath, terminal, lan = false }) {
  const pathname = upstreamPath.split("?", 1)[0];
  // Consume a control URL even if a forged prefix stopped the proxy stripping
  // it, rather than forwarding that request into ttyd.
  if (pathname !== "/terminal/quit" && !/^\/api\/hassio_ingress\/[A-Za-z0-9_-]+\/terminal\/quit(?:\?|$)/.test(req.url || "")) return false;
  const reject = () => send(res, 403, { message: "Forbidden" });
  const headers = req.headers;
  const names = req.rawHeaders.filter((_, index) => index % 2 === 0).map((name) => name.toLowerCase());
  const protectedHeaders = ["x-remote-user-id", "x-forwarded-host", "x-forwarded-proto", "x-ingress-path", "origin", "x-terminal-control", "x-terminal-csrf"];
  let origin;
  try {
    if (pathname !== "/terminal/quit" || !terminal || lan || (req.socket.remoteAddress || "").replace(/^::ffff:/, "") !== "172.30.32.2" ||
        protectedHeaders.some((name) => names.filter((entry) => entry === name).length > 1) ||
        !/^[a-f0-9]{32}$/.test(headers["x-remote-user-id"] || "") ||
        !/^\/api\/hassio_ingress\/[A-Za-z0-9_-]+$/.test(ingressPath) || headers["x-ingress-path"] !== ingressPath ||
        headers["x-terminal-control"] !== "1" ||
        !["http", "https"].includes(headers["x-forwarded-proto"]) ||
        typeof headers["x-forwarded-host"] !== "string" || /[\s,/@\\?#%]/.test(headers["x-forwarded-host"])) throw new Error();
    origin = new URL(`${headers["x-forwarded-proto"]}://${headers["x-forwarded-host"]}`).origin;
    if ((req.method === "POST" || headers.origin !== undefined) && headers.origin !== origin) throw new Error();
  } catch { reject(); return true; }
  // A custom-header GET is not a cross-origin simple request. The nonce is bound
  // to this Ingress user/path/origin, including against forged forwarding headers.
  const csrf = createHmac("sha256", secret).update(`${headers["x-remote-user-id"]}\n${ingressPath}\n${origin}`).digest("hex");
  if (req.method === "GET") {
    invoke("status").then((status) => send(res, 200, { ...status, csrf }))
      .catch(() => send(res, 503, { message: "Terminal control unavailable." }));
    return true;
  }
  if (req.method !== "POST") {
    send(res, 405, { message: "Use GET or POST." });
    return true;
  }
  const supplied = headers["x-terminal-csrf"];
  if (typeof supplied !== "string" || !/^[a-f0-9]{64}$/.test(supplied) ||
      !timingSafeEqual(Buffer.from(supplied), Buffer.from(csrf)) ||
      headers["content-type"] !== "application/json") {
    reject(); return true;
  }
  let body = "";
  let oversized = false;
  req.on("data", (chunk) => {
    if (oversized) return;
    body += chunk;
    if (Buffer.byteLength(body) > 256) {
      oversized = true;
      send(res, 413, { message: "Request too large." });
    }
  });
  req.on("error", () => {});
  req.on("end", async () => {
    if (oversized) return;
    let instance;
    try {
      const parsed = JSON.parse(body);
      if (!parsed || Object.keys(parsed).length !== 1 || !/^[a-f0-9]{64}$/.test(parsed.instance || "")) throw new Error();
      instance = parsed.instance;
    } catch { send(res, 400, { message: "Invalid request." }); return; }
    if (quitting) { send(res, 409, { message: "A quit request is already in progress." }); return; }
    quitting = true;
    try {
      const result = await invoke("quit", instance);
      send(res, result.state === "stopped" ? 200 : 409, result);
    } catch { send(res, 503, { message: "Could not confirm graceful exit. No force-kill was attempted." }); }
    finally { quitting = false; }
  });
  return true;
}

module.exports = { routeTerminalControl };
