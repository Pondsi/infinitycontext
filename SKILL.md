---
name: infinity-context
description: "Use when a long agent session is about to hit its context limit, when a detail from an earlier turn must be recalled exactly, or when past sessions should stay searchable offline. Compresses context, archives every conversation chunk into a local SQLite/FTS5 store with owner-only permissions, and retrieves exact details on demand. Works out of the box on DeepSeek Harness (dsh) and OpenClaw; also runs on Claude Code, Cursor, Dify, Ollama and any Agent Skills host."
license: MIT
compatibility: "Any host that loads a standard SKILL.md: DeepSeek Harness (dsh), OpenClaw, Claude Code, Cursor, Dify, Ollama, custom agents. Python 3.9+ standard library only. No network access, no shell commands, no subprocesses, no Windows-only dependency."
allowed-tools: Bash Read Write Env
metadata:
  author: "Pondsi"
  version: "1.3.1"
  license: "MIT"
---

# InfinityContext — portable context compression & memory archive

> Keep any model running indefinitely: compress context, archive every chunk locally, retrieve exact details later.

Works out of the box on **DeepSeek Harness (dsh)** and **OpenClaw**, and on any
host that loads a standard `SKILL.md`.

## Install

### 1. Registry (scanned artifact — no git, no build step)

```bash
# dsh / Claude Code: lands in ~/.agents/skills/infinity-context/
clawhub install infinity-context --workdir ~/.agents --dir skills

# OpenClaw: installs into the OpenClaw skills directory
clawhub install infinity-context
```

### 2. From source — pin the audited tag, verify every byte

```bash
git clone https://github.com/Pondsi/infinitycontext.git
cd infinitycontext
git checkout --detach v1.3.1              # never the mutable default branch
sha256sum -c checksums.txt                # macOS: shasum -a 256 -c checksums.txt
# compare the output with the hashes published in the GitHub release notes

mkdir -p ~/.agents/skills/infinity-context/scripts
mkdir -p ~/.agents/skills/infinity-context/references
cp SKILL.md README.md 说明.md CHANGELOG.md SPONSORS.md LICENSE ~/.agents/skills/infinity-context/
cp scripts/session_to_sqlite.py scripts/search.py scripts/cleanup.py scripts/secure_fs.py ~/.agents/skills/infinity-context/scripts/
cp references/architecture.md references/languages.md ~/.agents/skills/infinity-context/references/
```

Copy the files explicitly. Never `cp -r` the source tree: an audited package
must not pick up unaudited files.

## Quick start on DeepSeek Harness (dsh)

dsh uses the standard `SKILL.md` contract. Two rules matter:

- the **directory name must equal the frontmatter `name`** → use `infinity-context`
- **recursive discovery is not supported** → the skill folder must be a direct child of a discovery root

Use the user-level root `~/.agents/skills/infinity-context/` (rank 500, shared
with Claude Code and other agents) or the project-level root
`<project>/.agents/skills/infinity-context/` (rank 200, wins over the user-level
copy). Restart dsh, type `/`, and the skill appears under **Skills**. Nothing
else to install: a skill takes effect the moment its folder sits in a scan root.

Then drive it from the agent's shell tool:

```bash
# archive a transcript (JSONL) into the local SQLite/FTS5 store
python3 scripts/session_to_sqlite.py --session-key <key> --session-file <events.jsonl> --output-dir ~/.infinity-context/archive

# retrieve a detail from months ago
python3 scripts/search.py --query "deployment token"

# prune old archives (dry-run by default)
python3 scripts/cleanup.py --dry-run
```

## Quick start on OpenClaw

After `clawhub install infinity-context`, the three scripts above are available
unchanged; OpenClaw discovers the skill from its skills directory and calls them
through its shell tool. The Windows compaction automation (hook + pipeline) is a
separate, optional integration that lives outside this package — see
`openclaw/README.md` in the repository.

## Host compatibility

| Host | Install location | Notes |
|------|------------------|-------|
| **DeepSeek Harness (dsh)** | `~/.agents/skills/infinity-context/` or `<project>/.agents/skills/infinity-context/` | First-class; same contract as Claude Code |
| **OpenClaw** | OpenClaw skills directory (see `clawhub install`) | First-class; optional hook documented in the repository |
| **Claude Code** | `~/.claude/skills/infinity-context/` | `allowed-tools` pre-approves the declared capabilities |
| **Cursor / Dify / Ollama / custom** | point the agent at this folder | Pure Python standard library |

The core is **host-agnostic**: four Python scripts, no network, no shell, no
subprocesses, no Windows-only dependency.

