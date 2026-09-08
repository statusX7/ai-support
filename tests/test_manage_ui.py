#!/usr/bin/env python3
"""Drive production Shell menus; application HTTP/daemon readback are protocol fixtures."""

import errno
import copy
import fcntl
import hashlib
import http.server
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
(ROOT / ".work").mkdir(mode=0o700, exist_ok=True)
WORK = Path(tempfile.mkdtemp(prefix="menu-contract-", dir=ROOT / ".work"))
DEPLOY = WORK / "部署 空格'quote"
BIN = WORK / "bin"
COUNT = 0


def passing(label):
    global COUNT
    COUNT += 1
    print(f"通过：[UNIT/CONTRACT] {label}", flush=True)


def invoke(args, *, content=None, extra=None, cwd=WORK):
    return subprocess.run(args, input=content, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, cwd=cwd,
                          env={**ENV, **(extra or {})}, timeout=60)


class Terminal:
    def __init__(self, name, *, width=110, extra=None, command=None, cwd=WORK):
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, width, 0, 0))
        self.tty_before = termios.tcgetattr(slave)
        self.slave_name = os.ttyname(slave)
        self.process = subprocess.Popen(command or ["bash", str(DEPLOY / "manage.sh"), "--deploy-dir", str(DEPLOY)],
                                        stdin=slave, stdout=slave, stderr=slave, cwd=cwd,
                                        start_new_session=True,
                                        env={**ENV, "TERM": "xterm-256color", "COLUMNS": str(width), **(extra or {})})
        os.close(slave)
        self.output = ""
        self.cursor = 0
        self.name = name

    def read(self):
        if select.select([self.master], [], [], 0.1)[0]:
            try:
                chunk = os.read(self.master, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    return
                raise
            self.output += chunk.decode("utf-8", "replace")

    def expect(self, token, timeout=25):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            index = self.output.find(token, self.cursor)
            if index >= 0:
                self.cursor = index + len(token)
                return
            self.read()
            if self.process.poll() is not None:
                break
        raise AssertionError(f"{self.name}: 未收到 {token!r}\n{self.output[-6000:]}")

    def send(self, line):
        os.write(self.master, (line + "\n").encode())

    def finish(self, expected=0):
        deadline = time.monotonic() + 30
        while self.process.poll() is None and time.monotonic() < deadline:
            self.read()
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGTERM)
            raise AssertionError(f"{self.name}: 入口没有有限退出")
        for _ in range(3):
            self.read()
        os.close(self.master)
        transcript = WORK / (self.name + ".log")
        transcript.write_text(self.output, encoding="utf-8")
        transcript.chmod(0o600)
        assert self.process.returncode == expected, self.output
        assert "bad substitution" not in self.output and "unbound variable" not in self.output, self.output
        return self.output


PROMPT = {"text": "初始虚构 Prompt。\n"}
MODEL_LIST = {"status": 200, "calls": 0, "chat_calls": 0, "probes": [],
              "ids": ["synthetic-menu-model"], "post_status": 200}


class ApplicationFixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def answer(self, body, status=200):
        payload = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/api/v1/auth":
            self.answer({"authenticated": True})
        elif self.path == "/api/v1/workspace/crisp-support":
            self.answer({"workspace": [{"slug": "crisp-support", "openAiPrompt": PROMPT["text"], "documents": []}]})
        elif self.path == "/proxy/v1/models":
            MODEL_LIST["calls"] += 1
            if MODEL_LIST["status"] == 200:
                self.answer({"data": [{"id": name} for name in MODEL_LIST["ids"]]})
            else:
                self.answer({"error": {"message": "隔离模型列表临时故障"}}, MODEL_LIST["status"])
        elif self.path in ("/healthz", "/api/ping"):
            self.answer({"ok": True})
        else:
            self.send_error(404)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        body = json.loads(raw or b"{}")
        if self.path == "/api/v1/workspace/crisp-support/update":
            PROMPT["text"] = body["openAiPrompt"]
            self.answer({"workspace": {"slug": "crisp-support", "openAiPrompt": PROMPT["text"]}})
        elif self.path == "/api/v1/workspace/crisp-support/update-embeddings":
            self.answer({"success": True})
        elif self.path in ("/proxy/v1/chat/completions", "/proxy/v1/responses"):
            MODEL_LIST["chat_calls"] += 1
            messages = body.get("messages", body.get("input", []))
            content = messages[0].get("content", []) if messages else []
            vision = isinstance(content, list) and any(
                item.get("type") in ("image_url", "input_image") for item in content)
            MODEL_LIST["probes"].append((self.path, body.get("model"), vision))
            if MODEL_LIST["post_status"] != 200:
                self.answer({"error": {"code": "invalid_api_key", "message": "虚构候选验证失败"}}, MODEL_LIST["post_status"])
                return
            self.answer({"choices": [{"message": {"content": "协议测试，不是真实模型。"}}], "output_text": "协议测试"})
        elif self.path == "/webhook/crisp-webhook?key=ai-support-healthcheck-invalid":
            self.answer({"accepted": False, "reason": "Webhook 校验失败"}, 401)
        else:
            self.send_error(404)


def menu_case(number, first_label):
    terminal = Terminal(f"menu-{number:02}")
    terminal.expect("请选择：")
    terminal.send(str(number))
    terminal.expect(first_label)
    terminal.expect("请选择：")
    terminal.send("0")
    terminal.expect("请选择：")
    terminal.send("0")
    terminal.finish()
    passing(f"生产主菜单 {number} 进入真实子菜单并返回")


def log_menu_cases():
    """通过生产 PTY 菜单执行日志查看、取消、轮转、清理与 follow 中断。"""
    logs = ["bash", str(DEPLOY / "scripts/logs.sh"), "--deploy-dir", str(DEPLOY)]
    result = invoke(logs + ["initialize"])
    assert result.returncode == 0, result.stdout
    result = invoke(logs + ["event", "--action", "ui_regression", "--phase", "complete", "--code", "0"])
    assert result.returncode == 0, result.stdout
    active = DEPLOY / "logs/maintenance.jsonl"
    original = active.read_bytes()
    sentinel = DEPLOY / "data/runtime/log-cleanup-sentinel.json"
    sentinel.write_text('{"mode":"human","resume_at":null,"generation":17}', encoding="utf-8")
    protected = {p: p.read_bytes() for name in ("config", "knowledge", "data")
                 for p in (DEPLOY / name).rglob("*") if p.is_file()}

    def enter(name):
        terminal = Terminal(name)
        terminal.expect("请选择："); terminal.send("15")
        terminal.expect("日志来源、占用与保留策略"); terminal.expect("请选择：")
        return terminal

    def leave(terminal):
        terminal.expect("日志来源、占用与保留策略"); terminal.expect("请选择："); terminal.send("0")
        terminal.expect("请选择："); terminal.send("0")
        return terminal.finish()

    terminal = enter("logs-show")
    terminal.send("2"); terminal.expect("请选择序号（0 返回）："); terminal.send("1")
    terminal.expect("最近行数"); terminal.send("1")
    terminal.expect("时间窗口"); terminal.send("2h")
    terminal.expect("动作：已记录维护事件"); leave(terminal)
    assert active.read_bytes() == original
    passing("日志菜单按来源/行数/时间窗调用真实查看器，不修改日志或业务资料")

    terminal = enter("logs-clear-cancel")
    terminal.send("4"); terminal.expect("请选择序号（0 返回）："); terminal.send("1")
    terminal.expect("请选择："); terminal.send("2")
    terminal.expect("1 确认 / 0 返回："); terminal.send("0"); leave(terminal)
    assert active.read_bytes() == original
    passing("日志清空预览后数字取消保持原文件")

    terminal = enter("logs-follow-interrupt")
    terminal.send("3"); terminal.expect("请选择序号（0 返回）："); terminal.send("1")
    terminal.expect("动作：已记录维护事件")
    os.killpg(terminal.process.pid, signal.SIGINT)
    terminal.expect("已停止日志查看，服务未停止"); leave(terminal)
    assert active.read_bytes() == original
    passing("持续查看 Ctrl+C 仅终止日志子进程并返回主菜单，服务和资料不变")

    terminal = enter("logs-rotate-confirm")
    terminal.send("4"); terminal.expect("请选择序号（0 返回）："); terminal.send("1")
    terminal.expect("请选择："); terminal.send("1")
    terminal.expect("1 确认 / 0 返回："); terminal.send("1")
    terminal.expect("维护事件日志已安全轮转"); leave(terminal)
    rotated = DEPLOY / "logs/maintenance.jsonl.1"
    assert rotated.read_bytes() == original
    os.utime(rotated, (time.time() - 9 * 86400, time.time() - 9 * 86400))
    terminal = enter("logs-cleanup-confirm")
    terminal.send("5"); terminal.expect("删除多少天"); terminal.send("7")
    terminal.expect("1 个受管历史文件"); terminal.expect("1 确认 / 0 返回："); terminal.send("1")
    terminal.expect("清理完成：删除 1 个过期受管历史文件"); leave(terminal)
    assert not rotated.exists() and active.exists()
    assert all(path.read_bytes() == content for path, content in protected.items())
    passing("生产日志菜单数字确认真实轮转/过期删除，永久人工哨兵/配置/知识逐字保留")


