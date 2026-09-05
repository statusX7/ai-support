#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/bootstrap.sh
source "${SCRIPT_DIR}/scripts/bootstrap.sh"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/scripts/common.sh"
# shellcheck source=scripts/wizard.sh
source "${SCRIPT_DIR}/scripts/wizard.sh"

DEPLOY_REQUEST=""
ORIGINAL_ARGS=("$@")

manage_usage() {
  cat <<'EOF'
用法：./manage.sh [--deploy-dir PATH] [--help] [--version]

未安装时可选择“快速初始化”；已安装时可查看状态、修改配置、修复依赖或卸载。
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --deploy-dir)
      (( $# >= 2 )) || die "--deploy-dir 缺少参数"
      DEPLOY_REQUEST=$2
      shift 2
      ;;
    --help|-h)
      manage_usage
      exit 0
      ;;
    --version)
      printf '%s\n' "$(<"${SCRIPT_DIR}/VERSION")"
      exit 0
      ;;
    *) die "未知选项：$1" ;;
  esac
done
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo bash "$SCRIPT_DIR/manage.sh" "${ORIGINAL_ARGS[@]}"
  fi
  die "管理操作需要 root 权限；请使用 sudo bash ./manage.sh"
fi
bootstrap_prepare_minimal_dependencies \
  || die "管理工具所需基础依赖自动安装失败"
DEPLOY_DIR=$(resolve_deploy_dir "$DEPLOY_REQUEST")

require_installation() {
  bootstrap_prepare_minimal_dependencies
  assert_installation "$DEPLOY_DIR"
  acquire_maintenance_lock "$DEPLOY_DIR"
}

pause_screen() {
  printf '\n按 Enter 返回菜单...'
  IFS= read -r _ || true
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
  import_and_publish_workflow "$DEPLOY_DIR" || die "n8n workflow 发布失败"
  wait_for_local_health "$DEPLOY_DIR" 30 2
  "${DEPLOY_DIR}/scripts/healthcheck.sh" --deploy-dir "$DEPLOY_DIR" --application
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
  local secret_choice signing_secret existing_signing_secret auth marker_source
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
  import_and_publish_workflow "$DEPLOY_DIR" || die "n8n workflow 发布失败"
  wait_for_local_health "$DEPLOY_DIR" 30 2
  "${DEPLOY_DIR}/scripts/healthcheck.sh" --deploy-dir "$DEPLOY_DIR" --application
  marker_source=$(sed -n 's/^source=//p' "${DEPLOY_DIR}/${INSTALL_MARKER}" | head -n 1)
  if crisp_api_check "$DEPLOY_DIR"; then
    set_installation_fact "$DEPLOY_DIR" crisp_api ready
    write_installation_marker "$DEPLOY_DIR" "$marker_source" "$(<"${DEPLOY_DIR}/VERSION")" ready
    info "Crisp 配置已更新并通过 REST API 检查；Website Hook 与 Plugin Hook 的 Secret 不可混用"
  else
    set_installation_fact "$DEPLOY_DIR" crisp_api failed
    write_installation_marker "$DEPLOY_DIR" "$marker_source" "$(<"${DEPLOY_DIR}/VERSION")" local-ready
    warn "Crisp 配置已保存，但 REST API 检查失败（HTTP ${CRISP_API_STATUS:-000}）；本地服务保持运行"
  fi
}

ai_config_menu() {
  local choice
  while true; do
    printf '\n1. 重新检测 AI Provider\n'
    printf '2. 高级：配置 AnythingLLM API 与工作区\n'
    printf '3. 重新导入并发布 n8n workflow\n'
    printf '0. 返回\n请选择：'
    IFS= read -r choice
    case "$choice" in
      1)
        configure_provider "$DEPLOY_DIR" 0
        recreate_ai_services
        ;;
      2) configure_anythingllm ;;
      3) import_and_publish_workflow "$DEPLOY_DIR" ;;
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
  printf '2. 完整清理（永久删除部署数据，需要两次数字确认）\n'
  printf '0. 返回\n请选择：'
  IFS= read -r choice
  case "$choice" in
    1)
      "${DEPLOY_DIR}/uninstall.sh" --deploy-dir "$DEPLOY_DIR"
      exit 0
      ;;
    2)
      "${DEPLOY_DIR}/uninstall.sh" --deploy-dir "$DEPLOY_DIR" --purge --numeric-confirm
      exit 0
      ;;
    0) return ;;
    *) warn "无效选项" ;;
  esac
}

