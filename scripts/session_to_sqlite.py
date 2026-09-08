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

def main():
    parser = argparse.ArgumentParser(description='Convert session JSONL to SQLite with FTS5')
    parser.add_argument('--session-key', required=True, help='Session key')
    parser.add_argument('--session-file', required=True, help='Path to events.jsonl')
    parser.add_argument('--output-dir', required=True, help='Output directory for SQLite files')
    parser.add_argument('--append', action='store_true', help='Append to existing SQLite file')
    args = parser.parse_args()

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

        try:
            roles = set(msg['role'] for msg in chunk)
            has_thinking = any(msg['has_thinking'] for msg in chunk)
            has_tool_calls = any(msg['has_tool_calls'] for msg in chunk)

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
            for msg in chunk:
                words = msg['content'].split()
                for word in words:
                    if len(word) > 2 and word.isalnum():
                        keywords.add(word.lower())
            keywords_str = ', '.join(list(keywords)[:5])

            anchor_set = set()
            for msg in chunk:
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

        # Full original content (no truncation)
        raw_content = '\n'.join([f"[{msg['role']}] {msg['content']}" for msg in chunk])

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
