#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

fail() {
  printf '失败：%s\n' "$1" >&2
  exit 1
}

command -v git >/dev/null 2>&1 || fail "缺少命令 git"
git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || fail "项目目录不是 Git 工作区"

for ignored_path in \
  .env \
  config/provider.yaml \
  config/runtime.yaml \
  config/prompt.md \
  data/runtime.db \
  logs/runtime.log \
  backups/backup.tar.gz \
  knowledge/customer-private.pdf \
  .crisp-ai-installation; do
  git -C "$PROJECT_ROOT" check-ignore -q -- "$ignored_path" \
    || fail "敏感或运行时路径未被 .gitignore 排除：$ignored_path"
done
for public_path in .env.example knowledge/README.md; do
  if git -C "$PROJECT_ROOT" check-ignore -q -- "$public_path"; then
    fail "公开模板或目录说明被错误忽略：$public_path"
  fi
done

mapfile -t tracked_files < <(git -C "$PROJECT_ROOT" ls-files)
for tracked in "${tracked_files[@]}"; do
  case "$tracked" in
    .env|.env.*)
      [[ "$tracked" == ".env.example" ]] || fail "Git 已跟踪真实环境文件：$tracked"
      ;;
    config/provider.yaml|config/prompt.md|config/keyword.yaml|config/menu.yaml|config/handoff.yaml|config/tags.yaml|config/feedback.yaml|config/runtime.yaml)
      fail "Git 已跟踪真实配置：$tracked"
      ;;
    knowledge/*)
      [[ "$tracked" == "knowledge/README.md" ]] || fail "Git 已跟踪知识库内容：$tracked"
      ;;
    data/*|logs/*|backups/*|tmp/*|.crisp-ai-installation|*.pem|*.key|*.secret)
      fail "Git 已跟踪敏感或运行时文件：$tracked"
      ;;
  esac
done

SECRET_PATTERN='AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----'
WORKTREE_MATCHES=$(git -C "$PROJECT_ROOT" grep -IlE "$SECRET_PATTERN" -- . 2>/dev/null || true)
[[ -z "$WORKTREE_MATCHES" ]] || fail "当前受 Git 跟踪内容疑似包含真实密钥；请在本地检查命中文件并轮换密钥"

while IFS= read -r -d '' untracked; do
  [[ -f "${PROJECT_ROOT}/${untracked}" && ! -L "${PROJECT_ROOT}/${untracked}" ]] || continue
  if grep -IlEq "$SECRET_PATTERN" "${PROJECT_ROOT}/${untracked}"; then
    fail "未跟踪且未忽略的项目文件疑似包含真实密钥；请在本地检查并轮换密钥"
  fi
done < <(git -C "$PROJECT_ROOT" ls-files --others --exclude-standard -z)

while IFS= read -r revision; do
  [[ -n "$revision" ]] || continue
  HISTORY_MATCHES=$(git -C "$PROJECT_ROOT" grep -IlE "$SECRET_PATTERN" "$revision" -- . 2>/dev/null || true)
  [[ -z "$HISTORY_MATCHES" ]] \
    || fail "Git 历史疑似包含真实密钥；请执行历史清理并轮换密钥"
done < <(git -C "$PROJECT_ROOT" rev-list --all)

if grep -Eiq -- '(^|[[:space:]])(--header|-H)(=|[[:space:]])[^#]*(Authorization|Bearer)[[:space:]:]' \
  "${PROJECT_ROOT}"/*.sh "${PROJECT_ROOT}"/scripts/*.sh; then
  fail "Shell 脚本不得把 Authorization 值直接放入 curl 命令行参数"
fi
if grep -Eq -- '(curl[^#]*[[:space:]](--user|-u)(=|[[:space:]])|^[[:space:]]*(--user|-u)(=|[[:space:]]))' \
  "${PROJECT_ROOT}"/*.sh "${PROJECT_ROOT}"/scripts/*.sh; then
  fail "Shell 脚本不得把认证信息放入 curl --user 命令行参数"
fi

printf 'Git 忽略规则与密钥扫描：通过\n'
