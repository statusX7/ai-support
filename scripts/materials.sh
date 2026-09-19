#!/usr/bin/env bash
set -euo pipefail

MATERIALS_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if ! declare -F env_get >/dev/null; then
  # shellcheck source=scripts/common.sh
  source "${MATERIALS_SCRIPT_DIR}/common.sh"
fi
# shellcheck source=scripts/knowledge.sh
source "${MATERIALS_SCRIPT_DIR}/knowledge.sh"

readonly MATERIALS_SCHEMA_VERSION=2
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

materials_json_hash() {
  local file=$1
  python3 - "$file" <<'PY'
import hashlib
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
print(hashlib.sha256(encoded).hexdigest())
PY
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

materials_required_hash() {
  local file=$1 maximum=$2 description=$3
  materials_validate_private_file "$file" "$maximum" "$description" || return 1
  materials_sha_or_empty "$file"
}

materials_optional_hash() {
  local file=$1 maximum=$2 description=$3
  if [[ ! -e "$file" && ! -L "$file" ]]; then
    printf '\n'
    return 0
  fi
  materials_required_hash "$file" "$maximum" "$description"
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

materials_projection_validate_configuration() {
  local file=$1 stage name temporary
  stage=$(mktemp -d "${file}.validate.XXXXXXXX")
  for name in runtime handoff keyword menu tags feedback; do
    temporary="${stage}/${name}.json"
    jq -M ".configuration.${name}" "$file" > "$temporary" || { rm -rf -- "$stage"; return 1; }
    configuration_validate "$name" "$temporary" || { rm -rf -- "$stage"; return 1; }
  done
  rm -rf -- "$stage"
}

materials_projection_validate_legacy() {
  local file=$1
  [[ -f "$file" && ! -L "$file" && $(stat -c '%s' -- "$file") -le $MATERIALS_PROJECTION_MAX_BYTES ]] || return 1
  jq -M -e '
    .schema_version == 1 and (.revision | type == "number" and floor == . and . >= 1) and
    (.state == "applied" or .state == "applying") and
    (.applied_at | type == "number" and floor == . and . >= 0) and
    (.source_sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
    (.configuration | type == "object") and
    (.prompt | type == "object") and (.prompt.text | type == "string" and length > 0) and
    (.prompt.sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
    (.prompt.bytes | type == "number" and floor == . and . >= 1 and . <= 262144) and
    (.knowledge | type == "object") and
    (.configuration.runtime.revision == .revision) and
    (.configuration.runtime.applied_revision | type == "number" and floor == . and . >= 0) and
    (.configuration.runtime.applied_revision <= .revision) and
    (if .state == "applied" then .configuration.runtime.applied_revision == .revision else true end)
  ' "$file" >/dev/null || return 1
  python3 - "$file" <<'PY'
import hashlib
import json
import pathlib
import sys

raw = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
encoded = raw["prompt"]["text"].encode("utf-8")
if not encoded or b"\x00" in encoded or len(encoded) != raw["prompt"]["bytes"]:
    raise SystemExit(1)
if hashlib.sha256(encoded).hexdigest() != raw["prompt"]["sha256"]:
    raise SystemExit(1)
PY
  materials_projection_validate_configuration "$file"
}

materials_projection_validate() {
  local file=$1
  [[ -f "$file" && ! -L "$file" && $(stat -c '%s' -- "$file") -le $MATERIALS_PROJECTION_MAX_BYTES ]] || return 1
  jq -M -e --argjson schema "$MATERIALS_SCHEMA_VERSION" '
    .schema_version == $schema and (.revision | type == "number" and floor == . and . >= 1) and
    (.state == "applied" or .state == "applying") and
    (.applied_at | type == "number" and floor == . and . >= 0) and
    (.source_sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
    (.source_components | type == "object") and
    ((.source_components | keys) == ["feedback","handoff","keyword","knowledge","menu","prompt","runtime","tags"]) and
    all(.source_components[]; type == "string" and test("^[a-f0-9]{64}$")) and
    (.configuration | type == "object") and
    ((.configuration | keys) == ["feedback","handoff","keyword","menu","runtime","tags"]) and
    (.prompt | type == "object") and ((.prompt | keys) == ["bytes","sha256","text"]) and
    (.prompt.text | type == "string" and length > 0) and
    (.prompt.sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
    (.prompt.bytes | type == "number" and floor == . and . >= 1 and . <= 262144) and
    (.knowledge | type == "object") and
    ((.knowledge | keys) == ["catalog_revision","catalog_sha256","document_count","enabled_document_count",
      "enabled_library_ids","lexical_sha256","library_count","manifest_sha256","map_sha256","profile_sha256","settings_sha256"]) and
    all([.knowledge.catalog_sha256,.knowledge.manifest_sha256,.knowledge.map_sha256,
         .knowledge.settings_sha256,.knowledge.lexical_sha256][];
      type == "string" and test("^[a-f0-9]{64}$")) and
    (.knowledge.profile_sha256 | type == "string" and
      (. == "" or test("^[a-f0-9]{64}$"))) and
    (.knowledge.catalog_revision | type == "number" and floor == . and . >= 0) and
    (.knowledge.enabled_library_ids | type == "array" and all(type == "string" and test("^kb_([a-f0-9]{16}|default)$"))) and
    ((.knowledge.enabled_library_ids | unique | length) == (.knowledge.enabled_library_ids | length)) and
    (.knowledge.library_count | type == "number" and floor == . and . >= 0 and . <= 100) and
    ((.knowledge.enabled_library_ids | length) <= .knowledge.library_count) and
    (.knowledge.document_count | type == "number" and floor == . and . >= 0 and . <= 1000000) and
    (.knowledge.document_count as $document_count |
      .knowledge.enabled_document_count | type == "number" and floor == . and . >= 0 and . <= $document_count) and
    (if .knowledge.enabled_document_count > 0 then (.knowledge.profile_sha256 | test("^[a-f0-9]{64}$")) else true end) and
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
import pathlib
import sys

raw = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
encoded = raw["prompt"]["text"].encode("utf-8")
if not encoded or b"\x00" in encoded or len(encoded) != raw["prompt"]["bytes"]:
    raise SystemExit(1)
if hashlib.sha256(encoded).hexdigest() != raw["prompt"]["sha256"]:
    raise SystemExit(1)

knowledge = raw["knowledge"]
canonical = lambda value: json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
runtime = dict(raw["configuration"]["runtime"])
runtime.pop("revision", None)
runtime.pop("applied_revision", None)
embedded_components = {
    "runtime": runtime,
    "handoff": raw["configuration"]["handoff"],
    "keyword": raw["configuration"]["keyword"],
    "menu": raw["configuration"]["menu"],
    "tags": raw["configuration"]["tags"],
    "feedback": raw["configuration"]["feedback"],
}
for name, value in embedded_components.items():
    if hashlib.sha256(canonical(value)).hexdigest() != raw["source_components"][name]:
        raise SystemExit(1)
if raw["source_components"]["prompt"] != raw["prompt"]["sha256"]:
    raise SystemExit(1)
if hashlib.sha256(canonical(knowledge)).hexdigest() != raw["source_components"]["knowledge"]:
    raise SystemExit(1)
if hashlib.sha256(canonical(raw["source_components"])).hexdigest() != raw["source_sha256"]:
    raise SystemExit(1)
PY
  materials_projection_validate_configuration "$file"
}

materials_prepare_candidate() {
  local deploy_dir=$1 stage=$2 revision=$3 state=${4:-applied}
  local name prompt_hash prompt_bytes catalog_hash manifest_hash map_hash settings_hash profile_hash lexical_hash knowledge_hash source_hash now lexical_result
  local expected_workspace profile_fingerprint profile_actual
  local enabled_document_count
  local components="${stage}/components.json" candidate="${stage}/materials-applied.json" runtime_semantic knowledge_identity
  mkdir -p -- "${stage}/config" "${stage}/knowledge"
  for name in runtime handoff keyword menu tags feedback; do
    materials_normalize_configuration "$name" "${deploy_dir}/config/${name}.yaml" "${stage}/config/${name}.json" || return 1
  done
  materials_validate_prompt_file "${deploy_dir}/config/prompt.md" || return 1
  install -m 600 -- "${deploy_dir}/config/prompt.md" "${stage}/prompt.md"
  materials_reconcile_catalog "$deploy_dir" "${stage}/knowledge/catalog.json" "${stage}/knowledge/catalog-semantic.json" || return 1

  prompt_hash=$(materials_sha_or_empty "${stage}/prompt.md")
  prompt_bytes=$(stat -c '%s' -- "${stage}/prompt.md")
  catalog_hash=$(materials_json_hash "${stage}/knowledge/catalog-semantic.json")
  manifest_hash=$(materials_required_hash "${deploy_dir}/data/knowledge-manifest.json" "$MATERIALS_PROJECTION_MAX_BYTES" '知识清单') || return 1
  jq -M -e '.version == 1 and (.files | type == "object") and (.pending_files | type == "object")' \
    "${deploy_dir}/data/knowledge-manifest.json" >/dev/null \
    || { materials_error '知识清单格式无效'; return 1; }
  map_hash=$(materials_required_hash "${deploy_dir}/data/runtime/knowledge-map.json" "$MATERIALS_PROJECTION_MAX_BYTES" '运行时知识映射') || return 1
  jq -M -e '.schema_version == 2 and (.documents | type == "array")' "${deploy_dir}/data/runtime/knowledge-map.json" >/dev/null \
    || { materials_error '运行时知识映射格式无效'; return 1; }
  enabled_document_count=$(jq -M -r '.documents | length' "${deploy_dir}/data/runtime/knowledge-map.json")
  settings_hash=$(materials_required_hash "${deploy_dir}/data/runtime/knowledge-settings.json" 65536 '知识运行设置') \
    || { materials_error '知识运行设置尚未通过工作区回读'; return 1; }
  expected_workspace=$(env_get "${deploy_dir}/.env" ANYTHINGLLM_WORKSPACE) \
    || { materials_error '当前 AnythingLLM 工作区配置缺失'; return 1; }
  [[ "$expected_workspace" =~ ^[A-Za-z0-9_-]{1,128}$ ]] \
    || { materials_error '当前 AnythingLLM 工作区配置无效'; return 1; }
  jq -M -e --arg workspace "$expected_workspace" '.schema_version == 1 and .workspace_slug == $workspace and
    (.temperature | type == "number" and isfinite and . >= 0 and . <= 2) and
    (.observed_at | type == "number" and floor == . and . >= 0)' "${deploy_dir}/data/runtime/knowledge-settings.json" >/dev/null \
    || { materials_error '知识运行设置与当前工作区不一致'; return 1; }
  profile_hash=$(materials_optional_hash "${deploy_dir}/data/runtime/knowledge-profile.json" 65536 '知识索引代次') || return 1
  if [[ -n "$profile_hash" ]]; then
    jq -M -e '.schema_version == 1 and .state == "applied" and
      (.fingerprint | type == "string" and test("^[a-f0-9]{64}$")) and (.profile | type == "object")' \
      "${deploy_dir}/data/runtime/knowledge-profile.json" >/dev/null \
      || { materials_error '知识索引代次尚未完整应用'; return 1; }
    profile_fingerprint=$(jq -M -er '.fingerprint' "${deploy_dir}/data/runtime/knowledge-profile.json") || return 1
    profile_actual=$(python3 - "${deploy_dir}/data/runtime/knowledge-profile.json" <<'PY'
import hashlib
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["profile"]
encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
print(hashlib.sha256(encoded).hexdigest())
PY
    ) || return 1
    [[ "$profile_actual" == "$profile_fingerprint" ]] \
      || { materials_error '知识索引代次指纹与当前配置不一致'; return 1; }
  elif (( enabled_document_count > 0 )); then
    materials_error '已有启用知识文档，但知识索引代次缺失'
    return 1
  fi
  lexical_hash=$(materials_required_hash "${deploy_dir}/data/runtime/knowledge-lexical.json" "$MATERIALS_PROJECTION_MAX_BYTES" '词法补召回索引') || return 1
  lexical_result=$(mktemp "${stage}/knowledge-lexical-verify.XXXXXXXX")
  if ! python3 -B "${MATERIALS_SCRIPT_DIR}/knowledge-lexical.py" verify --deploy-dir "$deploy_dir" > "$lexical_result" 2>/dev/null \
    || ! jq -e --arg map "$map_hash" '.ok == true and .read_only == true and .map_sha256 == $map and (.complete | type == "boolean")' "$lexical_result" >/dev/null 2>&1; then
    rm -f -- "$lexical_result"
    materials_error '词法补召回索引与当前启用知识或解析正文不一致'
    return 1
  fi
  rm -f -- "$lexical_result"
  runtime_semantic="${stage}/config/runtime-semantic.json"
  jq -M 'del(.revision,.applied_revision)' "${stage}/config/runtime.json" > "$runtime_semantic"
  knowledge_identity="${stage}/knowledge/runtime-identity.json"
  jq -M -n --arg catalog "$catalog_hash" --arg manifest "$manifest_hash" --arg map "$map_hash" \
    --arg settings "$settings_hash" --arg profile "$profile_hash" --arg lexical "$lexical_hash" \
    --slurpfile catalog_value "${stage}/knowledge/catalog.json" --argjson enabled_document_count "$enabled_document_count" \
    '{catalog_revision:($catalog_value[0].revision // 0),catalog_sha256:$catalog,
      manifest_sha256:$manifest,map_sha256:$map,settings_sha256:$settings,
      profile_sha256:$profile,lexical_sha256:$lexical,
      enabled_library_ids:[$catalog_value[0].libraries[] | select(.enabled) | .id],
      library_count:($catalog_value[0].libraries|length),
      document_count:([$catalog_value[0].libraries[].documents[]]|length),
      enabled_document_count:$enabled_document_count}' \
    > "$knowledge_identity"
  knowledge_hash=$(materials_json_hash "$knowledge_identity")
  jq -M -n \
    --arg runtime "$(materials_json_hash "$runtime_semantic")" \
    --arg handoff "$(materials_json_hash "${stage}/config/handoff.json")" \
    --arg keyword "$(materials_json_hash "${stage}/config/keyword.json")" \
    --arg menu "$(materials_json_hash "${stage}/config/menu.json")" \
    --arg tags "$(materials_json_hash "${stage}/config/tags.json")" \
    --arg feedback "$(materials_json_hash "${stage}/config/feedback.json")" \
    --arg prompt "$prompt_hash" --arg knowledge "$knowledge_hash" \
    '{runtime:$runtime,handoff:$handoff,keyword:$keyword,menu:$menu,tags:$tags,feedback:$feedback,prompt:$prompt,knowledge:$knowledge}' \
    > "$components"
  source_hash=$(materials_json_hash "$components")
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
    --slurpfile knowledge "$knowledge_identity" '
      {schema_version:$schema,revision:$revision,state:$state,applied_at:$now,
       source_sha256:$source_hash,source_components:$components[0],
       configuration:{
         runtime:($runtime[0] + {schema_version:2,revision:$revision,applied_revision:(if $state == "applied" then $revision else ($runtime[0].applied_revision // 0) end)}),
         handoff:$handoff[0],keyword:$keyword[0],menu:$menu[0],tags:$tags[0],feedback:$feedback[0]},
       prompt:{text:$prompt,sha256:$prompt_hash,bytes:$prompt_bytes},
       knowledge:$knowledge[0]}
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

materials_projection_write_legacy() {
  local deploy_dir=$1 input=$2 target="${1}/config/materials-applied.json" temporary
  materials_projection_validate_legacy "$input" || { materials_error '拒绝写入无效的旧资料投影'; return 1; }
  temporary=$(mktemp "${target}.tmp.XXXXXX")
  install -m 640 -- "$input" "$temporary"
  chown root:1000 "$temporary" 2>/dev/null || true
  mv -f -- "$temporary" "$target"
}

# 候选第一次生成后，发布前再从当前受管原文和运行投影独立重算一次身份。
# 维护锁由调用方持有；二次结果不一致时保留旧投影，不发布混合代次。
materials_projection_write_current() {
  local deploy_dir=$1 input=$2 revision state verify_stage expected actual
  materials_projection_validate "$input" || { materials_error '拒绝发布无效的资料投影'; return 1; }
  revision=$(jq -M -er '.revision' "$input") || return 1
  state=$(jq -M -er '.state' "$input") || return 1
  verify_stage=$(mktemp -d "${deploy_dir}/tmp/materials-publish-verify.XXXXXXXX")
  if ! materials_prepare_candidate "$deploy_dir" "$verify_stage" "$revision" "$state"; then
    rm -rf -- "$verify_stage"
    materials_error '发布前资料身份复核失败，上一有效投影保持不变'
    return 1
  fi
  expected=$(jq -McS '{revision,state,source_sha256}' "$input") || { rm -rf -- "$verify_stage"; return 1; }
  actual=$(jq -McS '{revision,state,source_sha256}' "${verify_stage}/materials-applied.json") \
    || { rm -rf -- "$verify_stage"; return 1; }
  if [[ "$expected" != "$actual" ]]; then
    rm -rf -- "$verify_stage"
    materials_error '资料在候选生成后发生变化，未发布混合代次；请重新应用'
    return 1
  fi
  materials_projection_write "$deploy_dir" "$input"
  rm -rf -- "$verify_stage"
}

materials_projection_readback() {
  local deploy_dir=$1 expected actual revision
  expected=$(materials_sha_or_empty "${deploy_dir}/config/materials-applied.json")
  revision=$(jq -M -er '.revision' "${deploy_dir}/config/materials-applied.json") || return 1
  actual=$(docker_compose "$deploy_dir" exec -T n8n node -e '
    const fs=require("fs"),crypto=require("crypto");
    const digest=value=>crypto.createHash("sha256").update(value).digest("hex");
    const canonical=value=>Array.isArray(value)?"["+value.map(canonical).join(",")+"]"
      :value&&typeof value==="object"?"{"+Object.keys(value).sort().map(key=>JSON.stringify(key)+":"+canonical(value[key])).join(",")+"}"
      :JSON.stringify(value);
    const regular=(file,maximum,optional=false)=>{
      try { const stat=fs.lstatSync(file); if(!stat.isFile()||stat.isSymbolicLink()||stat.size<1||stat.size>maximum) throw new Error("unsafe"); return fs.readFileSync(file); }
      catch(error){ if(optional&&error.code==="ENOENT") return null; throw error; }
    };
    const projectionRaw=regular("/opt/crisp-ai/config/materials-applied.json",16777216);
    const value=JSON.parse(projectionRaw.toString("utf8"));
    if(value.schema_version!==2||value.state!=="applied"||value.configuration?.runtime?.revision!==value.revision
      ||value.configuration.runtime.applied_revision!==value.revision) throw new Error("projection");
    const runtime={...value.configuration.runtime}; delete runtime.revision; delete runtime.applied_revision;
    const embedded={runtime,handoff:value.configuration.handoff,keyword:value.configuration.keyword,
      menu:value.configuration.menu,tags:value.configuration.tags,feedback:value.configuration.feedback};
    for(const [name,item] of Object.entries(embedded)) if(digest(canonical(item))!==value.source_components?.[name]) throw new Error("component");
    if(digest(value.prompt.text)!==value.prompt.sha256||Buffer.byteLength(value.prompt.text)!==value.prompt.bytes
      ||value.source_components.prompt!==value.prompt.sha256) throw new Error("prompt");
    if(digest(canonical(value.knowledge))!==value.source_components.knowledge
      ||digest(canonical(value.source_components))!==value.source_sha256) throw new Error("identity");
    const base="/opt/crisp-ai/data/runtime/";
    const map=regular(base+"knowledge-map.json",16777216);
    const settings=regular(base+"knowledge-settings.json",65536);
    const lexical=regular(base+"knowledge-lexical.json",16777216);
    const profile=regular(base+"knowledge-profile.json",65536,true);
    if(digest(map)!==value.knowledge.map_sha256||digest(settings)!==value.knowledge.settings_sha256
      ||digest(lexical)!==value.knowledge.lexical_sha256
      ||(profile===null?"":digest(profile))!==value.knowledge.profile_sha256) throw new Error("runtime knowledge");
    const mapValue=JSON.parse(map.toString("utf8"));
    const settingsValue=JSON.parse(settings.toString("utf8"));
    if(mapValue?.schema_version!==2||!Array.isArray(mapValue.documents)
      ||mapValue.documents.length!==value.knowledge.enabled_document_count) throw new Error("map count");
    if(settingsValue?.schema_version!==1||settingsValue.workspace_slug!==String(process.env.ANYTHINGLLM_WORKSPACE||"crisp-support")
      ||typeof settingsValue.temperature!=="number"||!Number.isFinite(settingsValue.temperature)
      ||settingsValue.temperature<0||settingsValue.temperature>2
      ||!Number.isSafeInteger(settingsValue.observed_at)||settingsValue.observed_at<0) throw new Error("settings");
    if(profile!==null) {
      const profileValue=JSON.parse(profile.toString("utf8"));
      if(profileValue?.schema_version!==1||profileValue.state!=="applied"
        ||!/^[a-f0-9]{64}$/.test(profileValue.fingerprint||"")
        ||digest(canonical(profileValue.profile))!==profileValue.fingerprint) throw new Error("profile");
    } else if(value.knowledge.enabled_document_count>0) throw new Error("profile missing");
    process.stdout.write(digest(projectionRaw)+":"+value.revision+":ready");
  ' 2>/dev/null) || return 1
  [[ -n "$expected" && "$actual" == "${expected}:${revision}:ready" ]]
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
    for file in knowledge-map.json knowledge-settings.json knowledge-lexical.json; do
      if [[ -f "${restore_deploy}/data/runtime/${file}" ]]; then
        install -m 640 -- "${restore_deploy}/data/runtime/${file}" "${deploy_dir}/data/runtime/${file}"
        chown root:1000 "${deploy_dir}/data/runtime/${file}" 2>/dev/null || true
      fi
    done
    rm -rf -- "$stage"
    return 0
  fi
  rm -rf -- "$stage"
  return 1
}

materials_publish_old_generation() {
  local deploy_dir=$1 old=$2 revision=$3 state=$4 output schema
  output=$(mktemp "${deploy_dir}/tmp/materials-old.XXXXXX")
  jq -M --argjson revision "$revision" --arg state "$state" --argjson now "$(date +%s)" '
    .revision=$revision | .state=$state | .applied_at=$now |
    .configuration.runtime.revision=$revision |
    .configuration.runtime.applied_revision=(if $state == "applied" then $revision else (.configuration.runtime.applied_revision // 0) end)
  ' "$old" > "$output"
  schema=$(jq -M -er '.schema_version' "$output") || { rm -f -- "$output"; return 1; }
  if [[ "$schema" == 1 ]]; then
    materials_projection_write_legacy "$deploy_dir" "$output"
  else
    materials_projection_write "$deploy_dir" "$output"
  fi
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

materials_set_runtime_disable_epoch() {
  local deploy_dir=$1 epoch=$2 target="${1}/config/runtime.yaml" normalized temporary
  [[ "$epoch" =~ ^[0-9]+$ ]] && (( epoch <= 2147483647 )) || {
    materials_error '客服停用控制代次已达到安全边界，拒绝应用未受保护的配置'
    return 1
  }
  normalized=$(mktemp "${deploy_dir}/tmp/runtime-disable-epoch.XXXXXX")
  materials_normalize_configuration runtime "$target" "$normalized" \
    || { rm -f -- "$normalized"; return 1; }
  temporary=$(mktemp "${target}.tmp.XXXXXX")
  jq -M --argjson epoch "$epoch" '.schema_version=2 | .disable_epoch=$epoch' "$normalized" > "$temporary" \
    || { rm -f -- "$normalized" "$temporary"; return 1; }
  rm -f -- "$normalized"
  chmod 640 "$temporary"
  chown root:1000 "$temporary" 2>/dev/null || true
  mv -f -- "$temporary" "$target"
}

materials_initialize() (
  local deploy_dir=$1 projection="${1}/config/materials-applied.json" stage revision snapshot candidate_snapshot runtime_normalized
  local had_projection=false legacy=false legacy_archive='' failed=false
  if [[ -e "$projection" || -L "$projection" ]]; then
    if materials_projection_validate "$projection"; then
      return 0
    elif materials_projection_validate_legacy "$projection"; then
      had_projection=true
      legacy=true
    else
      materials_error '现有资料投影损坏，拒绝回退读取可编辑原文'
      return 1
    fi
  fi
  acquire_maintenance_lock "$deploy_dir"
  # 锁建立后重新核对；等待期间其他维护任务可能已经完成迁移。
  if [[ -e "$projection" || -L "$projection" ]]; then
    if materials_projection_validate "$projection"; then return 0; fi
    materials_projection_validate_legacy "$projection" \
      || { materials_error '资料投影在迁移前发生变化，拒绝继续'; return 1; }
    had_projection=true
    legacy=true
  fi
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
  if [[ "$legacy" == true ]]; then
    revision=$(jq -M -r --argjson runtime "$revision" '[.revision,$runtime] | max' "$projection")
    legacy_archive=$(mktemp -d "${deploy_dir}/backups/config-history/materials-v1-migration.XXXXXXXX")
    chmod 700 "$legacy_archive"
    install -m 600 -- "$projection" "${legacy_archive}/materials-applied-v1.json"
    if [[ -f "${deploy_dir}/backups/config-history/materials.applied.tar.gz" \
      && ! -L "${deploy_dir}/backups/config-history/materials.applied.tar.gz" ]]; then
      install -m 600 -- "${deploy_dir}/backups/config-history/materials.applied.tar.gz" \
        "${legacy_archive}/materials.applied.tar.gz"
    fi
  fi
  rm -f -- "$runtime_normalized"
  stage=$(mktemp -d "${deploy_dir}/tmp/materials-initialize.XXXXXXXX")
  install -m 600 -- "${deploy_dir}/config/runtime.yaml" "${stage}/runtime.previous.yaml"
  if [[ "$had_projection" == true ]]; then
    install -m 600 -- "$projection" "${stage}/materials.previous.json"
  fi
  materials_prepare_candidate "$deploy_dir" "$stage" "$revision" applied || { rm -rf -- "$stage"; return 1; }
  candidate_snapshot="${stage}/materials.applied.tar.gz"
  materials_snapshot_create "$deploy_dir" "$candidate_snapshot" || { rm -rf -- "$stage"; return 1; }
  materials_finalize_runtime_source "$deploy_dir" "$revision" || failed=true
  if [[ "$failed" == false ]]; then
    materials_projection_write_current "$deploy_dir" "${stage}/materials-applied.json" || failed=true
  fi
  if [[ "$failed" == false ]]; then
    materials_projection_readback "$deploy_dir" || failed=true
  fi
  if [[ "$failed" == true ]]; then
    install -m 640 -- "${stage}/runtime.previous.yaml" "${deploy_dir}/config/runtime.yaml"
    chown root:1000 "${deploy_dir}/config/runtime.yaml" 2>/dev/null || true
    if [[ "$had_projection" == true ]]; then
      if [[ "$legacy" == true ]]; then
        materials_projection_write_legacy "$deploy_dir" "${stage}/materials.previous.json" || true
      else
        materials_projection_write "$deploy_dir" "${stage}/materials.previous.json" || true
      fi
    else
      rm -f -- "$projection"
    fi
    materials_error '运行容器未确认同一代资料投影；上一配置已恢复，自动回复保持受阻止直到重新应用'
    rm -rf -- "$stage"
    return 1
  fi
  snapshot="${deploy_dir}/backups/config-history/materials.applied.tar.gz"
  install -m 600 -- "$candidate_snapshot" "$snapshot"
  jq -M --argjson migrated "$legacy" '{initialized:true,migrated_from_schema_v1:$migrated,revision,state,source_sha256}' "$projection"
  rm -rf -- "$stage"
)

materials_apply() (
  local deploy_dir=$1 knowledge_mode=${2:-none} projection="${1}/config/materials-applied.json" old_snapshot old='' stage='' revision=0
  local prompt_changed knowledge_changed config_changed final_stage='' rollback_revision history candidate_snapshot result=0 recovering=false
  local transition_started=false transition_committed=false signal_status=0
  local old_disable_epoch=0 candidate_disable_epoch=0 desired_disable_epoch=0 old_enabled=true candidate_enabled=true
  if [[ -f "$projection" && ! -L "$projection" ]] \
    && ! materials_projection_validate "$projection" \
    && materials_projection_validate_legacy "$projection"; then
    # 旧 schema 只作为迁移输入；先生成并回读当前 schema，再进入普通应用事务。
    materials_initialize "$deploy_dir" >/dev/null \
      || { materials_error '旧资料投影尚未完成安全迁移，未开始本次应用'; return 1; }
  fi
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
  old_disable_epoch=$(jq -M -er '.configuration.runtime.disable_epoch // 0' "$old") || return 1
  candidate_disable_epoch=$(jq -M -er '.configuration.runtime.disable_epoch // 0' "${stage}/materials-applied.json") || return 1
  old_enabled=$(jq -M -er '.configuration.runtime.enabled' "$old") || return 1
  candidate_enabled=$(jq -M -er '.configuration.runtime.enabled' "${stage}/materials-applied.json") || return 1
  desired_disable_epoch=$old_disable_epoch
  if [[ "$old_enabled" == true && "$candidate_enabled" == false ]]; then
    (( old_disable_epoch < 2147483647 )) \
      || { materials_error '客服停用控制代次已达到安全边界，拒绝应用未受保护的配置'; return 1; }
    desired_disable_epoch=$((old_disable_epoch + 1))
  fi
  if (( candidate_disable_epoch != desired_disable_epoch )); then
    # 该内部代次只由上一份有效投影决定。失败重试不会重复递增，导入包和
    # 直接编辑也不能把旧待处理消息重新变成可发送任务。
    materials_set_runtime_disable_epoch "$deploy_dir" "$desired_disable_epoch" || return 1
    rm -rf -- "$stage"
    stage=$(mktemp -d "${deploy_dir}/tmp/materials-candidate.XXXXXXXX")
    materials_prepare_candidate "$deploy_dir" "$stage" "$revision" applied \
      || { rm -f -- "$old"; rm -rf -- "$stage"; return 1; }
  fi
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
    materials_projection_write_current "$deploy_dir" "${final_stage}/materials-applied.json"
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

materials_pool_status() {
  local deploy_dir=$1 stage source_valid=true current_valid=true pending=false current_revision=0
  if [[ ! -e "${deploy_dir}/config/provider-pool-applied.json" \
    && $(env_get "${deploy_dir}/.env" PROVIDER_POOL_REQUIRED 2>/dev/null || true) != true ]]; then
    printf '%s\n' '{"enabled":false,"source_valid":true,"current_valid":true,"pending":false}'
    return
  fi
  stage=$(mktemp -d "${deploy_dir}/tmp/materials-pool-status.XXXXXXXX")
  if ! python3 "${MATERIALS_SCRIPT_DIR}/provider-pool.py" --deploy-dir "$deploy_dir" list > "${stage}/current.json" 2>/dev/null; then
    current_valid=false
  else
    current_revision=$(jq -r '.revision' "${stage}/current.json")
  fi
  if ! python3 "${MATERIALS_SCRIPT_DIR}/provider-pool.py" --deploy-dir "$deploy_dir" validate-file \
    "${deploy_dir}/config/provider-pool.yaml" >/dev/null 2>&1 \
    || ! configuration_decode_file "${deploy_dir}/config/provider-pool.yaml" "${stage}/source.json" >/dev/null 2>&1; then
    source_valid=false
  elif [[ "$current_valid" == true ]]; then
    [[ $(jq -McS '{primary_id,entries,policy}' "${stage}/source.json") \
      == "$(jq -McS '{primary_id,entries:(.entries|map(del(.key_status))),policy}' "${stage}/current.json")" ]] || pending=true
  fi
  jq -M -n --argjson source "$source_valid" --argjson current "$current_valid" --argjson pending "$pending" --argjson revision "$current_revision" \
    '{enabled:true,source_valid:$source,current_valid:$current,pending:$pending,applied_revision:$revision}'
  rm -rf -- "$stage"
}

materials_apply_all() (
  local deploy_dir=$1 knowledge_mode=$2 state business result business_file status
  acquire_maintenance_lock "$deploy_dir"
  state=$(materials_pool_status "$deploy_dir") || return 1
  if ! jq -e '.source_valid and .current_valid' <<< "$state" >/dev/null; then
    materials_error '接口池原文或当前有效池未通过校验，未应用本次资料；请先从菜单 3 修复'
    return 1
  fi
  # 不用命令替换包住有中断收尾的子事务：进程组 SIGINT 会终止额外的
  # substitution shell，丢失内层的 130。普通文件捕获仍隔离 JSON 与说明。
  business_file=$(mktemp "${deploy_dir}/tmp/materials-result.XXXXXXXX")
  trap 'rm -f -- "$business_file"' EXIT
  if materials_apply "$deploy_dir" "$knowledge_mode" > "$business_file"; then
    business=$(<"$business_file")
  else
    status=$?
    return "$status"
  fi
  if jq -e '.enabled and .pending' <<< "$state" >/dev/null; then
    if ! result=$(python3 "${MATERIALS_SCRIPT_DIR}/provider-pool.py" --deploy-dir "$deploy_dir" apply-file "${deploy_dir}/config/provider-pool.yaml"); then
      materials_error '业务资料已完成应用，但接口池候选应用失败，仍使用上一有效池；请从菜单 3 重试或恢复接口配置'
      return 1
    fi
    jq -e '.ok == true' <<< "$result" >/dev/null || return 1
    jq -M --argjson provider "$result" '. + {provider_pool:{applied:true,changed:true,revision:$provider.revision}}' <<< "$business"
  else
    jq -M --argjson provider "$state" '. + {provider_pool:{applied:$provider.current_valid,changed:false,revision:($provider.applied_revision // null)}}' <<< "$business"
  fi
)

materials_status() {
  local deploy_dir=$1 projection="${1}/config/materials-applied.json" stage source_valid=true applied_valid=true
  local source_hash='' applied_hash='' state='missing' revision=0 pool
  if [[ -e "$projection" || -L "$projection" ]]; then
    if materials_projection_validate "$projection"; then
      applied_hash=$(jq -M -r '.source_sha256' "$projection")
      state=$(jq -M -r '.state' "$projection")
      revision=$(jq -M -r '.revision' "$projection")
    elif materials_projection_validate_legacy "$projection"; then
      applied_valid=false
      state=migration_required
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
  pool=$(materials_pool_status "$deploy_dir") || return 1
  jq -e '.source_valid' <<< "$pool" >/dev/null || source_valid=false
  jq -e '.current_valid' <<< "$pool" >/dev/null || applied_valid=false
  jq -M -n --argjson source_valid "$source_valid" --argjson applied_valid "$applied_valid" \
    --arg state "$state" --argjson revision "$revision" --arg source_hash "$source_hash" --arg applied_hash "$applied_hash" \
    --arg projection "$projection" --arg prompt "${deploy_dir}/config/prompt.md" --arg catalog "${deploy_dir}/knowledge/catalog.json" --argjson pool "$pool" \
    '{source_valid:$source_valid,projection_valid:$applied_valid,state:$state,applied_revision:$revision,
      pending:($source_valid and $applied_valid and ($state != "applied" or $source_hash != $applied_hash or $pool.pending)),provider_pool:$pool,
      source_sha256:$source_hash,applied_sha256:$applied_hash,
      paths:{projection:$projection,prompt:$prompt,knowledge_catalog:$catalog}}'
  rm -rf -- "$stage"
  [[ "$source_valid" == true && "$applied_valid" == true && "$state" == applied ]] || return 1
  [[ "$source_hash" == "$applied_hash" ]] || return 2
  ! jq -e '.pending' <<< "$pool" >/dev/null || return 2
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
  if [[ "$action" == apply || "$action" == apply-business ]]; then
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
      local stage pool
      pool=$(materials_pool_status "$deploy_dir") || return 1
      jq -e '.source_valid and .current_valid' <<< "$pool" >/dev/null \
        || { materials_error '接口池原文或有效配置未通过校验'; return 1; }
      stage=$(mktemp -d "${deploy_dir}/tmp/materials-validate.XXXXXXXX")
      materials_prepare_candidate "$deploy_dir" "$stage" 1 applied
      jq -M -n --arg hash "$(jq -M -r '.source_sha256' "${stage}/materials-applied.json")" '{valid:true,source_sha256:$hash}'
      rm -rf -- "$stage" ;;
    initialize) materials_initialize "$deploy_dir" ;;
    apply) materials_apply_all "$deploy_dir" "$knowledge_mode" ;;
    apply-business) materials_apply "$deploy_dir" "$knowledge_mode" ;;
    *) materials_error "未知资料操作：$action"; return 64 ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  # 前台子事务自行完成受阻止投影/锁清理；CLI 保留明确中断退出码。
  materials_cli_interrupt() { trap '' INT TERM; exit "$1"; }
  trap 'materials_cli_interrupt 130' INT
  trap 'materials_cli_interrupt 143' TERM
  materials_main "$@"
fi
