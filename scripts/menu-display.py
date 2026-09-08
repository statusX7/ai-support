#!/usr/bin/env python3
"""中文终端展示层；只解释结果，不修改业务状态或机器接口。"""

import json
import contextlib
import math
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


LABELS = {
    "enabled": "启用状态", "name": "名称", "title": "标题", "text": "正文", "message": "说明",
    "base_url": "接口地址", "model": "模型", "api_mode": "请求协议", "key_status": "密钥状态",
    "context_window": "上下文上限", "max_output_tokens": "最大输出长度", "custom_header_names": "自定义请求头",
    "resume_after_seconds": "自动恢复秒数", "resume_at": "恢复时间", "pause_reason": "接管原因",
    "confirm_label": "确认按钮", "cancel_label": "取消按钮", "confirm_message": "接管提示",
    "keywords": "关键词", "exclude_keywords": "排除词", "match_mode": "匹配方式", "action": "动作",
    "priority": "优先级", "cooldown_seconds": "冷却秒数", "offer_ttl_seconds": "按钮有效秒数",
    "trigger": "触发方式", "auto_open": "自动展开聊天框", "show_menu": "欢迎附带菜单",
    "ai_replied": "已回复标签", "knowledge_miss": "未命中标签", "low_confidence": "低置信度标签",
    "human_required": "人工标签", "retention_days": "保留天数", "max_size_mib": "单文件容量（MiB）",
    "max_files": "总份数（含当前文件）", "timer_enabled": "自动清理", "status": "状态", "state": "状态",
    "source_valid": "原文校验", "applied_valid": "有效资料校验", "pending": "待处理", "changed": "未应用变更",
    "source_changed": "原文有修改", "applied": "资料已应用", "verified": "实际回读通过", "valid": "校验通过",
    "total_questions": "总问题", "ai_replies": "AI 回复", "knowledge_hits": "知识命中", "knowledge_misses": "知识未命中",
    "knowledge_unknown": "检索结果未知", "observable_queries": "可观察检索问题", "hit_rate": "命中率（%）",
    "handoffs": "转人工", "positive_feedback": "历史好评", "negative_feedback": "历史差评",
    "positive_rate": "历史有效好评率（%）", "feedback_coverage": "历史反馈覆盖率（%）",
    "answer": "测试回答", "textResponse": "测试回答", "question": "脱敏问题", "count": "数量",
    "documents": "文档", "libraries": "知识库", "sources": "来源", "files": "文件", "entries": "接口",
    "rules": "规则", "menus": "菜单树", "welcome": "欢迎语", "handoff": "人工恢复", "tags": "标签",
    "feedback": "历史评价设置", "runtime": "客服总开关", "configuration": "配置", "provider": "接口",
    "path": "路径", "prompt_path": "提示词路径", "catalog_path": "知识目录路径", "applied_path": "有效资料路径",
    "source_paths": "知识原文路径", "paths": "资料路径", "filename": "文件名", "size": "大小", "bytes": "字节",
    "indexed": "已索引", "indexed_count": "已索引数量", "document_count": "文档数量", "pending_count": "待处理数量",
    "website_id": "网站标识", "token_tier": "令牌类型", "hook_mode": "回调类型", "token_identifier_status": "凭据标识状态",
    "token_key_status": "凭据密钥状态", "webhook_secret_status": "回调密钥状态", "public_url": "公开地址",
    "webhook_url": "回调地址", "webhook": "回调", "conversation": "真实往返", "instructions": "操作说明", "html": "网页接入片段",
    "question_timeout_ms": "问题总期限（毫秒）", "call_timeout_ms": "单次期限（毫秒）",
    "connect_timeout_ms": "连接期限（毫秒）", "max_attempts": "每问题最多调用次数",
    "cooldown_initial_ms": "初始冷却（毫秒）", "cooldown_max_ms": "最长冷却（毫秒）", "pool_cooldown_ms": "全池冷却（毫秒）",
    "policy": "主备策略", "attempt": "本次尝试", "duration_ms": "耗时（毫秒）", "http_status": "上游状态码",
    "at": "时间", "stage": "阶段", "outcome": "结果", "error_class": "错误类别", "code": "退出码",
    "expired_files": "到期文件", "expired_bytes": "到期字节", "removed_files": "已删除文件", "removed_bytes": "已释放字节",
    "capabilities": "已确认能力", "chat_completions": "聊天接口", "responses": "响应接口", "vision": "图片理解",
    "readback": "运行状态回读", "draft": "仅保存草稿", "missing_keys": "待填写密钥的接口",
    "pending_credentials": "待填写凭据", "summary": "摘要", "suggestion": "处理建议",
    "last_cleanup": "最近自动清理", "managed_bytes": "受管日志占用（字节）", "timer": "自动清理调度",
    "systemd_available": "系统调度可用", "active": "正在运行", "owned": "属于本实例", "usage": "占用情况",
    "phase": "阶段", "service": "组件", "exit_code": "退出码", "version": "程序版本", "checked_at": "检测时间",
    "negative_questions": "近期历史差评", "frequent_failures": "高频失败问题", "notes": "说明", "note": "说明",
    "imported": "已导入", "exported": "已导出", "preview": "仅预览，未应用", "restored": "已恢复",
    "prompt": "提示词", "knowledge": "知识库", "logging": "日志策略", "reason": "原因",
    "projection": "有效资料路径", "knowledge_catalog": "知识目录路径", "projection_valid": "有效资料校验",
    "mode": "工作模式", "last_sync": "上次同步", "source": "来源", "manifest": "包内说明",
    "results": "结果", "library_name": "来源库", "text": "正文", "pageContent": "检索正文", "score": "检索得分",
    "crisp_api": "Crisp 认证", "public_webhook": "公网回调", "hook_observed": "已观察到当前回调",
    "conversation_observed": "已观察到真实回复往返", "scope": "检查范围", "resumed": "已恢复自动客服",
    "cleared_files": "已清理统计文件数", "remaining_seconds": "剩余恢复秒数", "last_human_at": "最近真人接管时间",
    "provider_pool": "主备接口资料", "current_valid": "当前有效接口校验",
    "business_applied": "业务资料已应用", "provider_pool_applied": "主备接口池已应用", "missing_credentials": "待补全凭据的接口",
    "rag_context": "知识上下文配置", "configuration_state": "配置应用状态",
}
VALUES = {
    True: "是", False: "否", None: "无", "chat_completions": "聊天接口", "responses": "响应接口",
    "first_message": "首条访客消息", "widget_load": "页面加载", "chat_open": "访客打开聊天框",
    "show_handoff_offer": "人工确认按钮", "reply": "固定回复", "prompt": "知识问答", "menu": "多级菜单",
    "contains": "包含匹配", "exact": "完全匹配", "primary": "主接口", "backup": "备用接口",
    "configured": "已配置", "present": "已配置", "missing": "未配置", "not-configured": "未配置",
    "PASS": "通过", "WARN": "需关注", "FAIL": "故障", "SKIP": "未执行", "ready": "已就绪",
    "local-ready": "本地就绪，外部待验证", "pending": "等待处理", "applied": "已生效", "applying": "应用中，暂停自动回复",
    "human": "人工接管", "ai": "自动客服", "website": "网站凭据", "plugin": "插件凭据",
    "answer": "正文回答", "vision": "图片理解", "success": "成功", "failed": "失败", "cancelled": "已取消",
    "authentication_failed": "鉴权失败，请检查地址与密钥", "temporarily_unavailable": "接口暂时不可用",
    "models_unavailable": "服务商未提供可用模型列表", "timeout": "请求超时", "rate_limited": "请求频率受限",
    "readback_failed": "实际回读未通过", "pool_capacity": "接口数量已达到上限", "primary_required": "请先设置其他主接口",
    "invalid_order": "备用顺序无效", "invalid_input": "本次输入无效", "invalid_policy": "策略超出允许范围",
    "revision_conflict": "其他操作已修改接口池，请刷新后重试", "entry_not_found": "所选接口不存在，请刷新列表",
    "human_reply": "真人公开回复", "human_message": "真人公开回复", "handoff_button": "点击人工确认按钮",
    "manual": "管理员操作", "scheduled": "自动调度", "complete": "已完成", "start": "开始", "end": "结束",
    "success": "成功", "failure": "失败", "fallback": "尝试下一接口", "cooldown": "临时冷却",
    "none": "不保存", "unknown": "尚未确认", "checked": "已检查", "unavailable": "暂不可用",
    "official_crisp": "官方 Crisp", "protocol_or_custom_endpoint": "自定义或协议环境，不代表官方真实往返",
    "local": "本地", "full": "完整", "default": "默认只读", "invalid": "无效",
    "quota_exhausted": "额度已用尽", "connection_failed": "连接失败", "upstream_timeout": "上游超时",
    "invalid_response": "上游返回格式无效", "model_not_found": "模型不存在", "safety_refusal": "模型安全拒绝",
    "question_cancelled": "控制状态变化，问题已取消", "question_budget_exhausted": "本题调用预算已用尽",
    "vision_unsupported": "此模型暂不支持图片", "upstream_unavailable": "上游暂不可用", "model_unavailable": "模型暂不可用",
    "rag_context_apply_failed": "知识上下文配置未能应用，请检查本地组件；已尝试恢复上一份配置",
    "rag_context_restore_failed": "知识上下文恢复未完成，自动推理保持保护状态；从菜单 3 → 10 → 12 恢复",
    "configuration_applying": "配置正在应用，请等待当前操作结束，不要同时修改",
    "context_preparation_incomplete": "知识组件没有保留完整提示词，已阻止不完整请求；请核对接口上下文预算",
    "unchanged": "保持原值，无需重建", "deferred": "将在安装阶段启动组件后验证",
}
TECHNICAL = re.compile(r'\b(?:schema_version|applied_revision|revision|Traceback|traceback)\b|(?:kb_|rule_|menu_|p_)[a-f0-9]{8,}|session-[a-f0-9]{64}|\b[0-9a-f]{64}\b')


