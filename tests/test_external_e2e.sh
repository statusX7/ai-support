#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

skip() {
  printf '跳过：%s\n' "$1" >&2
  exit 77
}

fail() {
  printf '失败：外部 E2E：%s\n' "$1" >&2
  exit 1
}

[[ "${AI_SUPPORT_E2E_ENABLE:-0}" == 1 ]] \
  || skip "未设置 AI_SUPPORT_E2E_ENABLE=1。"
[[ "${AI_SUPPORT_E2E_CONFIRM_DEDICATED:-}" == YES ]] \
  || skip "未确认使用隔离测试环境（AI_SUPPORT_E2E_CONFIRM_DEDICATED=YES）。"

REQUIRED_ENV=(
  AI_SUPPORT_E2E_DEPLOY_DIR
  AI_SUPPORT_E2E_TEXT_SESSION_ID
  AI_SUPPORT_E2E_HANDOFF_SESSION_ID
  AI_SUPPORT_E2E_IMAGE_URL
  AI_SUPPORT_E2E_IMAGE_EXPECTED_FACT
)
MISSING_ENV=()
for variable_name in "${REQUIRED_ENV[@]}"; do
  [[ -n "${!variable_name:-}" ]] || MISSING_ENV+=("$variable_name")
done
if (( ${#MISSING_ENV[@]} > 0 )); then
  skip "缺少环境变量：${MISSING_ENV[*]}。"
fi

for command_name in curl jq python3 realpath base64 sha256sum docker; do
  command -v "$command_name" >/dev/null 2>&1 || skip "缺少命令 ${command_name}。"
done

safe_credential() {
  local value=$1
  [[ -n "$value" && ${#value} -le 4096 && "$value" != *$'\n'* && "$value" != *$'\r'* ]]
}

safe_base_url() {
  local value=$1
  [[ "$value" =~ ^https?://[^/?#@]+(:[0-9]{1,5})?(/[^?#]*)?$ \
    && "$value" != *'/../'* && "$value" != *'/./'* ]]
}

DEPLOY_DIR=$(realpath -e -- "$AI_SUPPORT_E2E_DEPLOY_DIR")
[[ -d "$DEPLOY_DIR" && ! -L "$DEPLOY_DIR" ]] || fail "部署目录无效"
[[ -f "${DEPLOY_DIR}/.crisp-ai-installation" \
  && ! -L "${DEPLOY_DIR}/.crisp-ai-installation" ]] || fail "部署目录缺少安装标记"
grep -Eq '^state=(ready|local-ready)$' "${DEPLOY_DIR}/.crisp-ai-installation" \
  || fail "部署尚未完成本地安装"
[[ -f "${DEPLOY_DIR}/scripts/analytics.sh" ]] || fail "部署缺少统计脚本"
# Installed credentials are authoritative. No second set of 10+ secrets is needed.
# shellcheck source=scripts/common.sh
source "${PROJECT_ROOT}/scripts/common.sh"
[[ $EUID == 0 ]] || fail "请以 root 运行隔离实例验收，不能读取其他用户的秘密配置"
assert_installation "$DEPLOY_DIR"
ENV_FILE="${DEPLOY_DIR}/.env"
AI_SUPPORT_E2E_ANYTHINGLLM_API_KEY=$(env_get "$ENV_FILE" ANYTHINGLLM_API_KEY)
AI_SUPPORT_E2E_CRISP_TOKEN_IDENTIFIER=$(env_get "$ENV_FILE" CRISP_TOKEN_IDENTIFIER)
AI_SUPPORT_E2E_CRISP_TOKEN_KEY=$(env_get "$ENV_FILE" CRISP_TOKEN_KEY)

ANYTHING_BASE="http://127.0.0.1:$(env_get "$ENV_FILE" ANYTHINGLLM_PORT)"
ANYTHING_WORKSPACE=$(env_get "$ENV_FILE" ANYTHINGLLM_WORKSPACE)
CRISP_WEBSITE_ID=$(env_get "$ENV_FILE" CRISP_WEBSITE_ID)
CRISP_TIER=$(env_get "$ENV_FILE" CRISP_TOKEN_TIER)
TEXT_SESSION=$AI_SUPPORT_E2E_TEXT_SESSION_ID
OPERATOR_SESSION=${AI_SUPPORT_E2E_OPERATOR_SESSION_ID:-$TEXT_SESSION}
HANDOFF_SESSION=$AI_SUPPORT_E2E_HANDOFF_SESSION_ID
IMAGE_SESSION=${AI_SUPPORT_E2E_IMAGE_SESSION_ID:-$HANDOFF_SESSION}
IMAGE_URL=$AI_SUPPORT_E2E_IMAGE_URL
IMAGE_EXPECTED_FACT=$AI_SUPPORT_E2E_IMAGE_EXPECTED_FACT
TIMEOUT_SECONDS=${AI_SUPPORT_E2E_TIMEOUT_SECONDS:-180}
SETTLE_SECONDS=${AI_SUPPORT_E2E_SETTLE_SECONDS:-20}

safe_base_url "$ANYTHING_BASE" || fail "AnythingLLM Base URL 格式无效"
[[ "$IMAGE_URL" =~ ^https://[^/?#@]+/.+ ]] || fail "图片 URL 必须是 HTTPS"
[[ "$IMAGE_EXPECTED_FACT" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{5,127}$ ]] \
  || fail "图片预期事实标识必须是 6 到 128 位安全字符"
# 隔离测试图片必须清晰展示该唯一标识；脚本只比较标识，不输出图片或回复正文。
[[ "$ANYTHING_WORKSPACE" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || fail "AnythingLLM 工作区无效"
[[ "$CRISP_WEBSITE_ID" =~ ^[A-Za-z0-9-]{8,128}$ ]] || fail "Crisp Website ID 无效"
[[ "$CRISP_TIER" == website || "$CRISP_TIER" == plugin ]] || fail "Crisp Token tier 无效"
[[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ && "$SETTLE_SECONDS" =~ ^[0-9]+$ ]] \
  || fail "等待时间必须是整数"
(( TIMEOUT_SECONDS >= 30 && TIMEOUT_SECONDS <= 900 )) || fail "超时时间必须为 30 到 900 秒"
(( SETTLE_SECONDS >= 5 && SETTLE_SECONDS <= 120 )) || fail "稳定观察时间必须为 5 到 120 秒"
for credential in \
  "$AI_SUPPORT_E2E_ANYTHINGLLM_API_KEY" \
  "$AI_SUPPORT_E2E_CRISP_TOKEN_IDENTIFIER" \
  "$AI_SUPPORT_E2E_CRISP_TOKEN_KEY"; do
  safe_credential "$credential" || fail "凭据包含不安全字符或为空"
done

SESSIONS=("$TEXT_SESSION" "$OPERATOR_SESSION" "$HANDOFF_SESSION" "$IMAGE_SESSION")
for session_id in "${SESSIONS[@]}"; do
  [[ "$session_id" =~ ^session_[A-Za-z0-9-]{8,128}$ ]] || fail "Crisp 测试 session_id 格式无效"
done
[[ "$TEXT_SESSION" != "$HANDOFF_SESSION" ]] || fail "A/B 两个隔离测试会话必须不同"

umask 077
mkdir -p "${PROJECT_ROOT}/.work"
TEST_ROOT=$(mktemp -d "${PROJECT_ROOT}/.work/external-e2e.XXXXXX")
ANYTHING_CONFIG="${TEST_ROOT}/anythingllm.curl"
CRISP_CONFIG="${TEST_ROOT}/crisp.curl"
CRISP_AUTH=$(printf '%s' "${AI_SUPPORT_E2E_CRISP_TOKEN_IDENTIFIER}:${AI_SUPPORT_E2E_CRISP_TOKEN_KEY}" \
  | base64 | tr -d '\n')
printf 'Authorization: Bearer %s' "$AI_SUPPORT_E2E_ANYTHINGLLM_API_KEY" \
  | jq -Rs '"header = " + tojson' -r > "$ANYTHING_CONFIG"
printf 'header = "Authorization: Basic %s"\nheader = "X-Crisp-Tier: %s"\nheader = "Content-Type: application/json"\n' \
  "$CRISP_AUTH" "$CRISP_TIER" > "$CRISP_CONFIG"
chmod 600 "$ANYTHING_CONFIG" "$CRISP_CONFIG"
unset CRISP_AUTH

HTTP_STATUS=000
HTTP_BODY=''
ORIGINAL_HANDOFF_SEGMENTS=''
RESTORE_HANDOFF_SEGMENTS=0
EMBEDDED_LOCATIONS=()
RESTORE_TEST_CONFIGURATION=0

runtime_command() {
  docker_compose "$DEPLOY_DIR" exec -T n8n node /opt/crisp-ai/n8n/runtime-cli.js "$@"
}

session_mode() {
  runtime_command list | jq -r --arg website "$CRISP_WEBSITE_ID" --arg session "$1" \
    'map(select(.website_id == $website and .session_id == $session)) | first | .mode // "ai"'
}

resume_test_session() {
  local key
  key=$(runtime_command list | jq -r --arg website "$CRISP_WEBSITE_ID" --arg session "$1" \
    'map(select(.website_id == $website and .session_id == $session)) | first | .key // empty')
  [[ -z "$key" ]] || runtime_command resume "$key" >/dev/null
}

http_request() {
  local config_file=$1
  local method=$2
  local url=$3
  local payload=${4-}
  local upload_file=${5-}
  local raw
  if [[ -n "$upload_file" ]]; then
    if ! raw=$(curl --silent --connect-timeout 10 --max-time "$TIMEOUT_SECONDS" \
      --config "$config_file" --request "$method" --form "file=@${upload_file}" \
      --write-out $'\n%{http_code}' "$url"); then
      HTTP_STATUS=000
      HTTP_BODY=''
      return 1
    fi
  elif [[ -n "$payload" ]]; then
    if ! raw=$(printf '%s' "$payload" | curl --silent --connect-timeout 10 \
      --max-time "$TIMEOUT_SECONDS" --config "$config_file" --request "$method" \
      --header 'Content-Type: application/json' --data-binary @- --write-out $'\n%{http_code}' "$url"); then
      HTTP_STATUS=000
      HTTP_BODY=''
      return 1
    fi
  else
    if ! raw=$(curl --silent --connect-timeout 10 --max-time "$TIMEOUT_SECONDS" \
      --config "$config_file" --request "$method" --write-out $'\n%{http_code}' "$url"); then
      HTTP_STATUS=000
      HTTP_BODY=''
      return 1
    fi
  fi
  HTTP_STATUS=${raw##*$'\n'}
  HTTP_BODY=${raw%$'\n'*}
  [[ "$HTTP_STATUS" =~ ^[0-9]{3}$ ]]
}

expect_success() {
  local label=$1
  [[ "$HTTP_STATUS" == 2?? ]] || fail "${label}失败（HTTP ${HTTP_STATUS}）"
}

anything_request() {
  http_request "$ANYTHING_CONFIG" "$1" "${ANYTHING_BASE}$2" "${3-}" "${4-}"
}

crisp_request() {
  http_request "$CRISP_CONFIG" "$1" "https://api.crisp.chat/v1/website/${CRISP_WEBSITE_ID}$2" "${3-}"
}

crisp_send_text() {
  local session_id=$1
  local from=$2
  local content=$3
  local fingerprint=$4
  local body
  body=$(jq -cn --arg from "$from" --arg content "$content" --argjson fingerprint "$fingerprint" \
    '{type:"text",from:$from,origin:"chat",content:$content,fingerprint:$fingerprint,automated:false}')
  crisp_request POST "/conversation/${session_id}/message" "$body" \
    || fail "Crisp 文本消息请求失败"
  expect_success "Crisp 文本消息"
  unset HTTP_BODY
}

crisp_send_image() {
  local session_id=$1
  local image_url=$2
  local fingerprint=$3
  local body
  body=$(jq -cn --arg url "$image_url" --argjson fingerprint "$fingerprint" \
    '{type:"file",from:"user",origin:"chat",content:{type:"image/png",name:"e2e-image.png",url:$url},fingerprint:$fingerprint,automated:false}')
  crisp_request POST "/conversation/${session_id}/message" "$body" \
    || fail "Crisp 图片消息请求失败"
  expect_success "Crisp 图片消息"
  unset HTTP_BODY
}

crisp_message_snapshot() {
  local session_id=$1
  crisp_request GET "/conversation/${session_id}/messages" \
    || fail "读取 Crisp conversation 消息失败"
  expect_success "读取 Crisp conversation 消息"
  jq -e '(.data | type) == "array"' <<< "$HTTP_BODY" >/dev/null \
    || fail "Crisp 消息响应格式无效"
}

ai_reply_count() {
  local session_id=$1
  crisp_message_snapshot "$session_id"
  jq '[.data[]? | select(.from == "operator" and ((.automated == true) or (.properties.ai_support == true) or ((.properties.ai_support_version // "") != "")))] | length' \
    <<< "$HTTP_BODY"
  unset HTTP_BODY
}

wait_for_ai_count() {
  local session_id=$1
  local expected=$2
  local started=$SECONDS
  local current
  while (( SECONDS - started < TIMEOUT_SECONDS )); do
    current=$(ai_reply_count "$session_id")
    if (( current >= expected )); then
      return 0
    fi
    sleep 3
  done
  fail "等待 Crisp AI 回复超时"
}

latest_ai_reply_contains() {
  local session_id=$1
  local expected_text=$2
  local minimum_count=$3
  local match_status=0
  crisp_message_snapshot "$session_id"
  jq -e --arg expected "$expected_text" --argjson minimum "$minimum_count" '
    [.data[]? | select(
      .from == "operator" and
      ((.automated == true) or (.properties.ai_support == true) or
       ((.properties.ai_support_version // "") != "")))] as $replies
    | ($replies | length) >= $minimum and
      (($replies
        | sort_by(((.timestamp | tonumber?) // 0), ((.fingerprint // "") | tostring))
        | last
        | ((.content // "") | tostring)) as $latest
       | $latest | contains($expected))
  ' <<< "$HTTP_BODY" >/dev/null || match_status=$?
  unset HTTP_BODY
  return "$match_status"
}

wait_for_latest_ai_content() {
  local session_id=$1
  local expected_text=$2
  local minimum_count=$3
  local started=$SECONDS
  while (( SECONDS - started < TIMEOUT_SECONDS )); do
    latest_ai_reply_contains "$session_id" "$expected_text" "$minimum_count" && return 0
    sleep 3
  done
  fail "Crisp 最新 AI 回复未包含预期的非敏感测试标识"
}

latest_ai_reply_is_safe() {
  local session_id=$1
  local expected_fact=$2
  local minimum_count=$3
  local configured_failure=$4
  crisp_message_snapshot "$session_id"
  jq -e --arg expected "$expected_fact" --arg configured_failure "$configured_failure" \
    --argjson minimum "$minimum_count" '
    [.data[]? | select(
      .from == "operator" and
      ((.automated == true) or (.properties.ai_support == true) or
       ((.properties.ai_support_version // "") != "")))] as $replies
    | ($replies | length) >= $minimum and
      (($replies
        | sort_by(((.timestamp | tonumber?) // 0), ((.fingerprint // "") | tostring))
        | last
        | ((.content // "") | tostring)) as $reply
       | ($reply | length) > 0 and
         ($reply | contains($expected)) and
         ([
           "图片地址未通过安全校验",
           "请重新上传图片",
           "不支持图片理解",
           "切换为支持视觉的模型",
           "自动客服暂时不可用",
           "请稍后再试",
           $configured_failure
         ] | map(select(length > 0))
           | all(. as $failure_text | ($reply | contains($failure_text) | not))))
  ' <<< "$HTTP_BODY" >/dev/null
  local status=$?
  unset HTTP_BODY
  return "$status"
}

crisp_segments() {
  local session_id=$1
  crisp_request GET "/conversation/${session_id}/meta" || fail "读取 Crisp 标签失败"
  expect_success "读取 Crisp 标签"
  jq -ce '(.data.segments // .segments // []) | if type == "array" then map(tostring) else error("segments") end' \
    <<< "$HTTP_BODY" || fail "Crisp 标签响应格式无效"
  unset HTTP_BODY
}

set_crisp_segments() {
  local session_id=$1
  local segments=$2
  local body
  body=$(jq -cn --argjson segments "$segments" '{segments:$segments}')
  crisp_request PATCH "/conversation/${session_id}/meta" "$body" || fail "更新 Crisp 标签失败"
  expect_success "更新 Crisp 标签"
  unset HTTP_BODY
}

wait_for_segments() {
  local session_id=$1
  local preserved=$2
  local required_tag=$3
  local started=$SECONDS
  local segments
  while (( SECONDS - started < TIMEOUT_SECONDS )); do
    segments=$(crisp_segments "$session_id")
    if jq -e --arg preserved "$preserved" --arg required "$required_tag" \
      'index($preserved) != null and index($required) != null' <<< "$segments" >/dev/null; then
      return 0
    fi
    sleep 3
  done
  fail "Crisp 标签未按合并契约更新"
}

stats_snapshot() {
  local event_file="${DEPLOY_DIR}/data/analytics/events.jsonl"
  [[ -f "$event_file" && ! -L "$event_file" ]] || fail "匿名统计事件文件无效"
  jq -sc '[
    map(select(.type == "question")) | length,
    map(select(.type == "ai_reply")) | length,
    map(select(.type == "knowledge_hit")) | length,
    map(select(.type == "knowledge_miss")) | length,
    map(select(.type == "handoff")) | length
  ]' "$event_file" || fail "匿名统计事件格式无效"
}

cleanup() {
  local cleanup_payload
  set +e
  if (( RESTORE_HANDOFF_SEGMENTS )) && [[ -n "$ORIGINAL_HANDOFF_SEGMENTS" ]]; then
    cleanup_payload=$(jq -cn --argjson segments "$ORIGINAL_HANDOFF_SEGMENTS" '{segments:$segments}')
    crisp_request PATCH "/conversation/${HANDOFF_SESSION}/meta" "$cleanup_payload" >/dev/null 2>&1 || true
  fi
  if (( ${#EMBEDDED_LOCATIONS[@]} > 0 )); then
    cleanup_payload=$(printf '%s\n' "${EMBEDDED_LOCATIONS[@]}" \
      | jq -Rsc '{adds:[],deletes:(split("\n") | map(select(length > 0)))}')
    anything_request POST "/api/v1/workspace/${ANYTHING_WORKSPACE}/update-embeddings" \
      "$cleanup_payload" >/dev/null 2>&1
    cleanup_payload=$(printf '%s\n' "${EMBEDDED_LOCATIONS[@]}" \
      | jq -Rsc '{names:(split("\n") | map(select(length > 0)))}')
    anything_request DELETE '/api/v1/system/remove-documents' "$cleanup_payload" >/dev/null 2>&1
  fi
  if (( RESTORE_TEST_CONFIGURATION )); then
    for name in menu handoff; do
      bash "${DEPLOY_DIR}/scripts/configuration.sh" --deploy-dir "$DEPLOY_DIR" \
        apply "$name" --input "${TEST_ROOT}/${name}.original.json" >/dev/null 2>&1
    done
    for session_id in "${SESSIONS[@]}"; do resume_test_session "$session_id" >/dev/null 2>&1; done
  fi
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

printf '外部 E2E：开始校验 Provider 与 AnythingLLM（不会输出响应正文或凭据）。\n'
bash "${DEPLOY_DIR}/scripts/provider.sh" --deploy-dir "$DEPLOY_DIR" test >/dev/null \
  || fail "当前配置的 Provider 协议及应用容器调用失败"
jq -e '.enabled == true' "${DEPLOY_DIR}/config/runtime.yaml" >/dev/null \
  || fail "隔离实例的客服总开关未启用"
for session_id in "${SESSIONS[@]}"; do
  [[ "$(session_mode "$session_id")" == ai ]] || fail "隔离会话已处于人工模式，请先显式恢复后测试"
done
for name in menu handoff; do
  cp -- "${DEPLOY_DIR}/config/${name}.yaml" "${TEST_ROOT}/${name}.original.json"
done
RESTORE_TEST_CONFIGURATION=1
jq '.welcome.enabled = false' "${TEST_ROOT}/menu.original.json" > "${TEST_ROOT}/menu.test.json"
jq '.handoff.resume_after_seconds = 0' "${TEST_ROOT}/handoff.original.json" > "${TEST_ROOT}/handoff.test.json"
for name in menu handoff; do
  bash "${DEPLOY_DIR}/scripts/configuration.sh" --deploy-dir "$DEPLOY_DIR" \
    apply "$name" --input "${TEST_ROOT}/${name}.test.json" >/dev/null \
    || fail "隔离配置应用失败"
done
printf '外部 E2E：复用已安装凭据，临时关闭欢迎并设置不自动恢复，结束时恢复配置及测试会话。\n'

anything_request GET '/api/v1/auth' || fail "AnythingLLM API 鉴权请求失败"
expect_success "AnythingLLM API 鉴权"
jq -e '(.authenticated == true) or (.success == true)' <<< "$HTTP_BODY" >/dev/null \
  || fail "AnythingLLM API Key 无效"
unset HTTP_BODY
anything_request GET "/api/v1/workspace/${ANYTHING_WORKSPACE}" \
  || fail "AnythingLLM 工作区请求失败"
expect_success "AnythingLLM 工作区"
jq -e --arg workspace "$ANYTHING_WORKSPACE" '
  .workspace as $value |
  if ($value | type) == "array" then any($value[]; (.slug // .name // "") == $workspace)
  elif ($value | type) == "object" then ($value.slug // $value.name // "") == $workspace
  else false end
' <<< "$HTTP_BODY" >/dev/null || fail "AnythingLLM 工作区响应无效"
unset HTTP_BODY

NONCE="$(date -u '+%Y%m%d%H%M%S')-$RANDOM"
KB_MD="${TEST_ROOT}/e2e-${NONCE}.md"
KB_TXT="${TEST_ROOT}/e2e-${NONCE}.txt"
KB_PDF="${TEST_ROOT}/e2e-${NONCE}.pdf"
KB_DOCX="${TEST_ROOT}/e2e-${NONCE}.docx"
MD_MARKER="E2EMD${RANDOM}${RANDOM}"
TXT_MARKER="E2ETXT${RANDOM}${RANDOM}"
PDF_MARKER="E2EPDF${RANDOM}${RANDOM}"
DOCX_MARKER="E2EDOCX${RANDOM}${RANDOM}"
MD_ANSWER="ORBIT${RANDOM}${RANDOM}"
TXT_ANSWER="EMBER${RANDOM}${RANDOM}"
PDF_ANSWER="PINE${RANDOM}${RANDOM}"
DOCX_ANSWER="DELTA${RANDOM}${RANDOM}"
printf '# E2E knowledge\n\nThe answer for %s is %s.\n' "$MD_MARKER" "$MD_ANSWER" > "$KB_MD"
printf 'The answer for %s is %s.\n' "$TXT_MARKER" "$TXT_ANSWER" > "$KB_TXT"
python3 - "$KB_PDF" "The answer for ${PDF_MARKER} is ${PDF_ANSWER}." <<'PY'
import pathlib
import sys

target = pathlib.Path(sys.argv[1])
text = sys.argv[2].replace('\\', '\\\\').replace('(', '\\(').replace(')', '\\)')
stream = f"BT /F1 12 Tf 72 720 Td ({text}) Tj ET".encode('ascii')
objects = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
    b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
]
output = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
offsets = [0]
for index, obj in enumerate(objects, 1):
    offsets.append(len(output))
    output.extend(f"{index} 0 obj\n".encode('ascii'))
    output.extend(obj)
    output.extend(b"\nendobj\n")
xref = len(output)
output.extend(f"xref\n0 {len(objects) + 1}\n".encode('ascii'))
output.extend(b"0000000000 65535 f \n")
for offset in offsets[1:]:
    output.extend(f"{offset:010d} 00000 n \n".encode('ascii'))
output.extend(f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode('ascii'))
target.write_bytes(output)
PY
python3 - "$KB_DOCX" "The answer for ${DOCX_MARKER} is ${DOCX_ANSWER}." <<'PY'
import html
import pathlib
import sys
import zipfile

target = pathlib.Path(sys.argv[1])
text = html.escape(sys.argv[2])
content_types = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>'''
relationships = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>'''
document = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>{text}</w:t></w:r></w:p><w:sectPr/></w:body></w:document>'''
with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as archive:
    archive.writestr('[Content_Types].xml', content_types)
    archive.writestr('_rels/.rels', relationships)
    archive.writestr('word/document.xml', document)
PY
chmod 600 "$KB_MD" "$KB_TXT" "$KB_PDF" "$KB_DOCX"

KB_FILES=("$KB_MD" "$KB_TXT" "$KB_PDF" "$KB_DOCX")
KB_MARKERS=("$MD_MARKER" "$TXT_MARKER" "$PDF_MARKER" "$DOCX_MARKER")
KB_ANSWERS=("$MD_ANSWER" "$TXT_ANSWER" "$PDF_ANSWER" "$DOCX_ANSWER")
for knowledge_file in "${KB_FILES[@]}"; do
  anything_request POST '/api/v1/document/upload' '' "$knowledge_file" \
    || fail "AnythingLLM 文档上传失败"
  expect_success "AnythingLLM 文档上传"
  jq -e '.success == true' <<< "$HTTP_BODY" >/dev/null \
    || fail "AnythingLLM 文档上传响应未确认成功"
  mapfile -t uploaded < <(jq -r '(.documents // .data.documents // []) | .[]?.location | select(type == "string" and length > 0)' \
    <<< "$HTTP_BODY")
  (( ${#uploaded[@]} > 0 )) || fail "AnythingLLM 文档上传未返回位置"
  EMBEDDED_LOCATIONS+=("${uploaded[@]}")
  unset HTTP_BODY
done
EMBED_PAYLOAD=$(printf '%s\n' "${EMBEDDED_LOCATIONS[@]}" \
  | jq -Rsc '{adds:(split("\n") | map(select(length > 0))),deletes:[]}')
anything_request POST "/api/v1/workspace/${ANYTHING_WORKSPACE}/update-embeddings" "$EMBED_PAYLOAD" \
  || fail "AnythingLLM 文档索引请求失败"
expect_success "AnythingLLM 文档索引"
unset HTTP_BODY EMBED_PAYLOAD

for index in "${!KB_FILES[@]}"; do
  query_payload=$(jq -cn \
    --arg message "What is the answer for ${KB_MARKERS[index]}? Reply with the exact answer token." \
    --arg session "e2e-kb-${NONCE}-${index}" \
    '{message:$message,mode:"query",sessionId:$session}')
  query_ok=0
  query_started=$SECONDS
  while (( SECONDS - query_started < TIMEOUT_SECONDS )); do
    if anything_request POST "/api/v1/workspace/${ANYTHING_WORKSPACE}/chat" "$query_payload" \
      && [[ "$HTTP_STATUS" == 2?? ]] \
      && jq -e --arg expected "${KB_ANSWERS[index]}" '
        ((.textResponse // .text // .response // .data.textResponse // "") | tostring | contains($expected))
      ' <<< "$HTTP_BODY" >/dev/null; then
      query_ok=1
      unset HTTP_BODY
      break
    fi
    unset HTTP_BODY
    sleep 5
  done
  (( query_ok == 1 )) || fail "AnythingLLM 未能查询第 $((index + 1)) 种知识文件"
done
unset query_payload
printf '外部 E2E：Markdown、TXT、PDF、DOCX 真实上传、索引与查询通过。\n'

STATS_BEFORE=$(stats_snapshot)
read -r QUESTIONS_BEFORE REPLIES_BEFORE HITS_BEFORE MISSES_BEFORE HANDOFFS_BEFORE \
  < <(jq -r '@tsv' <<< "$STATS_BEFORE")

TEXT_BASELINE=$(ai_reply_count "$TEXT_SESSION")
DUPLICATE_FINGERPRINT=$((100000000 + RANDOM * 1000 + RANDOM % 1000))
TEXT_QUESTION="What is the answer for ${MD_MARKER}? Reply with the exact answer token."
crisp_send_text "$TEXT_SESSION" user "$TEXT_QUESTION" "$DUPLICATE_FINGERPRINT"
crisp_send_text "$TEXT_SESSION" user "$TEXT_QUESTION" "$DUPLICATE_FINGERPRINT"
wait_for_ai_count "$TEXT_SESSION" "$((TEXT_BASELINE + 1))"
wait_for_latest_ai_content "$TEXT_SESSION" "$MD_ANSWER" "$((TEXT_BASELINE + 1))"
sleep "$SETTLE_SECONDS"
[[ "$(ai_reply_count "$TEXT_SESSION")" == "$((TEXT_BASELINE + 1))" ]] \
  || fail "相同 Crisp fingerprint 产生了重复 AI 回复"
CONTEXT_FINGERPRINT=$((DUPLICATE_FINGERPRINT + 1))
crisp_send_text "$TEXT_SESSION" user \
  '上一条问题的准确答案标识是什么？请只回复该标识。' "$CONTEXT_FINGERPRINT"
wait_for_ai_count "$TEXT_SESSION" "$((TEXT_BASELINE + 2))"
wait_for_latest_ai_content "$TEXT_SESSION" "$MD_ANSWER" "$((TEXT_BASELINE + 2))"
printf '外部 E2E：文本、同 conversation 上下文与防重复通过。\n'

OPERATOR_BASELINE=$(ai_reply_count "$OPERATOR_SESSION")
crisp_send_text "$OPERATOR_SESSION" user \
  "What is the answer for ${TXT_MARKER}? Reply with the exact answer token." \
  "$((CONTEXT_FINGERPRINT + 100))"
wait_for_ai_count "$OPERATOR_SESSION" "$((OPERATOR_BASELINE + 1))"
wait_for_latest_ai_content "$OPERATOR_SESSION" "$TXT_ANSWER" "$((OPERATOR_BASELINE + 1))"
crisp_send_text "$OPERATOR_SESSION" operator "恢复AI" \
  "$((CONTEXT_FINGERPRINT + 101))"
handoff_wait_started=$SECONDS
while (( SECONDS - handoff_wait_started < TIMEOUT_SECONDS )); do
  current_stats=$(stats_snapshot)
  current_handoffs=$(jq -r '.[4]' <<< "$current_stats")
  (( current_handoffs > HANDOFFS_BEFORE )) && break
  sleep 3
done
(( current_handoffs > HANDOFFS_BEFORE )) || fail "operator 回复未触发人工接管统计"
crisp_send_text "$OPERATOR_SESSION" user \
  "AI must stay silent after operator ${NONCE}" "$((CONTEXT_FINGERPRINT + 102))"
sleep "$SETTLE_SECONDS"
[[ "$(ai_reply_count "$OPERATOR_SESSION")" == "$((OPERATOR_BASELINE + 1))" ]] \
  || fail "operator 主动回复后 AI 仍然自动回复"
printf '外部 E2E：operator 即使回复恢复关键词也关闭 AI 通过。\n'

HUMAN_TAG=$(jq -er '.tags.human_required | select(type == "string" and length > 0)' \
  "${DEPLOY_DIR}/config/tags.yaml") || fail "人工标签配置无效"
HANDOFF_RULE=$(jq -ce '[.rules[] | select(.enabled != false and .action == "show_handoff_offer")] | first // error("rule")' \
  "${DEPLOY_DIR}/config/keyword.yaml") || fail "请在隔离实例启用一条人工按钮规则"
HANDOFF_KEYWORD=$(jq -er '.keywords[0] | select(type == "string" and length > 0)' <<< "$HANDOFF_RULE")
HANDOFF_MESSAGE=$(jq -nr --argjson rule "$HANDOFF_RULE" --slurpfile control "${DEPLOY_DIR}/config/handoff.yaml" \
  '$rule.confirm_message // $control[0].handoff.message')
ORIGINAL_HANDOFF_SEGMENTS=$(crisp_segments "$HANDOFF_SESSION")
RESTORE_HANDOFF_SEGMENTS=1
PRESERVED_TAG="e2e-preserved-${NONCE}"
SEEDED_SEGMENTS=$(jq -cn --argjson existing "$ORIGINAL_HANDOFF_SEGMENTS" \
  --arg preserved "$PRESERVED_TAG" --arg human "$HUMAN_TAG" \
  '($existing | map(select(. != $human))) + [$preserved] | unique')
set_crisp_segments "$HANDOFF_SESSION" "$SEEDED_SEGMENTS"
HANDOFF_BASELINE=$(ai_reply_count "$HANDOFF_SESSION")
crisp_send_text "$HANDOFF_SESSION" user "$HANDOFF_KEYWORD" \
  "$((CONTEXT_FINGERPRINT + 200))"
wait_for_ai_count "$HANDOFF_SESSION" "$((HANDOFF_BASELINE + 1))"
[[ "$(session_mode "$HANDOFF_SESSION")" == ai ]] || fail "仅命中关键词就错误暂停 AI"
crisp_message_snapshot "$HANDOFF_SESSION"
OFFER_MESSAGE=$(jq -ce --arg label "$(jq -r '.confirm_label // "召唤人工客服"' <<< "$HANDOFF_RULE")" '
  [.data[] | select(.type == "picker" and .from == "operator" and
    ((.automated == true) or (.properties.ai_support == true)) and
    any(.content.choices[]?; .label == $label))] | sort_by(.timestamp) | last // error("picker")
' <<< "$HTTP_BODY") || fail "未收到本项目原生 picker"
unset HTTP_BODY
jq -e '.content.required != true' <<< "$OFFER_MESSAGE" >/dev/null || fail "卡片不应阻止普通聊天"
CURRENT_SEGMENTS=$(crisp_segments "$HANDOFF_SESSION")
jq -e --arg human "$HUMAN_TAG" 'index($human) == null' <<< "$CURRENT_SEGMENTS" >/dev/null \
  || fail "尚未点击按钮就添加了人工标签"
crisp_send_text "$HANDOFF_SESSION" user \
  "What is the answer for ${TXT_MARKER}? Reply with the exact answer token." \
  "$((CONTEXT_FINGERPRINT + 201))"
wait_for_ai_count "$HANDOFF_SESSION" "$((HANDOFF_BASELINE + 2))"
wait_for_latest_ai_content "$HANDOFF_SESSION" "$TXT_ANSWER" "$((HANDOFF_BASELINE + 2))"
[[ "$(session_mode "$HANDOFF_SESSION")" == ai ]] || fail "不点击继续提问时 AI 被暂停"
[[ "$(session_mode "$OPERATOR_SESSION")" == human ]] || fail "B 的正常问题改变了 A 的人工状态"
OFFER_FINGERPRINT=$(jq -r '.fingerprint' <<< "$OFFER_MESSAGE")
[[ "$OFFER_FINGERPRINT" =~ ^[0-9]+$ ]] || fail "卡片 fingerprint 无效"
CHOICE_PAYLOAD=$(jq -c '{content:(.content | .choices |= (to_entries | map(.value + {selected:(.key == 0)})))}' <<< "$OFFER_MESSAGE")
crisp_request PATCH "/conversation/${HANDOFF_SESSION}/message/${OFFER_FINGERPRINT}" "$CHOICE_PAYLOAD" \
  || fail "原生 picker 选择更新请求失败"
expect_success "picker 选择更新"
wait_for_ai_count "$HANDOFF_SESSION" "$((HANDOFF_BASELINE + 3))"
wait_for_latest_ai_content "$HANDOFF_SESSION" "$HANDOFF_MESSAGE" "$((HANDOFF_BASELINE + 3))"
[[ "$(session_mode "$HANDOFF_SESSION")" == human ]] || fail "有效按钮未暂停当前会话"
crisp_request PATCH "/conversation/${HANDOFF_SESSION}/message/${OFFER_FINGERPRINT}" "$CHOICE_PAYLOAD" \
  || fail "重复选择测试请求失败"
expect_success "重复选择更新"
wait_for_segments "$HANDOFF_SESSION" "$PRESERVED_TAG" "$HUMAN_TAG"
crisp_send_text "$HANDOFF_SESSION" user "AI must stay silent after confirmed handoff ${NONCE}" \
  "$((CONTEXT_FINGERPRINT + 202))"
sleep "$SETTLE_SECONDS"
[[ "$(ai_reply_count "$HANDOFF_SESSION")" == "$((HANDOFF_BASELINE + 3))" ]] \
  || fail "重复按钮确认或人工暂停期间仍有自动回复"
resume_test_session "$TEXT_SESSION"
RESUMED_BASELINE=$(ai_reply_count "$TEXT_SESSION")
crisp_send_text "$TEXT_SESSION" user "What is the answer for ${MD_MARKER}? Reply with the exact answer token." \
  "$((CONTEXT_FINGERPRINT + 203))"
wait_for_latest_ai_content "$TEXT_SESSION" "$MD_ANSWER" "$((RESUMED_BASELINE + 1))"
[[ "$(session_mode "$HANDOFF_SESSION")" == human ]] || fail "另一会话恢复影响了按钮人工会话"
printf '外部 E2E：关键词仅展示、真实选择更新、一次确认、两会话隔离与标签合并通过。\n'

resume_test_session "$IMAGE_SESSION"
IMAGE_BASELINE=$(ai_reply_count "$IMAGE_SESSION")
IMAGE_FAILURE_MESSAGE=$(jq -r '.handoff.failure_message // ""' \
  "${DEPLOY_DIR}/config/handoff.yaml") || fail "读取视觉失败提示配置失败"
crisp_send_image "$IMAGE_SESSION" "$IMAGE_URL" "$((CONTEXT_FINGERPRINT + 300))"
wait_for_ai_count "$IMAGE_SESSION" "$((IMAGE_BASELINE + 1))"
latest_ai_reply_is_safe "$IMAGE_SESSION" "$IMAGE_EXPECTED_FACT" "$((IMAGE_BASELINE + 1))" \
  "$IMAGE_FAILURE_MESSAGE" \
  || fail "真实图片理解未返回预先约定的唯一图片事实，或返回了安全/视觉失败提示"
unset IMAGE_FAILURE_MESSAGE
printf '外部 E2E：Crisp 图片消息与视觉 Provider 通过。\n'

stats_wait_started=$SECONDS
while (( SECONDS - stats_wait_started < TIMEOUT_SECONDS )); do
  STATS_AFTER=$(stats_snapshot)
  read -r QUESTIONS_AFTER REPLIES_AFTER HITS_AFTER MISSES_AFTER HANDOFFS_AFTER \
    < <(jq -r '@tsv' <<< "$STATS_AFTER")
  if (( QUESTIONS_AFTER >= QUESTIONS_BEFORE + 6 \
    && REPLIES_AFTER >= REPLIES_BEFORE + 6 \
    && HITS_AFTER > HITS_BEFORE \
    && HANDOFFS_AFTER >= HANDOFFS_BEFORE + 2 )); then
    break
  fi
  sleep 3
done
# Six actual inference questions: initial/context/operator/before-click/resumed/image.
# Keyword cards, clicks and human-paused questions are deliberately excluded.
(( QUESTIONS_AFTER >= QUESTIONS_BEFORE + 6 )) || fail "六个实际模型问题未进入统计"
(( REPLIES_AFTER >= REPLIES_BEFORE + 6 )) || fail "六个实际 AI 回复未进入统计"
(( HITS_AFTER > HITS_BEFORE )) || fail "知识库命中统计未增加"
(( HANDOFFS_AFTER >= HANDOFFS_BEFORE + 2 )) || fail "转人工统计未增加"
(( MISSES_AFTER >= MISSES_BEFORE )) || fail "知识库未命中统计发生倒退"

printf '外部 E2E：匿名统计增量通过。\n'
printf '外部 E2E 验收：通过（未输出消息正文、API 响应或凭据）。\n'
