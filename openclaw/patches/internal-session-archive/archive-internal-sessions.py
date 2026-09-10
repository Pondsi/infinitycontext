# -*- coding: utf-8 -*-
"""
archive-internal-sessions.py — 内部会话「静默化」：只留异常

memory-tencentdb 每次跑 L1/L2/L3 提取都发起独立「干净上下文运行」，
网关按运行建 session node → 侧边栏 Other 区多出一行。
delivery.kind=none 只表示「跑完不播报」≠ 不注册会话。

本脚本干两件事：
  A. status=done → 归档（隐藏；可逆）+ 顺带清未读
  B. status≠done → 不碰（running 保留、failed/timeout/error 的红色徽章必须保留）

用法：
  python archive-internal-sessions.py [选项]

选项：
  --status          只打印统计
  --dry-run         只报告，不执行
  --loop <秒>       循环模式（配合计划任务每分钟启动；Task Scheduler 重复间隔最小 1 分钟）
  --interval <秒>   循环内每轮间隔（默认 5 秒）
  --agent <id>      只扫指定 agent（默认扫全部）
  --selftest        分类逻辑自测

退出码：0 正常 / 1 意外错误
"""
import os
import re
import sys
import glob
import json
import time
import shutil
import sqlite3
import subprocess

sys.stdout.reconfigure(encoding="utf-8")

HOME = os.path.expanduser("~")
ROOT = os.path.join(HOME, ".openclaw")
AGENTS_GLOB = os.path.join(ROOT, "agents", "*", "agent", "openclaw-agent.sqlite")
LOG = os.path.join(ROOT, "logs", "internal-session-archive.log")
HEARTBEAT = os.path.join(ROOT, "logs", "internal-session-archive.heartbeat")

INTERNAL_MARKERS = (
    ":memory-l1-extraction",
    ":memory-l1-conflict-detection",
    ":memory-scene-extract",
    ":memory-persona",
    ":memory-",
)
ANOMALY_STATUSES = ("failed", "timeout", "error")

DRY = "--dry-run" in sys.argv
ONLY_STATUS = "--status" in sys.argv
SELFTEST = "--selftest" in sys.argv
ONLY_AGENT = None
if "--agent" in sys.argv:
    i = sys.argv.index("--agent")
    if i + 1 < len(sys.argv):
        ONLY_AGENT = sys.argv[i + 1]


def _arg(name, default):
    if name in sys.argv:
        i = sys.argv.index(name)
        if i + 1 < len(sys.argv):
            try:
                return int(sys.argv[i + 1])
            except ValueError:
                pass
    return default


LOOP_SECONDS = _arg("--loop", 0)
INTERVAL = max(2, _arg("--interval", 5))


def log(msg, echo=True):
    line = "%s %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
    try:
        d = os.path.dirname(LOG)
        if not os.path.isdir(d):
            os.makedirs(d, exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass
    if echo:
        print(line)


def heartbeat(pending=0, visible=0, archived=0, read=0):
    try:
        d = os.path.dirname(HEARTBEAT)
        if not os.path.isdir(d):
            os.makedirs(d, exist_ok=True)
        with open(HEARTBEAT, "w", encoding="utf-8") as f:
            f.write("%s pending=%d visible=%d archived=%d read=%d\n"
                    % (time.strftime("%Y-%m-%d %H:%M:%S"), pending, visible, archived, read))
    except Exception:
        pass


def resolve_openclaw():
    for name in ("openclaw.cmd", "openclaw.exe", "openclaw.bat", "openclaw"):
        p = shutil.which(name)
        if p:
            return p
    for cand in (
        r"C:\npm-global\openclaw.cmd",
        os.path.join(HOME, "AppData", "Roaming", "npm", "openclaw.cmd"),
    ):
        if os.path.isfile(cand):
            return cand
    return None


OPENCLAW = resolve_openclaw()


def is_internal(key):
    return any(m in key for m in INTERNAL_MARKERS)


def scan():
    """只读扫描。返回 [(agent_id, session_key, status, unread_bool), ...]"""
    found = []
    for db in glob.glob(AGENTS_GLOB):
        agent_id = os.path.basename(os.path.dirname(os.path.dirname(db)))
        if ONLY_AGENT and agent_id != ONLY_AGENT:
            continue
        if not os.path.isfile(db):
            continue
        try:
            con = sqlite3.connect("file:%s?mode=ro" % db.replace("\\", "/"), uri=True)
            con.execute("PRAGMA query_only = ON")
            cur = con.execute(
                "SELECT session_key, status, last_read_at, updated_at FROM session_nodes "
                "WHERE archived_at IS NULL AND session_key LIKE '%memory-%'"
            )
            for key, status, read_at, updated in cur.fetchall():
                if not is_internal(key):
                    continue
                unread = (read_at is None) or (updated is not None and read_at < updated)
                found.append((agent_id, key, status or "", bool(unread)))
            con.close()
        except Exception as e:
            log("WARN  扫描失败 %s: %r" % (db, e))
    return found


def cli_call(method, params, timeout=30):
    if not OPENCLAW:
        return None
    cmd = [OPENCLAW, "gateway", "call", method, "--params",
           json.dumps(params, ensure_ascii=False), "--timeout", str(timeout * 1000)]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                           errors="replace", timeout=timeout + 20)
        out = (p.stdout or "")
        i = out.find("{")
        return json.loads(out[i:]) if i >= 0 else {"ok": p.returncode == 0, "raw": out[:200]}
    except Exception as e:
        log("ERROR RPC %s 失败: %r" % (method, e))
        return None