def safe(value):
    text = str(value)
    text = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', text)
    text = ''.join(c for c in text if c in '\n\t' or ord(c) >= 32 and not 127 <= ord(c) < 160)
    text = re.sub(r'(?i)([?&](?:key|token|secret)=)[^\s&#]+', r'\1[已隐藏]', text)
    text = re.sub(r'(?i)\b(?:Bearer|Basic)\s+[^\s,;]+', '[认证已隐藏]', text)
    return TECHNICAL.sub('（已隐藏）', text)


def scalar(value):
    if isinstance(value, (dict, list)):
        return "（见下方）"
    if value is True: return "是"
    if value is False: return "否"
    if value is None: return "无"
    if isinstance(value, str) and value in VALUES:
        return VALUES[value]
    return safe(value)


def objects(raw):
    values, lines = [], []
    decoder = json.JSONDecoder()
    while raw.strip():
        raw = raw.lstrip()
        if raw[:1] in '[{':
            try:
                value, end = decoder.raw_decode(raw)
                values.append(value); raw = raw[end:]; continue
            except ValueError:
                pass
        line, _, raw = raw.partition('\n')
        lines.append(line)
    return values, lines


def provider_snapshot(arguments):
    source, status_file, status_code, recent_file, recent_code = arguments
    pool = json.loads(Path(source).read_text(encoding='utf-8'))
    if not isinstance(pool, dict) or pool.get('ok') is not True or not isinstance(pool.get('entries'), list):
        raise ValueError('接口列表无效')
    revision = pool.get('revision')
    def observed(file, code, field):
        reason = '读取超过 8 秒，已停止等待' if int(code) in (124, 137) else '本地适配器暂时不可用'
        try:
            result = json.loads(Path(file).read_text(encoding='utf-8'))
        except (OSError, ValueError):
            return None, reason if int(code) else '适配器结果格式无效'
        if int(code) or not isinstance(result, dict) or result.get('ok') is not True:
            error = result.get('error', {}) if isinstance(result, dict) else {}
            return None, VALUES.get(error.get('code'), reason) if isinstance(error, dict) else reason
        if not isinstance(result.get(field), list):
            return None, '适配器结果格式无效'
        if field == 'entries' and result.get('configuration_state') == 'applying':
            return None, '接口配置尚未完成应用，自动推理保持保护状态；请核对当前操作或从菜单 3 → 10 → 12 恢复'
        if field == 'entries' and result.get('revision') != revision or field == 'records' and result.get('revision', revision) != revision:
            return None, '读取期间接口配置已变化，请重新打开列表'
        return result, ''
    status, status_reason = observed(status_file, status_code, 'entries')
    recent, recent_reason = observed(recent_file, recent_code, 'records')
    health = {}
    keys = ('id', 'health', 'cooldown_until', 'last_error', 'vision_health', 'vision_cooldown_until', 'vision_last_error')
    if status:
        for item in status['entries']:
            if isinstance(item, dict) and isinstance(item.get('id'), str):
                health[item['id']] = {key: item[key] for key in keys if key in item}
    successes = {}
    if recent:
        for item in recent['records']:
            if not isinstance(item, dict) or item.get('pool_revision') != revision or item.get('outcome') != 'success' or item.get('stage') not in ('vision', 'answer'):
                continue
            identifier, at = item.get('entry_id'), item.get('at')
            if not isinstance(identifier, str) or type(at) not in (int, float) or not math.isfinite(at) or at <= 0:
                continue
            if at > successes.get(identifier, {}).get('at', 0):
                successes[identifier] = {'at': at, 'stage': item['stage']}
    pool['provider_view'] = {'checked_at': int(time.time() * 1000), 'status_ok': status is not None,
                             'status_reason': status_reason, 'recent_reason': recent_reason, 'health': health, 'successes': successes,
                             'pool_cooldown_until': status.get('pool_cooldown_until', 0) if status else 0}
    return pool


