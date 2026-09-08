# InfinityContext — other languages

`SKILL.md` carries the two canonical sections (English and 简体中文) so that it
stays small enough for an agent to load on every turn. The remaining localised
summaries live here and are read only when someone asks for that language.

Each section describes the same three scripts, the same safety rules and the
same host support as the English section.

---

# 無限上下文壓縮與記憶優化

> 透過多層壓縮、自動備份和 FTS5 搜尋，讓任何模型持續對話而不中斷。

## 概述

小模型（128K 上下文）一次深度思考就可能耗盡視窗。InfinityContext 透過多層防護確保對話永不中斷：

1. **配置層**：`keepRecentTokens=15000` + 看門狗閾值 35%
2. **管線層**：自動備份 → SQLite → 壓縮 → 喚醒
3. **Hook 層**：`compaction-pipeline` hook 攔截所有壓縮路徑
4. **記憶層**：MEMORY.md 精簡 + FTS5 按需檢索

## 安裝

詳見 `SKILL.md` 的英文安裝步驟（註冊表安裝優先；原始碼安裝需固定 tag 並校驗 `checksums.txt`）。

## 許可證

MIT 許可證 — 詳見 [LICENSE](../LICENSE)。

---

# 無限コンテキスト圧縮とメモリ最適化

> 多層圧縮、自動バックアップ、FTS5検索で、あらゆるモデルを途切れなく会話させます。

## 概要

小規模モデル（128K コンテキスト）は一度の深い思考でウィンドウを消費する可能性があります。InfinityContext は多層の保護で会話が途切れないことを保証します：

1. **設定層**：`keepRecentTokens=15000` + ウォッチドッグしきい値35%
2. **パイプライン層**：自動バックアップ → SQLite → 圧縮 → ウェイク
3. **Hook 層**：`compaction-pipeline` hook がすべての圧縮パスを傍受
4. **メモリ層**：MEMORY.md 精査 + FTS5 オンデマンド検索

## インストール

`SKILL.md` の英語インストール手順を参照してください（レジストリからのインストールを推奨。ソースからは固定タグ + `checksums.txt` 検証が必要）。

## ライセンス

MIT ライセンス — 詳細は [LICENSE](../LICENSE)。

---

# 무한 컨텍스트 압축 및 메모리 최적화

> 다층 압축, 자동 백업, FTS5 검색으로 모든 모델이 끊김 없이 대화할 수 있게 합니다.

## 개요

소규모 모델(128K 컨텍스트)은 한 번의 깊은 사고로 윈도우를 소진할 수 있습니다. InfinityContext는 다계층 보호로 대화가 끊기지 않도록 보장합니다:

1. **설정 계층**: `keepRecentTokens=15000` + 워치독 임계값 35%
2. **파이프라인 계층**: 자동 백업 → SQLite → 압축 → 웨이크
3. **Hook 계층**: `compaction-pipeline` hook이 모든 압축 경로를 가로챔
4. **메모리 계층**: MEMORY.md 정리 + FTS5 온디맨드 검색

## 설치

`SKILL.md`의 영어 설치 절차를 참조하세요(레지스트리 설치 권장, 소스 설치는 고정 태그 + `checksums.txt` 검증 필요).

## 라이선스

MIT 라이선스 — 자세한 내용은 [LICENSE](../LICENSE)를 참조하세요.

---

# Compresión de Contexto Ilimitada y Optimización de Memoria

> Mantenga cualquier modelo en funcionamiento indefinidamente con compresión multicapa, backup automático y búsqueda FTS5.

## Descripción

Los modelos pequeños (128K de contexto) pueden agotar su ventana en un solo turno de pensamiento profundo. InfinityContext proporciona varias capas de protección:

1. **Capa de Configuración**: `keepRecentTokens=15000` + umbral del watchdog al 35%
2. **Capa de Pipeline**: Backup automático → SQLite → compresión → activación
3. **Capa de Hook**: El hook `compaction-pipeline` intercepta todas las rutas de compresión
4. **Capa de Memoria**: MEMORY.md optimizado + búsqueda FTS5 bajo demanda

## Instalación

Consulte los pasos de instalación en inglés de `SKILL.md` (se recomienda el registro; desde el código fuente se exige una etiqueta fija y verificar `checksums.txt`).

