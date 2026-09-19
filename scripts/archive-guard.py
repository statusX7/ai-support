#!/usr/bin/env python3
"""在提取本机快照之前检查成员、类型和资源上限，不执行归档内容。"""
import argparse
import posixpath
import re
import sys
import tarfile


def validate(path, kind, max_bytes):
    seen, total = set(), 0
    root_files = {"VERSION", "CHANGELOG.md", "README.md", "LICENSE", "AGENTS.md",
                  ".env", ".env.example", "docker-compose.yml", "get.sh", "install.sh",
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
            elif kind == "materials":
                parts = name.split("/")
                allowed = name in ("config", "knowledge") and member.isdir()
                if len(parts) == 2 and parts[0] == "config":
                    allowed = member.isfile() and parts[1] in {
                        "runtime.yaml", "handoff.yaml", "keyword.yaml", "menu.yaml",
                        "tags.yaml", "feedback.yaml", "prompt.md",
                    }
                if name == "knowledge/catalog.json":
                    allowed = member.isfile()
                if len(parts) in (2, 3) and parts[0] == "knowledge" \
                        and re.fullmatch(r"kb_(?:default|[a-f0-9]{16})", parts[1]):
                    allowed = member.isdir() and (len(parts) == 2 or parts[2] == "sources")
                if len(parts) == 4 and parts[0] == "knowledge" \
                        and re.fullmatch(r"kb_(?:default|[a-f0-9]{16})", parts[1]) \
                        and parts[2] == "sources":
                    allowed = member.isfile() and re.fullmatch(
                        r"doc_[a-f0-9]{16}\.(?:md|txt|pdf|docx)", parts[3]) is not None
            else:
                parts = name.split("/")
                allowed = name == "payload" or (len(parts) == 2 and parts[0] == "payload" and parts[1] in root_files)
                if len(parts) >= 2 and parts[0] == "payload":
                    section = parts[1]
                    if section in ("config", "knowledge", "n8n", "scripts", "docs"):
                        # 快照只在本机可信恢复场景使用，迁移包另有不允许可执行文件的契约。
                        allowed = True
                    if section == "backups":
                        allowed = len(parts) in (2, 3) and (len(parts) == 2 or parts[2] == "config-history")
                        if len(parts) == 4:
                            allowed = parts[2] == "config-history" and parts[3] == "materials.applied.tar.gz" \
                                and member.isfile()
                    if section == "secrets":
                        allowed = len(parts) == 2 or parts[2] == "provider"
                    if section == "data":
                        allowed = len(parts) == 2 or parts[2] in ("anythingllm", "n8n", "runtime", "provider-router", "postgres", "knowledge-manifest.json")
                        if len(parts) == 3 and parts[2] == "knowledge-projection.json" and member.isfile():
                            allowed = True
                        if len(parts) >= 3 and parts[2] == "postgres":
                            allowed = len(parts) == 3 or (len(parts) == 4 and parts[3] == "n8n.dump")
            if not allowed:
                raise ValueError("归档包含未授权路径")
        if kind == "full" and seen != {"manifest.json", "snapshot.tar.gz"}:
            raise ValueError("完整备份必须且只能含 manifest.json 与 snapshot.tar.gz")
        if kind == "materials":
            required = {"config", "knowledge", "knowledge/catalog.json", "config/prompt.md"}
            required.update({f"config/{name}.yaml" for name in (
                "runtime", "handoff", "keyword", "menu", "tags", "feedback")})
            if not required.issubset(seen):
                raise ValueError("资料包缺少固定配置、Prompt 或知识目录")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive")
    parser.add_argument("--kind", choices=("snapshot", "full", "materials"), required=True)
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
