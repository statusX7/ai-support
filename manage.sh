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
  acquire_maintenance_lock "$DEPLOY_DIR"
}

pause_screen() {
  printf '\n按 Enter 返回菜单...'
  IFS= read -r _
}

recreate_ai_services() {
  require_docker_runtime
  docker_compose "$DEPLOY_DIR" config --quiet
  docker_compose "$DEPLOY_DIR" up -d --force-recreate anythingllm
  wait_for_local_health "$DEPLOY_DIR" 45 2
  bootstrap_anythingllm_api_key "$DEPLOY_DIR"
  ensure_anythingllm_workspace "$DEPLOY_DIR"
  docker_compose "$DEPLOY_DIR" up -d --force-recreate n8n
  wait_for_local_health "$DEPLOY_DIR" 30 2
  sync_prompt_to_anythingllm "$DEPLOY_DIR"
  import_and_publish_workflow "$DEPLOY_DIR"
  wait_for_local_health "$DEPLOY_DIR" 30 2
  "${DEPLOY_DIR}/scripts/healthcheck.sh" --deploy-dir "$DEPLOY_DIR"
}

configure_anythingllm() {
  local key workspace
  printf 'AnythingLLM Developer API Key（留空则保留现有值或自动创建）：'
  IFS= read -r -s key
  printf '\n工作区 slug [%s]：' "$(env_get "${DEPLOY_DIR}/.env" ANYTHINGLLM_WORKSPACE 2>/dev/null || printf 'crisp-support')"
  IFS= read -r workspace
  workspace=${workspace:-$(env_get "${DEPLOY_DIR}/.env" ANYTHINGLLM_WORKSPACE 2>/dev/null || printf 'crisp-support')}
  if [[ -n "$key" ]]; then
    validate_env_value "$key" || die "AnythingLLM API Key 无效"
    env_set "${DEPLOY_DIR}/.env" ANYTHINGLLM_API_KEY "$key"
  fi
  [[ "$workspace" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || die "工作区 slug 只能包含字母、数字、下划线或连字符"
  env_set "${DEPLOY_DIR}/.env" ANYTHINGLLM_WORKSPACE "$workspace"
  recreate_ai_services
}

configure_crisp() {
  local website tier hook_mode identifier token_key current current_identifier current_token_key
  local secret_choice signing_secret existing_signing_secret auth
  current=$(env_get "${DEPLOY_DIR}/.env" CRISP_WEBSITE_ID 2>/dev/null || true)
  printf 'Crisp Website ID [%s]：' "$current"
  IFS= read -r website
  website=${website:-$current}
  printf 'Crisp Token tier（website/plugin）[%s]：' "$(env_get "${DEPLOY_DIR}/.env" CRISP_TOKEN_TIER 2>/dev/null || printf 'website')"
  IFS= read -r tier
  tier=${tier:-$(env_get "${DEPLOY_DIR}/.env" CRISP_TOKEN_TIER 2>/dev/null || printf 'website')}
  current_identifier=$(env_get "${DEPLOY_DIR}/.env" CRISP_TOKEN_IDENTIFIER 2>/dev/null || true)
  current_token_key=$(env_get "${DEPLOY_DIR}/.env" CRISP_TOKEN_KEY 2>/dev/null || true)
  printf 'Crisp Token Identifier（留空则保留现有值）：'
  IFS= read -r identifier
  identifier=${identifier:-$current_identifier}
  printf 'Crisp Token Key（留空则保留现有值，输入内容不会显示）：'
  IFS= read -r -s token_key
  token_key=${token_key:-$current_token_key}
  printf '\nCrisp Hook 模式（website/plugin）[%s]：' "$(env_get "${DEPLOY_DIR}/.env" CRISP_HOOK_MODE 2>/dev/null || printf 'website')"
  IFS= read -r hook_mode
  hook_mode=${hook_mode:-$(env_get "${DEPLOY_DIR}/.env" CRISP_HOOK_MODE 2>/dev/null || printf 'website')}
  signing_secret=""
  if [[ "$hook_mode" == plugin ]]; then
    printf 'Plugin Hook Signing Secret（留空则保留现有值）：'
    IFS= read -r -s signing_secret
    printf '\n'
  else
    printf '是否轮换 Website Hook URL Secret？[y/N] '
    IFS= read -r secret_choice
  fi

  [[ "$website" =~ ^[A-Za-z0-9-]{8,128}$ ]] || die "Crisp Website ID 格式无效"
  [[ "$tier" == website || "$tier" == plugin ]] || die "Token tier 只能是 website 或 plugin"
  [[ "$hook_mode" == website || "$hook_mode" == plugin ]] || die "Hook 模式只能是 website 或 plugin"
  if ! validate_env_value "$identifier" || [[ "$identifier" == *:* ]]; then
    die "Token Identifier 无效"
  fi
  validate_env_value "$token_key" || die "Token Key 无效"
  auth=$(printf '%s' "${identifier}:${token_key}" | base64 | tr -d '\n')
  env_set "${DEPLOY_DIR}/.env" CRISP_WEBSITE_ID "$website"
  env_set "${DEPLOY_DIR}/.env" CRISP_TOKEN_TIER "$tier"
  env_set "${DEPLOY_DIR}/.env" CRISP_TOKEN_IDENTIFIER "$identifier"
  env_set "${DEPLOY_DIR}/.env" CRISP_TOKEN_KEY "$token_key"
  env_set "${DEPLOY_DIR}/.env" CRISP_AUTH_B64 "$auth"
  env_set "${DEPLOY_DIR}/.env" CRISP_HOOK_MODE "$hook_mode"
  if [[ "$hook_mode" == plugin ]]; then
    if [[ -n "$signing_secret" ]]; then
      validate_env_value "$signing_secret" || die "Plugin Hook Signing Secret 无效"
      env_set "${DEPLOY_DIR}/.env" CRISP_PLUGIN_SIGNING_SECRET "$signing_secret"
    fi
    existing_signing_secret=$(env_get "${DEPLOY_DIR}/.env" CRISP_PLUGIN_SIGNING_SECRET 2>/dev/null || true)
    validate_env_value "$existing_signing_secret" || die "Plugin 模式必须配置 Crisp 提供的 Signing Secret"
  else
    ensure_secret "${DEPLOY_DIR}/.env" CRISP_WEBSITE_HOOK_SECRET 32
    case "${secret_choice:-}" in
      y|Y|yes|YES) env_set "${DEPLOY_DIR}/.env" CRISP_WEBSITE_HOOK_SECRET "$(random_hex 32)" ;;
    esac
  fi
  require_docker_runtime
  docker_compose "$DEPLOY_DIR" up -d --force-recreate n8n
  wait_for_local_health "$DEPLOY_DIR" 30 2
  import_and_publish_workflow "$DEPLOY_DIR"
  wait_for_local_health "$DEPLOY_DIR" 30 2
  "${DEPLOY_DIR}/scripts/healthcheck.sh" --deploy-dir "$DEPLOY_DIR"
  info "Crisp 配置已更新；Website Hook 与 Plugin Hook 的 Secret 不可混用"
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
        sync_prompt_to_anythingllm "$DEPLOY_DIR"
        ;;
      3)
        printf '导入文件路径：'
        IFS= read -r source_path
        resolved=$(realpath -e -- "$source_path") || die "导入文件不存在"
        validate_prompt_file "$resolved"
        install -m 0640 -- "$resolved" "${DEPLOY_DIR}/config/prompt.md"
        chown root:1000 "${DEPLOY_DIR}/config/prompt.md" 2>/dev/null || true
        sync_prompt_to_anythingllm "$DEPLOY_DIR"
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
      4) knowledge_sync "$DEPLOY_DIR" || warn "知识库同步未完全成功；请根据上方错误修复后重试" ;;
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