show_installation_facts() {
  local fact value
  printf '安装状态：%s\n' "$(installation_state "$DEPLOY_DIR")"
  for fact in dependencies local_services app_config provider crisp_api webhook conversation; do
    value=$(installation_fact "$DEPLOY_DIR" "$fact" 2>/dev/null || true)
    printf '  %-15s %s\n' "$fact" "${value:-未记录}"
  done
}

quick_initialization() {
  local choice
  local -a args=(--deploy-dir "$DEPLOY_DIR")
  if [[ -f "${DEPLOY_DIR}/${INSTALL_MARKER}" ]] \
    && [[ "$(installation_state "$DEPLOY_DIR")" == ready || "$(installation_state "$DEPLOY_DIR")" == local-ready ]]; then
    printf '\n1. 使用现有配置继续检查或修复安装\n'
    printf '2. 重新运行十项快速初始化（保留数据）\n'
    printf '0. 返回\n请选择：'
    IFS= read -r choice || return 0
    case "$choice" in
      1) ;;
      2) args+=(--reconfigure) ;;
      0) return 0 ;;
      *) warn "无效选项"; return 0 ;;
    esac
  fi
  "${SCRIPT_DIR}/install.sh" "${args[@]}"
}

configure_webhook_menu() {
  local current requested
  current=$(env_get "${DEPLOY_DIR}/.env" WEBHOOK_PRODUCTION_URL 2>/dev/null || true)
  printf '当前生产 Webhook：%s\n' "${current:-未配置}"
  printf '请输入域名或现有 HTTPS 完整 Webhook 地址：'
  IFS= read -r requested || return 0
  [[ -n "$requested" ]] || { warn "未修改"; return 0; }
  if ! wizard_parse_webhook_input "$requested"; then
    warn "地址无效，或域名自动 HTTPS 所需的 80/443 已被占用"
    return 0
  fi
  configure_webhook_access "$DEPLOY_DIR" "$WIZARD_WEBHOOK_MODE" \
    "$WIZARD_WEBHOOK_BASE" "$WIZARD_WEBHOOK_URL" "$WIZARD_URL_HOST"
  env_set "${DEPLOY_DIR}/.env" N8N_HOST "$WIZARD_URL_HOST"
  env_set "${DEPLOY_DIR}/.env" N8N_PROTOCOL https
  env_set "${DEPLOY_DIR}/.env" N8N_SECURE_COOKIE true
  require_docker_runtime
  docker_compose "$DEPLOY_DIR" up -d --remove-orphans
  docker_compose "$DEPLOY_DIR" up -d --force-recreate n8n
  wait_for_local_health "$DEPLOY_DIR" 30 2
  import_and_publish_workflow "$DEPLOY_DIR"
  if webhook_access_check "$DEPLOY_DIR"; then
    set_installation_fact "$DEPLOY_DIR" webhook ready
    info "Webhook 的 DNS、TLS、反向代理及生产路由已可达；请在 Crisp 后台核对登记地址"
  else
    set_installation_fact "$DEPLOY_DIR" webhook pending
    warn "Webhook 运行配置已更新，但公网路由待验证（HTTP ${WEBHOOK_ACCESS_STATUS:-000}）"
  fi
}

edit_json_configuration() {
  local name=$1
  local target="${DEPLOY_DIR}/config/${name}"
  local temporary
  [[ -f "$target" && ! -L "$target" ]] || die "配置文件缺失或不安全：$name"
  temporary=$(mktemp "${DEPLOY_DIR}/tmp/${name}.edit.XXXXXX")
  install -m 0600 -- "$target" "$temporary"
  choose_editor "$temporary"
  if ! jq empty "$temporary" >/dev/null 2>&1; then
    rm -f -- "$temporary"
    warn "配置格式无效，原文件未改变"
    return 0
  fi
  install -m 0640 -- "$temporary" "$target"
  rm -f -- "$temporary"
  chown root:1000 "$target" 2>/dev/null || true
  info "配置已原子更新：$name"
}

prompt_knowledge_menu() {
  local choice
  while true; do
    printf '\n1. 客服提示词\n2. 知识库\n0. 返回\n请选择：'
    IFS= read -r choice || return 0
    case "$choice" in
      1) prompt_menu ;;
      2) knowledge_menu ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

