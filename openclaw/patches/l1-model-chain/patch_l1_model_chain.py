# -*- coding: utf-8 -*-
"""
patch_l1_model_chain.py — memory-tencentdb L1/L2/L3 模型解析加固（可移植版）

作用：对 memory-tencentdb 插件的 dist/index.mjs 就地打补丁：
  P1  干净上下文（L1/L2/L3）模型改为「有序降级链 + api 可用性过滤」
  P2  链首优先「该会话最后使用的模型」（在 L0 采集时把 provider/model 落旁路文件）

降级链顺序：该会话最后模型 → 该代理默认 → 全局默认 → 该代理调用链 → 全局默认调用链。
自动过滤：干净运行时（plugins.enabled=false）只注册 8 个核心内置 api，
  由插件注册的 api（如原生 ollama）一律剔除。

用法：
  python patch_l1_model_chain.py [dist路径]           # 打补丁（幂等）
  python patch_l1_model_chain.py [dist路径] --check    # 只体检
  python patch_l1_model_chain.py [dist路径] --restore  # 从最近备份还原

dist 路径可省略：自动扫描 ~/.openclaw/npm/**/memory-tencentdb/dist/index.mjs。
"""
import io, os, sys, glob, time, shutil, subprocess, hashlib, re

sys.stdout.reconfigure(encoding="utf-8")

HOME = os.path.expanduser("~")


def find_dist(explicit=None):
    """自动定位插件 dist/index.mjs（显式路径优先；否则扫描 ~/.openclaw/npm）。"""
    if explicit and os.path.isfile(explicit):
        return explicit
    pat = os.path.join(HOME, ".openclaw", "npm", "**", "memory-tencentdb", "dist", "index.mjs")
    hits = glob.glob(pat, recursive=True)
    if len(hits) == 1:
        return hits[0]
    if len(hits) > 1:
        print("发现 %d 个候选，请指定：\n  %s" % (len(hits), "\n  ".join(hits)))
        sys.exit(1)
    print("未找到 memory-tencentdb 插件 dist（已扫描 ~/.openclaw/npm）。")
    print("用法：python patch_l1_model_chain.py <dist/index.mjs 路径>")
    sys.exit(1)


DIST = find_dist(sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else None)

MODE = "apply"
if "--check" in sys.argv:
    MODE = "check"
if "--restore" in sys.argv:
    MODE = "restore"


def fail(msg):
    print("  [FAIL] " + msg)
    sys.exit(1)


def do_restore():
    baks = sorted(glob.glob(DIST + ".bak-l1chain-*"))
    if not baks:
        fail("找不到备份 " + DIST + ".bak-l1chain-*")
    src = baks[-1]
    shutil.copy2(src, DIST)
    print("  已还原：%s -> %s" % (os.path.basename(src), os.path.basename(DIST)))
    print("  还原后需重启网关生效。")
    sys.exit(0)


if MODE == "restore":
    do_restore()

if not os.path.exists(DIST):
    fail("插件 dist 不存在：" + DIST)

s = io.open(DIST, encoding="utf-8").read()
orig = s
applied = []
skipped = []


def replace_once(name, old, new, sentinel=None):
    global s
    if sentinel and sentinel in s:
        skipped.append(name + " (已应用)")
        return
    n = s.count(old)
    if n != 1:
        fail("%s 锚点命中 %d 次（应为 1）" % (name, n))
    s = s.replace(old, new, 1)
    applied.append(name)


