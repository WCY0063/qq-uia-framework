// Anti-detection / automation-fingerprint audit.
// Connects to an existing CDP endpoint and inspects renderer-side signals only (read-only).
const PORT = Number(process.argv[2] ?? 9222);
const BASE = `http://127.0.0.1:${PORT}`;
const out = [];
const log = (...a) => { const s = a.join(' '); out.push(s); console.log(s); };

class CDP {
  constructor(url) { this.url = url; this.id = 0; this.pending = new Map(); }
  connect() {
    return new Promise((res, rej) => {
      this.ws = new WebSocket(this.url);
      this.ws.onopen = () => res(this);
      this.ws.onerror = (e) => rej(new Error('ws error'));
      this.ws.onmessage = (m) => {
        let msg; try { msg = JSON.parse(m.data); } catch { return; }
        if (msg.id && this.pending.has(msg.id)) {
          const { resolve, reject } = this.pending.get(msg.id); this.pending.delete(msg.id);
          msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
        }
      };
    });
  }
  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
      setTimeout(() => { if (this.pending.has(id)) { this.pending.delete(id); reject(new Error('timeout ' + method)); } }, 15000);
    });
  }
  async eval(expression) {
    const r = await this.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error('threw: ' + (r.exceptionDetails.exception?.description ?? '').slice(0, 300));
    return r.result?.value;
  }
  close() { try { this.ws.close(); } catch {} }
}

