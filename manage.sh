#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/scripts/common.sh"

DEPLOY_REQUEST=""
if (( $# > 0 )); then
  if [[ "$1" == "--deploy-dir" && $# -eq 2 ]]; then
    DEPLOY_REQUEST=$2
  else
    die "用法：./manage.sh [--deploy-dir PATH]"
  fi
fi
DEPLOY_DIR=$(resolve_deploy_dir "$DEPLOY_REQUEST")

require_installation() {
  assert_installation "$DEPLOY_DIR"
}

pause_screen() {
  printf '\n按 Enter 返回菜单...'
  IFS= read -r _
}

recreate_ai_services() {
  require_docker_runtime
  docker_compose "$DEPLOY_DIR" config --quiet
  docker_compose "$DEPLOY_DIR" up -d --force-recreate anythingllm n8n
}

configure_anythingllm() {
  local key workspace port status payload
  printf 'AnythingLLM Developer API Key（输入内容不会显示）：'
  IFS= read -r -s key
  printf '\n工作区 slug [%s]：' "$(env_get "${DEPLOY_DIR}/.env" ANYTHINGLLM_WORKSPACE 2>/dev/null || printf 'crisp-support')"
  IFS= read -r workspace
  workspace=${workspace:-$(env_get "${DEPLOY_DIR}/.env" ANYTHINGLLM_WORKSPACE 2>/dev/null || printf 'crisp-support')}
  validate_env_value "$key" || die "AnythingLLM API Key 无效"
  [[ "$workspace" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || die "工作区 slug 只能包含字母、数字、下划线或连字符"
  env_set "${DEPLOY_DIR}/.env" ANYTHINGLLM_API_KEY "$key"
  env_set "${DEPLOY_DIR}/.env" ANYTHINGLLM_WORKSPACE "$workspace"

  port=$(env_get "${DEPLOY_DIR}/.env" ANYTHINGLLM_PORT 2>/dev/null || printf '3001')
  status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 5 --max-time 20 --header "Authorization: Bearer ${key}" \
    "http://127.0.0.1:${port}/api/v1/workspace/${workspace}" 2>/dev/null || true)
  if [[ "$status" == "404" ]]; then
    payload=$(jq -cn --arg name "$workspace" --arg slug "$workspace" '{name:$name,slug:$slug}')
    status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
      --connect-timeout 5 --max-time 30 --header "Authorization: Bearer ${key}" \
      --header 'Content-Type: application/json' --data "$payload" \
      "http://127.0.0.1:${port}/api/v1/workspace/new" 2>/dev/null || true)
  fi
  [[ "$status" == 2?? ]] || die "AnythingLLM API 或工作区检查失败（HTTP ${status:-000}）"
  sync_prompt_to_anythingllm "$DEPLOY_DIR"
  import_and_publish_workflow "$DEPLOY_DIR"
}

configure_crisp() {
  local website tier identifier token_key current secret_choice auth
  current=$(env_get "${DEPLOY_DIR}/.env" CRISP_WEBSITE_ID 2>/dev/null || true)
  printf 'Crisp Website ID [%s]：' "$current"
  IFS= read -r website
  website=${website:-$current}
  printf 'Crisp Token tier（website/plugin）[%s]：' "$(env_get "${DEPLOY_DIR}/.env" CRISP_TOKEN_TIER 2>/dev/null || printf 'website')"
  IFS= read -r tier
  tier=${tier:-$(env_get "${DEPLOY_DIR}/.env" CRISP_TOKEN_TIER 2>/dev/null || printf 'website')}
  printf 'Crisp Token Identifier：'
  IFS= read -r identifier
  printf 'Crisp Token Key（输入内容不会显示）：'
  IFS= read -r -s token_key
  printf '\n是否轮换 Webhook Secret？[y/N] '
  IFS= read -r secret_choice

  [[ "$website" =~ ^[A-Za-z0-9-]{8,128}$ ]] || die "Crisp Website ID 格式无效"
  [[ "$tier" == website || "$tier" == plugin ]] || die "Token tier 只能是 website 或 plugin"
  validate_env_value "$identifier" || die "Token Identifier 无效"
  validate_env_value "$token_key" || die "Token Key 无效"
  auth=$(printf '%s' "${identifier}:${token_key}" | base64 | tr -d '\n')
  env_set "${DEPLOY_DIR}/.env" CRISP_WEBSITE_ID "$website"
  env_set "${DEPLOY_DIR}/.env" CRISP_TOKEN_TIER "$tier"
  env_set "${DEPLOY_DIR}/.env" CRISP_TOKEN_IDENTIFIER "$identifier"
  env_set "${DEPLOY_DIR}/.env" CRISP_TOKEN_KEY "$token_key"
  env_set "${DEPLOY_DIR}/.env" CRISP_AUTH_B64 "$auth"
  case "$secret_choice" in
    y|Y|yes|YES) env_set "${DEPLOY_DIR}/.env" CRISP_WEBHOOK_SECRET "$(random_hex 32)" ;;
  esac
  require_docker_runtime
  docker_compose "$DEPLOY_DIR" up -d --force-recreate n8n
  info "Crisp 配置已更新；如已轮换 Secret，请同步修改 Crisp Webhook URL"
}

ai_config_menu() {
  local choice
  while true; do
    printf '\n1. 重新检测 AI Provider\n'
    printf '2. 配置 AnythingLLM API 与工作区\n'
    printf '3. 修改 Crisp 配置\n'
    printf '4. 重新导入并发布 n8n workflow\n'
    printf '0. 返回\n请选择：'
    IFS= read -r choice
    case "$choice" in
      1)
        configure_provider "$DEPLOY_DIR" 0
        recreate_ai_services
        ;;
      2) configure_anythingllm ;;
      3) configure_crisp ;;
      4) import_and_publish_workflow "$DEPLOY_DIR" ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
  done
}

