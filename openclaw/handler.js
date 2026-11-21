const { spawn } = require('child_process');
const path = require('path');
const os = require('os');
const fs = require('fs');
const crypto = require('crypto');

/**
 * Compaction Pipeline Hook
 * Runs backup / SQLite conversion / enhanced summary around every compaction event.
 *
 * Before compaction: export trajectory -> redact -> convert to SQLite (full history preserved)
 * After compaction:  run enhanced summary on the SQLite DB
 *
 * Security model (declared in SKILL.md):
 *   - The pipeline script is resolved from this file's own directory (trusted, not PATH-derived)
 *     or the legacy hook directory. Its bytes are verified against integrity.json before execution.
 *   - PowerShell is launched from its absolute System32 path; no shell, no string interpolation,
 *     arguments are passed as an array.
 *   - The hook only ever runs on compaction events; it never touches the network.
 */

// --- Trusted script resolution -------------------------------------------------
const HOME = process.env.USERPROFILE || os.homedir();
const PIPELINE_SCRIPT = path.join(__dirname, 'pipeline.ps1');
const PIPELINE_SCRIPT_FALLBACK = path.join(HOME, '.openclaw', 'hooks', 'compaction-pipeline', 'pipeline.ps1');
const INTEGRITY_MANIFEST = path.join(__dirname, 'integrity.json');

// The real pipeline script must begin with this marker; anything else is not ours.
const PIPELINE_MARKER = '# compaction-pipeline.ps1';

// PowerShell is always launched from its absolute location - never resolved through PATH.
const POWERSHELL_EXE = path.join(
    process.env.SystemRoot || 'C:\\Windows',
    'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'
);

// Session keys and phases accepted at this process boundary.
const SESSION_KEY_RE = /^[A-Za-z0-9:_\-.]{1,200}$/;
const PHASES = new Set(['before', 'after']);

// --- Logging (LOCALAPPDATA, no home-directory structure leaked) -----------------
const LOG_DIR = process.env.LOCALAPPDATA
    ? path.join(process.env.LOCALAPPDATA, '.openclaw', 'logs')
    : path.join(HOME, '.openclaw', 'logs');
const LOG_FILE = path.join(LOG_DIR, 'compaction-pipeline.log');
let logDirReady = false;

function log(msg) {
    const ts = new Date().toISOString().replace('T', ' ').substring(0, 19);
    const line = `${ts} ${msg}\n`;
    try {
        if (!logDirReady) {
            fs.mkdirSync(LOG_DIR, { recursive: true });
            logDirReady = true;
        }
        fs.appendFileSync(LOG_FILE, line, 'utf8');
    } catch (_) {}
}

// --- Integrity verification -----------------------------------------------------
function sha256(file) {
    return 'sha256:' + crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function verifyIntegrity(scriptPath) {
    try {
        if (!fs.existsSync(INTEGRITY_MANIFEST)) {
            log('INTEGRITY_MANIFEST_MISSING: refusing to execute pipeline '
                + '(regenerate with scripts/update-integrity.ps1)');
            return false;
        }
        const manifest = JSON.parse(fs.readFileSync(INTEGRITY_MANIFEST, 'utf8'));
        const expected = manifest && manifest['pipeline.ps1'];
        if (typeof expected !== 'string' || !expected.startsWith('sha256:')) {
            log('INTEGRITY_MANIFEST_INVALID: missing pipeline.ps1 digest');
            return false;
        }
        const actual = sha256(scriptPath);
        if (actual !== expected) {
            log(`INTEGRITY_FAIL: pipeline.ps1 digest mismatch (expected ${expected}, got ${actual}) `
                + '- refusing to execute');
            return false;
        }
        return true;
    } catch (err) {
        log(`INTEGRITY_ERR: ${err.message} - refusing to execute`);
        return false;
    }
}

// --- Trusted script resolution --------------------------------------------------
function resolvePipelineScript() {
    for (const candidate of [PIPELINE_SCRIPT, PIPELINE_SCRIPT_FALLBACK]) {
        try {
            const st = fs.lstatSync(candidate);
            if (!st.isFile() || st.isSymbolicLink() || st.size <= 0) continue;
            const head = fs.readFileSync(candidate, 'utf8').slice(0, 200);
            if (!head.includes(PIPELINE_MARKER)) {
                log(`PIPELINE_MARKER_MISSING: ${candidate}`);
                continue;
            }
            return candidate;
        } catch (_) {}
    }
    return null;
}

function runPipeline(sessionKey, phase) {
    if (!sessionKey || !SESSION_KEY_RE.test(sessionKey)) {
        log(`HOOK_${String(phase).toUpperCase()}: skipped (invalid or missing sessionKey)`);
        return Promise.resolve();
    }
    if (!PHASES.has(phase)) {
        log(`HOOK_HANDLER: skipped (unexpected phase ${phase})`);
        return Promise.resolve();
    }

    log(`HOOK_${phase.toUpperCase()}: triggering for ${sessionKey}`);

    const script = resolvePipelineScript();
    if (!script) {
        log(`HOOK_${phase.toUpperCase()}: pipeline.ps1 not found in a trusted directory`);
        return Promise.resolve();
    }
    if (!verifyIntegrity(script)) {
        return Promise.resolve();
    }
    if (!fs.existsSync(POWERSHELL_EXE)) {
        log(`HOOK_${phase.toUpperCase()}: powershell.exe not found at ${POWERSHELL_EXE}`);
        return Promise.resolve();
    }

    return new Promise((resolve) => {
        try {
            const child = spawn(POWERSHELL_EXE, [
                '-NoProfile',
                '-NonInteractive',
                '-File', script,
                '-SessionKey', sessionKey,
                '-Phase', phase
            ], {
                detached: false,
                stdio: 'ignore',
                windowsHide: true
            });

            child.on('error', (err) => {
                log(`HOOK_${phase.toUpperCase()}_SPAWN_ERR: ${sessionKey} ${err.message}`);
                resolve();
            });

            child.on('exit', (code) => {
                log(`HOOK_${phase.toUpperCase()}_EXIT: ${sessionKey} code=${code}`);
                resolve();
            });
        } catch (err) {
            log(`HOOK_${phase.toUpperCase()}_EXCEPTION: ${sessionKey} ${err.message}`);
            resolve();
        }
    });
}

const handler = async (event) => {
    try {
        const context = event.context || {};
        const sessionKey = context.sessionKey;

        if (event.type === 'session' && event.action === 'compact:before') {
            runPipeline(sessionKey, 'before');
            return;
        }

        if (event.type === 'session' && event.action === 'compact:after') {
            runPipeline(sessionKey, 'after');
            return;
        }
    } catch (error) {
        log(`HOOK_HANDLER_ERR: ${error instanceof Error ? error.message : String(error)}`);
    }
};

module.exports = handler;
module.exports.default = handler;
module.exports.handler = handler;
module.exports.__esModule = true;
