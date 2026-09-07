#!/usr/bin/env bash
set -euo pipefail

MATERIALS_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if ! declare -F env_get >/dev/null; then
  # shellcheck source=scripts/common.sh
  source "${MATERIALS_SCRIPT_DIR}/common.sh"
fi
# shellcheck source=scripts/knowledge.sh
source "${MATERIALS_SCRIPT_DIR}/knowledge.sh"

readonly MATERIALS_SCHEMA_VERSION=1
readonly MATERIALS_PROJECTION_MAX_BYTES=16777216
readonly MATERIALS_CATALOG_MAX_BYTES=536870912
readonly MATERIALS_PROMPT_MAX_BYTES=262144
readonly MATERIALS_DOCUMENT_MAX_BYTES=52428800

materials_error() { printf '错误：%s\n' "$*" >&2; }

materials_sha_or_empty() {
  local file=$1
  if [[ -f "$file" && ! -L "$file" ]]; then
    sha256sum -- "$file" | awk '{print $1}'
  else
    printf '\n'
  fi
}

materials_validate_private_file() {
  local file=$1 maximum=$2 description=$3 size mode
  [[ -f "$file" && ! -L "$file" ]] \
    || { materials_error "${description}必须是普通文件且不得是符号链接"; return 1; }
  size=$(stat -c '%s' -- "$file")
  (( size > 0 && size <= maximum )) \
    || { materials_error "${description}大小必须为 1～${maximum} 字节"; return 1; }
  mode=$(stat -c '%a' -- "$file")
  (( (8#$mode & 0027) == 0 )) \
    || { materials_error "${description}权限过宽（要求不得由 group 写入且不得向 other 开放）"; return 1; }
}

materials_validate_prompt_file() {
  local file=$1
  materials_validate_private_file "$file" "$MATERIALS_PROMPT_MAX_BYTES" 'Prompt' || return 1
  python3 - "$file" <<'PY'
import pathlib
import sys

raw = pathlib.Path(sys.argv[1]).read_bytes()
try:
    text = raw.decode("utf-8", "strict")
except UnicodeDecodeError:
    raise SystemExit("Prompt 不是有效 UTF-8")
if "\x00" in text or not text.strip():
    raise SystemExit("Prompt 不能为空、全空白或包含 NUL")
PY
}

materials_normalize_configuration() {
  local name=$1 input=$2 output=$3
  materials_validate_private_file "$input" 1048576 "${name} 配置" || return 1
  configuration_normalize_file "$name" "$input" "$output"
}

materials_reconcile_catalog() {
  local deploy_dir=$1 output=$2 semantic=$3
  local catalog="${deploy_dir}/knowledge/catalog.json"
  materials_validate_private_file "$catalog" "$MATERIALS_CATALOG_MAX_BYTES" '知识库目录' || return 1
  knowledge_catalog_validate "$catalog" \
    || { materials_error '知识库目录结构无效'; return 1; }
  python3 - "$deploy_dir" "$catalog" "$output" "$semantic" "$MATERIALS_DOCUMENT_MAX_BYTES" <<'PY'
import copy
import hashlib
import json
import os
import pathlib
import stat
import sys
import zipfile

deploy = pathlib.Path(sys.argv[1])
catalog_path = pathlib.Path(sys.argv[2])
output_path = pathlib.Path(sys.argv[3])
semantic_path = pathlib.Path(sys.argv[4])
maximum = int(sys.argv[5])
catalog = json.loads(catalog_path.read_text(encoding="utf-8"))

def fail(message):
    raise SystemExit(message)

def validate_regular_private(path, description):
    try:
        info = path.lstat()
    except FileNotFoundError:
        fail(f"{description}不存在")
    if not stat.S_ISREG(info.st_mode) or path.is_symlink():
        fail(f"{description}必须是普通文件且不得是符号链接")
    if info.st_mode & 0o027:
        fail(f"{description}权限过宽")
    if info.st_size < 1 or info.st_size > maximum:
        fail(f"{description}大小必须为 1～{maximum} 字节")
    return path.read_bytes()

def validate_document(path, extension, description):
    raw = validate_regular_private(path, description)
    if extension in ("md", "txt"):
        try:
            text = raw.decode("utf-8", "strict")
        except UnicodeDecodeError:
            fail(f"{description}不是有效 UTF-8")
        if "\x00" in text:
            fail(f"{description}包含 NUL")
    elif extension == "pdf":
        if not raw.startswith(b"%PDF-"):
            fail(f"{description}不是有效 PDF 文件头")
    elif extension == "docx":
        try:
            with zipfile.ZipFile(path) as archive:
                names = set(archive.namelist())
                if "[Content_Types].xml" not in names or "word/document.xml" not in names:
                    fail(f"{description}不是有效 DOCX 文档")
                if any(info.flag_bits & 0x1 for info in archive.infolist()):
                    fail(f"{description}不得是加密 DOCX")
        except (zipfile.BadZipFile, OSError):
            fail(f"{description}不是有效 DOCX 文档")
    return raw

changed_library_ids = set()
expected = {}
for library in catalog["libraries"]:
    library_dir = deploy / "knowledge" / library["id"]
    sources_dir = library_dir / "sources"
    if library_dir.is_symlink() or sources_dir.is_symlink():
        fail(f"知识库 {library['id']} 的目录不得是符号链接")
    if not sources_dir.is_dir():
        fail(f"知识库 {library['id']} 缺少 sources 目录")
    expected[library["id"]] = set()
    for document in library["documents"]:
        relative = pathlib.PurePosixPath(document["source"])
        filename = relative.name
        expected[library["id"]].add(filename)
        extension = relative.suffix.lower().lstrip(".")
        source = library_dir / pathlib.Path(*relative.parts)
        raw = validate_document(source, extension, f"知识文档 {library['id']}/{filename}")
        digest = hashlib.sha256(raw).hexdigest()
        if document["sha256"] != digest:
            document["sha256"] = digest
            changed_library_ids.add(library["id"])
    actual = set()
    for child in sources_dir.iterdir():
        if child.is_symlink() or not child.is_file():
            fail(f"知识库 {library['id']} 的 sources 含链接或特殊文件")
        actual.add(child.name)
    orphaned = sorted(actual - expected[library["id"]])
    if orphaned:
        fail(f"知识库 {library['id']} 含未登记文件；请通过知识库导入功能添加：{orphaned[0]}")

if changed_library_ids:
    catalog["revision"] = int(catalog.get("revision", 0)) + 1
    for library in catalog["libraries"]:
        if library["id"] in changed_library_ids:
            library["revision"] = int(library.get("revision", 0)) + 1
            library["status"] = "pending"
            library["error"] = None
            for document in library["documents"]:
                document["index_status"] = "pending"
                document["last_error"] = None

semantic = copy.deepcopy(catalog)
for library in semantic["libraries"]:
    for key in ("status", "last_sync", "error"):
        library.pop(key, None)
    for document in library["documents"]:
        for key in ("index_status", "last_error"):
            document.pop(key, None)

for target, value in ((output_path, catalog), (semantic_path, semantic)):
    target.write_text(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
PY
  knowledge_catalog_validate "$output" || return 1
}

materials_projection_validate() {
  local file=$1 stage name temporary
  [[ -f "$file" && ! -L "$file" && $(stat -c '%s' -- "$file") -le $MATERIALS_PROJECTION_MAX_BYTES ]] || return 1
  jq -M -e --argjson schema "$MATERIALS_SCHEMA_VERSION" '
    .schema_version == $schema and (.revision | type == "number" and floor == . and . >= 1) and
    (.state == "applied" or .state == "applying") and
    (.applied_at | type == "number" and floor == . and . >= 0) and
    (.source_sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
    (.source_components | type == "object") and
    all(.source_components[]; type == "string" and test("^[a-f0-9]{64}$")) and
    (.configuration | type == "object") and
    (.prompt | type == "object") and (.prompt.text | type == "string" and length > 0) and
    (.prompt.sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
    (.prompt.bytes | type == "number" and floor == . and . >= 1 and . <= 262144) and
    (.knowledge | type == "object") and
    all([.knowledge.catalog_sha256,.knowledge.manifest_sha256,.knowledge.map_sha256][];
      type == "string" and (. == "" or test("^[a-f0-9]{64}$"))) and
    (.knowledge.enabled_library_ids | type == "array" and all(type == "string" and test("^kb_([a-f0-9]{16}|default)$"))) and
    (.knowledge.library_count | type == "number" and floor == . and . >= 0 and . <= 100) and
    (.knowledge.document_count | type == "number" and floor == . and . >= 0 and . <= 1000000) and
    (if .state == "applied" then
       .configuration.runtime.revision == .revision and .configuration.runtime.applied_revision == .revision
     else .configuration.runtime.revision == .revision and
       (.configuration.runtime.applied_revision | type == "number" and floor == . and . >= 0) and
       .configuration.runtime.applied_revision <= .revision
     end)
  ' "$file" >/dev/null || return 1
  python3 - "$file" <<'PY'
import hashlib
import json
import sys
raw = json.load(open(sys.argv[1], encoding="utf-8"))
encoded = raw["prompt"]["text"].encode("utf-8")
if len(encoded) != raw["prompt"]["bytes"]:
    raise SystemExit(1)
if hashlib.sha256(encoded).hexdigest() != raw["prompt"]["sha256"]:
    raise SystemExit(1)
PY
  stage=$(mktemp -d "${file}.validate.XXXXXXXX")
  for name in runtime handoff keyword menu tags feedback; do
    temporary="${stage}/${name}.json"
    jq -M ".configuration.${name}" "$file" > "$temporary" || { rm -rf -- "$stage"; return 1; }
    configuration_validate "$name" "$temporary" || { rm -rf -- "$stage"; return 1; }
  done
  rm -rf -- "$stage"
}

materials_prepare_candidate() {
  local deploy_dir=$1 stage=$2 revision=$3 state=${4:-applied}
  local name prompt_hash prompt_bytes catalog_hash manifest_hash map_hash source_hash now
  local components="${stage}/components.json" candidate="${stage}/materials-applied.json" runtime_semantic
  mkdir -p -- "${stage}/config" "${stage}/knowledge"
  for name in runtime handoff keyword menu tags feedback; do
    materials_normalize_configuration "$name" "${deploy_dir}/config/${name}.yaml" "${stage}/config/${name}.json" || return 1
  done
  materials_validate_prompt_file "${deploy_dir}/config/prompt.md" || return 1
  install -m 600 -- "${deploy_dir}/config/prompt.md" "${stage}/prompt.md"
  materials_reconcile_catalog "$deploy_dir" "${stage}/knowledge/catalog.json" "${stage}/knowledge/catalog-semantic.json" || return 1

  prompt_hash=$(materials_sha_or_empty "${stage}/prompt.md")
  prompt_bytes=$(stat -c '%s' -- "${stage}/prompt.md")
  catalog_hash=$(materials_sha_or_empty "${stage}/knowledge/catalog-semantic.json")
  manifest_hash=$(materials_sha_or_empty "${deploy_dir}/data/knowledge-manifest.json")
  map_hash=$(materials_sha_or_empty "${deploy_dir}/data/runtime/knowledge-map.json")
  if [[ -f "${deploy_dir}/data/runtime/knowledge-map.json" ]]; then
    [[ ! -L "${deploy_dir}/data/runtime/knowledge-map.json" && $(stat -c '%s' -- "${deploy_dir}/data/runtime/knowledge-map.json") -le $MATERIALS_PROJECTION_MAX_BYTES ]] \
      || { materials_error '运行时知识映射超过 16777216 字节或文件类型不安全'; return 1; }
    jq -M -e '.schema_version == 2 and (.documents | type == "array")' "${deploy_dir}/data/runtime/knowledge-map.json" >/dev/null \
      || { materials_error '运行时知识映射格式无效'; return 1; }
  fi
  runtime_semantic="${stage}/config/runtime-semantic.json"
  jq -M 'del(.revision,.applied_revision)' "${stage}/config/runtime.json" > "$runtime_semantic"
  jq -M -n \
    --arg runtime "$(materials_sha_or_empty "$runtime_semantic")" \
    --arg handoff "$(materials_sha_or_empty "${stage}/config/handoff.json")" \
    --arg keyword "$(materials_sha_or_empty "${stage}/config/keyword.json")" \
    --arg menu "$(materials_sha_or_empty "${stage}/config/menu.json")" \
    --arg tags "$(materials_sha_or_empty "${stage}/config/tags.json")" \
    --arg feedback "$(materials_sha_or_empty "${stage}/config/feedback.json")" \
    --arg prompt "$prompt_hash" --arg catalog "$catalog_hash" \
    '{runtime:$runtime,handoff:$handoff,keyword:$keyword,menu:$menu,tags:$tags,feedback:$feedback,prompt:$prompt,knowledge:$catalog}' \
    > "$components"
  source_hash=$(sha256sum -- "$components" | awk '{print $1}')
  now=$(date +%s)
  jq -M -n --argjson schema "$MATERIALS_SCHEMA_VERSION" --argjson revision "$revision" \
    --arg state "$state" --argjson now "$now" --arg source_hash "$source_hash" \
    --slurpfile components "$components" \
    --slurpfile runtime "${stage}/config/runtime.json" \
    --slurpfile handoff "${stage}/config/handoff.json" \
    --slurpfile keyword "${stage}/config/keyword.json" \
    --slurpfile menu "${stage}/config/menu.json" \
    --slurpfile tags "${stage}/config/tags.json" \
    --slurpfile feedback "${stage}/config/feedback.json" \
    --rawfile prompt "${stage}/prompt.md" --arg prompt_hash "$prompt_hash" --argjson prompt_bytes "$prompt_bytes" \
    --slurpfile catalog "${stage}/knowledge/catalog.json" --arg catalog_hash "$catalog_hash" \
    --arg manifest_hash "$manifest_hash" --arg map_hash "$map_hash" '
      {schema_version:$schema,revision:$revision,state:$state,applied_at:$now,
       source_sha256:$source_hash,source_components:$components[0],
       configuration:{
         runtime:($runtime[0] + {schema_version:2,revision:$revision,applied_revision:(if $state == "applied" then $revision else ($runtime[0].applied_revision // 0) end)}),
         handoff:$handoff[0],keyword:$keyword[0],menu:$menu[0],tags:$tags[0],feedback:$feedback[0]},
       prompt:{text:$prompt,sha256:$prompt_hash,bytes:$prompt_bytes},
       knowledge:{catalog_revision:($catalog[0].revision // 0),catalog_sha256:$catalog_hash,
         manifest_sha256:$manifest_hash,map_sha256:$map_hash,
         enabled_library_ids:[$catalog[0].libraries[] | select(.enabled) | .id],
         library_count:($catalog[0].libraries|length),
         document_count:([$catalog[0].libraries[].documents[]]|length)}}
    ' > "$candidate"
  materials_projection_validate "$candidate" \
    || { materials_error '候选生效投影未通过内部一致性校验'; return 1; }
}

materials_projection_write() {
  local deploy_dir=$1 input=$2 target="${1}/config/materials-applied.json" temporary
  materials_projection_validate "$input" || { materials_error '拒绝写入无效的资料投影'; return 1; }
  temporary=$(mktemp "${target}.tmp.XXXXXX")
  install -m 640 -- "$input" "$temporary"
  chown root:1000 "$temporary" 2>/dev/null || true
  mv -f -- "$temporary" "$target"
}

materials_projection_readback() {
  local deploy_dir=$1 expected actual
  expected=$(materials_sha_or_empty "${deploy_dir}/config/materials-applied.json")
  actual=$(docker_compose "$deploy_dir" exec -T n8n node -e '
    const fs=require("fs"),crypto=require("crypto");
    const value=fs.readFileSync("/opt/crisp-ai/config/materials-applied.json");
    process.stdout.write(crypto.createHash("sha256").update(value).digest("hex"));
  ' 2>/dev/null) || return 1
  [[ -n "$expected" && "$actual" == "$expected" ]]
}

materials_snapshot_create() {
  local deploy_dir=$1 output=$2 stage temporary name row library source
  stage=$(mktemp -d "${deploy_dir}/tmp/materials-snapshot.XXXXXXXX")
  mkdir -p -- "${stage}/config" "${stage}/knowledge"
  for name in runtime handoff keyword menu tags feedback; do
    install -m 600 -- "${deploy_dir}/config/${name}.yaml" "${stage}/config/${name}.yaml"
  done
  install -m 600 -- "${deploy_dir}/config/prompt.md" "${stage}/config/prompt.md"
  install -m 600 -- "${deploy_dir}/knowledge/catalog.json" "${stage}/knowledge/catalog.json"
  while IFS= read -r row; do
    library=$(jq -M -r '.library' <<< "$row")
    source=$(jq -M -r '.source' <<< "$row")
    install -D -m 600 -- "${deploy_dir}/knowledge/${library}/${source}" "${stage}/knowledge/${library}/${source}"
  done < <(jq -M -c '.libraries[] | .id as $library | .documents[] | {library:$library,source:.source}' "${deploy_dir}/knowledge/catalog.json")
  temporary=$(mktemp "${output}.tmp.XXXXXX")
  tar -czf "$temporary" -C "$stage" config knowledge
  chmod 600 "$temporary"
  mv -f -- "$temporary" "$output"
  rm -rf -- "$stage"
}

materials_snapshot_extract() {
  local snapshot=$1 destination=$2
  [[ -f "$snapshot" && ! -L "$snapshot" ]] || return 1
  mkdir -p -- "$destination"
  tar -xzf "$snapshot" -C "$destination" --no-same-owner --no-same-permissions
  [[ -f "${destination}/config/prompt.md" && -f "${destination}/knowledge/catalog.json" ]] || return 1
}

materials_external_restore() {
  local deploy_dir=$1 snapshot=$2 restore_prompt=${3:-true} restore_knowledge=${4:-true}
  local stage restore_deploy file status=0
  stage=$(mktemp -d "${deploy_dir}/tmp/materials-restore.XXXXXXXX")
  restore_deploy="${stage}/deploy"
  materials_snapshot_extract "$snapshot" "$restore_deploy" || { rm -rf -- "$stage"; return 1; }
  mkdir -p -- "${restore_deploy}/tmp" "${restore_deploy}/data/runtime"
  install -m 600 -- "${deploy_dir}/.env" "${restore_deploy}/.env"
  for file in knowledge-manifest.json knowledge-projection.json; do
    [[ ! -f "${deploy_dir}/data/${file}" ]] || install -m 600 -- "${deploy_dir}/data/${file}" "${restore_deploy}/data/${file}"
  done
  if [[ "$restore_prompt" == true ]]; then
    configuration_prompt_sync_file "$deploy_dir" "${restore_deploy}/config/prompt.md" >/dev/null 2>&1 || status=1
  fi
  if [[ "$restore_knowledge" == true ]] && ! knowledge_sync_catalog "$restore_deploy"; then
    status=1
  fi
  if (( status == 0 )); then
    for file in knowledge-manifest.json knowledge-projection.json; do
      [[ ! -f "${restore_deploy}/data/${file}" ]] || install -m 600 -- "${restore_deploy}/data/${file}" "${deploy_dir}/data/${file}"
    done
    [[ ! -f "${restore_deploy}/data/runtime/knowledge-map.json" ]] \
      || install -m 640 -- "${restore_deploy}/data/runtime/knowledge-map.json" "${deploy_dir}/data/runtime/knowledge-map.json"
    rm -rf -- "$stage"
    return 0
  fi
  rm -rf -- "$stage"
  return 1
}

materials_publish_old_generation() {
  local deploy_dir=$1 old=$2 revision=$3 state=$4 output
  output=$(mktemp "${deploy_dir}/tmp/materials-old.XXXXXX")
  jq -M --argjson revision "$revision" --arg state "$state" --argjson now "$(date +%s)" '
    .revision=$revision | .state=$state | .applied_at=$now |
    .configuration.runtime.revision=$revision |
    .configuration.runtime.applied_revision=(if $state == "applied" then $revision else (.configuration.runtime.applied_revision // 0) end)
  ' "$old" > "$output"
  materials_projection_write "$deploy_dir" "$output"
  rm -f -- "$output"
}

materials_finalize_runtime_source() {
  local deploy_dir=$1 revision=$2 target="${1}/config/runtime.yaml" temporary normalized
  normalized=$(mktemp "${deploy_dir}/tmp/runtime-finalize.XXXXXX")
  materials_normalize_configuration runtime "$target" "$normalized" \
    || { rm -f -- "$normalized"; return 1; }
  temporary=$(mktemp "${target}.tmp.XXXXXX")
  jq -M --argjson revision "$revision" '.schema_version=2 | .revision=$revision | .applied_revision=$revision' "$normalized" > "$temporary" \
    || { rm -f -- "$normalized" "$temporary"; return 1; }
  rm -f -- "$normalized"
  chmod 640 "$temporary"
  chown root:1000 "$temporary" 2>/dev/null || true
  mv -f -- "$temporary" "$target"
}

materials_initialize() (
  local deploy_dir=$1 projection="${1}/config/materials-applied.json" stage revision snapshot candidate_snapshot runtime_normalized
  [[ ! -e "$projection" && ! -L "$projection" ]] \
    || { materials_projection_validate "$projection" || { materials_error '现有资料投影损坏，拒绝回退读取可编辑原文'; return 1; }; return 0; }
  acquire_maintenance_lock "$deploy_dir"
  configuration_runtime_init "$deploy_dir"
  knowledge_catalog_migrate "$deploy_dir"
  configuration_prompt_verify_file "$deploy_dir" "${deploy_dir}/config/prompt.md" \
    || { materials_error '当前 Prompt 尚未通过 AnythingLLM 回读，不能建立首份投影'; return 1; }
  knowledge_catalog_readback "$deploy_dir" \
    || { materials_error '当前知识索引尚未通过回读，不能建立首份投影'; return 1; }
  runtime_normalized=$(mktemp "${deploy_dir}/tmp/runtime-initialize.XXXXXX")
  materials_normalize_configuration runtime "${deploy_dir}/config/runtime.yaml" "$runtime_normalized" \
    || { rm -f -- "$runtime_normalized"; return 1; }
  revision=$(jq -M -r '[(.revision // 0),(.applied_revision // 0)] | max | if . < 1 then 1 else . end' "$runtime_normalized")
  rm -f -- "$runtime_normalized"
  stage=$(mktemp -d "${deploy_dir}/tmp/materials-initialize.XXXXXXXX")
  materials_prepare_candidate "$deploy_dir" "$stage" "$revision" applied || { rm -rf -- "$stage"; return 1; }
  candidate_snapshot="${stage}/materials.applied.tar.gz"
  materials_snapshot_create "$deploy_dir" "$candidate_snapshot" || { rm -rf -- "$stage"; return 1; }
  materials_finalize_runtime_source "$deploy_dir" "$revision"
  materials_projection_write "$deploy_dir" "${stage}/materials-applied.json"
  if ! materials_projection_readback "$deploy_dir"; then
    rm -f -- "$projection"
    materials_error '运行容器未读到首份资料投影'
    rm -rf -- "$stage"
    return 1
  fi
  snapshot="${deploy_dir}/backups/config-history/materials.applied.tar.gz"
  install -m 600 -- "$candidate_snapshot" "$snapshot"
  jq -M '{initialized:true,revision,state,source_sha256}' "$projection"
  rm -rf -- "$stage"
)

materials_apply() (
  local deploy_dir=$1 knowledge_mode=${2:-none} projection="${1}/config/materials-applied.json" old_snapshot old='' stage='' revision=0
  local prompt_changed knowledge_changed config_changed final_stage='' rollback_revision history candidate_snapshot result=0 recovering=false
  local transition_started=false transition_committed=false signal_status=0
  # shellcheck disable=SC2317
  materials_apply_on_signal() {
    signal_status=$1
    # 某些调用方会向整个进程组重复发送信号；先忽略后续信号，再由 EXIT 门禁收口。
    trap '' INT TERM
    exit "$signal_status"
  }
  # shellcheck disable=SC2317
  materials_apply_on_exit() {
    local exit_status=$? current_revision=0 safe_revision
    trap - EXIT
    trap '' INT TERM
    if [[ "$transition_started" == true && "$transition_committed" == false && -f "$old" ]]; then
      if materials_projection_validate "$projection"; then
        current_revision=$(jq -M -r '.revision' "$projection")
      fi
      safe_revision=$(( current_revision >= revision ? current_revision + 1 : revision + 1 ))
      if ! materials_publish_old_generation "$deploy_dir" "$old" "$safe_revision" applying; then
        materials_error '资料应用异常退出，且无法写回受阻止投影；请立即停止自动客服并从上一有效备份恢复'
      fi
    fi
    rm -f -- "${old:-}"
    rm -rf -- "${stage:-}" "${final_stage:-}"
    if (( signal_status != 0 )); then
      materials_error '资料应用已中断；候选原文已保留，自动回复保持受阻止状态，请重新执行资料应用以恢复'
    fi
    exit "$exit_status"
  }
  trap 'materials_apply_on_signal 130' INT
  trap 'materials_apply_on_signal 143' TERM
  trap materials_apply_on_exit EXIT
  acquire_maintenance_lock "$deploy_dir"
  [[ -f "$projection" && ! -L "$projection" ]] \
    || { materials_error '尚无已验证的资料投影；请先在安装/升级流程执行 materials.sh initialize'; return 1; }
  materials_projection_validate "$projection" \
    || { materials_error '现有资料投影损坏，已阻止应用；不会回退读取可编辑原文'; return 1; }
  old_snapshot="${deploy_dir}/backups/config-history/materials.applied.tar.gz"
  [[ -f "$old_snapshot" && ! -L "$old_snapshot" ]] \
    || { materials_error '缺少上一有效资料快照，已阻止不可恢复的应用'; return 1; }
  old=$(mktemp "${deploy_dir}/tmp/materials-effective.XXXXXX")
  install -m 600 -- "$projection" "$old"
  [[ $(jq -M -r '.state' "$old") != applying ]] || recovering=true
  revision=$(( $(jq -M -r '.revision' "$old") + 1 ))
  stage=$(mktemp -d "${deploy_dir}/tmp/materials-candidate.XXXXXXXX")
  materials_prepare_candidate "$deploy_dir" "$stage" "$revision" applied \
    || { rm -f -- "$old"; rm -rf -- "$stage"; return 1; }
  if [[ "$recovering" == false && "$knowledge_mode" == none && $(jq -M -r '.source_sha256' "$old") == $(jq -M -r '.source_sha256' "${stage}/materials-applied.json") ]]; then
    jq -M -n --argjson revision "$(jq -M -r '.revision' "$old")" '{applied:true,changed:false,revision:$revision}'
    rm -f -- "$old"; rm -rf -- "$stage"; return 0
  fi
  prompt_changed=false; knowledge_changed=false; config_changed=false
  [[ $(jq -M -r '.source_components.prompt' "$old") == $(jq -M -r '.source_components.prompt' "${stage}/materials-applied.json") ]] || prompt_changed=true
  [[ $(jq -M -r '.source_components.knowledge' "$old") == $(jq -M -r '.source_components.knowledge' "${stage}/materials-applied.json") ]] || knowledge_changed=true
  [[ "$knowledge_mode" != sync && "$knowledge_mode" != reindex ]] || knowledge_changed=true
  if [[ "$knowledge_mode" == external ]]; then
    prompt_changed=true
    knowledge_changed=true
  fi
  if [[ "$recovering" == true ]]; then
    # 上次外部回滚未能确认时，不能仅凭原文哈希相同就解除停发。
    # 重新同步 Prompt 与知识并回读，成功后才发布 applied 新代次。
    prompt_changed=true
    knowledge_changed=true
  fi
  jq -M -e --slurpfile old "$old" '
    [.source_components.runtime,.source_components.handoff,.source_components.keyword,.source_components.menu,.source_components.tags,.source_components.feedback] ==
    [$old[0].source_components.runtime,$old[0].source_components.handoff,$old[0].source_components.keyword,$old[0].source_components.menu,$old[0].source_components.tags,$old[0].source_components.feedback]
  ' "${stage}/materials-applied.json" >/dev/null || config_changed=true

  history=$(mktemp -d "${deploy_dir}/backups/config-history/materials.XXXXXXXX")
  install -m 600 -- "$old" "${history}/materials-applied.json"
  install -m 600 -- "$old_snapshot" "${history}/materials-applied.tar.gz"

  if [[ "$prompt_changed" == true || "$knowledge_changed" == true ]]; then
    transition_started=true
    materials_publish_old_generation "$deploy_dir" "$old" "$revision" applying
    if [[ "$prompt_changed" == true ]] && ! configuration_prompt_sync_file "$deploy_dir" "${stage}/prompt.md"; then
      result=1
    fi
    if (( result == 0 )) && [[ "$knowledge_changed" == true ]]; then
      install -m 640 -- "${stage}/knowledge/catalog.json" "${deploy_dir}/knowledge/catalog.json"
      chown root:1000 "${deploy_dir}/knowledge/catalog.json" 2>/dev/null || true
      if [[ "$knowledge_mode" == reindex || "$recovering" == true ]]; then
        knowledge_sync_catalog "$deploy_dir" 1 || result=1
      else
        knowledge_sync_catalog "$deploy_dir" 0 || result=1
      fi
    fi
  fi

  if (( result == 0 )); then
    final_stage=$(mktemp -d "${deploy_dir}/tmp/materials-final.XXXXXXXX")
    materials_prepare_candidate "$deploy_dir" "$final_stage" "$revision" applied || result=1
  fi
  if (( result == 0 )); then
    candidate_snapshot="${history}/candidate-applied.tar.gz"
    materials_snapshot_create "$deploy_dir" "$candidate_snapshot" || result=1
  fi
  if (( result == 0 )); then
    transition_started=true
    materials_finalize_runtime_source "$deploy_dir" "$revision"
    materials_projection_write "$deploy_dir" "${final_stage}/materials-applied.json"
    materials_projection_readback "$deploy_dir" || result=1
  fi
  if (( result == 0 )); then
    install -m 600 -- "$candidate_snapshot" "$old_snapshot"
    install -m 600 -- "$old" "${deploy_dir}/backups/config-history/materials.previous.json"
    transition_committed=true
    jq -M -n --argjson revision "$revision" --argjson config "$config_changed" --argjson prompt "$prompt_changed" --argjson knowledge "$knowledge_changed" \
      '{applied:true,changed:true,revision:$revision,components:{configuration:$config,prompt:$prompt,knowledge:$knowledge}}'
    rm -f -- "$old"; rm -rf -- "$stage" "${final_stage:-}"
    return 0
  fi

  rollback_revision=$((revision + 1))
  if materials_external_restore "$deploy_dir" "$old_snapshot" "$prompt_changed" "$knowledge_changed" \
    && materials_publish_old_generation "$deploy_dir" "$old" "$rollback_revision" applied; then
    transition_committed=true
    materials_error '资料应用失败；上一有效投影已恢复，可编辑原文保留为待应用变更'
  else
    materials_error '资料应用失败且外部恢复尚未确认；自动回复保持受阻止状态，请重试应用或执行恢复'
  fi
  # 未确认外部恢复时保留 old 到 EXIT 门禁，由其强制写回更高代次的 applying 后再清理。
  if [[ "$transition_committed" == true ]]; then
    rm -f -- "$old"; rm -rf -- "$stage" "${final_stage:-}"
  fi
  return 1
)

materials_status() {
  local deploy_dir=$1 projection="${1}/config/materials-applied.json" stage source_valid=true applied_valid=true
  local source_hash='' applied_hash='' state='missing' revision=0
  if [[ -e "$projection" || -L "$projection" ]]; then
    if materials_projection_validate "$projection"; then
      applied_hash=$(jq -M -r '.source_sha256' "$projection")
      state=$(jq -M -r '.state' "$projection")
      revision=$(jq -M -r '.revision' "$projection")
    else
      applied_valid=false
      state=invalid
    fi
  fi
  stage=$(mktemp -d "${deploy_dir}/tmp/materials-status.XXXXXXXX")
  if materials_prepare_candidate "$deploy_dir" "$stage" "$((revision > 0 ? revision : 1))" applied >/dev/null 2>&1; then
    source_hash=$(jq -M -r '.source_sha256' "${stage}/materials-applied.json")
  else
    source_valid=false
  fi
  jq -M -n --argjson source_valid "$source_valid" --argjson applied_valid "$applied_valid" \
    --arg state "$state" --argjson revision "$revision" --arg source_hash "$source_hash" --arg applied_hash "$applied_hash" \
    --arg projection "$projection" --arg prompt "${deploy_dir}/config/prompt.md" --arg catalog "${deploy_dir}/knowledge/catalog.json" \
    '{source_valid:$source_valid,projection_valid:$applied_valid,state:$state,applied_revision:$revision,
      pending:($source_valid and $applied_valid and ($state != "applied" or $source_hash != $applied_hash)),
      source_sha256:$source_hash,applied_sha256:$applied_hash,
      paths:{projection:$projection,prompt:$prompt,knowledge_catalog:$catalog}}'
  rm -rf -- "$stage"
  [[ "$source_valid" == true && "$applied_valid" == true && "$state" == applied ]] || return 1
  [[ "$source_hash" == "$applied_hash" ]] || return 2
}

materials_main() {
  local deploy_request='' action deploy_dir knowledge_mode=none
  while (( $# )); do
    case "$1" in
      --deploy-dir) deploy_request=${2:?}; shift 2 ;;
      --help|-h)
        printf '%s\n' \
          '用法：materials.sh [--deploy-dir PATH] status | validate | initialize | apply [--force-external|--sync-knowledge|--force-knowledge|--refresh-projection]' \
          'status 只显示哈希、revision 与稳定路径，不输出 Prompt、知识正文或秘密。'
        return ;;
      *) break ;;
    esac
  done
  action=${1:-status}; shift || true
  if [[ "$action" == apply ]]; then
    case "${1:-}" in
      --force-external) knowledge_mode=external; shift ;;
      --sync-knowledge) knowledge_mode=sync; shift ;;
      --force-knowledge) knowledge_mode=reindex; shift ;;
      --refresh-projection) knowledge_mode=refresh; shift ;;
    esac
  fi
  (( $# == 0 )) || { materials_error '参数过多'; return 64; }
  deploy_dir=$(resolve_deploy_dir "$deploy_request")
  assert_managed_installation "$deploy_dir"
  mkdir -p -- "${deploy_dir}/tmp" "${deploy_dir}/backups/config-history"
  case "$action" in
    status) materials_status "$deploy_dir" ;;
    validate)
      local stage
      stage=$(mktemp -d "${deploy_dir}/tmp/materials-validate.XXXXXXXX")
      materials_prepare_candidate "$deploy_dir" "$stage" 1 applied
      jq -M -n --arg hash "$(jq -M -r '.source_sha256' "${stage}/materials-applied.json")" '{valid:true,source_sha256:$hash}'
      rm -rf -- "$stage" ;;
    initialize) materials_initialize "$deploy_dir" ;;
    apply) materials_apply "$deploy_dir" "$knowledge_mode" ;;
    *) materials_error "未知资料操作：$action"; return 64 ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then materials_main "$@"; fi
