# 配置、应用与迁移契约

正常操作使用 [18 项 Shell 菜单](MENU.md)，不直接编辑 YAML 或登录应用网页补配置。以下描述真实存储与运行消费者，方便审计、故障定位和迁移；示例只含虚构内容。

## 1. 权威源和生效机制

业务 `.yaml` 使用 JSON 语法（也是合法 YAML），因此 n8n 可安全读取而不执行用户文字。`.env` 使用严格解析和序列化，不 `source`、不 `eval`，特殊字符 `$ # = 引号 反斜线` 不再被 Compose 意外插值。公开 `.example` 只用于首次生成，升级不覆盖合法自定义配置。

| 菜单 | 落盘位置（相对部署目录） | 消费者/生效与验证 |
| --- | --- | --- |
| 3 AI | `.env`、`config/provider.yaml` | 宿主探测 + 适配器/AnythingLLM/n8n；实际容器调用后提交代次，失败恢复旧值 |
| 4 Prompt | `config/prompt.md` | workspace openAiPrompt + n8n 图片请求；API 与容器文件回读，后续新问题使用新正文 |
| 5 知识 | `knowledge/catalog.json`、`kb_*/sources`、`data/knowledge-manifest.json` | 全部启用库投影到一个 workspace；实际文档/索引回读与来源映射 |
| 6 规则 | `config/keyword.yaml` | runtime 每事件读取；schema、边界、容器文件回读，无需全栈重启 |
| 7 人工 | `config/handoff.yaml`、`data/runtime/session-*.json` | 默认秒数供新接管使用；单会话 CLI 使用同一事务状态 |
| 8 总开关 | `config/runtime.yaml` | 事件处理和每次发送前读取，代次使旧任务失效，不停止服务 |
| 9 欢迎/菜单 | `config/menu.yaml` | runtime 与白名单公开配置路由；网页只读允许的 UI 字段 |
| 10 Crisp | `.env`、受管反代片段 | n8n 重载与 REST/Hook/收件事实复核，不重生 workspace |
| 11 标签/反馈 | `config/tags.yaml`、`config/feedback.yaml` | runtime 与 `data/analytics`，正文发送与可选标签分离 |
| 12 业务迁移 | 用户选择的受限 `.tar.gz` | schema/checksum/预览→备份→同步→回读，保留本机秘密 |
| 13/14 本机恢复 | `backups/versions`、完整备份包 | 数据库、应用文件与镜像身份一致性恢复 |

`runtime.yaml` 使用 `schema_version: 2`、布尔 `enabled`、单调 `revision`、`applied_revision`。候选受限暂存、校验、旧值备份、原子提交后，实际组件回读成功才标已应用。失败要恢复旧值或明确 pending，不能只输出“文件已保存”。总开关/控制事件不等待付费模型探测；Prompt/Provider/知识操作会使旧任务代次失效。

配置历史保存于受限 `backups/config-history`；它可能包含旧秘密、Prompt 或知识，不能上传。维护操作共用实例锁；空闲菜单不长期持锁。会话控制使用独立短临界区，不能锁着等 LLM 请求。直接在第三方 Web UI 改动可能造成偏离，选 `16 → 6` 重新应用受管配置。

## 2. Provider、协议与网络

`AI_API_PROBE_BASE_URL` 是宿主探测地址，`AI_API_BASE_URL` 是容器可达供应商地址；本机地址映射为 `host.docker.internal`，合法代理路径保留，不重复追加 `/v1`。`AI_API_KEY` 与 `AI_CUSTOM_HEADERS_JSON` 只在 `.env`；后者允许有限安全请求头，不能覆盖 Authorization/Host/Content-Length 等管理字段。

`provider.yaml` 记录 `schema_version: 2` 与 `provider.base_url/model/api_mode/capabilities/api_key_env` 等非秘密元数据，模型列表缓存与当前候选凭据摘要绑定，不保存明文 Key。管理员选择 `chat_completions` 或 `responses` 后必须得到有效正文；HTTP 200、模型 ID 或列表成功不能代替能力测试。

