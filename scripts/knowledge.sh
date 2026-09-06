#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

KNOWLEDGE_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if ! declare -F env_get >/dev/null; then
  # shellcheck source=scripts/common.sh
  source "${KNOWLEDGE_SCRIPT_DIR}/common.sh"
fi
# shellcheck source=scripts/configuration.sh
source "${KNOWLEDGE_SCRIPT_DIR}/configuration.sh"

knowledge_valid_id() { [[ "$1" =~ ^kb_([a-f0-9]{16}|default)$ ]]; }
knowledge_valid_document() { [[ "$1" =~ ^doc_[a-f0-9]{16}$ ]]; }

knowledge_catalog_validate() {
  jq -e '
    .schema_version == 2 and (.libraries | type == "array" and length <= 100) and
    ([.libraries[].id] | length == (unique | length)) and
    all(.libraries[]; (.id | test("^kb_([a-f0-9]{16}|default)$")) and
      (.name | type == "string" and length > 0 and length <= 100) and (.enabled | type == "boolean") and
      (.documents | type == "array" and length <= 10000) and
      ([.documents[].id] | length == (unique | length)) and
      all(.documents[]; (.id | test("^doc_[a-f0-9]{16}$")) and
        (.name | type == "string" and length > 0 and (test("[\\x00-\\x1f\\\\/]") | not)) and
        (.source | test("^sources/doc_[a-f0-9]{16}\\.(md|txt|pdf|docx)$")) and
        (.projection | type == "string" and length > 0 and (test("[\\x00-\\x1f\\\\/;,]") | not)) and
        (.sha256 | test("^[a-f0-9]{64}$")))) and
    ([.libraries[].documents[].projection] | length == (unique | length))
  ' "$1" >/dev/null
}

knowledge_catalog_write() {
  local deploy_dir=$1 temporary=$2 target="${1}/knowledge/catalog.json"
  knowledge_catalog_validate "$temporary" || { configuration_error '知识库目录结构校验失败'; return 1; }
  chmod 640 "$temporary"
  chown root:1000 "$temporary" 2>/dev/null || true
  mv -f -- "$temporary" "$target"
}

