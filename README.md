# InfinityContext

**Open-Source Context Compression & Memory Optimization for OpenClaw**

[English](#english) | [简体中文](#简体中文) | [繁體中文](#繁體中文) | [日本語](#日本語) | [한국어](#한국어) | [Español](#español) | [Português](#português) | [Français](#français) | [Deutsch](#deutsch) | [Русский](#русский)

---

## English

### What is this?

InfinityContext is an OpenClaw Skill that prevents context overflow in small models (128K context). It provides multi-layer compression, automatic backup, and FTS5 search to keep conversations running indefinitely.

### Features

- **Multi-layer protection**: Config → Pipeline → Hook → Memory
- **Automatic backup**: Trajectory exported before every compaction
- **SQLite + FTS5 search**: Compressed sessions searchable via trigram index
- **Deduplication**: 5-minute window prevents duplicate backups
- **All compaction paths**: Manual, auto-compact, and watchdog all covered

### Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/Pondsi/openclaw-infinity-context.git

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

### License

MIT License

---

## 简体中文

### 这是什么？

InfinityContext 是一个 OpenClaw Skill，解决小模型（128K 上下文）对话中上下文溢出的问题。通过多层压缩机制，让任何大小的模型都能持续对话而不中断。

### 功能特性

- **三层防护**：配置层 → 管线层 → Hook 层 → 记忆层
- **自动备份**：每次压缩前导出完整轨迹
- **SQLite + FTS5 搜索**：压缩后的会话可通过三元组索引搜索
- **去重机制**：5 分钟窗口避免重复备份
- **全覆盖压缩路径**：手动、自动压缩、看门狗全部覆盖

### 快速开始

```bash
# 1. 克隆仓库
git clone https://github.com/Pondsi/openclaw-infinity-context.git

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

InfinityContext 是一個 OpenClaw Skill，解決小模型（128K 上下文）對話中上下文溢出的問題。透過多層壓縮機制，讓任何大小的模型都能持續對話而不中斷。

### 功能特性

- **三層防護**：配置層 → 管線層 → Hook 層 → 記憶層
- **自動備份**：每次壓縮前導出完整軌跡
- **SQLite + FTS5 搜尋**：壓縮後的會話可透過三元組索引搜尋
- **去重機制**：5 分鐘視窗避免重複備份
- **全覆蓋壓縮路徑**：手動、自動壓縮、看門狗全部覆蓋

### 快速開始

```bash
git clone https://github.com/Pondsi/openclaw-infinity-context.git
cp scripts/* ~/.openclaw/scripts/
cp src/* ~/.openclaw/hooks/compaction-pipeline/
openclaw gateway restart
```

### 許可證

MIT 許可證

---

## 日本語

### これは何？

InfinityContext は、小規模モデル（128K コンテキスト）のコンテキストオーバーフローを防止する OpenClaw Skill です。多層圧縮、自動バックアップ、FTS5 検索で会話を途切れなく維持します。

### 機能

- **多層保護**：設定 → パイプライン → Hook → メモリ
- **自動バックアップ**：圧縮前に完全な軌跡をエクスポート
- **SQLite + FTS5 検索**：圧縮セッションをトライグラムインデックスで検索
- **重複排除**：5分ウィンドウで重複バックアップを防止

### クイックスタート

```bash
git clone https://github.com/Pondsi/openclaw-infinity-context.git
cp scripts/* ~/.openclaw/scripts/
cp src/* ~/.openclaw/hooks/compaction-pipeline/
openclaw gateway restart
```

### ライセンス

MIT ラ이センス

---

## 한국어

### 이것은 무엇인가?

InfinityContext는 소규모 모델(128K 컨텍스트)의 컨텍스트 오버플로우를 방지하는 OpenClaw Skill입니다. 다층 압축, 자동 백업, FTS5 검색으로 대화를 끊김 없이 유지합니다.

### 기능

- **다층 보호**: 설정 → 파이프라인 → Hook → 메모리
- **자동 백업**: 압缩 전 완전한轨迹 내보내기
- **SQLite + FTS5 검색**: 압축 세션을 트리그램 인덱스로 검색
- **중복 제거**: 5분 윈도우로 중복 백업 방지

### 빠른 시작

```bash
git clone https://github.com/Pondsi/openclaw-infinity-context.git
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
git clone https://github.com/Pondsi/openclaw-infinity-context.git
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
git clone https://github.com/Pondsi/openclaw-infinity-context.git
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
git clone https://github.com/Pondsi/openclaw-infinity-context.git
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
git clone https://github.com/Pondsi/openclaw-infinity-context.git
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
git clone https://github.com/Pondsi/openclaw-infinity-context.git
cp scripts/* ~/.openclaw/scripts/
cp src/* ~/.openclaw/hooks/compaction-pipeline/
openclaw gateway restart
```

### Лицензия

Лицензия MIT