choose_editor() {
  if command -v nano >/dev/null 2>&1; then
    nano "$1"
  elif command -v vi >/dev/null 2>&1; then
    vi "$1"
  else
    die "未找到 nano 或 vi 编辑器"
  fi
}

validate_prompt_file() {
  local file=$1
  [[ -f "$file" && ! -L "$file" ]] || die "Prompt 必须是普通文件且不能是符号链接"
  [[ -s "$file" ]] || die "Prompt 不能为空"
  (( $(stat -c '%s' "$file") <= 262144 )) || die "Prompt 文件不得超过 256 KiB"
}

prompt_menu() {
  local choice source_path resolved destination
  while true; do
    printf '\n1. 查看 Prompt\n2. 编辑 Prompt\n3. 导入 Prompt\n4. 导出 Prompt\n0. 返回\n请选择：'
    IFS= read -r choice
    case "$choice" in
      1) sed -n '1,240p' "${DEPLOY_DIR}/config/prompt.md" ;;
      2)
        choose_editor "${DEPLOY_DIR}/config/prompt.md"
        validate_prompt_file "${DEPLOY_DIR}/config/prompt.md"
        sync_prompt_to_anythingllm "$DEPLOY_DIR" || true
        ;;
      3)
        printf '导入文件路径：'
        IFS= read -r source_path
        resolved=$(realpath -e -- "$source_path") || die "导入文件不存在"
        validate_prompt_file "$resolved"
        install -m 0640 -- "$resolved" "${DEPLOY_DIR}/config/prompt.md"
        chown root:1000 "${DEPLOY_DIR}/config/prompt.md" 2>/dev/null || true
        sync_prompt_to_anythingllm "$DEPLOY_DIR" || true
        ;;
      4)
        printf '导出文件路径：'
        IFS= read -r destination
        [[ "$destination" == /* ]] || destination="${PWD}/${destination}"
        destination=$(realpath -m -- "$destination")
        [[ ! -L "$destination" ]] || die "导出目标不得是符号链接"
        mkdir -p -- "$(dirname -- "$destination")"
        install -m 0600 -- "${DEPLOY_DIR}/config/prompt.md" "$destination"
        info "Prompt 已导出：$destination"
        ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
  done
}

list_knowledge() {
  local found=0 file
  printf '\n知识文件：\n'
  while IFS= read -r -d '' file; do
    is_supported_knowledge_file "$file" || continue
    [[ "$(basename -- "$file")" == "README.md" ]] && continue
    printf '- %s\n' "$(basename -- "$file")"
    found=1
  done < <(find "${DEPLOY_DIR}/knowledge" -maxdepth 1 -type f -print0 | sort -z)
  (( found == 1 )) || printf '（空）\n'
}

add_knowledge() {
  local source_path resolved name overwrite
  printf '知识文件路径：'
  IFS= read -r source_path
  resolved=$(realpath -e -- "$source_path") || die "文件不存在"
  [[ -f "$resolved" && ! -L "$resolved" ]] || die "只允许普通文件，禁止符号链接"
  is_supported_knowledge_file "$resolved" || die "只支持 Markdown、TXT、PDF 或 DOCX"
  name=$(basename -- "$resolved")
  [[ "$name" != *$'\n'* && "$name" != *$'\r'* && "$name" != *\\* && "$name" != *';'* && "$name" != *','* ]] || die "文件名包含不安全字符"
  if [[ -e "${DEPLOY_DIR}/knowledge/${name}" ]]; then
    printf '同名文件已存在，确认覆盖？[y/N] '
    IFS= read -r overwrite
    case "$overwrite" in y|Y|yes|YES) ;; *) return ;; esac
  fi
  install -m 0640 -- "$resolved" "${DEPLOY_DIR}/knowledge/${name}"
  chown root:1000 "${DEPLOY_DIR}/knowledge/${name}" 2>/dev/null || true
  info "已添加知识文件：$name"
}

delete_knowledge() {
  local choice confirm
  local -a files=()
  while IFS= read -r -d '' file; do
    is_supported_knowledge_file "$file" || continue
    [[ "$(basename -- "$file")" == "README.md" ]] && continue
    files+=("$file")
  done < <(find "${DEPLOY_DIR}/knowledge" -maxdepth 1 -type f -print0 | sort -z)
  (( ${#files[@]} > 0 )) || { info "没有可删除的知识文件"; return; }
  for index in "${!files[@]}"; do
    printf '%d. %s\n' "$((index + 1))" "$(basename -- "${files[index]}")"
  done
  printf '请选择要删除的文件：'
  IFS= read -r choice
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#files[@]} )); then
    die "选择无效"
  fi
  printf '确认删除 %s？[y/N] ' "$(basename -- "${files[choice - 1]}")"
  IFS= read -r confirm
  case "$confirm" in
    y|Y|yes|YES) rm -f -- "${files[choice - 1]}" ;;
    *) return ;;
  esac
  info "本地文件已删除；请执行知识库同步以移除索引"
}

knowledge_menu() {
  local choice
  while true; do
    printf '\n1. 查看知识文件\n2. 添加知识文件\n3. 删除知识文件\n4. 同步知识库\n5. 重新索引\n0. 返回\n请选择：'
    IFS= read -r choice
    case "$choice" in
      1) list_knowledge ;;
      2) add_knowledge ;;
      3) delete_knowledge ;;
      4) knowledge_sync "$DEPLOY_DIR" || true ;;
      5) knowledge_reindex "$DEPLOY_DIR" ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
  done
}

run_backup() {
  local output
  printf '备份路径 [%s/backups/backup.tar.gz]：' "$DEPLOY_DIR"
  IFS= read -r output
  output=${output:-${DEPLOY_DIR}/backups/backup.tar.gz}
  "${DEPLOY_DIR}/scripts/backup.sh" --deploy-dir "$DEPLOY_DIR" --output "$output"
}

run_restore() {
  local input confirm
  printf '备份文件路径：'
  IFS= read -r input
  printf '恢复会替换业务配置与知识文件，但保留现有密钥。确认继续？[y/N] '
  IFS= read -r confirm
  case "$confirm" in
    y|Y|yes|YES) "${DEPLOY_DIR}/scripts/restore.sh" --deploy-dir "$DEPLOY_DIR" --input "$input" ;;
  esac
}

run_rollback() {
  local snapshot confirm
  "${DEPLOY_DIR}/scripts/rollback.sh" --deploy-dir "$DEPLOY_DIR" --list
  printf '请输入要回滚的版本快照 ID：'
  IFS= read -r snapshot
  [[ -n "$snapshot" ]] || { warn "未选择快照"; return; }
  printf '回滚会恢复程序、配置、workflow 与 AnythingLLM 数据，但保留密钥和统计数据。确认继续？[y/N] '
  IFS= read -r confirm
  case "$confirm" in
    y|Y|yes|YES) "${DEPLOY_DIR}/scripts/rollback.sh" --deploy-dir "$DEPLOY_DIR" --snapshot "$snapshot" ;;
  esac
}

while true; do
  CURRENT_VERSION=$(<"${SCRIPT_DIR}/VERSION")
  printf '\n%s\n' '================================'
  printf ' AI客服管理系统 %s\n' "$CURRENT_VERSION"
  printf '%s\n\n' '================================'
  printf '1. 安装系统\n'
  printf '2. 修改AI配置\n'
  printf '3. 修改Prompt\n'
  printf '4. 管理知识库\n'
  printf '5. 查看日志\n'
  printf '6. 健康检查\n'
  printf '7. 备份\n'
  printf '8. 恢复\n'
  printf '9. 更新\n'
  printf '10. 卸载\n'
  printf '11. 回滚版本\n'
  printf '12. 查看历史版本\n'
  printf '13. 知识库分析\n'
  printf '14. 回答质量反馈\n'
  printf '0. 退出\n\n请选择：'
  IFS= read -r CHOICE
  case "$CHOICE" in
    1)
      "${SCRIPT_DIR}/install.sh" --deploy-dir "$DEPLOY_DIR"
      ;;
    2)
      require_installation
      ai_config_menu
      ;;
    3)
      require_installation
      prompt_menu
      ;;
    4)
      require_installation
      knowledge_menu
      ;;
    5)
      require_installation
      require_docker_runtime
      warn "日志可能包含会话内容，请勿公开分享"
      docker_compose "$DEPLOY_DIR" logs --tail 200
      ;;
    6)
      require_installation
      "${DEPLOY_DIR}/scripts/healthcheck.sh" --deploy-dir "$DEPLOY_DIR" || true
      ;;
    7)
      require_installation
      run_backup
      ;;
    8)
      require_installation
      run_restore
      ;;
    9)
      require_installation
      "${DEPLOY_DIR}/update.sh" --deploy-dir "$DEPLOY_DIR"
      ;;
    10)
      require_installation
      "${DEPLOY_DIR}/uninstall.sh" --deploy-dir "$DEPLOY_DIR"
      exit 0
      ;;
    11)
      require_installation
      run_rollback
      ;;
    12)
      require_installation
      "${DEPLOY_DIR}/scripts/rollback.sh" --deploy-dir "$DEPLOY_DIR" --list
      ;;
    13)
      require_installation
      "${DEPLOY_DIR}/scripts/analytics.sh" knowledge --deploy-dir "$DEPLOY_DIR"
      ;;
    14)
      require_installation
      "${DEPLOY_DIR}/scripts/analytics.sh" feedback --deploy-dir "$DEPLOY_DIR"
      ;;
    0) exit 0 ;;
    *) warn "无效选项" ;;
  esac
  pause_screen
done
