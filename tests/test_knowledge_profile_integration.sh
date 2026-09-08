#!/usr/bin/env bash
# 真实知识迁移编排与纯合成组件边界回归；不连接 Docker、模型或任何目标机。
set -euo pipefail

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
for command in python3 bash jq flock timeout sha256sum tar; do
  command -v "$command" >/dev/null || { printf '缺少测试依赖：%s\n' "$command" >&2; exit 1; }
done
exec python3 - "$TEST_ROOT" "$@" <<'PY'
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid

ROOT = Path(sys.argv[1]).resolve()
AREA = ROOT / '.work/v1.2.1'
AREA.mkdir(parents=True, exist_ok=True)
WORK = Path(tempfile.mkdtemp(prefix='knowledge-profile-integration-', dir=AREA))
WORK.chmod(0o700)
SOURCE = WORK / 'source'
SOURCE.mkdir(mode=0o700)
for folder in ('scripts', 'config'):
    shutil.copytree(ROOT / folder, SOURCE / folder)
for name in ('install.sh', 'update.sh', 'docker-compose.yml'):
    shutil.copy2(ROOT / name, SOURCE / name)
shutil.copy2(ROOT / 'tests/test_knowledge_profile_integration.sh', WORK / 'test-input.sh')
MINI = 'Xenova/all-MiniLM-L6-v2'
MULTI = 'MintplexLabs/multilingual-e5-small'
NOMIC = 'Xenova/nomic-embed-text-v1'
LIBRARY = 'kb_' + '1' * 16
DOCUMENT = 'doc_' + '2' * 16
LIBRARY_TWO = 'kb_' + '3' * 16
DOCUMENT_TWO = 'doc_' + '4' * 16
PROJECTION = LIBRARY + '_' + DOCUMENT + '.md'
LOCATION = 'custom-documents/' + PROJECTION + '.fixture.json'
PROFILE = 'data/runtime/knowledge-profile.json'
SETTINGS = 'data/runtime/knowledge-settings.json'
LEXICAL = 'data/runtime/knowledge-lexical.json'
PROTECTED = ('data/runtime/session-' + 'a' * 64 + '.json',
             'data/runtime/jobs/' + 'b' * 64 + '.json',
             'data/runtime/owned-' + 'a' * 64 + '-01.json',
             'data/runtime/router/questions/' + 'c' * 64 + '.json',
             'data/runtime/offer-' + 'd' * 64 + '.json')
INPUTS = tuple('scripts/' + name for name in (
    'knowledge-profile.sh', 'knowledge-profile.py', 'knowledge-component.js',
    'knowledge.sh', 'knowledge-lexical.py', 'common.sh', 'materials.sh', 'configuration.sh')) + ('install.sh', 'update.sh', 'docker-compose.yml')


def sha(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()


def save(file, value, mode=0o600):
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True) + '\n', encoding='utf-8')
    file.chmod(mode)


def load(file):
    return json.loads(file.read_text(encoding='utf-8'))


def write(file, value, mode=0o600):
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_text(value, encoding='utf-8')
    file.chmod(mode)


def inventory(directory):
    result = {}
    for path in [directory, *sorted(directory.rglob('*'))]:
        info = path.lstat()
        key = str(path.relative_to(directory))
        if stat.S_ISREG(info.st_mode):
            value = ('file', sha(path))
        elif stat.S_ISLNK(info.st_mode):
            value = ('link', os.readlink(path))
        else:
            value = ('directory',)
        result[key] = (*value, stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid)
    return result


