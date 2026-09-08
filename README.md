# InfinityContext

**Open-Source Context Compression & Memory Optimization for AI Agents**

[English](#english) | [简体中文](#简体中文) | [繁體中文](#繁體中文) | [日本語](#日本語) | [한국어](#한국어) | [Español](#español) | [Português](#português) | [Français](#français) | [Deutsch](#deutsch) | [Русский](#русский)

---

## English

### What is this?

InfinityContext is a **universal AI agent skill** that keeps your conversations forever — no context overflow, no forgotten goals, no lost details. Works with **any agent platform**: OpenClaw, Claude, ChatGPT, Gemini, Dify, Ollama, Cursor, or custom API.

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
# 1. Clone the repository
git clone https://github.com/Pondsi/infinitycontext.git

# 2. Copy scripts to OpenClaw
cp scripts/* ~/.openclaw/scripts/
cp src/* ~/.openclaw/hooks/compaction-pipeline/

# 3. Update openclaw.json (see SKILL.md for full config)

# 4. Restart gateway
openclaw gateway restart
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

- OpenClaw installed and running
- PowerShell 5.1+ (Windows)
- Python 3.x (for SQLite conversion)

### Sponsors

If you find this project helpful, consider supporting its development! See [SPONSORS.md](SPONSORS.md) for donation options.

### License

MIT License

---

## 简体中文

### 这是什么？

InfinityContext 是一个**通用 AI 智能体技能**，让你的对话永远完整——不溢出、不遗忘目标、不丢失任何细节。适用于**所有智能体平台**：OpenClaw、Claude、ChatGPT、Gemini、Dify、Ollama、Cursor，或任何自定义 API。

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
# 1. 克隆仓库
git clone https://github.com/Pondsi/infinitycontext.git

# 2. 复制脚本到 OpenClaw
cp scripts/* ~/.openclaw/scripts/
cp src/* ~/.openclaw/hooks/compaction-pipeline/

# 3. 更新 openclaw.json（完整配置见 SKILL.md）

# 4. 重启 Gateway
openclaw gateway restart
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

- OpenClaw 已安装并运行
- PowerShell 5.1+（Windows）
- Python 3.x（用于 SQLite 转换）

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
git clone https://github.com/Pondsi/infinitycontext.git
cp scripts/* ~/.openclaw/scripts/
cp src/* ~/.openclaw/hooks/compaction-pipeline/
openclaw gateway restart
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
git clone https://github.com/Pondsi/infinitycontext.git
cp scripts/* ~/.openclaw/scripts/
cp src/* ~/.openclaw/hooks/compaction-pipeline/
openclaw gateway restart
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
git clone https://github.com/Pondsi/infinitycontext.git
cp scripts/* ~/.openclaw/scripts/
cp src/* ~/.openclaw/hooks/compaction-pipeline/
openclaw gateway restart
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
git clone https://github.com/Pondsi/infinitycontext.git
cp scripts/* ~/.openclaw/scripts/
cp src/* ~/.openclaw/hooks/compaction-pipeline/
openclaw gateway restart
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
git clone https://github.com/Pondsi/infinitycontext.git
cp scripts/* ~/.openclaw/scripts/
cp src/* ~/.openclaw/hooks/compaction-pipeline/
openclaw gateway restart
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
git clone https://github.com/Pondsi/infinitycontext.git
cp scripts/* ~/.openclaw/scripts/
cp src/* ~/.openclaw/hooks/compaction-pipeline/
openclaw gateway restart
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
git clone https://github.com/Pondsi/infinitycontext.git
cp scripts/* ~/.openclaw/scripts/
cp src/* ~/.openclaw/hooks/compaction-pipeline/
openclaw gateway restart
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
git clone https://github.com/Pondsi/infinitycontext.git
cp scripts/* ~/.openclaw/scripts/
cp src/* ~/.openclaw/hooks/compaction-pipeline/
openclaw gateway restart
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