## What it does

1. **Archive** (`session_to_sqlite.py`) — turns a session transcript into a local SQLite database with an FTS5 index, so a compressed session can still be searched down to the message.
2. **Retrieve** (`search.py`) — FTS5 trigram search with a `LIKE` fallback for short CJK queries; reads only, never writes.
3. **Prune** (`cleanup.py`) — retention-based cleanup with canonical path anchoring and `VACUUM`; dry-run by default.
4. **Protect** (`secure_fs.py`) — owner-only permissions for the archive directory, the database and its WAL sidecars.

Compression itself is a prompt-level discipline: keep `keepRecentTokens` small
enough that a deep reply still fits, and let the archive carry the details
instead of the context window.

## Security & privacy

- **Local only** — no network calls, no telemetry, no MCP, no cloud sync.
- **No shell, no subprocesses** — the core never starts another program. Windows ACL hardening uses in-process Win32 security API calls, not a helper executable.
- **Owner-only archive** — the archive directory is forced to `0700` and files to `0600` on POSIX; on Windows the DACL is replaced by a protected DACL granting only the current user and LOCAL SYSTEM. New database files are created atomically with `0600`, so no file ever exists with wider permissions (no check-then-chmod race). A pre-existing directory owned by another account is refused. If a filesystem cannot enforce this, a loud warning is printed and the JSON result reports `permissions_enforced: false`.
- **Fail-closed redaction** — before any text is stored, a regex redactor masks API keys, tokens, passwords, JWTs, private keys, connection strings, cookies, webhooks, phone numbers and emails. High-entropy candidates are excluded from the keyword index. If the redactor cannot run, the record is not written.
- **Data minimisation** — `MAX_ARCHIVE_LENGTH` truncates oversized content (head + tail kept) before storage.
- **Deny-by-default filesystem rules** — `cleanup.py` only deletes files inside the canonical archive directory, only with whitelisted extensions, never through a symbolic link, and never without `--apply`.

### Data sensitivity notice

Conversation archives contain session history and are treated as sensitive data.
Redaction is best-effort: after redaction the archive still holds a detailed
record of your sessions. Do not share archive files, sync them to cloud storage,
or widen the permissions of the archive directory without understanding the
consequences.

## Supply chain

This package is **self-contained**: `SKILL.md`, `README.md`, `说明.md`,
`CHANGELOG.md`, `SPONSORS.md`, `LICENSE`, `checksums.txt`, `scripts/` (Python
only), `references/`, `sponsors/`. It contains no JavaScript, no PowerShell and
no code fetched at install time — the audited artifact is exactly what runs.
`checksums.txt` lists the SHA-256 of every published file except itself.

Host-specific automation (for example an OpenClaw compaction hook) is
deliberately **out of scope** for this package. Anything of that kind lives in
the repository outside the published artifact and carries its own documentation,
pinned revision and checksums.

## Configuration

| Setting | Default | Where |
|---------|---------|-------|
| archive directory | `~/.infinity-context/archive` | `--output-dir` / `--archive-dir`, or `INFINITY_CONTEXT_HOME` |
| `MAX_ARCHIVE_LENGTH` | `20000` characters | `scripts/session_to_sqlite.py` |
| redaction rules | built in | `scripts/session_to_sqlite.py` (add `redact_rules.json` beside it to extend) |
| retention | 30 days | `cleanup.py --days` (1..3650) |

## Architecture

```
session transcript (JSONL)
        │
        ├─ redact  ────────────────► fail-closed: nothing is stored if this step fails
        ├─ truncate (MAX_ARCHIVE_LENGTH)
        ▼
  session_chunks  ──trigger──►  chunk_fts (FTS5 trigram)
        │
        └─ search.py  ──►  exact detail from any past turn
```

## More languages

Localised summaries (繁體中文, 日本語, 한국어, Español, Português, Français,
Deutsch, Русский) are in [`references/languages.md`](references/languages.md).

## License

MIT — see [LICENSE](LICENSE). Changelog: [CHANGELOG.md](CHANGELOG.md).

---

# 无限上下文压缩与记忆归档

> 让任何模型持续对话：压缩上下文、把每个片段归档到本地、随时精确检索细节。

**开箱即用**：DeepSeek Harness（dsh）与 OpenClaw；任何加载标准 `SKILL.md` 的宿主亦可。

## 安装