# ============================================================ P1: 链 helper
HELPER = '''/**
* Clean-runtime model chain (patch 2026-09-10).
*
* The clean context run forces `plugins.enabled = false`, so only the host's
* built-in API providers exist. A model whose provider `api` is registered by a
* plugin (native `ollama`, ...) can never resolve there and hard-fails every run.
*
* Ordered preference, deduplicated, unusable entries dropped.
*/
const CLEAN_RUNTIME_CORE_APIS = new Set([
\t"anthropic-messages",
\t"openai-completions",
\t"mistral-conversations",
\t"openai-responses",
\t"azure-openai-responses",
\t"openai-chatgpt-responses",
\t"google-generative-ai",
\t"google-vertex"
]);
function cleanRuntimeProviderApi(config, providerId) {
\tif (!providerId) return void 0;
\tconst providers = config && typeof config === "object" ? config.models && config.models.providers : void 0;
\tif (!providers || typeof providers !== "object") return void 0;
\tconst entry = providers[providerId];
\tif (!entry || typeof entry !== "object") return void 0;
\tconst api = typeof entry.api === "string" ? entry.api.trim().toLowerCase() : "";
\treturn api || void 0;
}
function cleanRuntimeModelUsable(config, ref) {
\tconst parsed = parseModelRef(ref);
\tif (!parsed) return false;
\tconst api = cleanRuntimeProviderApi(config, parsed.provider);
\tif (!api) return true; // provider not declared locally - let the host decide
\treturn CLEAN_RUNTIME_CORE_APIS.has(api);
}
function pushModelRefs(modelCfg, out) {
\tif (!modelCfg) return;
\tif (typeof modelCfg === "string") {
\t\tconst v = modelCfg.trim();
\t\tif (v) out.push(v);
\t\treturn;
\t}
\tif (typeof modelCfg !== "object") return;
\tif (typeof modelCfg.primary === "string" && modelCfg.primary.trim()) out.push(modelCfg.primary.trim());
\tif (Array.isArray(modelCfg.fallbacks)) {
\t\tfor (const f of modelCfg.fallbacks) {
\t\t\tif (typeof f === "string" && f.trim()) out.push(f.trim());
\t\t}
\t}
}
function resolveModelChain(config, agentId, sessionModel) {
\tif (!config || typeof config !== "object") return [];
\tconst agents = config.agents;
\tif (!agents || typeof agents !== "object") return [];
\tconst entries = agents.entries && typeof agents.entries === "object" ? agents.entries : {};
\tconst agentEntry = agentId && entries[agentId] && typeof entries[agentId] === "object" ? entries[agentId] : void 0;
\tconst raw = [];
\tif (typeof sessionModel === "string" && sessionModel.trim()) raw.push(sessionModel.trim());
\tpushModelRefs(agentEntry && agentEntry.model, raw);
\tpushModelRefs(agents.defaults && agents.defaults.model, raw);
\tconst seen = new Set();
\tconst chain = [];
\tfor (const ref of raw) {
\t\tif (!ref || ref.indexOf("/") <= 0) continue;
\t\tconst key = ref.toLowerCase();
\t\tif (seen.has(key)) continue;
\t\tseen.add(key);
\t\tchain.push(ref);
\t}
\tconst usable = chain.filter((ref) => cleanRuntimeModelUsable(config, ref));
\treturn usable.length > 0 ? usable : chain;
}
'''
replace_once(
    "P1 helper(resolveModelChain)",
    "var CleanContextRunner = class {",
    HELPER + "\nvar CleanContextRunner = class {",
    sentinel="function resolveModelChain(config, agentId, sessionModel)",
)

# ==================================================== P1: constructor 分支
replace_once(
    "P1 constructor(chain branch)",
    "\t\t} else {\n"
    "\t\t\tconst fromConfig = resolveModelFromMainConfig(options.config);\n"
    "\t\t\tif (fromConfig) {\n"
    "\t\t\t\tthis.resolvedProvider = fromConfig.provider;\n"
    "\t\t\t\tthis.resolvedModel = fromConfig.model;\n"
    "\t\t\t\tthis.logger?.debug?.(`${TAG$26} Using model from main config: ${fromConfig.provider}/${fromConfig.model}`);\n"
    "\t\t\t}\n"
    "\t\t}",
    "\t\t} else {\n"
    "\t\t\tconst chain = resolveModelChain(options.config, options.agentId, options.sessionModel);\n"
    "\t\t\tconst firstRef = chain.length > 0 ? parseModelRef(chain[0]) : void 0;\n"
    "\t\t\tif (firstRef) {\n"
    "\t\t\t\tthis.resolvedProvider = firstRef.provider;\n"
    "\t\t\t\tthis.resolvedModel = firstRef.model;\n"
    "\t\t\t\tthis.resolvedFallbackChain = chain.slice(1);\n"
    "\t\t\t\tthis.logger?.debug?.(`${TAG$26} Using model chain: ${chain.join(\" -> \")}`);\n"
    "\t\t\t} else {\n"
    "\t\t\t\tconst fromConfig = resolveModelFromMainConfig(options.config);\n"
    "\t\t\t\tif (fromConfig) {\n"
    "\t\t\t\t\tthis.resolvedProvider = fromConfig.provider;\n"
    "\t\t\t\t\tthis.resolvedModel = fromConfig.model;\n"
    "\t\t\t\t\tthis.logger?.debug?.(`${TAG$26} Using model from main config: ${fromConfig.provider}/${fromConfig.model}`);\n"
    "\t\t\t\t}\n"
    "\t\t\t}\n"
    "\t\t}",
    sentinel="const chain = resolveModelChain(options.config, options.agentId, options.sessionModel);",
)

