# 架构说明

## 组件边界

- Crisp 负责访客会话、消息收发和人工客服界面。
- n8n 负责校验 Webhook、编排规则、维护会话映射并调用外部 API。
- AnythingLLM 负责知识库、文档解析、自动分块、检索和模型调用。
- OpenAI Compatible API 提供文本或视觉模型能力。
- PostgreSQL 保存 n8n 配置、凭据和工作流状态。
- 可选 Caddy 只负责受管 HTTPS 的生产 Webhook 入口。

项目不自行实现 RAG、向量数据库、文档解析或模型管理。

## 数据流

1. Crisp 将 `message:send`、`message:received` 或 Plugin 的 `session:request:initiated` 发送到 n8n Webhook。
2. n8n 按配置的 Website URL Secret 或 Plugin HMAC 签名验证请求，只接受目标 Website 的受支持事件。
3. 配置化转人工关键词、普通关键词和菜单规则优先执行；其余消息发送到 AnythingLLM。
4. n8n 注入同一 conversation 的受限近期历史，并用 Crisp `session_id` 隔离 AnythingLLM 会话；AnythingLLM 检索知识库并调用已配置模型。
5. 回复发送前，n8n 重新读取 Crisp 消息并复核 AI 开关，避免 operator 已接管时仍发送在途回答。
6. Crisp 确认回复成功后，n8n 才提交 AI 回复、知识命中和待反馈统计。
7. n8n 读取 Crisp conversation 现有 `segments`，与新标签取并集后写回；读取或写入失败不会阻断正文回复。

AI 默认优先回复，不查询人工是否在线。只有真实 operator 回复，或访客命中 `handoff.yaml` 中的明确转人工关键词或菜单动作，才关闭该 conversation 的 AI。知识库未命中、低置信度、图片理解失败或 Provider 失败只返回安全提示并添加对应标签，不会进入人工模式。人工接管只按配置的等待时间自动解除；operator 的任意公开回复始终优先关闭 AI。

n8n 使用工作流持久状态保存有限长度的待反馈回答以及用户、AI 和人工历史。AI 开关、接管代次、菜单位置、欢迎状态和哈希后的事件指纹还会按哈希 session 键写入 `data/runtime/`，使用会话级锁和原子替换抵抗并发执行并跨容器重启保持状态；这些控制文件不保存消息正文。文本请求最多注入最近 12 条受长度限制的本地历史，图片请求最多使用最近 20 条；AnythingLLM 同时使用 Crisp `session_id` 作为 `sessionId` 隔离会话。工作流内的历史、指纹和活动会话数量都有上限。控制文件会在低频、加锁的清理中删除超过 7 天的记录；文件数超过 2000 时只保留最近更新的 1500 个，并始终保护当前会话。清理只处理严格匹配名称的普通文件。本版本只支持单客服场景，不包含坐席、权限或多客服账号管理。

Website Hook 本身不提供签名，因此必须在 Webhook URL 中携带独立随机 Secret。Plugin Hook 使用另一份 Crisp Signing Secret，强制验证 `X-Crisp-Signature`、原始请求体和请求时间，绝不降级为 URL Secret。两种模式都会校验 `website_id`、事件类型、消息方向和重复指纹，并为出站回复生成稳定数值 fingerprint。

欢迎语不使用 `session:set_opened`。Plugin 模式可由 `session:request:initiated` 触发；Website 模式在 conversation 第一条访客消息中合并欢迎语。

## 部署边界

安装入口分为两级：`scripts/bootstrap.sh` 先以 Bash 与发行版包管理器补齐最小运行工具，`scripts/wizard.sh` 再采集十项配置；只有用户确认后才安装或复用 Docker、启动 daemon 并进入应用初始化。两模块被 source 时不执行依赖检查或系统变更，因而 `--help`、`--version` 和参数错误不依赖 Docker/jq。

所有持久化数据都位于部署目录，默认是 `/opt/crisp-ai`。PostgreSQL、n8n、AnythingLLM 和匿名统计分别使用部署目录内的持久化路径；n8n 与 AnythingLLM 数据目录由容器 UID/GID `1000:1000` 持有。容器端口默认绑定到 `127.0.0.1`，数据库不对宿主机暴露端口。

安装标记经历 `collecting`、`installing` 或 `staged`。Docker、本地容器、Provider、AnythingLLM、Prompt/知识和已发布 workflow 通过后，可进入 `local-ready`；Crisp REST 凭据通过后进入 `ready`。依赖、本地服务、应用配置、Provider、Crisp API、Webhook 和真实 conversation 分别记录 fact，避免把容器启动与客户链路混为一谈。所有变更性维护操作通过同一文件锁串行执行。

n8n 与 AnythingLLM 始终绑定回环地址；PostgreSQL 仅在后端网络。选择受管 HTTPS 时，Compose 的 `managed-https` profile 启动 Caddy并公开 80/443，但 Caddyfile 只转发 `/webhook/crisp-webhook`。选择已有反向代理时不启用该 profile；模式切换只清理本项目 Caddy 容器。

默认卸载是可恢复的生命周期状态：容器、网络和程序文件被移除，安装标记变为 `uninstalled-data-kept`，但权限受限的 `.env`、业务配置、知识文件、数据库、AnythingLLM 数据、备份和日志保留在部署目录。必须从新的可信源码副本重新运行 `install.sh` 才能恢复服务。完整清理属于独立的破坏性流程，需要普通确认和精确输入 `PURGE` 两次确认；其迁移备份始终写到部署目录同级。

迁移备份不含密钥和运行时用户数据。版本快照额外包含 AnythingLLM 数据、n8n PostgreSQL 逻辑备份和本机镜像 ID；创建时暂停 n8n 与 AnythingLLM，回滚时原子切换 AnythingLLM 数据并恢复数据库。当前 `data/runtime/` 控制状态和匿名统计不由版本快照回退，避免软件回滚意外解除现有人工接管。版本快照只用于同一主机故障恢复，目录权限为仅管理员可访问，不得上传或当作迁移包分发。
