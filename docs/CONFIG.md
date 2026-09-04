# 配置说明

## 配置分层

- `.env` 保存部署路径、端口和密钥，仅允许部署账户读取，不得提交到 Git。
- `config/provider.yaml` 保存 Provider 类型、地址、模型和能力检测结果，不保存 API Key。
- `config/prompt.md` 保存客服系统提示词。
- `config/keyword.yaml`、`config/menu.yaml`、`config/handoff.yaml`、`config/tags.yaml` 和 `config/feedback.yaml` 保存业务规则。
- 带 `.example` 后缀的文件是可公开提交的模板，不得填入真实凭据。

## AI Provider

配置入口只要求输入 API Base URL 和 API Key。管理脚本会规范化地址、请求 `/v1/models` 并显示检测到的模型；模型列表请求失败时才提供手动输入或默认模型选项。

管理脚本还会分别探测 `/v1/responses` 与 `/v1/chat/completions`，把可用接口记录到 `config/provider.yaml`。API Key 只写入 `.env` 的 `AI_API_KEY`。

AnythingLLM 使用 `generic-openai` Provider、原生 Embedding 与内置 LanceDB。基础地址应包含 API 的 `/v1` 前缀；脚本会自动避免重复拼接 `/v1`。

上述业务配置使用 JSON 语法书写；JSON 本身是合法 YAML，这使 n8n 无需额外解析依赖即可安全读取。首次安装由对应 `.example` 模板生成实际配置，实际配置被 Git 忽略。修改后应运行健康检查并重新发布工作流。

## AnythingLLM 初始化

首次启动后，在本机访问 AnythingLLM 管理页面，创建名为 `crisp-support` 的工作区，并在“Developer API”中创建独立 API Key。随后通过 `./manage.sh` 保存该 Key。不同 Crisp conversation 使用各自的 `sessionId`，避免会话历史串线。

工作区默认使用 `query` 模式，以知识库为答案边界。若需要允许模型使用通用知识，可把 `.env` 中的 `ANYTHINGLLM_CHAT_MODE` 改为 `chat`，但应同步收紧 Prompt 与转人工规则。

## Crisp

单工作区部署优先使用 Website Token，`CRISP_TOKEN_TIER` 设置为 `website`；多工作区私有插件使用 Plugin Token，并设置为 `plugin`。两种 Token 都只保存在 `.env`。

Website Hook 不提供签名，Webhook 地址必须使用 `https://部署域名/webhook/crisp-webhook?key=随机Secret`，其中 Secret 与 `.env` 的 `CRISP_WEBHOOK_SECRET` 一致。Plugin Hook 应使用不带查询 Secret 的地址，工作流会校验 `X-Crisp-Signature` 和 `X-Crisp-Request-Timestamp`。

至少订阅 `message:send`。若使用 Plugin Hook，还可订阅 `message:received`、`session:set_opened` 和 `session:request:initiated`，分别用于记录人工回复和在聊天窗口打开时发送欢迎语。Website Hook 无法提供 `session:set_opened`，因此欢迎语会在访客首次发言时合并发送。

图片 URL 默认只接受 HTTPS 的 `crisp.chat` 子域名。确需使用其他可信图片主机时，可在 `.env` 的 `CRISP_IMAGE_HOSTS` 中填写逗号分隔的精确主机名。

## 人工接管

`handoff.yaml` 的 `keywords` 是唯一的自动识别入口，默认包含“人工”“人工客服”“转人工”“真人”和“真人客服”。关键词列表完全来自配置，工作流不内置业务主题词。访客命中关键词或明确选择菜单中的人工选项后，工作流先按 `notify_user.enabled` 回复“正在为您转接人工客服，请稍候。”，再按 `disable_ai` 关闭当前 conversation 的 AI，并添加人工标签。

真实 operator 回复也会立即关闭当前 conversation 的 AI。接管期间访客消息仍可进入有限会话历史，但不会触发 AI 回复。`resume_after_seconds` 到期后，AI 会在下一条访客消息恢复；设为 `0` 表示只允许 operator 发送 `resume_keywords` 中的控制词恢复。

知识库未命中、低置信度、图片理解失败和 API 失败不会关闭 AI。相应提示可通过 `no_answer_message`、`low_confidence_message` 和 `failure_message` 修改。

## Conversation 标签

`tags.yaml` 配置项目管理的四类标签，默认值分别是 `ai_resolved`、`knowledge_miss`、`low_confidence` 和 `human_required`。标签值不得包含空格或控制字符；设 `enabled` 为 `false` 可关闭自动标签。

更新标签时，工作流先读取 Crisp conversation 当前 `segments`，保留所有非本项目管理的标签，再替换项目管理标签。读取失败时会跳过更新，避免误清空已有标签。Website Token 或 Plugin Token 必须具备读取和修改 conversation meta 的权限。

## 回答反馈与统计

`feedback.yaml` 控制回答后的“是否解决问题”提示、正负反馈词、致谢消息、有效期与最大文本长度。反馈只在成功生成的知识库或视觉回答后询问；菜单、欢迎语、失败提示和转人工通知不会重复询问。

`data/analytics/events.jsonl` 保存追加式事件。问题数、AI 回复数、命中、未命中和转人工事件不保存消息内容。反馈事件按需求保存 `session`、`question`、`answer` 和 `feedback`，其中 session 使用 HMAC 匿名化，问题和回答会过滤常见 Token、Secret、邮箱和号码并截断。管理员仍应避免把敏感个人信息写入反馈，并按数据保留政策定期清理该文件。

查看统计：

```bash
sudo /opt/crisp-ai/scripts/analytics.sh knowledge
sudo /opt/crisp-ai/scripts/analytics.sh feedback
```

## 版本快照

`.env` 中的 `SNAPSHOT_MIN_FREE_MB` 控制快照完成后必须保留的空间，默认 `1024` MiB。容量预检按待复制数据的两倍加预留空间保守估算，以覆盖临时副本和压缩归档同时存在的阶段。

`SNAPSHOT_RETENTION_COUNT` 控制有效版本快照的最大数量，默认 `10`。设为 `0` 表示不自动清理。自定义值会在重复安装时保留；升级会为旧部署补齐缺失的默认值。

## Prompt

首次安装会从 `config/prompt.md.example` 创建 `config/prompt.md`。可通过管理菜单修改、导入或导出；导入文件必须是普通文件且位于允许的路径中。

## 知识库

支持 Markdown、TXT、PDF 和 DOCX。管理脚本只接受这些扩展名，并拒绝符号链接和路径穿越。AnythingLLM 负责解析、自动分块、向量化、检索和重新索引。
