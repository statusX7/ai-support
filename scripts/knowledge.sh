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
knowledge_utf8_bytes() { printf '%s' "$1" | wc -c | tr -d ' '; }

knowledge_validate_name() {
  local value=$1 maximum=$2 description=$3 bytes
  bytes=$(knowledge_utf8_bytes "$value")
  if (( bytes < 1 || bytes > maximum )) || [[ "$value" =~ [[:cntrl:]/\\] ]]; then
    configuration_error "${description}必须为 1～${maximum} 个 UTF-8 字节且不含控制符或路径分隔符"
    return 1
  fi
}

knowledge_validate_document_file() {
  local file=$1 extension=${2,,} size
  [[ -f "$file" && ! -L "$file" ]] || { configuration_error '知识来源必须是普通文件且不得是符号链接'; return 1; }
  size=$(stat -c '%s' -- "$file")
  (( size > 0 && size <= 52428800 )) || { configuration_error '单个知识文件必须为 1～52428800 字节（50 MiB）'; return 1; }
  python3 - "$file" "$extension" <<'PY'
import pathlib
import sys
import zipfile

path = pathlib.Path(sys.argv[1])
extension = sys.argv[2]
raw = path.read_bytes()
if extension in ("md", "txt"):
    try:
        text = raw.decode("utf-8", "strict")
    except UnicodeDecodeError:
        raise SystemExit("Markdown/TXT 知识不是有效 UTF-8")
    if "\x00" in text:
        raise SystemExit("Markdown/TXT 知识包含 NUL")
elif extension == "pdf":
    if not raw.startswith(b"%PDF-"):
        raise SystemExit("知识文件不是有效 PDF 文件头")
elif extension == "docx":
    try:
        with zipfile.ZipFile(path) as archive:
            names = set(archive.namelist())
            if "[Content_Types].xml" not in names or "word/document.xml" not in names:
                raise SystemExit("知识文件不是有效 DOCX")
            if any(info.flag_bits & 0x1 for info in archive.infolist()):
                raise SystemExit("知识文件不得是加密 DOCX")
    except (zipfile.BadZipFile, OSError):
        raise SystemExit("知识文件不是有效 DOCX")
else:
    raise SystemExit("知识文件格式不受支持")
PY
}