def online_update_menu_case():
    """确认菜单 14 只在数字确认后调用受管在线入口，并透传当前部署目录。"""
    online_entry = DEPLOY / "get.sh"
    original_entry = online_entry.read_bytes()
    update_log = WORK / "online-update.log"
    online_entry.write_text(r'''#!/usr/bin/env bash
set -euo pipefail
[[ -t 0 && -t 1 ]]
printf '%s\n' "$@" > "${MENU_ONLINE_UPDATE_LOG:?}"
printf '受管匿名在线更新入口已调用\n'
''', encoding="utf-8")
    online_entry.chmod(0o750)
    extra = {"MENU_ONLINE_UPDATE_LOG": str(update_log)}
    try:
        terminal = Terminal("online-update-cancel", extra=extra)
        terminal.expect("请选择："); terminal.send("14")
        terminal.expect("1. 匿名在线更新至最新正式版")
        terminal.expect("请选择："); terminal.send("1")
        terminal.expect("锁定版本后下载完整包与 SHA256SUMS 并校验")
        terminal.expect("1 确认 / 0 返回："); terminal.send("0")
        terminal.expect("1. 匿名在线更新至最新正式版")
        terminal.expect("请选择："); terminal.send("0")
        terminal.expect("请选择："); terminal.send("0")
        terminal.finish()
        assert not update_log.exists()
        passing("菜单14在线更新取消不联网、不调用更新入口")

        terminal = Terminal("online-update-confirm", extra=extra)
        terminal.expect("请选择："); terminal.send("14")
        terminal.expect("请选择："); terminal.send("1")
        terminal.expect("1 确认 / 0 返回："); terminal.send("1")
        terminal.expect("受管匿名在线更新入口已调用")
        terminal.expect("1. 匿名在线更新至最新正式版")
        terminal.expect("请选择："); terminal.send("0")
        terminal.expect("请选择："); terminal.send("0")
        terminal.finish()
        assert update_log.read_text(encoding="utf-8").splitlines() == [
            "--update", "--deploy-dir", str(DEPLOY)
        ]
        passing("菜单14经数字确认调用受管 get.sh --update 并保持生产 TTY")

        online_entry.unlink()
        online_entry.symlink_to("/bin/true")
        terminal = Terminal("online-update-unsafe-entry", extra=extra)
        terminal.expect("请选择："); terminal.send("14")
        terminal.expect("请选择："); terminal.send("1")
        terminal.expect("受管在线更新入口缺失或不安全")
        terminal.expect("请选择："); terminal.send("0")
        terminal.expect("请选择："); terminal.send("0")
        terminal.finish()
        assert update_log.read_text(encoding="utf-8").splitlines() == [
            "--update", "--deploy-dir", str(DEPLOY)
        ]
        passing("菜单14拒绝缺失或符号链接在线入口")
    finally:
        if online_entry.exists() or online_entry.is_symlink():
            online_entry.unlink()
        online_entry.write_bytes(original_entry)
        online_entry.chmod(0o750)




def provider_pool():
    return json.loads((DEPLOY / "config/provider-pool-applied.json").read_text())


def provider_snapshot():
    files = [DEPLOY / name for name in (".env", "config/provider.yaml", "config/runtime.yaml",
                                       "config/provider-pool.yaml", "config/provider-pool-applied.json")]
    files += sorted((DEPLOY / "secrets/provider/generations").glob("*.json"))
    return {path: path.read_bytes() for path in files}


def assert_chinese_result(output):
    assert not re.search(r'"(?:ok|enabled|schema_version|revision|applied_revision|entries)"\s*:', output), output
    assert not re.search(r'\b(?:schema_version|applied_revision|revision|Traceback)\b|p_[0-9a-f]{24}|(?:kb_|rule_|menu_)[0-9a-f]{8,}', output), output
    assert not re.search(r'synthetic-(?:menu-key|backup-secret|hidden-secret|header-value)', output), output


def enter_provider(name, extra=None):
    terminal = Terminal(name, extra=extra)
    terminal.expect("请选择："); terminal.send("3")
    terminal.expect("1. 查看主备接口列表"); terminal.expect("请选择：")
    return terminal


def leave_provider(terminal, *, editing=False):
    if editing:
        terminal.expect("9. 验证并保存整组修改"); terminal.expect("请选择："); terminal.send("0")
    terminal.expect("1. 查看主备接口列表"); terminal.expect("请选择："); terminal.send("0")
    terminal.expect("请选择："); terminal.send("0")
    output = terminal.finish()
    assert_chinese_result(output)
    return output


def provider_retry_cases():
    """真实 PTY → provider.sh → 本地生产 adapter → 虚构上游；不模拟保存回执。"""
    retry_prompt = "模型列表请求暂时失败：1 重试 / 2 返回修改接口 / 0 取消："

    def open_models(name):
        terminal = enter_provider(name, {"FUNCNEST": "12"})
        terminal.send("2"); terminal.expect("请选择："); terminal.send("4")
        return terminal

    try:
        MODEL_LIST.update(status=429, calls=0, chat_calls=0, probes=[], ids=["synthetic-menu-retry-model"])
        before = provider_snapshot()
        terminal = open_models("models-transient-retry")
        for _ in range(14):
            terminal.expect(retry_prompt)
            assert provider_snapshot() == before and MODEL_LIST["chat_calls"] == 0
            terminal.send("1")
        terminal.expect(retry_prompt); MODEL_LIST["status"] = 200; terminal.send("1")
        terminal.expect("1. synthetic-menu-retry-model")
        terminal.expect("选择模型（数字"); terminal.send("1")
        terminal.expect("模型已写入本次候选")
        assert provider_snapshot() == before and MODEL_LIST["chat_calls"] == 0
        terminal.expect("请选择："); terminal.send("9"); terminal.expect("1 确认 / 0 返回："); terminal.send("1")
        terminal.expect("接口共")
        output = leave_provider(terminal)
        assert provider_pool()["entries"][0]["model"] == "synthetic-menu-retry-model"
        # 模型列表后端每轮最多3次无推理GET重试；15轮失败+最终成功1次。
        assert MODEL_LIST["calls"] == 46 and MODEL_LIST["chat_calls"] == 1, MODEL_LIST
        assert MODEL_LIST["probes"] == [("/proxy/v1/chat/completions", "synthetic-menu-retry-model", False)], MODEL_LIST
        assert output.count(retry_prompt) == 15 and "maximum function nesting" not in output
        passing("生产PTY模型429连续14次重试不递归，模型选择不保存，整组确认才由真实adapter探测并应用一次")
        for action, label in (("0", "取消"), ("2", "返回编辑")):
            MODEL_LIST.update(status=503, calls=0, chat_calls=0, probes=[])
            before = provider_snapshot()
            terminal = open_models("models-transient-" + action)
            terminal.expect(retry_prompt); terminal.send(action)
            output = leave_provider(terminal, editing=True)
            assert provider_snapshot() == before and MODEL_LIST["chat_calls"] == 0
            assert MODEL_LIST["calls"] == 3 and output.count(retry_prompt) == 1
            passing(f"生产PTY模型503后{label}，有效池/秘密不变且未触发推理")
    finally:
        MODEL_LIST.update(status=200, ids=["synthetic-menu-model"], post_status=200)