AnythingLLM 固定使用 `generic-openai`，内部 Base 为 `AI_ANYTHINGLLM_BASE_URL=http://provider-adapter:8787/v1`。适配器复用固定镜像中的 Node，仅提供项目所需 Chat→Responses 转换或 Chat 转发，不是另一套 RAG。容器内部接口仍鉴权，不公开端口；生成请求有输出/内容上限、超时与取消。实际调用必须与 `api_mode` 一致。

图片走同一 Provider 的已验证文本/图片协议，带当前 Prompt 与同会话公开历史；不能支持时安全请求文字补充，不转人工。图片 URL 下载保护见 [SECURITY](SECURITY.md)。默认本地 Embedder由 AnythingLLM 管理，不需要另外的 API Key，不把聊天模型当 Embedding。升级已有模型设置须考虑全索引重建，不能只改显示名称。

`data/runtime/session-*.json` 中的可选 `image_context` 保留最多 3 份视觉摘要，每份 2000 字符、24 小时；后续问答只有匹配该会话近期公开附件才使用，避免依赖模型在公开回答里复述全部细节。它是受限会话数据，不是业务配置，不导出至迁移包；旧会话无此字段仍兼容，不重置原人工状态。

## 3. Prompt

`config/prompt.md` 保留原文，不加入内部版本号或 hash。文件/多行粘贴上限 256 KiB；空或仅空白拒绝覆盖。修改自动更新 workspace，并检查回读精确一致；n8n 同时读取最新正文。当前 conversation 的新问题使用新 Prompt，公开历史仅作背景，不能覆盖当前知识与系统护栏。

默认规则要求知识优先、不编造、不泄露内部配置、不声称执行未做操作、必要时追问、图片结合上下文。Prompt 不能修改鉴权、总开关、按钮授权和人工状态，不因为模型不确定自动接管。

## 4. 多知识库及真实索引

`knowledge/catalog.json` 的 `schema_version=2`，每库有稳定 `kb_*` ID、中文名称、enabled、revision、documents、status、last_sync、error。文档有稳定 `doc_*` ID、原名、source、projection、sha256；sources 为原文，投影名包含归属避免跨库同名覆盖。

所有启用库共同用于一个 `ANYTHINGLLM_WORKSPACE`（默认 `crisp-support`）；停用库保留原文但移出新检索，删除指定库/条目不改其他库。相同库同名文件更新原条目；跨库相同内容保持独立引用与所有权。每库最多 10000 条、最多 100 库、单文档 50 MiB 是实际校验边界，不承诺无限资源。

`data/knowledge-manifest.json` 保存 hash、远端文档位置和 pending/garbage 对账；`data/runtime/knowledge-map.json` 仅将已启用的有效位置映射回库/文档。上传、workspace 加入和索引回读分开处理。超时但服务端继续索引时保留 pending，重跑同步有限对账，不立即删远端工作。

默认目录升级幂等迁移为 `kb_default`，保留原映射，避免重装重复 N 份。删索引不会擦除旧聊天中已经出现的知识；事实变更以当前库优先，冲突时应澄清，不拼接矛盾政策。检索预览应看中文问题结果与来源，不凭模拟 Provider 的固定回答判断检索质量。

## 5. 关键词、菜单与人工控制

`keyword.yaml` 使用 `schema_version=2` 和 `rules[]`。字段为 id/name/enabled、keywords、exclude_keywords、match_mode（contains/exact）、priority、cooldown_seconds、offer_ttl_seconds、action、正文和按钮文案。人工动作只有 `show_handoff_offer`，不能配置关键词直接暂停。新装人工按钮模板启用，排除明确否定，默认冷却 60 秒、TTL 600 秒。

