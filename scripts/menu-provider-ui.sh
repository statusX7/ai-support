#!/usr/bin/env bash
set -euo pipefail

provider_error_message() {
  case "${1:-provider_error}" in
    authentication_failed) printf '%s\n' '接口鉴权失败：请核对本接口的地址、API Key 与模型调用权限。' ;;
    model_unavailable|model_not_found) printf '%s\n' '所选模型或对应推理端点不可用：请核对模型原名、请求协议与接口地址。' ;;
    protocol_error|protocol_mismatch|unsupported_protocol) printf '%s\n' '请求协议不匹配：请核对该接口应使用 Chat Completions 还是 Responses，以及 Base URL 路径。' ;;
    invalid_response) printf '%s\n' '接口响应无效：上游返回了空正文、非 JSON 或不符合所选协议的结构。' ;;
    rate_limited) printf '%s\n' '接口触发请求频率限制：请按服务端要求等待冷却，或核对独立授权的备用接口。' ;;
    quota_exhausted) printf '%s\n' '接口额度或余额不足：不会立即重复请求同一授权范围，可补充额度或使用独立授权的备用接口。' ;;
    upstream_timeout) printf '%s\n' '接口推理超时：请核对网络、模型响应时间与主备策略中的单次请求期限。' ;;
    upstream_unavailable) printf '%s\n' '上游服务端返回故障：请核对服务状态与备用接口。' ;;
    connection_failed) printf '%s\n' '应用环境连接接口失败：请核对 DNS、TLS、接口地址与容器网络。' ;;
    temporarily_unavailable) printf '%s\n' '本地 Provider 适配器不可用：请运行状态与自检，确认容器和配置已应用。' ;;
    models_unavailable) printf '%s\n' '接口没有提供可用模型列表：可以手动填写准确模型原名，再执行真实推理验证。' ;;
    *) printf '%s\n' '接口失败原因未能分类：未显示上游原始内容，请运行状态与自检。' ;;
  esac
}

