# 配置说明

## 配置分层

- `.env` 保存部署路径、端口和密钥，仅允许部署账户读取，不得提交到 Git。
- `config/provider.yaml` 保存 Provider 类型、地址、模型和能力检测结果，不保存 API Key。
- `config/prompt.md` 保存客服系统提示词。
- `config/keyword.yaml`、`config/menu.yaml` 和 `config/handoff.yaml` 保存业务规则。
- 带 `.example` 后缀的文件是可公开提交的模板，不得填入真实凭据。

## AI Provider

配置入口只要求输入 API Base URL 和 API Key。管理脚本会规范化地址、请求 `/v1/models` 并显示检测到的模型；模型列表请求失败时才提供手动输入或默认模型选项。

管理脚本还会分别探测 `/v1/responses` 与 `/v1/chat/completions`，把可用接口记录到 `config/provider.yaml`。API Key 只写入 `.env` 的 `AI_API_KEY`。

AnythingLLM 使用 `generic-openai` Provider、原生 Embedding 与内置 LanceDB。基础地址应包含 API 的 `/v1` 前缀；脚本会自动避免重复拼接 `/v1`。

`keyword.yaml`、`menu.yaml` 和 `handoff.yaml` 使用 JSON 语法书写；JSON 本身是合法 YAML，这使 n8n 无需额外解析依赖即可安全读取。修改后可通过管理菜单校验格式并重载工作流。

## AnythingLLM 初始化

首次启动后，在本机访问 AnythingLLM 管理页面，创建名为 `crisp-support` 的工作区，并在“Developer API”中创建独立 API Key。随后通过 `./manage.sh` 保存该 Key。不同 Crisp conversation 使用各自的 `sessionId`，避免会话历史串线。

工作区默认使用 `query` 模式，以知识库为答案边界。若需要允许模型使用通用知识，可把 `.env` 中的 `ANYTHINGLLM_CHAT_MODE` 改为 `chat`，但应同步收紧 Prompt 与转人工规则。

## Crisp

单工作区部署优先使用 Website Token，`CRISP_TOKEN_TIER` 设置为 `website`；多工作区私有插件使用 Plugin Token，并设置为 `plugin`。两种 Token 都只保存在 `.env`。

Website Hook 不提供签名，Webhook 地址必须使用 `https://部署域名/webhook/crisp-webhook?key=随机Secret`，其中 Secret 与 `.env` 的 `CRISP_WEBHOOK_SECRET` 一致。Plugin Hook 应使用不带查询 Secret 的地址，工作流会校验 `X-Crisp-Signature` 和 `X-Crisp-Request-Timestamp`。

至少订阅 `message:send`。若使用 Plugin Hook，还可订阅 `message:received`、`session:set_opened` 和 `session:request:initiated`，分别用于记录人工回复和在聊天窗口打开时发送欢迎语。Website Hook 无法提供 `session:set_opened`，因此欢迎语会在访客首次发言时合并发送。

图片 URL 默认只接受 HTTPS 的 `crisp.chat` 子域名。确需使用其他可信图片主机时，可在 `.env` 的 `CRISP_IMAGE_HOSTS` 中填写逗号分隔的精确主机名。

## 自动转人工

访客输入转人工关键词、命中投诉/付款/账户规则、AnythingLLM 没有来源、模型置信度不足或 API 调用失败时，会话会进入人工接管状态。人工消息也会自动延长接管时间。接管期间工作流记录访客消息但不发送 AI 回复，到达 `resume_after_seconds` 后才允许 AI 在下一条消息恢复。

## Prompt

首次安装会从 `config/prompt.md.example` 创建 `config/prompt.md`。可通过管理菜单修改、导入或导出；导入文件必须是普通文件且位于允许的路径中。

## 知识库

支持 Markdown、TXT、PDF 和 DOCX。管理脚本只接受这些扩展名，并拒绝符号链接和路径穿越。AnythingLLM 负责解析、自动分块、向量化、检索和重新索引。