(async () => {
  let version;
  try { version = await (await fetch(BASE + '/json/version')).json(); }
  catch (e) { console.error(`CDP endpoint ${BASE} not reachable: ${e.message}`); process.exitCode = 2; return; }

  log('CDP endpoint: ' + BASE);
  log('Browser: ' + version.Browser);
  log('Protocol: ' + version['Protocol-Version']);
  log('');

  const targets = (await (await fetch(BASE + '/json/list')).json()).filter(t => t.webSocketDebuggerUrl && t.type === 'page');
  log('page targets: ' + targets.length);
  const cdp = new CDP(targets[0].webSocketDebuggerUrl);
  await cdp.connect();
  await cdp.send('Runtime.enable');

  log('');
  log('=== A. JavaScript-level automation tells ===');
  const a = await cdp.eval(`(() => ({
    webdriver: navigator.webdriver,
    webdriverType: typeof navigator.webdriver,
    plugins: navigator.plugins.length,
    languages: navigator.languages,
    userAgent: navigator.userAgent.slice(0,140),
    userAgentData: navigator.userAgentData ? { brands: navigator.userAgentData.brands.map(b=>b.brand+':'+b.version), mobile: navigator.userAgentData.mobile } : null,
    hasChromeRuntime: typeof chrome !== 'undefined' && !!chrome.runtime,
    hasChromeLoadTimes: typeof chrome !== 'undefined' && typeof chrome.loadTimes === 'function',
    notificationPerm: typeof Notification !== 'undefined' ? Notification.permission : null,
    headlessHints: { 'userAgent has Headless': /Headless/i.test(navigator.userAgent), 'window.outerW==0': window.outerWidth === 0 }
  }))()`);
  log(JSON.stringify(a, null, 2));

  log('');
  log('=== B. Is the renderer automation-flagged? (CDP-observable) ===');
  // Browser.getVersion is a CDP call; checking which domains are exposed tells us how the app was started
  let domains = {};
  try { domains.browser = await cdp.send('Browser.getVersion'); } catch (e) { domains.browser = 'ERR ' + e.message; }
  log('Browser.getVersion: ' + JSON.stringify(domains.browser));
  // Check if --enable-automation style tells exist
  const b = await cdp.eval(`(() => ({
    // Chromium sets this banner only with --enable-automation
    infobars: document.querySelectorAll('[class*=infobar],[id*=infobar]').length,
    // Electron-specific accessors
    hasProcess: typeof process !== 'undefined',
    processType: (typeof process !== 'undefined') ? process.type : null,
    hasRequire: typeof require !== 'undefined',
    // QQ preload-exposed bridges
    bridgeKeys: Object.keys(window).filter(k => /^(qq|QQ|electron|nt|node|native|ipc)/.test(k)).slice(0, 40),
    // is the page the main chat UI?
    bodyClasses: document.body.className.slice(0, 200),
    title: document.title, href: location.href.slice(0, 140)
  }))()`);
  log(JSON.stringify(b, null, 2));

  log('');
  log('=== C. What does the page actually see for synthetic input? (trust model) ===');
  const c = await cdp.eval(`(() => {
    const ed = document.querySelector('.ExEditor-qq-msg-editor') || document.querySelector('[contenteditable="true"]');
    const res = { editorFound: !!ed };
    if (ed) {
      // A JS-dispatched event is NOT trusted; a browser-level (CDP Input.*) event IS.
      let jsTrusted = null, jsSeen = false;
      const probe = (e) => { jsSeen = true; jsTrusted = e.isTrusted; };
      ed.addEventListener('beforeinput', probe, { once: true });
      ed.addEventListener('input', probe, { once: true });
      try {
        ed.dispatchEvent(new InputEvent('beforeinput', { inputType: 'insertText', data: 'X', bubbles: true, cancelable: true }));
      } catch (err) { res.dispatchErr = String(err).slice(0,120); }
      ed.removeEventListener('beforeinput', probe); ed.removeEventListener('input', probe);
      res.jsDispatchedSeen = jsSeen; res.jsDispatchedIsTrusted = jsTrusted;
    }
    return res;
  })()`);
  log(JSON.stringify(c, null, 2));
  log('NOTE: jsDispatchedIsTrusted=false is the normal DOM rule. CDP Input.dispatchKeyEvent/insertText');
  log('      is injected at the browser process and DOES produce events with isTrusted=true.');

  log('');
  log('=== D. Trusted-input capability check (does CDP input actually reach the editor?) ===');
  // Try a browser-level insertText with a harmless probe string, then read back and clear it.
  const d1 = await cdp.eval(`(() => {
    const ed = document.querySelector('.ExEditor-qq-msg-editor') || document.querySelector('[contenteditable="true"]');
    if (!ed) return { ok: false };
    ed.focus();
    return { ok: true, before: (ed.innerText || '').slice(0, 60), focused: document.activeElement === ed };
  })()`);
  log('focus editor: ' + JSON.stringify(d1));
  if (d1.ok) {
    // count isTrusted on a real CDP-injected insert
    await cdp.eval(`(() => {
      window.__trustProbe = { seen: 0, trusted: 0, types: [] };
      const ed = document.querySelector('.ExEditor-qq-msg-editor') || document.querySelector('[contenteditable="true"]');
      const h = (e) => { window.__trustProbe.seen++; window.__trustProbe.trusted += e.isTrusted ? 1 : 0; window.__trustProbe.types.push(e.type + ':' + e.isTrusted); };
      ed.addEventListener('beforeinput', h); ed.addEventListener('input', h); ed.addEventListener('keydown', h);
      window.__trustCleanup = () => { ed.removeEventListener('beforeinput', h); ed.removeEventListener('input', h); ed.removeEventListener('keydown', h); };
      return true;
    })()`);
    try { await cdp.send('Input.insertText', { text: 'dshtest' }); } catch (e) { log('Input.insertText ERR: ' + e.message); }
    const d2 = await cdp.eval(`(() => {
      const ed = document.querySelector('.ExEditor-qq-msg-editor') || document.querySelector('[contenteditable="true"]');
      window.__trustCleanup && window.__trustCleanup();
      return { probe: window.__trustProbe, textNow: (ed.innerText || '').slice(0, 60),
               html: ed.innerHTML.slice(0, 160),
               editorClasses: ed.className.toString() };
    })()`);
    log('after Input.insertText: ' + JSON.stringify(d2, null, 2));
    // clear the probe text again (do NOT send)
    const d3 = await cdp.eval(`(() => {
      const ed = document.querySelector('.ExEditor-qq-msg-editor') || document.querySelector('[contenteditable="true"]');
      if (!ed) return null;
      ed.innerHTML = '<p><br></p>';
      try { ed.dispatchEvent(new InputEvent('input', { bubbles: true })); } catch(e) {}
      return { cleared: (ed.innerText||'').trim(), cls: ed.className.toString() };
    })()`);
    log('after clear: ' + JSON.stringify(d3));
  }

  log('');
  log('=== E. QQ secrets / native hooks visible from the page? (internal-API surface) ===');
  const e = await cdp.eval(`(() => {
    const hits = {};
    const keys = Object.keys(window);
    hits.windowKeyCount = keys.length;
    hits.bridgeCandidates = keys.filter(k => /qq|nt|native|node|ipc|electron|bridge|wrapper|major/i.test(k)).slice(0,40);
    // Common QQNT preload globals
    for (const k of ['qq','QQNT','qqnt','ntApi','nodeIKernel','wrapper','major','electron','ipcRenderer','require','process','module']) {
      try { hits['typeof_' + k] = typeof window[k]; } catch (err) { hits['typeof_' + k] = 'ERR'; }
    }
    // native node module presence
    try { hits.processType = typeof process !== 'undefined' ? process.type : null; } catch(e2) { hits.processType = 'ERR'; }
    try { hits.processVersions = typeof process !== 'undefined' ? process.versions : null; } catch(e3) { hits.processVersions = 'ERR'; }
    return hits;
  })()`);
  log(JSON.stringify(e, null, 2));

  cdp.close();
  const fs = await import('node:fs');
  fs.writeFileSync(new URL('./cdp-fingerprint-report.txt', import.meta.url), out.join('\n'), 'utf8');
  console.log('\n[report written to cdp-fingerprint-report.txt]');
})().catch(e => { console.error('FATAL ' + (e?.stack || e)); process.exitCode = 1; });