## Licencia

Licencia MIT — ver [LICENSE](../LICENSE).

---

# Compressão de Contexto Ilimitada e Otimização de Memória

> Mantenha qualquer modelo rodando indefinidamente com compressão multicamada, backup automático e busca FTS5.

## Descrição

Modelos pequenos (128K de contexto) podem esgotar sua janela em um único turno de pensamento profundo. Fornece várias camadas de proteção:

1. **Camada de Configuração**: `keepRecentTokens=15000` + limiar do watchdog em 35%
2. **Camada de Pipeline**: Backup automático → SQLite → compressão → ativação
3. **Camada de Hook**: O hook `compaction-pipeline` intercepta todos os caminhos de compressão
4. **Camada de Memória**: MEMORY.md otimizado + busca FTS5 sob demanda

## Instalação

Consulte as etapas de instalação em inglês do `SKILL.md` (registro recomendado; a partir do código-fonte é obrigatório usar uma tag fixa e verificar `checksums.txt`).

## Licença

Licença MIT — ver [LICENSE](../LICENSE).

---

# Compression de Contexte Illimitée et Optimisation de la Mémoire

> Maintenez n'importe quel modèle en fonctionnement indéfiniment avec compression multicouche, sauvegarde automatique et recherche FTS5.

## Description

Les petits modèles (128K de contexte) peuvent épuiser leur fenêtre en un seul tour de réflexion profonde. Fournit plusieurs couches de protection :

1. **Couche de Configuration** : `keepRecentTokens=15000` + seuil du watchdog à 35%
2. **Couche de Pipeline** : Sauvegarde automatique → SQLite → compression → réveil
3. **Couche de Hook** : Le hook `compaction-pipeline` intercepte tous les chemins de compression
4. **Couche de Mémoire** : MEMORY.md optimisé + recherche FTS5 à la demande

## Installation

Voir les étapes d'installation en anglais dans `SKILL.md` (registre recommandé ; depuis les sources, un tag fixe et la vérification de `checksums.txt` sont obligatoires).

## Licence

Licence MIT — voir [LICENSE](../LICENSE).

---

# Unbegrenzte Kontextkompression und Speicheroptimierung

> Halten Sie jedes Modell mit mehrschichtiger Kompression, automatischem Backup und FTS5-Suche unbegrenzt am Laufen.

## Beschreibung

Kleine Modelle (128K Kontext) können ihr Fenster in einer einzigen Tiefdenk-Runde erschöpfen. Bietet mehrere Schutzschichten:

1. **Konfigurationsschicht**: `keepRecentTokens=15000` + Watchdog-Schwelle bei 35%
2. **Pipeline-Schicht**: Automatisches Backup → SQLite → Kompression → Aufwecken
3. **Hook-Schicht**: Der `compaction-pipeline`-Hook fängt alle Kompressionswege ab
4. **Speicherschicht**: MEMORY.md optimiert + FTS5-Abfrage bei Bedarf

## Installation

Siehe die englischen Installationsschritte in `SKILL.md` (Registry empfohlen; aus dem Quellcode sind ein fester Tag und die Prüfung von `checksums.txt` erforderlich).

## Lizenz

MIT-Lizenz — siehe [LICENSE](../LICENSE).

---

# Безлимитное сжатие контекста и оптимизация памяти

> Поддерживайте любую модель в работе бесконечно с многоуровневым сжатием, автоматическим резервным копированием и поиском FTS5.

## Описание

Маленькие модели (128K контекста) могут исчерпать своё окно за один ход глубокого мышления. Предоставляет несколько уровней защиты:

1. **Уровень конфигурации**: `keepRecentTokens=15000` + порог сторожевого таймера 35%
2. **Уровень конвейера**: Автоматическое резервное копирование → SQLite → сжатие → пробуждение
3. **Уровень хука**: Хук `compaction-pipeline` перехватывает все пути сжатия
4. **Уровень памяти**: Оптимизированный MEMORY.md + поиск FTS5 по запросу

## Установка

См. английские шаги установки в `SKILL.md` (рекомендуется реестр; из исходников обязательны фиксированный тег и проверка `checksums.txt`).

## Лицензия

Лицензия MIT — см. [LICENSE](../LICENSE).