knowledge_move_root_contents() {
  local source_root=$1 destination_root=$2 entry name
  local -a moved=()
  [[ -d "$source_root" && ! -L "$source_root" ]] \
    || { configuration_error '知识根目录必须是普通目录且不得是符号链接'; return 1; }
  if [[ -e "$destination_root" || -L "$destination_root" ]]; then
    [[ -d "$destination_root" && ! -L "$destination_root" && -z $(find "$destination_root" -mindepth 1 -maxdepth 1 -print -quit) ]] \
      || { configuration_error '知识内容暂存目录不安全或非空'; return 1; }
  else
    mkdir -m 750 -- "$destination_root" || return 1
  fi
  while IFS= read -r -d '' entry; do
    name=${entry##*/}
    [[ ! -e "${destination_root}/${name}" && ! -L "${destination_root}/${name}" ]] \
      || { configuration_error '知识内容暂存目标发生冲突'; return 1; }
  done < <(find "$source_root" -mindepth 1 -maxdepth 1 -print0)
  while IFS= read -r -d '' entry; do
    name=${entry##*/}
    if ! mv -- "$entry" "${destination_root}/${name}"; then
      for name in "${moved[@]}"; do
        mv -- "${destination_root}/${name}" "${source_root}/${name}" 2>/dev/null || true
      done
      configuration_error '移动知识内容失败，已尝试原位恢复'
      return 1
    fi
    moved+=("$name")
  done < <(find "$source_root" -mindepth 1 -maxdepth 1 -print0)
}

knowledge_replace_root_contents() {
  local target_root=$1 candidate_root=$2 backup_root=$3
  [[ -d "$target_root" && ! -L "$target_root" && -d "$candidate_root" && ! -L "$candidate_root" ]] \
    || { configuration_error '知识目录替换来源或目标不安全'; return 1; }
  [[ ! -e "$backup_root" && ! -L "$backup_root" ]] \
    || { configuration_error '知识目录备份目标已存在'; return 1; }
  knowledge_move_root_contents "$target_root" "$backup_root" || return 1
  if knowledge_move_root_contents "$candidate_root" "$target_root"; then
    return 0
  fi
  if ! knowledge_move_root_contents "$backup_root" "$target_root"; then
    configuration_error '候选知识安装失败，且原内容未能完整回移'
  fi
  return 1
}

knowledge_source_inventory() {
  local requested=$1 output=$2 resolved lexical scan file name extension entries=0 inventory_regular_count=0 supported=0 total_bytes=0
  local -a files=() supported_files=()
  local -A names=() formats=([md]=0 [txt]=0 [pdf]=0 [docx]=0)
  [[ ! "$requested" =~ [[:cntrl:]] && ! -L "$requested" ]] \
    || { configuration_error '知识来源路径不得包含控制字符或符号链接'; return 1; }
  lexical=$(realpath -ms -- "$requested") || return 1
  resolved=$(realpath -e -- "$requested") \
    || { configuration_error '知识来源不存在'; return 1; }
  [[ "$resolved" == "$lexical" ]] \
    || { configuration_error '知识来源及其父目录不能经符号链接跳转'; return 1; }
  scan=$(mktemp "${TMPDIR:-/tmp}/crispai-knowledge-scan.XXXXXXXX") || return 1
  if ! python3 - "$resolved" "$scan" <<'PY'
import json
import os
import stat
import sys

root = os.path.abspath(sys.argv[1])
output = sys.argv[2]
members = 0
regular = []

def fail(message):
    raise SystemExit(message)

def valid_text_path(path):
    try:
        os.fsencode(path).decode(sys.getfilesystemencoding(), "strict")
    except (UnicodeDecodeError, UnicodeEncodeError):
        fail("知识来源路径或文件名不是有效 UTF-8")

try:
    root_status = os.lstat(root)
    valid_text_path(root)
    if stat.S_ISREG(root_status.st_mode):
        members = 1
        regular.append(root)
    elif stat.S_ISDIR(root_status.st_mode):
        stack = [(root, 0)]
        while stack:
            directory, parent_depth = stack.pop()
            try:
                children = list(os.scandir(directory))
            except OSError:
                fail("知识目录无法完整读取，请检查目录及其子目录权限")
            children.sort(key=lambda item: os.fsencode(item.name), reverse=True)
            for child in children:
                path = child.path
                valid_text_path(path)
                depth = parent_depth + 1
                if depth > 16:
                    fail("知识目录递归深度不得超过 16 层")
                members += 1
                if members > 20000:
                    fail("知识目录扫描成员不得超过 20000 个")
                try:
                    mode = child.stat(follow_symlinks=False).st_mode
                except OSError:
                    fail("知识目录成员状态无法读取，请检查目录权限")
                if stat.S_ISLNK(mode):
                    fail("知识目录内不得包含符号链接")
                if stat.S_ISDIR(mode):
                    stack.append((path, depth))
                elif stat.S_ISREG(mode):
                    regular.append(path)
                    if len(regular) > 10000:
                        fail("知识目录普通文件不得超过 10000 个")
                else:
                    fail("知识目录内不得包含特殊文件")
    else:
        fail("知识来源必须是普通文件或目录")
except OSError:
    fail("知识来源无法读取，请检查路径和权限")

regular.sort(key=os.fsencode)
try:
    encoded = json.dumps(
        {"files": regular, "scanned_members": members, "regular_files": len(regular)},
        ensure_ascii=False,
        separators=(",", ":"),
    )
    with open(output, "w", encoding="utf-8", newline="\n") as stream:
        stream.write(encoded + "\n")
except (OSError, UnicodeError, TypeError, ValueError):
    fail("知识目录扫描结果无法安全保存")
PY
  then
    rm -f -- "$scan"
    return 1
  fi
  entries=$(jq -M -r '.scanned_members' "$scan") || { rm -f -- "$scan"; return 1; }
  inventory_regular_count=$(jq -M -r '.regular_files' "$scan") || { rm -f -- "$scan"; return 1; }
  while IFS= read -r -d '' file; do files+=("$file"); done < <(knowledge_inventory_files "$scan")
  rm -f -- "$scan"
  for file in "${files[@]}"; do
    is_supported_knowledge_file "$file" || continue
    name=$(basename -- "$file")
    knowledge_validate_name "$name" 255 '知识文件名' || return 1
    [[ "$name" != *';'* && "$name" != *','* ]] \
      || { configuration_error '知识文件名不得包含分号或逗号'; return 1; }
    [[ -z ${names[$name]+x} ]] \
      || { configuration_error "导入目录含重名文件：$name"; return 1; }
    names[$name]=1
    extension=${name##*.}; extension=${extension,,}
    knowledge_validate_document_file "$file" "$extension" || return 1
    supported_files+=("$file")
    ((supported += 1))
    ((formats[$extension] += 1))
    total_bytes=$((total_bytes + $(stat -c '%s' -- "$file")))
  done
  (( supported > 0 )) \
    || { configuration_error '知识来源中没有可导入的 Markdown、TXT、PDF 或 DOCX 文件'; return 1; }
  # 通过 NUL 流交给 Python，路径含空格/Emoji 也不会失真。
  {
    printf '%s\0' "${supported_files[@]}"
  } | python3 -c '
import json, os, sys
paths = [os.fsdecode(item) for item in sys.stdin.buffer.read().split(b"\0") if item]
json.dump({"files": paths}, sys.stdout, ensure_ascii=False, separators=(",", ":"))
' > "$output" || return 1
  python3 - "$output" "$entries" "$inventory_regular_count" "$supported" "$total_bytes" \
    "${formats[md]}" "${formats[txt]}" "${formats[pdf]}" "${formats[docx]}" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value.update({
    "valid": True,
    "scanned_members": int(sys.argv[2]),
    "regular_files": int(sys.argv[3]),
    "supported_files": int(sys.argv[4]),
    "total_bytes": int(sys.argv[5]),
    "formats": {"md": int(sys.argv[6]), "txt": int(sys.argv[7]), "pdf": int(sys.argv[8]), "docx": int(sys.argv[9])},
})
path.write_text(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
PY
  chmod 600 "$output"
}

knowledge_inventory_files() {
  python3 - "$1" <<'PY'
import json
import os
import sys
for path in json.load(open(sys.argv[1], encoding="utf-8"))["files"]:
    sys.stdout.buffer.write(os.fsencode(path) + b"\0")
PY
}

knowledge_catalog_validate() {
  jq -M -e '
    .schema_version == 2 and (.libraries | type == "array" and length <= 100) and
    ([.libraries[].id] | length == (unique | length)) and
    all(.libraries[]; (.id | test("^kb_([a-f0-9]{16}|default)$")) and
      (.name | type == "string" and utf8bytelength > 0 and utf8bytelength <= 100) and (.enabled | type == "boolean") and
      (.documents | type == "array" and length <= 10000) and
      ([.documents[].id] | length == (unique | length)) and
      ([.documents[].source] | length == (unique | length)) and
      all(.documents[]; (.id | test("^doc_[a-f0-9]{16}$")) and
        (.name | type == "string" and utf8bytelength > 0 and utf8bytelength <= 255 and (test("[\\x00-\\x1f\\\\/]") | not)) and
        (.source | test("^sources/doc_[a-f0-9]{16}\\.(md|txt|pdf|docx)$")) and
        (.projection | type == "string" and utf8bytelength > 0 and utf8bytelength <= 255 and (test("[\\x00-\\x1f\\\\/;,]") | not)) and
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
  jq -M -n '{schema_version:2,revision:1,libraries:[{id:"kb_default",name:"默认知识库",enabled:true,revision:1,documents:[],status:"pending",last_sync:null,error:null}]}' > "$temporary"
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
    metadata=$(jq -M -cn --arg id "$document_id" --arg name "$name" --arg source "$source" --arg projection "$name" --arg hash "$hash" '{id:$id,name:$name,source:$source,projection:$projection,sha256:$hash}')
    file=$(mktemp "${catalog}.merge.XXXXXX")
    jq -M --argjson document "$metadata" '.libraries[0].documents += [$document]' "$temporary" > "$file"
    mv -f -- "$file" "$temporary"
  done < <(find "${deploy_dir}/knowledge" -maxdepth 1 -type f ! -type l -print0 | sort -z)
  file=$(mktemp "${catalog}.merge.XXXXXX")
  jq -M 'if (.libraries[0].documents | length) == 0 then .libraries=[] else . end' "$temporary" > "$file"
  mv -f -- "$file" "$temporary"
  knowledge_catalog_write "$deploy_dir" "$temporary"
  chown -R root:1000 "${deploy_dir}/knowledge/kb_default" 2>/dev/null || true
  chmod 750 "${deploy_dir}/knowledge/kb_default" "${deploy_dir}/knowledge/kb_default/sources"
}

knowledge_catalog_project() {
  local deploy_dir=$1 catalog="${1}/knowledge/catalog.json" old_list="${1}/data/knowledge-projection.json" next_list temporary row library source projection
  knowledge_catalog_validate "$catalog" || return 1
  next_list=$(jq -M -c '[.libraries[] | select(.enabled) | .documents[].projection] | unique' "$catalog")
  if [[ -f "$old_list" ]]; then
    jq -M -e 'type == "array" and all(type == "string" and (test("[\\x00-\\x1f\\\\/;,]") | not))' "$old_list" >/dev/null || return 1
    while IFS= read -r projection; do
      [[ -n "$projection" && "$projection" != README.md && ! -L "${deploy_dir}/knowledge/${projection}" ]] || return 1
      rm -f -- "${deploy_dir}/knowledge/${projection}"
    done < <(jq -M -rn --argjson previous "$(<"$old_list")" --argjson next "$next_list" '$previous - $next | .[]')
  else
    while IFS= read -r projection; do
      [[ -n "$projection" && "$projection" != README.md && ! -L "${deploy_dir}/knowledge/${projection}" ]] || return 1
      rm -f -- "${deploy_dir}/knowledge/${projection}"
    done < <(jq -M -r '.libraries[] | select(.enabled == false) | .documents[].projection' "$catalog")
  fi
  while IFS= read -r row; do
    library=$(jq -M -r '.library' <<< "$row")
    source=$(jq -M -r '.source' <<< "$row")
    projection=$(jq -M -r '.projection' <<< "$row")
    [[ -f "${deploy_dir}/knowledge/${library}/${source}" && ! -L "${deploy_dir}/knowledge/${library}/${source}" ]] || return 1
    [[ $(realpath -e "${deploy_dir}/knowledge/${library}/${source}") == "${deploy_dir}/knowledge/${library}/"* ]] || return 1
    [[ ! -L "${deploy_dir}/knowledge/${projection}" ]] || return 1
    temporary=$(mktemp "${deploy_dir}/knowledge/.projection.XXXXXX")
    install -m 640 -- "${deploy_dir}/knowledge/${library}/${source}" "$temporary"
    chown root:1000 "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "${deploy_dir}/knowledge/${projection}"
  done < <(jq -M -c '.libraries[] | select(.enabled) | .id as $library | .documents[] | . + {library:$library}' "$catalog")
  temporary=$(mktemp "${old_list}.tmp.XXXXXX")
  printf '%s\n' "$next_list" > "$temporary"
  chmod 600 "$temporary"
  mv -f -- "$temporary" "$old_list"
}

knowledge_catalog_readback() {
  local deploy_dir=$1 scope=${2:-all} manifest="${1}/data/knowledge-manifest.json" catalog="${1}/knowledge/catalog.json" locations temporary now
  anythingllm_connection "$deploy_dir"
  locations=$(anythingllm_workspace_locations) || return 1
  jq -M -en --slurpfile catalog "$catalog" --slurpfile manifest "$manifest" --argjson locations "$locations" --arg scope "$scope" '
    all($catalog[0].libraries[] | select($scope == "all" or .id == $scope) | select(.enabled) | .documents[]; . as $document |
      ($manifest[0].files[$document.projection].sha256 == $document.sha256) and
      ($manifest[0].files[$document.projection].locations | length > 0) and
      all($manifest[0].files[$document.projection].locations[]; . as $location | $locations | index($location) != null)) and
    all($catalog[0].libraries[] | select($scope == "all" or .id == $scope) | select(.enabled == false) | .documents[]; . as $document | $manifest[0].files[$document.projection] == null)
  ' >/dev/null || return 1
  now=$(date +%s)
  temporary=$(mktemp "${catalog}.tmp.XXXXXX")
  jq -M --argjson now "$now" --arg scope "$scope" '.libraries |= map(if $scope == "all" or .id == $scope then . as $library | .status=(if .enabled then "indexed" else "disabled" end) | .last_sync=$now | .error=null |
    .documents |= map(.index_status=(if $library.enabled then "indexed" else "disabled" end) | .last_error=null) else . end)' "$catalog" > "$temporary"
  knowledge_catalog_write "$deploy_dir" "$temporary"
  temporary=$(mktemp "${deploy_dir}/data/runtime/knowledge-map.json.tmp.XXXXXX")
  jq -M -n --slurpfile catalog "$catalog" --slurpfile manifest "$manifest" '{schema_version:2,revision:$catalog[0].revision,documents:[
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
    jq -M -e --arg id "$scope" 'any(.libraries[]; .id == $id)' "${deploy_dir}/knowledge/catalog.json" >/dev/null || { configuration_error '知识库不存在'; return 1; }
    filenames=$(jq -M -c --arg id "$scope" '[.libraries[] | select(.id == $id) | .documents[].projection]' "${deploy_dir}/knowledge/catalog.json")
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
  jq -M --arg scope "$scope" --slurpfile manifest "${deploy_dir}/data/knowledge-manifest.json" '.libraries |= map(if $scope != "all" and .id != $scope then . elif .enabled then
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
  jq -M "$@" "${filter} | .revision=((.revision // 0)+1)" "${deploy_dir}/knowledge/catalog.json" > "$temporary" || return 1
  knowledge_catalog_write "$deploy_dir" "$temporary"
}

knowledge_import_files() {
  local deploy_dir=$1 library_id=$2 requested=$3 inventory file name extension document_id source projection hash temporary
  local supported=0 existing_count=0 new_count=0
  local -a files=()
  inventory=$(mktemp "${deploy_dir}/tmp/knowledge-inventory.XXXXXX")
  knowledge_source_inventory "$requested" "$inventory" || { rm -f -- "$inventory"; return 1; }
  supported=$(jq -M -r '.supported_files' "$inventory")
  while IFS= read -r -d '' file; do files+=("$file"); done < <(knowledge_inventory_files "$inventory")
  rm -f -- "$inventory"
  for file in "${files[@]}"; do
    name=$(basename -- "$file")
    if ! jq -M -e --arg id "$library_id" --arg name "$name" \
      'any(.libraries[] | select(.id == $id) | .documents[]; .name == $name)' \
      "${deploy_dir}/knowledge/catalog.json" >/dev/null; then
      ((new_count += 1))
    fi
  done
  existing_count=$(jq -M -r --arg id "$library_id" '.libraries[] | select(.id == $id) | .documents | length' "${deploy_dir}/knowledge/catalog.json")
  (( existing_count + new_count <= 10000 )) || { configuration_error '导入后单个知识库文档数将超过 10000'; return 1; }
  for file in "${files[@]}"; do
    is_supported_knowledge_file "$file" || continue
    name=$(basename -- "$file")
    document_id=$(jq -M -r --arg id "$library_id" --arg name "$name" '.libraries[] | select(.id == $id) | .documents[] | select(.name == $name) | .id' "${deploy_dir}/knowledge/catalog.json")
    [[ -n "$document_id" ]] || document_id="doc_$(openssl rand -hex 8)"
    extension=${name##*.}; extension=${extension,,}
    source="sources/${document_id}.${extension}"
    projection=$(jq -M -r --arg id "$library_id" --arg doc "$document_id" '.libraries[] | select(.id == $id) | .documents[] | select(.id == $doc) | .projection' "${deploy_dir}/knowledge/catalog.json")
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
  local deploy_dir=$1 library=$2 question=$3 response status payload map question_bytes
  [[ "$library" == all ]] || knowledge_valid_id "$library" || return 1
  question_bytes=$(knowledge_utf8_bytes "$question")
  (( question_bytes > 0 && question_bytes <= 8000 )) || return 1
  anythingllm_connection "$deploy_dir"
  response=$(mktemp "${deploy_dir}/tmp/knowledge-query.XXXXXX")
  chmod 600 "$response"
  payload=$(jq -M -cn --arg query "$question" '{query:$query,topN:20,scoreThreshold:0}')
  status=$(anythingllm_secure_request "$deploy_dir" POST "http://127.0.0.1:${ANYTHING_PORT}/api/v1/workspace/${ANYTHING_WORKSPACE}/vector-search" "$ANYTHING_KEY" "$payload" "$response" 120)
  if [[ "$status" != 2?? ]] || ! jq -M -e '.results | type == "array"' "$response" >/dev/null; then rm -f -- "$response"; return 1; fi
  map="${deploy_dir}/data/runtime/knowledge-map.json"
  [[ -f "$map" ]] || { rm -f -- "$response"; return 1; }
  jq -M --arg library "$library" --slurpfile map "$map" '
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
  knowledge_validate_name "$name" 100 '知识库名称' || return 1
  knowledge_catalog_migrate "$deploy_dir" || return 1
  library_id=$(jq -M -r --arg name "$name" '.libraries[] | select(.name == $name) | .id' "${deploy_dir}/knowledge/catalog.json" | head -n 1)
  if [[ -z "$library_id" ]]; then
    jq -M -e '.libraries | length < 100' "${deploy_dir}/knowledge/catalog.json" >/dev/null \
      || { configuration_error '命名知识库数量不能超过 100'; return 1; }
    library_id="kb_$(openssl rand -hex 8)"
    mkdir -p -- "${deploy_dir}/knowledge/${library_id}/sources"
    knowledge_catalog_update "$deploy_dir" '.libraries += [{id:$id,name:$name,enabled:true,revision:1,documents:[],status:"pending",last_sync:null,error:null}]' --arg id "$library_id" --arg name "$name" || return 1
  fi
  knowledge_import_files "$deploy_dir" "$library_id" "$input" || return 1
  jq -M -n --arg id "$library_id" '{library_id:$id,status:"pending",applied:false}'
}

knowledge_main() (
  local deploy_request='' deploy_dir action library_id temporary name history removed_source='' status=0 failed_candidate inventory
  while (( $# )); do
    case "$1" in
      --deploy-dir) deploy_request=${2:?}; shift 2 ;;
      --help|-h) printf '%s\n' '用法：knowledge.sh [--deploy-dir PATH] list | create NAME | rename ID NAME | enable ID | disable ID | delete ID | entries ID | import ID PATH | remove ID DOCID | sync [ID|all] | reindex [ID|all] | query ID|all QUESTION' '无部署预检：knowledge.sh inspect-source PATH | validate-library-name NAME'; return ;;
      *) break ;;
    esac
  done
  action=${1:-list}; shift || true
  if [[ "$action" == inspect-source ]]; then
    (( $# == 1 )) || { configuration_error 'inspect-source 需要且仅需要一个文件或目录路径'; return 64; }
    inventory=$(mktemp "${TMPDIR:-/tmp}/crispai-knowledge-inspect.XXXXXXXX")
    if ! knowledge_source_inventory "$1" "$inventory"; then rm -f -- "$inventory"; return 1; fi
    jq -M 'del(.files)' "$inventory"
    rm -f -- "$inventory"
    return 0
  fi
  if [[ "$action" == validate-library-name ]]; then
    (( $# == 1 )) || { configuration_error 'validate-library-name 需要且仅需要一个知识库名称'; return 64; }
    knowledge_validate_name "$1" 100 '知识库名称' || return 1
    jq -M -n --arg name "$1" --argjson bytes "$(knowledge_utf8_bytes "$1")" \
      '{valid:true,name:$name,utf8_bytes:$bytes,max_utf8_bytes:100}'
    return 0
  fi
  deploy_dir=$(resolve_deploy_dir "$deploy_request")
  assert_managed_installation "$deploy_dir"
  acquire_maintenance_lock "$deploy_dir"
  configuration_runtime_init "$deploy_dir"
  knowledge_catalog_migrate "$deploy_dir" || return 1
  case "$action" in
    list) jq -M '.' "${deploy_dir}/knowledge/catalog.json"; return ;;
    entries) library_id=${1:?}; knowledge_valid_id "$library_id" || return 1; jq -M --arg id "$library_id" '.libraries[] | select(.id == $id) | {id,name,enabled,status,documents}' "${deploy_dir}/knowledge/catalog.json"; return ;;
    query) knowledge_query "$deploy_dir" "${1:-all}" "${2:?}"; return ;;
    bootstrap-source) knowledge_bootstrap_source "$deploy_dir" "${1:?}" "${2:?}"; return ;;
    sync|reindex)
      [[ ${1:-all} == all ]] || knowledge_valid_id "$1" || return 1
      if [[ ! -f "${deploy_dir}/config/materials-applied.json" ]]; then
        if [[ "$action" == reindex ]]; then knowledge_sync_catalog "$deploy_dir" 1 "${1:-all}"; else knowledge_sync_catalog "$deploy_dir" 0 "${1:-all}"; fi
        bash "${KNOWLEDGE_SCRIPT_DIR}/materials.sh" --deploy-dir "$deploy_dir" initialize >/dev/null
      elif [[ ${1:-all} != all ]]; then
        # 单库范围仍由现有索引器执行；随后统一投影回读新的 map/manifest。
        if [[ "$action" == reindex ]]; then knowledge_sync_catalog "$deploy_dir" 1 "$1"; else knowledge_sync_catalog "$deploy_dir" 0 "$1"; fi
        bash "${KNOWLEDGE_SCRIPT_DIR}/materials.sh" --deploy-dir "$deploy_dir" apply --refresh-projection >/dev/null
      elif [[ "$action" == reindex ]]; then
        bash "${KNOWLEDGE_SCRIPT_DIR}/materials.sh" --deploy-dir "$deploy_dir" apply --force-knowledge >/dev/null
      else
        bash "${KNOWLEDGE_SCRIPT_DIR}/materials.sh" --deploy-dir "$deploy_dir" apply --sync-knowledge >/dev/null
      fi
      jq -M '.' "${deploy_dir}/knowledge/catalog.json"
      return ;;
  esac
  if [[ "$action" != create ]]; then
    library_id=${1:?}; shift
    knowledge_valid_id "$library_id" || return 1
    jq -M -e --arg id "$library_id" 'any(.libraries[]; .id == $id)' "${deploy_dir}/knowledge/catalog.json" >/dev/null || { configuration_error '知识库不存在'; return 1; }
  fi
  configuration_materials_ensure "$deploy_dir" || return 1
  history=$(mktemp -d "${deploy_dir}/backups/config-history/knowledge.XXXXXXXX")
  tar -czf "${history}/knowledge.tar.gz" -C "$deploy_dir" knowledge
  chmod 600 "${history}/knowledge.tar.gz"
  case "$action" in
    create)
      name=${1:?}; knowledge_validate_name "$name" 100 '知识库名称' || return 1
      jq -M -e '.libraries | length < 100' "${deploy_dir}/knowledge/catalog.json" >/dev/null \
        || { configuration_error '命名知识库数量不能超过 100'; return 1; }
      library_id="kb_$(openssl rand -hex 8)"
      mkdir -p -- "${deploy_dir}/knowledge/${library_id}/sources"
      knowledge_catalog_update "$deploy_dir" '.libraries += [{id:$id,name:$name,enabled:true,revision:1,documents:[],status:"indexed",last_sync:null,error:null}]' --arg id "$library_id" --arg name "$name" || return 1 ;;
    rename)
      name=${1:?}; knowledge_validate_name "$name" 100 '知识库名称' || return 1
      knowledge_catalog_update "$deploy_dir" '.libraries |= map(if .id == $id then .name=$name | .revision+=1 else . end)' --arg id "$library_id" --arg name "$name" || return 1 ;;
    enable|disable)
      temporary=false; [[ "$action" != enable ]] || temporary=true
      knowledge_catalog_update "$deploy_dir" '.libraries |= map(if .id == $id then .enabled=$enabled | .revision+=1 else . end)' --arg id "$library_id" --argjson enabled "$temporary" || return 1 ;;
    delete)
      knowledge_catalog_update "$deploy_dir" '.libraries |= map(select(.id != $id))' --arg id "$library_id" || return 1 ;;
    import) knowledge_import_files "$deploy_dir" "$library_id" "${1:?}" || status=$? ;;
    remove)
      knowledge_valid_document "${1:?}" || return 1
      removed_source=$(jq -M -r --arg id "$library_id" --arg document "$1" '.libraries[] | select(.id == $id) | .documents[] | select(.id == $document) | .source' "${deploy_dir}/knowledge/catalog.json")
      [[ -n "$removed_source" ]] || { configuration_error '知识条目不存在'; return 1; }
      knowledge_catalog_update "$deploy_dir" '.libraries |= map(if .id == $id then .documents |= map(select(.id != $document)) else . end)' --arg id "$library_id" --arg document "$1" || return 1
      mkdir -p -- "${history}/${library_id}/sources"
      mv -- "${deploy_dir}/knowledge/${library_id}/${removed_source}" "${history}/${library_id}/${removed_source}" ;;
    *) configuration_error "未知知识库操作：$action"; return 1 ;;
  esac
  if (( status == 0 )) && bash "${KNOWLEDGE_SCRIPT_DIR}/materials.sh" --deploy-dir "$deploy_dir" apply >/dev/null; then
    if [[ "$action" == delete && -d "${deploy_dir}/knowledge/${library_id}" && ! -L "${deploy_dir}/knowledge/${library_id}" ]]; then
      mv -- "${deploy_dir}/knowledge/${library_id}" "${history}/${library_id}"
    fi
    jq -M --arg id "$library_id" '{library_id:$id,catalog:.}' "${deploy_dir}/knowledge/catalog.json"
    return 0
  fi
  failed_candidate="${history}/failed-candidate"
  temporary=$(mktemp -d "${deploy_dir}/tmp/knowledge-restore.XXXXXXXX")
  tar -xzf "${history}/knowledge.tar.gz" -C "$temporary" --no-same-owner --no-same-permissions
  if ! knowledge_replace_root_contents "${deploy_dir}/knowledge" "${temporary}/knowledge" "$failed_candidate"; then
    rm -rf -- "$temporary"
    configuration_error '知识修改失败，且旧原文未能完整回移；自动回复保持受控状态'
    return 1
  fi
  rm -rf -- "$temporary" "$failed_candidate"
  configuration_error '知识修改未通过实际索引与回读；旧配置和原文已恢复，可重新同步重试'
  return 1
)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then knowledge_main "$@"; fi
