---
name: infinity-context
description: "Keeps long agent sessions alive: compresses context, archives every conversation chunk into a local SQLite/FTS5 store, and retrieves exact details on demand. Portable Python core that runs on DeepSeek Harness (dsh), Claude Code, OpenClaw, Cursor, Dify, Ollama and any Agent Skills host. No network, no subprocesses, no Windows dependency."
license: MIT
compatibility: "Any host that loads a standard SKILL.md: DeepSeek Harness (dsh), Claude Code, OpenClaw, Cursor, Dify, Ollama, custom agents. Python 3.9+ standard library only. No network access, no external commands, no Windows-only APIs."
allowed-tools: Bash Read Write Env
metadata:
  author: "Pondsi"
  version: "1.3.0"
  license: "MIT"
---

# InfinityContext — portable context compression & memory archive

> Keep any model running indefinitely: compress context, archive every chunk locally, retrieve exact details later.

## Quick start on DeepSeek Harness (dsh)

dsh uses the standard `SKILL.md` contract. Two rules matter:

- the **directory name must equal the frontmatter `name`** → use `infinity-context`
- **recursive discovery is not supported** → the skill folder must be a direct child of a discovery root

```bash
# user-level (rank 500, shared with Claude Code and other agents)
mkdir -p ~/.agents/skills/infinity-context
cp -r ./* ~/.agents/skills/infinity-context/

# or project-level (rank 200, wins over the user-level copy)
mkdir -p <project>/.agents/skills/infinity-context
cp -r ./* <project>/.agents/skills/infinity-context/
```

Restart dsh, type `/`, and the skill appears under **Skills**. There is nothing else to install: a skill takes effect the moment its folder sits in a scan root. Then drive it from the agent's shell tool:

```bash
# archive a transcript (JSONL) into the local SQLite/FTS5 store
python3 scripts/session_to_sqlite.py --session-key <key> --session-file <events.jsonl> --output-dir ~/.infinity-context/archive

# retrieve a detail from months ago
python3 scripts/search.py --query "deployment token"

# prune old archives (dry-run by default)
python3 scripts/cleanup.py --dry-run
```

## Host compatibility

| Host | Install location | Notes |
|------|------------------|-------|
| **DeepSeek Harness (dsh)** | `~/.agents/skills/infinity-context/` or `<project>/.agents/skills/infinity-context/` | First-class; same contract as Claude Code |
| **Claude Code** | `~/.claude/skills/infinity-context/` | `allowed-tools` pre-approves the declared capabilities |
| **OpenClaw** | `~/.openclaw/定制化功能/infinity-context/` | Portable core only; host automation is a separate integration |
| **Cursor / Dify / Ollama / custom** | point the agent at this folder | Pure Python standard library |

The core is **host-agnostic**: three Python scripts, no network, no subprocesses, no Windows-only APIs.

## What it does

1. **Archive** (`session_to_sqlite.py`) — turns a session transcript into a local SQLite database with an FTS5 index, so a compressed session can still be searched down to the message.
2. **Retrieve** (`search.py`) — FTS5 trigram search with a `LIKE` fallback for short CJK queries; reads only, never writes.
3. **Prune** (`cleanup.py`) — retention-based cleanup with canonical path anchoring and `VACUUM`; dry-run by default.

Compression itself is a prompt-level discipline: keep `keepRecentTokens` small enough that a deep reply still fits, and let the archive carry the details instead of the context window.

## Security & privacy

- **Local only** — no network calls, no telemetry, no MCP, no cloud sync.
- **No subprocesses** — the scripts never spawn a shell or another program.
- **Fail-closed redaction** — before any text is stored, a regex redactor masks API keys, tokens, passwords, JWTs, private keys, connection strings, cookies, webhooks, phone numbers and emails. High-entropy candidates are excluded from the keyword index. If the redactor cannot run, the record is not written.
- **Data minimisation** — `MAX_ARCHIVE_LENGTH` truncates oversized content (head + tail kept) before storage.
- **Deny-by-default filesystem rules** — `cleanup.py` only deletes files inside the canonical archive directory, only with whitelisted extensions, never through a symbolic link, and never without `--apply`.

## Package boundary & trust model

This package is **self-contained**: `SKILL.md`, `README.md`, `说明.md`, `CHANGELOG.md`, `SPONSORS.md`, `LICENSE`, `scripts/` (Python only), `references/`, `sponsors/`. It contains no JavaScript, no PowerShell, and no code fetched at install time — the audited artifact is exactly what runs.

Host-specific automation (for example an OpenClaw compaction hook) is deliberately **out of scope** for this package. Anything of that kind lives in the repository outside the published artifact and carries its own documentation, pinned revision and checksums.

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

## License

MIT — see [LICENSE](LICENSE). Changelog: [CHANGELOG.md](CHANGELOG.md).

---

# 无限上下文压缩与记忆归档

> 让任何模型持续对话：压缩上下文、把每个片段归档到本地、随时精确检索细节。

