# 测试说明

## 测试分层

测试结果必须按以下三层记录，不能用低层结果代替高层验收：

- `STATIC`：Bash 语法、ShellCheck、JSON/YAML、Compose 解析、Git 忽略和密钥扫描、workflow 静态契约。
- `STUB`：在项目内临时目录使用桩 Docker、curl 和文件状态执行安装、Provider、工作流、备份、恢复、更新、回滚和安全失败路径。
- `INTEGRATION`：先连接一个已经安装的真实本地 Docker 部署，检查目录权限、Compose、容器、本地健康接口、workflow 已发布以及伪造 Webhook 被拒绝；再通过显式启用的外部 E2E 连接隔离的 Crisp、AnythingLLM 和 Provider。

只执行本地部署检查仍不能证明外部链路。`tests/test_external_e2e.sh` 默认跳过，只有同时设置启用开关、隔离环境确认及全部测试凭据时才会访问真实服务。

## 日常自动测试

```bash
./tests/run.sh
```

开发环境缺少 ShellCheck、Docker Compose、Node.js 或真实部署目录时，对应项目会明确显示“跳过”。日常模式允许跳过，但报告必须逐项列出，不能写成全部通过。

自动测试使用项目目录内的临时运行目录，结束后清理。桩凭据只用于测试，不得使用真实 Token、Secret 或用户数据。

## 发布模式自动测试

发布模式不允许关键自动测试跳过，并要求一个 `ready` 的真实部署，以及专用 Crisp Website、Provider、AnythingLLM 工作区和四个互不相同的空白测试 conversation。先通过 root shell 或 CI Secret Store 安全注入以下变量，不要把值写入仓库、命令行参数或 Shell 历史：

执行主机必须提供 ShellCheck、Docker Compose v2、Node.js、`curl`、`jq`、Python 3、`realpath`、`base64` 和 `sha256sum`；缺少任一关键依赖都会令发布模式失败。

- 控制：`AI_SUPPORT_E2E_ENABLE=1`、`AI_SUPPORT_E2E_CONFIRM_DEDICATED=YES`。
- 部署：`AI_SUPPORT_INTEGRATION_DEPLOY_DIR`、`AI_SUPPORT_E2E_DEPLOY_DIR`。
- Provider：`AI_SUPPORT_E2E_PROVIDER_BASE_URL`、`AI_SUPPORT_E2E_PROVIDER_API_KEY`、`AI_SUPPORT_E2E_PROVIDER_MODEL`；使用 Responses 时再设 `AI_SUPPORT_E2E_PROVIDER_API_MODE=responses`。
- AnythingLLM：`AI_SUPPORT_E2E_ANYTHINGLLM_BASE_URL`、`AI_SUPPORT_E2E_ANYTHINGLLM_API_KEY`、`AI_SUPPORT_E2E_ANYTHINGLLM_WORKSPACE`。
- Crisp：`AI_SUPPORT_E2E_CRISP_WEBSITE_ID`、`AI_SUPPORT_E2E_CRISP_TOKEN_TIER`、`AI_SUPPORT_E2E_CRISP_TOKEN_IDENTIFIER`、`AI_SUPPORT_E2E_CRISP_TOKEN_KEY`。
- 会话与图片：`AI_SUPPORT_E2E_TEXT_SESSION_ID`、`AI_SUPPORT_E2E_OPERATOR_SESSION_ID`、`AI_SUPPORT_E2E_HANDOFF_SESSION_ID`、`AI_SUPPORT_E2E_IMAGE_SESSION_ID`、`AI_SUPPORT_E2E_IMAGE_URL`。

变量就绪后，在该 root shell 中运行：

```bash
AI_SUPPORT_RELEASE_TEST=1 ./tests/run.sh
```

该命令必须以 0 退出，且 `STATIC`、`STUB`、`INTEGRATION` 都无失败、无跳过。外部脚本会使用真实 API 验证 Provider、四格式知识文件、Crisp 文本与上下文、防重复、operator 接管、精确转人工、标签并集、视觉和统计增量，并在结束时清理测试文档及恢复被修改的测试标签。它不会覆盖本章列出的全部负向、更新和回滚场景，不能单独作为 Release 依据。

Website Hook 和 Plugin Hook 必须在各自配置下分别完整执行一次发布模式测试；每次使用新的四个测试 conversation。测试结束后立即从 root 环境移除凭据。

## 真实部署验收

只在隔离的 Crisp 测试 Website、测试 Provider 和虚构知识文件中执行。报告只记录时间、版本、匿名测试会话标识、测试事实标识及 PASS/FAIL；禁止记录 Token、Secret、完整消息正文或真实用户数据。

### 1. 全新安装与两阶段状态

在干净部署目录运行 `./install.sh`。确认安装自动创建或验证 AnythingLLM Developer API Key、创建工作区、同步 Prompt、发布 workflow，并仅在完整健康检查通过后写入 `state=ready`。

再分别验证：

- Provider、Crisp 或 AnythingLLM 故障时安装返回非零，状态不是 `ready`。
- 对同一未完成部署重新运行安装可安全续跑。
- `--skip-start` 的新部署处于 `staged`，不能运行管理或更新；不带该参数重跑后成为 `ready`。
- 对 `ready` 部署重复安装不改写现有密钥或自定义配置。

### 2. Docker、健康和持久化

在部署目录执行：

```bash
docker version
docker compose version
docker compose config --quiet
docker compose up -d
docker compose ps
sudo ./scripts/healthcheck.sh
```