# ============================================= P1: 把链作为 fallbacks 交给宿主
replace_once(
    "P1 inject fallbacks into cleanConfig",
    "const result = await runDetachedWork(() => embeddedAgentRunner({",
    "\t\t\tif (this.resolvedProvider && this.resolvedModel && this.resolvedFallbackChain && this.resolvedFallbackChain.length > 0) {\n"
    "\t\t\t\tcleanConfig.agents = cleanConfig.agents || {};\n"
    "\t\t\t\tcleanConfig.agents.defaults = {\n"
    "\t\t\t\t\t...(cleanConfig.agents.defaults || {}),\n"
    "\t\t\t\t\tmodel: {\n"
    "\t\t\t\t\t\tprimary: this.resolvedProvider + \"/\" + this.resolvedModel,\n"
    "\t\t\t\t\t\tfallbacks: this.resolvedFallbackChain\n"
    "\t\t\t\t\t}\n"
    "\t\t\t\t};\n"
    "\t\t\t}\n"
    "\t\t\tconst result = await runDetachedWork(() => embeddedAgentRunner({",
    sentinel="fallbacks: this.resolvedFallbackChain",
)

# ================================================== P2: 采集侧落「会话最后模型」
CAPTURE_SNIPPET = (
    "\tconst __lastUsedModel = (() => {\n"
    "\t\ttry {\n"
    "\t\t\tconst arr = Array.isArray(messages) ? messages : [];\n"
    "\t\t\tfor (let i = arr.length - 1; i >= 0; i--) {\n"
    "\t\t\t\tconst m = arr[i];\n"
    "\t\t\t\tif (!m || typeof m !== \"object\") continue;\n"
    "\t\t\t\tif (m.role !== \"assistant\") continue;\n"
    "\t\t\t\tif (typeof m.provider === \"string\" && m.provider && typeof m.model === \"string\" && m.model) return { provider: m.provider, model: m.model };\n"
    "\t\t\t}\n"
    "\t\t\tfor (let i = arr.length - 1; i >= 0; i--) {\n"
    "\t\t\t\tconst m = arr[i];\n"
    "\t\t\t\tif (!m || typeof m !== \"object\") continue;\n"
    "\t\t\t\tif (typeof m.provider === \"string\" && m.provider && typeof m.model === \"string\" && m.model) return { provider: m.provider, model: m.model };\n"
    "\t\t\t}\n"
    "\t\t} catch {}\n"
    "\t\treturn void 0;\n"
    "\t})();\n"
    "\tif (__lastUsedModel) {\n"
    "\t\ttry {\n"
    "\t\t\tconst __safeKey = String(sessionKey).replace(/[^A-Za-z0-9._-]+/g, \"_\").slice(0, 180);\n"
    "\t\t\tconst __dir = pluginDataDir + \"/.session-model\";\n"
    "\t\t\tconst __payload = JSON.stringify({ provider: __lastUsedModel.provider, model: __lastUsedModel.model, ts: Date.now() });\n"
    "\t\t\tlogger?.info?.(`${TAG$23} [l0] session last-used model -> ${__lastUsedModel.provider}/${__lastUsedModel.model}`);\n"
    "\t\t\tPromise.resolve().then(() => import(\"node:fs\")).then((__fs) => {\n"
    "\t\t\t\ttry {\n"
    "\t\t\t\t\t__fs.mkdirSync(__dir, { recursive: true });\n"
    "\t\t\t\t\t__fs.writeFileSync(__dir + \"/\" + __safeKey + \".json\", __payload);\n"
    "\t\t\t\t} catch {}\n"
    "\t\t\t}).catch(() => {});\n"
    "\t\t} catch {}\n"
    "\t}\n"
)
replace_once(
    "P2a capture: persist session last-used model",
    "\tconst tL0RecordEnd = performance.now();\n\tconst tL0VecStart = performance.now();",
    "\tconst tL0RecordEnd = performance.now();\n" + CAPTURE_SNIPPET + "\tconst tL0VecStart = performance.now();",
    sentinel="__lastUsedModel",
)