def provider_pool_menu_cases():
    primary = provider_pool()["primary_id"]
    original = provider_pool()["entries"][0]
    base = original["base_url"]

    def select(terminal, action, identifier=None, *, backup=False):
        terminal.send(str(action)); terminal.expect("请选择序号（0 返回）：")
        entries = [item for item in provider_pool()["entries"] if not backup or item["role"] == "backup"]
        index = next(i for i, item in enumerate(entries, 1) if item["id"] == identifier) if identifier else 1
        terminal.send(str(index))

    def save(terminal):
        terminal.expect("请选择："); terminal.send("9")
        terminal.expect("1 确认 / 0 返回："); terminal.send("1"); terminal.expect("接口共")
        return leave_provider(terminal)

    def add(name, model):
        terminal = enter_provider("pool-add-" + model)
        terminal.send("3"); terminal.expect("备用接口显示名称"); terminal.send(name)
        terminal.expect("备用接口地址"); terminal.send(base)
        terminal.expect("备用接口密钥（隐藏输入）"); terminal.send("synthetic-backup-secret")
        terminal.expect("请选择："); terminal.send("5")
        terminal.expect("准确模型名称"); terminal.send(model)
        save(terminal)
        return next(item["id"] for item in provider_pool()["entries"] if item["name"] == name)

    calls = MODEL_LIST["chat_calls"]
    before = provider_snapshot()
    terminal = enter_provider("pool-readonly")
    terminal.send("1"); terminal.expect("合法的单接口配置")
    terminal.expect("请选择："); terminal.send("11"); terminal.expect("近期切换记录")
    leave_provider(terminal)
    assert provider_snapshot() == before and MODEL_LIST["chat_calls"] == calls
    passing("单接口零备用列表与近期记录真实读取、不付费、不热改")

    first = add("备用甲", "backup-a")
    assert provider_pool()["entries"][0] == original and len(provider_pool()["entries"]) == 2
    passing("数字添加备用接口，整组验证后生效且主接口不变")
    secret = json.loads((DEPLOY / "secrets/provider/generations" / (provider_pool()["secrets_generation"] + ".json")).read_text())["entries"][first]
    terminal = enter_provider("pool-edit-backup")
    select(terminal, 4, first)
    terminal.expect("请选择："); terminal.send("3"); terminal.expect("新 API Key"); terminal.send("")
    terminal.expect("请选择："); terminal.send("5"); terminal.expect("准确模型名称"); terminal.send("backup-a-updated")
    save(terminal)
    assert provider_pool()["entries"][0] == original
    assert next(item for item in provider_pool()["entries"] if item["id"] == first)["model"] == "backup-a-updated"
    after_secret = json.loads((DEPLOY / "secrets/provider/generations" / (provider_pool()["secrets_generation"] + ".json")).read_text())["entries"][first]
    assert after_secret == secret
    passing("编辑指定备用模型不改主，稳定标识不变，隐藏Key回车保留且结果不泄Key/内部编号")

    before = provider_snapshot()
    terminal = enter_provider("pool-candidate-cancel")
    select(terminal, 4, first)
    terminal.expect("请选择："); terminal.send("3"); terminal.expect("新 API Key"); terminal.send("synthetic-hidden-secret")
    leave_provider(terminal, editing=True)
    assert provider_snapshot() == before
    passing("含新密钥的候选数字取消保留旧整组与秘密代次")

    before = provider_snapshot(); MODEL_LIST["post_status"] = 401
    terminal = enter_provider("pool-failed-save")
    select(terminal, 4, first)
    terminal.expect("请选择："); terminal.send("5"); terminal.expect("准确模型名称"); terminal.send("rejected-model")
    terminal.expect("请选择："); terminal.send("9"); terminal.expect("1 确认 / 0 返回："); terminal.send("1")
    terminal.expect("验证未通过，候选仍保留")
    leave_provider(terminal, editing=True)
    MODEL_LIST["post_status"] = 200
    assert provider_snapshot() == before
    passing("候选真实上游401失败保旧，错误中文且留编辑页重试、不显示假成功")

    second = add("备用乙", "backup-b")
    terminal = enter_provider("pool-order")
    terminal.send("5"); terminal.expect("逗号分隔"); terminal.send("2,1")
    terminal.expect("1 确认 / 0 返回："); terminal.send("1"); terminal.expect("接口共"); leave_provider(terminal)
    assert [item["id"] for item in provider_pool()["entries"]] == [primary, second, first]
    before = provider_snapshot()
    terminal = enter_provider("pool-order-invalid")
    terminal.send("5"); terminal.expect("逗号分隔"); terminal.send("1,2,bad")
    terminal.expect("每个备用序号恰好出现一次"); leave_provider(terminal)
    assert provider_snapshot() == before
    passing("备用数字排序真实回读；非法多余项不被过滤后冒充合法顺序")

    for value, expected in (("2", False), ("1", True), ("2", False)):
        terminal = enter_provider("pool-enable-" + value + str(expected))
        select(terminal, 6, first, backup=True)
        terminal.expect("1 启用 / 2 停用"); terminal.send(value)
        terminal.expect("1 确认 / 0 返回："); terminal.send("1"); terminal.expect("接口共"); leave_provider(terminal)
        assert next(item for item in provider_pool()["entries"] if item["id"] == first)["enabled"] is expected
        assert provider_pool()["entries"][0] == original
    terminal = enter_provider("pool-primary-exchange")
    select(terminal, 7, first)
    terminal.expect("1 确认 / 0 返回："); terminal.send("1"); terminal.expect("接口共"); leave_provider(terminal)
    assert provider_pool()["primary_id"] == first and provider_pool()["entries"][0]["enabled"] is True
    assert next(item for item in provider_pool()["entries"] if item["id"] == primary)["role"] == "backup"
    passing("备用启停实际生效；停用备用设主时自动启用、原主原子转备")

    calls = MODEL_LIST["chat_calls"]
    terminal = enter_provider("pool-test-cancel")
    select(terminal, 9, second)
    terminal.expect("1 测试文本 / 2 测试图片"); terminal.send("1")
    terminal.expect("1 确认 / 0 返回："); terminal.send("0"); leave_provider(terminal)
    assert MODEL_LIST["chat_calls"] == calls
    terminal = enter_provider("pool-explicit-test")
    select(terminal, 9, second)
    terminal.expect("1 测试文本 / 2 测试图片"); terminal.send("1")
    terminal.expect("1 确认 / 0 返回："); terminal.send("1")
    terminal.expect("实际回读通过：是"); leave_provider(terminal)
    assert MODEL_LIST["chat_calls"] == calls + 1 and MODEL_LIST["probes"][-1][1] == "backup-b"
    passing("指定接口测试取消零调用；明确确认才测所选备用，不误测主")

    terminal = enter_provider("pool-policy")
    terminal.send("10"); terminal.expect("修改哪一项："); terminal.send("4")
    terminal.expect("新的正整数"); terminal.send("3")
    terminal.expect("1 确认 / 0 返回："); terminal.send("1"); terminal.expect("每问题最多调用次数：3")
    leave_provider(terminal)
    assert provider_pool()["policy"]["max_attempts"] == 3
    before = provider_snapshot()
    terminal = enter_provider("pool-policy-invalid")
    terminal.send("10"); terminal.expect("修改哪一项："); terminal.send("1")
    terminal.expect("新的正整数"); terminal.send("1000")
    terminal.expect("1 确认 / 0 返回："); terminal.send("1"); terminal.expect("操作未完成")
    leave_provider(terminal)
    assert provider_snapshot() == before
    passing("策略整组回读；违反连接/单次/总期限关系时拒绝且旧策略不变")

    terminal = enter_provider("pool-restore-original-primary")
    select(terminal, 7, primary)
    terminal.expect("1 确认 / 0 返回："); terminal.send("1"); terminal.expect("接口共"); leave_provider(terminal)
    for identifier in (first, second):
        terminal = enter_provider("pool-delete-" + ("a" if identifier == first else "b"))
        select(terminal, 8, identifier, backup=True)
        terminal.expect("1 确认 / 0 返回："); terminal.send("1"); terminal.expect("接口共"); leave_provider(terminal)
        assert identifier not in [item["id"] for item in provider_pool()["entries"]]
    assert provider_pool()["entries"] == [original]
    passing("数字删除仅所选备用，恢复为合法零备用且原主凭据配置保持")