# 所有边界程序都固定消费本用例路径；未识别命令直接失败，不调用真实网络/Docker。
HELPER = WORK / 'boundary.py'
write(HELPER, r'''import hashlib, json, os, pathlib, subprocess, sys, uuid
D = pathlib.Path(os.environ['KPI_DEPLOY']).resolve()
F = D / '.fixture'
S = D / 'data/anythingllm/component-state.json'
C = F / 'control.json'
MINI = 'Xenova/all-MiniLM-L6-v2'
MULTI = 'MintplexLabs/multilingual-e5-small'
NOMIC = 'Xenova/nomic-embed-text-v1'
PROFILE = D / 'data/runtime/knowledge-profile.json'
MATERIALS = D / 'config/materials-applied.json'
def read(path, default=None):
    return json.loads(path.read_text()) if path.exists() else default
def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.fixture-tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True) + '\n')
    temporary.chmod(0o600)
    os.replace(temporary, path)
def phase():
    profile = read(PROFILE, {})
    materials = read(MATERIALS, {})
    pointer = read(D / 'data/runtime/knowledge-migration.json', {})
    backup = pathlib.Path(pointer['backup']) if pointer.get('backup') else None
    return {'profile': profile.get('state'), 'materials': materials.get('state'),
            'complete': bool(backup and (backup / 'complete.json').is_file()),
            'running': read(F / 'running.json', False)}
def log(event, **extra):
    with (F / 'events.jsonl').open('a', encoding='utf-8') as stream:
        stream.write(json.dumps({'event': event, **phase(), **extra}, sort_keys=True) + '\n')
def reject():
    log('unsupported_boundary')
    raise SystemExit(64)
def env():
    result = {}
    for line in (D / '.env').read_text().splitlines():
        if '=' not in line or line.startswith('#'): continue
        key, value = line.split('=', 1)
        if value.startswith('"'): value = json.loads(value)
        result[key] = value
    return result
def observed(state):
    prefixes = {MINI: ('', ''), MULTI: ('passage: ', 'query: '), NOMIC: ('search_document: ', 'search_query: ')}
    passage, query = prefixes[state['model']]
    return {'engine': 'native', 'model': state['model'], 'chunk_size': state['chunk_size'],
            'chunk_overlap': state['chunk_overlap'], 'explicit_model': state['explicit_model'],
            'explicit_chunk_size': state['explicit_chunk_size'], 'passage_prefix': passage,
            'query_prefix': query, 'component_version': '1.16.1', 'foreign_documents': state.get('foreign_documents', 0),
            'workspace_documents': len(state['locations']), 'workspace_exists': True}
def update_control(**fields):
    value = read(C)
    value.update(fields)
    save(C, value)
    return value
mode, args = sys.argv[1], sys.argv[2:]
control = read(C)
if mode == 'python3':
    offset = 1 if args and args[0] == '-B' else 0
    if len(args) > offset and pathlib.Path(args[offset]).name == 'knowledge-profile.py':
        profile_args = args[offset:]
        if profile_args[1:3] != ['--deploy-dir', str(D)]: reject()
        action = profile_args[3]
        log('python_' + action + '_before', arguments=profile_args[4:])
        result = subprocess.run([os.environ['KPI_PYTHON'], *args], check=False)
        log('python_' + action + '_after', code=result.returncode, arguments=profile_args[4:])
        raise SystemExit(result.returncode)
    os.execv(os.environ['KPI_PYTHON'], [os.environ['KPI_PYTHON'], *args])
elif mode == 'awk':
    if args == ['/^MemTotal:/ {print $2; exit}', '/proc/meminfo']:
        print(control['memory_kib'])
    else:
        os.execv(os.environ['KPI_AWK'], [os.environ['KPI_AWK'], *args])
elif mode == 'date':
    if args == ['+%s']: print(control['clock'])
    else: os.execv(os.environ['KPI_DATE'], [os.environ['KPI_DATE'], *args])
elif mode == 'curl':
    if args != ['-q', '--fail', '--silent', '--connect-timeout', '3', '--max-time', '5',
                'http://127.0.0.1:3001/api/ping']: reject()
    log('ping')
    raise SystemExit(0 if read(F / 'running.json') else 1)
elif mode == 'docker':
    prefix = ['compose', '--project-directory', str(D), '--env-file', str(D / '.env'), '-f', str(D / 'docker-compose.yml')]
    if args[:len(prefix)] != prefix: reject()
    args = args[len(prefix):]
    state = read(S)
    if args == ['stop', '--timeout', '30', 'anythingllm']:
        log('stop')
        save(F / 'running.json', False)
    elif args in (['up', '-d', '--no-deps', 'anythingllm'],
                  ['up', '-d', '--no-deps', '--force-recreate', 'anythingllm'],
                  ['up', '-d', '--remove-orphans']):
        state['model'] = env().get('KNOWLEDGE_ACTIVE_EMBEDDING_MODEL', MINI)
        save(S, state)
        save(F / 'running.json', True)
        log('up', active_model=state['model'], force_recreate='--force-recreate' in args)
    elif args[:5] == ['exec', '-T', 'anythingllm', 'node', '-']:
        if len(args) < 7 or args[6] != 'synthetic_workspace': reject()
        action = args[5]
        # 确保真实脚本是通过标准输入交给组件边界，而不是跳过生产调用点。
        if 'workspace_documents' not in sys.stdin.read(): reject()
        if not read(F / 'running.json'): raise SystemExit(1)
        if action == 'observe' and len(args) == 7:
            if control.get('observe_unavailable'): raise SystemExit(1)
            output = observed(state)
            if control.get('fault') == 'commit' and control.get('syncs', 0) and not control.get('fault_consumed'):
                output = observed({**state, 'model': MINI if state['model'] != MINI else MULTI})
                update_control(fault_consumed=True)
            log('observe', active_model=output['model'])
            print(json.dumps(output))
        elif action == 'configure-chunks' and len(args) == 9:
            log('configure')
            if control.get('fault') == 'configure' and not control.get('fault_consumed'):
                update_control(fault_consumed=True)
                raise SystemExit(1)
            state.update(chunk_size=int(args[7]), chunk_overlap=int(args[8]), explicit_chunk_size=True)
            save(S, state)
            print(json.dumps(observed(state)))
        else: reject()
    elif args[:5] == ['exec', '-T', 'n8n', 'node', '-e'] and len(args) == 6:
        if 'materials-applied.json' not in args[5] or 'sha256' not in args[5]: reject()
        log('projection_readback')
        if control.get('fault') == 'readback' and control.get('syncs', 0) and not control.get('fault_consumed'):
            update_control(fault_consumed=True)
            print('0' * 64, end='')
        else: print(hashlib.sha256(MATERIALS.read_bytes()).hexdigest(), end='')
    else: reject()
elif mode == 'admin-query':
    if len(args) != 2 or args[0] != str(D): reject()
    save(F / 'received-question.json', {'question': args[1]})
    log('admin_query')
    if control.get('query_mutate_map'):
        mapping = read(D / 'data/runtime/knowledge-map.json')
        mapping['documents'][0]['library_name'] = '并发替换后的库'
        save(D / 'data/runtime/knowledge-map.json', mapping)
    if control.get('query_failure'):
        print(json.dumps({'error': 'Bearer fixture-query-secret-never-print',
                          'url': 'https://invalid.example/?token=fixture-query-token-never-print'}))
        raise SystemExit(1)
    result = read(F / 'admin-query.json')
    if not isinstance(result, dict): reject()
    print(json.dumps(result, ensure_ascii=False))
elif mode == 'api':
    if len(args) not in (6, 7) or args[:3] != [str(D), 'GET', 'http://127.0.0.1:3001/api/v1/workspace/synthetic_workspace']:
        reject()
    if args[3:5] != ['synthetic-key-not-real', '']: reject()
    output = pathlib.Path(args[5])
    if output.parent != D / 'tmp': reject()
    state = read(S)
    workspace = {'slug': 'synthetic_workspace', 'openAiPrompt': (D / 'config/prompt.md').read_text(),
                 'openAiTemp': state['temperature'], 'documents': [{'docpath': p} for p in state['locations']]}
    case = control.get('api_case', '')
    if case == 'wrong_slug': workspace['slug'] = 'other_synthetic_workspace'
    if case == 'invalid_temp': workspace['openAiTemp'] = 3
    if case == 'string_temp': workspace['openAiTemp'] = '0.7'
    if case == 'boolean_temp': workspace['openAiTemp'] = False
    body = {'workspace': [workspace]}
    if case == 'multiple': body['workspace'].append(dict(workspace))
    if case == 'object': body['workspace'] = workspace
    if case == 'schema': body = {'workspace': None}
    if case == 'malformed': output.write_text('{')
    else: save(output, body)
    log('workspace_read')
    print('503' if case == 'http' else '200')
elif mode == 'sync':
    if len(args) != 3 or args[0] != str(D) or args[1] not in ('0', '1') or args[2] != 'null': reject()
    current = phase()
    ordinary = bool(control.get('ordinary_sync'))
    force = args[1] == '1'
    operation = control.get('ordinary_operation', 'normal')
    if ordinary:
        if current['profile'] != 'applied' or current['materials'] != 'applied' or not current['running']:
            reject()
        if operation not in ('normal', 'update', 'retry'): reject()
        log('ordinary_sync', force=int(force), operation=operation)
    else:
        if current['profile'] != 'applying' or current['materials'] != 'applying' or not current['complete'] or not current['running']:
            reject()
        log('forced_sync', force=1)
    control = update_control(syncs=control.get('syncs', 0) + 1, clock=2000)
    if control.get('concurrent'):
        expected = {}
        for relative in control['protected']:
            path = D / relative
            value = read(path)
            value.update(generation=value['generation'] + 1, event='during-migration', jobs=['old', 'new'])
            save(path, value)
            expected[relative] = path.read_text()
        save(F / 'expected-protected.json', expected)
    manifest_path = D / 'data/knowledge-manifest.json'
    manifest = read(manifest_path)
    locations = []
    rewrite = not ordinary or force or operation == 'update'
    for projection, record in manifest['files'].items():
        if rewrite:
            record['embedding_profile'] = read(PROFILE)['fingerprint']
            previous_location = record['locations'][0]
            location = 'custom-documents/' + projection + '.reindexed-' + str(control['syncs']) + '.json'
            document = read(D / 'data/anythingllm/documents' / previous_location)
            save(D / 'data/anythingllm/documents' / location, document)
            record['locations'] = [location]
            record.pop('cache_bindings', None)
            cache = D / 'data/anythingllm/vector-cache' / (str(uuid.uuid5(uuid.NAMESPACE_URL, location)) + '.json')
            save(cache, {'synthetic_cache': 'new-embedding-generation', 'operation': operation, 'force': force})
        locations.extend(record['locations'])
    manifest['pending_files'] = {}
    manifest['garbage_locations'] = []
    save(manifest_path, manifest)
    save(D / 'data/runtime/knowledge-lexical.json', {'schema_version': 1, 'fixture': 'new-lexical', 'documents': []})
    state = read(S)
    state['temperature'] = 0.25
    state['locations'] = locations
    save(S, state)
    (D / 'data/anythingllm/anythingllm.db').write_bytes(b'synthetic-database-after-sync\0')
    (D / 'data/anythingllm/lancedb/fragment.bin').write_bytes(b'synthetic-vector-after-sync')
    if control.get('fault') == 'sync' and not control.get('fault_consumed'):
        update_control(fault_consumed=True)
        raise SystemExit(1)
else:
    reject()
''')

