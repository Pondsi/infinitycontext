---
version: 0.2.0
name: "infinity-context"
description: "OpenClaw上下文压缩与记忆优化：防小模型溢出、看门狗自动压缩、SQLite检索、MEMORY精简"
---

# InfinityContext - Unlimited Context Compression & Memory Optimization

> Keep any model running indefinitely with multi-layer compression, automatic backup, and FTS5 search.

## Overview

Small models (128K context) can exhaust their window in a single deep-thought turn. InfinityContext provides three layers of protection to ensure conversations never break:

1. **Config Layer**: `keepRecentTokens=15000` + watchdog threshold at 35%
2. **Pipeline Layer**: Automatic backup → SQLite → compression → wake
3. **Hook Layer**: `compaction-pipeline` hook intercepts ALL compaction paths (manual/auto/watchdog) ensuring backup → SQLite → enhanced summary coverage
4. **Memory Layer**: MEMORY.md streamlined + FTS5 on-demand retrieval

## Installation

### 1. OpenClaw Configuration

Add to `openclaw.json`:

```json
{
  "agents": {
    "defaults": {
      "compaction": {
        "mode": "safeguard",
        "keepRecentTokens": 15000,
        "model": "tokease/deepseek-v4-flash",
        "timeoutSeconds": 600,
        "midTurnPrecheck": { "enabled": true },
        "memoryFlush": {
          "model": "tokease/deepseek-v4-flash",
          "enabled": true,
          "softThresholdTokens": 10000
        }
      }
    }
  },
  "hooks": {
    "internal": {
      "entries": {
        "compaction-pipeline": { "enabled": true }
      },
      "load": {
        "extraDirs": ["~/.openclaw/hooks"]
      },
      "enabled": true
    }
  }
}
```

### 2. Deploy Scripts

Copy files from `scripts/` to `~/.openclaw/scripts/`:
- `main-session-monitor.ps1` — Watchdog (v6.8)
- `pipeline.ps1` — Hook pipeline (backup + SQLite + summary)
- `session-to-sqlite.ps1` — JSONL → SQLite wrapper

Copy `src/handler.js` and `src/HOOK.md` to `~/.openclaw/hooks/compaction-pipeline/`.

Copy `src/session_to_sqlite.py` to `~/.openclaw/scripts/`.

### 3. Create Scheduled Tasks

```powershell
# Watchdog: every 10 minutes
schtasks /Create /TN "OpenClaw-MainSessionMonitor" /TR `
  "powershell.exe -NoProfile -WindowStyle Hidden -File `"scripts\main-session-monitor.ps1`" -AutoCompact" `
  /SC MINUTE /MO 10 /RL LIMITED /F

# Backup cleanup: every 7 days
schtasks /Create /TN "OpenClaw-CleanupOldBackups" /TR `
  "powershell.exe -NoProfile -WindowStyle Hidden -File `"scripts\cleanup-old-backups.ps1`"" `
  /SC DAILY /MO 7 /ST 03:00 /RL LIMITED /F
```

### 4. Restart Gateway

```bash
openclaw gateway restart
```

## Architecture

```
Any compaction trigger (manual/auto/watchdog):
  │
  ├─ compact:before → pipeline.ps1
  │   ├─ export-trajectory (full history backup)
  │   └─ session-to-sqlite (JSONL → SQLite + FTS5)
  │
  ├─ OpenClaw executes compression
  │
  └─ compact:after → pipeline.ps1
      └─ enhanced summary (keyword index from SQLite)

Deduplication: if backup exists within 5 minutes, skip (avoids duplicate work)
```

## Space Guarantee (128K model)

```
Post-composition context:
  System prompt + tools  ≈ 30K tokens (fixed)
  Summary               ≈ 7K tokens
  Recent messages       = 15K tokens
  ─────────────────────────────
  Total                 = 52K / 131K (40%)
  Remaining             = 79K tokens

Worst-case single reply:
  thinking: 30K + reply: 10K + tools: 15K = 55K

  79K > 55K → guaranteed at least 1 full deep reply
```

## Configuration Reference

| Parameter | Default | Description |
|-----------|---------|-------------|
| keepRecentTokens | 15000 | Post-compaction retention (128K models) |
| ThresholdPct | 35.0 | Watchdog trigger threshold (%) |
| ThresholdAbsTokens | 60000 | Absolute token threshold |
| CompactCooldownMin | 5 | Cooldown between compressions |
| StickyLimit | 5 | Failures before pause |
| StickyPauseMin | 30 | Pause duration (minutes) |

## Key Fixes (v6.8)

| Version | Fix | Root Cause |
|---------|-----|------------|
| v5.9 | Dual condition trigger + session_chunks table | Wrong SQL table name |
| v6.3 | UTF-8 encoding forced | PS5.1 defaults to GBK |
| v6.3 | Control character cleanup | Invalid chars in session JSON |
| v6.4 | Colon path fix | Windows disallows colons in dirs |
| v6.5 | SqliteDir ASCII-only | Python sqlite3 can't handle Unicode paths |
| v6.6 | sticky pausedUntil write | State variable was read-only |
| v6.6 | sticky [long] for timestamps | [int] overflow on 13-digit ms |
| v6.7 | compaction-pipeline hook | Manual/auto compaction bypassed watchdog pipeline |
| v6.7 | handler.js exports.default | Hook loader couldn't find handler |
| v6.7 | pipeline.ps1 temp .py files | PowerShell string escaping broke inline Python |
| v6.8 | Unified backup pipeline + dedup | Watchdog and hook duplicated backup work |

## SQLite FTS5 Search

Compressed sessions are stored in SQLite with FTS5 trigram search:

```sql
-- Trigram search (≥3 characters)
SELECT * FROM chunk_fts WHERE chunk_fts MATCH 'keyword';

-- LIKE fallback (Chinese 2-char)
SELECT * FROM session_chunks WHERE raw_content LIKE '%keyword%';
```

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for full history.

## License

MIT License — see [LICENSE](LICENSE).

---

# 无限上下文压缩与记忆优化

> 通过多层压缩、自动备份和 FTS5 搜索，让任何模型持续对话而不中断。

## 概述

小模型（128K 上下文）一次深度思考就可能耗尽窗口。InfinityContext 通过三层防护确保对话永不中断：

1. **配置层**：`keepRecentTokens=15000` + 看门狗阈值 35%
2. **管线层**：自动备份→SQLite→压缩→唤醒
3. **Hook 层**：`compaction-pipeline` hook 拦截所有压缩路径，确保备份→SQLite→增强摘要全覆盖
4. **记忆层**：MEMORY.md 精简 + FTS5 按需检索

## 安装

详见上方英文版安装步骤。

## 架构

```
任意压缩触发（手动/自动/看门狗）
  ├─ compact:before → pipeline.ps1（备份+SQLite）
  ├─ OpenClaw 执行压缩
  └─ compact:after → pipeline.ps1（增强摘要）
去重机制：5分钟内已有备份则跳过
```

## 配置参考

| 参数 | 默认值 | 说明 |
|------|--------|------|
| keepRecentTokens | 15000 | 压缩后保留（128K 模型） |
| ThresholdPct | 35.0 | 看门狗触发阈值（%） |
| ThresholdAbsTokens | 60000 | 绝对值门槛 |
| StickyLimit | 5 | 连续失败暂停阈值 |
| StickyPauseMin | 30 | 暂停时长（分钟） |

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



