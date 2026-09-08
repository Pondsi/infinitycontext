# InfinityContext

**Open-Source Context Compression & Memory Optimization for AI Agents — DeepSeek Harness (dsh), Claude Code, OpenClaw, Cursor, Dify, Ollama and any Agent Skills host**

[English](#english) | [简体中文](#简体中文) | [繁體中文](#繁體中文) | [日本語](#日本語) | [한국어](#한국어) | [Español](#español) | [Português](#português) | [Français](#français) | [Deutsch](#deutsch) | [Русский](#русский)

---

> ⚠️ **Security & Privacy Disclosure — Intended Behavior / 安全与隐私披露（预期行为）**
>
> **EN** — InfinityContext is a **local persistent store and lifecycle manager** for agent
> sessions. By design it performs these local operations:
>
> | Operation | Tool | Scope control |
> |-----------|------|---------------|
> | Persist redacted conversation chunks in a local SQLite/FTS5 archive | `session_to_sqlite.py` | owner-only directory (`0700`/`0600`, or a protected DACL), fail-closed |
> | **Permanently delete** expired archive files | `cleanup.py` | verified `.infinity-context-archive` marker + full-filename allowlist + non-recursive + `--apply --confirm-destructive` |
> | **Rewrite a file in place** (redaction) | `session_to_sqlite.py --redact-file` | requires `--allow-dir`; the symlink-resolved path must stay inside it |
> | Move the archive when the path is not ASCII-safe | `session_to_sqlite.py` | refused unless `--allow-dir-fallback` is given |
>
> Redaction is best-effort and the archive still holds a detailed record of your sessions.
> Nothing is sent anywhere — no cloud sync, no telemetry, no outbound network. Keep the
> archive out of synced or shared folders and run cleanup deliberately.
> **Installing this skill means accepting these local persistence and file-mutation
> capabilities.**
>
> **中文** — 本插件是**本地持久化存储与生命周期管理器**，按设计会执行以下本地操作：
>
> | 操作 | 工具 | 范围控制 |
> |------|------|----------|
> | 把脱敏后的对话片段持久化到本地 SQLite/FTS5 | `session_to_sqlite.py` | 目录 0700 / 文件 0600（Windows 为受保护 DACL），Fail-Closed |
> | **永久删除**过期归档文件 | `cleanup.py` | 必须存在 `.infinity-context-archive` 归档标记 + 完整文件名白名单 + 不递归 + `--apply --confirm-destructive` |
> | **就地改写**文件（脱敏） | `session_to_sqlite.py --redact-file` | 必须指定 `--allow-dir`，解析符号链接后仍须落在该目录内 |
> | 路径非 ASCII 时改存其它目录 | `session_to_sqlite.py` | 默认拒绝，需显式 `--allow-dir-fallback` |
>
> 脱敏是尽力而为，归档仍保留会话的详细记录；不联网、不上传、无遥测。请把归档放在
> **非同步、非共享**目录，并谨慎执行清理。**安装即表示你接受上述本地持久化与文件修改能力。**

## Permissions / 权限声明

Declared capability scope (mirrors the Agent Skills `allowed-tools` field):

| Capability | Used for |
|-----------|----------|
| Shell / process | Launching the `openclaw` CLI and PowerShell helpers (argument arrays only — no shell string interpolation) |
| File read | Reading session trajectory JSONL and local config files |
| File write | Writing the SQLite archive, logs, and redacted trajectory backups under `%LOCALAPPDATA%` / `%USERPROFILE%` |
| Environment | Reading `LOCALAPPDATA`, `USERPROFILE`, and `INFINITY_CONTEXT_AGENTS` |

**Not declared because not used: network, MCP.** No data leaves the machine.

> **Registry package note**: ClawHub and similar registries reject packages that contain self-executing JavaScript, so this package ships **no `.js` files**. The optional OpenClaw compaction hook (`openclaw/handler.js`, `openclaw/HOOK.md`, `openclaw/integrity.json`) is distributed in the **GitHub repository only**. Everything in this package runs as scripts that the agent invokes through its declared tools.

When you install that hook from the GitHub repository, it launches exactly one subprocess: `pipeline.ps1`, resolved from the hook's own directory (never from `PATH`), verified against `integrity.json` (SHA-256) before execution, and run through the absolute `System32` path of `powershell.exe` with an argument array. No shell, no string interpolation, no `-Command`.

## English

### What is this?

InfinityContext is a **portable AI-agent skill** (a standard `SKILL.md` bundle) that keeps long sessions usable: it compresses context, archives **redacted** conversation chunks into a **local** SQLite/FTS5 store, and retrieves exact details from an earlier turn. It runs on **any Agent Skills host** — first-class support for **DeepSeek Harness (dsh)** (drop it into `.agents/skills/` and the harness discovers it) — plus Claude Code, OpenClaw, Cursor, Dify, Ollama and custom agents.

> **Scope, stated plainly.** This package is the portable Python core. It reads a session transcript, writes a local archive, and answers searches. It has **no network access, no shell, no subprocesses and no background service**. Everything it can do to your files is listed in the disclosure table at the top of `SKILL.md`.

### What it does

| Step | Script | What happens |
|------|--------|--------------|
| Archive | `scripts/session_to_sqlite.py` | transcript (JSONL) → redacted chunks in a local SQLite DB with an FTS5 index |
| Retrieve | `scripts/search.py` | read-only FTS5 search (trigram, with `LIKE` fallback for short CJK queries) |
| Prune | `scripts/cleanup.py` | retention cleanup of archive files; dry-run by default |
| Protect | `scripts/secure_fs.py` | owner-only permissions for the archive directory, database and WAL sidecars |

> **File operations this package performs** (full detail in the disclosure table at the top of `SKILL.md`):
>
> | Operation | Tool | Guard |
> |-----------|------|-------|
> | Write redacted chunks into a local archive | `session_to_sqlite.py` | owner-only permissions, fail-closed |
> | **Permanently delete** expired archive files | `cleanup.py` | archive marker + full-filename allowlist + non-recursive + `--apply --confirm-destructive` |
> | Rewrite a file in place (redaction) | `session_to_sqlite.py --redact-file` | requires `--allow-dir`; symlink-resolved path must stay inside it |
> | Move the archive when the path is not ASCII-safe | `session_to_sqlite.py` | **refused** unless `--allow-dir-fallback` is given |

### Retention policy (read this once)

| Setting | Value | Notes |
|---------|-------|-------|
| Default retention | **30 days** | chunks older than 30 days are purged on every run, in the same transaction as the insert |
| Configurable range | `1..3650` days | `--retention-days N` |
| No time limit | **opt-in only** | `--retention-days 0` is rejected unless `--allow-unbounded-retention` is also given |
| Manual pass | `--purge-only --output-dir <dir>` | applies the same policy to existing archives, without ingesting |
| Off switch | `INFINITY_CONTEXT_NO_ARCHIVE=1` | the archiver writes nothing and returns `status: disabled` |

Retention is enforced by code, not by documentation: every run deletes expired chunks from `session_chunks` and its FTS mirror and reports the count as `purged_chunks`.

### Quick start (5 minutes)

**Prerequisite: Python 3.9+.** No Node.js, no build step, no network access.

```bash
# 1. Install (registry — a scanned artifact)
clawhub install infinitycontext --workdir ~/.agents --dir skills   # dsh / Claude Code
clawhub install infinitycontext --workdir ~/.openclaw --dir skills  # OpenClaw

# 2. Archive a transcript
python3 scripts/session_to_sqlite.py \
  --session-key my-session \
  --session-file ~/path/to/events.jsonl \
  --output-dir ~/.infinity-context/archive

# 3. Retrieve a detail later (read-only)
python3 scripts/search.py --db ~/.infinity-context/archive/my-session-*.db --query "deployment token"

# 4. Prune archive files (dry-run first)
python3 scripts/cleanup.py --archive-dir ~/.infinity-context/archive --dry-run
```

**From source** — pin the reviewed tag and verify every byte:

```bash
git clone https://github.com/Pondsi/infinitycontext.git
cd infinitycontext
git checkout --detach v1.8.3
grep -q '^version: "1.8.3"' SKILL.md || { echo "tag/version mismatch - stop"; exit 1; }
sha256sum -c checksums.txt          # macOS: shasum -a 256 -c checksums.txt
```

Then place the verified files into your skills directory exactly as listed in
[`references/architecture.md`](references/architecture.md#file-layout) — the list is explicit, so no wildcard and no `cp -r` is ever needed.

### Where to install

| Host | Location | Notes |
|------|----------|-------|
| DeepSeek Harness (dsh) | `~/.agents/skills/infinity-context/` or `<project>/.agents/skills/infinity-context/` | a skill is one level deep (`<root>/<dir>/SKILL.md`); nested `**/SKILL.md` is deliberately not discovered |
| OpenClaw | `<workspace>/skills/` (highest precedence) or `~/.openclaw/skills/` | discovered automatically |
| Claude Code | `~/.claude/skills/infinity-context/` | same layout |
| Cursor / Dify / Ollama / custom | point the agent at this folder | pure Python standard library |

### Requirements

- Any host that loads a standard `SKILL.md`: dsh, Claude Code, OpenClaw, Cursor, Dify, Ollama or a custom agent.
- **Python 3.9+ only.** The core contains no JavaScript, no PowerShell, no subprocesses and no network code.
- An optional OpenClaw/Windows integration lives in the **repository** under `openclaw/` and is **not** part of this package.

### FAQ

**Where is my data?** In the directory passed as `--output-dir` (default `~/.infinity-context/archive`): a SQLite database plus `-wal`/`-shm` sidecars, owner-only permissions.

**How do I stop archiving completely?** Set `INFINITY_CONTEXT_NO_ARCHIVE=1`; the archiver writes nothing and returns `status: disabled`.

**How do I keep less history?** `--retention-days 7` — expired chunks are deleted on the next run. `--purge-only --output-dir <dir>` applies it immediately without ingesting anything.

**Is anything sent anywhere?** No. There is no network code in the package.

**What about secrets in the transcript?** Redaction runs before anything is stored (API keys, tokens, passwords, JWTs, private keys, connection strings, cookies, webhooks, phone numbers, emails). It is best-effort — treat the archive as sensitive data.

**Why is my non-ASCII output path refused?** SQLite on Windows cannot use it. The run aborts with exit 8; `--allow-dir-fallback` moves the archive to `~/.openclaw/sqlite-data` and reports the change instead of doing it silently.

### Issues & discussions

- **Bug reports**: <https://github.com/Pondsi/infinitycontext/issues>
- **Questions and ideas**: <https://github.com/Pondsi/infinitycontext/discussions>

### Sponsors

If you find this project helpful, consider supporting its development! See [SPONSORS.md](SPONSORS.md) for donation options.

### License

MIT License with a **mandatory attribution requirement**: using all or part of the
source, including modified variants, is permitted — but **Pondsi must always be
credited as the original author**. See [LICENSE](LICENSE).

---

## 简体中文

### 这是什么？

InfinityContext 是一个**可移植的 AI 智能体技能**（标准 `SKILL.md` 包）：压缩上下文、把**脱敏后**的对话片段写入**本地** SQLite/FTS5 归档，并可按需精确检索任意早期细节。它可运行在**任何支持 Agent Skills 的宿主**上——**原生支持 DeepSeek Harness（dsh）**（放进 `.agents/skills/` 即被发现），同样支持 Claude Code、OpenClaw、Cursor、Dify、Ollama 及自研 Agent。

> **边界说明（说清楚）**：本包只包含可移植的 Python 核心——读取会话轨迹、写入本地归档、提供检索。**不联网、不调用 shell、不启动子进程、不常驻后台**。它对文件能做的全部操作，都列在 `SKILL.md` 顶部的能力披露表里。

### 它做什么

| 步骤 | 脚本 | 说明 |
|------|------|------|
| 归档 | `scripts/session_to_sqlite.py` | 会话轨迹（JSONL）→ 脱敏片段写入本地 SQLite + FTS5 索引 |
| 检索 | `scripts/search.py` | 只读 FTS5 搜索（三元组；短中文词回退 `LIKE`） |
| 清理 | `scripts/cleanup.py` | 归档文件按保留期清理，默认演练模式 |
| 保护 | `scripts/secure_fs.py` | 归档目录/数据库/WAL 旁文件强制 owner-only 权限 |

> **本包会执行的文件操作**（完整披露见 `SKILL.md` 顶部表格）：
>
> | 操作 | 工具 | 约束 |
> |------|------|------|
> | 把脱敏片段写入本地归档 | `session_to_sqlite.py` | owner-only 权限，Fail-Closed |
> | **永久删除**过期归档文件 | `cleanup.py` | 归档标记 + 完整文件名白名单 + 不递归 + `--apply --confirm-destructive` |
> | 就地改写文件（脱敏） | `session_to_sqlite.py --redact-file` | 必须 `--allow-dir`；符号链接解析后的路径必须仍在范围内 |
> | 路径非 ASCII 时移动归档 | `session_to_sqlite.py` | 默认**拒绝**，需显式 `--allow-dir-fallback` |

### 保留期策略（看一次就够）

| 设置 | 取值 | 说明 |
|------|------|------|
| 默认保留 | **30 天** | 每次运行都会在同一事务内清理超过 30 天的片段 |
| 可配置范围 | `1..3650` 天 | `--retention-days N` |
| 不限时间 | **必须显式开启** | `--retention-days 0` 会被拒绝，除非同时给出 `--allow-unbounded-retention` |
| 手动清理 | `--purge-only --output-dir <目录>` | 对既有归档执行同一策略，不摄入新数据 |
| 彻底关闭 | `INFINITY_CONTEXT_NO_ARCHIVE=1` | 归档器不写任何文件，返回 `status: disabled` |

保留期是**代码强制**而非文档承诺：每次运行都会删除 `session_chunks` 及其 FTS 镜像中的过期片段，并在结果中返回 `purged_chunks`。

### 快速上手（5 分钟）

**前置条件：Python 3.9+**。不需要 Node.js、不需要构建、不需要联网。

```bash
# 1. 安装（注册表，已扫描产物）
clawhub install infinitycontext --workdir ~/.agents --dir skills   # dsh / Claude Code
clawhub install infinitycontext --workdir ~/.openclaw --dir skills  # OpenClaw

# 2. 归档一份会话轨迹
python3 scripts/session_to_sqlite.py \
  --session-key my-session \
  --session-file ~/path/to/events.jsonl \
  --output-dir ~/.infinity-context/archive

# 3. 以后精确检索（只读）
python3 scripts/search.py --db ~/.infinity-context/archive/my-session-*.db --query "部署令牌"

# 4. 清理归档文件（先演练）
python3 scripts/cleanup.py --archive-dir ~/.infinity-context/archive --dry-run
```

**源码安装**——固定已审计 tag 并逐文件校验：

```bash
git clone https://github.com/Pondsi/infinitycontext.git
cd infinitycontext
git checkout --detach v1.8.3
grep -q '^version: "1.8.3"' SKILL.md || { echo "tag/version mismatch - stop"; exit 1; }
sha256sum -c checksums.txt          # macOS：shasum -a 256 -c checksums.txt
```

随后按 [`references/architecture.md`](references/architecture.md#file-layout) 列出的文件清单逐文件放入技能目录——清单是显式的，不需要通配符，也不需要 `cp -r`。

### 安装到哪

| 宿主 | 位置 | 说明 |
|------|------|------|
| DeepSeek Harness（dsh） | `~/.agents/skills/infinity-context/` 或 `<项目>/.agents/skills/infinity-context/` | 技能是**一层深的目录包**（`<root>/<dir>/SKILL.md`）；嵌套 `**/SKILL.md` 故意不被发现 |
| OpenClaw | `<工作区>/skills/`（优先级最高）或 `~/.openclaw/skills/` | 自动发现 |
| Claude Code | `~/.claude/skills/infinity-context/` | 同样的目录结构 |
| Cursor / Dify / Ollama / 自研 | 让 Agent 指向本目录 | 纯 Python 标准库 |

### 系统要求

- 任意支持标准 `SKILL.md` 的宿主：dsh、Claude Code、OpenClaw、Cursor、Dify、Ollama 或自研 Agent。
- **只需 Python 3.9+**。核心**不含任何 JavaScript、PowerShell，不启动子进程，也没有网络代码**。
- 可选的 OpenClaw/Windows 自动化（钩子 + 看门狗）位于**仓库** `openclaw/` 目录，**不属于本包**。

### 常见问题

**数据存在哪？** 在你传入的 `--output-dir`（默认 `~/.infinity-context/archive`）：一个 SQLite 数据库及其 `-wal`/`-shm` 旁文件，owner-only 权限。

**怎么彻底停止归档？** 设置 `INFINITY_CONTEXT_NO_ARCHIVE=1`，归档器不写任何文件并返回 `status: disabled`。

**怎么只保留更少历史？** `--retention-days 7`，下次运行即删除超期片段；`--purge-only --output-dir <目录>` 可立即执行且不摄入新数据。

**数据会外传吗？** 不会。包内没有任何网络代码。

**轨迹里的密钥怎么办？** 脱敏在写入之前完成（API Key、Token、密码、JWT、私钥、连接串、Cookie、Webhook、手机号、邮箱），但它是尽力而为——请把归档当作敏感数据。

**为什么我的非 ASCII 路径被拒绝？** Windows 上的 SQLite 无法使用该路径。运行会以退出码 8 中止；`--allow-dir-fallback` 会把归档改到 `~/.openclaw/sqlite-data`，并如实上报，绝不静默改道。

### 问题与讨论

- **提交 Bug**：<https://github.com/Pondsi/infinitycontext/issues>
- **提问与想法**：<https://github.com/Pondsi/infinitycontext/discussions>

### 安全与隐私

- **纯本地**：无网络请求、无遥测、无云同步。
- **无 shell、无子进程**：核心脚本从不启动其它程序；Windows ACL 使用进程内 Win32 安全 API。
- **归档仅本人可读，Fail-Closed**：POSIX `0700`/`0600`；Windows 受保护 DACL；加固后回读校验；无法强制 owner-only 时中止并销毁半成品（退出码 3）。
- **脱敏 Fail-Closed**：规则启动期校验并预编译，任何失败都在建库之前中止；`session_key` 在生成任何路径/文件名之前先净化。
- **保留期有界**：默认 30 天，范围 `1..3650`，无限期保留需显式 `--allow-unbounded-retention`。
- **清理需二次确认**：`cleanup.py` 只清理带 `.infinity-context-archive` 标记的目录，必须同时给出 `--apply --confirm-destructive`，不递归，通用 `.json`/`.tmp`/`.bak` 永不删除。

### 许可证

MIT 许可证（附**强制署名条款**）：允许使用全部或部分源码（含修改后的变体），但**必须标注
Pondsi 的署名**。详见 [LICENSE](LICENSE)。

---

## 繁體中文

### 這是什麼？

InfinityContext 是一個 AI Agent Skill，解決小模型（128K 上下文）對話中上下文溢出的問題。透過多層壓縮機制，讓任何大小的模型都能持續對話而不中斷。

### 功能特性

- **宿主無關**：可搭配宿主提供的任何壓縮流程（手動或自動）
- **自動備份**：每次壓縮前導出完整軌跡
- **SQLite + FTS5 搜尋**：壓縮後的會話可透過三元組索引搜尋
- **去重機制**：5 分鐘視窗避免重複備份
- **全覆蓋壓縮路徑**：手動、自動壓縮、看門狗全部覆蓋

### 快速開始

> **安裝 / Install**: `clawhub install infinitycontext` — full steps in [Quick Start](#quick-start) above. The archive keeps a bounded 30-day window by default.

### 安全性與隱私

- **純本機**：無網路請求、無遙測、無雲端同步，資料只留在本機。
- **壓縮前先匯出**：每次壓縮前匯出完整會話軌跡，並把去識別化後的對話片段寫入本機 SQLite/FTS5 封存（可全文檢索）。
- **去識別化 + 資料最小化**：正則規則遮蔽 API Key / Token / 密碼 / JWT / 私鑰 / 連線字串 / 手機號 / 電子郵件，高熵內容不進索引；過長內容依 `MAX_ARCHIVE_LENGTH` 掐頭去尾。
- **Fail-Closed**：去識別化無法執行時直接銷毀備份，絕不保留明文。
- **權限與保留**：備份目錄 ACL 收緊為「目前使用者 + SYSTEM」，預設保留 30 天後自動清理。
- **清理需二次確認**：`cleanup.py` 只清理帶 `.infinity-context-archive` 標記的目錄，必須同時給出 `--apply --confirm-destructive`；一般 `.json`/`.tmp`/`.bak` 檔案永不刪除。
- **完整性校驗**：壓縮鉤子執行前以 `integrity.json` 校驗 `pipeline.ps1`。

### 許可證

MIT 许可证（附**强制署名条款**）：允许使用全部或部分源码（含修改后的变体），但**必须标注
Pondsi 的署名**。详见 [LICENSE](LICENSE)。

---

## 日本語

### これは何？

InfinityContext は、小規模モデル（128K コンテキスト）のコンテキストオーバーフローを防止する AI Agent Skill です。多層圧縮、自動バックアップ、FTS5 検索で会話を途切れなく維持します。

### 機能

- **多層保護**：設定 → パイプライン → Hook → メモリ
- **自動バックアップ**：圧縮前に完全な軌跡をエクスポート
- **SQLite + FTS5 検索**：圧縮セッションをトライグラムインデックスで検索
- **重複排除**：5分ウィンドウで重複バックアップを防止

### クイックスタート

```bash
# Registry install (scanned artifact, no git, no build step)
clawhub install infinitycontext --workdir ~/.agents --dir skills
# From source: pin the reviewed release tag and verify checksums.txt - see "Quick Start" above
```

### セキュリティとプライバシー

- **完全ローカル**：ネットワーク通信・テレメトリ・クラウド同期は一切なし。データは端末内にのみ保存されます。
- **圧縮前に完全エクスポート**：圧縮のたびにセッション軌跡全体をエクスポートし、秘匿化した会話断片をローカルの SQLite/FTS5 アーカイブ（全文検索可能）に書き込みます。
- **秘匿化とデータ最小化**：正規表現で API キー / トークン / パスワード / JWT / 秘密鍵 / 接続文字列 / 電話番号 / メールをマスクし、高エントロピー値は索引から除外。長すぎる内容は `MAX_ARCHIVE_LENGTH` で頭と末尾のみ保持します。
- **Fail-Closed**：秘匿化を実行できない場合はバックアップを破棄し、平文を残しません。
- **権限と保持期間**：バックアップの ACL は「現在のユーザー + SYSTEM」に限定。既定で 30 日後に自動削除されます。
- **削除には二段階の確認が必要**：`cleanup.py` は `.infinity-context-archive` マーカーのあるディレクトリだけを対象とし、`--apply --confirm-destructive` の同時指定を必須とします。汎用の `.json`/`.tmp`/`.bak` は決して削除しません。
- **完全性検証**：圧縮フックは実行前に `integrity.json` で `pipeline.ps1` を検証します。

### ライセンス

MIT 许可证（附**强制署名条款**）：允许使用全部或部分源码（含修改后的变体），但**必须标注
Pondsi 的署名**。详见 [LICENSE](LICENSE)。

---

## 한국어

### 이것은 무엇인가?

InfinityContext는 소규모 모델(128K 컨텍스트)의 컨텍스트 오버플로우를 방지하는 AI Agent Skill입니다. 다층 압축, 자동 백업, FTS5 검색으로 대화를 끊김 없이 유지합니다.

### 기능

- **다층 보호**: 설정 → 파이프라인 → Hook → 메모리
- **자동 백업**: 압缩 전 완전한轨迹 내보내기
- **SQLite + FTS5 검색**: 압축 세션을 트리그램 인덱스로 검색
- **중복 제거**: 5분 윈도우로 중복 백업 방지

### 빠른 시작

```bash
# Registry install (scanned artifact, no git, no build step)
clawhub install infinitycontext --workdir ~/.agents --dir skills
# From source: pin the reviewed release tag and verify checksums.txt - see "Quick Start" above
```

### 보안 및 개인정보

- **완전 로컬**: 네트워크 요청·텔레메트리·클라우드 동기화가 없습니다. 데이터는 이 컴퓨터에만 남습니다.
- **압축 전 전체 내보내기**: 압축할 때마다 세션 전체 기록을 내보내고, 마스킹된 대화 조각을 로컬 SQLite/FTS5 아카이브(전문 검색 가능)에 기록합니다.
- **마스킹 및 데이터 최소화**: 정규식으로 API 키 / 토큰 / 비밀번호 / JWT / 개인 키 / 연결 문자열 / 전화번호 / 이메일을 가리고, 엔트로피가 높은 값은 색인에서 제외합니다. 지나치게 긴 내용은 `MAX_ARCHIVE_LENGTH`로 앞뒤만 보관합니다.
- **Fail-Closed**: 마스킹을 실행할 수 없으면 백업을 파기하며 평문을 남기지 않습니다.
- **권한 및 보존**: 백업 ACL은 "현재 사용자 + SYSTEM"으로 제한되며 기본 30일 후 자동 삭제됩니다.
- **삭제에는 2단계 확인**: `cleanup.py`는 `.infinity-context-archive` 마커가 있는 디렉터리만 대상으로 하며 `--apply --confirm-destructive`를 함께 지정해야 합니다. 일반 `.json`/`.tmp`/`.bak` 파일은 절대 삭제하지 않습니다.
- **무결성 검사**: 압축 훅은 실행 전에 `integrity.json`으로 `pipeline.ps1`을 검증합니다.

### 라이선스

MIT 许可证（附**强制署名条款**）：允许使用全部或部分源码（含修改后的变体），但**必须标注
Pondsi 的署名**。详见 [LICENSE](LICENSE)。

---

## Español

### ¿Qué es esto?

InfinityContext es un Skill de OpenClaw que previene el desbordamiento de contexto en modelos pequeños (128K de contexto). Proporciona compresión multicapa, backup automático y búsqueda FTS5.

### Características

- **Protección multicapa**: Configuración → Pipeline → Hook → Memoria
- **Backup automático**: Trajectory exportado antes de cada compresión
- **SQLite + Búsqueda FTS5**: Sesiones comprimidas buscables por índice trigram
- **Deduplicación**: Ventana de 5 minutos previene backups duplicados

### Inicio Rápido

```bash
# Registry install (scanned artifact, no git, no build step)
clawhub install infinitycontext --workdir ~/.agents --dir skills
# From source: pin the reviewed release tag and verify checksums.txt - see "Quick Start" above
```

### Seguridad y privacidad

- **Solo local**: sin peticiones de red, sin telemetría y sin sincronización en la nube. Los datos permanecen en este equipo.
- **Exportación completa antes de comprimir**: cada compactación exporta toda la trayectoria de la sesión y escribe fragmentos de conversación redactados en un archivo SQLite/FTS5 local (con búsqueda de texto completo).
- **Redacción y minimización**: expresiones regulares ocultan claves de API, tokens, contraseñas, JWT, claves privadas, cadenas de conexión, teléfonos y correos; los valores de alta entropía se excluyen del índice. El contenido demasiado largo se recorta con `MAX_ARCHIVE_LENGTH` (se conservan inicio y final).
- **Fail-closed**: si la redacción no puede ejecutarse, la copia de seguridad se destruye; nunca se conserva en texto plano.
- **Permisos y retención**: la ACL de las copias se limita al usuario actual + SYSTEM y se eliminan automáticamente a los 30 días por defecto.
- **La limpieza exige doble confirmación**: `cleanup.py` solo actúa en directorios con el marcador `.infinity-context-archive` y requiere `--apply --confirm-destructive`; los archivos genéricos `.json`/`.tmp`/`.bak` nunca se borran.
- **Verificación de integridad**: el hook de compactación verifica `pipeline.ps1` contra `integrity.json` antes de ejecutarlo.

### Licencia

MIT License with a **mandatory attribution requirement** — any use, including
modified variants, must credit **Pondsi**. See [LICENSE](LICENSE).

---

## Português

### O que é isso?

InfinityContext é um Skill do OpenClaw que previne o transbordamento de contexto em modelos pequenos (128K de contexto). Fornece compressão multicamada, backup automático e busca FTS5.

### Características

- **Proteção multicamada**: Configuração → Pipeline → Hook → Memória
- **Backup automático**: Trajetória exportada antes de cada compressão
- **SQLite + Busca FTS5**: Sessões comprimidas pesquisáveis por índice trigram
- **Deduplicação**: Janela de 5 minutos previne backups duplicados

### Início Rápido

```bash
# Registry install (scanned artifact, no git, no build step)
clawhub install infinitycontext --workdir ~/.agents --dir skills
# From source: pin the reviewed release tag and verify checksums.txt - see "Quick Start" above
```

### Segurança e privacidade

- **Somente local**: sem requisições de rede, sem telemetria e sem sincronização na nuvem. Os dados permanecem neste computador.
- **Exportação completa antes de comprimir**: cada compactação exporta toda a trajetória da sessão e grava trechos de conversa redigidos em um arquivo SQLite/FTS5 local (com busca em texto completo).
- **Redação e minimização**: expressões regulares mascaram chaves de API, tokens, senhas, JWT, chaves privadas, strings de conexão, telefones e e-mails; valores de alta entropia ficam fora do índice. Conteúdo muito longo é recortado por `MAX_ARCHIVE_LENGTH` (mantendo início e fim).
- **Fail-closed**: se a redação não puder ser executada, o backup é destruído; nunca é mantido em texto claro.
- **Permissões e retenção**: a ACL dos backups é restrita ao usuário atual + SYSTEM e eles são removidos automaticamente após 30 dias por padrão.
- **A limpeza exige dupla confirmação**: o `cleanup.py` só atua em diretórios com o marcador `.infinity-context-archive` e exige `--apply --confirm-destructive`; arquivos genéricos `.json`/`.tmp`/`.bak` nunca são apagados.
- **Verificação de integridade**: o hook de compactação verifica `pipeline.ps1` contra `integrity.json` antes de executar.

### Licença

MIT License with a **mandatory attribution requirement** — any use, including
modified variants, must credit **Pondsi**. See [LICENSE](LICENSE).

---

## Français

### Qu'est-ce que c'est ?

InfinityContext est un Skill OpenClaw qui empêche le débordement de contexte dans les petits modèles (128K de contexte). Il fournit compression multicouche, sauvegarde automatique et recherche FTS5.

### Fonctionnalités

- **Protection multicouche** : Configuration → Pipeline → Hook → Mémoire
- **Sauvegarde automatique** : Trajectoire exportée avant chaque compression
- **SQLite + Recherche FTS5** : Sessions compressées recherchables par index trigram
- **Dédoublonnage** : Fenêtre de 5 minutes empêche les sauvegardes en double

### Démarrage Rapide

```bash
# Registry install (scanned artifact, no git, no build step)
clawhub install infinitycontext --workdir ~/.agents --dir skills
# From source: pin the reviewed release tag and verify checksums.txt - see "Quick Start" above
```

### Sécurité et confidentialité

- **100 % local** : aucune requête réseau, aucune télémétrie, aucune synchronisation cloud. Les données restent sur cette machine.
- **Export complet avant compression** : chaque compaction exporte l'intégralité de la trajectoire de session et écrit des extraits de conversation masqués dans une archive SQLite/FTS5 locale (recherche plein texte).
- **Masquage et minimisation** : des expressions régulières masquent clés d'API, jetons, mots de passe, JWT, clés privées, chaînes de connexion, téléphones et e-mails ; les valeurs à forte entropie sont exclues de l'index. Les contenus trop longs sont tronqués via `MAX_ARCHIVE_LENGTH` (début et fin conservés).
- **Fail-closed** : si le masquage ne peut pas s'exécuter, la sauvegarde est détruite ; aucun texte en clair n'est conservé.
- **Permissions et rétention** : l'ACL des sauvegardes est limitée à l'utilisateur courant + SYSTEM et elles sont supprimées automatiquement après 30 jours par défaut.
- **Le nettoyage exige une double confirmation** : `cleanup.py` n'agit que sur les répertoires portant le marqueur `.infinity-context-archive` et exige `--apply --confirm-destructive` ; les fichiers génériques `.json`/`.tmp`/`.bak` ne sont jamais supprimés.
- **Vérification d'intégrité** : le hook de compaction vérifie `pipeline.ps1` via `integrity.json` avant exécution.

### Licence

MIT License with a **mandatory attribution requirement** — any use, including
modified variants, must credit **Pondsi**. See [LICENSE](LICENSE).

---

## Deutsch

### Was ist das?

InfinityContext ist ein OpenClaw-Skill, der Kontext-Überlauf in kleinen Modellen (128K Kontext) verhindert. Bietet mehrschichtige Kompression, automatisches Backup und FTS5-Suche.

### Funktionen

- **Mehrschichtiger Schutz**: Konfiguration → Pipeline → Hook → Speicher
- **Automatisches Backup**: Trajektorie wird vor jeder Kompression exportiert
- **SQLite + FTS5-Suche**: Komprimierte Sessions über Trigramm-Index durchsuchbar
- **Deduplizierung**: 5-Minuten-Fenster verhindert doppelte Backups

### Schnellstart

```bash
# Registry install (scanned artifact, no git, no build step)
clawhub install infinitycontext --workdir ~/.agents --dir skills
# From source: pin the reviewed release tag and verify checksums.txt - see "Quick Start" above
```

### Sicherheit und Datenschutz

- **Nur lokal**: keine Netzwerkanfragen, keine Telemetrie, keine Cloud-Synchronisierung. Die Daten bleiben auf diesem Rechner.
- **Vollständiger Export vor dem Komprimieren**: Jede Komprimierung exportiert den kompletten Sitzungsverlauf und schreibt redigierte Gesprächsausschnitte in ein lokales SQLite/FTS5-Archiv (Volltextsuche).
- **Redaktion und Datenminimierung**: Reguläre Ausdrücke maskieren API-Schlüssel, Token, Passwörter, JWT, private Schlüssel, Verbindungszeichenfolgen, Telefonnummern und E-Mails; Werte mit hoher Entropie werden nicht indexiert. Zu lange Inhalte werden per `MAX_ARCHIVE_LENGTH` gekürzt (Anfang und Ende bleiben erhalten).
- **Fail-Closed**: Kann die Redaktion nicht ausgeführt werden, wird das Backup vernichtet; Klartext wird nie behalten.
- **Rechte und Aufbewahrung**: Die ACL der Backups ist auf aktuellen Benutzer + SYSTEM beschränkt; sie werden standardmäßig nach 30 Tagen gelöscht.
- **Löschen erfordert doppelte Bestätigung**: `cleanup.py` arbeitet nur in Verzeichnissen mit der Markierung `.infinity-context-archive` und verlangt `--apply --confirm-destructive`; generische `.json`/`.tmp`/`.bak`-Dateien werden nie gelöscht.
- **Integritätsprüfung**: Der Compaction-Hook prüft `pipeline.ps1` vor der Ausführung gegen `integrity.json`.

### Lizenz

MIT License with a **mandatory attribution requirement** — any use, including
modified variants, must credit **Pondsi**. See [LICENSE](LICENSE).

---

## Русский

### Что это?

InfinityContext — это навык OpenClaw, предотвращающий переполнение контекста в маленьких моделях (128K контекста). Предоставляет многоуровневое сжатие, автоматическое резервирование и поиск FTS5.

### Возможности

- **Многоуровневая защита**: Конфигурация → Конвейер → Хук → Память
- **Автоматическое резервирование**: Траектория экспортируется перед каждым сжатием
- **SQLite + Поиск FTS5**: Сжатые сессии searchable через trigram индекс
- **Дедупликация**: 5-минутное окно предотвращает дублирование бэкапов

### Быстрый старт

```bash
# Registry install (scanned artifact, no git, no build step)
clawhub install infinitycontext --workdir ~/.agents --dir skills
# From source: pin the reviewed release tag and verify checksums.txt - see "Quick Start" above
```

### Безопасность и конфиденциальность

- **Только локально**: никаких сетевых запросов, телеметрии и облачной синхронизации. Данные остаются на этом компьютере.
- **Полный экспорт перед сжатием**: каждое сжатие экспортирует всю траекторию сессии и записывает отредактированные фрагменты диалога в локальный архив SQLite/FTS5 (полнотекстовый поиск).
- **Редактирование и минимизация**: регулярные выражения маскируют API-ключи, токены, пароли, JWT, приватные ключи, строки подключения, телефоны и адреса электронной почты; значения с высокой энтропией не попадают в индекс. Слишком длинный текст обрезается через `MAX_ARCHIVE_LENGTH` (начало и конец сохраняются).
- **Fail-Closed**: если редактирование невозможно, резервная копия уничтожается; открытый текст не сохраняется.
- **Права и хранение**: ACL резервных копий ограничен текущим пользователем + SYSTEM; по умолчанию они удаляются через 30 дней.
- **Удаление требует двойного подтверждения**: `cleanup.py` работает только в каталогах с маркером `.infinity-context-archive` и требует `--apply --confirm-destructive`; обычные файлы `.json`/`.tmp`/`.bak` не удаляются никогда.
- **Проверка целостности**: хук сжатия проверяет `pipeline.ps1` по `integrity.json` перед выполнением.

### Лицензия

MIT 许可证（附**强制署名条款**）：允许使用全部或部分源码（含修改后的变体），但**必须标注
Pondsi 的署名**。详见 [LICENSE](LICENSE)。

## Security / 安全模型

**Fail-closed by default — nothing is written when a safety check cannot be enforced.**

- **Local only**: no network code, no telemetry, no MCP, no cloud sync anywhere in the package.
- **No shell, no subprocesses**: the four Python scripts never start another program; Windows ACL hardening uses in-process Win32 security APIs.
- **Owner-only archive, fail-closed**: the archive directory is forced to `0700` and files to `0600` (POSIX) or a protected DACL (Windows); the result is re-read to prove it took effect. If owner-only access cannot be enforced, archiving aborts and the half-written database is destroyed (exit 3). `--allow-insecure-storage` is the only opt-out and is reported as `insecure_storage: true`.
- **Fail-closed redaction**: rules are validated and precompiled at startup; a malformed rule file aborts before any database is created. `session_key` is sanitised before it is used for any path or filename.
- **Bounded retention**: 30 days by default, `--retention-days 1..3650`; unlimited retention requires the explicit `--allow-unbounded-retention` flag; `INFINITY_CONTEXT_NO_ARCHIVE=1` disables archiving entirely.
- **Deny-by-default filesystem rules**: `cleanup.py` refuses a directory without the `.infinity-context-archive` marker, deletes only full filenames matching InfinityContext artifacts, never recurses, re-checks every candidate with `lstat`, and does nothing without `--apply --confirm-destructive`.

**默认拒绝 — 任何安全检查无法强制执行时，直接中止而不是降级。**

- **纯本地**：包内没有任何网络代码、遥测、MCP 或云同步。
- **无 shell、无子进程**：四个 Python 脚本从不启动其它程序；Windows ACL 使用进程内 Win32 安全 API。
- **归档仅本人可读，Fail-Closed**：POSIX `0700`/`0600`，Windows 受保护 DACL，并回读校验；无法强制时中止并销毁半成品（退出码 3）。唯一例外是 `--allow-insecure-storage`，且结果中会标记 `insecure_storage: true`。
- **脱敏 Fail-Closed**：规则启动期校验并预编译，规则文件损坏会在建库前中止；`session_key` 在生成任何路径/文件名之前先净化。
- **保留期有界**：默认 30 天，`--retention-days 1..3650`；无限期保留需显式 `--allow-unbounded-retention`；`INFINITY_CONTEXT_NO_ARCHIVE=1` 可彻底关闭归档。
- **默认拒绝的文件系统规则**：`cleanup.py` 拒绝没有 `.infinity-context-archive` 标记的目录，只删除完整文件名匹配本应用产物的文件，不递归，删除前用 `lstat` 复核，且必须同时给出 `--apply --confirm-destructive`。

## 隐私声明 / Privacy Statement

本 Skill 会将对话上下文保存在本地纯内网的 SQLite 中以供检索，系统已内置正则脱敏机制屏蔽常见 API 密钥，且不依赖任何云端同步。所有数据仅存储于本机，不会外传。

This skill stores conversation context in a local-only SQLite database for retrieval. Built-in regex redaction masks common API keys. No cloud sync is used; all data stays on the local machine.

---

Pondsi (+MiMo-v2.5/v2.5pro+deepseek-v4-flash/pro+deepseek-v4.1-flash-expires-on-0910+GLM5.3-flash+Gemini3.1-pro+Qwen3.8-27b+Gemini3.8-flash) — automatically committed by Openclaw