PostgreSQL、AnythingLLM 和 n8n 必须运行且健康，workflow 必须处于已发布状态，完整健康检查必须验证 Provider、Crisp 和 AnythingLLM Chat。

在 `data/anythingllm/` 与 n8n 数据库分别创建无敏感测试标记并记录 SHA-256 或查询值。执行 `docker compose restart`，等待本地健康检查通过，确认两类标记仍存在且内容一致，然后删除测试标记。

### 3. Provider

- `/v1/models` 成功时显示模型列表并能选择模型。
- 列表失败时允许手工模型，但所选模型仍必须实际通过 `/v1/chat/completions`。
- 分别验证支持和不支持 `/v1/responses` 的 Provider，确认 `AI_API_MODE` 正确。
- 用测试图片验证安装检测出的 `AI_SUPPORTS_VISION` 与实际能力一致。
- 无效 Key、错误 Base URL 和不可用模型必须清晰失败，日志不得出现 Key。

### 4. Crisp Hook 与消息链路

Website Hook 和 Plugin Hook 分别执行一轮，且都订阅 `message:send` 与 `message:received`：

- Website 模式：正确 URL Secret 接受，错误 Secret 拒绝。
- Plugin 模式：正确签名接受；错误签名、过期时间戳、缺少原始请求体均拒绝，且不能用 Website Secret 绕过。
- 访客文本完成 Crisp → n8n → AnythingLLM → Provider → Crisp 回复。
- 同一 conversation 连续两轮能引用上一轮用户、AI 和人工上下文；不同 conversation 不串线。
- 重放同一入站 fingerprint 不产生第二条回复；出站重试使用稳定 fingerprint。
- 重启 n8n 后当前 conversation 的 AI 开关、接管代次、欢迎/菜单状态和重复指纹仍生效；在隔离环境构造过期及超量控制文件，确认 7 天和 2000/1500 清理阈值生效，且当前会话、非普通文件和不匹配名称的文件不被删除。
- operator 公开回复后 AI 立即停止；内部 note 和自动消息不触发接管。
- 在 AI 推理期间插入 operator 回复，确认发送前复核会取消在途 AI 回答。
- 访客发送精确关键词“转人工”时只回复配置提示、关闭 AI 并添加 `human_required`；“人工智能”不得在默认 `exact` 模式误触发。
- 知识库未命中、低置信度和 Provider 失败只安全回复或标记，不得自动转人工。
- Plugin 的 `session:request:initiated` 可发送一次欢迎语；`session:set_opened` 不得发送欢迎语。Website 欢迎语只在第一条访客消息合并一次。

### 5. 标签、统计与反馈

- 预先设置无关标签和已有项目标签，再触发四类标签，确认结果是去重并集且不删除任何既有标签。
- 临时移除 conversation meta 权限，确认跳过标签更新但正文回复仍成功。
- 验证 `ai_resolved`、`knowledge_miss`、`low_confidence`、`human_required` 均来自配置。
- Crisp 发送失败时不得增加 AI 回复、知识命中或待反馈记录；应增加匿名发送失败计数。
- 正负反馈均能记录匿名 session 和脱敏、截断后的问题与答案；统计结果包含好评率和高频失败问题。
- 生成超过轮转阈值的非敏感测试事件，确认 `.1` 至 `.5` 与活动文件会被共同汇总，且第六个历史轮转按策略淘汰。

### 6. 知识库四种格式

准备内容真实有效、仅含虚构事实的 Markdown、TXT、PDF 和 DOCX，不能只把文本改扩展名。逐个执行添加、同步、查询、重新索引和删除：

- AnythingLLM 必须真实解析并把文档加入目标工作区。
- 每种格式的唯一事实都能从 Crisp 查询到。
- 更新文档时先验证新索引，失败时旧索引仍可查询。
- 删除后文档和索引都消失。
- 知识命中、未命中、总问题和命中率增量正确。

### 7. 图片

- 从 Crisp 发送允许主机上的测试图片，视觉模型返回与图片有关的回答。
- 切换到不支持视觉的模型或让视觉接口返回明确不支持错误，系统提示切换视觉模型且 workflow 不崩溃。
- 非 HTTPS 或未允许主机的图片 URL 被拒绝。

### 8. 备份、更新和回滚

- 迁移备份和恢复覆盖 Prompt、业务配置、workflow、知识文件和清单，且不包含 `.env` 或任何真实 Secret。
- 并发启动两个维护操作时，第二个操作因维护锁而安全退出。
- 正常更新在停机前完成新镜像拉取，创建 v2 快照后升级并恢复 `ready`。
- 快照包含非空 n8n PostgreSQL 逻辑备份、AnythingLLM 数据和历史镜像 ID，不包含 `.env`、匿名统计或日志。
- 注入健康失败触发自动回滚；回滚后 n8n 数据库测试记录、AnythingLLM 数据哈希、Prompt、workflow 和旧版本镜像全部恢复，同时当前人工接管控制状态不得因软件回滚被清除。
- 删除所需历史镜像后，回滚必须在修改当前文件和停止服务前安全失败。
- 验证容量不足拒绝、历史保留数量以及回滚目标保护策略。

## 结果判定

任何步骤为 FAIL、SKIP、未执行或证据不足，都必须写成“未验收”。只有 [发布说明](RELEASE.md) 中全部门禁为 PASS，才允许创建 `v1.0.0` tag 和 GitHub Release。
