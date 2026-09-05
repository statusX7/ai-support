# 配置说明

## 配置分层

- `.env` 保存部署路径、端口和密钥，仅允许部署账户读取，不得提交到 Git。
- `config/provider.yaml` 保存 Provider 类型、地址、模型和能力检测结果，不保存 API Key。
- `config/prompt.md` 保存客服系统提示词。
- `config/keyword.yaml`、`config/menu.yaml`、`config/handoff.yaml`、`config/tags.yaml` 和 `config/feedback.yaml` 保存业务规则。
- 带 `.example` 后缀的文件是可公开提交的模板，不得填入真实凭据。
- `tmp/quick-init.json` 仅在十项向导未完成或安装需恢复时存在，权限为 `0600`；配置与本地应用成功落盘后自动删除。

## AI Provider

配置入口只要求输入 API Base URL 和 API Key。脚本会规范化地址、请求 `/v1/models` 并显示模型菜单；列表请求失败时才允许手动输入或使用默认模型。

选择模型后，脚本会实际请求 `/v1/chat/completions`。该接口和所选模型必须可用，否则拒绝保存配置，因为 AnythingLLM 的 `generic-openai` Provider 依赖 Chat Completions。脚本还会探测 `/v1/responses`，并使用一张无业务数据的微型图片实际检测视觉能力。检测结果写入 `config/provider.yaml`，API Key 只写入 `.env` 的 `AI_API_KEY`。

AnythingLLM 使用 `generic-openai` Provider、原生 Embedding 与内置 LanceDB。基础地址应包含 API 的 `/v1` 前缀；脚本会自动避免重复拼接 `/v1`。

`.env` 中 `AI_API_PROBE_BASE_URL` 是宿主机实际探测地址，`AI_API_BASE_URL` 是容器运行地址。用户输入 `localhost` 或 `127.0.0.1` 时，后者自动映射为 `host.docker.internal`；两者不要手工混用。非本机 Provider 必须使用 HTTPS。配置值通过受限的 dotenv 序列化保存，支持 `$`、`#`、空格、引号、反斜线和 `=`，脚本从不 `source .env`。

上述业务配置使用 JSON 语法书写；JSON 本身是合法 YAML，这使 n8n 无需额外解析依赖即可安全读取。首次安装由对应 `.example` 模板生成实际配置，实际配置被 Git 忽略。修改后应运行健康检查并重新发布工作流。

## AnythingLLM 初始化

首次安装会自动使用本机 `ANYTHINGLLM_AUTH_TOKEN` 获取会话令牌，复用或创建名为 `ai-support` 的 Developer API Key，并检查或创建 `ANYTHINGLLM_WORKSPACE` 指定的工作区。Key 自动写入权限为 `0600` 的 `.env`，不会写入公开模板或日志。预先提供 Key 时，安装程序会先验证它。

`ANYTHINGLLM_CHAT_MODE` 必须是 `chat`。n8n 会把同一 Crisp conversation 受长度限制的用户、AI 与人工消息加入当前请求，并使用 `sessionId` 隔离 AnythingLLM 会话；安装和升级会把旧的 `query` 或 `automatic` 值迁移为 `chat`。知识库优先与“不确定不猜测”由独立 Prompt 约束。

## Crisp

`CRISP_TOKEN_TIER` 配置 REST API Token 的 `website` 或 `plugin` 类型。`CRISP_HOOK_MODE` 独立配置 Webhook 的 `website` 或 `plugin` 校验方式。Token、URL Secret 和 Signing Secret 都只保存在 `.env`。

- Website 模式使用 `CRISP_WEBSITE_HOOK_SECRET`，地址带 `?key=<Secret>`。Website Hook 没有 Crisp 签名，工作流只验证随机查询 Secret。
- Plugin 模式使用 `CRISP_PLUGIN_SIGNING_SECRET`，地址不带查询 Secret。工作流强制验证原始请求体的 HMAC-SHA256 签名和五分钟时间窗，不会回退为 URL Secret。

两种 Hook 都必须订阅 `message:send` 与 `message:received`。前者处理访客消息，后者处理公开 operator 回复。Plugin Hook 可额外订阅 `session:request:initiated` 发送会话创建欢迎语。不要使用 `session:set_opened` 作为欢迎事件，它表示 operator 查看 conversation。

`WEBHOOK_ACCESS_MODE` 为 `managed_https` 时启用 Compose 中的 Caddy profile；`external_proxy` 表示复用现有 HTTPS 入口。`WEBHOOK_PRODUCTION_URL` 始终保存最终 `/webhook/crisp-webhook` 地址，`PUBLIC_WEBHOOK_URL` 保存 n8n 使用的公开 base。受管 Caddy 仅发布生产 Webhook，证书目录集中在 `data/caddy` 和 `data/caddy-config`。

图片 URL 默认只接受 HTTPS 的 `crisp.chat` 子域名。确需使用其他可信图片主机时，可在 `.env` 的 `CRISP_IMAGE_HOSTS` 中填写逗号分隔的精确主机名。

## 人工接管

`handoff.yaml` 的 `keywords` 是唯一的文字自动识别入口，默认包含“人工”“人工客服”“转人工”“真人”和“真人客服”。`match_mode` 默认是 `exact`：对输入做 Unicode、空白和大小写规范化后，必须与某个配置词完全相等，避免“人工智能”之类文本误触发。确需旧式包含匹配时可显式设为 `contains`。

