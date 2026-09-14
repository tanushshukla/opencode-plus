/* Injected at build time like clipboard.js; only the managed terminal can quit. */
(function () {
  'use strict';
  var prefix = location.pathname.match(/^\/api\/hassio_ingress\/[A-Za-z0-9_-]+(?=\/|$)/);
  if (!prefix) return;
  var endpoint = prefix[0] + '/terminal/quit';
  var button = document.createElement('button');
  button.type = 'button';
  button.textContent = 'Quit OpenCode';
  button.title = 'Exit the shared OpenCode terminal instance and return to the shell';
  button.style.cssText =
    'position:fixed;right:12px;top:8px;z-index:1000;min-height:44px;' +
    'padding:8px 12px;border:1px solid #7f8c8d;border-radius:6px;cursor:pointer;' +
    'background:#232629;color:#fcfcfc;font:13px/1.4 -apple-system,system-ui,sans-serif';
  var message = document.createElement('div');
  message.setAttribute('role', 'status');
  message.setAttribute('aria-live', 'polite');
  message.style.cssText =
    'display:none;position:fixed;right:12px;top:60px;z-index:1000;max-width:min(320px,85vw);' +
    'padding:10px;border-radius:6px;background:#232629;color:#fcfcfc;' +
    'font:13px/1.4 -apple-system,system-ui,sans-serif';
  var hideTimer;
  function show(text) {
    message.textContent = text;
    message.style.display = 'block';
    clearTimeout(hideTimer);
    hideTimer = setTimeout(function () { message.style.display = 'none'; }, 10000);
  }
  async function request(options) {
    var abort = new AbortController();
    var timer = setTimeout(function () { abort.abort(); }, 15000);
    try {
      var response = await fetch(endpoint, Object.assign({ credentials: 'same-origin', cache: 'no-store', signal: abort.signal }, options));
      var result = await response.json();
      if (!response.ok) throw new Error(result.message || 'Quit request failed.');
      return result;
    } finally { clearTimeout(timer); }
  }
  button.addEventListener('click', async function () {
    if (button.disabled) return;
    button.disabled = true;
    try {
      var status = await request({ headers: { 'X-Terminal-Control': '1' } });
      if (status.state !== 'running') {
        show(status.message || 'OpenCode is still starting. Please try again shortly.');
        return;
      }
      if (!window.confirm('Quit the shared OpenCode terminal instance? This interrupts current work for all connected viewers and returns to the shell. Saved conversations remain available.')) return;
      button.textContent = 'Quitting…';
      var result = await request({ method: 'POST', headers: {
        'X-Terminal-Control': '1', 'X-Terminal-CSRF': status.csrf, 'Content-Type': 'application/json',
      }, body: JSON.stringify({ instance: status.instance }) });
      show(result.message);
    } catch (error) {
      show(error.message || 'Could not confirm exit. Use OpenCode’s normal exit command.');
    } finally {
      button.textContent = 'Quit OpenCode';
      button.disabled = false;
      if (window.term) window.term.focus();
    }
  });
  document.body.appendChild(button);
  document.body.appendChild(message);
})();
