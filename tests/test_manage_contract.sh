#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
command -v python3 >/dev/null 2>&1 || { printf '失败：管理入口测试需要 Python 3 PTY 驱动。\n' >&2; exit 1; }
exec python3 "${SCRIPT_DIR}/test_manage_ui.py"