provider_error_code_from_file() {
  local file=$1 fallback=${2:-provider_error}
  jq -M -r --arg fallback "$fallback" '
    (.error.code // $fallback) as $code |
    if $code == "authentication_failed" or $code == "model_unavailable" or $code == "model_not_found"
      or $code == "protocol_error" or $code == "protocol_mismatch" or $code == "unsupported_protocol"
      or $code == "invalid_response" or $code == "rate_limited" or $code == "quota_exhausted"
      or $code == "upstream_timeout" or $code == "upstream_unavailable" or $code == "connection_failed"
      or $code == "temporarily_unavailable" or $code == "models_unavailable"
    then $code else $fallback end
  ' "$file" 2>/dev/null || printf '%s\n' "$fallback"
}

provider_pool_read() {
  local action=${1:-list}
  manager_temporary || return 1
  PROVIDER_POOL=$MANAGE_FILE
  manager_tool provider "$action" > "$PROVIDER_POOL" || return 1
  jq -M -e '.ok==true and (.entries|type=="array") and (.primary_id|type=="string")' "$PROVIDER_POOL" >/dev/null
}

provider_status_view() {
  local pool status recent result status_code=0 recent_code=0
  manager_temporary || return 1; pool=$MANAGE_FILE
  if manager_tool provider list > "$pool"; then :; else result=$?; cat -- "$pool"; return "$result"; fi
  manager_temporary || return 1; status=$MANAGE_FILE
  manager_temporary || return 1; recent=$MANAGE_FILE
  if timeout --signal=TERM --kill-after=1s 8s bash "$DEPLOY_DIR/scripts/provider.sh" --deploy-dir "$DEPLOY_DIR" status > "$status" 2> "$status.stderr"; then :; else status_code=$?; fi
  if timeout --signal=TERM --kill-after=1s 8s bash "$DEPLOY_DIR/scripts/provider.sh" --deploy-dir "$DEPLOY_DIR" recent > "$recent" 2> "$recent.stderr"; then :; else recent_code=$?; fi
  python3 "$SCRIPT_DIR/scripts/menu-display.py" --provider-snapshot "$pool" "$status" "$status_code" "$recent" "$recent_code"
}

provider_select() {
  local filter=${1:-all} source=${2:-list}
  provider_pool_read "$source" || { warn '接口列表读取失败，可能尚无导入草稿；请查看主备状态或运行自检'; return 1; }
  jq -M --arg filter "$filter" '[.entries[] | select($filter!="backup" or .role=="backup") | . + {name:(.name+"（"+(if .role=="primary" then "主接口" else "备用接口" end)+"，"+(if .enabled then "启用" else "停用" end)+"）")}]' \
    "$PROVIDER_POOL" > "$PROVIDER_POOL.entries" || return 1
  menu_pick_json "$PROVIDER_POOL.entries" id name || return 1
  PROVIDER_SELECTED=$MENU_SELECTED_ID
}

provider_candidate() {
  local id=$1 draft=${2:-0} action=entry
  manager_temporary || return 1
  PROVIDER_CANDIDATE=$MANAGE_FILE
  if [[ "$id" == new ]]; then
    printf '{"provider":{"name":"","base_url":"","model":"","api_mode":"chat_completions","capabilities":{"chat_completions":true,"responses":false,"vision":false}}}\n' > "$PROVIDER_CANDIDATE"
  else
    if (( draft )); then action='draft-entry'; fi
    manager_tool provider "$action" "$id" > "$PROVIDER_CANDIDATE.entry" || return 1
    jq -M '{provider:(.entry | {name,base_url,model,api_mode,capabilities,context_window,max_output_tokens} | with_entries(select(.value!=null)))}' \
      "$PROVIDER_CANDIDATE.entry" > "$PROVIDER_CANDIDATE" || return 1
  fi
}

provider_model_select() {
  local candidate=$1 id=$2 models_file choice query='' page=0 total start request_status error_code
  manager_temporary || return 1; models_file=$MANAGE_FILE
  while true; do
    if manager_tool provider models "$id" "$candidate" > "$models_file"; then break; else request_status=$?; fi
    case "$request_status" in
      2) error_code=$(provider_error_code_from_file "$models_file" models_unavailable) ;;
      3) error_code=$(provider_error_code_from_file "$models_file" authentication_failed) ;;
      4) error_code=$(provider_error_code_from_file "$models_file" temporarily_unavailable) ;;
      *) error_code=$(provider_error_code_from_file "$models_file" provider_error) ;;
    esac
    warn "$(provider_error_message "$error_code")"
    if [[ "$error_code" == authentication_failed ]]; then return 1; fi
    if [[ "$error_code" == rate_limited || "$error_code" == quota_exhausted \
      || "$error_code" == upstream_timeout || "$error_code" == upstream_unavailable \
      || "$error_code" == connection_failed || "$error_code" == temporarily_unavailable ]]; then
      menu_read choice '模型列表请求暂时失败：1 重试 / 2 返回修改接口 / 0 取消：' || return 1
      case "$choice" in 1) continue ;; *) return 2 ;; esac
    fi
    if [[ "$error_code" != models_unavailable && "$error_code" != model_unavailable \
      && "$error_code" != protocol_error && "$error_code" != protocol_mismatch \
      && "$error_code" != unsupported_protocol && "$error_code" != invalid_response ]]; then
      warn '模型列表读取失败，未改动任何接口'
      return 1
    fi
    printf '模型列表不能证明推理能力；可以手填准确模型原名，保存前仍会执行实际推理验证。\n'
    menu_read choice '手动模型原名（0 或回车取消）：' || return 1
    [[ -n "$choice" && "$choice" != 0 ]] || return 2
    jq -M --arg model "$choice" '.provider.model=$model' "$candidate" > "$candidate.new" || return 1
    mv -f -- "$candidate.new" "$candidate"; return 0
  done
  jq -M '[.models[] | select(type=="string")] | unique' "$models_file" > "$models_file.ids" || return 1
  while true; do
    jq -M --arg query "$query" '[.[] | select(contains($query))]' "$models_file.ids" > "$models_file.filtered" || return 1
    total=$(jq -M 'length' "$models_file.filtered")
    (( total > 0 )) || { warn '没有匹配模型；返回后可手动填写'; return 2; }
    start=$((page*15)); (( start < total )) || { page=0; start=0; }
    jq -M -r --argjson start "$start" '.[$start:$start+15] | to_entries[] | "\(.key+1). \(.value)"' "$models_file.filtered"
    menu_read choice '选择模型（数字）：1～15 本页模型 / 16 下一页 / 17 上一页 / 18 搜索 / 19 手填 / 0 返回：' || return 1
    case "$choice" in
      0|'') return 2 ;;
      16) page=$((page+1)) ;;
      17) if (( page>0 )); then page=$((page-1)); fi ;;
      18) menu_read query '搜索模型名称（回车显示全部）：' || return 1; page=0 ;;
      19)
        menu_read choice '手动模型原名（0 或回车返回）：' || return 1
        [[ -n "$choice" && "$choice" != 0 ]] || continue
        jq -M --arg model "$choice" '.provider.model=$model' "$candidate" > "$candidate.new" || return 1
        mv -f -- "$candidate.new" "$candidate"; return 0 ;;
      *)
        if [[ "$choice" =~ ^[1-9][0-9]?$ ]] && (( 10#$choice <= 15 && start+10#$choice <= total )); then
          jq -M --slurpfile models "$models_file.filtered" --argjson index "$((start+10#$choice-1))" '.provider.model=$models[0][$index]' \
            "$candidate" > "$candidate.new" || return 1
          mv -f -- "$candidate.new" "$candidate"; return 0
        fi
        warn '请选择本页有效数字' ;;
    esac
  done
}

provider_field_write() {
  local candidate=$1 field=$2 value=$3 secret
  manager_temporary || return 1; secret=$MANAGE_FILE
  printf '%s' "$value" > "$secret"
  if [[ "$field" == api_key ]]; then
    jq -M --rawfile value "$secret" '.api_key=$value' "$candidate" > "$candidate.new" || return 1
  else
    jq -M --arg field "$field" --rawfile value "$secret" '.provider[$field]=$value' "$candidate" > "$candidate.new" || return 1
  fi
  rm -f -- "$secret"
  mv -f -- "$candidate.new" "$candidate"
}

provider_edit_menu() {
  local id=$1 draft=${2:-0} candidate choice value field header secret
  provider_candidate "$id" "$draft" || return 1; candidate=$PROVIDER_CANDIDATE
  if [[ "$id" == new ]]; then
    for field in name base_url api_key; do
      case "$field" in name) value='备用接口显示名称' ;; base_url) value='备用接口地址' ;; api_key) value='备用接口密钥（隐藏输入）' ;; esac
      menu_read value "$value（0 取消）：" "$([[ "$field" == api_key ]] && printf 1 || printf 0)" || return 1
      [[ -n "$value" && "$value" != 0 ]] || { printf '已取消添加备用接口。\n'; return 0; }
      provider_field_write "$candidate" "$field" "$value" || return 1; unset value
    done
  fi
  while (( MANAGE_EOF == 0 )); do
    if (( draft )); then printf '正在补全导入草稿；保存只验证候选，不会替换当前有效主备接口。\n'; fi
    printf '\n本次修改仅写入候选；确认保存前不会改变主接口或备用接口。\n'
    python3 "$SCRIPT_DIR/scripts/menu-display.py" detail "$candidate" /dev/null 0
    printf '1. 修改显示名称\n2. 修改接口地址\n3. 替换密钥\n4. 获取并选择模型\n5. 手动填写模型\n6. 请求协议与图片能力\n7. 自定义请求头\n8. 上下文与输出限制\n9. 验证并保存整组修改\n0. 取消并返回\n'
    menu_read choice '请选择：' || return 1
    case "$choice" in
      1|2|3|5)
        case "$choice" in 1) field=name; value='显示名称' ;; 2) field=base_url; value='接口地址' ;; 3) field=api_key; value='新 API Key（隐藏输入，回车保留）' ;; 5) field=model; value='准确模型名称' ;; esac
        menu_read value "$value（0 取消本项）：" "$([[ "$field" == api_key ]] && printf 1 || printf 0)" || return 1
        [[ -n "$value" && "$value" != 0 ]] || continue
        provider_field_write "$candidate" "$field" "$value" || return 1; unset value ;;
      4)
        if (( draft )); then
          printf '导入草稿请用 5 手填提供方模型原名，保存时实际验证；不会借用当前主接口获取列表。\n'
        elif provider_model_select "$candidate" "$id"; then printf '模型已写入本次候选；选择 9 才验证保存。\n'; fi ;;
      6)
        menu_read value '1 聊天接口（Chat Completions）/ 2 响应接口（Responses）/ 3 启用图片能力 / 4 关闭图片能力 / 0 返回：' || return 1
        case "$value" in
          1|2)
            if [[ "$value" == 1 ]]; then value=chat_completions; else value=responses; fi
            provider_field_write "$candidate" api_mode "$value" || return 1 ;;
          3|4)
            if [[ "$value" == 3 ]]; then value=true; else value=false; fi
            jq -M --argjson value "$value" '.provider.capabilities.vision=$value' "$candidate" > "$candidate.new" || return 1
            mv -f -- "$candidate.new" "$candidate"
            printf '图片能力已写入候选；保存时会按所选协议验证，失败不应用。\n' ;;
          *) continue ;;
        esac ;;
      7)
        menu_read header '请求头名称（0 或回车返回；不能覆盖受管协议头）：' || return 1
        [[ -n "$header" && "$header" != 0 ]] || continue
        menu_read choice '1 修改此请求头 / 2 删除此请求头 / 0 返回：' || return 1
        case "$choice" in
          1)
            menu_read value '请求头值（隐藏输入，回车保留）：' 1 || return 1; [[ -n "$value" ]] || continue
            manager_temporary || return 1; secret=$MANAGE_FILE; printf '%s' "$value" > "$secret"; unset value
            jq -M --arg name "$header" --rawfile value "$secret" '.provider.custom_headers[$name]=$value | if .provider.remove_header==$name then del(.provider.remove_header) else . end' "$candidate" > "$candidate.new" || return 1
            rm -f -- "$secret" ;;
          2) jq -M --arg name "$header" '.provider.remove_header=$name | del(.provider.custom_headers[$name])' "$candidate" > "$candidate.new" || return 1 ;;
          *) continue ;;
        esac
        mv -f -- "$candidate.new" "$candidate" ;;
      8)
        menu_read choice '1 上下文长度 / 2 最大输出长度 / 0 返回：' || return 1
        case "$choice" in 1) field=context_window ;; 2) field=max_output_tokens ;; *) continue ;; esac
        menu_read value '服务商支持的正整数（0 或回车保留）：' || return 1
        [[ "$value" =~ ^[1-9][0-9]{0,8}$ ]] || continue
        jq -M --arg field "$field" --argjson value "$value" '.provider[$field]=$value' "$candidate" > "$candidate.new" || return 1
        mv -f -- "$candidate.new" "$candidate" ;;
      9)
        printf '将针对当前候选接口进行少量合成请求验证，可能产生费用；失败保留旧整组。\n'
        if menu_confirm '验证并保存此接口？'; then
          if (( draft )); then manager_action manager_tool provider edit-draft "$id" "$candidate"
          elif [[ "$id" == new ]]; then manager_action manager_tool provider add "$candidate"
          else manager_action manager_tool provider edit "$id" "$candidate"; fi
          if (( MANAGER_ACTION_STATUS == 0 )); then return 0; fi
          printf '验证未通过，候选仍保留在本次编辑页；可以修正或数字 0 取消。\n'
        fi ;;
      0) printf '已取消候选修改，原接口保持不变。\n'; return ;;
      *) warn '请输入有效数字' ;;
    esac
  done
}

