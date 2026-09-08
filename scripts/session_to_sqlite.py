# -*- coding: utf-8 -*-
# session_to_sqlite.py - 会话 JSONL 转换为 SQLite（支持 FTS5 全文检索）
# 调用：python session_to_sqlite.py --session-key KEY --session-file FILE --output-dir DIR [--append]
# 作者：大龙虾
# 版本：v2.1 (2026-09-08)

import json
import sqlite3
import sys
import os
import re
import argparse


# ============================================================================
# T09 安全修复（v2.2）：脱敏 + 数据最小化
#   - 脱敏规则可插拔：同目录下 redact_rules.json 存在时覆盖/追加默认规则
#   - 所有派生字段（keywords/anchor/summary）均从“已脱敏文本”派生
#   - 入库前对每个文本列再做一次最终脱敏
#   - 超长原文掐头去尾（MAX_ARCHIVE_LENGTH），落实数据最小化原则
# ============================================================================

# 本地存档最大字符数（掐头去尾），防止无限制存储
MAX_ARCHIVE_LENGTH = 20000
# 单条消息最大字符数（防止单条巨文本绕过总量限制）
MAX_MESSAGE_CHARS = 8000

DEFAULT_REDACT_RULES = [
    # OpenAI 风格 API Key
    (r'(sk-[a-zA-Z0-9]{20,})', 'sk-[REDACTED]'),
    # GitHub Token
    (r'(gh[pousr]_[a-zA-Z0-9]{20,})', 'gh*_[REDACTED]'),
    # Bearer / Authorization
    (r'(?i)(Bearer\s+)[a-zA-Z0-9\-\._~\+/]+=*', r'\1[REDACTED]'),
    (r'(?i)(authorization\s*:\s*)[^\r\n]+', r'\1[REDACTED]'),
    # 常见密码/密钥字段（值直到空白/分隔符）
    (r'(?i)(password|passwd|secret|pwd|api_key|apikey|access_key|private_key|client_secret)["\'\s:=]+([^\s,;\}"\']+)', r'\1=[REDACTED]'),
    # JWT
    (r'(eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,})', '[JWT_REDACTED]'),
    # AWS Access Key
    (r'(AKIA[0-9A-Z]{16})', '[AWS_KEY_REDACTED]'),
    # Google API Key
    (r'(AIza[0-9A-Za-z_\-]{35})', '[GOOGLE_KEY_REDACTED]'),
    # Slack Token
    (r'(xox[baprs]-[0-9A-Za-z\-]{10,})', '[SLACK_TOKEN_REDACTED]'),
    # PEM 私钥块
    (r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----', '[PRIVATE_KEY_REDACTED]'),
    # 数据库/中间件连接串
    (r'(?i)((?:mysql|postgres|postgresql|mongodb|redis|mssql|amqp|smtp)(?:\+\w+)?://)[^\s"\']+', r'\1[REDACTED]'),
    # Cookie
    (r'(?i)((?:set-)?cookie\s*:\s*)[^\r\n]+', r'\1[REDACTED]'),
    # Webhook（Slack/Discord/Telegram）
    (r'(?i)(https?://[^\s"\']*?(?:hooks\.slack\.com|discord(?:app)?\.com/api/webhooks|api\.telegram\.org/bot)[^\s"\']*)', '[WEBHOOK_REDACTED]'),
    # PII：手机号 / 邮箱
    (r'(?<!\d)(1[3-9]\d{9})(?!\d)', '[PHONE_REDACTED]'),
    (r'([a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,})', '[EMAIL_REDACTED]'),
]


def _load_redact_rules():
    """加载同目录下 redact_rules.json（可选），支持自定义/追加脱敏规则。"""
    rules = list(DEFAULT_REDACT_RULES)
    cfg_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'redact_rules.json')
    if not os.path.isfile(cfg_path):
        return rules
    try:
        with open(cfg_path, 'r', encoding='utf-8') as f:
            cfg = json.load(f)
        custom = cfg.get('custom_redact_rules') or []
        for item in custom:
            pat = item.get('pattern')
            rep = item.get('replace', '[REDACTED]')
            if isinstance(pat, str) and pat:
                rules.append((pat, rep))
    except Exception:
        pass
    return rules