knowledge_catalog_migrate() {
  local deploy_dir=$1 catalog="${1}/knowledge/catalog.json" temporary file name document_id hash extension source metadata
  mkdir -p -- "${deploy_dir}/knowledge" "${deploy_dir}/tmp" "${deploy_dir}/data/runtime"
  [[ ! -L "${deploy_dir}/knowledge" && ! -L "$catalog" ]] || return 1
  if [[ -f "$catalog" ]]; then knowledge_catalog_validate "$catalog"; return; fi
  temporary=$(mktemp "${catalog}.tmp.XXXXXX")
  jq -n '{schema_version:2,revision:1,libraries:[{id:"kb_default",name:"默认知识库",enabled:true,revision:1,documents:[],status:"pending",last_sync:null,error:null}]}' > "$temporary"
  mkdir -p -- "${deploy_dir}/knowledge/kb_default/sources"
  while IFS= read -r -d '' file; do
    is_supported_knowledge_file "$file" || continue
    name=$(basename -- "$file")
    [[ "$name" != README.md && "$name" != *$'\n'* && "$name" != *$'\r'* && "$name" != *\\* && "$name" != *';'* && "$name" != *','* ]] || continue
    hash=$(sha256sum -- "$file" | awk '{print $1}')
    document_id="doc_$(printf '%s' "$name" | sha256sum | cut -c1-16)"
    extension=${name##*.}; extension=${extension,,}
    source="sources/${document_id}.${extension}"
    install -m 640 -- "$file" "${deploy_dir}/knowledge/kb_default/${source}"
    metadata=$(jq -cn --arg id "$document_id" --arg name "$name" --arg source "$source" --arg projection "$name" --arg hash "$hash" '{id:$id,name:$name,source:$source,projection:$projection,sha256:$hash}')
    file=$(mktemp "${catalog}.merge.XXXXXX")
    jq --argjson document "$metadata" '.libraries[0].documents += [$document]' "$temporary" > "$file"
    mv -f -- "$file" "$temporary"
  done < <(find "${deploy_dir}/knowledge" -maxdepth 1 -type f ! -type l -print0 | sort -z)
  file=$(mktemp "${catalog}.merge.XXXXXX")
  jq 'if (.libraries[0].documents | length) == 0 then .libraries=[] else . end' "$temporary" > "$file"
  mv -f -- "$file" "$temporary"
  knowledge_catalog_write "$deploy_dir" "$temporary"
  chown -R root:1000 "${deploy_dir}/knowledge/kb_default" 2>/dev/null || true
  chmod 750 "${deploy_dir}/knowledge/kb_default" "${deploy_dir}/knowledge/kb_default/sources"
}

knowledge_catalog_project() {
  local deploy_dir=$1 catalog="${1}/knowledge/catalog.json" old_list="${1}/data/knowledge-projection.json" next_list temporary row library source projection
  knowledge_catalog_validate "$catalog" || return 1
  next_list=$(jq -c '[.libraries[] | select(.enabled) | .documents[].projection] | unique' "$catalog")
  if [[ -f "$old_list" ]]; then
    jq -e 'type == "array" and all(type == "string" and (test("[\\x00-\\x1f\\\\/;,]") | not))' "$old_list" >/dev/null || return 1
    while IFS= read -r projection; do
      [[ -n "$projection" && "$projection" != README.md && ! -L "${deploy_dir}/knowledge/${projection}" ]] || return 1
      rm -f -- "${deploy_dir}/knowledge/${projection}"
    done < <(jq -rn --argjson previous "$(<"$old_list")" --argjson next "$next_list" '$previous - $next | .[]')
  else
    while IFS= read -r projection; do
      [[ -n "$projection" && "$projection" != README.md && ! -L "${deploy_dir}/knowledge/${projection}" ]] || return 1
      rm -f -- "${deploy_dir}/knowledge/${projection}"
    done < <(jq -r '.libraries[] | select(.enabled == false) | .documents[].projection' "$catalog")
  fi
  while IFS= read -r row; do
    library=$(jq -r '.library' <<< "$row")
    source=$(jq -r '.source' <<< "$row")
    projection=$(jq -r '.projection' <<< "$row")
    [[ -f "${deploy_dir}/knowledge/${library}/${source}" && ! -L "${deploy_dir}/knowledge/${library}/${source}" ]] || return 1
    [[ $(realpath -e "${deploy_dir}/knowledge/${library}/${source}") == "${deploy_dir}/knowledge/${library}/"* ]] || return 1
    [[ ! -L "${deploy_dir}/knowledge/${projection}" ]] || return 1
    temporary=$(mktemp "${deploy_dir}/knowledge/.projection.XXXXXX")
    install -m 640 -- "${deploy_dir}/knowledge/${library}/${source}" "$temporary"
    chown root:1000 "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "${deploy_dir}/knowledge/${projection}"
  done < <(jq -c '.libraries[] | select(.enabled) | .id as $library | .documents[] | . + {library:$library}' "$catalog")
  temporary=$(mktemp "${old_list}.tmp.XXXXXX")
  printf '%s\n' "$next_list" > "$temporary"
  chmod 600 "$temporary"
  mv -f -- "$temporary" "$old_list"
}

knowledge_catalog_readback() {
  local deploy_dir=$1 scope=${2:-all} manifest="${1}/data/knowledge-manifest.json" catalog="${1}/knowledge/catalog.json" locations temporary now
  anythingllm_connection "$deploy_dir"
  locations=$(anythingllm_workspace_locations) || return 1
  jq -en --slurpfile catalog "$catalog" --slurpfile manifest "$manifest" --argjson locations "$locations" --arg scope "$scope" '
    all($catalog[0].libraries[] | select($scope == "all" or .id == $scope) | select(.enabled) | .documents[]; . as $document |
      ($manifest[0].files[$document.projection].sha256 == $document.sha256) and
      ($manifest[0].files[$document.projection].locations | length > 0) and
      all($manifest[0].files[$document.projection].locations[]; . as $location | $locations | index($location) != null)) and
    all($catalog[0].libraries[] | select($scope == "all" or .id == $scope) | select(.enabled == false) | .documents[]; . as $document | $manifest[0].files[$document.projection] == null)
  ' >/dev/null || return 1
  now=$(date +%s)
  temporary=$(mktemp "${catalog}.tmp.XXXXXX")
  jq --argjson now "$now" --arg scope "$scope" '.libraries |= map(if $scope == "all" or .id == $scope then . as $library | .status=(if .enabled then "indexed" else "disabled" end) | .last_sync=$now | .error=null |
    .documents |= map(.index_status=(if $library.enabled then "indexed" else "disabled" end) | .last_error=null) else . end)' "$catalog" > "$temporary"
  knowledge_catalog_write "$deploy_dir" "$temporary"
  temporary=$(mktemp "${deploy_dir}/data/runtime/knowledge-map.json.tmp.XXXXXX")
  jq -n --slurpfile catalog "$catalog" --slurpfile manifest "$manifest" '{schema_version:2,revision:$catalog[0].revision,documents:[
    $catalog[0].libraries[] | select(.enabled) | . as $library | .documents[] | . as $document |
    $manifest[0].files[$document.projection].locations[]? | {location:.,library_id:$library.id,library_name:$library.name,document_id:$document.id,projection:$document.projection}
  ]}' > "$temporary"
  chmod 640 "$temporary"
  chown 1000:1000 "$temporary" 2>/dev/null || true
  mv -f -- "$temporary" "${deploy_dir}/data/runtime/knowledge-map.json"
}

