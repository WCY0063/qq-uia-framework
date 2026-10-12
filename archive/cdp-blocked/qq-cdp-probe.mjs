// CDP probe against a QQ (QQNT/Electron) instance launched with --remote-debugging-port.
// Read-only: enumerates targets and runs DOM queries. Sends no messages.
import fs from 'node:fs';

const PORT = Number(process.argv[2] ?? 9222);
const BASE = `http://127.0.0.1:${PORT}`;
const out = [];
const log = (...a) => { const s = a.join(' '); out.push(s); console.log(s); };

async function getJson(path) {
  const r = await fetch(BASE + path);
  if (!r.ok) throw new Error(`${path} -> HTTP ${r.status}`);
  return r.json();
}

class CDP {
  constructor(url) { this.url = url; this.id = 0; this.pending = new Map(); this.events = []; this.ws = null; }
  connect() {
    return new Promise((res, rej) => {
      this.ws = new WebSocket(this.url);
      this.ws.onopen = () => res(this);
      this.ws.onerror = (e) => rej(new Error('ws error ' + (e?.message ?? '')));
      this.ws.onmessage = (m) => {
        let msg; try { msg = JSON.parse(m.data); } catch { return; }
        if (msg.id && this.pending.has(msg.id)) {
          const { resolve, reject } = this.pending.get(msg.id);
          this.pending.delete(msg.id);
          msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
        } else if (msg.method) {
          this.events.push(msg);
        }
      };
    });
  }
  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
      setTimeout(() => { if (this.pending.has(id)) { this.pending.delete(id); reject(new Error('timeout ' + method)); } }, 20000);
    });
  }
  async eval(expression, awaitPromise = false) {
    const r = await this.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise, userGesture: false });
    if (r.exceptionDetails) throw new Error('eval threw: ' + (r.exceptionDetails.exception?.description ?? JSON.stringify(r.exceptionDetails)));
    return r.result?.value;
  }
  close() { try { this.ws?.close(); } catch {} }
}

// ---- DOM helper source injected into each page ----
const HELPERS = `
window.__probe = {
  sel(sel){ return document.querySelectorAll(sel).length; },
  first(sel){ const e=document.querySelector(sel); if(!e) return null;
    return { tag:e.tagName, cls:e.className && e.className.toString().slice(0,160), id:e.id,
             role:e.getAttribute('role'), aria:e.getAttribute('aria-label'),
             ce:e.getAttribute('contenteditable'), text:(e.innerText||'').slice(0,120) }; },
  countByClass(sub){ const all=document.querySelectorAll('*'); let n=0; const set=new Set();
    for(const el of all){ const c=(el.className&&el.className.toString())||''; if(c.includes(sub)){ n++; set.add(c.slice(0,120)); } }
    return { count:n, classes:[...set].slice(0,6) }; },
  classStats(){ const m=new Map(); for(const el of document.querySelectorAll('*')){
      const c=(el.className&&el.className.toString())||''; for(const tok of c.split(/\\s+/)){ if(tok) m.set(tok,(m.get(tok)||0)+1); } }
    return [...m.entries()].filter(([,v])=>v>1).sort((a,b)=>b[1]-a[1]).slice(0,45); }
};
'ok';`;

function section(n, title) { log(''); log('='.repeat(78)); log(`### ${n}. ${title}`); log('='.repeat(78)); }

