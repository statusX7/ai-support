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

# 只冻结用户可编辑的语义输入；manifest/map/profile/lexical 是同步过程
# 必然更换的运行投影，不能用它们误判用户编辑。catalog 身份来自调和后的
# 语义文件，因此同时绑定文档原文的实际摘要，但排除 indexed/pending 等运行状态。
materials_editable_identity_once() (
  local deploy_dir=$1 output=$2 stage name runtime_semantic base digest temporary
  local runtime_hash handoff_hash keyword_hash menu_hash tags_hash feedback_hash prompt_hash catalog_hash
  stage=$(mktemp -d "${deploy_dir}/tmp/materials-editable.XXXXXXXX") || return 1
  trap 'rm -rf -- "$stage"' EXIT
  mkdir -p -- "${stage}/config" "${stage}/knowledge" || return 1
  for name in runtime handoff keyword menu tags feedback; do
    materials_normalize_configuration "$name" "${deploy_dir}/config/${name}.yaml" \
      "${stage}/config/${name}.json" || return 1
  done
  materials_validate_prompt_file "${deploy_dir}/config/prompt.md" || return 1
  materials_reconcile_catalog "$deploy_dir" "${stage}/knowledge/catalog.json" \
    "${stage}/knowledge/catalog-semantic.json" || return 1
  runtime_semantic="${stage}/config/runtime-semantic.json"
  jq -M 'del(.revision,.applied_revision)' "${stage}/config/runtime.json" > "$runtime_semantic" \
    || return 1
  runtime_hash=$(materials_json_hash "$runtime_semantic") || return 1
  handoff_hash=$(materials_json_hash "${stage}/config/handoff.json") || return 1
  keyword_hash=$(materials_json_hash "${stage}/config/keyword.json") || return 1
  menu_hash=$(materials_json_hash "${stage}/config/menu.json") || return 1
  tags_hash=$(materials_json_hash "${stage}/config/tags.json") || return 1
  feedback_hash=$(materials_json_hash "${stage}/config/feedback.json") || return 1
  prompt_hash=$(materials_sha_or_empty "${deploy_dir}/config/prompt.md") || return 1
  catalog_hash=$(materials_json_hash "${stage}/knowledge/catalog-semantic.json") || return 1
  base="${stage}/identity-base.json"
  jq -M -n \
    --arg runtime "$runtime_hash" --arg handoff "$handoff_hash" \
    --arg keyword "$keyword_hash" --arg menu "$menu_hash" \
    --arg tags "$tags_hash" --arg feedback "$feedback_hash" \
    --arg prompt "$prompt_hash" --arg catalog "$catalog_hash" \
    '{schema_version:1,configuration:{runtime:$runtime,handoff:$handoff,keyword:$keyword,
      menu:$menu,tags:$tags,feedback:$feedback},prompt_sha256:$prompt,catalog_sha256:$catalog}' \
    > "$base" || return 1
  digest=$(materials_json_hash "$base") || return 1
  temporary=$(mktemp "${output}.tmp.XXXXXXXX") || return 1
  if ! jq -M --arg digest "$digest" '. + {identity_sha256:$digest}' "$base" > "$temporary" \
    || ! chmod 600 "$temporary" || ! mv -f -- "$temporary" "$output"; then
    rm -f -- "$temporary"
    return 1
  fi
)

materials_editable_identity_validate() {
  local input=$1
  [[ -f "$input" && ! -L "$input" && $(stat -c '%s' -- "$input") -le 65536 ]] || return 1
  jq -M -e '
    .schema_version == 1 and
    (.configuration | keys | sort) == ["feedback","handoff","keyword","menu","runtime","tags"] and
    all(.configuration[]; type == "string" and test("^[a-f0-9]{64}$")) and
    (.prompt_sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
    (.catalog_sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
    (.identity_sha256 | type == "string" and test("^[a-f0-9]{64}$"))
  ' "$input" >/dev/null || return 1
  python3 -B - "$input" <<'PY'
import hashlib
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = value.pop("identity_sha256")
encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
raise SystemExit(0 if hashlib.sha256(encoded).hexdigest() == expected else 1)
PY
}

# 连续两次从 live 原文独立生成相同身份后才接受，避免把编辑器
# 正在分步替换的中间态冻结为一个候选代。
materials_editable_identity_capture() {
  local deploy_dir=$1 output=$2 first second temporary
  first=$(mktemp "${deploy_dir}/tmp/materials-editable-first.XXXXXXXX") || return 1
  second=$(mktemp "${deploy_dir}/tmp/materials-editable-second.XXXXXXXX") \
    || { rm -f -- "$first"; return 1; }
  if ! materials_editable_identity_once "$deploy_dir" "$first" \
    || ! materials_editable_identity_once "$deploy_dir" "$second" \
    || ! materials_editable_identity_validate "$first" \
    || ! materials_editable_identity_validate "$second" \
    || ! cmp -s -- "$first" "$second"; then
    rm -f -- "$first" "$second"
    materials_error '可编辑资料在读取期间发生变化，未冻结不完整代次'
    return 1
  fi
  temporary=$(mktemp "${output}.tmp.XXXXXXXX") \
    || { rm -f -- "$first" "$second"; return 1; }
  if ! install -m 600 -- "$first" "$temporary" || ! mv -f -- "$temporary" "$output"; then
    rm -f -- "$first" "$second" "$temporary"
    return 1
  fi
  rm -f -- "$first" "$second"
}

materials_projection_editable_identity() {
  local projection=$1 output=$2 base digest temporary schema stage name runtime_hash prompt_hash catalog_hash
  local handoff_hash keyword_hash menu_hash tags_hash feedback_hash
  schema=$(jq -M -er '.schema_version' "$projection") || return 1
  base=$(mktemp "${output}.base.XXXXXXXX") || return 1
  if [[ "$schema" == 2 ]]; then
    if ! materials_projection_validate "$projection" \
      || ! jq -M '{schema_version:1,
        configuration:{runtime:.source_components.runtime,handoff:.source_components.handoff,
          keyword:.source_components.keyword,menu:.source_components.menu,
          tags:.source_components.tags,feedback:.source_components.feedback},
        prompt_sha256:.source_components.prompt,catalog_sha256:.knowledge.catalog_sha256}' \
        "$projection" > "$base"; then
      rm -f -- "$base"
      return 1
    fi
  elif [[ "$schema" == 1 ]]; then
    if ! materials_projection_validate_legacy "$projection"; then
      rm -f -- "$base"
      return 1
    fi
    stage=$(mktemp -d "${output}.legacy.XXXXXXXX") || { rm -f -- "$base"; return 1; }
    if ! jq -M '.configuration.runtime | del(.revision,.applied_revision)' "$projection" \
        > "${stage}/runtime.json"; then
      rm -rf -- "$stage"
      rm -f -- "$base"
      return 1
    fi
    for name in handoff keyword menu tags feedback; do
      if ! jq -M ".configuration.${name}" "$projection" > "${stage}/${name}.json"; then
        rm -rf -- "$stage"
        rm -f -- "$base"
        return 1
      fi
    done
    runtime_hash=$(materials_json_hash "${stage}/runtime.json") || { rm -rf -- "$stage"; rm -f -- "$base"; return 1; }
    handoff_hash=$(materials_json_hash "${stage}/handoff.json") || { rm -rf -- "$stage"; rm -f -- "$base"; return 1; }
    keyword_hash=$(materials_json_hash "${stage}/keyword.json") || { rm -rf -- "$stage"; rm -f -- "$base"; return 1; }
    menu_hash=$(materials_json_hash "${stage}/menu.json") || { rm -rf -- "$stage"; rm -f -- "$base"; return 1; }
    tags_hash=$(materials_json_hash "${stage}/tags.json") || { rm -rf -- "$stage"; rm -f -- "$base"; return 1; }
    feedback_hash=$(materials_json_hash "${stage}/feedback.json") || { rm -rf -- "$stage"; rm -f -- "$base"; return 1; }
    prompt_hash=$(jq -M -er '.prompt.sha256' "$projection") || { rm -rf -- "$stage"; rm -f -- "$base"; return 1; }
    catalog_hash=$(jq -M -er '.knowledge.catalog_sha256 | select(type == "string" and test("^[a-f0-9]{64}$"))' "$projection") \
      || { rm -rf -- "$stage"; rm -f -- "$base"; return 1; }
    if ! jq -M -n \
      --arg runtime "$runtime_hash" \
      --arg handoff "$handoff_hash" --arg keyword "$keyword_hash" \
      --arg menu "$menu_hash" --arg tags "$tags_hash" --arg feedback "$feedback_hash" \
      --arg prompt "$prompt_hash" --arg catalog "$catalog_hash" \
      '{schema_version:1,configuration:{runtime:$runtime,handoff:$handoff,keyword:$keyword,
        menu:$menu,tags:$tags,feedback:$feedback},prompt_sha256:$prompt,catalog_sha256:$catalog}' \
      > "$base"; then
      rm -rf -- "$stage"
      rm -f -- "$base"
      return 1
    fi
    rm -rf -- "$stage"
  else
    rm -f -- "$base"
    return 1
  fi
  digest=$(materials_json_hash "$base") || { rm -f -- "$base"; return 1; }
  temporary=$(mktemp "${output}.tmp.XXXXXXXX") || { rm -f -- "$base"; return 1; }
  if ! jq -M --arg digest "$digest" '. + {identity_sha256:$digest}' "$base" > "$temporary" \
    || ! chmod 600 "$temporary" || ! mv -f -- "$temporary" "$output"; then
    rm -f -- "$base" "$temporary"
    return 1
  fi
  rm -f -- "$base"
  materials_editable_identity_validate "$output"
}