```bash
# 方式一：注册表（已扫描产物，无需 git、无需构建）
clawhub install infinity-context --workdir ~/.agents --dir skills   # dsh / Claude Code
clawhub install infinity-context                                     # OpenClaw

# 方式二：源码（固定已审计 tag + 逐文件校验，禁止使用可变分支）
git clone https://github.com/Pondsi/infinitycontext.git
cd infinitycontext
git checkout --detach v1.3.1
sha256sum -c checksums.txt                # macOS：shasum -a 256 -c checksums.txt
mkdir -p ~/.agents/skills/infinity-context/scripts
mkdir -p ~/.agents/skills/infinity-context/references
cp SKILL.md README.md 说明.md CHANGELOG.md SPONSORS.md LICENSE ~/.agents/skills/infinity-context/
cp scripts/session_to_sqlite.py scripts/search.py scripts/cleanup.py scripts/secure_fs.py ~/.agents/skills/infinity-context/scripts/
cp references/architecture.md references/languages.md ~/.agents/skills/infinity-context/references/
```

**必须逐文件显式复制，禁止 `cp -r`**：被审计的包不得混入未审计文件。

## 在 dsh 上快速开始

- **目录名必须与 frontmatter 的 `name` 一致** → 用 `infinity-context`
- **不支持递归发现** → 技能文件夹必须是发现根目录的直接子目录

用户级 `~/.agents/skills/infinity-context/`（rank 500，与 Claude Code 共享）或项目级
`<project>/.agents/skills/infinity-context/`（rank 200，优先）。重启 dsh，输入 `/`，
技能即出现在 **Skills** 分组——文件夹进入扫描根即生效，无需其它步骤。

## 在 OpenClaw 上快速开始

`clawhub install infinity-context` 后，上述三个脚本即可直接调用；OpenClaw 从技能目录
发现本技能并通过 shell 工具执行。Windows 压缩自动化（hook + pipeline）属于**可选集成**，
不在本包内，详见仓库 `openclaw/README.md`。

## 四个脚本

1. **归档** `session_to_sqlite.py`——会话轨迹转本地 SQLite + FTS5 索引
2. **检索** `search.py`——FTS5 三元组搜索，短中文词回退 `LIKE`；只读
3. **清理** `cleanup.py`——按保留期清理并 `VACUUM`；默认演练模式
4. **保护** `secure_fs.py`——归档目录/数据库/WAL 旁文件强制 owner-only 权限

## 安全与隐私

- **纯本地**：不联网、无遥测、无 MCP、不上传
- **无 shell、无子进程**：核心脚本从不启动其它程序；Windows ACL 使用进程内 Win32 安全 API，不调用外部工具
- **归档仅本人可读**：POSIX 目录 `0700`、文件 `0600`；Windows 用受保护 DACL 仅授权当前用户与 LOCAL SYSTEM；新数据库文件以 `0600` **原子创建**（无「先建后改」时间差）；预存目录若属于其它账号则**拒绝使用**；无法强制时打印醒目告警并在 JSON 结果中标记 `permissions_enforced: false`
- **Fail-Closed 脱敏**：入库前屏蔽 API Key / Token / 密码 / JWT / 私钥 / 连接串 / Cookie / Webhook / 手机号 / 邮箱；脱敏不可用时**不写入**
- **数据最小化**：`MAX_ARCHIVE_LENGTH` 掐头去尾截断
- **默认拒绝的文件系统规则**：`cleanup.py` 只删归档目录内、白名单扩展名、非符号链接的文件，且必须显式 `--apply`

### 数据敏感性声明

归档包含会话历史，属于敏感数据。脱敏是尽力而为：脱敏后仍保留会话的详细记录。
请勿分享归档文件、同步到云存储，或在未理解后果的情况下放宽归档目录权限。

## 供应链

本包**自包含**：`SKILL.md`、`README.md`、`说明.md`、`CHANGELOG.md`、`SPONSORS.md`、
`LICENSE`、`checksums.txt`、`scripts/`（仅 Python）、`references/`、`sponsors/`。
**不含任何 JavaScript / PowerShell，也不在安装时拉取外部代码**——被审计的产物就是
实际运行的东西。`checksums.txt` 列出除自身外每个发布文件的 SHA-256。

宿主专有的自动化（例如 OpenClaw 压缩钩子）**不属于本包范围**，只存在于仓库中、
位于发布产物之外，并自带文档、固定版本号与校验和。

## 其它语言

繁體中文、日本語、한국어、Español、Português、Français、Deutsch、Русский 见
[`references/languages.md`](references/languages.md)。

## 许可证

MIT 许可证 — 详见 [LICENSE](LICENSE)。
