# 内部会话静默化（只留异常）

## 解决什么问题

`memory-tencentdb` 每次跑 L1 提取 / 冲突检测 / L2 场景提取 / L3 画像，
都会发起一次独立「干净上下文运行」。网关按运行建 session node，
侧边栏 Other 区就多出一行。`delivery.kind=none` 只表示「跑完不播报」，
**不等于不注册会话**。

## 判定规则

| status | 清未读徽章 | 归档 | 意图 |
|---|---|---|---|
| `done`（成功） | ✅ 清（顺带） | ✅ 归档 | 成功的不该占位 |
| `running` 等其它 | ❌ 不碰 | ❌ 不归档 | — |
| `failed` / `timeout` / `error` | ❌ **绝不碰** | ❌ **绝不碰** | **异常必须保留红色徽章** |

## 用法

```powershell
python archive-internal-sessions.py --selftest    # 分类自测（4 项断言）
python archive-internal-sessions.py --status       # 查看当前状态
python archive-internal-sessions.py --dry-run      # 只报告
python archive-internal-sessions.py                # 执行
python archive-internal-sessions.py --loop 55 --interval 5  # 循环模式
```

## 计划任务

`.\install-task.ps1` 注册 `OpenClaw-InternalSessionArchive`，
每 1 分钟启动 55 秒循环（Task Scheduler 重复间隔最小 1 分钟）。