# ============================================ P2: L1 派发侧读取「会话最后模型」
L1_READ = (
    "\t\t\tlet sessionModelRef;\n"
    "\t\t\ttry {\n"
    "\t\t\t\tconst __safeKey = String(sessionKey).replace(/[^A-Za-z0-9._-]+/g, \"_\").slice(0, 180);\n"
    "\t\t\t\tconst __fsm = await import(\"node:fs\");\n"
    "\t\t\t\tconst __j = JSON.parse(__fsm.readFileSync(pluginDataDir + \"/.session-model/\" + __safeKey + \".json\", \"utf8\"));\n"
    "\t\t\t\tif (__j && typeof __j.provider === \"string\" && __j.provider && typeof __j.model === \"string\" && __j.model) sessionModelRef = __j.provider + \"/\" + __j.model;\n"
    "\t\t\t} catch {}\n"
    "\t\t\tif (sessionModelRef) logger.info?.(`${TAG$9} [l1] session last-used model: ${sessionModelRef}`);\n"
    "\t\t\ttry {\n"
    "\t\t\t\tconst __aid = typeof extractAgentId$1 === \"function\" ? extractAgentId$1(sessionKey) : void 0;\n"
    "\t\t\t\tconst __chainPreview = resolveModelChain(config, __aid, sessionModelRef);\n"
    "\t\t\t\tlogger.info?.(`${TAG$9} [l1] model chain: ${__chainPreview.join(\" -> \") || \"(none)\"}`);\n"
    "\t\t\t} catch (__e) {\n"
    "\t\t\t\tlogger.info?.(`${TAG$9} [l1] model chain preview failed: ${__e && __e.message}`);\n"
    "\t\t\t}\n"
)
replace_once(
    "P2b dispatch: read session last-used model",
    "\t\t\tlet lastSceneName;\n\t\t\tfor (const group of groups) {",
    "\t\t\tlet lastSceneName;\n" + L1_READ + "\t\t\tfor (const group of groups) {",
    sentinel="sessionModelRef",
)

replace_once(
    "P2c options: forward sessionModel",
    "\t\t\t\t\t\tmodel: cfg.extraction.model,",
    "\t\t\t\t\t\tmodel: cfg.extraction.model,\n\t\t\t\t\t\tsessionModel: sessionModelRef,",
    sentinel="sessionModel: sessionModelRef,",
)

replace_once(
    "P2d callLlmExtraction: forward sessionModel",
    "\t\t\t\tmodel: options.model,\n\t\t\t\tllmRunner: options.llmRunner,\n\t\t\t\tsessionKey",
    "\t\t\t\tmodel: options.model,\n\t\t\t\tsessionModel: options.sessionModel,\n\t\t\t\tllmRunner: options.llmRunner,\n\t\t\t\tsessionKey",
    sentinel="sessionModel: options.sessionModel,",
)

replace_once(
    "P2e callLlmExtraction: destructure sessionModel",
    "const { newMessages, backgroundMessages, previousSceneName, config, logger, model, llmRunner } = params;",
    "const { newMessages, backgroundMessages, previousSceneName, config, logger, model, sessionModel, llmRunner } = params;",
    sentinel="model, sessionModel, llmRunner } = params;",
)

