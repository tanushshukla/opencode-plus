const assert = require("node:assert/strict");
const { test } = require("node:test");
const { once } = require("node:events");
const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const os = require("node:os");
const { spawnSync } = require("node:child_process");

const prefix = "/api/hassio_ingress/test_token";
const bin = path.resolve(__dirname, "../rootfs/usr/local/bin");
const headers = {
  "x-ingress-path": prefix, "x-remote-user-id": "a".repeat(32),
  "x-forwarded-host": "ha.example", "x-forwarded-proto": "https",
  "x-terminal-control": "1", origin: "https://ha.example",
};

function load(file, overrides = {}, extras = {}) {
  const module = { exports: {} };
  vm.runInNewContext(fs.readFileSync(file, "utf8"), {
    module, require: (name) => overrides[name] || require(name.startsWith(".") ? path.resolve(path.dirname(file), name) : name),
    Buffer, URL, console, ...extras,
  }, { filename: file });
  return module.exports;
}

test("quit route: real HTTP through ingress router with a simulated trusted peer", async (t) => {
  const calls = [];
  let peer = "172.30.32.2";
  let held;
  let nextState = "stopped";
  const route = load(path.join(bin, "terminal-control.js"), {
    "node:child_process": { execFile(executable, args, options, callback) {
      assert.equal(executable, "/usr/bin/python3");
      assert.equal(args[0], "/usr/local/bin/terminal-control.py");
      assert.deepEqual(Object.keys(options.env), ["PATH"]);
      calls.push([...args]);
      if (nextState === "hold" && args[1] === "quit") { held = callback; return; }
      callback(null, JSON.stringify(args[1] === "status" ? { state: "running", instance: "b".repeat(64) } : { state: nextState }));
    } },
  });
  let server;
  load(path.join(bin, "openchamber-ingress-proxy.js"), {
    "./terminal-control.js": route,
    http: { ...http, createServer(handler) {
      server = http.createServer((req, res) => {
        Object.defineProperty(req.socket, "remoteAddress", { configurable: true, get: () => peer });
        handler(req, res);
      });
      const listen = server.listen.bind(server);
      server.listen = () => listen(0, "127.0.0.1");
      return server;
    } },
  }, { process: { env: { HA_INGRESS_UI: "terminal" } } });
  await once(server, "listening");
  t.after(() => { server.closeAllConnections(); server.close(); });
  async function request(method = "GET", changes = {}, body) {
    return new Promise((resolve, reject) => {
      const request = http.request({ host: "127.0.0.1", port: server.address().port, path: prefix + "/terminal/quit", method, headers: { ...headers, ...changes } }, (res) => {
        let text = "";
        res.on("data", (chunk) => { text += chunk; });
        res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, text }));
      });
      request.on("error", reject); request.end(body);
    });
  }
  const get = await request();
  assert.equal(get.status, 200);
  assert.equal(get.headers["cache-control"], "no-store");
  assert.equal(get.headers["access-control-allow-origin"], undefined);
  const { csrf, instance } = JSON.parse(get.text);
  const postHeaders = { "x-terminal-csrf": csrf, "content-type": "application/json" };
  const body = JSON.stringify({ instance });
  const before = calls.length;
  for (const change of [
    { origin: "https://evil.example" }, { "x-terminal-csrf": "0".repeat(64) },
    { "x-remote-user-id": "c".repeat(32) }, { "x-ingress-path": "/api/hassio_ingress/other" },
    { "x-forwarded-host": "evil.example", origin: "https://evil.example" },
    { "content-type": "text/plain" }, { origin: [headers.origin, headers.origin] },
  ]) assert.equal((await request("POST", { ...postHeaders, ...change }, body)).status, 403);
  assert.equal((await request("POST", postHeaders, JSON.stringify({ instance, pid: 1 }))).status, 400);
  assert.equal((await request("POST", postHeaders, "x".repeat(257))).status, 413);
  assert.equal((await request("OPTIONS")).status, 405);
  peer = "127.0.0.1";
  assert.equal((await request("POST", postHeaders, body)).status, 403);
  peer = "172.30.32.2";
  assert.equal(calls.length, before);
  assert.equal((await request("POST", postHeaders, body)).status, 200);
  assert.deepEqual(calls.at(-1), ["/usr/local/bin/terminal-control.py", "quit", instance]);
  nextState = "timeout";
  assert.equal((await request("POST", postHeaders, body)).status, 409);
  nextState = "hold";
  const first = request("POST", postHeaders, body);
  while (!held) await new Promise((resolve) => setTimeout(resolve, 5));
  assert.equal((await request("POST", postHeaders, body)).status, 409);
  held(null, JSON.stringify({ state: "stopped" }));
  assert.equal((await first).status, 200);
});

