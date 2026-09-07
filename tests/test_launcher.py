#!/usr/bin/env python3
"""受管命令和兼容入口的权限、归属及生命周期回归。"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def invoke(command, *, env=None, cwd="/", content=None):
    return subprocess.run(command, env=env, cwd=cwd, input=content, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)


def main():
    if os.geteuid() != 0:
        print("跳过：受管命令生命周期专项需要 root 测试权限。")
        return
    with tempfile.TemporaryDirectory(prefix="crispai-launcher-test-") as temporary:
        base = Path(temporary)
        base.chmod(0o755)
        deploy = base / "managed ' instance"
        deploy.mkdir(mode=0o700)
        (deploy / "config").mkdir()
        (deploy / ".crisp-ai-installation").write_text("ai-support\nstate=local-ready\n")
        (deploy / "VERSION").write_text("v1.1.1\n")
        (deploy / ".env").write_text("AI_API_KEY=synthetic-launcher-secret\n")
        (deploy / "manage.sh").write_text("#!/usr/bin/env bash\nset -euo pipefail\nprintf '%s\\n' \"$@\"\n")
        directory = base / "bin"
        directory.mkdir(mode=0o755)
        launcher = directory / "crispai"
        alias = directory / "crisp"
        install = ["bash", str(ROOT / "scripts/launcher.sh"), "install", "--deploy-dir", str(deploy), "--command-path", str(launcher), "--non-interactive"]
        remove = ["bash", str(ROOT / "scripts/launcher.sh"), "remove", "--deploy-dir", str(deploy)]
        environment = {**os.environ, "PATH": str(directory) + ":/usr/bin:/bin"}
        result = invoke(install, env=environment)
        assert result.returncode == 0, result.stdout
        assert alias.is_file() and not alias.is_symlink(), "正式入口安装后缺少受管 crisp 兼容命令"
        first = (launcher.read_bytes(), alias.read_bytes())
        assert invoke(install, env=environment).returncode == 0
        assert first == (launcher.read_bytes(), alias.read_bytes()), "重复安装没有保持幂等"
        for command in (launcher, alias):
            assert "synthetic-launcher-secret" not in command.read_text()
            assert invoke([str(command), "--version"], env=environment).stdout.strip() == "v1.1.1"
            assert invoke([str(command), "--help"], env=environment).returncode == 0
            result = invoke([str(command), "status", "quoted ' argument"], env=environment, cwd="/tmp")
            assert result.returncode == 0 and result.stdout.splitlines() == ["--deploy-dir", str(deploy), "status", "quoted ' argument"], result.stdout
        print("通过：crispai 与 crisp 从陌生 cwd 透传参数，幂等且不含秘密")
        launcher.write_text("#!/usr/bin/env bash\nprintf 'foreign official command\\n'\n")
        assert invoke([str(alias), "status"], env=environment).returncode != 0, "兼容入口执行了归属已改变的正式入口"
        launcher.write_bytes(first[0])
        if shutil.which("setpriv"):
            for command in (launcher, alias):
                result = invoke(["setpriv", "--reuid=65534", "--regid=65534", "--clear-groups", str(command), "--version"], env=environment)
                assert result.returncode == 0 and result.stdout.strip() == "v1.1.1", result.stdout
            (directory / "sudo").write_text("#!/usr/bin/env bash\nset -euo pipefail\nif [[ \"${1:-}\" == -n && \"${2:-}\" == true ]]; then exit 0; fi\nprintf '%s\\n' \"$@\"\n")
            (directory / "sudo").chmod(0o755)
            result = invoke(["setpriv", "--reuid=65534", "--regid=65534", "--clear-groups", str(alias), "status"], env=environment)
            assert result.returncode == 0 and str(launcher) in result.stdout and "status" in result.stdout, result.stdout
            print("通过：普通用户无需读取私有部署即可查看帮助/版本并受控委托 sudo")
        assert invoke(remove, env=environment).returncode == 0
        assert not launcher.exists() and not alias.exists(), "卸载未同时移除本实例的受管命令"
        assert invoke(install, env=environment).returncode == 0
        alias.write_text("#!/usr/bin/env bash\nprintf 'foreign command\\n'\n")
        saved = alias.read_bytes()
        assert invoke(install, env=environment).returncode == 0
        assert alias.read_bytes() == saved, "覆盖了其他程序的 crisp 命令"
        assert invoke(remove, env=environment).returncode == 0
        assert alias.read_bytes() == saved, "卸载删除了其他程序的 crisp 命令"
        alias.unlink()
        sentinel = base / "sentinel"
        sentinel.write_text("foreign\n")
        alias.symlink_to(sentinel)
        assert invoke(install, env=environment).returncode == 0
        assert alias.is_symlink() and sentinel.read_text() == "foreign\n"
        assert invoke(remove, env=environment).returncode == 0 and alias.is_symlink()
        alias.unlink()
        print("通过：移除/重建仅管理本实例文件，保留外来命令和符号链接")
        other = base / "other-bin"
        other.mkdir()
        (other / "crisp").write_text("#!/usr/bin/env bash\nprintf 'other path\\n'\n")
        (other / "crisp").chmod(0o755)
        foreign_env = {**environment, "PATH": str(directory) + ":" + str(other) + ":/usr/bin:/bin"}
        assert invoke(install, env=foreign_env).returncode == 0
        assert not alias.exists(), "新兼容入口遮蔽了其他 PATH 位置的外来命令"
        assert invoke(remove, env=foreign_env).returncode == 0
        print("通过：不遮蔽 PATH 中已有的外来 crisp 命令")
    print("受管命令专项测试通过。")


if __name__ == "__main__":
    main()
