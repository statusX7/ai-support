#!/usr/bin/env python3
"""校验并安全提取由测试编排器提供的 v1.1.0 源码归档。"""

import argparse
import hashlib
import hmac
import os
from pathlib import Path
import posixpath
import shutil
import stat
import sys
import tarfile
import tempfile


MAX_ARCHIVE_BYTES = 128 * 1024 * 1024
MAX_EXPANDED_BYTES = 512 * 1024 * 1024
MAX_MEMBERS = 10_000


def safe_name(raw):
    name = raw.rstrip("/")
    if not name or name.startswith("/") or "\\" in name:
        raise ValueError("归档包含不安全路径")
    if any(ord(character) < 32 for character in name):
        raise ValueError("归档包含控制字符")
    parts = name.split("/")
    if any(part in ("", ".", "..") for part in parts) or posixpath.normpath(name) != name:
        raise ValueError("归档包含路径穿越")
    return parts, name


def verified_copy(archive_path, expected_sha256, destination_parent):
    if not hasattr(os, "O_NOFOLLOW"):
        raise ValueError("当前系统缺少安全打开归档所需的 O_NOFOLLOW")
    flags = os.O_RDONLY | os.O_NOFOLLOW
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    descriptor = os.open(archive_path, flags)
    source = os.fdopen(descriptor, "rb")
    try:
        archive_stat = os.fstat(source.fileno())
        if not stat.S_ISREG(archive_stat.st_mode) or archive_stat.st_size <= 0 \
                or archive_stat.st_size > MAX_ARCHIVE_BYTES:
            raise ValueError("受控旧版归档不是安全的普通文件或大小超限")
        if archive_stat.st_uid != os.geteuid() or stat.S_IMODE(archive_stat.st_mode) != 0o600:
            raise ValueError("受控旧版归档必须由当前身份持有且权限为 0600")
        result = hashlib.sha256()
        remaining = archive_stat.st_size
        verified = tempfile.TemporaryFile(mode="w+b", dir=destination_parent)
        try:
            while remaining:
                chunk = source.read(min(1024 * 1024, remaining))
                if not chunk:
                    raise ValueError("受控旧版归档在校验期间被截断")
                result.update(chunk)
                verified.write(chunk)
                remaining -= len(chunk)
            if source.read(1):
                raise ValueError("受控旧版归档在校验期间大小发生变化")
            if not hmac.compare_digest(result.hexdigest(), expected_sha256):
                raise ValueError("受控旧版归档 SHA256 不匹配")
            verified.flush()
            verified.seek(0)
            return verified
        except Exception:
            verified.close()
            raise
    finally:
        source.close()


def extract(archive_path, expected_sha256, destination):
    if not archive_path.is_absolute():
        raise ValueError("受控旧版归档必须使用绝对路径")
    if not destination.is_absolute():
        raise ValueError("旧版源码目标目录必须使用绝对路径")
    parent_stat = archive_path.parent.lstat()
    if not stat.S_ISDIR(parent_stat.st_mode) or stat.S_ISLNK(parent_stat.st_mode) \
            or parent_stat.st_uid != os.geteuid() or stat.S_IMODE(parent_stat.st_mode) != 0o700:
        raise ValueError("受控旧版归档父目录必须由当前身份持有且权限为 0700")
    destination_stat = destination.lstat()
    if not stat.S_ISDIR(destination_stat.st_mode) or any(destination.iterdir()):
        raise ValueError("旧版源码目标目录必须是空的普通目录")

    seen = set()
    expanded = 0
    with verified_copy(archive_path, expected_sha256, destination.parent) as verified:
        with tarfile.open(fileobj=verified, mode="r:*") as source:
            for member in source:
                parts, name = safe_name(member.name)
                if name in seen:
                    raise ValueError("归档包含重复成员")
                seen.add(name)
                if len(seen) > MAX_MEMBERS:
                    raise ValueError("归档成员数量超限")
                if not (member.isdir() or member.isfile()):
                    raise ValueError("归档包含链接或特殊文件")
                expanded += member.size
                if member.size < 0 or expanded > MAX_EXPANDED_BYTES:
                    raise ValueError("归档展开大小超限")
                target = destination.joinpath(*parts)
                if member.isdir():
                    if target.exists() and not target.is_dir():
                        raise ValueError("归档目录与文件冲突")
                    target.mkdir(parents=True, exist_ok=True, mode=0o755)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
                if target.exists() or target.is_symlink():
                    raise ValueError("归档文件与已有路径冲突")
                stream = source.extractfile(member)
                if stream is None:
                    raise ValueError("归档普通文件无法读取")
                with target.open("xb") as output:
                    shutil.copyfileobj(stream, output, length=1024 * 1024)
                if target.stat().st_size != member.size:
                    raise ValueError("归档成员长度不匹配")
                os.chmod(target, 0o755 if member.mode & 0o111 else 0o644)

    required = ("VERSION", "install.sh", "manage.sh", "scripts/common.sh")
    for relative in required:
        target = destination / relative
        if not target.is_file() or target.is_symlink():
            raise ValueError("旧版源码缺少必要普通文件")
    if (destination / "VERSION").read_text(encoding="utf-8").strip() != "v1.1.0":
        raise ValueError("旧版源码 VERSION 不是 v1.1.0")
    for relative in ("get.sh", "scripts/doctor.sh", "scripts/visitor-output.js"):
        target = destination / relative
        if target.exists() or target.is_symlink():
            raise ValueError("旧版源码混入后续版本模块")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--destination", required=True)
    arguments = parser.parse_args()
    if len(arguments.sha256) != 64 or any(character not in "0123456789abcdef" for character in arguments.sha256):
        print("错误：受控旧版归档 SHA256 格式无效", file=sys.stderr)
        return 1
    try:
        extract(Path(arguments.archive), arguments.sha256, Path(arguments.destination))
    except (OSError, UnicodeError, ValueError, tarfile.TarError) as error:
        print("错误：旧版测试源码归档校验失败：" + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
