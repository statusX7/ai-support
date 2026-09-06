#!/usr/bin/env python3
"""在提取本机快照之前检查成员、类型和资源上限，不执行归档内容。"""
import argparse
import posixpath
import sys
import tarfile


def validate(path, kind, max_bytes):
    seen, total = set(), 0
    root_files = {"VERSION", "CHANGELOG.md", "README.md", "LICENSE", "AGENTS.md",
                  ".env", ".env.example", "docker-compose.yml", "install.sh",
                  "manage.sh", "update.sh", "uninstall.sh"}
    with tarfile.open(path, "r:gz") as archive:
        for member in archive:
            raw = member.name
            name = raw.removeprefix("./").rstrip("/")
            if (not name or name == ".") and member.isdir():
                continue
            if (raw.startswith("/") or "\\" in raw or any(ord(c) < 32 for c in raw)
                    or any(p in ("", ".", "..") for p in name.split("/"))
                    or posixpath.normpath(name) != name):
                raise ValueError("归档包含路径穿越或不安全路径")
            if name in seen:
                raise ValueError("归档包含重复成员")
            seen.add(name)
            if not (member.isfile() or member.isdir()):
                raise ValueError("归档包含链接或特殊文件")
            if len(seen) > 100000:
                raise ValueError("归档成员数量超过 100000")
            total += member.size
            if member.size < 0 or total > max_bytes:
                raise ValueError("归档解压总容量超过安全上限")
            if kind == "full":
                allowed = name in ("manifest.json", "snapshot.tar.gz") and member.isfile()
            else:
                parts = name.split("/")
                allowed = name == "payload" or (len(parts) == 2 and parts[0] == "payload" and parts[1] in root_files)
                if len(parts) >= 2 and parts[0] == "payload":
                    section = parts[1]
                    if section in ("config", "knowledge", "n8n", "scripts", "docs"):
                        # 快照只在本机可信恢复场景使用，迁移包另有不允许可执行文件的契约。
                        allowed = True
                    if section == "data":
                        allowed = len(parts) == 2 or parts[2] in ("anythingllm", "n8n", "runtime", "postgres", "knowledge-manifest.json")
                        if len(parts) >= 3 and parts[2] == "postgres":
                            allowed = len(parts) == 3 or (len(parts) == 4 and parts[3] == "n8n.dump")
            if not allowed:
                raise ValueError("归档包含未授权路径")
        if kind == "full" and seen != {"manifest.json", "snapshot.tar.gz"}:
            raise ValueError("完整备份必须且只能含 manifest.json 与 snapshot.tar.gz")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive")
    parser.add_argument("--kind", choices=("snapshot", "full"), required=True)
    parser.add_argument("--max-bytes", type=int, default=50 * 1024**3)
    args = parser.parse_args()
    try:
        validate(args.archive, args.kind, args.max_bytes)
    except (OSError, ValueError, tarfile.TarError) as error:
        print("错误：归档校验失败：" + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
