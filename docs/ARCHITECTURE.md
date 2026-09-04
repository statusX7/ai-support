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
3. 配置化转人工关键词、普通关键词和菜单规则优先执行；其余消息发送到 AnythingLLM。
4. AnythingLLM 使用对应会话线程检索知识库并调用已配置模型。
5. n8n 记录不含用户内容的命中指标；可选反馈仅保存匿名会话标识及脱敏、截断后的问题和回答。
6. n8n 合并 Crisp conversation 的既有标签，再通过 REST API 写入标签和回复。

AI 默认优先回复，不查询人工是否在线。只有真实 operator 回复，或访客命中 `handoff.yaml` 中的明确转人工关键词或菜单动作，才关闭该 conversation 的 AI。知识库未命中、低置信度、图片理解失败或 Provider 失败只返回安全提示并添加对应标签，不会进入人工模式。人工接管可在配置的等待时间后自动解除，也可由配置的恢复关键词解除。

n8n 使用工作流持久状态保存有限长度的 AI 开关、菜单位置、事件指纹、待反馈回答和人工上下文；AnythingLLM 使用 Crisp `session_id` 作为 `sessionId` 保存文本问答历史。人工消息只补充上下文，不触发模型调用。状态会定期裁剪，避免无限增长。本版本只支持单客服场景，不包含坐席、权限或多客服账号管理。

Website Hook 本身不提供签名，因此必须在 Webhook URL 中携带随机 Secret。Plugin Hook 优先验证 `X-Crisp-Signature`，签名算法为 HMAC-SHA256，并拒绝超过五分钟的请求。两种模式都会校验 `website_id`、事件类型、消息方向和重复指纹。

## 部署边界

所有持久化数据都位于部署目录，默认是 `/opt/crisp-ai`。匿名统计事件位于 `data/analytics/events.jsonl`；版本快照位于 `backups/versions/`。容器端口默认绑定到 `127.0.0.1`，生产环境应通过带 TLS 的反向代理公开 n8n Webhook，数据库不对宿主机暴露端口。

迁移备份不含密钥和运行时用户数据。回滚快照额外包含 AnythingLLM 数据，只用于同一主机的故障恢复，目录权限为仅管理员可访问，不得上传或当作迁移包分发。
