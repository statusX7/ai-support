#!/usr/bin/env bash
set -euo pipefail
umask 077

CRISP_SETTINGS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh
source "$CRISP_SETTINGS_DIR/common.sh"
# shellcheck source=scripts/wizard.sh
source "$CRISP_SETTINGS_DIR/wizard.sh"

crisp_settings_get() {
  local env_file="${1}/.env"
  jq -n --arg website "$(env_get "$env_file" CRISP_WEBSITE_ID)" \
    --arg tier "$(env_get "$env_file" CRISP_TOKEN_TIER)" --arg hook "$(env_get "$env_file" CRISP_HOOK_MODE)" \
    --arg url "$(env_get "$env_file" WEBHOOK_PRODUCTION_URL)" \
    '{website_id:$website,token_tier:$tier,hook_mode:$hook,webhook_url:$url,token_identifier:"已填写（隐藏）",token_key:"已填写（隐藏）",events:["message:send","message:received","message:updated"]}'
}

crisp_settings_test() {
  local deploy_dir=$1 api=false webhook=false marker_source version previous_state
  previous_state=$(installation_state "$deploy_dir")
  if crisp_api_check "$deploy_dir"; then api=true; set_installation_fact "$deploy_dir" crisp_api ready
  else set_installation_fact "$deploy_dir" crisp_api failed; fi
  if webhook_access_check "$deploy_dir"; then webhook=true; set_installation_fact "$deploy_dir" webhook ready
  else set_installation_fact "$deploy_dir" webhook pending; fi
  refresh_conversation_fact "$deploy_dir" || set_installation_fact "$deploy_dir" conversation pending
  marker_source=$(sed -n 's/^source=//p' "$deploy_dir/$INSTALL_MARKER" | head -n 1)
  version=$(<"$deploy_dir/VERSION")
  if [[ "$previous_state" == ready || "$previous_state" == local-ready ]]; then
    if [[ "$api" == true && "$webhook" == true && "$(installation_fact "$deploy_dir" conversation)" == ready ]]; then
      write_installation_marker "$deploy_dir" "$marker_source" "$version" ready
    else
      write_installation_marker "$deploy_dir" "$marker_source" "$version" local-ready
    fi
  fi
  jq -n --argjson api "$api" --argjson webhook "$webhook" \
    --arg status "${CRISP_API_STATUS:-000}" --arg state "$(installation_state "$deploy_dir")" \
    '{crisp_api:$api,http_status:$status,public_webhook:$webhook,state:$state,events:["message:send","message:received","message:updated"],instructions:"在 Workspace Settings → Advanced configuration → Web Hooks 登记生产地址；使用私密终端的显示 Hook URL 功能获取含 Secret 的完整值。"}'
  [[ "$(installation_state "$deploy_dir")" == ready ]] || return 2
}