BIN = WORK / 'bin'
BIN.mkdir(mode=0o700)
for program in ('docker', 'curl', 'awk', 'date', 'python3'):
    write(BIN / program, '#!/usr/bin/env bash\nset -euo pipefail\n'
          'exec "$KPI_PYTHON" "$KPI_HELPER" ' + program + ' "$@"\n', 0o700)
DRIVER = WORK / 'driver.sh'
write(DRIVER, r'''#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1090
source "$KPI_SOURCE/scripts/knowledge-profile.sh"
configuration_query() { "$KPI_PYTHON" "$KPI_HELPER" admin-query "$@"; }
anythingllm_connection() {
  ANYTHING_DEPLOY_DIR=$1
  ANYTHING_KEY=synthetic-key-not-real
  ANYTHING_WORKSPACE=synthetic_workspace
  ANYTHING_PORT=3001
}
anythingllm_secure_request() { "$KPI_PYTHON" "$KPI_HELPER" api "$@"; }
knowledge_sync_legacy() {
  "$KPI_PYTHON" "$KPI_HELPER" sync "$@" || return $?
  if [[ ${KPI_INTERRUPT_SYNC:-0} == 1 ]]; then
    # 只向当前合成 ensure 子 Shell 发信号，不按用户、名称或进程组匹配。
    kill -TERM "$BASHPID"
  fi
}
case "$1" in
  initialize) materials_initialize "$KPI_DEPLOY" ;;
  capture) knowledge_profile_capture "$KPI_DEPLOY" ;;
  capture-start)
    knowledge_profile_capture "$KPI_DEPLOY"
    docker_compose "$KPI_DEPLOY" up -d --remove-orphans
    ;;
  start-without-capture) docker_compose "$KPI_DEPLOY" up -d --remove-orphans ;;
  ensure) knowledge_profile_ensure "$KPI_DEPLOY" ;;
  ordinary-sync) knowledge_sync_catalog "$KPI_DEPLOY" 0 ;;
  ordinary-force) knowledge_sync_catalog "$KPI_DEPLOY" 1 ;;
  profile-current) knowledge_current_profile "$KPI_DEPLOY" ;;
  query-all) knowledge_query "$KPI_DEPLOY" all "$(<"$KPI_DEPLOY/.fixture/question.txt")" ;;
  query-library) knowledge_query "$KPI_DEPLOY" "$KPI_LIBRARY" "$(<"$KPI_DEPLOY/.fixture/question.txt")" ;;
  restore)
    backup=$(jq -er '.backup' "$KPI_DEPLOY/data/runtime/knowledge-migration.json")
    knowledge_profile_restore "$KPI_DEPLOY" "$backup"
    ;;
  outer-ensure)
    acquire_maintenance_lock "$KPI_DEPLOY"
    bash "$0" ensure
    ;;
  settings)
    anythingllm_connection "$KPI_DEPLOY"
    anythingllm_workspace_runtime_settings "$KPI_DEPLOY"
    ;;
  settings-repeat)
    anythingllm_connection "$KPI_DEPLOY"
    for ((iteration=0; iteration<12; iteration++)); do
      anythingllm_workspace_runtime_settings "$KPI_DEPLOY"
    done
    ;;
  prepare)
    materials_prepare_candidate "$KPI_DEPLOY" "$KPI_DEPLOY/tmp/candidate" 9 applied
    ;;
  *) exit 64 ;;
esac
''', 0o700)


