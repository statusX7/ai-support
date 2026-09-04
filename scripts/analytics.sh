#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

DEPLOY_REQUEST=""
MODE=all
JSON_OUTPUT=0

usage() {
  cat <<'EOF'
用法：analytics.sh [knowledge|feedback|all] [--deploy-dir PATH] [--json]

输出匿名聚合指标。反馈问题只显示工作流脱敏并截断后的内容。
EOF
}

while (( $# > 0 )); do
  case "$1" in
    knowledge|feedback|all)
      MODE=$1
      shift
      ;;
    --deploy-dir)
      (( $# >= 2 )) || die "--deploy-dir 缺少参数"
      DEPLOY_REQUEST=$2
      shift 2
      ;;
    --json)
      JSON_OUTPUT=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *) die "未知选项：$1" ;;
  esac
done

DEPLOY_DIR=$(resolve_deploy_dir "$DEPLOY_REQUEST")
assert_installation "$DEPLOY_DIR"
require_command jq
EVENT_FILE="${DEPLOY_DIR}/data/analytics/events.jsonl"

if [[ -L "$EVENT_FILE" ]]; then
  die "统计事件文件不得是符号链接"
fi
if [[ ! -f "$EVENT_FILE" ]]; then
  EVENT_FILE=/dev/null
fi

SUMMARY=$(jq -nR '
  reduce inputs as $line (
    {
      total_questions: 0, ai_replies: 0, knowledge_hits: 0, knowledge_misses: 0,
      handoffs: 0, positive_feedback: 0, negative_feedback: 0,
      negative_questions: [], failure_counts: {}
    };
    ($line | fromjson) as $event |
    if ($event | type) != "object" then .
    elif $event.type == "question" then .total_questions += 1
    elif $event.type == "ai_reply" then .ai_replies += 1
    elif $event.type == "knowledge_hit" then .knowledge_hits += 1
    elif $event.type == "knowledge_miss" then .knowledge_misses += 1
    elif $event.type == "handoff" then .handoffs += 1
    elif $event.type == "feedback" and $event.feedback == "positive" then .positive_feedback += 1
    elif $event.type == "feedback" and $event.feedback == "negative" then
      .negative_feedback += 1 |
      .negative_questions = ((.negative_questions + [{
        at: ($event.at // ""), session: ($event.session // ""), question: ($event.question // "")
      }]) | if length > 20 then .[-20:] else . end) |
      if (($event.question // "") | length) > 0 then
        .failure_counts[$event.question] = ((.failure_counts[$event.question] // 0) + 1)
      else . end
    else . end
  ) |
  .hit_rate = (if .total_questions == 0 then 0 else ((.knowledge_hits * 10000 / .total_questions) | floor / 100) end) |
  .positive_rate = (if (.positive_feedback + .negative_feedback) == 0 then 0 else ((.positive_feedback * 10000 / (.positive_feedback + .negative_feedback)) | floor / 100) end) |
  .negative_questions |= reverse |
  .frequent_failures = (.failure_counts | to_entries | map({question: .key, count: .value}) | sort_by([-.count, .question]) | .[:10]) |
  del(.failure_counts)
' "$EVENT_FILE") || die "统计事件文件包含无效 JSON"

if (( JSON_OUTPUT )); then
  jq . <<< "$SUMMARY"
  exit 0
fi

print_knowledge() {
  jq -r '
    "总问题： \(.total_questions)",
    "AI回复： \(.ai_replies)",
    "命中： \(.knowledge_hits)",
    "未命中： \(.knowledge_misses)",
    "转人工： \(.handoffs)",
    "命中率： \(.hit_rate)%"
  ' <<< "$SUMMARY"
}

print_feedback() {
  jq -r '
    "好评： \(.positive_feedback)",
    "差评： \(.negative_feedback)",
    "好评率： \(.positive_rate)%",
    "",
    "近期差评问题：",
    (if (.negative_questions | length) == 0 then "（无）" else (.negative_questions[] | "- [\(.at)] \(.question)") end),
    "",
    "高频失败问题：",
    (if (.frequent_failures | length) == 0 then "（无）" else (.frequent_failures[] | "- \(.question)（\(.count) 次）") end)
  ' <<< "$SUMMARY"
}

case "$MODE" in
  knowledge) print_knowledge ;;
  feedback) print_feedback ;;
  all)
    printf '%s\n' '知识库分析'
    print_knowledge
    printf '\n%s\n' '回答质量反馈'
    print_feedback
    ;;
esac
