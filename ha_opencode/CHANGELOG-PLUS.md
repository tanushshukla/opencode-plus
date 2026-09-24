## 3.0.6.1

- **Carry the OpenCode+ overlay onto OpenCode V2 stable (3.0.6)** — the image/voice wrapper stays on loopback port 8101 behind the shared ingress router and now follows the interface mode resolved at startup (`/data/.interface_mode`), matching upstream's router. The upstream sync now auto-resolves conflicts in every upstream file the overlay patches, including files upstream deletes.

## 2.5.5.2

- **Fix add-on crash loop on port 8099 (OpenCode+ overlay)** — upstream 2.5.5 moved the shared ingress router (`ha-openchamber-ingress`) onto port 8099 for both interface modes, colliding with the OpenCode+ image/voice wrapper that also listened there. The router now crashed repeatedly with `EADDRINUSE` and the wrapper showed "Terminal backend unavailable". The wrapper now runs on loopback port 8101 behind the router, which is patched to use it as its upstream; the wrapper proxies to ttyd (8100) or OpenChamber (3010) and forwards absolute paths so ingress-rewritten asset URLs and the quit control keep working.