def mark_read(key):
    r = cli_call("sessions.patch", {"key": key, "unread": False})
    ok = bool(r and r.get("ok") is not False)
    if ok:
        log("READ  清未读 %s" % key)
    else:
        log("ERROR 清未读失败 %s -> %s" % (key, json.dumps(r, ensure_ascii=False)[:160] if r else "no-response"))
    return ok


def archive(agent_id, keys):
    if not OPENCLAW:
        log("ERROR 找不到 openclaw 可执行文件，跳过归档")
        return 0
    cmd = [OPENCLAW, "sessions", "archive", "--agent", agent_id, "--json"] + list(keys)
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                           errors="replace", timeout=120)
        if p.returncode != 0:
            log("ERROR 归档失败 agent=%s rc=%d %s" % (agent_id, p.returncode, (p.stderr or "")[:300]))
            return 0
        log("DONE  归档 agent=%s 请求=%d 条" % (agent_id, len(keys)))
        return len(keys)
    except Exception as e:
        log("ERROR 归档异常 agent=%s: %r" % (agent_id, e))
        return 0


def classify(rows):
    """分类（纯函数，可自测）。"""
    anomalies = [r for r in rows if r[2] in ANOMALY_STATUSES]
    to_archive = [r for r in rows if r[2] == "done"]
    to_read = [r for r in to_archive if r[3]]  # 只清「将归档的 done」；running 异常绝不碰
    return to_archive, to_read, anomalies


def sweep(dry=False):
    rows = scan()
    to_archive, to_read, anomalies = classify(rows)

    if dry:
        for a, k, s, u in to_archive:
            log("[dry-run] 将归档 %s" % k)
        for a, k, s, u in to_read:
            log("[dry-run] 将清未读 %s (status=%s)" % (k, s))
        for a, k, s, u in anomalies:
            log("[dry-run] 保留可见+保留徽章 %s (status=%s)" % (k, s))
        return 0, 0, len(anomalies), rows

    read_n = 0
    for a, k, s, u in to_read:
        if mark_read(k):
            read_n += 1

    arch_n = 0
    by_agent = {}
    for a, k, s, u in to_archive:
        by_agent.setdefault(a, []).append(k)
    for a, ks in by_agent.items():
        arch_n += archive(a, ks)

    return arch_n, read_n, len(anomalies), rows


def selftest():
    rows = [
        ("yai", "agent:yai:memory-x-1", "done", True),
        ("yai", "agent:yai:memory-x-2", "done", False),
        ("yai", "agent:yai:memory-x-3", "running", True),
        ("yai", "agent:yai:memory-x-4", "running", False),
        ("yai", "agent:yai:memory-x-5", "failed", True),
        ("yai", "agent:yai:memory-x-6", "timeout", True),
        ("yai", "agent:yai:memory-x-7", "error", True),
    ]
    arch, read, anom = classify(rows)
    got = {
        "archive": sorted(k for _, k, _, _ in arch),
        "read": sorted(k for _, k, _, _ in read),
        "anomaly": sorted(k for _, k, _, _ in anom),
    }
    want = {
        "archive": ["agent:yai:memory-x-1", "agent:yai:memory-x-2"],
        "read": ["agent:yai:memory-x-1"],
        "anomaly": ["agent:yai:memory-x-5", "agent:yai:memory-x-6", "agent:yai:memory-x-7"],
    }
    ok = True
    for k in ("archive", "read", "anomaly"):
        mark = "OK " if got[k] == want[k] else "FAIL"
        if got[k] != want[k]:
            ok = False
        print("  %s %-8s got=%s" % (mark, k, got[k]))
        if got[k] != want[k]:
            print("       want=%s" % want[k])
    leaked = [k for k in got["archive"] + got["read"] if k in want["anomaly"]]
    if leaked:
        ok = False
        print("  FAIL 异常会话被误处理: %s" % leaked)
    else:
        print("  OK   异常会话 0 条被归档/清未读")
    print("结果:", "全部通过" if ok else "存在失败")
    return 0 if ok else 1


def main():
    if SELFTEST:
        return selftest()
    if ONLY_STATUS:
        rows = scan()
        print("内部会话（未归档）：%d 条" % len(rows))
        for a, k, s, u in rows:
            print("   %-8s unread=%-6s %s" % (s, u, k))
        return 0
    if LOOP_SECONDS > 0:
        deadline = time.time() + LOOP_SECONDS
        tot_a = tot_r = 0
        while True:
            a, r, vis, rows = sweep(dry=DRY)
            tot_a += a
            tot_r += r
            heartbeat(pending=len([x for x in rows if x[2] == "done"]), visible=vis,
                      archived=tot_a, read=tot_r)
            if time.time() + INTERVAL >= deadline:
                break
            time.sleep(INTERVAL)
        if tot_a or tot_r:
            log("本轮循环：归档 %d，清未读 %d" % (tot_a, tot_r))
        return 0
    a, r, vis, rows = sweep(dry=DRY)
    heartbeat(pending=len([x for x in rows if x[2] == "done"]), visible=vis, archived=a, read=r)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        log("FATAL %r" % e)
        sys.exit(1)