## 在 DeepSeek Harness（dsh）上快速开始

dsh 使用标准 `SKILL.md` 契约，两条规则必须注意：

- **目录名必须与 frontmatter 的 `name` 一致** → 用 `infinity-context`
- **不支持递归发现** → 技能文件夹必须是发现根目录的直接子目录

```bash
# 用户级（rank 500，与 Claude Code 共享）
mkdir -p ~/.agents/skills/infinity-context
cp -r ./* ~/.agents/skills/infinity-context/

# 或项目级（rank 200，优先级高于用户级）
mkdir -p <project>/.agents/skills/infinity-context
cp -r ./* <project>/.agents/skills/infinity-context/
```

重启 dsh，输入 `/`，技能即出现在 **Skills** 分组。无需其它安装步骤——文件夹进入扫描根即生效。然后通过 agent 的 shell 工具调用：

```bash
python3 scripts/session_to_sqlite.py --session-key <key> --session-file <events.jsonl> --output-dir ~/.infinity-context/archive
python3 scripts/search.py --query "部署 token"
python3 scripts/cleanup.py --dry-run
```

## 兼容性

| 宿主 | 安装位置 |
|------|----------|
| **DeepSeek Harness（dsh）** | `~/.agents/skills/infinity-context/` 或 `<project>/.agents/skills/infinity-context/` |
| **Claude Code** | `~/.claude/skills/infinity-context/` |
| **OpenClaw** | `~/.openclaw/定制化功能/infinity-context/` |
| **Cursor / Dify / Ollama / 自研** | 指向本文件夹即可 |

## 三个脚本

1. **归档** `session_to_sqlite.py`——把会话轨迹转成本地 SQLite + FTS5 索引
2. **检索** `search.py`——FTS5 三元组搜索，短中文词自动回退 `LIKE`；只读
3. **清理** `cleanup.py`——按保留期清理并 `VACUUM`；默认演练模式

## 安全与隐私

- **纯本地**：不联网、无遥测、无 MCP、不上传
- **无子进程**：脚本从不启动 shell 或其它程序
- **Fail-Closed 脱敏**：入库前屏蔽 API Key / Token / 密码 / JWT / 私钥 / 连接串 / Cookie / Webhook / 手机号 / 邮箱；脱敏不可用时**不写入**
- **数据最小化**：`MAX_ARCHIVE_LENGTH` 掐头去尾截断
- **默认拒绝的文件系统规则**：`cleanup.py` 只删归档目录内、白名单扩展名、非符号链接的文件，且必须显式 `--apply`

## 包边界与信任模型

本包**自包含**：`SKILL.md`、`README.md`、`说明.md`、`CHANGELOG.md`、`SPONSORS.md`、`LICENSE`、`scripts/`（仅 Python）、`references/`、`sponsors/`。**不含任何 JavaScript / PowerShell，也不在安装时拉取外部代码**——被审计的产物就是实际运行的东西。

宿主专有的自动化（例如 OpenClaw 压缩钩子）**不属于本包范围**，只存在于仓库中、位于发布产物之外，并自带文档、固定版本号与校验和。

## 许可证

MIT 许可证 — 详见 [LICENSE](LICENSE)。

---

# 無限上下文壓縮與記憶優化

> 透過多層壓縮、自動備份和 FTS5 搜尋，讓任何模型持續對話而不中斷。

## 概述

小模型（128K 上下文）一次深度思考就可能耗盡視窗。InfinityContext 透過三層防護確保對話永不中斷：

1. **配置層**：`keepRecentTokens=15000` + 看門狗閾值 35%
2. **管線層**：自動備份→SQLite→壓縮→喚醒
3. **Hook 層**：`compaction-pipeline` hook 攔截所有壓縮路徑
4. **記憶層**：MEMORY.md 精簡 + FTS5 按需檢索

## 安裝

詳見上方英文版安裝步驟。

## 許可證

MIT 許可證 — 詳見 [LICENSE](LICENSE)。

---

# 無限コンテキスト圧縮とメモリ最適化

> 多層圧縮、自動バックアップ、FTS5検索で、あらゆるモデルを途切れなく会話させます。

## 概要

小規模モデル（128K コンテキスト）は一度の深い思考でウィンドウを消費する可能性があります。InfinityContext は3層の保護で会話が途切れないことを保証します：

1. **設定層**：`keepRecentTokens=15000` + ウォッチドッグしきい値35%
2. **パイプライン層**：自動バックアップ→SQLite→圧縮→ wake
3. **Hook 層**：`compaction-pipeline` hook がすべての圧縮パスを傍受
4. **メモリ層**：MEMORY.md 精査 + FTS5 オンデマンド検索

## ライセンス

MIT ライセンス — 詳細は [LICENSE](LICENSE)。

---

# 무한 컨텍스트 압축 및 메모리 최적화

> 다층 압축, 자동 백업, FTS5 검색으로 모든 모델이 끊김 없이 대화할 수 있게 합니다.