def provider_file_menu_cases():
    source = DEPLOY / "config/provider-pool.yaml"
    active = DEPLOY / "config/provider-pool-applied.json"
    original = copy.deepcopy(provider_pool())
    name = original["entries"][0]["name"]

    def policy(terminal, action):
        terminal.send("10"); terminal.expect("修改哪一项："); terminal.send(str(action))

    changed = json.loads(source.read_text())
    changed["entries"][0]["name"] = "文件编辑后的主接口"
    source.write_text(json.dumps(changed, ensure_ascii=False), encoding="utf-8")
    before = active.read_bytes()
    terminal = enter_provider("pool-source-apply-cancel")
    policy(terminal, 9); terminal.expect("校验通过只表示原文格式可用")
    terminal.expect("1 确认 / 0 返回："); terminal.send("0"); leave_provider(terminal)
    assert active.read_bytes() == before
    terminal = enter_provider("pool-source-apply")
    policy(terminal, 9); terminal.expect("1 确认 / 0 返回："); terminal.send("1")
    terminal.expect("文件编辑后的主接口"); leave_provider(terminal)
    assert provider_pool()["entries"][0]["name"] == changed["entries"][0]["name"]
    passing("主备原文只读校验与数字取消不生效，明确确认后由生产apply-file回读生效")

    original_source = json.loads(source.read_text())
    original_source["entries"][0]["name"] = name
    imported = copy.deepcopy(original_source)
    former = copy.deepcopy(imported["entries"][0]); former.update(role="backup", order=1)
    imported["entries"][0].update(id="p_" + "b" * 24, name="导入的新主", role="primary", order=0)
    new_backup = copy.deepcopy(former); new_backup.update(id="p_" + "c" * 24, name="待补密钥备用", order=2)
    imported["entries"] += [former, new_backup]
    imported["primary_id"] = imported["entries"][0]["id"]
    file = WORK / "虚构主备导入.json"
    file.write_text(json.dumps(imported, ensure_ascii=False), encoding="utf-8"); file.chmod(0o600)
    before = {path: path.read_bytes() for path in (active, source, DEPLOY / ".env")}
    terminal = enter_provider("pool-import-draft")
    policy(terminal, 10); terminal.expect("结构文件路径"); terminal.send(str(file))
    terminal.expect("1 确认 / 0 返回："); terminal.send("1")
    terminal.expect("仅保存草稿，尚未应用"); leave_provider(terminal)
    assert all(path.read_bytes() == data for path, data in before.items())
    draft = json.loads((DEPLOY / "config/provider-pool-import-draft.json").read_text())
    assert draft["primary_id"] == imported["primary_id"]
    passing("陌生主接口无本机Key导入仅受限草稿，普通中文明确未应用且旧池/.env字节不变")

    terminal = enter_provider("pool-complete-draft")
    policy(terminal, 11)
    terminal.expect("请选择："); terminal.send("2")
    terminal.expect("请选择序号（0 返回）："); terminal.send("1")
    terminal.expect("请选择："); terminal.send("3"); terminal.expect("新 API Key"); terminal.send("synthetic-backup-secret")
    terminal.expect("请选择："); terminal.send("9"); terminal.expect("1 确认 / 0 返回："); terminal.send("1")
    terminal.expect("仅保存草稿，尚未应用")
    terminal.expect("请选择："); terminal.send("0"); leave_provider(terminal)
    assert all(path.read_bytes() == data for path, data in before.items())
    draft = json.loads((DEPLOY / "config/provider-pool-import-draft.json").read_text())
    assert draft["primary_id"] == imported["primary_id"] and not draft["entries"][0].get("draft", False)
    passing("导入草稿数字选中主接口补隐藏Key，真实验证后只保存草稿且稳定编号/当前池保持")

    terminal = enter_provider("pool-apply-draft")
    policy(terminal, 11)
    terminal.expect("请选择："); terminal.send("3"); terminal.expect("1 确认 / 0 返回："); terminal.send("1")
    terminal.expect("导入的新主"); leave_provider(terminal)
    assert provider_pool()["primary_id"] == imported["primary_id"]
    pending = next(item for item in provider_pool()["entries"] if item["id"] == new_backup["id"])
    assert pending["enabled"] is False and pending["draft"] is True
    assert provider_pool()["entries"][1]["id"] == original["primary_id"]
    passing("草稿明确确认后才整体应用，缺Key备用保持禁用，匹配旧接口本机秘密继续保留")

    terminal = enter_provider("pool-file-fixture-restore-primary")
    terminal.send("7"); terminal.expect("请选择序号（0 返回）："); terminal.send("2")
    terminal.expect("1 确认 / 0 返回："); terminal.send("1"); terminal.expect("接口共"); leave_provider(terminal)
    for suffix in ("new-primary", "empty-backup"):
        terminal = enter_provider("pool-file-fixture-delete-" + suffix)
        terminal.send("8"); terminal.expect("请选择序号（0 返回）："); terminal.send("1")
        terminal.expect("1 确认 / 0 返回："); terminal.send("1"); terminal.expect("接口共"); leave_provider(terminal)
    assert provider_pool()["entries"] == original["entries"]


def material_menu_cases():
    materials = ["bash", str(DEPLOY / "scripts/materials.sh"), "--deploy-dir", str(DEPLOY)]
    result = invoke(materials + ["initialize"])
    assert result.returncode == 0, result.stdout
    command = ["bash", str(DEPLOY / "manage.sh"), "--deploy-dir", str(DEPLOY), "apply"]
    source = DEPLOY / "config/prompt.md"
    original = source.read_bytes()
    projection = DEPLOY / "config/materials-applied.json"
    before = projection.read_bytes()
    calls = MODEL_LIST["chat_calls"]
    result = invoke(command + ["--check"])
    assert result.returncode == 0 and projection.read_bytes() == before, result.stdout
    for options in (("--check", "--force-external"), ("--force-external", "--check")):
        result = invoke(command + list(options))
        assert result.returncode == 64 and projection.read_bytes() == before, result.stdout
    passing("生产 apply --check 只校验，拒绝与强制应用互斥参数")
    try:
        candidate = "资料直接编辑回归：中文 Emoji 🧪 与 $ 不执行。\n"
        source.write_text(candidate, encoding="utf-8")
        assert PROMPT["text"] != candidate
        terminal = Terminal("material-apply-menu")
        terminal.expect("请选择："); terminal.send("16"); terminal.expect("请选择："); terminal.send("6")
        terminal.expect("仅应用已编辑的资料变更"); terminal.expect("请选择："); terminal.send("1")
        terminal.expect("1 确认 / 0 返回"); terminal.send("1"); terminal.expect('资料已应用：是')
        terminal.expect("请选择："); terminal.send("0"); terminal.expect("请选择："); terminal.send("0")
        terminal.finish()
        assert PROMPT["text"] == candidate
        assert json.loads(projection.read_text())["prompt"]["text"] == candidate
        passing("生产菜单16→6→1将直接编辑原文应用到HTTP工作区并发布同版投影")
        PROMPT["text"] = "仅在协议工作区模拟的外部偏移"
        terminal = Terminal("material-force-menu")
        terminal.expect("请选择："); terminal.send("16"); terminal.expect("请选择："); terminal.send("6")
        terminal.expect("重新同步现有资料"); terminal.expect("请选择："); terminal.send("2")
        terminal.expect("1 确认 / 0 返回"); terminal.send("1"); terminal.expect('资料已应用：是')
        terminal.expect("请选择："); terminal.send("0"); terminal.expect("请选择："); terminal.send("0")
        terminal.finish()
        assert PROMPT["text"] == candidate and source.read_text() == candidate
        before = projection.read_bytes()
        source.write_bytes(b"")
        result = invoke(command)
        assert result.returncode == 1 and projection.read_bytes() == before and PROMPT["text"] == candidate, result.stdout
        assert MODEL_LIST["chat_calls"] == calls
        passing("生产菜单16→6→2修复外部Prompt偏离；空原文拒绝且不修改生效版、不调用模型")
    finally:
        source.write_bytes(original)
        result = invoke(command + ["--force-external"])
        assert result.returncode == 0 and PROMPT["text"] == original.decode(), result.stdout