crisp_settings_apply() (
  local deploy_dir=$1 input=$2 work env_candidate history key value identifier token auth hook_mode changed_credentials=false
  local committed=0 completed=0 previous_caddy=0 old_access_mode
  [[ -f "$input" && ! -L "$input" && $(stat -c '%a' "$input") == 600 && $(stat -c '%s' "$input") -le 65536 ]] \
    || die 'Crisp 候选配置必须是权限 0600 的受限普通 JSON 文件'
  jq -e 'type=="object" and all(keys[]; IN("website_id","token_tier","hook_mode","token_identifier","token_key","plugin_signing_secret","rotate_secret","webhook_input")) and all(to_entries[]; if .key=="rotate_secret" then (.value|type)=="boolean" else (.value|type)=="string" end)' "$input" >/dev/null || die 'Crisp 候选字段无效'
  acquire_maintenance_lock "$deploy_dir"
  mkdir -p -- "$deploy_dir/backups/config-history"
  work=$(mktemp -d "$deploy_dir/tmp/crisp-settings.XXXXXX")
  history=$(mktemp -d "$deploy_dir/backups/config-history/crisp.XXXXXXXX")
  chmod 0700 "$work" "$history"
  mkdir -p "$work/tmp"
  env_candidate="$work/.env"
  install -m 0600 -- "$deploy_dir/.env" "$env_candidate"
  install -m 0600 -- "$deploy_dir/.env" "$history/.env"
  old_access_mode=$(env_get "$env_candidate" WEBHOOK_ACCESS_MODE)
  if [[ -f "$deploy_dir/config/Caddyfile" ]]; then
    previous_caddy=1; install -m 0600 -- "$deploy_dir/config/Caddyfile" "$history/Caddyfile"
  fi
  # shellcheck disable=SC2317
  crisp_settings_cleanup() {
    local status=$?
    trap - EXIT
    if (( committed && ! completed )); then
      install -m 0600 -- "$history/.env" "$work/restore.env"
      mv -f -- "$work/restore.env" "$deploy_dir/.env"
      if (( previous_caddy )); then install -m 0640 -- "$history/Caddyfile" "$deploy_dir/config/Caddyfile"; fi
      docker_compose "$deploy_dir" up -d --force-recreate n8n >/dev/null 2>&1 || true
      if [[ "$old_access_mode" == managed_https ]]; then docker_compose "$deploy_dir" up -d caddy >/dev/null 2>&1 || true; fi
      warn 'Crisp 配置应用失败，原配置已恢复；服务状态可从诊断菜单复核'
    fi
    [[ "$work" == "$deploy_dir"/tmp/crisp-settings.* ]] && find "$work" -depth -delete
    exit "$status"
  }
  trap crisp_settings_cleanup EXIT
  for key in website_id token_tier hook_mode token_identifier token_key plugin_signing_secret; do
    value=$(jq -r --arg key "$key" '.[$key] // ""' "$input")
    [[ -n "$value" ]] || continue
    validate_env_value "$value" || die 'Crisp 配置不可包含控制字符'
    case "$key" in
      website_id) [[ "$value" =~ ^[A-Za-z0-9-]{8,128}$ ]] || die 'Website ID 格式无效'; key=CRISP_WEBSITE_ID; changed_credentials=true ;;
      token_tier) [[ "$value" == website || "$value" == plugin ]] || die 'Token tier 无效'; key=CRISP_TOKEN_TIER; changed_credentials=true ;;
      hook_mode) [[ "$value" == website || "$value" == plugin ]] || die 'Hook 模式无效'; key=CRISP_HOOK_MODE ;;
      token_identifier) [[ "$value" != *:* ]] || die 'Token Identifier 不能包含冒号'; key=CRISP_TOKEN_IDENTIFIER; changed_credentials=true ;;
      token_key) key=CRISP_TOKEN_KEY; changed_credentials=true ;;
      plugin_signing_secret) key=CRISP_PLUGIN_SIGNING_SECRET ;;
    esac
    env_set "$env_candidate" "$key" "$value"
  done
  identifier=$(env_get "$env_candidate" CRISP_TOKEN_IDENTIFIER)
  token=$(env_get "$env_candidate" CRISP_TOKEN_KEY)
  auth=$(printf '%s' "$identifier:$token" | base64 | tr -d '\n')
  env_set "$env_candidate" CRISP_AUTH_B64 "$auth"
  hook_mode=$(env_get "$env_candidate" CRISP_HOOK_MODE)
  if [[ "$hook_mode" == plugin ]]; then
    value=$(env_get "$env_candidate" CRISP_PLUGIN_SIGNING_SECRET 2>/dev/null || true)
    validate_env_value "$value" || die 'Plugin Hook 必须配置有效 Signing Secret'
  elif [[ "$(jq -r '.rotate_secret // false' "$input")" == true ]]; then
    env_set "$env_candidate" CRISP_WEBSITE_HOOK_SECRET "$(random_hex 32)"
  fi
  value=$(jq -r '.webhook_input // ""' "$input")
  if [[ -n "$value" ]]; then
    wizard_parse_webhook_input "$value" || die '请输入域名或正确的 HTTPS 生产 Webhook 地址'
    if [[ "$WIZARD_WEBHOOK_MODE" == domain ]]; then
      webhook_ports_available "$deploy_dir" || die '80/443 被其他服务占用；请使用已有反代完整地址'
      env_set "$env_candidate" WEBHOOK_ACCESS_MODE managed_https
      env_set "$env_candidate" COMPOSE_PROFILES managed-https
    else
      env_set "$env_candidate" WEBHOOK_ACCESS_MODE external_proxy
      env_unset "$env_candidate" COMPOSE_PROFILES
    fi
    wizard_parse_http_url "$WIZARD_WEBHOOK_BASE_URL" 1 || die 'Webhook URL 无效'
    env_set "$env_candidate" WEBHOOK_DOMAIN "$WIZARD_URL_HOST"
    env_set "$env_candidate" N8N_HOST "$WIZARD_URL_HOST"
    env_set "$env_candidate" N8N_PROTOCOL https
    env_set "$env_candidate" N8N_SECURE_COOKIE true
    env_set "$env_candidate" PUBLIC_WEBHOOK_URL "$WIZARD_WEBHOOK_BASE_URL"
    env_set "$env_candidate" WEBHOOK_PRODUCTION_URL "$WIZARD_WEBHOOK_PRODUCTION_URL"
  fi
  if [[ "$changed_credentials" == true ]] && ! crisp_api_check "$work"; then
    die "Crisp 候选凭据未通过验证（HTTP ${CRISP_API_STATUS:-000}），原配置保持"
  fi
  docker_compose_command --project-directory "$deploy_dir" --env-file "$env_candidate" -f "$deploy_dir/docker-compose.yml" config --quiet
  committed=1
  install -m 0600 -- "$env_candidate" "$work/commit.env"
  mv -f -- "$work/commit.env" "$deploy_dir/.env"
  write_webhook_proxy_snippets "$deploy_dir"
  if [[ "$(env_get "$env_candidate" WEBHOOK_ACCESS_MODE)" == managed_https && ! -f "$deploy_dir/config/Caddyfile" ]]; then
    install -m 0640 -- "$deploy_dir/config/Caddyfile.example" "$deploy_dir/config/Caddyfile"
  fi
  if [[ "$old_access_mode" == managed_https && "$(env_get "$env_candidate" WEBHOOK_ACCESS_MODE)" != managed_https ]]; then
    docker_compose "$deploy_dir" --profile managed-https stop caddy >&2
  fi
  docker_compose "$deploy_dir" up -d --remove-orphans >&2
  docker_compose "$deploy_dir" up -d --force-recreate n8n >&2
  wait_for_local_health "$deploy_dir" >&2
  import_and_publish_workflow "$deploy_dir" >&2
  completed=1
  if crisp_settings_test "$deploy_dir"; then return 0; else return $?; fi
)