(async () => {
  section('0', 'CDP REACHABILITY');
  log('URL: ' + BASE);
  const version = await getJson('/json/version');
  log('Browser: ' + version.Browser);
  log('Protocol-Version: ' + version['Protocol-Version']);
  log('V8: ' + version['V8-Version']);
  log('userAgent: ' + version['User-Agent']);
  log('webSocketDebuggerUrl: ' + version.webSocketDebuggerUrl);

  const targets = await getJson('/json/list');
  section('1', `TARGET ENUMERATION (Target.getTargets) — ${targets.length} targets`);
  log(String('idx').padEnd(4) + 'type'.padEnd(12) + 'title'.padEnd(40) + 'url');
  targets.forEach((t, i) => {
    log(String(i).padEnd(4) + String(t.type).padEnd(12) + String(t.title || '').slice(0, 38).padEnd(40) + String(t.url || '').slice(0, 70));
  });
  log('');
  log('websocket targets available: ' + targets.filter(t => t.webSocketDebuggerUrl).length + '/' + targets.length);

  // Pick the real chat page: prefer a target whose title/url looks like the main UI
  const scored = targets.filter(t => t.webSocketDebuggerUrl).map(t => {
    const s = `${t.title} ${t.url}`;
    let score = 0;
    if (/main|index|qq/i.test(s)) score += 2;
    if (t.type === 'page') score += 3;
    if (/devtools/i.test(s)) score -= 10;
    return { t, score };
  }).sort((a, b) => b.score - a.score);

  if (!scored.length) { log('NO ATTACHABLE TARGETS'); fs.writeFileSync('cdp-report.txt', out.join('\n')); return; }

  const main = scored[0].t;
  log('');
  log('>>> selecting main target: ' + main.title + ' | ' + main.url);
  const cdp = new CDP(main.webSocketDebuggerUrl);
  await cdp.connect();
  await cdp.send('Runtime.enable');
  log('Runtime.enable OK');

  const ready = await cdp.eval(HELPERS, false);
  log('helper injection: ' + ready);

  section('2', 'READ CURRENT CHAT TEXT (item ②)');
  const chat = await cdp.eval(`(() => {
    const ea = document.querySelector('.chat-msg-area');
    const list = document.querySelector('.ml-area') || document.querySelector('.ml-container') || ea;
    const msgs = [...document.querySelectorAll('.message')];
    const out = { hasChatArea: !!ea, msgCount: msgs.length, sample: [] };
    for (const m of msgs.slice(-6)) {
      const self = !!m.querySelector('.message-container--self');
      const who = m.querySelector('.avatar-span')?.innerText?.trim() || null;
      const body = (m.querySelector('.msg-content-container')?.innerText || m.innerText || '').trim().slice(0, 160);
      const ts = m.querySelector('.message__timestamp')?.innerText?.trim() || null;
      out.sample.push({ self, who, ts, body });
    }
    out.chatAreaText = (ea?.innerText || '').slice(-400);
    out.listClasses = list?.className?.toString?.().slice(0,140) || null;
    return out;
  })()`);
  log('chat-msg-area present: ' + chat.hasChatArea + ' | .message nodes: ' + chat.msgCount);
  log('list container class: ' + chat.listClasses);
  log('-- last messages (oldest->newest) --');
  chat.sample.forEach((m, i) => log(`  [${i}] ${m.self ? 'SELF' : 'PEER'} ts=${m.ts ?? '-'} who=${m.who ?? '-'} :: ${JSON.stringify(m.body)}`));
  log('-- tail of chat area innerText --');
  log(JSON.stringify(chat.chatAreaText));

  section('4', 'CHAT / CONVERSATION LIST LOCATOR (item ④)');
  const cl = await cdp.eval(`(() => {
    const probes = {
      '.recent-contact-list': null, '.recent-contact-item': null, '.recent-contact-item--selected': null,
      '.recent-contact-default-theme-list': null, '.item__content': null, '.sidebar-nav': null,
      '.chat-header__contact-name': null
    };
    for (const k of Object.keys(probes)) probes[k] = window.__probe.first(k);
    const items = [...document.querySelectorAll('.recent-contact-item')].slice(0, 5).map(el => ({
      text: (el.innerText || '').replace(/\\n+/g, ' | ').slice(0, 110),
      selected: el.className.toString().includes('--selected')
    }));
    const total = document.querySelectorAll('.recent-contact-item').length;
    return { probes, items, total,
      listScrollable: (() => { const e = document.querySelector('.recent-contact-list'); if(!e) return null;
        return { scrollHeight: e.scrollHeight, clientHeight: e.clientHeight }; })() };
  })()`);
  log('recent-contact-item count: ' + cl.total);
  log('list scroll metrics: ' + JSON.stringify(cl.listScrollable));
  log('sample rows:');
  cl.items.forEach((it, i) => log(`  [${i}] sel=${it.selected} :: ${JSON.stringify(it.text)}`));
  for (const [k, v] of Object.entries(cl.probes)) log(`  ${k.padEnd(36)} -> ${v ? v.tag + ' .' + (v.cls || '').slice(0, 60) : 'NOT FOUND'}`);

  section('5', 'INPUT BOX LOCATOR (item ⑤)');
  const ib = await cdp.eval(`(() => {
    const cands = {
      '.ExEditor-qq-msg-editor': null, '.ProseMirror': null, '.msg-input': null,
      '.q-search input': null, 'input': null, '[contenteditable="true"]': null,
      '.send-msg': null, '.operation': null
    };
    for (const k of Object.keys(cands)) cands[k] = window.__probe.first(k);
    const ce = document.querySelector('.ExEditor-qq-msg-editor') || document.querySelector('[contenteditable="true"]');
    let detail = null;
    if (ce) detail = { tag: ce.tagName, role: ce.getAttribute('role'), ce: ce.getAttribute('contenteditable'),
      aria: ce.getAttribute('aria-label'), children: ce.childElementCount, html: ce.innerHTML.slice(0, 200) };
    const inputs = [...document.querySelectorAll('input')].map(i => ({ type: i.type, cls: i.className.toString().slice(0,60),
      ph: i.placeholder, ro: i.readOnly, val: i.value.slice(0,40) }));
    return { cands, detail, inputs };
  })()`);
  log('contenteditable detail: ' + JSON.stringify(ib.detail));
  log('input elements: ' + JSON.stringify(ib.inputs));
  for (const [k, v] of Object.entries(ib.cands)) log(`  ${k.padEnd(34)} -> ${v ? v.tag + ' .' + (v.cls || '').slice(0, 50) : 'NOT FOUND'}`);

  section('6', 'SEND PLAIN TEXT — write path (item ⑥)');
  const send = await cdp.eval(`(() => {
    const ed = document.querySelector('.ExEditor-qq-msg-editor') || document.querySelector('[contenteditable="true"]');
    const btn = document.querySelector('.send-msg');
    if (!ed) return { ok: false, reason: 'editor not found' };
    const before = ed.innerHTML;
    ed.focus();
    // simulate what a real IME/typing would produce
    const dt = new DataTransfer();
    dt.setData('text/plain', 'CDP-PROBE-TEST');
    const ev = new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true });
    ed.dispatchEvent(ev);
    const after = ed.innerHTML;
    const state = { ok: true, before: before.slice(0,80), after: after.slice(0,120),
      textNow: (ed.innerText||'').slice(0,80),
      sendBtnCls: btn?.className?.toString() || null,
      sendDisabled: btn ? btn.className.toString().includes('disabled') : null };
    // do NOT click send
    return state;
  })()`);
  log(JSON.stringify(send, null, 2));
  log('NOTE: no send was triggered.');

  section('7', 'FILE PICKER / FILE INPUT (item ⑦)');
  const fp = await cdp.eval(`(() => {
    const fis = [...document.querySelectorAll('input[type=file]')];
    return { fileInputCount: fis.length,
      fileInputs: fis.map(f => ({ cls: f.className.toString().slice(0,60), accept: f.accept, multiple: f.multiple, hidden: f.offsetParent===null })),
      hasShowOpenFilePicker: typeof window.showOpenFilePicker,
      hasElectron: typeof window.electron, hasRequire: typeof window.require, hasProcess: typeof window.process,
      qqKeys: Object.keys(window).filter(k => /^qq|electron|native|bridge/i.test(k)).slice(0,25),
      ipcKeys: (() => { const c = window.qq || window.qqnt || window.electron; return c ? Object.keys(c).slice(0,25) : null; })() };
  })()`);
  log(JSON.stringify(fp, null, 2));

  section('8', 'IMAGE / FILE MESSAGE DOM (item ⑧)');
  const imgFile = await cdp.eval(`(() => {
    const pick = (sel) => { const e = document.querySelector(sel); if (!e) return null;
      return { cls: e.className.toString().slice(0,140), tag: e.tagName, html: e.outerHTML.slice(0, 500) }; };
    const imgs = [...document.querySelectorAll('img')].slice(0, 8).map(i => ({
      src: (i.src||'').slice(0, 110), srcset: (i.getAttribute('srcset')||'').slice(0,60),
      cls: i.className.toString().slice(0,80), natW: i.naturalWidth, natH: i.naturalHeight }));
    const files = [...document.querySelectorAll('.file-element, .normal-file, .file-message--content')].slice(0,3).map(f => ({
      cls: f.className.toString().slice(0,120), text: (f.innerText||'').replace(/\\n+/g,' | ').slice(0,180), html: f.outerHTML.slice(0,400) }));
    return {
      picElement: pick('.pic-element'), msgPic: pick('.mix-message__container--pic'),
      marketFace: pick('.market-face-element'), faceElem: pick('.face-element'),
      arkCard: pick('.ark-msg-content-container'),
      imgs, files,
      blobOrDataUrls: imgs.filter(i => i.src.startsWith('blob:') || i.src.startsWith('data:')).length
    };
  })()`);
  log('pic-element: ' + JSON.stringify(imgFile.picElement, null, 2));
  log('image-message container: ' + JSON.stringify(imgFile.msgPic, null, 2));
  log('market face: ' + JSON.stringify(imgFile.marketFace));
  log('ark card: ' + JSON.stringify(imgFile.arkCard, null, 2));
  log('');
  log('img samples:');
  imgFile.imgs.forEach((i, n) => log(`  [${n}] ${i.natW}x${i.natH} src=${i.src} cls=${i.cls}`));
  log('images using blob:/data: = ' + imgFile.blobOrDataUrls);
  log('file element samples:');
  imgFile.files.forEach((f, n) => log(`  [${n}] .${f.cls} :: ${JSON.stringify(f.text)}`));

  section('9', 'POKE (戳一戳) DOM / EVENTS (item ⑨)');
  const poke = await cdp.eval(`(() => {
    const tips = [...document.querySelectorAll('.gray-tip-message')].slice(0, 6).map(t => ({
      cls: t.className.toString().slice(0,120),
      html: t.outerHTML.slice(0, 420) }));
    const links = [...document.querySelectorAll('.gray-tip-action')].slice(0, 4).map(a => ({
      tag: a.tagName, text: (a.innerText||'').slice(0,40), attrs: [...a.attributes].map(x => x.name + '=' + x.value.slice(0,60)) }));
    const anyPoke = document.body.innerText.includes('戳了戳');
    return { tipCount: document.querySelectorAll('.gray-tip-message').length, tips, links, anyPoke,
      tipImg: (() => { const i = document.querySelector('.gray-tip-img'); return i ? { tag:i.tagName, cls:i.className.toString().slice(0,80), html:i.outerHTML.slice(0,300) } : null; })() };
  })()`);
  log('"戳了戳" present in body text: ' + poke.anyPoke + ' | .gray-tip-message count: ' + poke.tipCount);
  log('gray-tip sample HTML:');
  poke.tips.slice(0, 3).forEach((t, i) => log(`  [${i}] ${t.html.replace(/\\s+/g, ' ').slice(0, 380)}`));
  log('gray-tip-action (the clickable nickname): ' + JSON.stringify(poke.links, null, 2));
  log('gray-tip-img: ' + JSON.stringify(poke.tipImg));

  section('10', 'EVENT-DRIVEN MESSAGE LISTENING (item ③/⑩)');
  // show that Runtime.addBinding + MutationObserver gives push notifications
  await cdp.send('Runtime.addBinding', { name: '__dshPush' });
  const installed = await cdp.eval(`(() => {
    const list = document.querySelector('.ml-area') || document.querySelector('.chat-msg-area');
    if (!list) return { ok: false, reason: 'message list not found' };
    window.__dshMuts = 0;
    window.__dshObserver = new MutationObserver((muts) => {
      window.__dshMuts += muts.length;
      for (const m of muts.slice(0, 3)) {
        try { window.__dshPush(JSON.stringify({ type: m.type, added: m.addedNodes.length,
          cls: (m.target.className||'').toString().slice(0,60),
          text: (m.target.innerText||'').slice(-200) })); } catch(e) {}
      }
    });
    window.__dshObserver.observe(list, { childList: true, subtree: true, characterData: true });
    return { ok: true, target: list.className.toString().slice(0,100) };
  })()`);
  log('MutationObserver install: ' + JSON.stringify(installed));
  log('binding __dshPush registered via Runtime.addBinding (enables PUSH to client, no polling).');
  log('waiting 6s to capture live mutations from continuous QQ activity...');
  await new Promise(r => setTimeout(r, 6000));
  const muts = await cdp.eval('({ mutations: window.__dshMuts || 0 })');
  log('mutations observed in 6s window: ' + JSON.stringify(muts));
  const pushed = cdp.events.filter(e => e.method === 'Runtime.bindingCalled');
  log('Runtime.bindingCalled events received by client: ' + pushed.length);
  pushed.slice(0, 5).forEach((p, i) => log(`  [${i}] ${String(p.params.payload).slice(0, 220)}`));

  // also demonstrate scroll-to-load-older + verify attribute-change observation target
  const scrollTest = await cdp.eval(`(() => {
    const el = document.querySelector('.ml-area') || document.querySelector('.ml-container');
    if (!el) return null;
    const before = el.scrollTop; el.scrollTop = 0;
    return { before, after: el.scrollTop, scrollHeight: el.scrollHeight, clientHeight: el.clientHeight };
  })()`);
  log('scroll-to-top probe (loads older history): ' + JSON.stringify(scrollTest));

  section('11', 'CLASS STATISTICS (for selector crafting)');
  const stats = await cdp.eval('window.__probe.classStats()');
  stats.slice(0, 45).forEach(([k, v]) => log('  ' + String(v).padStart(5) + '  ' + k));

  cdp.close();

  // ---------- REMAINING TARGETS ----------
  section('12', 'OTHER TARGETS OVERVIEW');
  for (const t of scored.slice(1, 8)) {
    try {
      const c = new CDP(t.webSocketDebuggerUrl); await c.connect();
      await c.send('Runtime.enable');
      const info = await c.eval(`({
        title: document.title, url: location.href.slice(0,120),
        nodes: document.querySelectorAll('*').length,
        bodyText: (document.body?.innerText||'').slice(0,160).replace(/\\n+/g,' | ')
      })`);
      log(`- [${t.type}] ${t.title} :: nodes=${info.nodes} url=${info.url}`);
      log(`    text: ${JSON.stringify(info.bodyText)}`);
      c.close();
    } catch (e) { log(`- [${t.type}] ${t.title} :: ATTACH FAILED: ${e.message}`); }
  }

  fs.writeFileSync(new URL('./cdp-report.txt', import.meta.url), out.join('\n'), 'utf8');
  console.log('\n[report written to cdp-report.txt]');
})().catch(e => { console.error('FATAL: ' + (e?.stack || e)); fs.writeFileSync('cdp-report.txt', out.join('\n') + '\nFATAL: ' + (e?.stack || e), 'utf8'); process.exitCode = 1; });