def welcome_presentation_cases():
    """欢迎与总开关分别实际回读，普通菜单不能显示后端总开关的 JSON 冒充欢迎结果。"""
    runtime_before = json.loads((DEPLOY / "config/runtime.yaml").read_text())["enabled"]
    for action, expected, label in (("3", False, "欢迎语：已关闭"), ("2", True, "欢迎语：已启用")):
        terminal = Terminal("welcome-readable-" + action)
        terminal.expect("请选择："); terminal.send("9")
        terminal.expect("请选择："); start = len(terminal.output); terminal.send(action)
        terminal.expect("1. 查看欢迎配置")
        terminal.expect("请选择："); terminal.send("0")
        terminal.expect("请选择："); terminal.send("0")
        output = terminal.finish()
        actual = json.loads((DEPLOY / "config/menu.yaml").read_text())
        projection = json.loads((DEPLOY / "config/materials-applied.json").read_text())
        assert actual["welcome"]["enabled"] is expected
        assert projection["configuration"]["menu"]["welcome"]["enabled"] is expected
        assert projection["configuration"]["runtime"]["enabled"] is runtime_before
        assert label in output[start:], output
        assert not re.search(r'"(?:enabled|schema_version|revision|applied_revision)"\s*:', output[start:]), output
    passing("欢迎启停按目标与有效投影回读中文结果，总开关保持且不泄露内部JSON")
    before = json.loads((DEPLOY / "config/menu.yaml").read_text())
    terminal = Terminal("welcome-failure-old-state", extra={"CONFIGURATION_FIXTURE_READBACK_FAIL": "1"})
    terminal.expect("请选择："); terminal.send("9"); terminal.expect("请选择："); terminal.send("3")
    terminal.expect("保存未完成")
    terminal.expect("请选择："); terminal.send("0"); terminal.expect("请选择："); terminal.send("0")
    output = terminal.finish()
    assert "设置已保存并完成实际回读" not in output
    assert json.loads((DEPLOY / "config/menu.yaml").read_text())["welcome"] == before["welcome"]
    assert_chinese_result(output)
    passing("欢迎保存回读失败保留旧欢迎，中文不声称目标已关闭或保存成功")
    recovered = invoke(["bash", str(DEPLOY / "manage.sh"), "--deploy-dir", str(DEPLOY), "apply", "--force-external"])
    assert recovered.returncode == 0, recovered.stdout