def provider_health(view, entry, vision=False):
    if not entry.get('enabled'):
        return '已停用', 0, '', False
    if vision and not entry.get('capabilities', {}).get('vision'):
        return '未启用图片能力', 0, '', False
    if not entry.get('capabilities', {}).get(entry.get('api_mode')):
        return '当前协议能力未确认', 0, '', False
    observed = view['health'].get(entry.get('id'))
    if not view['status_ok'] or not observed:
        return '未检测', 0, view['status_reason'] or '适配器未返回此接口状态', False
    prefix = 'vision_' if vision else ''
    health = observed.get(prefix + 'health')
    until = observed.get(prefix + 'cooldown_until')
    if health not in ('healthy', 'unknown', 'cooling', 'half_open', 'disabled') or type(until) not in (int, float) or not math.isfinite(until) or until < 0:
        return '未检测', 0, '适配器健康或冷却数据无效', False
    remaining = math.ceil(max(0, until - view['checked_at']) / 1000)
    reason = VALUES.get(observed.get(prefix + 'last_error'), '已记录接口故障') if observed.get(prefix + 'last_error') else ''
    if remaining:
        return '冷却中', remaining, reason, False
    if health == 'half_open':
        return '恢复验证中', 0, reason, False
    if health == 'disabled':
        return '已停用', 0, reason, False
    if health == 'healthy':
        return '健康', 0, '', True
    return '尚未确认', 0, reason, True


