const { spawn } = require('child_process');
const path = require('path');
const os = require('os');

/**
 * Compaction Pipeline Hook
 * Runs backup/SQLite/enhanced-summary around every compaction event.
 *
 * Before compaction: export trajectory → convert to SQLite (preserves full history)
 * After compaction:  run enhanced summary on SQLite DB
 */

const PIPELINE_SCRIPT = path.join(
    os.homedir(), '.openclaw', 'hooks', 'compaction-pipeline', 'pipeline.ps1'
);

// T06 安全修复：日志使用 LOCALAPPDATA 而非暴露 home 目录结构
const LOG_DIR = process.env.LOCALAPPDATA
    ? path.join(process.env.LOCALAPPDATA, '.openclaw', 'logs')
    : path.join(os.homedir(), '.openclaw', 'logs');
const LOG_FILE = path.join(LOG_DIR, 'compaction-pipeline.log');

function log(msg) {
    const ts = new Date().toISOString().replace('T', ' ').substring(0, 19);
    const line = `${ts} ${msg}\n`;
    try {
        require('fs').appendFileSync(LOG_FILE, line, 'utf8');
    } catch (_) {}
}

function runPipeline(sessionKey, phase) {
    if (!sessionKey) {
        log(`HOOK_${phase.toUpperCase()}: skipped (no sessionKey)`);
        return Promise.resolve();
    }

    log(`HOOK_${phase.toUpperCase()}: triggering for ${sessionKey}`);

    return new Promise((resolve) => {
        try {
            const child = spawn('powershell.exe', [
                '-NoProfile',
                '-File', PIPELINE_SCRIPT,
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