provider_policy_menu() {
  local choice value candidate field file
  local -a fields=(question_timeout_ms call_timeout_ms connect_timeout_ms max_attempts cooldown_initial_ms cooldown_max_ms pool_cooldown_ms)
  manager_temporary || return 1; candidate=$MANAGE_FILE
  manager_tool provider policy > "$candidate" || return 1
  jq -M '.policy' "$candidate" > "$candidate.new" || return 1
  mv -f -- "$candidate.new" "$candidate"
  printf '\n1. 问题总期限（1000～180000 毫秒）\n2. 单次请求期限（1000～60000 毫秒）\n3. 连接期限（100～10000 毫秒）\n4. 每问题最多调用次数（1～21）\n5. 初始冷却（1000～300000 毫秒）\n6. 最长冷却（1000～3600000 毫秒）\n7. 全池冷却（100～60000 毫秒）\n8. 查看主备资料文件路径\n9. 校验并应用已编辑的主备资料\n10. 导入不含密钥的主备结构\n11. 查看、补全或应用导入草稿\n12. 恢复中断的知识上下文配置\n0. 返回\n连接期限不能超过单次期限，单次不能超过问题总期限；初始冷却不能超过最长冷却。\n'
  python3 "$SCRIPT_DIR/scripts/menu-display.py" detail "$candidate" /dev/null 0
  menu_read choice '修改哪一项：' || return 1
  case "$choice" in
    8)
      printf '可编辑的非敏感主备资料：%s/config/provider-pool.yaml\n受管有效资料：%s/config/provider-pool-applied.json（不可手改）\n导入草稿：%s/config/provider-pool-import-draft.json（用菜单补全）\n接口密钥仅由受管秘密文件保存，不要粘入上述文件或公开它们。\n' "$DEPLOY_DIR" "$DEPLOY_DIR" "$DEPLOY_DIR"
      return 0 ;;
    9)
      file="$DEPLOY_DIR/config/provider-pool.yaml"
      if ! manager_result manager_tool provider validate-file "$file"; then return 1; fi
      printf '校验通过只表示原文格式可用；应用会验证有变动的接口，可能产生少量费用，失败保留旧有效池。\n'
      if menu_confirm '应用这份完整主备资料？'; then manager_action manager_tool provider apply-file "$file"; fi
      return 0 ;;
    10)
      menu_read file '不含密钥的主备结构文件路径（0 或回车返回）：' || return 1
      [[ -n "$file" && "$file" != 0 ]] || return 0
      printf '同一接口保留本机密钥；新备用缺密钥会停用。陌生主接口只能暂存草稿，当前有效池不变。\n'
      printf '完整可用的候选可能发出少量验证请求，确认前请核对路径与来源。\n'
      if menu_confirm '导入这份主备结构？'; then manager_action manager_tool provider import "$file"; fi
      return 0 ;;
    11) provider_draft_menu; return $? ;;
    12)
      printf '仅恢复已中断的主备知识预算事务；可能重建本实例 AnythingLLM，不清空知识和人工状态。正在运行的应用操作不会被强行覆盖。\n'
      if menu_confirm '恢复上一份成套主备配置并核对运行状态？'; then
        manager_action manager_tool provider recover-rag-context
      fi
      return 0 ;;
  esac
  [[ "$choice" =~ ^[1-7]$ ]] || return 0; field=${fields[choice-1]}
  menu_read value '新的正整数（0 或回车取消）：' || return 1
  [[ "$value" =~ ^[1-9][0-9]{0,8}$ ]] || return 0
  jq -M --arg field "$field" --argjson value "$value" '.[$field]=$value' "$candidate" > "$candidate.new" || return 1
  mv -f -- "$candidate.new" "$candidate"
  if menu_confirm '保存整组主备策略？'; then manager_action manager_tool provider policy "$candidate"; fi
}