materials_editable_identity_compare_live() {
  local deploy_dir=$1 expected=$2 current comparison=0
  materials_editable_identity_validate "$expected" || return 2
  current=$(mktemp "${deploy_dir}/tmp/materials-editable-current.XXXXXXXX") || return 2
  if ! materials_editable_identity_capture "$deploy_dir" "$current"; then
    rm -f -- "$current"
    return 2
  fi
  if cmp -s -- "$expected" "$current"; then
    comparison=0
  else
    comparison=$?
  fi
  rm -f -- "$current" || return 2
  case "$comparison" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

materials_editable_identity_matches_live() {
  materials_editable_identity_compare_live "$@"
}

materials_projection_validate_configuration() {
  local file=$1 stage name temporary
  stage=$(mktemp -d "${file}.validate.XXXXXXXX") || return 1
  [[ -d "$stage" && ! -L "$stage" && "$stage" == "${file}.validate."* ]] \
    || { rm -rf -- "$stage"; return 1; }
  for name in runtime handoff keyword menu tags feedback; do
    temporary="${stage}/${name}.json"
    jq -M ".configuration.${name}" "$file" > "$temporary" || { rm -rf -- "$stage"; return 1; }
    configuration_validate "$name" "$temporary" || { rm -rf -- "$stage"; return 1; }
  done
  rm -rf -- "$stage"
}

materials_projection_validate_legacy() {
  local file=$1
  [[ -f "$file" && ! -L "$file" \
    && $(stat -c '%h' -- "$file" 2>/dev/null || printf 0) == 1 \
    && $(stat -c '%s' -- "$file") -le $MATERIALS_PROJECTION_MAX_BYTES ]] || return 1
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
  [[ -f "$file" && ! -L "$file" \
    && $(stat -c '%h' -- "$file" 2>/dev/null || printf 0) == 1 \
    && $(stat -c '%s' -- "$file") -le $MATERIALS_PROJECTION_MAX_BYTES ]] || return 1
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
    (.knowledge.enabled_document_count | type == "number" and floor == . and . >= 0 and . <= 1000000) and
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
  temporary=$(mktemp "${target}.tmp.XXXXXX") || return 1
  if ! install -m 640 -- "$input" "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  chown root:1000 "$temporary" 2>/dev/null || true
  if ! mv -f -- "$temporary" "$target"; then
    rm -f -- "$temporary"
    return 1
  fi
}

materials_projection_write_legacy() {
  local deploy_dir=$1 input=$2 target="${1}/config/materials-applied.json" temporary
  materials_projection_validate_legacy "$input" || { materials_error '拒绝写入无效的旧资料投影'; return 1; }
  temporary=$(mktemp "${target}.tmp.XXXXXX") || return 1
  if ! install -m 640 -- "$input" "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  chown root:1000 "$temporary" 2>/dev/null || true
  if ! mv -f -- "$temporary" "$target"; then
    rm -f -- "$temporary"
    return 1
  fi
}

# 候选第一次生成后，发布前再从当前受管原文和运行投影独立重算一次身份。
# 维护锁由调用方持有；二次结果不一致时保留旧投影，不发布混合代次。
materials_projection_write_current() {
  local deploy_dir=$1 input=$2 revision state verify_stage expected actual
  materials_projection_validate "$input" || { materials_error '拒绝发布无效的资料投影'; return 1; }
  revision=$(jq -M -er '.revision' "$input") || return 1
  state=$(jq -M -er '.state' "$input") || return 1
  verify_stage=$(mktemp -d "${deploy_dir}/tmp/materials-publish-verify.XXXXXXXX") || return 1
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
  if ! materials_projection_write "$deploy_dir" "$input"; then
    rm -rf -- "$verify_stage"
    return 1
  fi
  rm -rf -- "$verify_stage" || return 1
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
  stage=$(mktemp -d "${deploy_dir}/tmp/materials-snapshot.XXXXXXXX") || return 1
  mkdir -p -- "${stage}/config" "${stage}/knowledge" || { rm -rf -- "$stage"; return 1; }
  for name in runtime handoff keyword menu tags feedback; do
    install -m 600 -- "${deploy_dir}/config/${name}.yaml" "${stage}/config/${name}.yaml" \
      || { rm -rf -- "$stage"; return 1; }
  done
  install -m 600 -- "${deploy_dir}/config/prompt.md" "${stage}/config/prompt.md" \
    || { rm -rf -- "$stage"; return 1; }
  install -m 600 -- "${deploy_dir}/knowledge/catalog.json" "${stage}/knowledge/catalog.json" \
    || { rm -rf -- "$stage"; return 1; }
  while IFS= read -r library; do
    mkdir -m 700 -p -- "${stage}/knowledge/${library}/sources" \
      || { rm -rf -- "$stage"; return 1; }
  done < <(jq -M -r '.libraries[].id' "${deploy_dir}/knowledge/catalog.json")
  while IFS= read -r row; do
    library=$(jq -M -r '.library' <<< "$row")
    source=$(jq -M -r '.source' <<< "$row")
    install -D -m 600 -- "${deploy_dir}/knowledge/${library}/${source}" "${stage}/knowledge/${library}/${source}" \
      || { rm -rf -- "$stage"; return 1; }
  done < <(jq -M -c '.libraries[] | .id as $library | .documents[] | {library:$library,source:.source}' "${deploy_dir}/knowledge/catalog.json")
  temporary=$(mktemp "${output}.tmp.XXXXXX") || { rm -rf -- "$stage"; return 1; }
  if ! tar -czf "$temporary" -C "$stage" config knowledge \
    || ! chmod 600 "$temporary" \
    || ! mv -f -- "$temporary" "$output"; then
    rm -f -- "$temporary"
    rm -rf -- "$stage"
    return 1
  fi
  rm -rf -- "$stage"
}

materials_snapshot_extract() {
  local snapshot=$1 destination=$2
  [[ -f "$snapshot" && ! -L "$snapshot" ]] || return 1
  python3 -B "${MATERIALS_SCRIPT_DIR}/archive-guard.py" "$snapshot" --kind materials --max-bytes 53687091200 \
    >/dev/null || return 1
  mkdir -p -- "$destination" || return 1
  tar -xzf "$snapshot" -C "$destination" --no-same-owner --no-same-permissions || return 1
  [[ -f "${destination}/config/prompt.md" && -f "${destination}/knowledge/catalog.json" ]] || return 1
}

materials_snapshot_validate_generation() {
  local deploy_dir=$1 snapshot=$2 projection=$3 stage restore_deploy name normalized semantic runtime_semantic actual expected
  local manifest_hash map_hash settings_hash profile_hash lexical_hash enabled_document_count expected_workspace
  materials_projection_validate "$projection" || return 1
  jq -M -e '.state == "applied"' "$projection" >/dev/null || return 1
  stage=$(mktemp -d "${deploy_dir}/tmp/materials-snapshot-validate.XXXXXXXX") || return 1
  restore_deploy="${stage}/deploy"
  if ! materials_snapshot_extract "$snapshot" "$restore_deploy"; then
    rm -rf -- "$stage"
    return 1
  fi
  mkdir -p -- "${restore_deploy}/tmp" || { rm -rf -- "$stage"; return 1; }
  knowledge_catalog_validate "${restore_deploy}/knowledge/catalog.json" || { rm -rf -- "$stage"; return 1; }
  while IFS= read -r library; do
    mkdir -m 700 -p -- "${restore_deploy}/knowledge/${library}/sources" \
      || { rm -rf -- "$stage"; return 1; }
  done < <(jq -M -r '.libraries[].id' "${restore_deploy}/knowledge/catalog.json")
  for name in runtime handoff keyword menu tags feedback; do
    normalized="${stage}/${name}.json"
    if ! materials_normalize_configuration "$name" "${restore_deploy}/config/${name}.yaml" "$normalized"; then
      rm -rf -- "$stage"
      return 1
    fi
    if [[ "$name" == runtime ]]; then
      runtime_semantic="${stage}/runtime-semantic.json"
      jq -M 'del(.revision,.applied_revision)' "$normalized" > "$runtime_semantic" || { rm -rf -- "$stage"; return 1; }
      actual=$(materials_json_hash "$runtime_semantic") || { rm -rf -- "$stage"; return 1; }
    else
      actual=$(materials_json_hash "$normalized") || { rm -rf -- "$stage"; return 1; }
    fi
    expected=$(jq -M -er --arg name "$name" '.source_components[$name]' "$projection") \
      || { rm -rf -- "$stage"; return 1; }
    [[ "$actual" == "$expected" ]] || { rm -rf -- "$stage"; return 1; }
  done
  [[ $(materials_sha_or_empty "${restore_deploy}/config/prompt.md") == "$(jq -M -er '.prompt.sha256' "$projection")" ]] \
    || { rm -rf -- "$stage"; return 1; }
  [[ $(<"${restore_deploy}/config/prompt.md") == "$(jq -M -er '.prompt.text' "$projection")" ]] \
    || { rm -rf -- "$stage"; return 1; }
  semantic="${stage}/catalog-semantic.json"
  if ! materials_reconcile_catalog "$restore_deploy" "${stage}/catalog.json" "$semantic"; then
    rm -rf -- "$stage"
    return 1
  fi
  actual=$(materials_json_hash "$semantic") || { rm -rf -- "$stage"; return 1; }
  expected=$(jq -M -er '.knowledge.catalog_sha256' "$projection") || { rm -rf -- "$stage"; return 1; }
  if [[ "$actual" != "$expected" ]] || ! jq -M -e --slurpfile candidate "${stage}/catalog.json" '
    .knowledge.catalog_revision == ($candidate[0].revision // 0) and
    .knowledge.enabled_library_ids == [$candidate[0].libraries[] | select(.enabled) | .id] and
    .knowledge.library_count == ($candidate[0].libraries | length) and
    .knowledge.document_count == ([$candidate[0].libraries[].documents[]] | length)
  ' "$projection" >/dev/null; then
    rm -rf -- "$stage"
    return 1
  fi
  manifest_hash=$(materials_required_hash "${deploy_dir}/data/knowledge-manifest.json" \
    "$MATERIALS_PROJECTION_MAX_BYTES" '知识清单') || { rm -rf -- "$stage"; return 1; }
  map_hash=$(materials_required_hash "${deploy_dir}/data/runtime/knowledge-map.json" \
    "$MATERIALS_PROJECTION_MAX_BYTES" '运行时知识映射') || { rm -rf -- "$stage"; return 1; }
  settings_hash=$(materials_required_hash "${deploy_dir}/data/runtime/knowledge-settings.json" \
    65536 '知识运行设置') || { rm -rf -- "$stage"; return 1; }
  expected_workspace=$(env_get "${deploy_dir}/.env" ANYTHINGLLM_WORKSPACE) \
    || { rm -rf -- "$stage"; return 1; }
  [[ "$expected_workspace" =~ ^[A-Za-z0-9_-]{1,128}$ ]] \
    || { rm -rf -- "$stage"; return 1; }
  jq -M -e --arg workspace "$expected_workspace" '
    .schema_version == 1 and .workspace_slug == $workspace and
    (.temperature | type == "number" and isfinite and . >= 0 and . <= 2) and
    (.observed_at | type == "number" and floor == . and . >= 0)
  ' "${deploy_dir}/data/runtime/knowledge-settings.json" >/dev/null \
    || { rm -rf -- "$stage"; return 1; }
  profile_hash=$(materials_optional_hash "${deploy_dir}/data/runtime/knowledge-profile.json" \
    65536 '知识索引代次') || { rm -rf -- "$stage"; return 1; }
  lexical_hash=$(materials_required_hash "${deploy_dir}/data/runtime/knowledge-lexical.json" \
    "$MATERIALS_PROJECTION_MAX_BYTES" '词法补召回索引') || { rm -rf -- "$stage"; return 1; }
  enabled_document_count=$(jq -M -er '.documents | length' \
    "${deploy_dir}/data/runtime/knowledge-map.json") || { rm -rf -- "$stage"; return 1; }
  if ! jq -M -e --arg manifest "$manifest_hash" --arg map "$map_hash" \
    --arg settings "$settings_hash" --arg profile "$profile_hash" --arg lexical "$lexical_hash" \
    --argjson enabled "$enabled_document_count" '
      .knowledge.manifest_sha256 == $manifest and
      .knowledge.map_sha256 == $map and
      .knowledge.settings_sha256 == $settings and
      .knowledge.profile_sha256 == $profile and
      .knowledge.lexical_sha256 == $lexical and
      .knowledge.enabled_document_count == $enabled
    ' "$projection" >/dev/null; then
    rm -rf -- "$stage"
    return 1
  fi
  if ! materials_knowledge_generation_validate "$deploy_dir" "${restore_deploy}/knowledge/catalog.json"; then
    rm -rf -- "$stage"
    return 1
  fi
  rm -rf -- "$stage"
}

materials_applied_external_readback() {
  local deploy_dir=$1 snapshot=$2 projection=$3 stage restore_deploy locations
  stage=$(mktemp -d "${deploy_dir}/tmp/materials-applied-readback.XXXXXXXX") || return 1
  restore_deploy="${stage}/deploy"
  if ! materials_snapshot_extract "$snapshot" "$restore_deploy" \
    || ! configuration_prompt_verify_file "$deploy_dir" "${restore_deploy}/config/prompt.md"; then
    rm -rf -- "$stage"
    return 1
  fi
  anythingllm_connection "$deploy_dir"
  locations=$(anythingllm_workspace_locations) || { rm -rf -- "$stage"; return 1; }
  if ! jq -M -en --slurpfile catalog "${restore_deploy}/knowledge/catalog.json" \
    --slurpfile manifest "${deploy_dir}/data/knowledge-manifest.json" --argjson locations "$locations" '
      all($catalog[0].libraries[] | select(.enabled) | .documents[]; . as $document |
        ($manifest[0].files[$document.projection].sha256 == $document.sha256) and
        (($manifest[0].files[$document.projection].locations // []) | length > 0) and
        all($manifest[0].files[$document.projection].locations[]; . as $location |
          $locations | index($location) != null)) and
      all($catalog[0].libraries[] | select(.enabled == false) | .documents[]; . as $document |
        $manifest[0].files[$document.projection] == null)
    ' >/dev/null \
    || ! materials_snapshot_validate_generation "$deploy_dir" "$snapshot" "$projection" \
    || ! materials_projection_readback "$deploy_dir"; then
    rm -rf -- "$stage"
    return 1
  fi
  rm -rf -- "$stage"
}

materials_recovery_clear() {
  local deploy_dir=$1 recovery="${1}/backups/config-history/materials.recovery" result
  [[ ! -e "$recovery" && ! -L "$recovery" ]] && return 0
  [[ -d "$recovery" && ! -L "$recovery" ]] || return 1
  # cleanup.json 是尚未完成的外部删除责任；不能随恢复目录一起丢弃。
  [[ ! -e "${recovery}/cleanup.json" && ! -L "${recovery}/cleanup.json" \
    && ! -e "${recovery}/touched.json" && ! -L "${recovery}/touched.json" \
    && ! -e "${recovery}/upload-response.json" && ! -L "${recovery}/upload-response.json" \
    && ! -e "${recovery}/upload-intent.json" && ! -L "${recovery}/upload-intent.json" \
    && ! -e "${recovery}/upload-payload" && ! -L "${recovery}/upload-payload" ]] || return 1
  result=$(python3 -B "${MATERIALS_SCRIPT_DIR}/materials-recovery.py" --deploy-dir "$deploy_dir" \
    --recovery "$recovery" retire) || return 1
  jq -M -e '.ok == true and .action == "retire" and (.cleaned | type == "boolean")' <<< "$result" >/dev/null \
    || return 1
  if ! jq -M -e '.cleaned == true' <<< "$result" >/dev/null; then
    recovery_cleanup_pending=true
    materials_error '旧资料事务已原子退役，但尚有受限清理目录待下次维护收口'
  fi
}

materials_recovery_cleanup_retired() {
  local deploy_dir=$1 recovery="${1}/backups/config-history/materials.recovery" result
  result=$(python3 -B "${MATERIALS_SCRIPT_DIR}/materials-recovery.py" --deploy-dir "$deploy_dir" \
    --recovery "$recovery" cleanup-retired) || return 1
  jq -M -e '.ok == true and .action == "cleanup-retired" and (.cleaned | type == "boolean")' <<< "$result" >/dev/null \
    || return 1
  if ! jq -M -e '.cleaned == true' <<< "$result" >/dev/null; then
    recovery_cleanup_pending=true
    materials_error '上次已退役资料事务仍有未删除目录；不影响当前生效代，将继续安全重试'
  fi
}

materials_recovery_cleanup_orphans() {
  local deploy_dir=$1 recovery="${1}/backups/config-history/materials.recovery" result
  result=$(python3 -B "${MATERIALS_SCRIPT_DIR}/materials-recovery.py" --deploy-dir "$deploy_dir" \
    --recovery "$recovery" cleanup-orphans) || return 1
  jq -M -e '.ok == true and .action == "cleanup-orphans" and (.removed | type == "array")' \
    <<< "$result" >/dev/null || return 1
}

materials_snapshot_publish() {
  local deploy_dir=$1 source=$2 target=$3 temporary
  [[ -f "$source" && ! -L "$source" ]] || return 1
  [[ "$target" == "${deploy_dir}/backups/config-history/materials.applied.tar.gz" ]] || return 1
  [[ ! -L "$target" ]] || return 1
  # 调用方持有本实例维护锁。先收口上一次在 install 与 mv 之间被
  # SIGKILL 遗留的严格命名临时文件，避免长期占用一整份 canonical 空间；
  # helper 会核对名称、类型、归属、权限、链接数和大小，绝不泛删同目录。
  materials_recovery_cleanup_orphans "$deploy_dir" || return 1
  temporary=$(mktemp "${target}.tmp.XXXXXXXX") || return 1
  if ! install -m 600 -- "$source" "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  if ! mv -f -- "$temporary" "$target"; then
    rm -f -- "$temporary"
    return 1
  fi
}

materials_knowledge_generation_validate() {
  local deploy_dir=$1 catalog=$2
  [[ -f "$catalog" && ! -L "$catalog" ]] || return 1
  if [[ "$catalog" != "${deploy_dir}/knowledge/catalog.json" ]]; then
    [[ "$catalog" == "${deploy_dir}/tmp/"* ]] || return 1
    [[ $(realpath -e -- "$catalog") == "$(realpath -e -- "${deploy_dir}/tmp")/"* ]] || return 1
  fi
  if [[ -f "${deploy_dir}/data/runtime/knowledge-profile.json" && ! -L "${deploy_dir}/data/runtime/knowledge-profile.json" ]]; then
    python3 -B "${MATERIALS_SCRIPT_DIR}/knowledge-profile.py" --deploy-dir "$deploy_dir" \
      refresh-bindings --validate-only --require-complete >/dev/null || return 1
  else
    jq -M -e '(.embedding_profile // "") == "" and .files == {} and .pending_files == {} and .garbage_locations == []' \
      "${deploy_dir}/data/knowledge-manifest.json" >/dev/null \
      && jq -M -e '.schema_version == 2 and .documents == []' "${deploy_dir}/data/runtime/knowledge-map.json" >/dev/null \
      || return 1
  fi
  knowledge_catalog_validate "$catalog" || return 1
  # catalog、manifest、供运行时消费的 map 及投影清单必须是同一完整代。
  # profile/cache 门禁不会证明文档归属，单独核对可防止把旧 map
  # 与新 manifest 一起冻结成“可恢复”的混合快照。
  jq -M -e --slurpfile manifest "${deploy_dir}/data/knowledge-manifest.json" \
    --slurpfile map "${deploy_dir}/data/runtime/knowledge-map.json" \
    --slurpfile projected "${deploy_dir}/data/knowledge-projection.json" '
    [.libraries[] | select(.enabled) | . as $library | .documents[] |
      {library_id:$library.id,library_name:$library.name,document_id:.id,
       projection:.projection,sha256:.sha256}] as $documents |
    ($documents | map(.projection) | length) == ($documents | map(.projection) | unique | length) and
    (($manifest[0].files | keys | sort) == ($documents | map(.projection) | sort)) and
    all($documents[]; . as $document |
      ($manifest[0].files[$document.projection].sha256 == $document.sha256) and
      (($manifest[0].files[$document.projection].locations // []) | type == "array" and length > 0)) and
    ($projected[0] == ($documents | map(.projection) | unique | sort)) and
    ($map[0].schema_version == 2) and ($map[0].revision == (.revision // 0)) and
    ($map[0].documents == [
      $documents[] as $document |
      $manifest[0].files[$document.projection].locations[] |
      {location:.,library_id:$document.library_id,library_name:$document.library_name,
       document_id:$document.document_id,projection:$document.projection}
    ])
  ' "$catalog" >/dev/null || return 1
  python3 -B "${MATERIALS_SCRIPT_DIR}/knowledge-lexical.py" verify --deploy-dir "$deploy_dir" \
    >/dev/null || return 1
}

materials_recovery_capture() {
  local deploy_dir=$1 projection=$2 snapshot=$3 recovery="${1}/backups/config-history/materials.recovery"
  local workspace
  if [[ -e "$recovery" || -L "$recovery" ]]; then
    materials_error '发现未收口的资料恢复事务，拒绝覆盖旧代保全'
    return 1
  fi
  materials_applied_external_readback "$deploy_dir" "$snapshot" "$projection" \
    || { materials_error '上一有效原文包与生效投影不一致，未开始外部修改'; return 1; }
  anythingllm_connection "$deploy_dir"
  workspace=$(mktemp "${deploy_dir}/tmp/materials-workspace.XXXXXXXX") || return 1
  if ! anythingllm_workspace_locations > "$workspace"; then
    rm -f -- "$workspace"
    materials_error '无法冻结当前工作区位置，未开始外部修改'
    return 1
  fi
  if ! python3 -B "${MATERIALS_SCRIPT_DIR}/materials-recovery.py" --deploy-dir "$deploy_dir" \
    --recovery "$recovery" capture --projection "$projection" --snapshot "$snapshot" \
    --workspace-locations "$workspace" >/dev/null; then
    rm -f -- "$workspace"
    materials_error '上一有效资料代未能成套冻结，未开始外部修改'
    return 1
  fi
  rm -f -- "$workspace"
}

# common.sh 在一次上传前调用这个可选 hook。curl 直接把响应落入 recovery，
# 因此进程在收到 location 后、写 manifest 前退出时，恢复仍能取得清理责任。
materials_recovery_upload_response_file() {
  local deploy_dir=$1 filename=$2 source=$3 recovery="${1}/backups/config-history/materials.recovery"
  local response="${1}/backups/config-history/materials.recovery/upload-response.json"
  local intent="${1}/backups/config-history/materials.recovery/upload-intent.json"
  [[ -d "$recovery" && ! -L "$recovery" ]] || return 1
  [[ -n "$filename" && "$filename" != . && "$filename" != .. && "$filename" != */* && "$filename" != *\\* \
    && "$filename" != *$'\n'* && "$filename" != *$'\r'* \
    && "$filename" != *';'* && "$filename" != *','* ]] || return 1
  [[ ! -e "$response" && ! -L "$response" && ! -e "$intent" && ! -L "$intent" ]] || return 1
  python3 -B "${MATERIALS_SCRIPT_DIR}/materials-recovery.py" --deploy-dir "$deploy_dir" \
    --recovery "$recovery" begin-upload --filename "$filename" --source "$source" >/dev/null || return 1
  if ! (umask 077; : > "$response"); then
    rm -f -- "$intent"
    return 1
  fi
  printf '%s\n' "$response"
}

materials_recovery_track_locations() {
  local deploy_dir=$1 additions=$2 recovery="${1}/backups/config-history/materials.recovery"
  local ledger="${1}/backups/config-history/materials.recovery/touched.json" existing='[]' merged observed temporary
  [[ -d "$recovery" && ! -L "$recovery" ]] || return 1
  jq -M -en --argjson value "$additions" '
    $value | type == "array" and length > 0 and
    all(.[]; type == "string" and test("^custom-documents/[^/\\\\[:cntrl:]]+\\.json$"))
  ' >/dev/null || return 1
  # AnythingLLM 的响应正文不能授权删除任意既有文档。只有使用本事务随机
  # alias 后在本实例持久卷真实出现、且不在冻结基线中的位置才归本次责任。
  observed=$(python3 -B "${MATERIALS_SCRIPT_DIR}/materials-recovery.py" --deploy-dir "$deploy_dir" \
    --recovery "$recovery" resolve-upload) || return 1
  jq -M -en --argjson claimed "$additions" --argjson observed "$observed" \
    '($claimed | unique | sort) == ($observed | unique | sort) and ($observed | length > 0)' \
    >/dev/null || return 1
  if [[ -e "$ledger" || -L "$ledger" ]]; then
    [[ -f "$ledger" && ! -L "$ledger" ]] || return 1
    existing=$(jq -M -ce 'select(.schema_version == 1) | .locations' "$ledger") || return 1
  fi
  merged=$(jq -M -cn --argjson old "$existing" --argjson add "$additions" '$old + $add | unique') || return 1
  temporary=$(mktemp "${recovery}.touched.XXXXXXXX") || return 1
  if ! jq -M -n --argjson locations "$merged" '{schema_version:1,locations:$locations}' > "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  chmod 600 "$temporary" || { rm -f -- "$temporary"; return 1; }
  mv -f -- "$temporary" "$ledger"
}

materials_recovery_ingest_upload_response() {
  local deploy_dir=$1 recovery="${1}/backups/config-history/materials.recovery"
  local response="${1}/backups/config-history/materials.recovery/upload-response.json"
  local intent="${1}/backups/config-history/materials.recovery/upload-intent.json" locations='[]'
  python3 -B "${MATERIALS_SCRIPT_DIR}/materials-recovery.py" --deploy-dir "$deploy_dir" \
    --recovery "$recovery" cleanup-upload-orphan >/dev/null || return 1
  [[ ! -e "$response" && ! -L "$response" && ! -e "$intent" && ! -L "$intent" ]] && return 0
  [[ -f "$intent" && ! -L "$intent" ]] || return 1
  if [[ -e "$response" || -L "$response" ]]; then
    [[ -f "$response" && ! -L "$response" ]] || return 1
  fi
  locations=$(python3 -B "${MATERIALS_SCRIPT_DIR}/materials-recovery.py" --deploy-dir "$deploy_dir" \
    --recovery "$recovery" resolve-upload) || return 1
  if [[ "$locations" == '[]' ]]; then
    materials_recovery_retry_upload "$deploy_dir" || return 1
    locations=$(python3 -B "${MATERIALS_SCRIPT_DIR}/materials-recovery.py" --deploy-dir "$deploy_dir" \
      --recovery "$recovery" resolve-upload) || return 1
  fi
  [[ "$locations" != '[]' ]] || return 1
  if [[ "$locations" != '[]' ]]; then
    materials_recovery_track_locations "$deploy_dir" "$locations" || return 1
  fi
  rm -f -- "$response" "$intent" "${recovery}/upload-payload" || return 1
}

materials_recovery_retry_upload() {
  local deploy_dir=$1 recovery="${1}/backups/config-history/materials.recovery"
  local response="${1}/backups/config-history/materials.recovery/upload-response.json"
  local intent="${1}/backups/config-history/materials.recovery/upload-intent.json"
  local alias upload_config status_file escaped_key status=000 curl_result=0
  python3 -B "${MATERIALS_SCRIPT_DIR}/materials-recovery.py" --deploy-dir "$deploy_dir" \
    --recovery "$recovery" validate >/dev/null || return 1
  alias=$(jq -M -er '.upload_filename | select(type == "string" and test("^crispai-upload-[a-f0-9]{32}\\.[A-Za-z0-9]{1,16}$"))' \
    "$intent") || return 1
  upload_config=$(mktemp "${deploy_dir}/tmp/materials-retry-curl.XXXXXXXX") || return 1
  status_file=$(mktemp "${deploy_dir}/tmp/materials-retry-status.XXXXXXXX") \
    || { rm -f -- "$upload_config"; return 1; }
  chmod 600 "$upload_config" "$status_file" || { rm -f -- "$upload_config" "$status_file"; return 1; }
  escaped_key=$(curl_config_escape "$ANYTHING_KEY") \
    || { rm -f -- "$upload_config" "$status_file"; return 1; }
  printf 'header = "Authorization: Bearer %s"\n' "$escaped_key" > "$upload_config" \
    || { rm -f -- "$upload_config" "$status_file"; return 1; }
  if (umask 077; cd "$recovery" && curl --silent --output "$response" --write-out '%{http_code}' \
    --connect-timeout 5 --max-time 300 --config "$upload_config" \
    --form "file=@upload-payload;filename=${alias}" \
    "http://127.0.0.1:${ANYTHING_PORT}/api/v1/document/upload" 2>/dev/null) > "$status_file"; then
    curl_result=0
  else
    curl_result=$?
  fi
  status=$(<"$status_file")
  rm -f -- "$upload_config" "$status_file"
  # 响应正文或 alias 扫描由调用方统一收口；即使 curl/HTTP
  # 失败，请求也可能已落盘，不在这里删除责任。
  [[ "$curl_result" =~ ^[0-9]+$ && "$status" =~ ^[0-9]{3}$ ]]
}

materials_recovery_finish_upload() {
  local recovery="${1}/backups/config-history/materials.recovery"
  [[ -d "$recovery" && ! -L "$recovery" ]] || return 1
  rm -f -- "${recovery}/upload-response.json" "${recovery}/upload-intent.json" "${recovery}/upload-payload"
}

materials_recovery_finish_tracking() {
  local recovery="${1}/backups/config-history/materials.recovery"
  [[ -d "$recovery" && ! -L "$recovery" ]] || return 1
  [[ ! -e "${recovery}/cleanup.json" && ! -L "${recovery}/cleanup.json" \
    && ! -e "${recovery}/upload-response.json" && ! -L "${recovery}/upload-response.json" \
    && ! -e "${recovery}/upload-intent.json" && ! -L "${recovery}/upload-intent.json" ]] || return 1
  [[ ! -e "${recovery}/upload-payload" && ! -L "${recovery}/upload-payload" ]] || return 1
  rm -f -- "${recovery}/touched.json"
}

materials_cleanup_ledger_retry() {
  local deploy_dir=$1 recovery=$2 ledger="${2}/cleanup.json" touched="${2}/touched.json"
  local locations payload remaining='[]' temporary
  [[ ! -e "$ledger" && ! -L "$ledger" ]] && return 0
  python3 -B "${MATERIALS_SCRIPT_DIR}/materials-recovery.py" --deploy-dir "$deploy_dir" \
    --recovery "$recovery" validate >/dev/null || return 1
  locations=$(jq -M -ce '
    if .schema_version == 1 and (.locations | type == "array") and
      (.locations | length > 0) and all(.locations[]; type == "string")
    then .locations else empty end
  ' "$ledger") || return 1
  payload=$(jq -M -cn --argjson deletes "$locations" '{adds:[],deletes:$deletes}') || return 1
  anythingllm_update_embeddings "$payload" || return 1
  if ! anythingllm_remove_documents "$locations"; then
    # 删除请求可能已经在服务端完成但响应丢失。只有所有受管源文件都已从
    # 本实例持久卷消失时才收敛为成功；仍存在或路径异常时继续保留责任。
    while IFS= read -r location; do
      [[ "$location" == custom-documents/* && "$location" != *'/'*'/'* \
        && "$location" != *\\* && "$location" != *$'\n'* && "$location" != *$'\r'* ]] || return 1
      [[ ! -e "${deploy_dir}/data/anythingllm/documents/${location}" \
        && ! -L "${deploy_dir}/data/anythingllm/documents/${location}" ]] || return 1
    done < <(jq -M -r '.[]' <<< "$locations")
  fi
  if [[ -e "$touched" || -L "$touched" ]]; then
    [[ -f "$touched" && ! -L "$touched" ]] || return 1
    remaining=$(jq -M -cn --slurpfile touched "$touched" --argjson removed "$locations" \
      '($touched[0].locations // []) - $removed') || return 1
    if [[ "$remaining" == '[]' ]]; then
      rm -f -- "$touched" || return 1
    else
      temporary=$(mktemp "${recovery}.touched.XXXXXXXX") || return 1
      if ! jq -M -n --argjson locations "$remaining" '{schema_version:1,locations:$locations}' > "$temporary"; then
        rm -f -- "$temporary"
        return 1
      fi
      chmod 600 "$temporary" || { rm -f -- "$temporary"; return 1; }
      mv -f -- "$temporary" "$touched" || return 1
    fi
  fi
  rm -f -- "$ledger"
}

materials_cleanup_ledger_write() {
  local recovery=$1 locations=$2 ledger="${1}/cleanup.json" temporary
  [[ -d "$recovery" && ! -L "$recovery" ]] || return 1
  [[ ! -e "$ledger" && ! -L "$ledger" ]] || return 1
  temporary=$(mktemp "${recovery}.cleanup.XXXXXXXX") || return 1
  if ! jq -M -n --argjson locations "$locations" \
    '{schema_version:1,locations:$locations}' > "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  chmod 600 "$temporary" || { rm -f -- "$temporary"; return 1; }
  mv -f -- "$temporary" "$ledger"
}

materials_cleanup_workspace_delta() {
  local deploy_dir=$1 recovery=$2 actual=$3 baseline managed ledger transient touched='[]' delta cleanup unknown foreign
  materials_recovery_ingest_upload_response "$deploy_dir" || return 1
  # 两个外部删除调用之间崩溃时，先按持久清理责任幂等收口，再重新读取
  # workspace；不能使用崩溃前已经过期的列表。
  materials_cleanup_ledger_retry "$deploy_dir" "$recovery" || return 1
  anythingllm_workspace_locations > "$actual" || return 1
  baseline=$(python3 -B "${MATERIALS_SCRIPT_DIR}/materials-recovery.py" --deploy-dir "$deploy_dir" \
    --recovery "$recovery" baseline-locations) || return 1
  managed=$(python3 -B "${MATERIALS_SCRIPT_DIR}/materials-recovery.py" --deploy-dir "$deploy_dir" \
    --recovery "$recovery" managed-locations) || return 1
  delta=$(jq -M -cn --argjson current "$(<"$actual")" --argjson baseline "$baseline" '$current - $baseline') || return 1
  ledger=$(jq -M -c '[
    ((.files // {})[] | (.locations // [])[]),
    ((.pending_files // {})[] | ((.locations // [])[], (.old_locations // [])[])),
    ((.garbage_locations // [])[])
  ] | map(select(type == "string")) | unique' "${deploy_dir}/data/knowledge-manifest.json") || return 1
  transient=$(jq -M -c '[
    ((.pending_files // {})[] | (.locations // [])[]),
    ((.garbage_locations // [])[])
  ] | map(select(type == "string")) | unique' "${deploy_dir}/data/knowledge-manifest.json") || return 1
  if [[ -e "${recovery}/touched.json" || -L "${recovery}/touched.json" ]]; then
    [[ -f "${recovery}/touched.json" && ! -L "${recovery}/touched.json" ]] || return 1
    touched=$(jq -M -ce 'select(.schema_version == 1) | .locations' "${recovery}/touched.json") || return 1
  fi
  cleanup=$(jq -M -cn --argjson delta "$delta" --argjson ledger "$ledger" --argjson transient "$transient" --argjson touched "$touched" \
    '([$delta[] | select(. as $item | $ledger | index($item) != null)] + $transient + $touched) | unique') || return 1
  unknown=$(jq -M -cn --argjson delta "$delta" --argjson cleanup "$cleanup" '$delta - $cleanup') || return 1
  # 新出现但没有进入本事务 manifest 的位置可能是管理员并发添加的资料；不能误删，
  # 也不能在来源不明时宣布旧代已恢复。
  [[ "$unknown" == '[]' ]] || return 1
  # 如果上游把候选上传复用了冻结时的其他（非本资料代）位置，不能删除
  # 管理员资料；旧代自身被复用的位置允许删掉，随后一律从冻结原文重建。
  foreign=$(jq -M -cn --argjson cleanup "$cleanup" --argjson baseline "$baseline" --argjson managed "$managed" \
    '$cleanup | map(select(. as $item | ($baseline | index($item) != null) and ($managed | index($item) == null)))') || return 1
  [[ "$foreign" == '[]' ]] || return 1
  [[ "$cleanup" != '[]' ]] || return 0
  materials_cleanup_ledger_write "$recovery" "$cleanup" || return 1
  materials_cleanup_ledger_retry "$deploy_dir" "$recovery"
}

materials_external_restore() {
  local deploy_dir=$1 recovery=$2 restore_prompt=${3:-true} restore_knowledge=${4:-true} revision=$5
  local stage restore_deploy current_locations restored_projection status=0
  python3 -B "${MATERIALS_SCRIPT_DIR}/materials-recovery.py" --deploy-dir "$deploy_dir" \
    --recovery "$recovery" cleanup-upload-orphan >/dev/null || return 1
  python3 -B "${MATERIALS_SCRIPT_DIR}/materials-recovery.py" --deploy-dir "$deploy_dir" \
    --recovery "$recovery" validate >/dev/null || return 1
  stage=$(mktemp -d "${deploy_dir}/tmp/materials-restore.XXXXXXXX") || return 1
  restore_deploy="${stage}/deploy"
  materials_snapshot_extract "${recovery}/source.tar.gz" "$restore_deploy" \
    || { rm -rf -- "$stage"; return 1; }
  mkdir -p -- "${restore_deploy}/tmp" "${restore_deploy}/data" \
    || { rm -rf -- "$stage"; return 1; }
  if [[ "$restore_prompt" == true ]]; then
    configuration_prompt_sync_file "$deploy_dir" "${restore_deploy}/config/prompt.md" >/dev/null 2>&1 || status=1
  fi
  if (( status == 0 )) && [[ "$restore_knowledge" == true ]]; then
    anythingllm_connection "$deploy_dir"
    current_locations=$(mktemp "${deploy_dir}/tmp/materials-workspace-current.XXXXXXXX") \
      || { rm -rf -- "$stage"; return 1; }
    if ! anythingllm_workspace_locations > "$current_locations" \
      || ! materials_cleanup_workspace_delta "$deploy_dir" "$recovery" "$current_locations"; then
      status=1
    fi
    if (( status == 0 )); then
      anythingllm_workspace_locations > "$current_locations" || status=1
      if (( status == 0 )); then
        python3 -B "${MATERIALS_SCRIPT_DIR}/materials-recovery.py" --deploy-dir "$deploy_dir" \
          --recovery "$recovery" prepare-rebuild --current-workspace-locations "$current_locations" >/dev/null \
          || status=1
      fi
      if (( status == 0 )); then
        knowledge_catalog_project "$restore_deploy" || status=1
      fi
      if (( status == 0 )); then
        knowledge_sync_legacy "$deploy_dir" 1 null "${restore_deploy}/knowledge" >&2 || status=1
      fi
      if (( status == 0 )); then
        install -m 600 -- "${restore_deploy}/data/knowledge-projection.json" \
          "${deploy_dir}/data/knowledge-projection.json" || status=1
      fi
      if (( status == 0 )); then
        knowledge_catalog_readback "$deploy_dir" all false "${restore_deploy}/knowledge/catalog.json" false || status=1
      fi
    fi
    rm -f -- "$current_locations"
  fi
  if (( status == 0 )) \
    && ! materials_knowledge_generation_validate "$deploy_dir" "${restore_deploy}/knowledge/catalog.json"; then
    status=1
  fi
  if (( status == 0 )); then
    restored_projection="${stage}/materials-restored.json"
      python3 -B "${MATERIALS_SCRIPT_DIR}/materials-recovery.py" --deploy-dir "$deploy_dir" \
        --recovery "$recovery" build-projection --revision "$revision" --output "$restored_projection" >/dev/null \
      && materials_snapshot_publish "$deploy_dir" "${recovery}/source.tar.gz" \
        "${deploy_dir}/backups/config-history/materials.applied.tar.gz" \
      && materials_projection_write "$deploy_dir" "$restored_projection" \
      && materials_applied_external_readback "$deploy_dir" \
        "${deploy_dir}/backups/config-history/materials.applied.tar.gz" "$restored_projection" \
      && materials_recovery_finish_tracking "$deploy_dir" || status=1
  fi
  rm -rf -- "$stage"
  (( status == 0 ))
}

materials_publish_old_generation() {
  local deploy_dir=$1 old=$2 revision=$3 state=$4 output schema
  output=$(mktemp "${deploy_dir}/tmp/materials-old.XXXXXX") || return 1
  if ! jq -M --argjson revision "$revision" --arg state "$state" --argjson now "$(date +%s)" '
    .revision=$revision | .state=$state | .applied_at=$now |
    .configuration.runtime.revision=$revision |
    .configuration.runtime.applied_revision=(if $state == "applied" then $revision else (.configuration.runtime.applied_revision // 0) end)
  ' "$old" > "$output"; then
    rm -f -- "$output"
    return 1
  fi
  schema=$(jq -M -er '.schema_version' "$output") || { rm -f -- "$output"; return 1; }
  if [[ "$schema" == 1 ]]; then
    materials_projection_write_legacy "$deploy_dir" "$output" \
      || { rm -f -- "$output"; return 1; }
  else
    materials_projection_write "$deploy_dir" "$output" \
      || { rm -f -- "$output"; return 1; }
  fi
  rm -f -- "$output"
}

materials_finalize_runtime_source() {
  local deploy_dir=$1 revision=$2 target="${1}/config/runtime.yaml" temporary normalized
  normalized=$(mktemp "${deploy_dir}/tmp/runtime-finalize.XXXXXX") || return 1
  materials_normalize_configuration runtime "$target" "$normalized" \
    || { rm -f -- "$normalized"; return 1; }
  temporary=$(mktemp "${target}.tmp.XXXXXX") \
    || { rm -f -- "$normalized"; return 1; }
  jq -M --argjson revision "$revision" '.schema_version=2 | .revision=$revision | .applied_revision=$revision' "$normalized" > "$temporary" \
    || { rm -f -- "$normalized" "$temporary"; return 1; }
  rm -f -- "$normalized"
  chmod 640 "$temporary" || { rm -f -- "$temporary"; return 1; }
  chown root:1000 "$temporary" 2>/dev/null || true
  mv -f -- "$temporary" "$target" || { rm -f -- "$temporary"; return 1; }
}

materials_set_runtime_disable_epoch() {
  local deploy_dir=$1 epoch=$2 target="${1}/config/runtime.yaml" normalized temporary
  [[ "$epoch" =~ ^[0-9]+$ ]] && (( epoch <= 2147483647 )) || {
    materials_error '客服停用控制代次已达到安全边界，拒绝应用未受保护的配置'
    return 1
  }
  normalized=$(mktemp "${deploy_dir}/tmp/runtime-disable-epoch.XXXXXX") || return 1
  materials_normalize_configuration runtime "$target" "$normalized" \
    || { rm -f -- "$normalized"; return 1; }
  temporary=$(mktemp "${target}.tmp.XXXXXX") \
    || { rm -f -- "$normalized"; return 1; }
  jq -M --argjson epoch "$epoch" '.schema_version=2 | .disable_epoch=$epoch' "$normalized" > "$temporary" \
    || { rm -f -- "$normalized" "$temporary"; return 1; }
  rm -f -- "$normalized"
  chmod 640 "$temporary" || { rm -f -- "$temporary"; return 1; }
  chown root:1000 "$temporary" 2>/dev/null || true
  mv -f -- "$temporary" "$target" || { rm -f -- "$temporary"; return 1; }
}

materials_initialize_transaction_validate() {
  local deploy_dir=$1 journal="${1}/backups/config-history/materials.initialize" complete
  local runtime_hash projection_hash snapshot_hash projection_present snapshot_present
  [[ -d "$journal" && ! -L "$journal" && $(stat -c '%a' -- "$journal") == 700 ]] || return 1
  complete="${journal}/complete.json"
  materials_validate_private_file "$complete" 65536 '资料初始化事务清单' || return 1
  jq -M -e '
    .schema_version == 1 and .state == "prepared" and
    (.projection_present | type == "boolean") and (.snapshot_present | type == "boolean") and
    (.runtime_sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
    (.projection_sha256 | type == "string" and test("^(|[a-f0-9]{64})$")) and
    (.snapshot_sha256 | type == "string" and test("^(|[a-f0-9]{64})$"))
  ' "$complete" >/dev/null || return 1
  runtime_hash=$(jq -M -er '.runtime_sha256' "$complete") || return 1
  projection_hash=$(jq -M -er '.projection_sha256' "$complete") || return 1
  snapshot_hash=$(jq -M -er '.snapshot_sha256' "$complete") || return 1
  projection_present=$(jq -M -er '.projection_present | tostring' "$complete") || return 1
  snapshot_present=$(jq -M -er '.snapshot_present | tostring' "$complete") || return 1
  materials_validate_private_file "${journal}/runtime.yaml" 1048576 '资料初始化旧运行配置' || return 1
  [[ $(materials_sha_or_empty "${journal}/runtime.yaml") == "$runtime_hash" ]] || return 1
  if [[ "$projection_present" == true ]]; then
    materials_validate_private_file "${journal}/materials-applied.json" "$MATERIALS_PROJECTION_MAX_BYTES" '资料初始化旧投影' || return 1
    [[ $(materials_sha_or_empty "${journal}/materials-applied.json") == "$projection_hash" ]] || return 1
    materials_projection_validate "${journal}/materials-applied.json" \
      || materials_projection_validate_legacy "${journal}/materials-applied.json" || return 1
  else
    [[ -z "$projection_hash" && ! -e "${journal}/materials-applied.json" && ! -L "${journal}/materials-applied.json" ]] || return 1
  fi
  if [[ "$snapshot_present" == true ]]; then
    materials_validate_private_file "${journal}/materials.applied.tar.gz" 53687091200 '资料初始化旧原文包' || return 1
    [[ $(materials_sha_or_empty "${journal}/materials.applied.tar.gz") == "$snapshot_hash" ]] || return 1
  else
    [[ -z "$snapshot_hash" && ! -e "${journal}/materials.applied.tar.gz" && ! -L "${journal}/materials.applied.tar.gz" ]] || return 1
  fi
}

materials_initialize_transaction_capture() {
  local deploy_dir=$1 projection="${1}/config/materials-applied.json"
  local snapshot="${1}/backups/config-history/materials.applied.tar.gz"
  local journal="${1}/backups/config-history/materials.initialize" stage projection_present=false snapshot_present=false
  local projection_hash='' snapshot_hash='' runtime_hash temporary
  [[ ! -e "$journal" && ! -L "$journal" ]] || return 1
  stage=$(mktemp -d "${deploy_dir}/backups/config-history/materials.initialize.XXXXXXXX") || return 1
  chmod 700 "$stage" || { rm -rf -- "$stage"; return 1; }
  install -m 600 -- "${deploy_dir}/config/runtime.yaml" "${stage}/runtime.yaml" \
    || { rm -rf -- "$stage"; return 1; }
  runtime_hash=$(materials_sha_or_empty "${stage}/runtime.yaml") || { rm -rf -- "$stage"; return 1; }
  if [[ -e "$projection" || -L "$projection" ]]; then
    [[ -f "$projection" && ! -L "$projection" ]] || { rm -rf -- "$stage"; return 1; }
    install -m 600 -- "$projection" "${stage}/materials-applied.json" \
      || { rm -rf -- "$stage"; return 1; }
    projection_present=true
    projection_hash=$(materials_sha_or_empty "${stage}/materials-applied.json") || { rm -rf -- "$stage"; return 1; }
  fi
  if [[ -e "$snapshot" || -L "$snapshot" ]]; then
    [[ -f "$snapshot" && ! -L "$snapshot" ]] || { rm -rf -- "$stage"; return 1; }
    # canonical 只通过临时文件+替换发布；同文件系统硬链接可在不再复制
    # 数十 GiB 原文包的前提下冻结旧 inode，新发布不会就地改写它。
    ln -- "$snapshot" "${stage}/materials.applied.tar.gz" \
      || { rm -rf -- "$stage"; return 1; }
    chmod 600 "${stage}/materials.applied.tar.gz" || { rm -rf -- "$stage"; return 1; }
    snapshot_present=true
    snapshot_hash=$(materials_sha_or_empty "${stage}/materials.applied.tar.gz") || { rm -rf -- "$stage"; return 1; }
  fi
  temporary="${stage}/complete.json.tmp"
  if ! jq -M -n --arg runtime "$runtime_hash" --arg projection "$projection_hash" --arg snapshot "$snapshot_hash" \
    --argjson projection_present "$projection_present" --argjson snapshot_present "$snapshot_present" \
    '{schema_version:1,state:"prepared",runtime_sha256:$runtime,projection_present:$projection_present,
      projection_sha256:$projection,snapshot_present:$snapshot_present,snapshot_sha256:$snapshot}' > "$temporary" \
    || ! chmod 600 "$temporary" || ! mv -f -- "$temporary" "${stage}/complete.json"; then
    rm -rf -- "$stage"
    return 1
  fi
  # validator 只接受固定 journal 路径；临时目录在原子改名后再完整回读。
  if ! mv -- "$stage" "$journal" || ! materials_initialize_transaction_validate "$deploy_dir"; then
    [[ -e "$stage" || -L "$stage" ]] && rm -rf -- "$stage"
    return 1
  fi
}

materials_initialize_transaction_clear() {
  local deploy_dir=$1 journal="${1}/backups/config-history/materials.initialize" retired
  [[ ! -e "$journal" && ! -L "$journal" ]] && return 0
  materials_initialize_transaction_validate "$deploy_dir" || return 1
  retired=$(mktemp -d "${deploy_dir}/backups/config-history/materials.initialize.retired.XXXXXXXX") || return 1
  rmdir -- "$retired" || return 1
  mv -T -- "$journal" "$retired" || return 1
  rm -rf -- "$retired" || return 1
}

materials_initialize_transaction_cleanup_orphans() {
  local deploy_dir=$1 parent="${1}/backups/config-history" item mode owner group expected_owner expected_group unsafe
  expected_owner=$(id -u) || return 1
  expected_group=$(id -g) || return 1
  (( expected_owner != 0 )) || expected_group=0
  while IFS= read -r -d '' item; do
    [[ "$item" == "${parent}/materials.initialize."* && "$item" != "${parent}/materials.initialize" \
      && -d "$item" && ! -L "$item" ]] || return 1
    mode=$(stat -c '%a' -- "$item") || return 1
    owner=$(stat -c '%u' -- "$item") || return 1
    group=$(stat -c '%g' -- "$item") || return 1
    [[ "$mode" == 700 && "$owner" == "$expected_owner" && "$group" == "$expected_group" ]] || return 1
    unsafe=$(find "$item" -mindepth 1 \( ! -type d ! -type f -o -type l \) -print -quit 2>/dev/null) || return 1
    [[ -z "$unsafe" ]] || return 1
    rm -rf -- "$item" || return 1
  done < <(find "$parent" -mindepth 1 -maxdepth 1 -name 'materials.initialize.*' -print0)
}

materials_initialize_transaction_restore() {
  local deploy_dir=$1 journal="${1}/backups/config-history/materials.initialize"
  local projection="${1}/config/materials-applied.json" snapshot="${1}/backups/config-history/materials.applied.tar.gz"
  local projection_present snapshot_present temporary schema
  materials_initialize_transaction_validate "$deploy_dir" || return 1
  projection_present=$(jq -M -er '.projection_present | tostring' "${journal}/complete.json") || return 1
  snapshot_present=$(jq -M -er '.snapshot_present | tostring' "${journal}/complete.json") || return 1
  temporary=$(mktemp "${deploy_dir}/config/runtime.yaml.restore.XXXXXXXX") || return 1
  if ! install -m 640 -- "${journal}/runtime.yaml" "$temporary"; then rm -f -- "$temporary"; return 1; fi
  chown root:1000 "$temporary" 2>/dev/null || true
  mv -f -- "$temporary" "${deploy_dir}/config/runtime.yaml" || { rm -f -- "$temporary"; return 1; }
  if [[ "$snapshot_present" == true ]]; then
    materials_snapshot_publish "$deploy_dir" "${journal}/materials.applied.tar.gz" "$snapshot" || return 1
  else
    [[ ! -L "$snapshot" ]] && rm -f -- "$snapshot" || return 1
  fi
  if [[ "$projection_present" == true ]]; then
    schema=$(jq -M -er '.schema_version' "${journal}/materials-applied.json") || return 1
    if [[ "$schema" == 1 ]]; then
      materials_projection_write_legacy "$deploy_dir" "${journal}/materials-applied.json" || return 1
    else
      materials_projection_write "$deploy_dir" "${journal}/materials-applied.json" || return 1
    fi
  else
    [[ ! -L "$projection" ]] && rm -f -- "$projection" || return 1
  fi
  materials_initialize_transaction_clear "$deploy_dir"
}

materials_initialize() (
  local deploy_dir=$1 projection="${1}/config/materials-applied.json" stage revision
  local snapshot="${1}/backups/config-history/materials.applied.tar.gz" candidate_snapshot runtime_normalized
  local had_projection=false legacy=false legacy_archive='' failed=false rollback_failed=false
  local recovery_cleanup_pending=false
  acquire_maintenance_lock "$deploy_dir"
  materials_recovery_cleanup_orphans "$deploy_dir" \
    || { materials_error '资料恢复遗留临时对象不安全，已停止初始化'; return 1; }
  # 上次进程可能在替换 runtime、规范原文包或投影任一边界被
  # SIGKILL。必须在解析当前投影之前先回放持久事务，否则一份
  # 已写一半的新投影会让恢复入口自身先行失败。
  if [[ -e "${deploy_dir}/backups/config-history/materials.initialize" \
    || -L "${deploy_dir}/backups/config-history/materials.initialize" ]]; then
    materials_initialize_transaction_restore "$deploy_dir" \
      || { materials_error '上次资料初始化事务未能恢复，已停止继续'; return 1; }
  fi
  materials_initialize_transaction_cleanup_orphans "$deploy_dir" \
    || { materials_error '资料初始化遗留目录不安全，已停止继续'; return 1; }
  if [[ -e "$projection" || -L "$projection" ]]; then
    if materials_projection_validate "$projection"; then
      :
    elif materials_projection_validate_legacy "$projection"; then
      had_projection=true
      legacy=true
    else
      materials_error '现有资料投影损坏，拒绝回退读取可编辑原文'
      return 1
    fi
  fi
  materials_recovery_cleanup_retired "$deploy_dir" \
    || { materials_error '已退役资料事务目录检查失败，已停止初始化'; return 1; }
  # 锁建立后重新核对；等待期间其他维护任务可能已经完成迁移。
  if [[ -e "$projection" || -L "$projection" ]]; then
    if materials_projection_validate "$projection"; then
      if [[ -f "$snapshot" && ! -L "$snapshot" ]] \
        && materials_applied_external_readback "$deploy_dir" "$snapshot" "$projection"; then
        return 0
      fi
      # 只允许从仍与当前投影完全一致的原文修复丢失/不完整的规范快照。
      # 已经存在待应用编辑时无法重建上一原文，必须失败而不是覆盖证据。
      stage=$(mktemp -d "${deploy_dir}/tmp/materials-initialize-repair.XXXXXXXX") || return 1
      candidate_snapshot="${stage}/materials.applied.tar.gz"
      if materials_snapshot_create "$deploy_dir" "$candidate_snapshot" \
        && materials_snapshot_validate_generation "$deploy_dir" "$candidate_snapshot" "$projection" \
        && materials_snapshot_publish "$deploy_dir" "$candidate_snapshot" "$snapshot" \
        && materials_applied_external_readback "$deploy_dir" "$snapshot" "$projection"; then
        rm -rf -- "$stage"
        return 0
      fi
      rm -rf -- "$stage"
      materials_error '现有投影缺少同代有效原文快照，且当前待编辑资料不能重建上一代；已停止初始化'
      return 1
    fi
    materials_projection_validate_legacy "$projection" \
      || { materials_error '资料投影在迁移前发生变化，拒绝继续'; return 1; }
    had_projection=true
    legacy=true
  fi
  configuration_runtime_init "$deploy_dir" || return 1
  knowledge_catalog_migrate "$deploy_dir" || return 1
  knowledge_catalog_project "$deploy_dir" \
    || { materials_error '当前知识原文投影尚未完整生成，不能建立首份资料投影'; return 1; }
  configuration_prompt_verify_file "$deploy_dir" "${deploy_dir}/config/prompt.md" \
    || { materials_error '当前 Prompt 尚未通过 AnythingLLM 回读，不能建立首份投影'; return 1; }
  knowledge_catalog_readback "$deploy_dir" \
    || { materials_error '当前知识索引尚未通过回读，不能建立首份投影'; return 1; }
  runtime_normalized=$(mktemp "${deploy_dir}/tmp/runtime-initialize.XXXXXX") || return 1
  materials_normalize_configuration runtime "${deploy_dir}/config/runtime.yaml" "$runtime_normalized" \
    || { rm -f -- "$runtime_normalized"; return 1; }
  revision=$(jq -M -er '[(.revision // 0),(.applied_revision // 0)] | max | if . < 1 then 1 else . end' "$runtime_normalized") \
    || { rm -f -- "$runtime_normalized"; return 1; }
  if [[ "$legacy" == true ]]; then
    revision=$(jq -M -er --argjson runtime "$revision" '[.revision,$runtime] | max' "$projection") \
      || { rm -f -- "$runtime_normalized"; return 1; }
    legacy_archive=$(mktemp -d "${deploy_dir}/backups/config-history/materials-v1-migration.XXXXXXXX") \
      || { rm -f -- "$runtime_normalized"; return 1; }
    chmod 700 "$legacy_archive" \
      && install -m 600 -- "$projection" "${legacy_archive}/materials-applied-v1.json" \
      || { rm -f -- "$runtime_normalized"; rm -rf -- "$legacy_archive"; return 1; }
    if [[ -f "${deploy_dir}/backups/config-history/materials.applied.tar.gz" \
      && ! -L "${deploy_dir}/backups/config-history/materials.applied.tar.gz" ]]; then
      install -m 600 -- "${deploy_dir}/backups/config-history/materials.applied.tar.gz" \
        "${legacy_archive}/materials.applied.tar.gz" \
        || { rm -f -- "$runtime_normalized"; rm -rf -- "$legacy_archive"; return 1; }
    fi
  fi
  rm -f -- "$runtime_normalized"
  stage=$(mktemp -d "${deploy_dir}/tmp/materials-initialize.XXXXXXXX") || return 1
  materials_initialize_transaction_capture "$deploy_dir" \
    || { rm -rf -- "$stage"; materials_error '未能建立持久初始化事务，已拒绝改动运行配置'; return 1; }
  # 规范快照必须从已写入本代 revision 的运行原文生成。否则投影
  # 虽然会忽略这两个内部字段做语义比较，恢复包本身却会保留旧代值。
  materials_finalize_runtime_source "$deploy_dir" "$revision" || failed=true
  if [[ "$failed" == false ]]; then
    materials_prepare_candidate "$deploy_dir" "$stage" "$revision" applied || failed=true
  fi
  candidate_snapshot="${stage}/materials.applied.tar.gz"
  if [[ "$failed" == false ]]; then
    materials_snapshot_create "$deploy_dir" "$candidate_snapshot" || failed=true
  fi
  if [[ "$failed" == false ]]; then
    materials_snapshot_validate_generation "$deploy_dir" "$candidate_snapshot" "${stage}/materials-applied.json" \
      || { materials_error '首份资料快照与候选投影不同代'; failed=true; }
  fi
  if [[ "$failed" == false ]]; then
    materials_snapshot_publish "$deploy_dir" "$candidate_snapshot" "$snapshot" || failed=true
  fi
  if [[ "$failed" == false ]]; then
    materials_projection_write_current "$deploy_dir" "${stage}/materials-applied.json" || failed=true
  fi
  if [[ "$failed" == false ]]; then
    materials_applied_external_readback "$deploy_dir" "$snapshot" "${stage}/materials-applied.json" \
      || failed=true
  fi
  if [[ "$failed" == true ]]; then
    materials_initialize_transaction_restore "$deploy_dir" || rollback_failed=true
    if [[ "$rollback_failed" == true ]]; then
      materials_error '运行容器未确认同一代资料投影，且上一资料代未能完整恢复；请保持自动客服关闭并从完整快照恢复'
    else
      materials_error '运行容器未确认同一代资料投影；上一配置已恢复，自动回复保持受阻止直到重新应用'
    fi
    rm -rf -- "$stage"
    return 1
  fi
  if ! materials_initialize_transaction_clear "$deploy_dir"; then
    materials_error '资料已完成容器回读，但初始化事务尚未原子退役；请重试初始化以完成收口'
    rm -rf -- "$stage"
    return 1
  fi
  jq -M --argjson migrated "$legacy" --argjson cleanup "$recovery_cleanup_pending" \
    '{initialized:true,migrated_from_schema_v1:$migrated,revision,state,source_sha256,recovery_cleanup_pending:$cleanup}' "$projection" \
    || { rm -rf -- "$stage"; return 1; }
  rm -rf -- "$stage"
)

materials_apply() (
  local deploy_dir=$1 knowledge_mode=${2:-none} projection="${1}/config/materials-applied.json" old_snapshot old='' stage='' revision=0
  local prompt_changed knowledge_changed config_changed final_stage='' rollback_revision history candidate_snapshot result=0 recovering=false
  local recovery="${1}/backups/config-history/materials.recovery"
  local transition_started=false transition_committed=false signal_status=0
  local recovery_cleanup_pending=false
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
  materials_recovery_cleanup_orphans "$deploy_dir" \
    || { materials_error '资料恢复遗留临时对象不安全，已停止应用'; return 1; }
  materials_recovery_cleanup_retired "$deploy_dir" \
    || { materials_error '已退役资料事务目录检查失败，已停止应用'; return 1; }
  [[ -f "$projection" && ! -L "$projection" ]] \
    || { materials_error '尚无已验证的资料投影；请先在安装/升级流程执行 materials.sh initialize'; return 1; }
  materials_projection_validate "$projection" \
    || { materials_error '现有资料投影损坏，已阻止应用；不会回退读取可编辑原文'; return 1; }
  old_snapshot="${deploy_dir}/backups/config-history/materials.applied.tar.gz"
  [[ -f "$old_snapshot" && ! -L "$old_snapshot" ]] \
    || { materials_error '缺少上一有效资料快照，已阻止不可恢复的应用'; return 1; }
  old=$(mktemp "${deploy_dir}/tmp/materials-effective.XXXXXX") || return 1
  install -m 600 -- "$projection" "$old" || return 1
  if [[ -e "$recovery" || -L "$recovery" ]]; then
    [[ -d "$recovery" && ! -L "$recovery" ]] \
      || { materials_error '资料恢复事务路径类型不安全，已停止应用'; return 1; }
    # 候选可能已经完成回读，只差删除旧事务记录。只有当前规范快照、知识
    # 绑定和容器回读全部同代，且不存在清理责任时，才把 recovery 视为陈旧。
    if [[ $(jq -M -r '.state' "$old") == applied ]] \
      && [[ ! -e "${recovery}/cleanup.json" && ! -L "${recovery}/cleanup.json" \
        && ! -e "${recovery}/touched.json" && ! -L "${recovery}/touched.json" \
        && ! -e "${recovery}/upload-response.json" && ! -L "${recovery}/upload-response.json" \
        && ! -e "${recovery}/upload-intent.json" && ! -L "${recovery}/upload-intent.json" ]] \
      && materials_applied_external_readback "$deploy_dir" "$old_snapshot" "$old"; then
      materials_recovery_clear "$deploy_dir" \
        || { materials_error '资料已生效，但旧事务记录未能安全清理'; return 1; }
    else
      recovering=true
    fi
  elif [[ $(jq -M -r '.state' "$old") == applying ]]; then
    materials_error '资料投影处于恢复状态但旧代保全缺失，已停止应用'
    return 1
  fi
  revision=$(( $(jq -M -r '.revision' "$old") + 1 ))
  if [[ "$recovering" == true && -d "$recovery" && ! -L "$recovery" ]]; then
    transition_started=true
    if ! materials_external_restore "$deploy_dir" "$recovery" true true "$revision"; then
      materials_error '上次资料事务仍未恢复；自动回复继续受阻止，未从混合现场建立新基线'
      return 1
    fi
    install -m 600 -- "$projection" "$old" || return 1
    transition_committed=true
    if ! materials_recovery_clear "$deploy_dir"; then
      materials_error '上次资料事务已恢复，但受限恢复记录未能安全清理'
      return 1
    fi
    recovering=false
    revision=$(( $(jq -M -r '.revision' "$old") + 1 ))
    transition_started=false
    transition_committed=false
  fi
  stage=$(mktemp -d "${deploy_dir}/tmp/materials-candidate.XXXXXXXX") || return 1
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
    stage=$(mktemp -d "${deploy_dir}/tmp/materials-candidate.XXXXXXXX") || return 1
    materials_prepare_candidate "$deploy_dir" "$stage" "$revision" applied \
      || { rm -f -- "$old"; rm -rf -- "$stage"; return 1; }
  fi
  if [[ "$recovering" == false && "$knowledge_mode" == none && $(jq -M -r '.source_sha256' "$old") == $(jq -M -r '.source_sha256' "${stage}/materials-applied.json") ]]; then
    jq -M -n --argjson revision "$(jq -M -r '.revision' "$old")" \
      --argjson cleanup "$recovery_cleanup_pending" \
      '{applied:true,changed:false,revision:$revision,recovery_cleanup_pending:$cleanup}'
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

  if [[ "$prompt_changed" == true || "$knowledge_changed" == true || "$config_changed" == true ]] \
    && [[ "$recovering" == false ]]; then
    materials_recovery_capture "$deploy_dir" "$old" "$old_snapshot" \
      || { materials_error '未建立可验证的旧资料恢复事务，拒绝开始外部修改'; return 1; }
  fi

  history=$(mktemp -d "${deploy_dir}/backups/config-history/materials.XXXXXXXX") || return 1
  install -m 600 -- "$old" "${history}/materials-applied.json" || return 1
  install -m 600 -- "$old_snapshot" "${history}/materials-applied.tar.gz" || return 1
  install -m 600 -- "$old" "${deploy_dir}/backups/config-history/materials.previous.json" || return 1

  if [[ "$prompt_changed" == true || "$knowledge_changed" == true ]]; then
    transition_started=true
    materials_publish_old_generation "$deploy_dir" "$old" "$revision" applying \
      || { materials_error '未能发布资料应用屏障，外部配置保持不变'; return 1; }
    if [[ "$prompt_changed" == true ]] && ! configuration_prompt_sync_file "$deploy_dir" "${stage}/prompt.md"; then
      result=1
    fi
    if (( result == 0 )) && [[ "$knowledge_changed" == true ]]; then
      if ! install -m 640 -- "${stage}/knowledge/catalog.json" "${deploy_dir}/knowledge/catalog.json"; then
        result=1
      else
        chown root:1000 "${deploy_dir}/knowledge/catalog.json" 2>/dev/null || true
        if [[ "$knowledge_mode" == reindex || "$recovering" == true ]]; then
          knowledge_sync_catalog "$deploy_dir" 1 || result=1
        else
          knowledge_sync_catalog "$deploy_dir" 0 || result=1
        fi
      fi
    fi
  fi

  if (( result == 0 )); then
    final_stage=$(mktemp -d "${deploy_dir}/tmp/materials-final.XXXXXXXX") || result=1
  fi
  if (( result == 0 )); then
    materials_prepare_candidate "$deploy_dir" "$final_stage" "$revision" applied || result=1
  fi
  if (( result == 0 )); then
    transition_started=true
    materials_finalize_runtime_source "$deploy_dir" "$revision" || result=1
  fi
  if (( result == 0 )); then
    candidate_snapshot="${history}/candidate-applied.tar.gz"
    materials_snapshot_create "$deploy_dir" "$candidate_snapshot" || result=1
  fi
  if (( result == 0 )); then
    materials_snapshot_validate_generation "$deploy_dir" "$candidate_snapshot" \
      "${final_stage}/materials-applied.json" || result=1
  fi
  if (( result == 0 )); then
    materials_snapshot_publish "$deploy_dir" "$candidate_snapshot" "$old_snapshot" || result=1
  fi
  if (( result == 0 )); then
    materials_projection_write_current "$deploy_dir" "${final_stage}/materials-applied.json" || result=1
  fi
  if (( result == 0 )); then
    materials_applied_external_readback "$deploy_dir" "$old_snapshot" \
      "${final_stage}/materials-applied.json" || result=1
  fi
  if (( result == 0 )); then
    materials_recovery_finish_tracking "$deploy_dir" || result=1
  fi
  if (( result == 0 )); then
    transition_committed=true
    if ! materials_recovery_clear "$deploy_dir"; then
      materials_error '资料已完成运行回读，但旧事务未能原子退役；请重试应用以收口维护记录'
      return 1
    fi
    jq -M -n --argjson revision "$revision" --argjson config "$config_changed" --argjson prompt "$prompt_changed" --argjson knowledge "$knowledge_changed" \
      --argjson cleanup "$recovery_cleanup_pending" \
      '{applied:true,changed:true,revision:$revision,recovery_cleanup_pending:$cleanup,components:{configuration:$config,prompt:$prompt,knowledge:$knowledge}}'
    rm -f -- "$old"; rm -rf -- "$stage" "${final_stage:-}"
    return 0
  fi

  rollback_revision=$((revision + 1))
  if [[ -d "$recovery" && ! -L "$recovery" ]] \
    && materials_external_restore "$deploy_dir" "$recovery" "$prompt_changed" "$knowledge_changed" "$rollback_revision"; then
    transition_committed=true
    if materials_recovery_clear "$deploy_dir"; then
      materials_error '资料应用失败；上一有效投影已恢复，可编辑原文保留为待应用变更'
    else
      materials_error '资料应用失败；上一有效投影已恢复，但受限恢复记录未能安全清理'
    fi
  elif [[ "$prompt_changed" == false && "$knowledge_changed" == false ]] \
    && materials_publish_old_generation "$deploy_dir" "$old" "$rollback_revision" applied \
    && materials_applied_external_readback "$deploy_dir" "$old_snapshot" "$projection"; then
    transition_committed=true
    materials_error '资料应用失败；未发生外部资料变更，上一有效投影已恢复'
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