crisp_settings_main() {
  local deploy_request='' action deploy_dir url secret
  while (( $# )); do
    case "$1" in
      --deploy-dir) (( $# >= 2 )) || die '--deploy-dir 缺少参数'; deploy_request=$2; shift 2 ;;
      --help|-h) printf '用法：crisp-settings.sh --deploy-dir DIR get|test|apply FILE|hook-url\n'; return ;;
      *) break ;;
    esac
  done
  action=${1:-get}; (( $# == 0 )) || shift
  (( EUID == 0 )) || die 'Crisp 配置管理需要 root 或 sudo 权限'
  deploy_dir=$(resolve_deploy_dir "$deploy_request")
  assert_managed_installation "$deploy_dir"
  case "$action" in
    get) crisp_settings_get "$deploy_dir" ;;
    test) crisp_settings_test "$deploy_dir" ;;
    apply) assert_installation "$deploy_dir"; crisp_settings_apply "$deploy_dir" "${1:?缺少受限候选文件}" ;;
    hook-url)
      url=$(env_get "$deploy_dir/.env" WEBHOOK_PRODUCTION_URL)
      if [[ "$(env_get "$deploy_dir/.env" CRISP_HOOK_MODE)" == website ]]; then
        secret=$(env_get "$deploy_dir/.env" CRISP_WEBSITE_HOOK_SECRET)
        printf '%s?key=%s\n' "$url" "$secret"
      else printf '%s（需 Plugin 签名）\n' "$url"; fi ;;
    *) die "未知 Crisp 配置操作：$action" ;;
  esac
}

crisp_settings_main "$@"