test("quit action is unavailable to OpenChamber and LAN routes", () => {
  const { routeTerminalControl } = require(path.join(bin, "terminal-control.js"));
  for (const options of [{ terminal: false }, { terminal: true, lan: true }]) {
    let status;
    assert.equal(routeTerminalControl({ headers, rawHeaders: Object.entries(headers).flat(), socket: { remoteAddress: "172.30.32.2" } }, {
      writeHead(code) { status = code; }, end() {},
    }, { ingressPath: prefix, upstreamPath: "/terminal/quit", ...options }), true);
    assert.equal(status, 403);
  }
});

test("injected button confirms, sends no terminal keys, handles stopped/error states", async () => {
  const elements = [];
  const requests = [];
  let confirmed = true;
  let state = "running";
  let fail = false;
  function element() {
    return { style: {}, setAttribute() {}, addEventListener(event, handler) { this[event] = handler; } };
  }
  vm.runInNewContext(fs.readFileSync(path.resolve(__dirname, "../rootfs/opt/ttyd/quit.js"), "utf8"), {
    location: { pathname: prefix + "/" },
    document: { createElement: element, body: { appendChild(item) { elements.push(item); } } },
    window: { confirm: () => confirmed, term: { focus() {}, input() { assert.fail("must not inject keys"); } } },
    AbortController, clearTimeout() {}, setTimeout() { return 1; },
    async fetch(url, options) {
      requests.push({ url, options });
      return { ok: !fail, json: async () => options.method === "POST"
        ? { state: "stopped", message: fail ? "No confirmed exit" : "Exited" }
        : { state, instance: "b".repeat(64), csrf: "c".repeat(64), message: "Already stopped" } };
    },
  });
  const [button, message] = elements;
  assert.equal(button.textContent, "Quit OpenCode");
  assert.match(button.style.cssText, /right:12px;top:8px/);
  confirmed = false;
  await button.click();
  assert.equal(requests.length, 1);
  confirmed = true;
  await button.click();
  assert.equal(requests.at(-1).url, prefix + "/terminal/quit");
  assert.equal(requests.at(-1).options.method, "POST");
  assert.equal(message.textContent, "Exited");
  assert.equal(button.disabled, false);
  state = "stopped";
  await button.click();
  assert.equal(requests.at(-1).options.method, undefined);
  assert.equal(message.textContent, "Already stopped");
  state = "running";
  fail = true;
  await button.click();
  assert.equal(button.disabled, false);
  assert.notEqual(message.textContent, "Exited");
});

test("build-time injector includes the quit control alongside existing scripts", (t) => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "terminal-page-"));
  t.after(() => fs.rmSync(temporary, { recursive: true, force: true }));
  const input = path.join(temporary, "input.html");
  const output = path.join(temporary, "output.html");
  fs.writeFileSync(input, "<html><body>terminal</body></html>");
  const directory = path.resolve(__dirname, "../rootfs/opt/ttyd");
  const scripts = ["clipboard.js", "touch-scroll.js", "resize-fit.js", "quit.js"];
  const result = spawnSync("python3", [path.join(directory, "inject-clipboard.py"), input, output,
    ...scripts.map((name) => path.join(directory, name))], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  const html = fs.readFileSync(output, "utf8");
  for (const name of scripts) assert.ok(html.includes(fs.readFileSync(path.join(directory, name), "utf8")));
  assert.match(fs.readFileSync(path.resolve(__dirname, "../Dockerfile"), "utf8"), /inject-clipboard\.py[^\n]*\/opt\/ttyd\/quit\.js/);
});
