#!/usr/bin/env python3
"""RAG 配置应用边界：合成 Docker/API；不启动服务、不进行模型调用。"""

import json
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ["RAG_FIXTURE_ROOT"])
args = sys.argv[1:]
fault = os.environ.get("RAG_FIXTURE_FAULT", "")
if pathlib.Path(sys.argv[0]).name == "curl":
    output = pathlib.Path(args[args.index("--output") + 1])
    value = (root / "current").read_text()
    output.write_text(json.dumps({"settings": {"GenericOpenAiTokenLimit": "17" if fault == "api_drift" else value}}))
    print("401" if fault == "api_auth" else "200", end="")
    sys.exit(0)
if args[0] == "context":
    print("tcp://fixture.invalid:2376" if fault == "remote" else "unix:///var/run/docker.sock")
    sys.exit(0)
if args[0] == "inspect":
    print((str(root) if fault != "foreign" else "/opt/other-fixture") + "|anythingllm")
    sys.exit(0)
if args[0] != "compose":
    sys.exit(99)
args = args[1:]
while args and args[0] in ("--project-directory", "--env-file", "-f"):
    args = args[2:]
if args[0] == "ps":
    if fault != "absent": print("a" * 64)
elif args[0] == "up":
    assert args == ["up", "-d", "--no-deps", "--force-recreate", "anythingllm"]
    assert "PROVIDER_RAG_CONTEXT_WINDOW" not in os.environ
    assert os.environ["DEPLOY_DIR"] == str(root)
    with (root / "calls").open("a") as stream: stream.write("recreate-anythingllm\n")
    if fault == "recreate": sys.exit(1)
    env = dict(line.split("=", 1) for line in (root / ".env").read_text().splitlines())
    (root / "current").write_text(env["PROVIDER_RAG_CONTEXT_WINDOW"])
elif args[0] == "exec":
    assert args[:5] == ["exec", "-T", "anythingllm", "node", "-e"]
    print("17" if fault == "container_drift" else (root / "current").read_text(), end="")
else:
    sys.exit(99)
'''


def main():
    passed = 0
    with tempfile.TemporaryDirectory(prefix=".test-runtime.rag-context.", dir=ROOT) as temporary:
        root = Path(temporary)
        for name in ("config", "tmp", "bin"):
            (root / name).mkdir()
        (root / ".crisp-ai-installation").write_text("ai-support\nstate=local-ready\n")
        (root / ".env").write_text("PROVIDER_RAG_CONTEXT_WINDOW=16384\nANYTHINGLLM_API_KEY=fixture-internal-key\nANYTHINGLLM_PORT=3001\n")
        (root / "docker-compose.yml").write_text("services: {}\n")
        (root / "config/provider-pool-applied.json").write_text(json.dumps({"entries": [
            {"enabled": True, "api_mode": "chat_completions", "context_window": 8192, "capabilities": {"chat_completions": True}},
            {"enabled": True, "api_mode": "responses", "context_window": 16384, "capabilities": {"responses": True}},
            {"enabled": False, "api_mode": "responses", "context_window": 131072, "capabilities": {"responses": True}},
        ]}))
        for name in ("docker", "curl"):
            (root / "bin" / name).write_text(MOCK)
            (root / "bin" / name).chmod(0o700)
        command = ["bash", "-c", 'source "$1"; sleep() { SECONDS=$((SECONDS + 120)); }; provider_rag_context_apply "$2" "$3"',
                   "rag-context-test", str(ROOT / "scripts/common.sh"), str(root)]
        environment = {"PATH": str(root / "bin") + ":/usr/bin:/bin", "LC_ALL": "C.UTF-8", "RAG_FIXTURE_ROOT": str(root),
                       "DEPLOY_DIR": "/opt/foreign-fixture", "PROVIDER_RAG_CONTEXT_WINDOW": "999999"}

        def check(label, fault="", expected="16384", applied=False, restart=False, state="local-ready"):
            nonlocal passed
            (root / "current").write_text("8192")
            (root / "calls").write_text("")
            (root / ".crisp-ai-installation").write_text("ai-support\nstate=" + state + "\n")
            result = subprocess.run(command + [expected], env={**environment, "RAG_FIXTURE_FAULT": fault},
                                    capture_output=True, text=True, timeout=10)
            assert (result.returncode == 0) == applied, (label, result.returncode, result.stdout, result.stderr)
            calls = (root / "calls").read_text().splitlines()
            assert calls == (["recreate-anythingllm"] if restart else []), (label, calls)
            if applied:
                assert json.loads(result.stdout) == {"ok": True, "state": "applied", "context_window": int(expected)}
            else:
                assert not result.stdout.strip(), (label, result.stdout)
            assert "fixture-internal-key" not in result.stdout + result.stderr
            assert not list((root / "tmp").glob("rag-context.*"))
            passed += 1
            print("通过：[UNIT/CONTRACT] " + label, flush=True)

        check("聚合预算取启用备用，不受继承环境污染，仅重建本实例 AnythingLLM", applied=True, restart=True)
        check("无效预算在服务动作前拒绝", expected="0")
        check("与有效池或受管环境不同的预算拒绝", expected="8192")
        check("安装或恢复阶段不单独强启 RAG", state="installing")
        check("远程 Docker context 拒绝", fault="remote")
        check("非本实例容器拒绝", fault="foreign")
        check("缺少容器时不偷偷创建第二实例", fault="absent")
        check("重建失败保留非零，不宣称已应用", fault="recreate", restart=True)
        check("实际容器预算漂移不报告成功（受控时钟）", fault="container_drift", restart=True)
        check("API 预算读回漂移不报告成功（受控时钟）", fault="api_drift", restart=True)
        check("API 认证失败不报告成功（受控时钟）", fault="api_auth", restart=True)
    print(f"RAG 预算应用边界：{passed} 通过，0 失败；合成协议，不是真实组件。")


if __name__ == "__main__":
    main()
