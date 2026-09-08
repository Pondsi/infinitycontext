# InfinityContext

**Open-Source Context Compression & Memory Optimization for AI Agents — DeepSeek Harness (dsh), Claude Code, OpenClaw, Cursor, Dify, Ollama and any Agent Skills host**

[English](#english) | [简体中文](#简体中文) | [繁體中文](#繁體中文) | [日本語](#日本語) | [한국어](#한국어) | [Español](#español) | [Português](#português) | [Français](#français) | [Deutsch](#deutsch) | [Русский](#русский)

---

> ⚠️ **Privacy & Data Retention Notice / 隐私与数据留存声明**
>
> **EN** — This skill does more than compress context. It (a) exports the full session trajectory before every compaction, and (b) writes redacted conversation chunks into a **local-only SQLite archive** used for FTS5 retrieval. `MAX_ARCHIVE_LENGTH` truncates oversized content and a regex redactor masks API keys, tokens, passwords, JWTs, private keys, connection strings, phone numbers, and emails; high-entropy candidates are excluded from the index. **Fail-closed:** if redaction cannot run, the backup is destroyed, never kept in plaintext. Nothing is sent anywhere — no cloud sync, no telemetry, no outbound network. Backups are ACL-restricted to the current user + SYSTEM and pruned after 30 days. The optional **auto-recovery** is opt-in (`enableAutoWake`), sends exactly one validated resume command per monitor round, logs `WAKE_REQUEST` first, and never spawns a notification process; the agent allowlist is deny-by-default. The compaction hook verifies `pipeline.ps1` against `integrity.json` before executing. Run `scripts/cleanup-old-backups.ps1` for manual cleanup and SQLite `VACUUM`.
>
> **中文** — 本插件不只做上下文压缩：它会在每次压缩前导出完整会话轨迹，并把脱敏后的对话片段写入**纯本地 SQLite**（用于 FTS5 检索）。内置 `MAX_ARCHIVE_LENGTH` 截断与正则脱敏（API Key / Token / 密码 / JWT / 私钥 / 连接串 / 手机号 / 邮箱），高熵内容不进索引。**Fail-Closed：脱敏无法执行时直接销毁备份，绝不保留明文。** 不联网、不上传、无遥测；备份目录 ACL 收紧为「当前用户 + SYSTEM」，默认保留 30 天后自动清理。可选的**自动恢复**需显式开启（`enableAutoWake`），每轮最多发送一次经过校验的「继续」指令，执行前先写 `WAKE_REQUEST` 日志，绝不拉起通知进程；Agent 白名单默认拒绝。压缩钩子执行前会校验 `pipeline.ps1` 的 `integrity.json` 摘要。可手动执行 `scripts/cleanup-old-backups.ps1` 清理并 VACUUM。

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

InfinityContext is a **universal AI agent skill** that keeps your conversations forever — no context overflow, no forgotten goals, no lost details. It is a standard `SKILL.md`, so it runs on **any Agent Skills host**, with first-class support for **DeepSeek Harness (dsh)** — drop it into `.agents/skills/` and the harness discovers it — plus Claude Code, OpenClaw, Cursor, Dify, Ollama, and custom agents.

> **Core promise**: Whether you're using a 64K or 1M context model, switching between models mid-conversation, or running dozens of back-and-forth turns — InfinityContext ensures the agent always remembers **what it's doing**, **what it's done**, **how it did it**, and **every detail in between**. When you need specifics, it knows **when, where, and how** to retrieve them.

### Features

- 🔒 **Never forget**: Multi-layer compression keeps context within safe bounds while preserving all critical information
- 🧠 **Full memory**: Goals, actions, reasoning process, results, and intermediate details — all retained
- 🔄 **Model-agnostic**: Works with 64K, 128K, 1M context models; seamless switching between them
- 📦 **Automatic backup**: Every compaction triggers trajectory export + SQLite indexing
- 🔍 **FTS5 search**: Compressed sessions fully searchable via trigram index
- 🛡️ **Triple coverage**: Manual, auto-compact, and watchdog — all paths protected
- ⚡ **Deduplication**: 5-minute window prevents redundant backups

### Quick Start

```bash
# 1. Registry install (scanned artifact, no git, no build step)
clawhub install infinitycontext --workdir ~/.agents --dir skills   # dsh / Claude Code
clawhub install infinitycontext --workdir ~/.openclaw --dir skills  # OpenClaw

# 2. From source: pin the audited tag, then verify every file
git clone https://github.com/Pondsi/infinitycontext.git
cd infinitycontext
git checkout --detach v1.3.1
sha256sum -c checksums.txt          # macOS: shasum -a 256 -c checksums.txt

# 3. Copy exactly these files (never `cp -r`, never a wildcard)
mkdir -p ~/.agents/skills/infinity-context/scripts
mkdir -p ~/.agents/skills/infinity-context/references
cp SKILL.md README.md 说明.md CHANGELOG.md SPONSORS.md LICENSE ~/.agents/skills/infinity-context/
cp scripts/session_to_sqlite.py scripts/search.py scripts/cleanup.py scripts/secure_fs.py ~/.agents/skills/infinity-context/scripts/
cp references/architecture.md references/languages.md ~/.agents/skills/infinity-context/references/

# 4. Optional OpenClaw compaction automation: see openclaw/README.md
# 5. Restart your host (dsh: restart dsh; OpenClaw: openclaw gateway restart)
```

### How It Works

```
Any compaction trigger (manual/auto/watchdog)
  ├─ compact:before → backup + SQLite conversion
  ├─ OpenClaw executes compression
  └─ compact:after → enhanced summary generation

Deduplication: skip if backup exists within 5 minutes
```

### Requirements

- **Any host that loads standard `SKILL.md` / Agent Skills** — DeepSeek Harness (dsh), Claude Code, OpenClaw, Cursor, Dify, Ollama, or a custom agent. **OpenClaw is optional.**
- Python 3.9+ (redaction engine + SQLite/FTS5 archive — the portable core)
- PowerShell 5.1+ (Windows only, for the optional watchdog and compaction hook)

### Sponsors

If you find this project helpful, consider supporting its development! See [SPONSORS.md](SPONSORS.md) for donation options.

### License

MIT License

---

## 简体中文

### 这是什么？

InfinityContext 是一个**通用 AI 智能体技能**，让你的对话永远完整——不溢出、不遗忘目标、不丢失任何细节。它是标准 `SKILL.md`，可运行在**任何支持 Agent Skills 的宿主**上，并**原生支持 DeepSeek Harness（dsh）**——放进 `.agents/skills/` 即被自动发现；同样支持 Claude Code、OpenClaw、Cursor、Dify、Ollama 及自研 Agent。

> **核心承诺**：无论你使用 64K 还是 1M 上下文的模型，无论对话中切换模型，无论进行了多少轮交互——InfinityContext 确保智能体始终记得**要做什么**、**做过什么**、**怎么做的**，以及**每一个中间细节**。当你需要具体信息时，它知道**什么时候、在哪里、怎么查**。

### 功能特性

- 🔒 **永不遗忘**：多层压缩保持上下文在安全范围内，同时保留所有关键信息
- 🧠 **完整记忆**：目标、行动、推理过程、结果、中间细节——全部保留
- 🔄 **模型无关**：支持 64K、128K、1M 上下文模型；模型间无缝切换
- 📦 **自动备份**：每次压缩触发轨迹导出 + SQLite 索引
- 🔍 **FTS5 搜索**：压缩后的会话可通过三元组索引完整搜索
- 🛡️ **三重覆盖**：手动、自动压缩、看门狗——所有路径受保护
- ⚡ **去重机制**：5 分钟窗口避免重复备份

### 快速开始

```bash
# 方式一：注册表安装（已扫描产物，无需 git、无需构建）
clawhub install infinitycontext --workdir ~/.agents --dir skills   # dsh / Claude Code
clawhub install infinitycontext --workdir ~/.openclaw --dir skills  # OpenClaw

# 方式二：源码安装——固定已审计 tag，并逐文件校验
git clone https://github.com/Pondsi/infinitycontext.git
cd infinitycontext
git checkout --detach v1.3.1
sha256sum -c checksums.txt          # macOS：shasum -a 256 -c checksums.txt

# 逐文件显式复制（禁止 cp -r、禁止通配符）
mkdir -p ~/.agents/skills/infinity-context/scripts
mkdir -p ~/.agents/skills/infinity-context/references
cp SKILL.md README.md 说明.md CHANGELOG.md SPONSORS.md LICENSE ~/.agents/skills/infinity-context/
cp scripts/session_to_sqlite.py scripts/search.py scripts/cleanup.py scripts/secure_fs.py ~/.agents/skills/infinity-context/scripts/
cp references/architecture.md references/languages.md ~/.agents/skills/infinity-context/references/

# 可选 OpenClaw 压缩自动化：见 openclaw/README.md
# 重启宿主（dsh：重启 dsh；OpenClaw：openclaw gateway restart）
```

### 工作原理

```
任意压缩触发（手动/自动/看门狗）
  ├─ compact:before → 备份 + SQLite 转换
  ├─ OpenClaw 执行压缩
  └─ compact:after → 增强摘要生成

去重机制：5 分钟内已有备份则跳过
```

### 系统要求

- **任意支持标准 `SKILL.md` / Agent Skills 的宿主**——DeepSeek Harness（dsh）、Claude Code、OpenClaw、Cursor、Dify、Ollama 或自研 Agent。**OpenClaw 不是必需的。**
- Python 3.9+（脱敏引擎 + SQLite/FTS5 归档，可独立运行的核心）
- PowerShell 5.1+（仅 Windows，用于可选看门狗与压缩钩子）

### 许可证

MIT 许可证

---

## 繁體中文

### 這是什麼？

InfinityContext 是一個 AI Agent Skill，解決小模型（128K 上下文）對話中上下文溢出的問題。透過多層壓縮機制，讓任何大小的模型都能持續對話而不中斷。

### 功能特性

- **三層防護**：配置層 → 管線層 → Hook 層 → 記憶層
- **自動備份**：每次壓縮前導出完整軌跡
- **SQLite + FTS5 搜尋**：壓縮後的會話可透過三元組索引搜尋
- **去重機制**：5 分鐘視窗避免重複備份
- **全覆蓋壓縮路徑**：手動、自動壓縮、看門狗全部覆蓋

### 快速開始

```bash
# Registry install (scanned artifact, no git, no build step)
clawhub install infinitycontext --workdir ~/.agents --dir skills
# From source: pin the audited tag and verify checksums.txt - see "Quick Start" above
```

### 許可證

MIT 許可證

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
# From source: pin the audited tag and verify checksums.txt - see "Quick Start" above
```

### ライセンス

MIT ラ이センス

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
# From source: pin the audited tag and verify checksums.txt - see "Quick Start" above
```

### 라이선스

MIT 라이선스

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
# From source: pin the audited tag and verify checksums.txt - see "Quick Start" above
```

### Licencia

Licencia MIT

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
# From source: pin the audited tag and verify checksums.txt - see "Quick Start" above
```

### Licença

Licença MIT

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
# From source: pin the audited tag and verify checksums.txt - see "Quick Start" above
```

### Licence

Licence MIT

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
# From source: pin the audited tag and verify checksums.txt - see "Quick Start" above
```

### Lizenz

MIT-Lizenz

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
# From source: pin the audited tag and verify checksums.txt - see "Quick Start" above
```

### Лицензия

Лицензия MIT

## Security / 安全模型

**Deny by Default — no privileged operation runs unless it was explicitly authorized.**

- **Agent allowlist**: only agents listed in `INFINITY_CONTEXT_AGENTS`, `%LOCALAPPDATA%\.openclaw\infinity-context.config.json` (`{"allowedAgents":["main"]}`), or the built-in default `main` are ever read or compacted. An empty list **aborts**; it never degrades to allow-all. The `~/.openclaw/agents` directory is not enumerated.
- **Cleanup script**: `cleanup-old-backups.ps1` validates retention days (`1..3650`), anchors the target path to `%LOCALAPPDATA%\.openclaw\backups`, allows only backup file extensions, skips symlinks/junctions, and supports `-WhatIf`.
- **No shell interpolation**: session keys are validated against a strict pattern before any `openclaw` invocation; no `powershell -Command` string building.
- **No auto-wake by default**: `$EnableAutoWake = $false`; enabling it is an explicit opt-in.

**默认拒绝 — 任何特权操作都必须先被显式授权，否则不执行。**

- **Agent 白名单**：只有 `INFINITY_CONTEXT_AGENTS`、`%LOCALAPPDATA%\.openclaw\infinity-context.config.json`（`{"allowedAgents":["main"]}`）或内置默认值 `main` 中列出的 Agent 会被读取或压缩。白名单为空时**直接阻断**，绝不降级为“全部允许”；不再枚举 `~/.openclaw/agents` 目录。
- **清理脚本**：`cleanup-old-backups.ps1` 校验保留天数（`1..3650`）、将目标路径锚定在 `%LOCALAPPDATA%\.openclaw\backups` 之内、仅允许备份类扩展名、跳过符号链接/Junction，并支持 `-WhatIf` 预演。
- **无 shell 拼接**：调用 `openclaw` 前先对 session key 做严格正则校验，不使用 `powershell -Command` 字符串拼接。
- **默认不自动唤醒**：`$EnableAutoWake = $false`，开启需显式授权。

## 隐私声明 / Privacy Statement

本 Skill 会将对话上下文保存在本地纯内网的 SQLite 中以供检索，系统已内置正则脱敏机制屏蔽常见 API 密钥，且不依赖任何云端同步。所有数据仅存储于本机，不会外传。

This skill stores conversation context in a local-only SQLite database for retrieval. Built-in regex redaction masks common API keys. No cloud sync is used; all data stays on the local machine.

---

Pondsi (+MiMo-v2.5/v2.5pro+deepseek-v4-flash/pro+/deepseek-v4.1-flash-expires-on-0910+GLM5.3-flash+Gemini3.1-pro+Qwen3.8-27b) — automatically committed by Openclaw