# ============================== P1+P2: 两个 L1 runner 站点补 agentId/sessionModel
replace_once(
    "P1f runner site: l1-conflict-detection",
    "new CleanContextRunner({\n\t\t\tconfig,\n\t\t\tmodelRef: model,\n\t\t\tenableTools: false,\n\t\t\tlogger\n\t\t}).run({\n\t\t\tprompt: userPrompt,\n\t\t\tsystemPrompt: CONFLICT_DETECTION_SYSTEM_PROMPT,\n\t\t\ttaskId: \"l1-conflict-detection\",",
    "new CleanContextRunner({\n\t\t\tconfig,\n\t\t\tmodelRef: model,\n\t\t\tenableTools: false,\n\t\t\tlogger,\n\t\t\tagentId: sessionKey ? extractAgentId$1(sessionKey) : void 0\n\t\t}).run({\n\t\t\tprompt: userPrompt,\n\t\t\tsystemPrompt: CONFLICT_DETECTION_SYSTEM_PROMPT,\n\t\t\ttaskId: \"l1-conflict-detection\",",
    sentinel="agentId: sessionKey ? extractAgentId$1(sessionKey) : void 0\n",
)

replace_once(
    "P1g runner site: l1-extraction",
    "new CleanContextRunner({\n\t\tconfig,\n\t\tmodelRef: model,\n\t\tenableTools: false,\n\t\tlogger\n\t}).run({\n\t\tprompt: userPrompt,\n\t\tsystemPrompt: EXTRACT_MEMORIES_SYSTEM_PROMPT,\n\t\ttaskId: \"l1-extraction\",",
    "new CleanContextRunner({\n\t\tconfig,\n\t\tmodelRef: model,\n\t\tenableTools: false,\n\t\tlogger,\n\t\tagentId: extractAgentId$1(params.sessionKey)\n\t}).run({\n\t\tprompt: userPrompt,\n\t\tsystemPrompt: EXTRACT_MEMORIES_SYSTEM_PROMPT,\n\t\ttaskId: \"l1-extraction\",",
    sentinel="agentId: extractAgentId$1(params.sessionKey)\n",
)

# ---------------------------------------------------------------- 收尾
if MODE == "check":
    print("== 体检（未修改）==")
    for k, v in [("resolveModelChain(config, agentId, sessionModel)", "P1 链逻辑"),
                 ("sessionModel: sessionModelRef,", "P2c 派发转发"),
                 ("__lastUsedModel", "P2a 采集落盘"),
                 ("sessionModelRef", "P2b 派发读取"),
                 ("model, sessionModel, llmRunner } = params;", "P2e 定义解构")]:
        print("   %-46s %s" % (k, "OK" if k in s else "MISSING"))
    sys.exit(0)

if s == orig:
    print("== 无需修改（全部已应用）==")
    print("   体积 %d" % len(s))
    sys.exit(0)

bak = DIST + ".bak-l1chain-" + time.strftime("%Y%m%d-%H%M%S")
shutil.copy2(DIST, bak)
io.open(DIST, "w", encoding="utf-8", newline="").write(s)

r = subprocess.run(["node", "--check", DIST], capture_output=True, text=True)
old_hash = hashlib.sha256(orig.encode("utf-8")).hexdigest()[:16]
new_hash = hashlib.sha256(s.encode("utf-8")).hexdigest()[:16]

print("== 应用结果 ==")
for a in applied:
    print("   [APPLIED] " + a)
for k in skipped:
    print("   [SKIP   ] " + k)
print("   备份        : " + os.path.basename(bak))
print("   体积        : %d -> %d" % (len(orig), len(s)))
print("   sha256[:16] : %s -> %s" % (old_hash, new_hash))
print("   node --check: rc=%d" % r.returncode)
if r.returncode != 0:
    print(r.stderr[:800])
    fail("语法检查未通过，已保留备份，请用 --restore 还原")
print("   OK：重启网关后生效。")
