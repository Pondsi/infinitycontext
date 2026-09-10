# L1 模型降级链（memory-tencentdb 补丁）

## 解决什么问题

`memory-tencentdb` 跑 L1 提取 / L2 场景 / L3 画像时用「干净上下文」运行，
`plugins.enabled=false` → 只注册 8 个核心内置 API。原生 `ollama` 由插件注册 →
必报 `No API provider registered for api: ollama`。而且作为共享 skill，其他安装者的
模型配置各不相同，不能硬编码任何具体模型。

## 补丁内容

对插件 `dist/index.mjs` 就地打补丁：

| 标记 | 说明 |
|---|---|
| P1 | 新增 `resolveModelChain()` —— 有序降级链 + api 可用性过滤 |
| P2a | 采集侧：从 `agent_end` 的 raw messages 倒序取 assistant 的 provider/model，落旁路文件 |
| P2b | 派发侧：读旁路文件，链首优先「会话最后模型」 |
| P2c–e | 把 sessionModel 一路传到 `CleanContextRunner` |

降级链顺序（先到先用，去重，剔除干净运行时不可用的 api）：

1. 该会话最后使用的模型（P2 旁路文件）
2. 该代理默认模型 `agents.entries[<agentId>].model.primary`
3. 全局默认模型 `agents.defaults.model.primary`
4. 该代理调用链 `agents.entries[<agentId>].model.fallbacks[]`
5. 全局调用链 `agents.defaults.model.fallbacks[]`

证据日志（info 级）：
- `[l0] session last-used model -> <provider>/<model>` — 采集侧落盘
- `[l1] session last-used model: <provider>/<model>` — 派发侧读取
- `[l1] model chain: A/B -> C/D -> ...` — 最终生效的完整降级链

## 用法

```powershell
# 打补丁（自动定位插件 dist；幂等）
.\scripts\apply.ps1

# 只体检
.\scripts\apply.ps1 -Check

# 从最近备份还原
.\scripts\apply.ps1 -Restore

# 也可手动指定 dist 路径
python patch_l1_model_chain.py "<openclaw-npm>/.../memory-tencentdb/dist/index.mjs"
```

打完补丁后 `openclaw daemon restart`（进程级重启，ESM 缓存）。

## 校验

脚本每次执行：锚点恰好命中 1 次 → 写前备份 → `node --check` → sha256 → 幂等跳过。