knowledge_sync_catalog() {
  local deploy_dir=$1 force=${2:-0} scope=${3:-all} filenames=null status=0 temporary
  knowledge_catalog_migrate "$deploy_dir" || return 1
  if [[ "$scope" != all ]]; then
    knowledge_valid_id "$scope" || return 1
    jq -e --arg id "$scope" 'any(.libraries[]; .id == $id)' "${deploy_dir}/knowledge/catalog.json" >/dev/null || { configuration_error '知识库不存在'; return 1; }
    filenames=$(jq -c --arg id "$scope" '[.libraries[] | select(.id == $id) | .documents[].projection]' "${deploy_dir}/knowledge/catalog.json")
  fi
  knowledge_catalog_project "$deploy_dir" || return 1
  if declare -F knowledge_sync_legacy >/dev/null; then
    knowledge_sync_legacy "$deploy_dir" "$force" "$filenames" >&2 || status=$?
  else
    knowledge_sync "$deploy_dir" "$force" >&2 || status=$?
  fi
  if (( status == 0 )) && knowledge_catalog_readback "$deploy_dir" "$scope"; then
    return 0
  fi
  temporary=$(mktemp "${deploy_dir}/knowledge/catalog.json.tmp.XXXXXX")
  jq --arg scope "$scope" --slurpfile manifest "${deploy_dir}/data/knowledge-manifest.json" '.libraries |= map(if $scope != "all" and .id != $scope then . elif .enabled then
    .documents |= map(. as $document | .index_status=(if $manifest[0].files[$document.projection].sha256 == $document.sha256 then "indexed" elif $manifest[0].pending_files[$document.projection] != null then "pending" else "failed" end)) |
    .status=(if all(.documents[]; .index_status == "indexed") then "indexed" else "pending" end) |
    .error=(if .status == "indexed" then null else "索引或服务端对账未完成，可重新同步继续" end)
    else .status="disabled" end)' "${deploy_dir}/knowledge/catalog.json" > "$temporary"
  knowledge_catalog_write "$deploy_dir" "$temporary"
  return 1
}

knowledge_catalog_update() {
  local deploy_dir=$1 filter=$2; shift 2
  local temporary
  temporary=$(mktemp "${deploy_dir}/knowledge/catalog.json.tmp.XXXXXX")
  jq "$@" "${filter} | .revision=((.revision // 0)+1)" "${deploy_dir}/knowledge/catalog.json" > "$temporary" || return 1
  knowledge_catalog_write "$deploy_dir" "$temporary"
}

