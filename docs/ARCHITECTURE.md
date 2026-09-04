# 架构说明

## 组件边界

- Crisp 负责访客会话、消息收发和人工客服界面。
- n8n 负责校验 Webhook、编排规则、维护会话映射并调用外部 API。
- AnythingLLM 负责知识库、文档解析、自动分块、检索和模型调用。
- OpenAI Compatible API 提供文本或视觉模型能力。
- PostgreSQL 保存 n8n 配置、凭据和工作流状态。

项目不自行实现 RAG、向量数据库、文档解析或模型管理。

## 数据流

1. Crisp 将 `message:send` 或欢迎事件发送到 n8n Webhook。
2. n8n 验证请求，只接受需要处理的用户事件，并按会话读取配置。
3. 关键词、菜单或转人工规则优先执行；其余消息发送到 AnythingLLM。
4. AnythingLLM 使用对应会话线程检索知识库并调用已配置模型。
5. n8n 通过 Crisp REST API 将结果写回原会话。

人工消息同样进入会话历史，但不会触发机器人回复。人工接管状态按 Crisp conversation 保存，并在配置的恢复时间后自动解除。

n8n 使用工作流持久状态保存有限长度的菜单位置、事件指纹、人工上下文和图片会话摘要；AnythingLLM 使用 Crisp `session_id` 作为 `sessionId` 保存文本问答历史。人工消息只补充上下文，不触发模型调用。状态会定期裁剪，避免无限增长。

Website Hook 本身不提供签名，因此必须在 Webhook URL 中携带随机 Secret。Plugin Hook 优先验证 `X-Crisp-Signature`，签名算法为 HMAC-SHA256，并拒绝超过五分钟的请求。两种模式都会校验 `website_id`、事件类型、消息方向和重复指纹。

## 部署边界

所有持久化数据都位于部署目录，默认是 `/opt/crisp-ai`。容器端口默认绑定到 `127.0.0.1`，生产环境应通过带 TLS 的反向代理公开 n8n Webhook，数据库不对宿主机暴露端口。