_REDACT_RULES = _load_redact_rules()


def redact_sensitive_info(text):
    """遮蔽常见敏感凭据 / PII 格式（API Key、Token、密码、私钥、连接串、Webhook、手机号、邮箱）"""
    if not text:
        return text
    for pattern, replacement in _REDACT_RULES:
        try:
            text = re.sub(pattern, replacement, text)
        except re.error:
            continue
    return text


def is_high_entropy(word):
    """高熵候选（可能是密钥/哈希）不进入关键词索引。"""
    if len(word) < 24:
        return False
    has_lower = any(c.islower() for c in word)
    has_upper = any(c.isupper() for c in word)
    has_digit = any(c.isdigit() for c in word)
    if has_lower and has_upper and has_digit:
        return True
    # 长十六进制串
    if re.fullmatch(r'[0-9a-fA-F]{32,}', word):
        return True
    return False


def truncate_for_archive(text, limit=MAX_ARCHIVE_LENGTH):
    """数据最小化：超长内容掐头去尾，中间丢弃（保留头尾上下文）。"""
    if text is None or len(text) <= limit:
        return text
    head = text[: limit // 2]
    tail = text[-(limit // 2):]
    dropped = len(text) - limit
    return f"{head}\n\n...[内容因数据最小化原则被截断，中间 {dropped} 字符未保存]...\n\n{tail}"


def redact_file_in_place(path):
    """对给定文件原地脱敏（供轨迹备份复用同一套规则），返回字节数。"""
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        data = f.read()
    redacted = redact_sensitive_info(data)
    tmp = path + '.redact.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write(redacted)
    os.replace(tmp, path)
    return len(redacted)

def main():
    parser = argparse.ArgumentParser(description='Convert session JSONL to SQLite with FTS5')
    parser.add_argument('--session-key', required=False, help='Session key')
    parser.add_argument('--session-file', required=False, help='Path to events.jsonl')
    parser.add_argument('--output-dir', required=False, help='Output directory for SQLite files')
    parser.add_argument('--append', action='store_true', help='Append to existing SQLite file')
    parser.add_argument('--redact-file', help='Redact sensitive data in-place in the given file, then exit')
    args = parser.parse_args()

    # T09 安全修复（v2.2）：轨迹备份脱敏模式
    if args.redact_file:
        try:
            n = redact_file_in_place(args.redact_file)
            print(json.dumps({'status': 'ok', 'mode': 'redact-file', 'bytes': n}))
        except Exception as e:
            print(json.dumps({'status': 'error', 'mode': 'redact-file', 'error': str(e)}))
            sys.exit(1)
        return

    if not (args.session_key and args.session_file and args.output_dir):
        parser.error('--session-key, --session-file and --output-dir are required unless --redact-file is used')

    session_key = args.session_key
    session_file = args.session_file
    output_dir = args.output_dir
    append_mode = args.append

    # Ensure output directory exists
    os.makedirs(output_dir, exist_ok=True)

    # Generate SQLite filename
    safe_key = re.sub(r'[^a-zA-Z0-9_-]', '_', session_key)

    # Use ASCII-safe path for SQLite (avoid Chinese characters in path)
    # Python sqlite3 has issues with non-ASCII paths on Windows
    # Use a fallback ASCII directory if the path contains non-ASCII
    try:
        output_dir.encode('ascii')
    except UnicodeEncodeError:
        # Path contains non-ASCII, use fallback
        ascii_dir = os.path.join(os.path.expanduser('~'), '.openclaw', 'sqlite-data')
        os.makedirs(ascii_dir, exist_ok=True)
        output_dir = ascii_dir

    if append_mode:
        # Find existing SQLite file (first one)
        existing = sorted([f for f in os.listdir(output_dir) if f.startswith(safe_key) and f.endswith('.db')])
        if existing:
            db_path = os.path.join(output_dir, existing[0])
        else:
            from datetime import datetime
            stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
            db_path = os.path.join(output_dir, f'{safe_key}-{stamp}.db')
    else:
        from datetime import datetime
        stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
        db_path = os.path.join(output_dir, f'{safe_key}-{stamp}.db')

    # Find Python executable
    python_exe = 'python'
    if not os.path.exists(python_exe):
        python_exe = sys.executable

    # Create SQLite connection
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    # Enable WAL mode
    cursor.execute('PRAGMA journal_mode = WAL')
    cursor.execute('PRAGMA busy_timeout = 5000')
    cursor.execute('PRAGMA synchronous = NORMAL')

    # Create main table
    cursor.execute('''
    CREATE TABLE IF NOT EXISTS session_chunks (
        chunk_id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_key TEXT NOT NULL,
        start_msg_id INTEGER NOT NULL,
        end_msg_id INTEGER NOT NULL,
        summary TEXT NOT NULL,
        keywords TEXT NOT NULL,
        anchor_questions TEXT NOT NULL DEFAULT '',
        raw_content TEXT NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
    ''')

    # Add anchor_questions column if missing
    try:
        cursor.execute('ALTER TABLE session_chunks ADD COLUMN anchor_questions TEXT NOT NULL DEFAULT ""')
    except:
        pass

    # Create FTS5 virtual table
    cursor.execute('''
    CREATE VIRTUAL TABLE IF NOT EXISTS chunk_fts USING fts5(
        chunk_id UNINDEXED,
        session_key,
        keywords,
        summary,
        anchor_questions,
        raw_content,
        tokenize = 'trigram'
    )
    ''')

    # Create trigger for auto-sync
    cursor.execute('''
    CREATE TRIGGER IF NOT EXISTS after_chunk_insert AFTER INSERT ON session_chunks BEGIN
        INSERT INTO chunk_fts(chunk_id, session_key, keywords, summary, anchor_questions, raw_content)
        VALUES (new.chunk_id, new.session_key, new.keywords, new.summary, new.anchor_questions, new.raw_content);
    END
    ''')

    # Create indexes
    cursor.execute('CREATE INDEX IF NOT EXISTS idx_session_key ON session_chunks(session_key)')
    cursor.execute('CREATE INDEX IF NOT EXISTS idx_created_at ON session_chunks(created_at)')
    try:
        cursor.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_chunk_unique ON session_chunks(session_key, start_msg_id, end_msg_id)')
    except:
        pass

    # Read JSONL
    messages = []
    with open(session_file, 'r', encoding='utf-8') as f:
        for line_num, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                data = json.loads(line)
                msg_type = data.get('type', 'unknown')
                message = data.get('message', {})
                if not message:
                    message = data.get('data', {}).get('message', data.get('data', {}))
                role = message.get('role', 'unknown')
                content = message.get('content', '')
                timestamp = data.get('ts', data.get('timestamp', ''))

                content_text = ''
                has_thinking = 0
                has_tool_calls = 0

                if isinstance(content, str):
                    content_text = content
                elif isinstance(content, list):
                    for item in content:
                        if isinstance(item, dict):
                            if item.get('type') == 'text':
                                content_text += item.get('text', '')
                            elif item.get('type') == 'thinking':
                                has_thinking = 1
                            elif item.get('type') == 'toolCall':
                                has_tool_calls = 1

                if content_text:
                    messages.append({
                        'id': line_num,
                        'role': role,
                        'content': content_text,
                        'timestamp': timestamp,
                        'has_thinking': has_thinking,
                        'has_tool_calls': has_tool_calls
                    })
            except json.JSONDecodeError:
                continue

    # Get max chunk_id for append mode
    max_chunk_id = 0
    if append_mode:
        cursor.execute('SELECT MAX(chunk_id) FROM session_chunks WHERE session_key = ?', (session_key,))
        result = cursor.fetchone()
        if result and result[0]:
            max_chunk_id = result[0]

    # Chunk messages (10 per chunk)
    chunk_size = 10
    for i in range(0, len(messages), chunk_size):
        chunk = messages[i:i+chunk_size]
        if not chunk:
            continue

        start_msg_id = chunk[0]['id']
        end_msg_id = chunk[-1]['id']

        # T09 安全修复（v2.2）：先对整块消息脱敏，再从脱敏后的文本派生一切元数据
        safe_chunk = []
        for msg in chunk:
            safe_msg = dict(msg)
            safe_msg['content'] = truncate_for_archive(
                redact_sensitive_info(msg.get('content', '')), MAX_MESSAGE_CHARS
            )
            safe_chunk.append(safe_msg)

        try:
            roles = set(msg['role'] for msg in safe_chunk)
            has_thinking = any(msg['has_thinking'] for msg in safe_chunk)
            has_tool_calls = any(msg['has_tool_calls'] for msg in safe_chunk)

            summary_parts = []
            if 'user' in roles:
                summary_parts.append('user')
            if 'assistant' in roles:
                summary_parts.append('assistant')
            if has_thinking:
                summary_parts.append('thinking')
            if has_tool_calls:
                summary_parts.append('tool_calls')

            summary = ', '.join(summary_parts) if summary_parts else 'dialogue'

            keywords = set()
            for msg in safe_chunk:
                words = msg['content'].split()
                for word in words:
                    if len(word) > 2 and word.isalnum() and not is_high_entropy(word):
                        keywords.add(word.lower())
            keywords_str = ', '.join(list(keywords)[:5])

            anchor_set = set()
            for msg in safe_chunk:
                content = msg['content']
                for m in re.finditer(r'[a-zA-Z0-9_-]+\.[a-zA-Z]{2,4}', content):
                    anchor_set.add(m.group())
                for m in re.finditer(r'[a-zA-Z_][a-zA-Z0-9_]+\(\)', content):
                    anchor_set.add(m.group())
                for m in re.finditer(r'[\u4e00-\u9fa5]{2,6}', content):
                    anchor_set.add(m.group())
            anchor_questions = ', '.join(list(anchor_set)[:8])
        except Exception as e:
            summary = 'dialogue (metadata error)'
            keywords_str = ''
            anchor_questions = ''

        # 数据最小化：拼装后再次截断（防止多消息累计超限）
        raw_content = '\n'.join([f"[{msg['role']}] {msg['content']}" for msg in safe_chunk])
        raw_content = truncate_for_archive(raw_content, MAX_ARCHIVE_LENGTH)

        # 入库前对每个文本列做最后一道脱敏（防御性双保险）
        summary = redact_sensitive_info(summary)
        keywords_str = redact_sensitive_info(keywords_str)
        anchor_questions = redact_sensitive_info(anchor_questions)
        raw_content = redact_sensitive_info(raw_content)

        cursor.execute('''
            INSERT OR IGNORE INTO session_chunks (session_key, start_msg_id, end_msg_id, summary, keywords, anchor_questions, raw_content)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        ''', (session_key, start_msg_id, end_msg_id, summary, keywords_str, anchor_questions, raw_content))

    conn.commit()
    cursor.execute('PRAGMA wal_checkpoint(TRUNCATE)')

    # Statistics
    cursor.execute('SELECT COUNT(*) FROM session_chunks WHERE session_key = ?', (session_key,))
    total_chunks = cursor.fetchone()[0]
    cursor.execute('SELECT MIN(chunk_id), MAX(chunk_id) FROM session_chunks WHERE session_key = ?', (session_key,))
    min_id, max_id = cursor.fetchone()
    cursor.execute('SELECT MIN(start_msg_id), MAX(end_msg_id) FROM session_chunks WHERE session_key = ?', (session_key,))
    min_msg, max_msg = cursor.fetchone()
    conn.close()

    result = {
        'status': 'ok',
        'db_path': db_path,
        'total_chunks': total_chunks,
        'chunk_id_range': [min_id, max_id],
        'msg_id_range': [min_msg, max_msg],
        'append_mode': append_mode
    }
    print(json.dumps(result, ensure_ascii=False))

if __name__ == '__main__':
    main()
