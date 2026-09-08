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

// T09 安全修复：脚本路径基于 __dirname 解析（与 handler.js 同目录），
// 不依赖可变的 PATH 或用户目录推断；部署时 pipeline.ps1 必须与本文件同目录。
const PIPELINE_SCRIPT = path.join(__dirname, 'pipeline.ps1');
// 兼容旧部署：pipeline.ps1 位于 ~/.openclaw/hooks/compaction-pipeline/
const PIPELINE_SCRIPT_FALLBACK = path.join(
    os.homedir(), '.openclaw', 'hooks', 'compaction-pipeline', 'pipeline.ps1'
);

// 信任边界校验：仅接受存在且非空的可信目录内的脚本
function resolvePipelineScript() {
    const fs = require('fs');
    for (const candidate of [PIPELINE_SCRIPT, PIPELINE_SCRIPT_FALLBACK]) {
        try {
            const st = fs.statSync(candidate);
            if (st.isFile() && st.size > 0) return candidate;
        } catch (_) {}
    }
    return null;
}

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

    const script = resolvePipelineScript();
    if (!script) {
        log(`HOOK_${phase.toUpperCase()}: pipeline.ps1 not found in trusted dir`);
        return Promise.resolve();
    }

    return new Promise((resolve) => {
        try {
            const child = spawn('powershell.exe', [
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