provider_draft_menu() {
  local choice
  while (( MANAGE_EOF == 0 )); do
    printf '\n草稿保存不等于应用；以本次实际回执与主备有效列表为准。\n1. 查看导入草稿\n2. 补全所选草稿接口\n3. 验证并应用整份导入草稿\n0. 返回\n'
    menu_read choice '请选择：' || return 1
    case "$choice" in
      1) manager_action manager_tool provider draft ;;
      2) provider_select all draft || continue; manager_action provider_edit_menu "$PROVIDER_SELECTED" 1 ;;
      3)
        printf '将验证所有启用接口，可能产生少量费用；缺密钥备用仍保持停用。成功后整体替换当前主备结构。\n'
        if menu_confirm '验证并应用导入草稿？'; then
          manager_action manager_tool provider apply-draft
          if (( MANAGER_ACTION_STATUS == 0 )); then return 0; fi
        fi ;;
      0) return 0 ;; *) warn '请输入有效数字' ;;
    esac
  done
}

ai_config_menu() {
  local choice id value order candidate action
  while (( MANAGE_EOF == 0 )); do
    printf '\n1. 查看主备接口列表\n2. 配置主接口\n3. 添加备用接口\n4. 编辑接口或模型\n5. 调整备用顺序\n6. 启用或停用备用接口\n7. 设置主接口（原主自动转备用）\n8. 删除备用接口\n9. 显式测试指定接口\n10. 主备切换策略\n11. 查看近期切换记录\n0. 返回\n'
    menu_read choice '请选择：' || return
    case "$choice" in
      1) manager_action provider_status_view ;;
      2)
        provider_pool_read || continue; id=$(jq -M -r '.primary_id' "$PROVIDER_POOL")
        manager_action provider_edit_menu "$id" ;;
      3)
        provider_pool_read || continue
        if (( $(jq -M '.entries|length' "$PROVIDER_POOL") >= 21 )); then
          warn '已达到 1 主接口与 20 备用接口上限；停用项也占名额，请先删除不再使用的备用接口'
          continue
        fi
        manager_action provider_edit_menu new ;;
      4) provider_select || continue; manager_action provider_edit_menu "$PROVIDER_SELECTED" ;;
      5)
        provider_pool_read || continue
        jq -M '[.entries[]|select(.role=="backup")]' "$PROVIDER_POOL" > "$PROVIDER_POOL.backups"
        if [[ $(jq -M length "$PROVIDER_POOL.backups") == 0 ]]; then printf '没有备用接口，单接口配置无需排序。\n'; continue; fi
        jq -M -r 'to_entries[]|"\(.key+1). \(.value.name)"' "$PROVIDER_POOL.backups"
        menu_read order '按期望顺序填写全部备用序号，逗号分隔（0 或回车取消）：' || return
        [[ -n "$order" && "$order" != 0 ]] || continue
        candidate="$PROVIDER_POOL.order"
        if ! jq -M -e --arg order "$order" 'length as $count | . as $entries |
          ($order|split(",")|map(gsub("^\\s+|\\s+$";""))) as $tokens |
          select(all($tokens[]; test("^[1-9][0-9]*$"))) | ($tokens|map(tonumber)) as $numbers |
          select(($numbers|length)==$count and ($numbers|unique|length)==$count and all($numbers[]; .<=$count)) |
          {ids:[$numbers[]|$entries[.-1].id]}' "$PROVIDER_POOL.backups" > "$candidate"; then warn '需要每个备用序号恰好出现一次'; continue; fi
        if menu_confirm '保存上述备用顺序？'; then manager_action manager_tool provider order "$candidate"; fi ;;
      6|7|8|9)
        if [[ "$choice" == 6 || "$choice" == 8 ]]; then provider_select backup || continue
        else provider_select || continue; fi
        id=$PROVIDER_SELECTED
        case "$choice" in
          6) menu_read value '1 启用 / 2 停用 / 0 返回：' || return
            case "$value" in 1) value=true ;; 2) value=false ;; *) continue ;; esac
            if menu_confirm '修改所选备用接口状态？'; then manager_action manager_tool provider enable "$id" "$value"; fi ;;
          7) if menu_confirm '将所选接口启用并设为主接口，原主接口转为备用？'; then manager_action manager_tool provider primary "$id"; fi ;;
          8) if menu_confirm '删除所选备用接口？其他接口保持不变。'; then manager_action manager_tool provider delete "$id"; fi ;;
          9) menu_read action '1 测试文本 / 2 测试图片 / 0 返回：' || return
            case "$action" in 1) action='test' ;; 2) action=vision-test ;; *) continue ;; esac
            printf '测试会发出少量合成模型请求，可能产生费用；不向客户发送消息。\n'
            if menu_confirm '测试所选接口？'; then manager_action manager_tool provider "$action" "$id"; fi ;;
        esac ;;
      10) manager_action provider_policy_menu ;;
      11) manager_action manager_tool provider recent ;;
      0) return ;; *) warn '请输入有效数字' ;;
    esac
  done
}
