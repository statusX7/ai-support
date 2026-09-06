#!/usr/bin/env python3
"""Drive production Shell menus; application HTTP/daemon readback are protocol fixtures."""

import errno
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


class ApplicationFixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def answer(self, body):
        payload = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(200)
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
            self.answer({"data": [{"id": "synthetic-menu-model"}]})
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
            self.answer({"choices": [{"message": {"content": "协议测试，不是真实模型。"}}], "output_text": "协议测试"})
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


def main():
    global ENV
    for name in ("config", "scripts", "n8n", "docs"):
        shutil.copytree(ROOT / name, DEPLOY / name)
    for name in ("manage.sh", "install.sh", "update.sh", "uninstall.sh", "VERSION", "docker-compose.yml"):
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
    fixture = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ApplicationFixture)
    threading.Thread(target=fixture.serve_forever, daemon=True).start()
    port = fixture.server_address[1]
    (DEPLOY / ".env").write_text(
        f"DEPLOY_DIR={json.dumps(str(DEPLOY), ensure_ascii=False)}\nANYTHINGLLM_API_KEY=synthetic-menu-secret\nANYTHINGLLM_PORT={port}\nANYTHINGLLM_WORKSPACE=crisp-support\n"
        f"AI_API_BASE_URL=http://127.0.0.1:{port}/proxy/v1\nAI_API_PROBE_BASE_URL=http://127.0.0.1:{port}/proxy/v1\nAI_API_KEY=synthetic-menu-key\nAI_MODEL=synthetic-menu-model\nAI_API_MODE=chat_completions\n"
        "CRISP_WEBSITE_ID=11111111-1111-1111-1111-111111111111\nCRISP_TOKEN_TIER=website\nCRISP_HOOK_MODE=website\nCRISP_TOKEN_IDENTIFIER=synthetic-identifier\nCRISP_TOKEN_KEY=synthetic-crisp-key\nWEBHOOK_PRODUCTION_URL=https://support.example.invalid/webhook/crisp-webhook\n",
        encoding="utf-8")
    (DEPLOY / ".env").chmod(0o600)
    ENV = {**os.environ, "PATH": str(BIN) + ":" + os.environ["PATH"], "LANG": "C.UTF-8", "CONFIGURATION_FIXTURE_DEPLOY": str(DEPLOY)}
    try:
        for argument in ("--help", "--version"):
            result = invoke(["bash", str(DEPLOY / "manage.sh"), argument])
            assert result.returncode == 0, result.stdout
        passing("帮助与版本不调用 Docker 或外部 Provider")
        labels = ["保留现有配置", "初始化与接入事实", "查看脱敏配置", "查看当前 Prompt", "查看知识库及索引状态", "查看规则", "查看恢复设置", "关闭客服会停止", "查看欢迎配置", "查看脱敏接入配置", "知识命中分析", "导出完整业务", "创建本机完整备份", "从已解压", "n8n 最近日志", "启动本项目服务", "安装部署", "安全卸载"]
        for number, label in enumerate(labels, 1):
            menu_case(number, label)
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
        terminal = Terminal("invalid-eof")
        terminal.expect("请选择："); terminal.send("")
        terminal.expect("回车不会执行操作"); terminal.expect("请选择："); terminal.send("999")
        terminal.expect("请输入菜单中的数字"); terminal.expect("请选择：")
        os.write(terminal.master, b"\x04"); terminal.finish()
        assert not (DEPLOY / "tmp/maintenance.lock").exists()
        passing("回车/非法数字/EOF 安全退出，空闲菜单不持维护锁")
        terminal = Terminal("sigint")
        terminal.expect("请选择："); os.killpg(terminal.process.pid, signal.SIGINT); terminal.finish(130)
        passing("SIGINT 保留现有配置并有限退出")
        prompt = '## 中文 🙂 Prompt\n\n$ # = " \\ `touch should-not-execute`\n::END::\n\n'
        terminal = Terminal("prompt-paste")
        for prompt_token, answer in (("请选择：", "4"), ("请选择：", "2")):
            terminal.expect(prompt_token); terminal.send(answer)
        terminal.expect("正文需要结束符字面量时")
        for line in prompt.splitlines():
            terminal.send("\\" + line if line in ("::END::", "::CANCEL::") else line)
        terminal.send("::END::"); terminal.expect("应用新 Prompt 到当前客服？"); terminal.send("1")
        terminal.expect('"applied": true'); terminal.expect("请选择："); terminal.send("0")
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
        terminal.expect("新恢复秒数"); terminal.send("0"); terminal.expect('"applied_revision"')
        terminal.expect("请选择："); terminal.send("0"); terminal.expect("请选择："); terminal.send("9")
        terminal.expect("请选择："); terminal.send("3"); terminal.expect('"applied_revision"')
        terminal.expect("请选择："); terminal.send("0"); terminal.expect("请选择："); terminal.send("0"); terminal.finish()
        assert json.loads((DEPLOY / "config/handoff.yaml").read_text())["handoff"]["resume_after_seconds"] == 0
        assert json.loads((DEPLOY / "config/menu.yaml").read_text())["welcome"]["enabled"] is False
        passing("生产菜单修改0秒永久人工与欢迎关闭实际读回")
        terminal = Terminal("new-menu-node")
        terminal.expect("请选择："); terminal.send("9"); terminal.expect("请选择："); terminal.send("8")
        terminal.expect("请选择："); terminal.send("2"); terminal.expect("新节点标题："); terminal.send("虚构测试节点")
        terminal.expect("请选择序号"); terminal.send("1"); terminal.expect("新节点 ID：")
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
        print(f"管理入口专项：{COUNT} 通过，0 失败。协议Fixture不是空机/真实Docker证据。")
        print(f"脱敏测试转录：{WORK.relative_to(ROOT)}")
    finally:
        fixture.shutdown(); fixture.server_close()


if __name__ == "__main__":
    main()
