/**
 * memory-flush-dedup hook
 * Event: session:compact:after
 *
 * Root cause being mitigated (found 2026-09-10):
 * compaction memoryFlush appends diary sections; when compaction fails after
 * the flush write and retries, the SAME sections get appended again.
 * This hook removes byte-identical duplicate `##` sections from recent daily
 * memory files right after every compaction. Conservative: sections are only
 * removed when their non-blank line content is fully identical (blank-line
 * count, trailing whitespace and standalone HTML-comment marker lines are
 * ignored for comparison only; the kept first copy stays verbatim).
 */

const fs = require('fs');
const path = require('path');
const os = require('os');

const HOME = os.homedir();
const OPENCLAW_DIR = path.join(HOME, '.openclaw');
const LOG_FILE = path.join(OPENCLAW_DIR, 'logs', 'memory-flush-dedup.log');
const DAILY_RE = /^\d{4}-\d{2}-\d{2}[-\w]*\.md$/;
const EVENT_MODE_MAX_AGE_MS = 24 * 60 * 60 * 1000;
const BAK_MAX_AGE_MS = 14 * 24 * 60 * 60 * 1000;
const MARKER_RE = /^\s*<!--.*-->\s*$/;

function log(msg) {
  try {
    fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true });
    fs.appendFileSync(LOG_FILE, new Date().toISOString() + ' ' + msg + '\n');
  } catch (e) { /* never throw from logging */ }
}

function memoryDirs() {
  const dirs = [];
  let entries = [];
  try { entries = fs.readdirSync(OPENCLAW_DIR, { withFileTypes: true }); } catch (e) { return dirs; }
  for (const d of entries) {
    if (!d.isDirectory()) continue;
    if (!/^workspace/.test(d.name)) continue;
    const mem = path.join(OPENCLAW_DIR, d.name, 'memory');
    try { if (fs.statSync(mem).isDirectory()) dirs.push(mem); } catch (e) { /* skip */ }
  }
  return dirs;
}

function sectionKey(lines) {
  const parts = [];
  for (const ln of lines) {
    const t = ln.replace(/\r$/, '').trim();
    if (!t) continue;
    if (MARKER_RE.test(t)) continue; // standalone comment markers do not affect identity
    parts.push(t);
  }
  return parts.join('\n');
}

function dedupeText(raw) {
  let bom = '';
  let text = raw;
  if (text.charCodeAt(0) === 0xfeff) { bom = '\uFEFF'; text = text.slice(1); }
  const lines = text.split('\n');

  let firstIdx = -1;
  for (let i = 0; i < lines.length; i++) {
    if (/^## /.test(lines[i].replace(/\r$/, ''))) { firstIdx = i; break; }
  }
  if (firstIdx < 0) return { changed: false, removed: 0, kept: 0, out: null };

  const preamble = lines.slice(0, firstIdx);
  const sections = [];
  let cur = null;
  for (let i = firstIdx; i < lines.length; i++) {
    const stripped = lines[i].replace(/\r$/, '');
    if (/^## /.test(stripped)) {
      if (cur) sections.push(cur);
      cur = [lines[i]];
    } else if (cur) {
      cur.push(lines[i]);
    }
  }
  if (cur) sections.push(cur);

  const seen = new Set();
  const kept = [];
  let removed = 0;
  for (const sec of sections) {
    const key = sectionKey(sec);
    if (key && seen.has(key)) { removed++; continue; }
    if (key) seen.add(key);
    kept.push(sec);
  }
  if (removed === 0) return { changed: false, removed: 0, kept: sections.length, out: null };

  const outLines = preamble.slice();
  for (const sec of kept) for (const ln of sec) outLines.push(ln);
  return { changed: true, removed, kept: kept.length, out: bom + outLines.join('\n') };
}

function backupFile(file) {
  const bakDir = path.join(path.dirname(file), '.bak');
  fs.mkdirSync(bakDir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:T]/g, '-').slice(0, 19);
  const dest = path.join(bakDir, path.basename(file).replace(/\.md$/, '') + '.' + stamp + '.dedup.bak');
  fs.copyFileSync(file, dest);
  return dest;
}

