#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if ! command -v node >/dev/null 2>&1; then
  printf '跳过：未安装开发测试依赖 Node.js。\n' >&2
  exit 77
fi
exec node "${SCRIPT_DIR}/workflow-runtime.test.js"
