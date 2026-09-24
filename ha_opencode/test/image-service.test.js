// OpenCode Plus overlay: the image/voice wrapper sits BEHIND the upstream
// ingress router (ha-openchamber-ingress on 8099) so the router keeps seeing
// the Supervisor socket directly (its /ha-mcp route binds
// to the remote address). The wrapper listens on loopback 8101 and proxies to
// ttyd (8100) or OpenChamber (3010).
//
// Run with: node --test ha_opencode/test/image-service.test.js

const assert = require("node:assert/strict");
const { after, before, describe, it } = require("node:test");
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const http = require("node:http");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");

const ROOT = path.join(__dirname, "..");
const SERVER = path.join(ROOT, "rootfs", "opt", "image-service", "server.js");
const S6 = path.join(ROOT, "rootfs", "etc", "s6-overlay", "s6-rc.d");

function read(...parts) {
  return fs.readFileSync(path.join(...parts), "utf8");
}

function freePort() {
  return new Promise((resolve, reject) => {
    const probe = net.createServer();
    probe.once("error", reject);
    probe.listen(0, "127.0.0.1", () => {
      const { port } = probe.address();
      probe.close(() => resolve(port));
    });
  });
}

function request(port, pathname, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: "127.0.0.1", port, path: pathname, headers }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString("utf8") }));
    });
    req.on("error", reject);
    req.end();
  });
}

function upgrade(port, pathname) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      host: "127.0.0.1",
      port,
      path: pathname,
      headers: { connection: "Upgrade", upgrade: "websocket", "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==", "sec-websocket-version": "13" },
    });
    req.on("upgrade", (res, socket) => {
      socket.destroy();
      resolve(res.statusCode);
    });
    req.on("response", (res) => resolve(res.statusCode));
    req.on("error", reject);
    req.end();
  });
}

function waitForPort(port, attempts = 50) {
  return new Promise((resolve, reject) => {
    const tryOnce = (left) => {
      const s = net.connect(port, "127.0.0.1");
      s.once("connect", () => { s.destroy(); resolve(); });
      s.once("error", () => {
        if (left === 0) reject(new Error(`port ${port} never opened`));
        else setTimeout(() => tryOnce(left - 1), 50);
      });
    };
    tryOnce(attempts);
  });
}

describe("image-service s6 wiring sits behind the shared ingress router", () => {
  const imageRun = read(S6, "image-service", "run");
  const ingressRun = read(S6, "ha-openchamber-ingress", "run");
  const openchamberRun = read(S6, "ha-openchamber", "run");

  it("does not compete with the router for the ingress port", () => {
    assert.doesNotMatch(imageRun, /IMAGE_SERVICE_PORT=8099/);
    assert.match(imageRun, /^export IMAGE_SERVICE_HOST=127\.0\.0\.1$/m);
    assert.match(imageRun, /^export IMAGE_SERVICE_PORT=8101$/m);
    assert.match(ingressRun, /^export OPENCHAMBER_INGRESS_PORT=8099$/m);
  });

  it("wraps the real UI backends", () => {
    assert.match(imageRun, /export UPSTREAM_PORT=3010/);
    assert.match(imageRun, /export UPSTREAM_PORT=8100/);
    assert.doesNotMatch(imageRun, /808[09]|8090/);
  });

  it("is the router's upstream in both interface modes", () => {
    const upstreamLines = ingressRun.match(/^\s*export OPENCHAMBER_UPSTREAM_PORT=\d+$/mg);
    assert.equal(upstreamLines.length, 2);
    for (const line of upstreamLines) assert.match(line, /=8101$/);
  });

  it("keeps the OpenChamber update-check URL pointed at the router", () => {
    assert.match(openchamberRun, /OPENCHAMBER_UPDATE_API_URL="http:\/\/127\.0\.0\.1:8099\//);
  });
});

describe("image-service proxy", () => {
  let child;
  let upstream;
  let port;
  let upstreamPort;
  let tmp;
  const seen = [];

  before(async () => {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), "image-service-"));
    port = await freePort();
    upstreamPort = await freePort();
    upstream = http.createServer((req, res) => {
      seen.push(req.url);
      res.writeHead(200, { "content-type": "text/plain" });
      res.end(`upstream saw ${req.url}`);
    });
    upstream.on("upgrade", (req, socket) => {
      seen.push(`upgrade ${req.url}`);
      socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n");
      socket.end();
    });
    await new Promise((r) => upstream.listen(upstreamPort, "127.0.0.1", r));
    child = spawn(process.execPath, [SERVER], {
      env: {
        PATH: process.env.PATH,
        IMAGE_SERVICE_HOST: "127.0.0.1",
        IMAGE_SERVICE_PORT: String(port),
        UPSTREAM_PORT: String(upstreamPort),
        UPLOAD_DIR: tmp,
      },
      stdio: ["ignore", "ignore", "inherit"],
    });
    await waitForPort(port);
  });

  after(async () => {
    if (child) child.kill("SIGTERM");
    await new Promise((r) => upstream.close(r));
    fs.rmSync(tmp, { recursive: true, force: true });
  });

  it("serves the wrapper page at the root", async () => {
    const res = await request(port, "/");
    assert.equal(res.status, 200);
    assert.match(res.body, /id="terminal-frame"/);
  });

  it("strips the /terminal prefix for the iframe", async () => {
    const res = await request(port, "/terminal/token?x=1");
    assert.equal(res.status, 200);
    assert.equal(res.body, "upstream saw /token?x=1");
    assert.equal((await request(port, "/terminal")).body, "upstream saw /");
  });

  it("forwards unknown paths untouched so ingress-rewritten absolute URLs reach the backend", async () => {
    const res = await request(port, "/assets/app.js");
    assert.equal(res.status, 200);
    assert.equal(res.body, "upstream saw /assets/app.js");
  });

  it("proxies websocket upgrades for both prefixed and absolute paths", async () => {
    assert.equal(await upgrade(port, "/terminal/ws"), 101);
    assert.equal(await upgrade(port, "/ws"), 101);
    assert.ok(seen.includes("upgrade /ws"));
    assert.equal(seen.filter((entry) => entry === "upgrade /ws").length, 2);
  });

  it("keeps its own endpoints local", async () => {
    assert.equal((await request(port, "/health")).status, 200);
    assert.equal((await request(port, "/favicon.ico")).status, 204);
    assert.ok(!seen.includes("/health"));
  });
});
