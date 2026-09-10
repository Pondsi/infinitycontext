---
name: memory-flush-dedup
description: "Deduplicate byte-identical memory sections repeatedly appended to daily memory files when compaction memoryFlush retries re-run after a failed compaction."
metadata:
  {
    "openclaw":
      {
        "emoji": "🧹",
        "events": ["session:compact:after"],
        "always": true,
      },
  }
---

# Memory Flush Dedup Hook

**背景（2026-09-10 根因定位）**：compaction memoryFlush（压缩前 agentic 记忆写入）在「flush 已写盘但压缩主步骤失败」后整体重试时，会把相同内容原样再追加到当日日记（memory/YYYY-MM-DD.md），造成成对重复块（09-10 曾 4 连重复；08-08 起 14 个日记文件均有同款问题）。本钩子在每次压缩完成后立即清除这类重复。

## 行为

- 触发：`session:compact:after`（所有 agent 的压缩完成后，进程内执行）。
- 扫描对象：`~/.openclaw/workspace*/memory/` 下最近 24h 内修改过的 `YYYY-MM-DD*.md` 日记。
- 去重规则（保守）：按 `^## ` 标题切分 section；两个 section 的**非空行内容完全一致**（忽略行尾空白、空行数量、独立成行的 HTML 注释标记）才视为重复，只保留**第一份**，后续原样删除。内容有任何实质差异一律保留（宁漏勿删）。
- 修改前自动备份到 `memory/.bak/<名>.<时间戳>.dedup.bak`；自动清理 14 天前的 `.dedup.bak`。
- 日志：`~/.openclaw/logs/memory-flush-dedup.log`。所有异常只记日志、不抛出（绝不影响压缩主流程）。

## CLI 模式（直接 node 运行）

```powershell
node handler.js --scan --dry-run   # 全量历史日记 dry-run，只报告
node handler.js --scan             # 全量历史日记去重（自动备份）
node handler.js --file <路径>      # 处理单个文件
```

## 已知边界

- 跨 flush 的「近似重复」（如一版带 project 标记、一版不带）在 key 比较时视为相同并保留带标记的**第一份**；其余实质差异不合并。
- 只处理日记文件；MEMORY.md 与场景库不碰。
