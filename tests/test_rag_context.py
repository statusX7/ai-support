#!/usr/bin/env python3
"""RAG 配置应用边界：合成 Docker/API；不启动服务、不进行模型调用。"""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
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


def lifecycle_mock_checks():
    """单列共享生命周期桩契约；不启动真实 Docker、不进行模型调用。"""
    passed = failed = 0
    area = ROOT / ".work/v1.2.1"
    area.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix="lifecycle-rag-mock-", dir=area))
    environment = {**os.environ, "MOCK_ANYTHING_STATE": str(evidence / "anything-state.json")}
    for name in ("MOCK_DOCKER_LOG", "MOCK_FORBIDDEN_ARG_FILE", "MOCK_CHOWN_ROOT"):
        environment.pop(name, None)
    (evidence / "anything-state.json").write_text('{"documents":[]}')

    def fixture(name, port=3001, api_key=None):
        root = evidence / name
        (root / "config").mkdir(parents=True)
        (root / "tmp").mkdir()
        (root / "scripts").mkdir()
        shutil.copy2(ROOT / "scripts/provider-pool.py", root / "scripts/provider-pool.py")
        (root / "docker-compose.yml").write_text("services:\n  anythingllm: {}\n")
        (root / ".crisp-ai-installation").write_text("ai-support\nstate=staged\n")
        key = api_key or "synthetic-lifecycle-rag-key-" + name
        (root / ".env").write_text(
            "AI_API_BASE_URL=https://synthetic.invalid/v1\nAI_API_KEY=synthetic-provider-key\n"
            "AI_MODEL=synthetic-model\nAI_API_MODE=chat_completions\nAI_MODEL_TOKEN_LIMIT=8192\n"
            f"ANYTHINGLLM_API_KEY={key}\nANYTHINGLLM_PORT={port}\n")
        migrated = subprocess.run([sys.executable, str(ROOT / "scripts/provider-pool.py"),
                                   "--deploy-dir", str(root), "migrate", "--defer-runtime"],
                                  env=environment, capture_output=True, text=True, timeout=10)
        assert migrated.returncode == 0, "合成接口池初始化失败"
        return root, key

    def docker(root, *args, content="", extra=None):
        return subprocess.run([str(ROOT / "tests/mocks/docker"), "compose", "--project-directory", str(root),
                               "--env-file", str(root / ".env"), "-f", str(root / "docker-compose.yml"), *args],
                              input=content, env={**environment, **(extra or {})}, capture_output=True, text=True, timeout=10)

    def window(root, expected):
        return docker(root, "exec", "-T", "anythingllm", "node", "-e",
                      'const marker="CRISPAI_EXPECTED_RAG_CONTEXT";', content=str(expected))

    def change_window(root, value):
        file = root / ".env"
        lines = [line for line in file.read_text().splitlines() if not line.startswith("PROVIDER_RAG_CONTEXT_WINDOW=")]
        file.write_text("\n".join(lines) + f"\nPROVIDER_RAG_CONTEXT_WINDOW={value}\n")

    def api(key, port=3001, method="GET", config_mode=0o600):
        config = evidence / "api.conf"
        config.write_text('header = ' + json.dumps("Authorization: Bearer " + key) + "\n")
        config.chmod(config_mode)
        response = evidence / "response.json"
        result = subprocess.run([str(ROOT / "tests/mocks/curl"), "--config", str(config), "--request", method,
                                 "--output", str(response), "--write-out", "%{http_code}",
                                 f"http://127.0.0.1:{port}/api/v1/system"],
                                env=environment, capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, "合成 HTTP 请求执行失败"
        return result.stdout, json.loads(response.read_text())

    def capture_check():
        before = (evidence / "anything-state.json").read_bytes()
        help_result = subprocess.run([str(ROOT / "tests/mocks/docker"), "compose", "up", "--help"],
                                     env=environment, capture_output=True, text=True, timeout=10)
        assert help_result.returncode == 0, "无部署的能力查询不能当成实际 up"
        assert (evidence / "anything-state.json").read_bytes() == before
        root, _ = fixture("runtime")
        assert window(root, 8192).returncode != 0, "未启动不能冒称已有运行窗口"
        assert docker(root, "up", "-d").returncode == 0
        assert window(root, 8192).returncode == 0, "up 后原 doctor marker 必须实际读回"
        change_window(root, 16384)
        assert window(root, 16384).returncode != 0, "只改环境不能冒称容器已生效"
        assert window(root, 8192).returncode == 0
        for args in (("restart", "anythingllm"), ("up", "-d", "n8n")):
            assert docker(root, *args).returncode == 0
            assert window(root, 8192).returncode == 0, "重启或其它组件不能更新 Anything 窗口"
        assert docker(root, "up", "-d", "--no-deps", "--force-recreate", "anythingllm").returncode == 0
        assert window(root, 16384).returncode == 0
        assert window(root, 8192).returncode != 0
        assert docker(root, "exec", "-T", "anythingllm", "node", "-e",
                      'process.stdout.write(String(process.env.GENERIC_OPEN_AI_MODEL_TOKEN_LIMIT || ""))').stdout.strip() == "16384"

    def api_check():
        root, key = fixture("api", 3002)
        assert docker(root, "up", "-d").returncode == 0
        status, value = api(key, 3002)
        assert status == "200" and value.get("settings", {}).get("GenericOpenAiTokenLimit") == "8192", "API 必须返回官方 settings 结构与运行值"
        change_window(root, 32768)
        assert api(key, 3002)[1]["settings"]["GenericOpenAiTokenLimit"] == "8192"
        assert api("synthetic-wrong-key", 3002)[0] == "401"
        assert api(key, 3003)[0] == "503"
        assert api(key, 3002, "POST")[0] == "405"
        assert api(key, 3002, config_mode=0o644)[0] == "401"
        equivalent, _ = fixture("api-equivalent", 3002, key)
        assert docker(equivalent, "up", "-d").returncode == 0
        assert api(key, 3002)[0] == "503", "同端口同认证的多实例即使窗口相同也必须拒绝"
        change_window(equivalent, 16384)
        assert docker(equivalent, "up", "-d").returncode == 0
        assert api(key, 3002)[0] == "503", "同端口同认证的运行窗口冲突必须拒绝"
        assert api("synthetic-wrong-key", 3002)[0] == "401"
        assert (evidence / "anything-state.json").stat().st_mode & 0o777 == 0o600
        assert key not in (evidence / "anything-state.json").read_text(), "独立运行记录不得落盘 API Key 原文"

    def legacy_prompt_migration_check():
        state_file = evidence / "legacy-prompt-state.json"
        migration_extra = {"MOCK_ANYTHING_STATE": str(state_file)}
        owner, owner_key = fixture("legacy-prompt-owner", 3012)
        successor, successor_key = fixture("legacy-prompt-successor", 3013)
        third, _ = fixture("legacy-prompt-third", 3014)
        legacy_prompt = "旧 schema 应完整保留的 Prompt"

        def instance(project, key, port, prompt=None):
            value = {
                "context_window": 8192,
                "port": port,
                "api_key_sha256": hashlib.sha256(key.encode()).hexdigest(),
                "knowledge_model": "Xenova/all-MiniLM-L6-v2",
                "knowledge_chunk_size": 1000,
                "knowledge_chunk_overlap": 20,
                "knowledge_chunk_explicit": False,
                "documents": [],
                "removed_documents": [],
            }
            if prompt is not None:
                value["prompt"] = prompt
            return str(project), value

        def write_state(value):
            state_file.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
            state_file.chmod(0o600)

        def snapshot():
            root_info = evidence.stat()
            file_info = state_file.stat()
            return (
                root_info.st_dev, root_info.st_ino, root_info.st_mode, root_info.st_nlink,
                root_info.st_uid, root_info.st_gid, root_info.st_size,
                root_info.st_mtime_ns, root_info.st_ctime_ns,
                file_info.st_dev, file_info.st_ino, file_info.st_mode, file_info.st_nlink,
                file_info.st_uid, file_info.st_gid, file_info.st_size,
                file_info.st_mtime_ns, file_info.st_ctime_ns,
                hashlib.sha256(state_file.read_bytes()).hexdigest(),
                tuple(sorted(path.name for path in evidence.glob(".mock-anything-*"))),
            )

        write_state({"documents": [], "prompt": legacy_prompt, "rag_instances": {}})
        assert docker(owner, "up", "-d", extra=migration_extra).returncode == 0
        migrated = json.loads(state_file.read_text())
        assert "prompt" not in migrated
        assert migrated["rag_instances"][str(owner)]["prompt"] == legacy_prompt

        owner_name, owner_value = instance(owner, owner_key, 3012)
        write_state({"documents": [], "prompt": legacy_prompt,
                     "rag_instances": {owner_name: owner_value}})
        assert docker(successor, "up", "-d", extra=migration_extra).returncode == 0
        migrated = json.loads(state_file.read_text())
        assert "prompt" not in migrated
        assert migrated["rag_instances"][str(owner)]["prompt"] == legacy_prompt
        assert migrated["rag_instances"][str(successor)]["prompt"] == ""

        owner_name, owner_value = instance(owner, owner_key, 3012, legacy_prompt)
        write_state({"documents": [], "prompt": legacy_prompt,
                     "rag_instances": {owner_name: owner_value}})
        assert docker(successor, "up", "-d", extra=migration_extra).returncode == 0
        migrated = json.loads(state_file.read_text())
        assert "prompt" not in migrated
        assert migrated["rag_instances"][str(owner)]["prompt"] == legacy_prompt

        owner_name, owner_value = instance(owner, owner_key, 3012, "冲突的实例 Prompt")
        write_state({"documents": [], "prompt": legacy_prompt,
                     "rag_instances": {owner_name: owner_value}})
        before = snapshot()
        assert docker(successor, "up", "-d", extra=migration_extra).returncode != 0
        assert snapshot() == before, "冲突 legacy Prompt 必须失败且零改写"

        owner_name, owner_value = instance(owner, owner_key, 3012)
        successor_name, successor_value = instance(successor, successor_key, 3013)
        write_state({"documents": [], "prompt": legacy_prompt,
                     "rag_instances": {owner_name: owner_value,
                                       successor_name: successor_value}})
        before = snapshot()
        assert docker(third, "up", "-d", extra=migration_extra).returncode != 0
        assert snapshot() == before, "多实例 legacy Prompt 歧义必须失败且零改写"

        owner_name, owner_value = instance(owner, owner_key, 3012)
        write_state({"documents": [], "prompt": "界" * (256 * 1024 // 3 + 1),
                     "rag_instances": {owner_name: owner_value}})
        before = snapshot()
        assert docker(third, "up", "-d", extra=migration_extra).returncode != 0
        assert snapshot() == before, "超限 legacy Prompt 必须失败且零改写"

    def cache_digest_check():
        helper = ROOT / "tests/mocks/anything-cache.py"
        with tempfile.TemporaryDirectory(prefix=".test-runtime.cache-digest.", dir=ROOT) as temporary:
            scope = Path(temporary)
            primary = scope / "primary"
            secondary = scope / "secondary"
            primary.mkdir(mode=0o700)
            secondary.mkdir(mode=0o700)
            state_file = scope / "anything-state.json"
            key = "synthetic-cache-digest-primary"
            alternate_key = "synthetic-cache-digest-secondary"
            digest = hashlib.sha256(key.encode()).hexdigest()
            alternate_digest = hashlib.sha256(alternate_key.encode()).hexdigest()
            location = "custom-documents/existing.json"
            state = {"rag_instances": {
                str(primary): {"port": 3011, "api_key_sha256": digest,
                               "documents": [location], "removed_documents": [],
                               "prompt": "primary-old"},
                str(secondary): {"port": 3011, "api_key_sha256": digest,
                                 "documents": [location], "removed_documents": [],
                                 "prompt": "secondary-old"},
            }}
            state_file.write_text(json.dumps(state, sort_keys=True, separators=(",", ":")) + "\n")
            state_file.chmod(0o600)
            url = "http://127.0.0.1:3011/api/v1/workspace/crisp-support"

            def snapshot():
                values = []
                for path in [scope, *sorted(scope.rglob("*"))]:
                    metadata = path.lstat()
                    content = hashlib.sha256(path.read_bytes()).hexdigest() \
                        if path.is_file() and not path.is_symlink() else ""
                    values.append((str(path.relative_to(scope)), metadata.st_dev, metadata.st_ino,
                                   metadata.st_mode, metadata.st_nlink, metadata.st_uid,
                                   metadata.st_gid, metadata.st_size, metadata.st_mtime_ns,
                                   metadata.st_ctime_ns, content))
                return values

            def invoke(action, reference, *arguments, input_text=None):
                return subprocess.run([sys.executable, str(helper), action, str(state_file),
                                       str(scope), url, reference, *arguments],
                                      input=input_text, capture_output=True, text=True, timeout=10)

            baseline = snapshot()
            assert invoke("observe", "sha256:not-a-valid-digest").returncode != 0
            assert snapshot() == baseline, "畸形摘要不得改写状态或缓存"
            for action, arguments in (("observe", ()),
                                      ("workspace-observe", ()),
                                      ("update", ('["custom-documents/new.json"]', "[]")),
                                      ("remove", ('["custom-documents/existing.json"]',))):
                assert invoke(action, "sha256:" + digest, *arguments).returncode != 0
                assert snapshot() == baseline, "同端口同摘要歧义不得改写任何实例"
            assert invoke("prompt-write", "sha256:" + digest,
                          input_text=json.dumps("不得写入的歧义 Prompt")).returncode != 0
            assert snapshot() == baseline, "Prompt 歧义不得改写任何实例"

            state["rag_instances"][str(secondary)]["api_key_sha256"] = alternate_digest
            state["rag_instances"][str(secondary)]["documents"] = []
            state_file.write_text(json.dumps(state, sort_keys=True, separators=(",", ":")) + "\n")
            state_file.chmod(0o600)
            unique_baseline = snapshot()
            for invalid_prompt in (json.dumps(""),
                                   json.dumps("x" * (256 * 1024 + 1)),
                                   "x" * (2 * 1024 * 1024 + 1)):
                assert invoke("prompt-write", "sha256:" + alternate_digest,
                              input_text=invalid_prompt).returncode != 0
                assert snapshot() == unique_baseline, \
                    "空值、解码后超限或输入封套超限的 Prompt 必须零改写"
            added = "custom-documents/unique.json"
            expected_after_update = json.loads(json.dumps(state))
            expected_after_update["rag_instances"][str(secondary)]["documents"] = [added]
            state_identity = state_file.stat()
            result = invoke("update", "sha256:" + alternate_digest,
                            json.dumps([added], separators=(",", ":")), "[]")
            assert result.returncode == 0, "同端口不同摘要应唯一修改目标实例"
            updated = json.loads(state_file.read_text())
            assert updated == expected_after_update, "摘要写入只能修改目标实例的指定字段"
            replaced_identity = state_file.stat()
            assert (replaced_identity.st_dev, replaced_identity.st_ino) != \
                   (state_identity.st_dev, state_identity.st_ino), "状态必须原子替换"
            assert replaced_identity.st_nlink == 1 \
                   and (replaced_identity.st_mode & 0o777) == 0o600 \
                   and replaced_identity.st_uid == os.geteuid()
            assert not list(scope.glob(".mock-state-*.tmp")), "原子状态不得遗留临时文件"

            expected = json.loads(json.dumps(expected_after_update))
            expected["rag_instances"][str(primary)]["prompt"] = "primary-new"
            expected["rag_instances"][str(secondary)]["prompt"] = "secondary-new"
            assert invoke("prompt-write", "sha256:" + digest,
                          input_text=json.dumps("primary-new")).returncode == 0
            assert invoke("prompt-write", "sha256:" + alternate_digest,
                          input_text=json.dumps("secondary-new")).returncode == 0
            final_state = json.loads(state_file.read_text())
            assert final_state == expected, "不同摘要的 Prompt 只能写入各自实例"
            primary_view = invoke("workspace-observe", "sha256:" + digest)
            secondary_view = invoke("workspace-observe", "sha256:" + alternate_digest)
            assert primary_view.returncode == secondary_view.returncode == 0
            assert json.loads(primary_view.stdout) == {"documents": [location], "prompt": "primary-new"}
            assert json.loads(secondary_view.stdout) == {"documents": [added], "prompt": "secondary-new"}

    def status_check():
        root, _ = fixture("status", 3004)
        assert docker(root, "up", "-d").returncode == 0
        args = ("exec", "-T", "anythingllm", "node", "-e", 'fetch("http://provider-adapter:8787/internal/provider/status")')
        result = docker(root, *args)
        assert result.returncode == 0
        value = json.loads(result.stdout)
        pool = json.loads((root / "config/provider-pool-applied.json").read_text())
        assert value.get("ok") is True and value.get("configuration_state") == "applied", "status 必须按真实 adapter 返回应用状态"
        assert value["revision"] == pool["revision"]
        assert value["entries"][0]["health"] == "unknown", "桩不能假造上游健康"
        assert value["entries"][0]["vision_health"] in ("unknown", "disabled")
        assert "base_url" not in value["entries"][0]
        marker = root / "config/provider-pool-transaction.json"
        marker.write_text("synthetic-unreadable-body")
        marker.chmod(0o600)
        assert json.loads(docker(root, *args).stdout)["configuration_state"] == "applying"
        marker.unlink()
        marker.symlink_to(root / "absent")
        assert json.loads(docker(root, *args).stdout)["configuration_state"] == "applying"
        marker.unlink()
        active = root / "config/provider-pool-applied.json"
        active.write_text("invalid-json")
        assert docker(root, *args).returncode != 0, "损坏池不能返回 applied"

    for label, action in (("生命周期桩仅由 Anything up/recreate更新独立运行窗口", capture_check),
                          ("生命周期 API/system 鉴权、运行值与实例隔离", api_check),
                          ("生命周期旧 Prompt 唯一迁移且歧义零改写", legacy_prompt_migration_check),
                          ("生命周期缓存摘要唯一绑定且歧义零改写", cache_digest_check),
                          ("生命周期 adapter状态匹配真实schema，未知不假绿、pending不冒applied", status_check)):
        try:
            action()
            passed += 1
            print("通过：[UNIT/CONTRACT] " + label, flush=True)
        except (AssertionError, KeyError, OSError, ValueError, subprocess.SubprocessError) as error:
            failed += 1
            print("失败：[UNIT/CONTRACT] " + label + "：" + str(error), flush=True)
    print(f"生命周期桩独立子组：{passed} 通过，{failed} 失败；合成证据 {evidence.relative_to(ROOT)}。")
    return failed


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
    if lifecycle_mock_checks():
        raise SystemExit(1)


if __name__ == "__main__":
    main()