function rotateOldBackups(memDir) {
  try {
    const bakDir = path.join(memDir, '.bak');
    if (!fs.existsSync(bakDir)) return;
    const now = Date.now();
    for (const f of fs.readdirSync(bakDir)) {
      if (!f.endsWith('.dedup.bak')) continue;
      const p = path.join(bakDir, f);
      try {
        if (now - fs.statSync(p).mtimeMs > BAK_MAX_AGE_MS) fs.unlinkSync(p);
      } catch (e) { /* skip */ }
    }
  } catch (e) { /* never throw */ }
}

function processFile(file, opts) {
  const st = fs.statSync(file);
  if (opts.maxAgeMs && (Date.now() - st.mtimeMs > opts.maxAgeMs)) {
    return { file, skipped: 'stale' };
  }
  const raw = fs.readFileSync(file, 'utf8');
  const res = dedupeText(raw);
  if (!res.changed) {
    log((opts.label || 'scan') + ' CLEAN file=' + file);
    return { file, removed: 0, kept: res.kept };
  }
  if (opts.dryRun) {
    log((opts.label || 'scan') + ' DRY file=' + file + ' wouldRemove=' + res.removed);
    return { file, wouldRemove: res.removed, kept: res.kept };
  }
  const bak = backupFile(file);
  fs.writeFileSync(file, res.out, 'utf8');
  log((opts.label || 'scan') + ' DEDUP file=' + file + ' removed=' + res.removed + ' kept=' + res.kept + ' backup=' + bak);
  return { file, removed: res.removed, kept: res.kept, backup: bak };
}

let chain = Promise.resolve(); // in-process mutex (hook runs inside gateway process)

function runAll(opts) {
  const out = [];
  for (const memDir of memoryDirs()) {
    rotateOldBackups(memDir);
    let names = [];
    try { names = fs.readdirSync(memDir).filter((n) => DAILY_RE.test(n)); } catch (e) { continue; }
    for (const n of names) {
      try { out.push(processFile(path.join(memDir, n), opts)); } catch (e) {
        log('ERROR file=' + n + ' ' + (e && e.stack ? e.stack : e));
        out.push({ file: n, error: String(e) });
      }
    }
  }
  return out;
}

async function handler(event) {
  try {
    if (!event || event.type !== 'session' || event.action !== 'compact:after') return;
    const ctx = event.context || {};
    const sessionKey = ctx.sessionKey || 'unknown';
    const work = () => {
      const results = runAll({ maxAgeMs: EVENT_MODE_MAX_AGE_MS, label: 'compact:after', sessionKey });
      const total = results.reduce((a, r) => a + (r.removed || r.wouldRemove || 0), 0);
      log('compact:after DONE session=' + sessionKey + ' files=' + results.length + ' removedSections=' + total);
    };
    chain = chain.then(work, work);
    await chain;
  } catch (e) {
    log('HANDLER_ERROR ' + (e && e.stack ? e.stack : e));
  }
}

function cli() {
  const argv = process.argv.slice(2);
  const dryRun = argv.includes('--dry-run');
  const get = (flag) => { const i = argv.indexOf(flag); return i >= 0 ? argv[i + 1] : null; };
  if (argv.includes('--file')) {
    const f = get('--file');
    if (!f || !fs.existsSync(f)) { console.error('file not found: ' + f); process.exit(1); }
    console.log(JSON.stringify(processFile(path.resolve(f), { label: 'cli-file', dryRun }), null, 2));
    return;
  }
  if (argv.includes('--scan')) {
    const results = runAll({ label: 'cli-scan', dryRun });
    let total = 0;
    for (const r of results) {
      const n = (r.removed !== undefined ? r.removed : r.wouldRemove) || 0;
      total += n;
      const tag = r.removed !== undefined ? 'removed' : (r.wouldRemove !== undefined ? 'wouldRemove' : 'info');
      console.log((r.skipped ? 'SKIP(stale) ' : tag + '=' + n + ' ') + r.file + (r.error ? ' ERROR ' + r.error : ''));
    }
    console.log('TOTAL ' + (dryRun ? 'wouldRemove' : 'removed') + '=' + total + ' files=' + results.length + (dryRun ? ' (dry-run, nothing written)' : ''));
    return;
  }
  console.log('usage: node handler.js --scan [--dry-run] | --file <path> [--dry-run]');
}

if (require.main === module) cli();

module.exports = handler;
module.exports.default = handler;
module.exports.handler = handler;
module.exports.__esModule = true;
