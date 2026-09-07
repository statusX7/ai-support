#!/usr/bin/env python3
"""独立核对活跃文档与只读生产入口；不执行在线安装或外部验收。"""

import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
ACTIVE = [ROOT / "README.md"] + [
    ROOT / "docs" / f"{name}.md"
    for name in (
        "INSTALL", "CRISP", "CONFIG", "MENU", "TROUBLESHOOTING", "SECURITY",
        "TESTING", "ARCHITECTURE", "RELEASE", "ADVANCED",
    )
]
COMMAND_DIGEST = "115ac2c7160e763db4a9340273311a8ccdf3137eb28d8ceac4666ac57663f4ad"


def invoke(arguments, *, cwd, env=None, input_text=None):
    result = subprocess.run(
        arguments, cwd=cwd, env=env, input=input_text, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30, check=False,
    )
    assert result.returncode == 0, (arguments, result.returncode, result.stdout)
    return result.stdout


def passing(message):
    print(f"通过：[DOCS/CONTRACT] {message}", flush=True)


def main():
    documents = {path: path.read_text(encoding="utf-8") for path in ACTIVE}
    for path, content in documents.items():
        assert "\x00" not in content, path
        assert len(content.splitlines()) <= 320, f"菜单文档查看上限之外：{path}"
        for target in re.findall(r"\[[^\]\n]+\]\(([^)\n]+)\)", content):
            parsed = urlsplit(target.strip("<>"))
            if parsed.scheme or not parsed.path:
                continue
            destination = (path.parent / unquote(parsed.path)).resolve()
            assert destination.is_relative_to(ROOT), (path, target)
            assert destination.is_file(), f"失效的本地文档链接：{path.name} → {target}"
    passing("11 份活跃文档 UTF-8、本地链接及菜单 320 行可读边界")

    version = (ROOT / "VERSION").read_text().strip()
    for path in (ROOT / "README.md", ROOT / "docs/INSTALL.md", ROOT / f"docs/releases/{version}.md"):
        content = path.read_text(encoding="utf-8")
        marker = "<!-- CRISPAI_RECOMMENDED_INSTALL_COMMAND -->"
        assert content.count(marker) == 1, path
        match = re.search(re.escape(marker) + r"\s*```bash\n([^\n]+)\n```", content)
        assert match, path
        command = match.group(1).encode()
        assert len(command) == 1779 and hashlib.sha256(command).hexdigest() == COMMAND_DIGEST, path
    passing("README、INSTALL、当前 Release 推荐命令逐字相同且保留已实测原样")

    count = 0
    for path, content in documents.items():
        for block in re.findall(r"```bash[ \t]*\n(.*?)\n```", content, re.S):
            invoke(["bash", "-n"], cwd=ROOT, input_text=block)
            count += 1
    passing(f"{count} 段 Bash 示例仅做语法检查，没有执行安装、下载或管理操作")

    with tempfile.TemporaryDirectory(prefix="crispai-docs-") as temporary:
        fixture = Path(temporary)
        foreign = fixture / "陌生 目录"
        foreign.mkdir()
        binary = fixture / "bin"
        binary.mkdir()
        forbidden_log = fixture / "forbidden-calls"
        stub = (
            "#!/usr/bin/env python3\n"
            "import os\nfrom pathlib import Path\n"
            "Path(os.environ['CRISPAI_DOCS_FORBIDDEN_LOG']).write_text('发生禁止的副作用')\n"
            "raise SystemExit(99)\n"
        )
        for name in ("docker", "curl", "wget", "sudo", "apt-get", "apt", "systemctl"):
            target = binary / name
            target.write_text(stub, encoding="utf-8")
            target.chmod(0o700)
        environment = dict(os.environ)
        environment["PATH"] = f"{binary}:{environment.get('PATH', '/usr/bin:/bin')}"
        environment["CRISPAI_DOCS_FORBIDDEN_LOG"] = str(forbidden_log)
        help_outputs = {}
        for name in (
            "get.sh", "install.sh", "manage.sh", "update.sh", "uninstall.sh",
            "scripts/doctor.sh", "scripts/logs.sh", "scripts/materials.sh", "scripts/launcher.sh",
        ):
            help_outputs[name] = invoke(["bash", str(ROOT / name), "--help"], cwd=foreign, env=environment)
            assert "用法：" in help_outputs[name], name
        for name in ("get.sh", "install.sh", "manage.sh", "update.sh", "scripts/doctor.sh", "scripts/logs.sh"):
            output = invoke(["bash", str(ROOT / name), "--version"], cwd=foreign, env=environment)
            assert output.strip() == version, (name, output, version)
        assert not forbidden_log.exists(), "帮助或版本发生网络、提权、依赖安装或服务副作用"
        for flag in ("--check", "--force-external"):
            assert flag in help_outputs["manage.sh"] and flag in documents[ROOT / "docs/CONFIG.md"]
        assert "--force-external" in help_outputs["scripts/materials.sh"]
        assert "--repair" in help_outputs["get.sh"] and "--repair" in documents[ROOT / "docs/TROUBLESHOOTING.md"]
        for action in ("status", "show", "follow", "clear", "rotate", "cleanup", "configure", "export"):
            assert action in help_outputs["scripts/logs.sh"], action
        titles = invoke(
            ["bash", "-c", 'source "$1"; printf "%s\\0" "${MENU_TITLES[@]}"', "_", str(ROOT / "scripts/menu-ui.sh")],
            cwd=foreign, env=environment,
        ).rstrip("\x00").split("\x00")
        assert len(titles) == 18
        for number, title in enumerate(titles, start=1):
            assert f"## {number}. {title}\n" in documents[ROOT / "docs/MENU.md"], (number, title)
    passing("陌生中文/空格 cwd 下 9 个生产帮助、6 个版本及 apply/logs/repair 文档接线，无外部副作用")
    passing("生产菜单真实加载的 18 项标题与操作文档逐项一致")

    config = documents[ROOT / "docs/CONFIG.md"]
    materials = (ROOT / "scripts/materials.sh").read_text()
    for identifier, maximum in (("PROMPT", 262144), ("DOCUMENT", 52428800), ("CATALOG", 536870912), ("PROJECTION", 16777216)):
        assert f"MATERIALS_{identifier}_MAX_BYTES={maximum}" in materials
    assert "262144" in config and "52428800" in config
    assert "每节点最多 12 个选项" in config and "向下跳转 8 次" in config
    validation = (ROOT / "scripts/configuration.sh").read_text()
    assert "$depth > 8" in validation and ".options | type == \"object\" and length <= 12" in validation
    for directive in (
        "request>uri replace [REDACTED]", "request>headers>Authorization delete", "request>headers>Cookie delete",
    ):
        assert directive in (ROOT / "config/Caddyfile.example").read_text()
        assert directive in documents[ROOT / "docs/CRISP.md"]
    passing("Prompt/文档字节、菜单边界及 Caddy 错误日志过滤的源码/文档一致性")
    print("独立文档验收：6 组通过；不代表最终包匿名实装、真实容器或真实 Crisp E2E。")


if __name__ == "__main__":
    main()