访客精确命中关键词或选择菜单中的人工动作后，工作流先按 `notify_user.enabled` 回复“正在为您转接人工客服，请稍候。”，随后关闭当前 conversation 的 AI，并添加人工标签。`disable_ai` 必须保持为 `true`；安装、更新和恢复会把旧配置中的其他值安全迁移为 `true`。

真实、公开且非自动的 operator `message:received` 文本或文件回复会立即关闭当前 conversation 的 AI；内部 note 和本系统发送的消息会被忽略。AI 生成后、发送前还会重新读取 Crisp 消息并检查接管代次，发现人工已经回复时取消本次 AI 发送。接管期间访客消息不会触发 AI 回复。`resume_after_seconds` 到期后，AI 会在下一条访客消息恢复；设为 `0` 表示不自动恢复。operator 的消息内容不会绕过接管规则。

知识库未命中、低置信度、图片理解失败和 API 失败不会关闭 AI。相应提示可通过 `no_answer_message`、`low_confidence_message` 和 `failure_message` 修改。

## Conversation 标签

`tags.yaml` 配置项目管理的四类标签，默认值分别是 `ai_resolved`、`knowledge_miss`、`low_confidence` 和 `human_required`。标签值不得包含空格或控制字符；设 `enabled` 为 `false` 可关闭自动标签。

更新标签时，工作流先读取 Crisp conversation 当前 `segments`，再把新标签与全部既有标签做去重并集；不会删除或替换既有项目标签。读取失败时会跳过 PATCH，正文回复不受影响。Website Token 或 Plugin Token 必须具备读取和修改 conversation meta 的权限。

## 回答反馈与统计

`feedback.yaml` 控制回答后的“是否解决问题”提示、正负反馈词、致谢消息、有效期与最大文本长度。反馈只在成功生成的知识库或视觉回答后询问；菜单、欢迎语、失败提示和转人工通知不会重复询问。

`data/analytics/events.jsonl` 保存追加式事件，活动文件达到约 10 MiB 时轮转，最多保留 `.1` 至 `.5` 五个历史文件。统计脚本按最旧轮转到活动文件汇总，存储窗口最大约 60 MiB；超出窗口的最旧轮转会被淘汰。问题数、AI 回复数、命中、未命中、发送失败和转人工事件不保存消息内容；AI 回复、命中和待反馈数据只在 Crisp 确认消息成功发送后提交。反馈事件按需求保存 `session`、`question`、`answer` 和 `feedback`，其中 session 使用 HMAC 匿名化，问题和回答在进入待反馈状态前就会过滤常见 Token、Cookie、JWT、Secret、邮箱和号码并截断。管理员仍应落实隐私告知、访问控制和保留期限。

查看统计：

```bash
sudo /opt/crisp-ai/scripts/analytics.sh knowledge
sudo /opt/crisp-ai/scripts/analytics.sh feedback
```

## 版本快照

`.env` 中的 `SNAPSHOT_MIN_FREE_MB` 控制快照完成后必须保留的空间，默认 `1024` MiB。容量预检按待复制数据的两倍加预留空间保守估算，以覆盖临时副本和压缩归档同时存在的阶段。

`SNAPSHOT_RETENTION_COUNT` 控制有效版本快照的最大数量，默认 `10`。设为 `0` 表示不自动清理。自定义值会在重复安装时保留；升级会为旧部署补齐缺失的默认值。

`LOCAL_HEALTH_TIMEOUT_SECONDS` 与 `LOCAL_HEALTH_INTERVAL_SECONDS` 控制安装、更新、恢复和回滚等待本地服务就绪的有限窗口，默认分别为总计 `1800` 秒和每轮 `5` 秒。HTTP 探测耗时也计入总时限，普通服务器就绪后会立即提前结束；仅在已确认机器冷启动较慢时调整，允许范围分别为 `1–3600` 秒和 `1–30` 秒。

`N8N_WORKFLOW_READY_TIMEOUT_SECONDS` 控制 workflow 发布后等待生产 Webhook 和 JavaScript task runner 可实际执行的总时限，默认 `300` 秒，允许 `1–900` 秒。检查使用固定无效 Secret，期望得到 workflow 自身的 401 JSON，不会触发 AI 或 Crisp 外发。

版本快照会短暂停止 n8n 与 AnythingLLM，保存程序、配置、知识文件、AnythingLLM 数据、n8n PostgreSQL 逻辑备份和本机镜像 ID。快照不包含 `.env`、匿名统计或日志，只用于同一主机受限回滚。

## 镜像版本

默认 Compose 使用已选定的版本标签：

- n8n `2.33.0`
- PostgreSQL `16.10-alpine`
- AnythingLLM `1.16.1`
- Caddy `2.10.2-alpine`（仅受管 HTTPS profile 启用）

AnythingLLM 基线选择 `1.16.1`，用于包含 `1.15.0` 之后公布的相关修复；不得把正式部署降级到 `1.15.0` 或更早版本。可通过 `.env` 覆盖镜像，但覆盖后必须先核对上游安全公告，再重新执行完整测试和真实部署验收。不要在正式部署中改用 `latest` 或宽泛主版本标签。

## Prompt

首次安装会从 `config/prompt.md.example` 创建 `config/prompt.md`。可通过管理菜单修改、导入或导出；导入文件必须是普通文件且位于允许的路径中。

## 知识库

支持 Markdown、TXT、PDF 和 DOCX。管理脚本只接受这些扩展名，并拒绝符号链接和路径穿越。AnythingLLM 负责解析、自动分块、向量化、检索和重新索引；文件更新或删除后，脚本同时清除旧索引与 AnythingLLM 源文档，暂时失败的源文档清理会写入本地清单并在下次同步重试。