status_menu() {
  local choice
  while true; do
    printf '\n1. 查看容器状态\n2. 执行健康检查\n3. 查看历史版本\n0. 返回\n请选择：'
    IFS= read -r choice
    case "$choice" in
      1)
        require_docker_runtime
        docker_compose "$DEPLOY_DIR" ps
        ;;
      2) "${DEPLOY_DIR}/scripts/healthcheck.sh" --deploy-dir "$DEPLOY_DIR" || true ;;
      3) "${DEPLOY_DIR}/scripts/rollback.sh" --deploy-dir "$DEPLOY_DIR" --list ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
  done
}

statistics_menu() {
  local choice
  while true; do
    printf '\n1. 知识库命中分析\n2. AI 回答质量反馈\n0. 返回\n请选择：'
    IFS= read -r choice
    case "$choice" in
      1) "${DEPLOY_DIR}/scripts/analytics.sh" knowledge --deploy-dir "$DEPLOY_DIR" ;;
      2) "${DEPLOY_DIR}/scripts/analytics.sh" feedback --deploy-dir "$DEPLOY_DIR" ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
  done
}

uninstall_menu() {
  local choice
  printf '\n1. 安全卸载（保留配置、知识库和运行数据）\n'
  printf '2. 完整清理（永久删除部署数据，必须输入 PURGE）\n'
  printf '0. 返回\n请选择：'
  IFS= read -r choice
  case "$choice" in
    1)
      "${DEPLOY_DIR}/uninstall.sh" --deploy-dir "$DEPLOY_DIR"
      exit 0
      ;;
    2)
      "${DEPLOY_DIR}/uninstall.sh" --deploy-dir "$DEPLOY_DIR" --purge
      exit 0
      ;;
    0) return ;;
    *) warn "无效选项" ;;
  esac
}

while true; do
  CURRENT_VERSION=$(<"${SCRIPT_DIR}/VERSION")
  printf '\n%s\n' '================================'
  printf ' AI客服管理系统 %s\n' "$CURRENT_VERSION"
  printf '%s\n\n' '================================'
  printf '1. 查看状态\n'
  printf '2. 修改AI配置\n'
  printf '3. 修改Prompt\n'
  printf '4. 管理知识库\n'
  printf '5. 查看统计\n'
  printf '6. 查看日志\n'
  printf '7. 备份\n'
  printf '8. 恢复\n'
  printf '9. 更新\n'
  printf '10. 回滚\n'
  printf '11. 卸载系统\n'
  printf '0. 退出\n\n请选择：'
  IFS= read -r CHOICE
  case "$CHOICE" in
    1)
      require_installation
      status_menu
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
      statistics_menu
      ;;
    6)
      require_installation
      require_docker_runtime
      warn "日志可能包含会话内容，请勿公开分享"
      docker_compose "$DEPLOY_DIR" logs --tail 200
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
      run_rollback
      ;;
    11)
      require_installation
      uninstall_menu
      ;;
    0) exit 0 ;;
    *) warn "无效选项" ;;
  esac
  pause_screen
done