每张卡片保存随机 offer、网站+会话、fingerprint、允许 choices、配置/会话代次、有效期与消费状态。关键词本条仅展示 picker，不附普通 AI 答案；未来普通问题继续 AI。合法点击原子消费并先暂停再确认；取消、未知、跨会话、过期、重复和纯文本冒充都不能暂停。`message:updated` 使用事件类型+选择摘要去重，不因同 fingerprint 已见而丢弃。

只有有效确认按钮或真实人工公开回复自动进入 human。控制状态 key 为网站+session 的 hash，保存 mode、generation、last_human_at、resume_at、pause_reason 及控制水位；全局 enabled 不写成共享会话模式。`handoff.resume_after_seconds` 新装 1800，0 永久；真人新公开回复重计、访客/机器人/重复旧事件不重计。到期递增代次并只处理新消息，5 秒持久扫描加惰性校验，不发恢复通知。

普通任务在模型前记录 revision/generation，模型后与发送前复核；可信人工控制先落盘，不等待长请求。尚未 POST 的旧结果作废，不能保证撤回远端已经接收的 POST。人工状态不按普通缓存期限淘汰。

## 6. 欢迎、反馈、标签

`menu.yaml` 的 welcome 默认 `enabled=true/trigger=first_message/auto_open=false/show_menu=true`。另支持 widget_load/chat_open，需无密钥 SDK + `session:sync:events`。菜单树用 root/menus/options，动作 reply/prompt/menu/show_handoff_offer；返回父级用受限 back 标记，普通下级禁止环，深度最多十层。

`feedback.yaml` 定义启停、提示、正负文案、有效期及保留；反馈绑定已发送回答并防重复，“否”只有存在有效反馈上下文时才消费。负反馈不接管。`retention_days` 默认 30，允许 1～3650；调度检测保留期变化后执行清理，平时每小时检查，范围仅统计活动文件及五份轮转，不删除人工状态。默认 `retain_text=false`，不留明文问题，仅保留限长指纹/脱敏摘要。

`tags.yaml` 的 `ai_replied` 表示已回复，不自动 resolved。标签读取现有 segments 后并集写回，失败跳过，不中断正文。知识命中使用实际 sources；可观察查询才参与命中分母，未知单列，按库来源归属但每问题总数只计一次。

## 7. Crisp 与安装事实

Token tier 与 Hook mode 分开；Website URL Secret、Plugin Signing Secret、Crisp API Key互不替用。`.env` 中 PUBLIC_WEBHOOK_URL 为 base，WEBHOOK_PRODUCTION_URL 为最终生产路由。受管 HTTPS/已有反代仅公开 Hook 与无秘密 SDK/UI 配置，详见 [CRISP](CRISP.md)。

安装 marker 保存单一分层 facts；runtime 收件/往返观察绑定当前凭据与 Hook，不能拿旧账户记录或协议模拟端点变成真实 Crisp 通过。菜单 10→12 读取观察，doctor 合并实际结果。收到 Hook、REST 可用、公网可达、真实回答成功是不同检查。

## 8. 导出、升级和恢复

业务包 `ai-support-business-v2` 包含非敏感 Provider、所有业务配置、Prompt、多库原文、workflow模板、版本和 SHA 清单；排除 `.env`、秘密 Header 和会话。导入前完整校验与数字确认，保留本机秘密，自动应用后回读；失败恢复旧配置。包上限压缩 128 MiB/展开 512 MiB，不能在导入时执行其中的代码。

本机快照 `ai-support-snapshot-v3` 与完整备份包含 `.env`、PostgreSQL dump、AnythingLLM/n8n/runtime、程序配置和历史镜像身份；用于可信本机一致性恢复。旧 v2 快照按原边界兼容，不假称其含后来新增的秘密和状态。升级保留旧自定义设置，将 handoff 动作迁移成按钮、单知识迁移默认库；不统一重置人工。密钥和数据恢复保护见 [SECURITY](SECURITY.md)。