class Integration(unittest.TestCase):
    def setUp(self):
        self.deploy = Path(tempfile.mkdtemp(prefix=self._testMethodName + '-', dir=WORK))
        self.deploy.chmod(0o700)
        for folder in ('config', 'tmp', 'data/runtime', 'data/anythingllm/vector-cache',
                       'data/anythingllm/documents/custom-documents', 'data/anythingllm/lancedb',
                       'backups/config-history', '.fixture', 'knowledge/' + LIBRARY + '/sources'):
            (self.deploy / folder).mkdir(parents=True, exist_ok=True)
        self.fixture = self.deploy / '.fixture'
        self.control = self.fixture / 'control.json'
        self.state = self.deploy / 'data/anythingllm/component-state.json'
        save(self.control, {'memory_kib': 8 * 1024 * 1024, 'clock': 1000, 'syncs': 0, 'protected': list(PROTECTED)})
        save(self.fixture / 'running.json', True)
        save(self.state, {'model': MINI, 'chunk_size': 1000, 'chunk_overlap': 20,
                         'explicit_model': False, 'explicit_chunk_size': False,
                         'temperature': None, 'locations': [LOCATION]})
        write(self.fixture / 'events.jsonl', '')
        write(self.deploy / '.crisp-ai-installation', 'ai-support\nstate=ready\n')
        write(self.deploy / 'VERSION', 'v1.2.1\n')
        write(self.deploy / 'docker-compose.yml', 'services: {}\n')
        write(self.deploy / '.env', 'ANYTHINGLLM_WORKSPACE=synthetic_workspace\nANYTHINGLLM_PORT=3001\n'
              'ANYTHINGLLM_API_KEY=synthetic-key-not-real\n')
        write(self.deploy / 'data/anythingllm/.env', 'SYNTHETIC_INTERNAL=not-a-real-key\n')
        (self.deploy / 'data/anythingllm/anythingllm.db').write_bytes(b'synthetic-database-before\0')
        (self.deploy / 'data/anythingllm/lancedb/fragment.bin').write_bytes(b'synthetic-vector-before')
        save(self.deploy / 'data/anythingllm/documents' / LOCATION, {'pageContent': '纯虚构说明：测试灯亮时设备就绪。'})
        save(self.deploy / 'data/anythingllm/vector-cache' / (str(uuid.uuid5(uuid.NAMESPACE_URL, LOCATION)) + '.json'),
             {'synthetic_cache': 'before'})
        for name in ('runtime', 'handoff', 'keyword', 'menu', 'tags', 'feedback'):
            target = self.deploy / 'config' / (name + '.yaml')
            shutil.copyfile(SOURCE / 'config' / (name + '.yaml.example'), target)
            target.chmod(0o640)
        write(self.deploy / 'config/runtime.yaml', 'schema_version: 2\nenabled: true\nrevision: 3\napplied_revision: 3\n', 0o640)
        write(self.deploy / 'config/prompt.md', '# 合成客服规则\n只回答本测试文档；此处没有客户资料。\n', 0o640)
        raw = self.deploy / 'knowledge' / LIBRARY / 'sources' / (DOCUMENT + '.md')
        write(raw, '# 纯虚构说明\n测试灯亮时设备就绪。\n', 0o640)
        shutil.copy2(raw, self.deploy / 'knowledge' / PROJECTION)
        save(self.deploy / 'knowledge/catalog.json', {'schema_version': 2, 'revision': 1, 'libraries': [{
            'id': LIBRARY, 'name': '合成库', 'enabled': True, 'revision': 1, 'status': 'indexed',
            'last_sync': 1000, 'error': None, 'documents': [{'id': DOCUMENT, 'name': '合成说明.md',
            'source': 'sources/' + DOCUMENT + '.md', 'projection': PROJECTION, 'sha256': sha(raw)}]}]}, 0o640)
        save(self.deploy / 'data/knowledge-manifest.json', {'version': 1, 'files': {
            PROJECTION: {'sha256': sha(raw), 'locations': [LOCATION]}}, 'pending_files': {}, 'garbage_locations': []})
        save(self.deploy / 'data/knowledge-projection.json', [PROJECTION])
        save(self.deploy / LEXICAL, {'schema_version': 1, 'fixture': 'old-lexical', 'documents': []}, 0o640)
        for relative in PROTECTED:
            save(self.deploy / relative, {'generation': 4, 'mode': 'human', 'resume_at': 0,
                                         'event': 'before-migration', 'jobs': ['old']})
        self.environment = {key: value for key, value in os.environ.items()
                            if key not in ('CRISP_AI_MAINTENANCE_LOCK_HELD', 'MAINTENANCE_LOCK_FD',
                                           'CRISP_AI_MAINTENANCE_LOCK_PATH')}
        self.environment.update(PATH=str(BIN) + ':' + os.environ['PATH'], KPI_SOURCE=str(SOURCE),
                                KPI_DEPLOY=str(self.deploy), KPI_HELPER=str(HELPER), KPI_PYTHON=sys.executable,
                                KPI_AWK=shutil.which('awk'), KPI_DATE=shutil.which('date'), KPI_LIBRARY=LIBRARY)
        self.call_sequence = 0
        self.ok('initialize')
        self.initial_protected = {relative: (self.deploy / relative).read_text() for relative in PROTECTED}
        write(self.fixture / 'events.jsonl', '')

    def set_control(self, **fields):
        save(self.control, {**load(self.control), **fields})

    def set_state(self, **fields):
        save(self.state, {**load(self.state), **fields})

    def call(self, action):
        self.call_sequence += 1
        result = subprocess.run(['bash', str(DRIVER), action], cwd=self.deploy,
                                env=self.environment, capture_output=True, text=True, timeout=50, check=False)
        write(self.fixture / ('command-%02d-%s.log' % (self.call_sequence, action)),
              'exit=' + str(result.returncode) + '\n' + result.stdout + result.stderr)
        return result

    def ok(self, action):
        result = self.call(action)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def events(self):
        return [json.loads(line) for line in (self.fixture / 'events.jsonl').read_text().splitlines()]

    def env_value(self, key):
        for line in (self.deploy / '.env').read_text().splitlines():
            if line.startswith(key + '='):
                value = line.split('=', 1)[1]
                return json.loads(value) if value.startswith('"') else value
        return None

    def backups(self):
        return sorted((self.deploy / 'backups/knowledge-profiles').glob('generation.*'))

    def prepare_query(self, sources, question='请根据现有知识库回答：虚构灯塔周三开放吗？'):
        write(self.fixture / 'question.txt', question)
        save(self.fixture / 'admin-query.json', {'answer': '虚构灯塔周三闭馆。', 'sources': sources,
             'verified': True, 'retrieval_state': 'knowledge_hit'})
        return question

    def assert_protected(self, concurrent=False):
        expected = load(self.fixture / 'expected-protected.json') if concurrent else self.initial_protected
        self.assertEqual({relative: (self.deploy / relative).read_text() for relative in PROTECTED}, expected)
        self.assertTrue(load(self.deploy / 'config/runtime.yaml')['enabled'])

    def assert_hashes(self):
        projection = load(self.deploy / 'config/materials-applied.json')
        for key, relative in (('manifest_sha256', 'data/knowledge-manifest.json'),
                              ('map_sha256', 'data/runtime/knowledge-map.json'),
                              ('settings_sha256', SETTINGS), ('lexical_sha256', LEXICAL),
                              ('profile_sha256', PROFILE)):
            expected = sha(self.deploy / relative) if (self.deploy / relative).exists() else ''
            self.assertEqual(projection['knowledge'][key], expected, key)

    def baseline(self):
        return {'storage': inventory(self.deploy / 'data/anythingllm'),
                'settings': (self.deploy / SETTINGS).read_bytes(),
                'lexical': (self.deploy / LEXICAL).read_bytes(),
                'projection': load(self.deploy / 'config/materials-applied.json')}

    def assert_restored(self, before, concurrent=False):
        self.assertEqual(inventory(self.deploy / 'data/anythingllm'), before['storage'])
        self.assertEqual((self.deploy / SETTINGS).read_bytes(), before['settings'])
        self.assertEqual((self.deploy / LEXICAL).read_bytes(), before['lexical'])
        self.assertFalse((self.deploy / PROFILE).exists())
        self.assertFalse((self.deploy / 'data/runtime/knowledge-migration.json').exists())
        current = load(self.deploy / 'config/materials-applied.json')
        for key in ('prompt', 'knowledge', 'source_components', 'source_sha256'):
            self.assertEqual(current[key], before['projection'][key], key)
        for key in ('handoff', 'keyword', 'menu', 'tags', 'feedback'):
            self.assertEqual(current['configuration'][key], before['projection']['configuration'][key], key)
        self.assertEqual(current['configuration']['runtime']['enabled'],
                         before['projection']['configuration']['runtime']['enabled'])
        self.assertEqual(current['state'], 'applied')
        self.assertGreater(current['revision'], before['projection']['revision'])
        self.assertEqual(self.env_value('KNOWLEDGE_ACTIVE_EMBEDDING_MODEL'), MINI)
        self.assertTrue(load(self.fixture / 'running.json'))
        self.assert_hashes()
        self.assert_protected(concurrent)

    def test_successful_migration_runs_real_order_and_projection_hashes(self):
        before = self.baseline()
        self.ok('ensure')
        events = self.events()
        names = [event['event'] for event in events]
        ordered = ('observe', 'python_plan_after', 'stop', 'python_backup_after',
                   'python_activate_after', 'up', 'configure', 'forced_sync',
                   'python_commit_after', 'projection_readback')
        previous = -1
        for name in ordered:
            previous = names.index(name, previous + 1)
        up = next(event for event in events if event['event'] == 'up')
        self.assertEqual((up['materials'], up['profile'], up['complete']), ('applying', 'applying', True))
        backup = self.backups()[0]
        self.assertEqual(inventory(backup / 'anythingllm'), before['storage'])
        self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((backup / 'complete.json').stat().st_mode), 0o600)
        self.assertFalse((backup / 'old-projection.json').exists())
        profile = load(self.deploy / PROFILE)
        self.assertEqual(profile['state'], 'applied')
        self.assertEqual((profile['profile']['model'], profile['profile']['chunk_size']), (MULTI, 400))
        self.assertEqual(self.env_value('KNOWLEDGE_ACTIVE_EMBEDDING_MODEL'), MULTI)
        self.assertEqual(load(self.control)['syncs'], 1)
        self.assertEqual(load(self.deploy / SETTINGS)['temperature'], 0.25)
        self.assertNotEqual((self.deploy / LEXICAL).read_bytes(), before['lexical'])
        self.assertEqual(load(self.deploy / LEXICAL)['algorithm'], 'crispai-lexical-v1')
        self.assertFalse((self.deploy / 'data/runtime/knowledge-migration.json').exists())
        refreshes = [event['arguments'] for event in events if event['event'] == 'python_refresh-bindings_before']
        self.assertEqual(refreshes, [['--allow-migration', '--validate-only'],
                                     ['--allow-migration'], ['--allow-migration']])
        self.assert_hashes()
        self.assert_protected()

    def test_ordinary_sync_preserves_then_update_and_force_refresh_cache_bindings(self):
        self.ok('ensure')
        self.set_control(ordinary_sync=True)
        previous_syncs = load(self.control)['syncs']
        original = load(self.deploy / 'data/knowledge-manifest.json')['files'][PROJECTION]['cache_bindings']
        write(self.fixture / 'events.jsonl', '')
        self.ok('ordinary-sync')
        self.assertEqual(load(self.control)['syncs'], previous_syncs + 1)
        self.assertEqual(load(self.deploy / 'data/knowledge-manifest.json')['files'][PROJECTION]['cache_bindings'], original)
        refreshes = [event['arguments'] for event in self.events() if event['event'] == 'python_refresh-bindings_before']
        self.assertEqual(refreshes, [['--validate-only'], []])

        # 普通内容更新会让同步器只删除该记录的旧摘要；post 仅补这份新缓存。
        self.set_control(ordinary_operation='update')
        write(self.fixture / 'events.jsonl', '')
        self.ok('ordinary-sync')
        updated = load(self.deploy / 'data/knowledge-manifest.json')['files'][PROJECTION]
        self.assertNotEqual(updated['cache_bindings'], original)
        self.assertEqual(self.events()[0]['event'], 'python_refresh-bindings_before')
        self.assertEqual(self.events()[0]['arguments'], ['--validate-only'])

        # force 即使正文 hash 不变也产生新索引位置；新摘要同样由 post 补齐。
        before_force = updated['cache_bindings']
        self.set_control(ordinary_operation='normal')
        write(self.fixture / 'events.jsonl', '')
        self.ok('ordinary-force')
        self.assertNotEqual(load(self.deploy / 'data/knowledge-manifest.json')['files'][PROJECTION]['cache_bindings'],
                            before_force)
        manifest = load(self.deploy / 'data/knowledge-manifest.json')
        fingerprint = load(self.deploy / PROFILE)['fingerprint']
        for record in manifest['files'].values():
            self.assertEqual(record['embedding_profile'], fingerprint)
            self.assertEqual(len(record['cache_bindings']), len(record['locations']))
            for binding in record['cache_bindings']:
                cache = self.deploy / 'data/anythingllm/vector-cache' / (str(uuid.uuid5(uuid.NAMESPACE_URL, binding['location'])) + '.json')
                self.assertEqual(binding['sha256'], sha(cache))
        self.assertTrue(any(event['event'] == 'ordinary_sync' for event in self.events()))
        self.assert_protected()

    def test_pending_and_garbage_retry_passes_read_only_preflight_then_refreshes(self):
        self.ok('ensure')
        self.set_control(ordinary_sync=True, ordinary_operation='retry')
        manifest_path = self.deploy / 'data/knowledge-manifest.json'
        manifest = load(manifest_path)
        profile = load(self.deploy / PROFILE)['fingerprint']
        pending = 'custom-documents/pending-fixture.json'
        stale = 'custom-documents/stale-fixture.json'
        manifest['pending_files'] = {'pending-fixture.md': {'sha256': 'd' * 64, 'locations': [pending],
             'old_locations': [], 'started_at': 1, 'embedding_profile': profile}}
        manifest['garbage_locations'] = [stale]
        save(manifest_path, manifest)
        previous_syncs = load(self.control)['syncs']
        write(self.fixture / 'events.jsonl', '')
        self.ok('ordinary-sync')
        current = load(manifest_path)
        self.assertEqual(current['pending_files'], {})
        self.assertEqual(current['garbage_locations'], [])
        self.assertEqual(load(self.control)['syncs'], previous_syncs + 1)
        refreshes = [event['arguments'] for event in self.events() if event['event'] == 'python_refresh-bindings_before']
        self.assertEqual(refreshes, [['--validate-only'], []])
        self.assert_protected()

    def test_cache_tamper_is_rejected_before_external_sync_and_never_resigned(self):
        self.ok('ensure')
        self.set_control(ordinary_sync=True)
        manifest_path = self.deploy / 'data/knowledge-manifest.json'
        before_manifest = manifest_path.read_bytes()
        binding = load(manifest_path)['files'][PROJECTION]['cache_bindings'][0]
        cache = self.deploy / 'data/anythingllm/vector-cache' / (str(uuid.uuid5(uuid.NAMESPACE_URL, binding['location'])) + '.json')
        cache.write_bytes(b'{"synthetic_cache":"tampered"}\n')
        before_syncs = load(self.control)['syncs']
        write(self.fixture / 'events.jsonl', '')
        result = self.call('ordinary-sync')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(load(self.control)['syncs'], before_syncs)
        self.assertEqual(manifest_path.read_bytes(), before_manifest)
        self.assertFalse(any(event['event'] == 'ordinary_sync' for event in self.events()))
        self.assert_protected()

    def test_ordinary_sync_rejects_stale_migration_pointer_before_external_sync(self):
        self.ok('ensure')
        self.set_control(ordinary_sync=True)
        backup = self.backups()[0]
        save(self.deploy / 'data/runtime/knowledge-migration.json', {'schema_version': 1, 'backup': str(backup)})
        before_manifest = (self.deploy / 'data/knowledge-manifest.json').read_bytes()
        before_syncs = load(self.control)['syncs']
        write(self.fixture / 'events.jsonl', '')
        result = self.call('ordinary-sync')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(load(self.control)['syncs'], before_syncs)
        self.assertEqual((self.deploy / 'data/knowledge-manifest.json').read_bytes(), before_manifest)
        self.assertFalse(any(event['event'] == 'ordinary_sync' for event in self.events()))
        self.assert_protected()

        # 悬空链接不是“旧实例尚无代次文件”；否则同步入口会把不安全的
        # profile 当成合法缺省值继续。
        profile_path = self.deploy / PROFILE
        profile_backup = self.fixture / 'profile-backup.json'
        profile_path.rename(profile_backup)
        profile_path.symlink_to(self.fixture / 'missing-profile.json')
        result = self.call('profile-current')
        self.assertNotEqual(result.returncode, 0)
        profile_path.unlink()
        profile_backup.rename(profile_path)
        self.assert_protected()

    def test_query_uses_production_admin_chain_and_exact_source_not_similar_prefix(self):
        self.ok('ensure')
        mapping_path = self.deploy / 'data/runtime/knowledge-map.json'
        mapping = load(mapping_path)
        first = mapping['documents'][0]
        second_projection = first['projection'] + '.similar.md'
        second_location = 'custom-documents/' + second_projection + '.fixture-query-private-location.json'
        mapping['documents'].append({'library_id': LIBRARY_TWO, 'library_name': '第二个合成库',
            'document_id': DOCUMENT_TWO, 'projection': second_projection, 'location': second_location})
        save(mapping_path, mapping)
        materials = load(self.deploy / 'config/materials-applied.json')
        materials['knowledge']['map_sha256'] = sha(mapping_path)
        save(self.deploy / 'config/materials-applied.json', materials)
        question = self.prepare_query([second_location])
        write(self.fixture / 'events.jsonl', '')
        result = self.ok('query-library')
        output = json.loads(result.stdout)
        self.assertEqual(load(self.fixture / 'received-question.json')['question'], question)
        self.assertEqual(output['answer'], '虚构灯塔周三闭馆。')
        self.assertEqual(output['scope'], '全部已启用知识库（与实际客服一致）')
        self.assertIn('所选单库不作为额外过滤', output['note'])
        self.assertEqual(output['sources'], [{'library_name': '第二个合成库', 'projection': second_projection}])
        self.assertNotIn(second_location, result.stdout + result.stderr)
        self.assertEqual([event['event'] for event in self.events()], ['admin_query'])

    def test_query_rejects_prefix_only_and_ambiguous_source_without_disclosure(self):
        self.ok('ensure')
        mapping_path = self.deploy / 'data/runtime/knowledge-map.json'
        location = load(mapping_path)['documents'][0]['location']
        self.prepare_query([location + '.prefix-only-private'])
        result = self.call('query-all')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('prefix-only-private', result.stdout + result.stderr)

        mapping = load(mapping_path)
        mapping['documents'].append({**mapping['documents'][0], 'library_id': LIBRARY_TWO,
            'library_name': '重复映射不应展示', 'document_id': DOCUMENT_TWO})
        save(mapping_path, mapping)
        materials = load(self.deploy / 'config/materials-applied.json')
        materials['knowledge']['map_sha256'] = sha(mapping_path)
        save(self.deploy / 'config/materials-applied.json', materials)
        self.prepare_query([location])
        result = self.call('query-all')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('重复映射不应展示', result.stdout + result.stderr)

    def test_query_rejects_symlink_and_hardlink_map_before_admin_chain(self):
        self.ok('ensure')
        mapping_path = self.deploy / 'data/runtime/knowledge-map.json'
        backup = self.fixture / 'map-backup.json'
        self.prepare_query([])
        os.replace(mapping_path, backup)
        mapping_path.symlink_to(backup)
        write(self.fixture / 'events.jsonl', '')
        result = self.call('query-all')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(event['event'] == 'admin_query' for event in self.events()))
        mapping_path.unlink()
        os.replace(backup, mapping_path)
        os.link(mapping_path, backup)
        write(self.fixture / 'events.jsonl', '')
        result = self.call('query-all')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(event['event'] == 'admin_query' for event in self.events()))

    def test_query_rejects_concurrent_map_change_and_redacts_admin_failure(self):
        self.ok('ensure')
        location = load(self.deploy / 'data/runtime/knowledge-map.json')['documents'][0]['location']
        self.prepare_query([location])
        self.set_control(query_mutate_map=True)
        result = self.call('query-all')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('并发替换后的库', result.stdout + result.stderr)

        # 恢复一致代次后单独验证底层失败的原始 JSON 不会透传。
        mapping = load(self.deploy / 'data/runtime/knowledge-map.json')
        materials = load(self.deploy / 'config/materials-applied.json')
        materials['knowledge']['map_sha256'] = sha(self.deploy / 'data/runtime/knowledge-map.json')
        save(self.deploy / 'config/materials-applied.json', materials)
        self.set_control(query_mutate_map=False, query_failure=True)
        result = self.call('query-all')
        self.assertNotEqual(result.returncode, 0)
        combined = result.stdout + result.stderr
        self.assertNotIn('fixture-query-secret-never-print', combined)
        self.assertNotIn('fixture-query-token-never-print', combined)

    def test_same_profile_rerun_does_not_restart_or_reindex(self):
        self.ok('ensure')
        before = self.baseline()
        backup_names = [path.name for path in self.backups()]
        write(self.fixture / 'events.jsonl', '')
        self.ok('ensure')
        self.assertEqual(self.baseline(), before)
        self.assertEqual([path.name for path in self.backups()], backup_names)
        self.assertEqual(load(self.control)['syncs'], 1)
        self.assertFalse({'stop', 'up', 'configure', 'forced_sync', 'python_backup_before'} &
                         {event['event'] for event in self.events()})
        self.assert_protected()

    def test_outer_maintenance_lock_is_reentrant_across_child_bash(self):
        self.ok('outer-ensure')
        self.assertEqual(load(self.deploy / PROFILE)['state'], 'applied')
        self.assertEqual(load(self.control)['syncs'], 1)
        self.assert_protected()

    def test_other_maintenance_owner_refuses_without_mutation(self):
        before = self.baseline()
        with (self.deploy / 'tmp/maintenance.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.call('ensure')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('另一个安装、更新、备份或恢复任务正在运行', result.stderr)
        self.assertEqual(self.baseline(), before)
        self.assertEqual(self.events(), [])
        self.assert_protected()

    def test_four_gib_preserves_legacy_model_but_builds_first_binding(self):
        self.set_control(memory_kib=4 * 1024 * 1024)
        self.ok('capture-start')
        self.assertEqual(self.env_value('KNOWLEDGE_EMBEDDING_MODEL'), MINI)
        self.assertEqual(load(self.state)['model'], MINI)
        self.ok('ensure')
        self.assertEqual(load(self.deploy / PROFILE)['profile']['model'], MINI)
        self.assertEqual(load(self.deploy / PROFILE)['profile']['chunk_size'], 1000)
        self.assertEqual(load(self.control)['syncs'], 1)
        self.assert_hashes()
        self.assert_protected()

    def test_capture_precedes_new_compose_override_for_explicit_model(self):
        self.set_state(model=NOMIC, explicit_model=True)
        write(self.deploy / 'data/anythingllm/.env', 'EMBEDDING_MODEL_PREF=' + NOMIC + '\n')
        # 对照桩真实模拟新 Compose 缺 active 时的旧默认覆盖，证明本测试可检测顺序颠倒。
        self.ok('start-without-capture')
        self.assertEqual(load(self.state)['model'], MINI)
        self.set_state(model=NOMIC, explicit_model=True)
        write(self.fixture / 'events.jsonl', '')
        self.ok('capture-start')
        self.assertEqual(self.env_value('KNOWLEDGE_ACTIVE_EMBEDDING_MODEL'), NOMIC)
        self.assertEqual(self.env_value('KNOWLEDGE_EMBEDDING_MODEL'), NOMIC)
        self.assertEqual(load(self.state)['model'], NOMIC)
        names = [event['event'] for event in self.events()]
        self.assertLess(names.index('observe'), names.index('up'))
        self.assert_protected()

    def test_capture_persistent_explicit_model_when_old_container_unavailable(self):
        self.set_control(observe_unavailable=True)
        self.set_state(model=NOMIC, explicit_model=True)
        write(self.deploy / 'data/anythingllm/.env', 'EMBEDDING_MODEL_PREF=' + NOMIC + '\n')
        self.ok('capture-start')
        self.assertEqual(self.env_value('KNOWLEDGE_ACTIVE_EMBEDDING_MODEL'), NOMIC)
        self.assertEqual(self.env_value('KNOWLEDGE_EMBEDDING_MODEL'), NOMIC)
        self.set_control(observe_unavailable=False)
        self.ok('ensure')
        self.assertEqual(load(self.deploy / PROFILE)['profile']['model'], NOMIC)
        self.assert_protected()

    def test_capture_fills_missing_desired_without_observing_or_switching(self):
        with (self.deploy / '.env').open('a') as stream:
            stream.write('KNOWLEDGE_ACTIVE_EMBEDDING_MODEL=' + NOMIC + '\n')
        self.set_control(observe_unavailable=True)
        self.ok('capture')
        self.assertEqual(self.env_value('KNOWLEDGE_EMBEDDING_MODEL'), NOMIC)
        self.assertEqual(self.events(), [])
        self.assert_protected()

    def test_install_and_update_capture_before_first_new_compose_up(self):
        install = (SOURCE / 'install.sh').read_text()
        segment = install[install.rindex('if (( SKIP_START == 0 )); then'):]
        capture = segment.index('knowledge-profile.sh" --deploy-dir "$DEPLOY_DIR" capture')
        start = segment.index('docker_compose "$DEPLOY_DIR" up -d --remove-orphans')
        self.assertLess(capture, start)
        update = (SOURCE / 'update.sh').read_text()
        capture = update.index('knowledge-profile.sh" --deploy-dir "$DEPLOY_DIR" capture')
        start = re.search(r'^  docker_compose .*\bup -d --remove-orphans', update, re.M)
        self.assertIsNotNone(start)
        self.assertLess(capture, start.start())
        compose = (SOURCE / 'docker-compose.yml').read_text()
        self.assertIn('EMBEDDING_MODEL_PREF: ${KNOWLEDGE_ACTIVE_EMBEDDING_MODEL:-' + MINI + '}', compose)

    def test_interrupted_applying_reentry_restores_then_migrates_without_rewinding_jobs(self):
        self.set_control(concurrent=True)
        self.environment['KPI_INTERRUPT_SYNC'] = '1'
        result = self.call('ensure')
        self.assertEqual(result.returncode, 143)
        self.assertEqual(load(self.deploy / PROFILE)['state'], 'applying')
        self.assertEqual(load(self.deploy / 'config/materials-applied.json')['state'], 'applying')
        pointer = load(self.deploy / 'data/runtime/knowledge-migration.json')
        self.assertTrue((Path(pointer['backup']) / 'complete.json').is_file())
        self.assert_protected(concurrent=True)
        self.environment.pop('KPI_INTERRUPT_SYNC')
        self.set_control(concurrent=False)
        write(self.fixture / 'events.jsonl', '')
        self.ok('ensure')
        names = [event['event'] for event in self.events()]
        self.assertLess(names.index('python_restore_after'), names.index('python_plan_before'))
        self.assertEqual(load(self.deploy / PROFILE)['state'], 'applied')
        self.assertFalse((self.deploy / 'data/runtime/knowledge-migration.json').exists())
        self.assert_protected(concurrent=True)
        self.assert_hashes()

    def check_verified_projection_damage(self, remove):
        self.set_control(concurrent=True)
        self.environment['KPI_INTERRUPT_SYNC'] = '1'
        self.assertEqual(self.call('ensure').returncode, 143)
        self.environment.pop('KPI_INTERRUPT_SYNC')
        pointer = load(self.deploy / 'data/runtime/knowledge-migration.json')
        preserved = Path(pointer['backup']) / 'metadata/config/materials-applied.json'
        if remove:
            preserved.unlink()
        else:
            value = load(preserved)
            value['configuration']['runtime']['enabled'] = False
            save(preserved, value)
        applying = self.baseline()
        result = self.call('restore')
        self.assertNotEqual(result.returncode, 0)
        # complete 绑定的资料原件损坏必须整体拒绝，不能先交换组件再发现问题。
        self.assertEqual(self.baseline(), applying)
        self.assertTrue((self.deploy / 'data/runtime/knowledge-migration.json').exists())
        self.assertEqual(load(self.deploy / PROFILE)['state'], 'applying')
        self.assert_protected(concurrent=True)

    def test_restore_changed_verified_projection_rejects_before_component_swap(self):
        self.check_verified_projection_damage(remove=False)

    def test_restore_missing_verified_projection_rejects_before_component_swap(self):
        self.check_verified_projection_damage(remove=True)

    def test_configure_failure_restores_complete_old_generation(self):
        before = self.baseline()
        self.set_control(fault='configure')
        self.assertNotEqual(self.call('ensure').returncode, 0)
        self.assert_restored(before)

    def test_sync_failure_preserves_concurrent_human_jobs_and_owned(self):
        before = self.baseline()
        self.set_control(fault='sync', concurrent=True)
        self.assertNotEqual(self.call('ensure').returncode, 0)
        self.assert_restored(before, concurrent=True)

    def test_commit_observation_mismatch_restores_component_and_metadata(self):
        before = self.baseline()
        self.set_control(fault='commit', concurrent=True)
        self.assertNotEqual(self.call('ensure').returncode, 0)
        failures = [event for event in self.events() if event['event'] == 'python_commit_after']
        self.assertEqual(len(failures), 1)
        self.assertNotEqual(failures[0]['code'], 0)
        self.assert_restored(before, concurrent=True)

    def test_final_readback_failure_restores_settings_lexical_and_projection_hashes(self):
        before = self.baseline()
        self.set_control(fault='readback', concurrent=True)
        self.assertNotEqual(self.call('ensure').returncode, 0)
        self.assertTrue(any(event['event'] == 'python_commit_after' and event['code'] == 0 for event in self.events()))
        self.assert_restored(before, concurrent=True)

    def test_restored_failure_can_retry_then_becomes_idempotent(self):
        self.set_control(fault='sync', concurrent=True)
        self.assertNotEqual(self.call('ensure').returncode, 0)
        self.set_control(fault='', concurrent=False)
        self.ok('ensure')
        self.assertEqual(load(self.deploy / PROFILE)['state'], 'applied')
        self.assert_protected(concurrent=True)
        count = len(self.backups())
        self.ok('ensure')
        self.assertEqual(len(self.backups()), count)
        self.assertEqual(load(self.control)['syncs'], 2)
        self.assert_protected(concurrent=True)

    def test_backup_failure_does_not_publish_applying_or_stop_old_service(self):
        os.link(self.deploy / 'data/anythingllm/anythingllm.db', self.deploy / 'data/anythingllm/unsafe-hardlink')
        before = self.baseline()
        self.assertNotEqual(self.call('ensure').returncode, 0)
        self.assertEqual(self.baseline(), before)
        self.assertTrue(load(self.fixture / 'running.json'))
        self.assertFalse((self.deploy / 'data/runtime/knowledge-migration.json').exists())
        self.assertFalse((self.deploy / PROFILE).exists())
        self.assertFalse(any(event['event'] in ('configure', 'forced_sync', 'python_activate_before') for event in self.events()))
        self.assert_protected()

    def test_workspace_settings_invalid_readback_is_atomic_and_keeps_old_value(self):
        original = (self.deploy / SETTINGS).read_bytes()
        for case in ('http', 'wrong_slug', 'invalid_temp', 'string_temp', 'boolean_temp', 'multiple', 'schema', 'malformed'):
            with self.subTest(case=case):
                self.set_control(api_case=case)
                self.assertNotEqual(self.call('settings').returncode, 0)
                self.assertEqual((self.deploy / SETTINGS).read_bytes(), original)
                self.assertEqual(list((self.deploy / 'data/runtime').glob('knowledge-settings.json.tmp.*')), [])
                self.assertEqual(list((self.deploy / 'tmp').glob('workspace-settings.*')), [])
        self.assert_protected()

    def test_workspace_settings_zero_null_and_object_keep_official_semantics(self):
        self.set_state(temperature=0)
        self.set_control(api_case='object')
        self.ok('settings')
        self.assertEqual(load(self.deploy / SETTINGS)['temperature'], 0)
        self.set_state(temperature=None)
        self.ok('settings')
        self.assertEqual(load(self.deploy / SETTINGS)['temperature'], 0.7)
        info = (self.deploy / SETTINGS).stat()
        self.assertEqual(stat.S_IMODE(info.st_mode), 0o640)
        if os.geteuid() == 0:
            self.assertEqual((info.st_uid, info.st_gid), (0, 1000))
        self.assert_protected()

    def test_workspace_settings_atomic_reader_and_materials_projection_binding(self):
        self.set_state(temperature=0.125)
        self.set_control(clock=2000)
        errors, reads = [], []
        stop = threading.Event()
        def reader():
            while not stop.is_set():
                try:
                    value = load(self.deploy / SETTINGS)
                    if value['temperature'] not in (0.7, 0.125): errors.append('non-atomic-value')
                    if len(reads) < 1000: reads.append(value['temperature'])
                except (OSError, ValueError, KeyError):
                    errors.append('missing-or-partial-json')
                time.sleep(0.001)
        thread = threading.Thread(target=reader, daemon=True)
        thread.start()
        try:
            self.ok('settings-repeat')
        finally:
            stop.set()
            thread.join(timeout=2)
        self.assertEqual(errors, [])
        self.assertIn(0.125, reads)
        old = load(self.deploy / 'config/materials-applied.json')['knowledge']['settings_sha256']
        self.ok('prepare')
        new = load(self.deploy / 'tmp/candidate/materials-applied.json')['knowledge']['settings_sha256']
        self.assertNotEqual(old, new)
        self.assertEqual(new, sha(self.deploy / SETTINGS))
        self.assertEqual(list((self.deploy / 'data/runtime').glob('knowledge-settings.json.tmp.*')), [])
        self.assert_protected()


class Transcript:
    def __init__(self, file):
        self.file = file
    def write(self, text):
        sys.stderr.write(text)
        self.file.write(text)
        self.file.flush()
    def flush(self):
        sys.stderr.flush()
        self.file.flush()


transcript = WORK / 'transcript.log'
with transcript.open('w', encoding='utf-8') as stream:
    selected = sys.argv[2:]
    if selected and any(not name.startswith('test_') or not hasattr(Integration, name) for name in selected):
        raise SystemExit('测试方法选择无效')
    suite = unittest.TestSuite(Integration(name) for name in selected) if selected else unittest.defaultTestLoader.loadTestsFromTestCase(Integration)
    result = unittest.TextTestRunner(verbosity=2, stream=Transcript(stream)).run(suite)
transcript.chmod(0o600)
failed = sorted({case.id().split('.')[-1].split(' ')[0] for case, _ in result.failures + result.errors})
receipt = {
    'layer': 'ORCHESTRATION/COMPONENT-STUB', 'tests_run': result.testsRun,
    'selected_methods': selected or 'all',
    'passed': result.testsRun - len(failed), 'failed_methods': len(failed), 'failures': failed,
    'failure_count': len(result.failures), 'error_count': len(result.errors), 'skipped': len(result.skipped),
    'target_connections': 0, 'real_docker_calls': 0, 'real_embedding_calls': 0, 'real_model_calls': 0,
    'production_files_modified_by_test': False,
    'production_inputs_stable': all(sha(ROOT / name) == sha(SOURCE / name) for name in INPUTS),
    'production_source_sha256': {name: sha(SOURCE / name) for name in INPUTS},
    'test_input_sha256': sha(WORK / 'test-input.sh'),
    'actual_install_update_execution': False,
    'install_update_capture_order': 'STATIC-CONTRACT',
    'external_boundaries': ['docker-compose', 'component-observe-configure', 'workspace-api', 'vector-upload-embedding', 'memory-clock'],
}
save(WORK / 'result.json', receipt)
print(json.dumps(receipt, ensure_ascii=False, sort_keys=True))
print('合成证据目录：' + str(WORK.relative_to(ROOT)))
raise SystemExit(0 if result.wasSuccessful() else 1)
PY