rules_menu() {
  local choice
  while true; do
    printf '\n1. Crisp 凭据与 Hook 类型\n2. 公网 Webhook 接入\n'
    printf '3. 关键词回复\n4. 欢迎语与多级菜单\n5. 人工接管\n0. 返回\n请选择：'
    IFS= read -r choice || return 0
    case "$choice" in
      1) configure_crisp ;;
      2) configure_webhook_menu ;;
      3) edit_json_configuration keyword.yaml ;;
      4) edit_json_configuration menu.yaml ;;
      5) edit_json_configuration handoff.yaml ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

analysis_menu() {
  local choice
  while true; do
    printf '\n1. 查看知识命中与反馈统计\n2. 编辑标签配置\n3. 编辑反馈配置\n0. 返回\n请选择：'
    IFS= read -r choice || return 0
    case "$choice" in
      1) statistics_menu ;;
      2) edit_json_configuration tags.yaml ;;
      3) edit_json_configuration feedback.yaml ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

diagnostics_menu() {
  local choice
  while true; do
    printf '\n1. 查看最近日志\n2. 完整健康检查\n3. 环境检查\n4. 自动修复依赖\n0. 返回\n请选择：'
    IFS= read -r choice || return 0
    case "$choice" in
      1)
        require_docker_runtime
        warn "日志可能包含会话内容，请勿公开分享"
        docker_compose "$DEPLOY_DIR" logs --tail 200
        ;;
      2) "${DEPLOY_DIR}/scripts/healthcheck.sh" --deploy-dir "$DEPLOY_DIR" || true ;;
      3) "${DEPLOY_DIR}/scripts/bootstrap.sh" --check || true ;;
      4)
        if [[ $EUID -eq 0 ]]; then
          "${DEPLOY_DIR}/scripts/bootstrap.sh" --all
        elif command -v sudo >/dev/null 2>&1; then
          sudo bash "${DEPLOY_DIR}/scripts/bootstrap.sh" --all
        else
          warn "自动修复依赖需要 root 或 sudo 权限"
        fi
        ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

backup_restore_menu() {
  local choice
  while true; do
    printf '\n1. 创建备份\n2. 恢复备份\n0. 返回\n请选择：'
    IFS= read -r choice || return 0
    case "$choice" in
      1) run_backup ;;
      2) run_restore ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

update_rollback_menu() {
  local choice
  while true; do
    printf '\n1. 更新系统\n2. 回滚版本\n3. 查看历史版本\n0. 返回\n请选择：'
    IFS= read -r choice || return 0
    case "$choice" in
      1) "${DEPLOY_DIR}/update.sh" --deploy-dir "$DEPLOY_DIR" ;;
      2) run_rollback ;;
      3) "${DEPLOY_DIR}/scripts/rollback.sh" --deploy-dir "$DEPLOY_DIR" --list ;;
      0) return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

while true; do
  CURRENT_VERSION=$(<"${SCRIPT_DIR}/VERSION")
  printf '\n%s\n' '================================'
  printf ' AI客服管理系统 %s\n' "$CURRENT_VERSION"
  printf '%s\n\n' '================================'
  printf '1. 快速初始化 / 继续未完成安装\n'
  printf '2. 查看运行与接入状态\n'
  printf '3. AI 接口和模型设置\n'
  printf '4. 客服提示词与知识库\n'
  printf '5. 关键词、欢迎菜单及人工接管设置\n'
  printf '6. 标签、统计与反馈\n'
  printf '7. 日志、环境检查与依赖修复\n'
  printf '8. 备份与恢复\n'
  printf '9. 更新与回滚\n'
  printf '10. 卸载系统\n'
  printf '0. 退出\n\n请选择：'
  if ! IFS= read -r CHOICE; then
    printf '\n输入结束，未执行任何操作。\n'
    exit 0
  fi
  case "$CHOICE" in
    1) quick_initialization ;;
    2)
      require_installation
      show_installation_facts
      status_menu
      ;;
    3)
      require_installation
      ai_config_menu
      ;;
    4)
      require_installation
      prompt_knowledge_menu
      ;;
    5)
      require_installation
      rules_menu
      ;;
    6)
      require_installation
      analysis_menu
      ;;
    7)
      require_installation
      diagnostics_menu
      ;;
    8)
      require_installation
      backup_restore_menu
      ;;
    9)
      require_installation
      update_rollback_menu
      ;;
    10)
      require_installation
      uninstall_menu
      ;;
    0) exit 0 ;;
    *) warn "无效选项" ;;
  esac
  pause_screen
done