def presentation_cases():
    """实际管理入口呈现与纯机器回执分离，失败不改为成功。"""
    command = ["bash", str(DEPLOY / "manage.sh"), "--deploy-dir", str(DEPLOY)]
    for action, state in (("disable", False), ("enable", True)):
        result = subprocess.run(command + [action, "--json"], env=ENV, cwd=WORK, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        assert result.returncode == 0, result.stdout + result.stderr
        reply = json.loads(result.stdout)
        assert reply["ok"] is True and reply["target"] == "runtime" and reply["configuration"]["enabled"] is state
        applied = json.loads((DEPLOY / "config/materials-applied.json").read_text())
        assert applied["configuration"]["runtime"]["enabled"] is state
    for arguments in (["apply", "--check", "--json"], ["status", "--json"], ["logs", "policy", "--json"]):
        result = subprocess.run(command + arguments, env=ENV, cwd=WORK, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        reply = json.loads(result.stdout)
        assert isinstance(reply, dict)
        if arguments[0] == "logs":
            # 本夹具不是 Docker/systemd 环境，报告非绿灯仍须准确透传而非改成成功。
            assert result.returncode == {"PASS": 0, "WARN": 2, "FAIL": 1}[reply["status"]], result.stdout
        else:
            assert result.returncode == 0, repr(arguments) + result.stdout + result.stderr
    result = subprocess.run(command + ["disable", "--json"], env={**ENV, "CONFIGURATION_FIXTURE_READBACK_FAIL": "1"},
                            cwd=WORK, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    assert result.returncode != 0 and json.loads(result.stdout)["ok"] is False
    assert json.loads((DEPLOY / "config/runtime.yaml").read_text())["enabled"] is True
    passing("显式 enable/disable/apply/status/logs --json 的stdout逐份严格解析；失败非零且不夹中文进度或假成功")
    recovered = invoke(command + ["apply", "--force-external"])
    assert recovered.returncode == 0, recovered.stdout

    for number, action, token in ((5, 1, "知识库："), (6, 1, "规则："), (7, 1, "自动恢复秒数"),
                                  (8, 3, "客服总开关："), (9, 1, "欢迎语："), (10, 1, "网站标识："),
                                  (11, 1, "总问题："), (11, 2, "历史好评："), (15, 1, "日志维护："),
                                  (15, 6, "日志保留"), (16, 8, "资料路径：")):
        terminal = Terminal(f"readable-menu-{number}-{action}")
        terminal.expect("请选择："); terminal.send(str(number)); terminal.expect("请选择："); terminal.send(str(action))
        terminal.expect(token)
        if number == 15 and action == 6:
            terminal.expect("文件日志保留天数"); terminal.send("0")
        terminal.expect("请选择："); terminal.send("0"); terminal.expect("请选择："); terminal.send("0")
        assert_chinese_result(terminal.finish())
    passing("真实知识/规则/恢复/总开关/欢迎/Crisp/统计/日志/资料子菜单读取中文结果，无内部对象或编号")

    feedback = json.loads((DEPLOY / "config/feedback.yaml").read_text())
    old_runtime = json.loads((DEPLOY / "config/runtime.yaml").read_text())["enabled"]
    terminal = Terminal("history-retention-no-invite")
    terminal.expect("请选择："); terminal.send("11")
    terminal.expect("自动评价邀请已停用"); terminal.expect("请选择："); terminal.send("5")
    terminal.expect("新的历史保留天数"); terminal.send("45")
    terminal.expect("1 确认 / 0 返回："); terminal.send("1")
    terminal.expect("保留天数：45")
    terminal.expect("请选择："); terminal.send("0"); terminal.expect("请选择："); terminal.send("0")
    output = terminal.finish(); assert_chinese_result(output)
    actual = json.loads((DEPLOY / "config/feedback.yaml").read_text())["feedback"]
    assert actual["retention_days"] == 45 and actual["enabled"] is False and actual["auto_invite"] is False
    assert actual["prompt"] == feedback["feedback"]["prompt"]
    assert json.loads((DEPLOY / "config/runtime.yaml").read_text())["enabled"] is old_runtime
    assert "反馈：1 启用" not in output and "反馈启停" not in output
    passing("统计菜单仅历史保留期真实应用，邀请始终停用、原历史文案和总开关保持")

    menu_source = DEPLOY / "config/menu.yaml"
    runtime_source = DEPLOY / "config/runtime.yaml"
    menu_before, runtime_before = menu_source.read_bytes(), runtime_source.read_bytes()
    projection = DEPLOY / "config/materials-applied.json"
    effective_before = projection.read_bytes()
    try:
        menu = json.loads(menu_before); menu["welcome"]["enabled"] = False
        menu_source.write_text(json.dumps(menu), encoding="utf-8")
        terminal = Terminal("welcome-read-effective-not-source")
        terminal.expect("请选择："); terminal.send("9"); terminal.expect("请选择："); terminal.send("1")
        terminal.expect("当前已应用状态："); terminal.expect("欢迎语：已启用")
        terminal.expect("另有未应用的原文修改")
        terminal.expect("请选择："); terminal.send("0"); terminal.expect("请选择："); terminal.send("0")
        output = terminal.finish(); assert_chinese_result(output)
        assert "欢迎语：已关闭" not in output and projection.read_bytes() == effective_before
        menu_source.write_bytes(menu_before)
        runtime = json.loads(runtime_before); runtime["enabled"] = False
        runtime_source.write_text(json.dumps(runtime), encoding="utf-8")
        result = subprocess.run(command + ["status", "--json"], env=ENV, cwd=WORK, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        reply = json.loads(result.stdout)
        assert result.returncode == 2 and reply["applied"] is True and reply["pending"] is True and reply["value"]["enabled"] is True
        terminal = Terminal("welcome-pending-global-guard")
        terminal.expect("请选择："); terminal.send("9"); terminal.expect("请选择："); terminal.send("3")
        terminal.expect("客服总开关原文有未应用修改")
        terminal.expect("请选择："); terminal.send("0"); terminal.expect("请选择："); terminal.send("0")
        output = terminal.finish(); assert_chinese_result(output)
        assert menu_source.read_bytes() == menu_before and projection.read_bytes() == effective_before
        assert "设置已保存" not in output
    finally:
        menu_source.write_bytes(menu_before); runtime_source.write_bytes(runtime_before)
    passing("原文未应用时欢迎/状态显示真实有效值与待应用标记；欢迎操作拒绝夹带修改总开关")


def renderer_cases():
    source = WORK / "renderer-source.json"
    errors = WORK / "renderer-error.txt"
    script = ["python3", str(DEPLOY / "scripts/menu-display.py")]
    errors.write_text("", encoding="utf-8")
    cases = [
        ("welcome", {"welcome": {"enabled": False}, "enabled": True, "revision": 3}, "欢迎语：已关闭"),
        ("welcome", {"enabled": True}, "欢迎语：未能确认"),
        ("runtime", {"enabled": False, "revision": 0}, "客服总开关：已停用"),
        ("detail", {"count": 0, "enabled": True}, "数量：0"),
        ("detail", {"count": 1, "enabled": False}, "数量：1"),
        ("pool", {"ok": True, "draft": True, "applied": False, "entries": 3}, "仅保存草稿，尚未应用"),
        ("detail", {"applied": False, "draft": True, "business_applied": True,
                    "provider_pool_applied": False, "missing_credentials": [{"id": "p_" + "a" * 24, "name": "待补主接口"}]}, "3 → 10 → 11"),
        ("detail", {"website_id": "private-website-identifier", "api_key": "synthetic-hidden-secret"}, "网站标识：已配置（默认隐藏）"),
        ("sessions", [{"key": "a" * 64, "session_id": "private-session", "mode": "human", "resume_at": None},
                      {"key": "b" * 64, "mode": "ai"}], "当前人工会话：1 个"),
        ("doctor", {"results": [{"id": "private-check-id", "name": "虚构组件", "status": "WARN", "summary": "待验证"}],
                    "summary": {"pass": 0, "warn": 1, "fail": 0, "skip": 0}}, "【需关注】虚构组件"),
    ]
    for kind, value, expected in cases:
        source.write_text(json.dumps(value), encoding="utf-8")
        result = invoke(script + [kind, str(source), str(errors), "0"])
        assert result.returncode == 0 and expected in result.stdout, result.stdout
        assert_chinese_result(result.stdout)
        assert not re.search(r'private-(?:check-id|session|website-identifier)', result.stdout), result.stdout
    errors.write_text('Traceback (most recent call last):\n  File "private", line 1\nValueError: synthetic-hidden-secret\n', encoding="utf-8")
    source.write_text('{broken output', encoding="utf-8")
    result = invoke(script + ["detail", str(source), str(errors), "1"])
    assert "操作未完成" in result.stdout and "发生异常" in result.stdout
    assert "synthetic-hidden-secret" not in result.stdout and "Traceback" not in result.stdout
    source.write_text(json.dumps({"enabled": True, "revision": 7}), encoding="utf-8")
    result = subprocess.run(script + ["runtime", str(source), str(errors), "1", "--json"], env=ENV, cwd=WORK,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10)
    assert json.loads(result.stdout)["ok"] is False
    assert "synthetic-hidden-secret" not in result.stdout + result.stderr
    errors.write_text("中文进度，不可放机器标准输出。\n", encoding="utf-8")
    result = subprocess.run(script + ["runtime", str(source), str(errors), "0", "--json"], env=ENV, cwd=WORK,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10)
    assert json.loads(result.stdout) == {"enabled": True, "revision": 7} and "中文进度" in result.stderr
    passing("中文展示器13个边界：数值非布尔、目标未知不冒称关闭、草稿未生效、隐藏标识/秘密、失败纯JSON且进度仅stderr")


def signal_menu_cases():
    protected = {path: path.read_bytes() for name in ("config", "knowledge", "data")
                 for path in (DEPLOY / name).rglob("*") if path.is_file()}
    protected[DEPLOY / ".env"] = (DEPLOY / ".env").read_bytes()
    input_directories = set(Path("/tmp").glob("crispai-menu-input.*"))
    pending_secret = "synthetic-hidden-signal-value"

    def finish_interrupt(terminal, signals=(signal.SIGINT,), *, parent_only=False, hidden=False, eof=False, eof_status=0):
        children = Path(f"/proc/{terminal.process.pid}/task/{terminal.process.pid}/children").read_text().split()
        if hidden:
            assert not (termios.tcgetattr(terminal.master)[3] & termios.ECHO)
            if not eof:
                os.write(terminal.master, pending_secret.encode())
        if eof:
            os.write(terminal.master, b"\x04")
        else:
            for requested in signals:
                try:
                    if parent_only:
                        os.kill(terminal.process.pid, requested)
                    else:
                        os.killpg(terminal.process.pid, requested)
                except ProcessLookupError:
                    break
        try:
            terminal.process.wait(timeout=2)
        except subprocess.TimeoutExpired as error:
            os.killpg(terminal.process.pid, signal.SIGKILL)
            terminal.process.wait(timeout=2)
            terminal.read()
            raise AssertionError(f"{terminal.name}: 信号后 2 秒内未退出，不允许用超时重试代替修复") from error
        assert termios.tcgetattr(terminal.master) == terminal.tty_before, terminal.name
        assert all(not Path(f"/proc/{pid}").exists() for pid in children), terminal.name
        if hidden and not eof:
            reader = os.open(terminal.slave_name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOCTTY)
            try:
                os.write(terminal.master, b"\n")
                assert os.read(reader, 4096) == b"\n", "中断后的秘密输入残留在终端输入队列"
            finally:
                os.close(reader)
        output = terminal.finish(eof_status if eof else 130)
        assert pending_secret not in output
        assert not (set(Path("/tmp").glob("crispai-menu-input.*")) - input_directories), terminal.name
        assert all(path.read_bytes() == value for path, value in protected.items()), terminal.name

    for index in range(30):
        terminal = Terminal(f"sigint-prompt-race-{index}")
        terminal.expect("请选择：")
        finish_interrupt(terminal)

    for name, signals, parent_only in (
        ("sigterm", (signal.SIGTERM,), False),
        ("double-sigint", (signal.SIGINT, signal.SIGINT), False),
        ("parent-sigint", (signal.SIGINT,), True),
    ):
        terminal = Terminal(name)
        terminal.expect("请选择：")
        finish_interrupt(terminal, signals, parent_only=parent_only)

    for name, commands, ready in (
        ("submenu", ("2",), "请选择："),
        ("hidden", ("3", "2", "3"), "新 API Key（隐藏输入，回车保留）（0 取消本项）："),
        ("multiline", ("4", "2"), "正文需要结束符字面量时"),
        ("confirm", ("16", "2"), "1 确认 / 0 返回："),
    ):
        for suffix, signals, eof in (
            ("int", (signal.SIGINT,), False),
            ("term", (signal.SIGTERM,), False),
            ("double", (signal.SIGINT, signal.SIGINT), False),
            ("eof", (), True),
        ):
            terminal = Terminal(f"{name}-{suffix}")
            for command in commands:
                terminal.expect("请选择：")
                terminal.send(command)
            terminal.expect(ready)
            # 直接传播 read 失败的子菜单为 1；候选编辑由导航包装取消，退出为 0。
            finish_interrupt(terminal, signals, hidden=name == "hidden", eof=eof,
                             eof_status=1 if name == "submenu" else 0)

    result = invoke(["bash", str(DEPLOY / "manage.sh"), "--deploy-dir", str(DEPLOY)], content="2\n0\n0\n")
    assert result.returncode == 0 and "快速自检" in result.stdout, result.stdout
    assert all(path.read_bytes() == value for path, value in protected.items())
    assert not (set(Path("/tmp").glob("crispai-menu-input.*")) - input_directories)
    passing("SIGINT 提示瞬间30轮、子菜单/隐藏/多行/确认的INT/TERM/双信号/EOF及非TTY输入，2秒内退出且TTY/秘密/配置保持")


def main():
    global ENV
    for name in ("config", "scripts", "n8n", "docs"):
        shutil.copytree(ROOT / name, DEPLOY / name)
    for name in ("get.sh", "manage.sh", "install.sh", "update.sh", "uninstall.sh", "VERSION", "docker-compose.yml"):
        shutil.copy2(ROOT / name, DEPLOY / name)
    for name in ("tmp", "logs", "backups/config-history", "knowledge", "data/runtime"):
        (DEPLOY / name).mkdir(parents=True, exist_ok=True)
    BIN.mkdir()
    shutil.copy2(ROOT / "tests/mocks/configuration_docker", BIN / "docker")
    (BIN / "docker").chmod(0o755)
    for name in ("runtime", "provider", "keyword", "menu", "handoff", "tags", "feedback"):
        shutil.copy2(ROOT / f"config/{name}.yaml.example", DEPLOY / f"config/{name}.yaml")
    (DEPLOY / ".crisp-ai-installation").write_text("ai-support\nstate=local-ready\nfact_conversation=pending\n", encoding="utf-8")
    (DEPLOY / "config/prompt.md").write_text(PROMPT["text"], encoding="utf-8")
    (DEPLOY / "knowledge/catalog.json").write_text('{"schema_version":2,"revision":1,"libraries":[]}', encoding="utf-8")
    (DEPLOY / "data/knowledge-manifest.json").write_text('{"version":1,"files":{},"garbage_locations":[]}', encoding="utf-8")
    for directory in (DEPLOY / "config", DEPLOY / "knowledge", DEPLOY / "data"):
        directory.chmod(0o750)
        for file in directory.rglob("*"):
            if file.is_file():
                file.chmod(0o640)
    fixture = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ApplicationFixture)
    threading.Thread(target=fixture.serve_forever, daemon=True).start()
    port = fixture.server_address[1]
    (DEPLOY / ".env").write_text(
        f"DEPLOY_DIR={json.dumps(str(DEPLOY), ensure_ascii=False)}\nANYTHINGLLM_API_KEY=synthetic-menu-secret\nANYTHINGLLM_PORT={port}\nANYTHINGLLM_WORKSPACE=crisp-support\nN8N_PORT={port}\nLOCAL_HEALTH_TIMEOUT_SECONDS=5\nN8N_WORKFLOW_READY_TIMEOUT_SECONDS=5\n"
        f"AI_API_BASE_URL=http://127.0.0.1:{port}/proxy/v1\nAI_API_PROBE_BASE_URL=http://127.0.0.1:{port}/proxy/v1\nAI_API_KEY=synthetic-menu-key\nAI_MODEL=synthetic-menu-model\nAI_API_MODE=chat_completions\n"
        "CRISP_WEBSITE_ID=11111111-1111-1111-1111-111111111111\nCRISP_TOKEN_TIER=website\nCRISP_HOOK_MODE=website\nCRISP_TOKEN_IDENTIFIER=synthetic-identifier\nCRISP_TOKEN_KEY=synthetic-crisp-key\nWEBHOOK_PRODUCTION_URL=https://support.example.invalid/webhook/crisp-webhook\n"
        "CRISPAI_LOG_MAX_SIZE=10m\nCRISPAI_LOG_MAX_FILES=5\nCRISPAI_LOG_RETENTION_DAYS=7\nCRISPAI_LOG_RETENTION_HOURS=168\n",
        encoding="utf-8")
    (DEPLOY / ".env").chmod(0o600)
    ENV = {**os.environ, "PATH": str(BIN) + ":" + os.environ["PATH"], "LANG": "C.UTF-8", "CONFIGURATION_FIXTURE_DEPLOY": str(DEPLOY)}
    migrated = invoke(["bash", str(DEPLOY / "scripts/provider.sh"), "--deploy-dir", str(DEPLOY), "migrate"])
    assert migrated.returncode == 0, migrated.stdout
    pool_key = next(line.split("=", 1)[1] for line in (DEPLOY / ".env").read_text().splitlines()
                    if line.startswith("PROVIDER_ADAPTER_KEY="))
    adapter_log = (WORK / "adapter-stderr.log").open("w", encoding="utf-8")
    adapter = subprocess.Popen(["node", "-e", "const {createAdapter}=require(process.argv[1]);const s=createAdapter();s.listen(0,'127.0.0.1',()=>process.stdout.write(String(s.address().port)+'\\n'));process.on('SIGTERM',()=>{s.closeAllConnections();s.close(()=>process.exit(0));});", str(DEPLOY / "scripts/provider-adapter.js")],
                               stdout=subprocess.PIPE, stderr=adapter_log, text=True,
                               env={**ENV, "PROVIDER_ROOT": str(DEPLOY), "PROVIDER_ADAPTER_KEY": pool_key,
                                    "PROVIDER_POOL_REQUIRED": "true"})
    assert select.select([adapter.stdout], [], [], 10)[0], "真实本地 adapter 未有界启动"
    adapter_port = adapter.stdout.readline().strip()
    assert adapter_port.isdecimal() and adapter.poll() is None
    ENV["PROVIDER_ADAPTER_MANAGEMENT_URL"] = f"http://127.0.0.1:{adapter_port}"
    try:
        if os.environ.get("MENU_TEST_FOCUS") == "welcome":
            welcome_presentation_cases()
            return
        if os.environ.get("MENU_TEST_FOCUS") == "provider":
            provider_retry_cases()
            provider_pool_menu_cases()
            provider_file_menu_cases()
            return
        if os.environ.get("MENU_TEST_FOCUS") == "presentation":
            material_menu_cases()
            welcome_presentation_cases()
            presentation_cases()
            renderer_cases()
            return
        for argument in ("--help", "--version"):
            result = invoke(["bash", str(DEPLOY / "manage.sh"), argument])
            assert result.returncode == 0, result.stdout
        passing("帮助与版本不调用 Docker 或外部 Provider")
        labels = ["保留现有配置", "快速自检", "查看主备接口列表", "查看当前 Prompt", "查看知识库及索引状态", "查看规则", "查看恢复设置", "关闭客服会停止", "查看欢迎配置", "查看脱敏接入配置", "知识命中分析", "导出完整业务", "创建本机完整备份", "匿名在线更新至最新正式版", "日志来源、占用与保留策略", "启动本项目服务", "安装部署", "安全卸载"]
        for number, label in enumerate(labels, 1):
            menu_case(number, label)
        online_update_menu_case()
        log_menu_cases()
        material_menu_cases()
        welcome_presentation_cases()
        presentation_cases()
        renderer_cases()
        for name, width, extra in (("wide", 110, {}), ("narrow", 42, {}), ("dumb", 110, {"TERM": "dumb", "NO_COLOR": "1"}), ("plain", 110, {"CRISPAI_NO_EMOJI": "1"}), ("nonutf8", 110, {"LC_ALL": "C"})):
            terminal = Terminal(name, width=width, extra=extra)
            terminal.expect("请选择：")
            terminal.send("0")
            output = terminal.finish()
            assert "\x1b" not in output, output
            rows = [line for line in output.splitlines() if re.search(r"\b1\. ", line)]
            assert rows, output
            if name == "wide":
                assert "2. " in rows[0], output
            elif name in ("narrow", "dumb", "nonutf8"):
                assert "2. " not in rows[0], output
            if name in ("plain", "dumb", "nonutf8"):
                assert "🚀" not in output
        passing("宽屏双栏、窄屏/dumb/NO_COLOR/无Emoji/非UTF8降级")
        lock_path = DEPLOY / "tmp/maintenance.lock"
        lock_before = lock_path.read_bytes() if lock_path.exists() else None
        terminal = Terminal("invalid-eof")
        terminal.expect("请选择：")
        if lock_path.exists():
            with lock_path.open("rb") as lock_file:
                fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(lock_file, fcntl.LOCK_UN)
        terminal.send("")
        terminal.expect("回车不会执行操作"); terminal.expect("请选择："); terminal.send("999")
        terminal.expect("请输入菜单中的数字"); terminal.expect("请选择：")
        os.write(terminal.master, b"\x04"); terminal.finish()
        assert (lock_path.read_bytes() if lock_path.exists() else None) == lock_before
        passing("回车/非法数字/EOF 安全退出，空闲菜单不持维护锁")
        signal_menu_cases()
        provider_retry_cases()
        provider_pool_menu_cases()
        provider_file_menu_cases()
        prompt = '## 中文 🙂 Prompt\n\n$ # = " \\ `touch should-not-execute`\n::END::\n\n'
        terminal = Terminal("prompt-paste")
        for prompt_token, answer in (("请选择：", "4"), ("请选择：", "2")):
            terminal.expect(prompt_token); terminal.send(answer)
        terminal.expect("正文需要结束符字面量时")
        for line in prompt.splitlines():
            terminal.send("\\" + line if line in ("::END::", "::CANCEL::") else line)
        terminal.send("::END::"); terminal.expect("应用新 Prompt 到当前客服？"); terminal.send("1")
        terminal.expect('资料已应用：是'); terminal.expect("请选择："); terminal.send("0")
        terminal.expect("请选择："); terminal.send("0"); terminal.finish()
        assert (DEPLOY / "config/prompt.md").read_text() == prompt
        assert PROMPT["text"] == prompt
        assert not (WORK / "should-not-execute").exists()
        passing("生产菜单多行Prompt逐字落盘、HTTP应用和读回；正文不执行")
        terminal = Terminal("prompt-cancel")
        terminal.expect("请选择："); terminal.send("4"); terminal.expect("请选择："); terminal.send("2")
        terminal.expect("正文需要结束符字面量时"); terminal.send("不要保存"); terminal.send("::CANCEL::")
        terminal.expect("请选择："); terminal.send("0"); terminal.expect("请选择："); terminal.send("0"); terminal.finish()
        assert PROMPT["text"] == prompt
        passing("粘贴取消不改Prompt")
        for command, expected in (("disable", False), ("enable", True)):
            result = invoke(["bash", str(DEPLOY / "manage.sh"), "--deploy-dir", str(DEPLOY), command])
            assert result.returncode == 0, result.stdout
            actual = json.loads((DEPLOY / "config/runtime.yaml").read_text())
            assert actual["enabled"] == expected and actual["revision"] == actual["applied_revision"]
        passing("生产 enable/disable 使用统一apply/readback且不中断服务")
        before = (DEPLOY / "config/runtime.yaml").read_text()
        result = invoke(["bash", str(DEPLOY / "manage.sh"), "--deploy-dir", str(DEPLOY), "disable"], extra={"CONFIGURATION_FIXTURE_READBACK_FAIL": "1"})
        assert result.returncode != 0, result.stdout
        assert json.loads((DEPLOY / "config/runtime.yaml").read_text())["enabled"] == json.loads(before)["enabled"]
        passing("运行时回读失败时CLI非零且保留旧总开关")
        terminal = Terminal("welcome-resume")
        terminal.expect("请选择："); terminal.send("7"); terminal.expect("请选择："); terminal.send("2")
        terminal.expect("新恢复秒数"); terminal.send("0"); terminal.expect('设置已保存并完成实际回读')
        terminal.expect("请选择："); terminal.send("0"); terminal.expect("请选择："); terminal.send("9")
        terminal.expect("请选择："); terminal.send("3"); terminal.expect('欢迎语：已关闭')
        terminal.expect("请选择："); terminal.send("0"); terminal.expect("请选择："); terminal.send("0"); terminal.finish()
        assert json.loads((DEPLOY / "config/handoff.yaml").read_text())["handoff"]["resume_after_seconds"] == 0
        assert json.loads((DEPLOY / "config/menu.yaml").read_text())["welcome"]["enabled"] is False
        passing("生产菜单修改0秒永久人工与欢迎关闭实际读回")
        terminal = Terminal("new-menu-node")
        terminal.expect("请选择："); terminal.send("9"); terminal.expect("请选择："); terminal.send("8")
        terminal.expect("请选择："); terminal.send("2"); terminal.expect("新节点标题："); terminal.send("虚构测试节点")
        terminal.expect("请选择序号"); terminal.send("1"); terminal.expect("新菜单“虚构测试节点”已生效")
        for _ in range(3):
            terminal.expect("请选择："); terminal.send("0")
        output = terminal.finish()
        assert "候选配置格式或边界无效" not in output, output
        nodes = json.loads((DEPLOY / "config/menu.yaml").read_text())["menus"]
        created = next((node for node in nodes.values() if node["title"] == "虚构测试节点"), None)
        assert created and created["options"]["0"]["action"]["back"] is True
        passing("多级菜单创建节点同时建立父入口与受限返回按钮")
        launcher = BIN / "crispai"
        install = ["bash", str(ROOT / "scripts/launcher.sh"), "install", "--deploy-dir", str(DEPLOY), "--command-path", str(launcher), "--non-interactive"]
        result = invoke(install); assert result.returncode == 0, result.stdout
        assert "synthetic-menu-key" not in launcher.read_text()
        first = hashlib.sha256(launcher.read_bytes()).hexdigest()
        assert invoke(install).returncode == 0 and hashlib.sha256(launcher.read_bytes()).hexdigest() == first
        for directory in (Path("/tmp"), Path("/"), Path("/root")):
            terminal = Terminal("launcher-" + (directory.name or "rootfs"), command=[str(launcher)], cwd=directory)
            terminal.expect("请选择："); terminal.send("0"); terminal.finish()
        passing("受管crispai按绝对路径运行；陌生cwd/引号路径/重复安装")
        assert invoke([str(launcher), "--version"]).stdout.strip() == (DEPLOY / "VERSION").read_text().strip()
        assert invoke([str(launcher), "--help"]).returncode == 0
        removal = ["bash", str(ROOT / "scripts/launcher.sh"), "remove", "--deploy-dir", str(DEPLOY)]
        assert invoke(removal).returncode == 0 and not launcher.exists()
        assert invoke(install).returncode == 0
        launcher.write_text("#!/usr/bin/env bash\nprintf 'foreign command\\n'\n"); launcher.chmod(0o755)
        assert invoke(install).returncode != 0 and "foreign command" in launcher.read_text()
        assert invoke(removal).returncode == 0 and launcher.exists()
        assert invoke(["bash", str(ROOT / "scripts/launcher.sh"), "install", "--deploy-dir", str(DEPLOY), "--command-path", str(launcher)], content="0\n").returncode == 2
        assert "foreign command" in launcher.read_text()
        passing("入口移除/重建、外来同名命令拒绝覆盖与数字取消")
        terminal = Terminal("safe-uninstall-cancel")
        terminal.expect("请选择："); terminal.send("18"); terminal.expect("请选择："); terminal.send("1")
        terminal.expect("0 返回"); terminal.send("0"); terminal.expect("请选择："); terminal.send("0")
        terminal.expect("请选择："); terminal.send("0"); terminal.finish()
        assert (DEPLOY / "manage.sh").exists() and (DEPLOY / ".env").exists()
        passing("主菜单18真实uninstall入口数字取消不动服务或数据")
        cache = DEPLOY / "logs/doctor-last.json"
        cache.parent.mkdir(exist_ok=True)
        cache.write_text(json.dumps({"schema_version": 1, "checked_at": "2026-09-07T00:00:00Z", "summary": {"fail": 1, "warn": 2}}))
        before_configuration = (DEPLOY / "config/runtime.yaml").read_bytes()
        before_provider = MODEL_LIST["chat_calls"]
        terminal = Terminal("cached-doctor-summary")
        terminal.expect("上次自检（缓存）：2026-09-07T00:00:00Z；失败 1，警告 2")
        terminal.expect("请选择："); terminal.send("0"); terminal.finish()
        assert (DEPLOY / "config/runtime.yaml").read_bytes() == before_configuration
        assert MODEL_LIST["chat_calls"] == before_provider
        cache.unlink()
        passing("主菜单只读带时间缓存，不联网、不把旧状态冒充当前自检")
        print(f"管理入口专项：{COUNT} 通过，0 失败。协议Fixture不是空机/真实Docker证据。")
        print(f"脱敏测试转录：{WORK.relative_to(ROOT)}")
    finally:
        adapter.terminate()
        adapter.wait(timeout=5)
        adapter.stdout.close()
        adapter_log.close()
        fixture.shutdown(); fixture.server_close()


if __name__ == "__main__":
    main()