knowledge_import_files() {
  local deploy_dir=$1 library_id=$2 requested=$3 resolved file name extension document_id source projection hash temporary
  local -a files=()
  [[ ! -L "$requested" ]] || { configuration_error '知识来源不得是符号链接'; return 1; }
  resolved=$(realpath -e -- "$requested") || return 1
  if [[ -f "$resolved" ]]; then files+=("$resolved");
  elif [[ -d "$resolved" ]]; then
    while IFS= read -r -d '' file; do files+=("$file"); done < <(find "$resolved" -type f ! -type l -print0 | sort -z)
  else return 1; fi
  (( ${#files[@]} <= 10000 )) || return 1
  for file in "${files[@]}"; do
    is_supported_knowledge_file "$file" || continue
    [[ $(stat -c '%s' "$file") -gt 0 && $(stat -c '%s' "$file") -le 52428800 ]] || { configuration_error '单个知识文件必须为 1～50 MiB'; return 1; }
    name=$(basename -- "$file")
    [[ "$name" != *$'\n'* && "$name" != *$'\r'* && "$name" != *\\* && "$name" != *';'* && "$name" != *','* ]] || return 1
    document_id=$(jq -r --arg id "$library_id" --arg name "$name" '.libraries[] | select(.id == $id) | .documents[] | select(.name == $name) | .id' "${deploy_dir}/knowledge/catalog.json")
    [[ -n "$document_id" ]] || document_id="doc_$(openssl rand -hex 8)"
    extension=${name##*.}; extension=${extension,,}
    source="sources/${document_id}.${extension}"
    projection=$(jq -r --arg id "$library_id" --arg doc "$document_id" '.libraries[] | select(.id == $id) | .documents[] | select(.id == $doc) | .projection' "${deploy_dir}/knowledge/catalog.json")
    [[ -n "$projection" ]] || projection="${library_id}_${document_id}.${extension}"
    hash=$(sha256sum -- "$file" | awk '{print $1}')
    mkdir -p -- "${deploy_dir}/knowledge/${library_id}/sources"
    temporary=$(mktemp "${deploy_dir}/knowledge/${library_id}/sources/.import.XXXXXX")
    install -m 640 -- "$file" "$temporary"
    mv -f -- "$temporary" "${deploy_dir}/knowledge/${library_id}/${source}"
    knowledge_catalog_update "$deploy_dir" '.libraries |= map(if .id == $library then .revision+=1 | .status="pending" | .documents=((.documents | map(select(.id != $document))) + [{id:$document,name:$name,source:$source,projection:$projection,sha256:$hash}]) else . end)' \
      --arg library "$library_id" --arg document "$document_id" --arg name "$name" --arg source "$source" --arg projection "$projection" --arg hash "$hash" || return 1
  done
  chown -R root:1000 "${deploy_dir}/knowledge/${library_id}" 2>/dev/null || true
  find "${deploy_dir}/knowledge/${library_id}" -type d -exec chmod 750 {} +
}

knowledge_query() {
  local deploy_dir=$1 library=$2 question=$3 response status payload map
  [[ "$library" == all ]] || knowledge_valid_id "$library" || return 1
  [[ -n "$question" && ${#question} -le 8000 ]] || return 1
  anythingllm_connection "$deploy_dir"
  response=$(mktemp "${deploy_dir}/tmp/knowledge-query.XXXXXX")
  chmod 600 "$response"
  payload=$(jq -cn --arg query "$question" '{query:$query,topN:20,scoreThreshold:0}')
  status=$(anythingllm_secure_request "$deploy_dir" POST "http://127.0.0.1:${ANYTHING_PORT}/api/v1/workspace/${ANYTHING_WORKSPACE}/vector-search" "$ANYTHING_KEY" "$payload" "$response" 120)
  if [[ "$status" != 2?? ]] || ! jq -e '.results | type == "array"' "$response" >/dev/null; then rm -f -- "$response"; return 1; fi
  map="${deploy_dir}/data/runtime/knowledge-map.json"
  [[ -f "$map" ]] || { rm -f -- "$response"; return 1; }
  jq --arg library "$library" --slurpfile map "$map" '
    {query_scope:$library,results:[.results[] | . as $result |
      ($map[0].documents | map(. as $document | select(
        (.location == ($result.metadata.docpath // $result.docpath // "")) or
        ((.location | split("/") | last) == (($result.metadata.location // "") | split("/") | last)) or
        (.projection == ($result.metadata.title // "")) or
        (($result.metadata.title // "") | startswith($document.projection))
      )) | .[0] // {}) as $source |
      . + {library_id:($source.library_id // "unknown"),library_name:($source.library_name // "未识别来源")} |
      select($library == "all" or .library_id == $library)]}
  ' "$response"
  rm -f -- "$response"
}

knowledge_bootstrap_source() {
  local deploy_dir=$1 name=$2 input=$3 library_id
  [[ -n "$name" && ${#name} -le 100 && ! "$name" =~ [[:cntrl:]] ]] || return 1
  knowledge_catalog_migrate "$deploy_dir" || return 1
  library_id=$(jq -r --arg name "$name" '.libraries[] | select(.name == $name) | .id' "${deploy_dir}/knowledge/catalog.json" | head -n 1)
  if [[ -z "$library_id" ]]; then
    library_id="kb_$(openssl rand -hex 8)"
    mkdir -p -- "${deploy_dir}/knowledge/${library_id}/sources"
    knowledge_catalog_update "$deploy_dir" '.libraries += [{id:$id,name:$name,enabled:true,revision:1,documents:[],status:"pending",last_sync:null,error:null}]' --arg id "$library_id" --arg name "$name" || return 1
  fi
  knowledge_import_files "$deploy_dir" "$library_id" "$input" || return 1
  jq -n --arg id "$library_id" '{library_id:$id,status:"pending",applied:false}'
}

knowledge_main() (
  local deploy_request='' deploy_dir action library_id temporary name history removed_source='' status=0
  while (( $# )); do
    case "$1" in
      --deploy-dir) deploy_request=${2:?}; shift 2 ;;
      --help|-h) printf '%s\n' '用法：knowledge.sh [--deploy-dir PATH] list | create NAME | rename ID NAME | enable ID | disable ID | delete ID | entries ID | import ID PATH | remove ID DOCID | sync [ID|all] | reindex [ID|all] | query ID|all QUESTION'; return ;;
      *) break ;;
    esac
  done
  action=${1:-list}; shift || true
  deploy_dir=$(resolve_deploy_dir "$deploy_request")
  assert_managed_installation "$deploy_dir"
  acquire_maintenance_lock "$deploy_dir"
  configuration_runtime_init "$deploy_dir"
  knowledge_catalog_migrate "$deploy_dir" || return 1
  case "$action" in
    list) jq '.' "${deploy_dir}/knowledge/catalog.json"; return ;;
    entries) library_id=${1:?}; knowledge_valid_id "$library_id" || return 1; jq --arg id "$library_id" '.libraries[] | select(.id == $id) | {id,name,enabled,status,documents}' "${deploy_dir}/knowledge/catalog.json"; return ;;
    query) knowledge_query "$deploy_dir" "${1:-all}" "${2:?}"; return ;;
    bootstrap-source) knowledge_bootstrap_source "$deploy_dir" "${1:?}" "${2:?}"; return ;;
    sync|reindex) [[ ${1:-all} == all ]] || knowledge_valid_id "$1" || return 1; if [[ "$action" == reindex ]]; then knowledge_sync_catalog "$deploy_dir" 1 "${1:-all}"; else knowledge_sync_catalog "$deploy_dir" 0 "${1:-all}"; fi; configuration_revision "$deploy_dir" true; jq '.' "${deploy_dir}/knowledge/catalog.json"; return ;;
  esac
  if [[ "$action" != create ]]; then
    library_id=${1:?}; shift
    knowledge_valid_id "$library_id" || return 1
    jq -e --arg id "$library_id" 'any(.libraries[]; .id == $id)' "${deploy_dir}/knowledge/catalog.json" >/dev/null || { configuration_error '知识库不存在'; return 1; }
  fi
  history=$(mktemp -d "${deploy_dir}/backups/config-history/knowledge.XXXXXXXX")
  tar -czf "${history}/knowledge.tar.gz" -C "$deploy_dir" knowledge
  chmod 600 "${history}/knowledge.tar.gz"
  case "$action" in
    create)
      name=${1:?}; [[ -n "$name" && ${#name} -le 100 && ! "$name" =~ [[:cntrl:]] ]] || return 1
      library_id="kb_$(openssl rand -hex 8)"
      mkdir -p -- "${deploy_dir}/knowledge/${library_id}/sources"
      knowledge_catalog_update "$deploy_dir" '.libraries += [{id:$id,name:$name,enabled:true,revision:1,documents:[],status:"indexed",last_sync:null,error:null}]' --arg id "$library_id" --arg name "$name" || return 1 ;;
    rename)
      name=${1:?}; [[ -n "$name" && ${#name} -le 100 && ! "$name" =~ [[:cntrl:]] ]] || return 1
      knowledge_catalog_update "$deploy_dir" '.libraries |= map(if .id == $id then .name=$name | .revision+=1 else . end)' --arg id "$library_id" --arg name "$name" || return 1 ;;
    enable|disable)
      temporary=false; [[ "$action" != enable ]] || temporary=true
      knowledge_catalog_update "$deploy_dir" '.libraries |= map(if .id == $id then .enabled=$enabled | .revision+=1 else . end)' --arg id "$library_id" --argjson enabled "$temporary" || return 1 ;;
    delete)
      knowledge_catalog_update "$deploy_dir" '.libraries |= map(select(.id != $id))' --arg id "$library_id" || return 1 ;;
    import) knowledge_import_files "$deploy_dir" "$library_id" "${1:?}" || status=$? ;;
    remove)
      knowledge_valid_document "${1:?}" || return 1
      removed_source=$(jq -r --arg id "$library_id" --arg document "$1" '.libraries[] | select(.id == $id) | .documents[] | select(.id == $document) | .source' "${deploy_dir}/knowledge/catalog.json")
      [[ -n "$removed_source" ]] || { configuration_error '知识条目不存在'; return 1; }
      knowledge_catalog_update "$deploy_dir" '.libraries |= map(if .id == $id then .documents |= map(select(.id != $document)) else . end)' --arg id "$library_id" --arg document "$1" || return 1 ;;
    *) configuration_error "未知知识库操作：$action"; return 1 ;;
  esac
  if (( status == 0 )) && knowledge_sync_catalog "$deploy_dir"; then
    if [[ "$action" == delete && -d "${deploy_dir}/knowledge/${library_id}" && ! -L "${deploy_dir}/knowledge/${library_id}" ]]; then
      mv -- "${deploy_dir}/knowledge/${library_id}" "${history}/${library_id}"
    elif [[ "$action" == remove && -f "${deploy_dir}/knowledge/${library_id}/${removed_source}" && ! -L "${deploy_dir}/knowledge/${library_id}/${removed_source}" ]]; then
      mkdir -p -- "${history}/${library_id}/sources"
      mv -- "${deploy_dir}/knowledge/${library_id}/${removed_source}" "${history}/${library_id}/${removed_source}"
    fi
    configuration_revision "$deploy_dir" true
    jq --arg id "$library_id" '{library_id:$id,catalog:.}' "${deploy_dir}/knowledge/catalog.json"
    return 0
  fi
  tar -xzf "${history}/knowledge.tar.gz" -C "$deploy_dir" --no-same-owner
  knowledge_sync_catalog "$deploy_dir" >&2 || true
  configuration_error '知识修改未通过实际索引与回读；旧配置和原文已恢复，可重新同步重试'
  return 1
)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then knowledge_main "$@"; fi