## 개요

소규모 모델(128K 컨텍스트)은 한 번의 깊은 사고로 윈도우를 소진할 수 있습니다. InfinityContext는 3계층 보호로 대화가 끊기지 않도록 보장합니다:

1. **설정 계층**: `keepRecentTokens=15000` + 워치독 임계값 35%
2. **파이프라인 계층**: 자동 백업→SQLite→압축→ wake
3. **Hook 계층**: `compaction-pipeline` hook이 모든 압축 경로를 가로챔
4. **메모리 계층**: MEMORY.md 정리 + FTS5 온디맨드 검색

## 라이선스

MIT 라이선스 — 자세한 내용은 [LICENSE](LICENSE)를 참조하세요.

---

# Compresión de Contexto Ilimitada y Optimización de Memoria

> Mantenga cualquier modelo en funcionamiento indefinidamente con compresión multicapa, backup automático y búsqueda FTS5.

## Descripción

Los modelos pequeños (128K de contexto) pueden agotar su ventana en un solo turno de pensamiento profundo. InfinityContext proporciona tres capas de protección:

1. **Capa de Configuración**: `keepRecentTokens=15000` + umbral del watchdog al 35%
2. **Capa de Pipeline**: Backup automático → SQLite → compresión → activación
3. **Capa de Hook**: El hook `compaction-pipeline` intercepta todas las rutas de compresión
4. **Capa de Memoria**: MEMORY.md optimizado + búsqueda FTS5 bajo demanda

## Licencia

Licencia MIT — ver [LICENSE](LICENSE).

---

# Compressão de Contexto Ilimitada e Otimização de Memória

> Mantenha qualquer modelo rodando indefinidamente com compressão multicamada, backup automático e busca FTS5.

## Descrição

Modelos pequenos (128K de contexto) podem esgotar sua janela em um único turno de pensamento profundo. Fornece três camadas de proteção:

1. **Camada de Configuração**: `keepRecentTokens=15000` + limiar do watchdog em 35%
2. **Camada de Pipeline**: Backup automático → SQLite → compressão → ativação
3. **Camada de Hook**: O hook `compaction-pipeline` intercepta todos os caminhos de compressão
4. **Camada de Memória**: MEMORY.md otimizado + busca FTS5 sob demanda

## Licença

Licença MIT — ver [LICENSE](LICENSE).

---

# Compression de Contexte Illimitée et Optimisation de la Mémoire

> Maintenez n'importe quel modèle en fonctionnement indefiniment avec compression multicouche, sauvegarde automatique et recherche FTS5.

## Description

Les petits modèles (128K de contexte) peuvent épuiser leur fenêtre en un seul tour de réflexion profonde. Fournit trois couches de protection :

1. **Couche de Configuration** : `keepRecentTokens=15000` + seuil du watchdog à 35%
2. **Couche de Pipeline** : Sauvegarde automatique → SQLite → compression → réveil
3. **Couche de Hook** : Le hook `compaction-pipeline` intercepte tous les chemins de compression
4. **Couche de Mémoire** : MEMORY.md optimisé + recherche FTS5 à la demande

## Licence

Licence MIT — voir [LICENSE](LICENSE).

---

# Unbegrenzte Kontextkompression und Speicheroptimierung

> Halten Sie jedes Modell mit mehrschichtiger Kompression, automatischem Backup und FTS5-Suche unbegrenzt am Laufen.

## Beschreibung

Kleine Modelle (128K Kontext) können ihr Fenster in einer einzigen Tiefdenk-Runde erschöpfen. Bietet drei Schutzschichten:

1. **Konfigurationsschicht**: `keepRecentTokens=15000` + Watchdog-Schwelle bei 35%
2. **Pipeline-Schicht**: Automatisches Backup → SQLite → Kompression → Aufwecken
3. **Hook-Schicht**: Der `compaction-pipeline`-Hook fängt alle Kompressionswege ab
4. **Speicherschicht**: MEMORY.md optimiert + FTS5-Abfrage bei Bedarf

## Lizenz

MIT-Lizenz — siehe [LICENSE](LICENSE).

---

# Безлимитное сжатие контекста и оптимизация памяти

> Поддерживайте любую модель в работе бесконечно с многоуровневым сжатием, автоматическим резервированием и поиском FTS5.

## Описание

Маленькие модели (128K контекста) могут исчерпать своё окно за один ход глубокого мышления. Предоставляет три уровня защиты:

1. **Уровень конфигурации**: `keepRecentTokens=15000` + порог сторожевого таймера 35%
2. **Уровень конвейера**: Автоматическое резервирование → SQLite → сжатие → пробуждение
3. **Уровень хука**: Хук `compaction-pipeline` перехватывает все пути сжатия
4. **Уровень памяти**: Оптимизированный MEMORY.md + поиск FTS5 по запросу

## Лицензия

Лицензия MIT — см. [LICENSE](LICENSE).