def provider_time(milliseconds):
    try:
        return datetime.fromtimestamp(milliseconds / 1000, timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')
    except (ValueError, OverflowError, OSError):
        return '时间未能确认'


def provider_entry_status(view, entry):
    for vision, label in ((False, '文本健康'), (True, '视觉健康')):
        health, remaining, reason, _ = provider_health(view, entry, vision)
        cooling = '未检测' if health == '未检测' else f'{remaining} 秒'
        print('  ' + label + '：' + health + '；冷却剩余：' + cooling + ('；原因：' + safe(reason) if reason else ''))
    success = view['successes'].get(entry.get('id'))
    if view['recent_reason']:
        print('  当前配置下最近成功：未检测；原因：' + safe(view['recent_reason']))
    elif success:
        print('  当前配置下最近成功：' + provider_time(success['at']) + '（' + scalar(success['stage']) + '）')
    else:
        print('  当前配置下暂无可核对成功记录。')


def provider_next_candidates(view, entries):
    until = view.get('pool_cooldown_until', 0)
    cooling = type(until) in (int, float) and math.isfinite(until) and until > view['checked_at']
    for vision, label in ((False, '文本'), (True, '视觉')):
        selected = next((entry for entry in entries if provider_health(view, entry, vision)[3]), None)
        if not view['status_ok']:
            result = '未检测，暂无法确认'
        elif cooling:
            result = '接口池保护中，剩余 ' + str(math.ceil((until-view['checked_at'])/1000)) + ' 秒'
        elif selected:
            result = safe(selected.get('name') or '未命名接口') + '（' + provider_health(view, selected, vision)[0] + '）'
        else:
            result = '当前无可尝试候选'
        print('下一请求优先候选（' + label + '）：' + result)
    print('候选按当前顺序、启用状态、能力和冷却推算；实际请求还受上下文与本题共享预算约束。')


def detail(value, indent=''):
    if isinstance(value, list):
        if not value:
            print(indent + '暂无记录。'); return
        for number, item in enumerate(value, 1):
            print(f'{indent}{number}. ' + (safe(item.get('name') or item.get('title') or '记录') if isinstance(item, dict) else scalar(item)))
            if isinstance(item, dict): detail(item, indent + '  ')
        return
    if not isinstance(value, dict):
        print(indent + scalar(value)); return
    for key, item in value.items():
        if key not in LABELS or key in ('name', 'title') and indent:
            continue
        if key == 'website_id':
            print(indent + '网站标识：' + ('已配置（默认隐藏）' if item else '未配置'))
        elif key == 'resume_at' and item is None:
            print(indent + '恢复时间：不自动恢复')
        elif key == 'action' and isinstance(item, str) and item not in VALUES and not re.search('[\u4e00-\u9fff]', item):
            print(indent + '动作：已记录维护事件')
        elif key == 'menus' and isinstance(item, dict):
            for node in item.values():
                print(indent + '菜单：' + safe(node.get('title', '未命名')))
                for number, option in node.get('options', {}).items():
                    print(indent + '  ' + safe(number) + '. ' + safe(option.get('label', '选项')) + ' — ' + scalar(option.get('action', {}).get('type')))
        elif isinstance(item, (dict, list)):
            print(indent + LABELS[key] + '：'); detail(item, indent + '  ')
        else:
            print(indent + LABELS[key] + '：' + scalar(item))


def render(kind, value):
    if isinstance(value, dict) and value.get('draft') is True and value.get('business_applied') is True:
        print('业务资料已应用，但主备接口仅为待补凭据草稿；原有效接口池继续工作。请到菜单 3 → 10 → 11 补全并明确应用。')
        detail({key: value[key] for key in ('missing_credentials', 'message') if key in value})
        return
    if kind in ('pool', 'pool-status') and isinstance(value, dict):
        view = value.get('provider_view') if kind == 'pool-status' else None
        if view:
            print('只读状态回读：' + provider_time(view['checked_at']) + '；本次未调用模型。')
        is_draft = value.get('draft') is True or value.get('applied') is False
        if is_draft:
            print('仅保存草稿，尚未应用；原有效主备接口继续工作。')
            detail({key: value[key] for key in ('missing_keys', 'pending_credentials', 'message') if key in value})
        entries = value.get('entries', [])
        if not isinstance(entries, list):
            print('草稿接口数量：' + scalar(entries)); return
        print(f'接口共 {len(entries)} 个；备用 {max(0, len(entries)-1)} 个。')
        if len(entries) == 1 and not is_draft: print('当前是合法的单接口配置；无需额外配置备用。')
        if 'rag_context' in value:
            detail({'rag_context': value['rag_context']})
        for number, entry in enumerate(entries, 1):
            role = '主接口' if entry.get('id') == value.get('primary_id') or entry.get('role') == 'primary' else '备用接口'
            print(f'{number}. {safe(entry.get("name") or "未命名接口")}（{role}，' + ('启用' if entry.get('enabled') else '停用') + '）')
            detail({key: entry[key] for key in ('base_url', 'model', 'api_mode', 'key_status', 'custom_header_names') if key in entry}, '  ')
            if view:
                provider_entry_status(view, entry)
        if view:
            provider_next_candidates(view, entries)
        return
    if kind == 'welcome' and isinstance(value, dict):
        welcome = value.get('welcome', value.get('configuration', {}).get('menu', {}).get('welcome', {}))
        print('欢迎语：' + ('已启用' if welcome.get('enabled') is True else '已关闭' if welcome.get('enabled') is False else '未能确认'))
        detail({key: val for key, val in welcome.items() if key != 'enabled'})
        return
    if kind == 'runtime' and isinstance(value, dict):
        print('客服总开关：' + ('已启用' if value.get('enabled') is True else '已停用' if value.get('enabled') is False else '未能确认'))
        return
    if kind == 'records' and isinstance(value, dict):
        names = {}
        if '--names' in sys.argv:
            data = json.loads(Path(sys.argv[sys.argv.index('--names') + 1]).read_text(encoding='utf-8'))
            names = {entry['id']: entry['name'] for entry in data['entries']}
        records = [dict(item, name=names.get(item.get('entry_id'), '历史接口记录')) for item in value.get('records', [])]
        print('近期切换记录（不含问题正文或内部标识）：'); detail(records); return
    if kind == 'sessions' and isinstance(value, dict):
        return render(kind, value.get('sessions', value.get('conversations', [])))
    if kind == 'sessions' and isinstance(value, list):
        value = [item for item in value if item.get('mode') == 'human']
        print(f'当前人工会话：{len(value)} 个。')
        for number, item in enumerate(value, 1):
            print(f'{number}. 会话 {number}；原因：{scalar(item.get("pause_reason"))}；恢复时间：{scalar(item.get("resume_at"))}')
        return
    if kind == 'doctor' and isinstance(value, dict):
        print('自检时间：' + scalar(value.get('checked_at', 'unknown')))
        for item in value.get('results', []):
            print('【' + scalar(item.get('status', 'unknown')) + '】' + safe(item.get('name', '检查项')) + '：' + safe(item.get('summary', '')))
            if item.get('suggestion'): print('  建议：' + safe(item['suggestion']))
        if value.get('fix', {}).get('actions'):
            print('本次安全修复：'); detail(value['fix']['actions'])
        summary = value.get('summary', {})
        print(f'结果：通过 {summary.get("pass", 0)}，需关注 {summary.get("warn", 0)}，故障 {summary.get("fail", 0)}，未执行 {summary.get("skip", 0)}。')
        return
    if kind.startswith('analytics-') and isinstance(value, dict):
        fields = ('total_questions', 'ai_replies', 'knowledge_hits', 'knowledge_misses', 'knowledge_unknown', 'observable_queries', 'handoffs', 'hit_rate') if kind == 'analytics-knowledge' else ('positive_feedback', 'negative_feedback', 'positive_rate', 'feedback_coverage', 'negative_questions', 'frequent_failures')
        detail({key: value[key] for key in fields if key in value})
        if kind == 'analytics-knowledge':
            names = {}
            if len(sys.argv) > 5:
                try:
                    catalog = json.loads(Path(sys.argv[5]).read_text(encoding='utf-8'))
                    names = {item['id']: item['name'] for item in catalog['libraries']}
                except (OSError, ValueError, KeyError, TypeError):
                    print('知识库名称暂不可读；历史来源按序号显示，不改变统计。')
            for number, (identifier, count) in enumerate(value.get('knowledge_libraries', {}).items(), 1):
                print('来源库 ' + safe(names.get(identifier, f'历史知识库 {number}')) + f'：{count} 次命中（同题跨库不增加总问题数）。')
        return
    if kind == 'logs' and isinstance(value, dict):
        if 'policy' in value:
            print('日志维护：' + scalar(value.get('status', 'unknown')) + '；' + safe(value.get('summary', '')))
            print('日志保留策略：'); detail(value['policy'])
            detail({key: value[key] for key in ('timer', 'usage') if key in value})
        else:
            print('日志保留策略：')
            detail(value)
        return
    detail(value)


def human_lines(lines):
    emitted = False
    traceback = False
    for line in lines:
        if not line.strip(): continue
        if 'Traceback' in line: traceback = True
        if traceback:
            if not emitted: print('执行模块发生异常；请在状态与自检中核对，未将异常内容作为成功结果。'); emitted = True
            continue
        if re.search(r'Traceback|File ".*", line|jq:|SyntaxError|JSONDecodeError|^[\s{}\[\]",:]+$|\{\s*"[^"\n]+"\s*:', line):
            if not emitted: print('结果格式异常；请在状态与自检中核对，未将异常内容作为成功结果。'); emitted = True
        elif re.match(r'^\s*"[^"\n]+"\s*:', line):
            if not emitted: print('结果格式异常；请在状态与自检中核对。'); emitted = True
        else:
            print(safe(line))


def main():
    if sys.argv[1:2] == ['--provider-snapshot']:
        print(json.dumps(provider_snapshot(sys.argv[2:]), ensure_ascii=False))
        return 0
    if len(sys.argv) == 3 and sys.argv[1] == '--snapshot-options':
        choices = []
        for line in Path(sys.argv[2]).read_text(encoding='utf-8').splitlines():
            if not line.strip() or line.startswith('快照 ID') or line == '（暂无版本快照）': continue
            match = re.fullmatch(r'([A-Za-z0-9][A-Za-z0-9._-]{0,127})\s+(\S+)\s+(\S+)\s+(.*)', line)
            if not match: raise ValueError('快照列表格式不符')
            identifier, version, created, reason = match.groups()
            explanation = safe(reason) if re.search('[\u4e00-\u9fff]', reason) else '维护快照'
            choices.append({'id': identifier, 'name': f'{safe(version)}；{safe(created)}；{explanation}'})
        print(json.dumps(choices, ensure_ascii=False)); return 0
    if len(sys.argv) == 3 and sys.argv[1] == '--document':
        inside = False
        print('以下为本地操作说明；完整配置字段和代码示例请打开文末文档链接。')
        for line in Path(sys.argv[2]).read_text(encoding='utf-8').splitlines()[:320]:
            if re.match(r'^\s*```', line): inside = not inside; continue
            if not inside: print(safe(line))
        return 0
    if sys.argv[1:] == ['--stream']:
        try:
            for line in sys.stdin:
                values, lines = objects(line)
                human_lines(lines)
                for value in values: render('log-event', value)
                sys.stdout.flush()
        except KeyboardInterrupt:
            return 130
        return 0
    kind, source, errors, code, *flags = sys.argv[1:]
    status = int(code)
    raw = Path(source).read_text(encoding='utf-8', errors='replace')
    stderr = Path(errors).read_text(encoding='utf-8', errors='replace')
    values, lines = objects(raw)
    if '--json' in flags:
        if status and not (len(values) == 1 and isinstance(values[0], dict) and values[0].get('ok') is False):
            print(json.dumps({'ok': False, 'error': {'code': 'operation_failed', 'message': '操作未完成，请运行自检。'}, 'results': values}, ensure_ascii=False))
        elif len(values) == 1:
            print(json.dumps(values[0], ensure_ascii=False))
        else:
            print(json.dumps({'ok': True, 'results': values}, ensure_ascii=False))
        with contextlib.redirect_stdout(sys.stderr):
            human_lines(lines)
            human_lines(stderr.splitlines())
        return 0
    if status:
        print(f'操作未完成（退出码 {status}），不能视为已生效。')
    human_lines(lines)
    for value in values:
        if isinstance(value, dict) and value.get('ok') is False:
            error = value.get('error', {})
            print('原因：' + VALUES.get(error.get('code'), '操作被拒绝，请核对本次输入与自检结果'))
            if error.get('message'): print('说明：' + safe(error['message']))
        else:
            render(kind, value)
    if stderr:
        human_lines(stderr.splitlines())
    if not values and not lines and not stderr and not status:
        print('操作完成。')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, TypeError, KeyError):
        print('结果展示失败；请运行状态与自检，未将异常结果视为成功。', file=sys.stderr)
        raise SystemExit(1)
