# 配置、应用与迁移契约

正常操作使用 [18 项 Shell 菜单](MENU.md)。v1.2.0 也支持管理员在稳定路径编辑已有资料，再用 `crispai apply --check` / `crispai apply` 校验和应用。本页说明哪些是可编辑原文、哪些是程序管理的生效状态；示例只含虚构内容。

## 1. 权威源和生效机制

程序生成的业务 `.yaml` 使用 JSON 语法（也是合法 YAML）；也可编辑为普通 YAML，保留现有 schema 和英文字段名。资料应用、菜单读取及业务导出共用严格规范化，拒绝重复键和无效结构，不执行用户文字。`.env` 使用严格解析和序列化，不 `source`、不 `eval`，特殊字符 `$ # = 引号 反斜线` 不再被 Compose 意外插值。公开 `.example` 只用于首次生成，升级不覆盖合法自定义配置。

| 菜单 | 落盘位置（相对部署目录） | 消费者/生效与验证 |
| --- | --- | --- |
| 3 AI | `.env`、`config/provider.yaml` | 宿主探测 + 适配器/AnythingLLM/n8n；实际容器调用后提交代次，失败恢复旧值 |
| 4 Prompt | `config/prompt.md` | 可编辑原文；成功应用后更新 workspace openAiPrompt 和受管生效投影，下一次新问题使用该版 |
| 5 知识 | `knowledge/catalog.json`、`kb_*/sources`、`data/knowledge-manifest.json` | 全部启用库投影到一个 workspace；实际文档/索引回读与来源映射 |
| 6 规则 | `config/keyword.yaml` | 应用进入受管投影后由 runtime 每事件读取；schema、边界、容器回读，无需全栈重启 |
| 7 人工 | `config/handoff.yaml`、`data/runtime/session-*.json` | 默认秒数供新接管使用；单会话 CLI 使用同一事务状态 |
| 8 总开关 | `config/runtime.yaml` | 应用后的投影供事件处理和发送前读取，代次使旧任务失效，不停止服务 |
| 9 欢迎/菜单 | `config/menu.yaml` | runtime 与白名单公开配置路由；网页只读允许的 UI 字段 |
| 10 Crisp | `.env`、受管反代片段 | n8n 重载与 REST/Hook/收件事实复核，不重生 workspace |
| 11 标签/反馈 | `config/tags.yaml`、`config/feedback.yaml` | runtime 与 `data/analytics`，正文发送与可选标签分离 |
| 12 业务迁移 | 用户选择的受限 `.tar.gz` | schema/checksum/预览→备份→同步→回读，保留本机秘密 |
| 13/14 本机恢复 | `backups/versions`、完整备份包 | 数据库、应用文件与镜像身份一致性恢复 |
| 15 日志 | `config/logging.yaml`、受管日志及 systemd timer | 文件历史按天清理，Docker 容量轮转，n8n pruning；预览、确认、实际回读 |
| 16 资料应用 | `config/materials-applied.json` | 程序维护的当前有效投影，供 runtime 消费；包含 Prompt，禁止手改或公开 |

`runtime.yaml` 使用 `schema_version: 2`、布尔 `enabled`、单调 `revision`、`applied_revision`。v1.2.0 由 `materials-applied.json` 保存已验证的配置、Prompt、知识版本和状态；运行时不把尚未完成的可编辑原文当作新一代配置。实际组件回读成功才标 `applied`，失败不能只输出“文件已保存”。总开关/人工控制不等待付费模型探测，原有开关和逐会话人工状态不会被普通资料应用重置。

配置历史保存于受限 `backups/config-history`；它可能包含旧秘密、Prompt 或知识，不能上传。维护操作共用实例锁；空闲菜单不长期持锁。会话控制使用独立短临界区，不能锁着等 LLM 请求。不要在第三方 Web UI 随意修改受管 Prompt、索引或生产 workflow；先用 doctor 定位偏离，再从对应生产维护入口恢复。

### 稳定资料路径与应用顺序

菜单 `16 → 8` 显示本实例绝对路径和待应用状态。默认根目录为 `/opt/crisp-ai`，自定义部署以实际输出为准：

| 路径 | 管理员怎样使用 |
| --- | --- |
| `config/prompt.md` | 直接编辑已有 UTF-8 Prompt 原文，或用菜单 4 导入/粘贴。 |
| `config/runtime.yaml`、`handoff.yaml`、`keyword.yaml`、`menu.yaml`、`tags.yaml`、`feedback.yaml` | 保留现有 schema 和英文字段；用菜单修改最稳妥，直接编辑后统一校验应用。 |
| `knowledge/catalog.json` | 库名、启用状态、稳定 ID、文档登记的权威定义；保留已生成的 ID、source、projection，不把任意文件名改成路径。 |
| `knowledge/kb_*/sources/doc_*.md` 等 | 原始知识内容；可原位更新已登记文件。新增/删除条目使用菜单 5，由程序维护登记和归属。 |
| `config/materials-applied.json` | 已生效投影，程序管理、不可手改；包含有效 Prompt 正文，不是可公开的状态报告。 |
| `data/knowledge-manifest.json`、`data/runtime/knowledge-map.json` | 真实索引对账和检索归属，不是用户输入；不要手动清空。 |
| `backups/config-history/materials.applied.tar.gz` | 上一有效资料的恢复副本；含业务原文，受限保存。 |

直接编辑已有资料后的完整操作：

```bash
crispai apply --check
crispai apply
crispai doctor --local
```

`--check` 只验证候选、权限、UTF-8、schema、路径与大小，不改原文、不同步索引或调用模型。普通 `apply` 在原文未变时快速结束；有变化时验证全部候选并保存上一有效版。需要更新 Prompt/知识时进入 `applying`，使旧任务代次失效，同步完成并真实回读后发布新 revision。慢同步期间新问题不自动回复，也不在完成后补答；人工控制仍独立处理。菜单等价入口为 `16 → 6 → 1`，状态用 `16 → 8`。底层复用 `scripts/materials.sh` 的 `status | validate | initialize | apply`；`initialize` 是安装/升级建立首份投影的内部接口。

若 doctor 发现 AnythingLLM 中的 Prompt 或受管索引关系偏离，而原文没有变化，用 `crispai apply --force-external` 或 `16 → 6 → 2` 明确重新同步现有 Prompt 和启用知识并回读；知识仍按增量对账，不默认重建全部索引。它确认受管文档的位置和启停关系，不能证明同一远端 location 的解析正文逐字未被外部篡改，也不删除本项目 manifest 之外的文档。确需从原文重建索引用 `5 → 11`，先确认作用范围与耗时。强制同步同样先校验当前可编辑原文，未完成的修改必须先修正。生产 workflow 不属于资料应用，工作流损坏按[排障说明](TROUBLESHOOTING.md)修复。

尚未保存完的坏 JSON、无效 YAML、空 Prompt、超限原文只会让校验失败，旧有效投影和旧索引继续服务。开始同步后若失败，程序尝试恢复上一个有效 Prompt/索引和投影；直接编辑的原文保留为待修正候选。菜单的候选提交失败会恢复该菜单修改的原文。若外部恢复也未确认，自动回复保持阻止状态，按错误提示修复后重试或成套恢复，不能手改投影为 `applied`。

`status` 中 `source_valid=false` 说明原文无效；`pending=true` 表示有效原文与有效投影不同，或投影尚未处于 `applied`。`state=applied` 和对应应用代次才代表已发布。把新文件直接塞入 `sources` 而不登记会被拒绝；新资料用 `5 → 4/5` 添加。资料数量/原文字节改变后 hash 和索引由程序重算，不手工制造校验值。

## 2. Provider、协议与网络

`AI_API_PROBE_BASE_URL` 是宿主探测地址，`AI_API_BASE_URL` 是容器可达供应商地址；本机地址映射为 `host.docker.internal`，合法代理路径保留，不重复追加 `/v1`。`AI_API_KEY` 与 `AI_CUSTOM_HEADERS_JSON` 只在 `.env`；后者允许有限安全请求头，不能覆盖 Authorization/Host/Content-Length 等管理字段。

`provider.yaml` 记录 `schema_version: 2` 与 `provider.base_url/model/api_mode/capabilities/api_key_env` 等非秘密元数据，模型列表缓存与当前候选凭据摘要绑定，不保存明文 Key。管理员选择 `chat_completions` 或 `responses` 后必须得到有效正文；HTTP 200、模型 ID 或列表成功不能代替能力测试。

AnythingLLM 固定使用 `generic-openai`，内部 Base 为 `AI_ANYTHINGLLM_BASE_URL=http://provider-adapter:8787/v1`。适配器复用固定镜像中的 Node，仅提供项目所需 Chat→Responses 转换或 Chat 转发，不是另一套 RAG。容器内部接口仍鉴权，不公开端口；生成请求有输出/内容上限、超时与取消。实际调用必须与 `api_mode` 一致。

图片走同一 Provider 的已验证文本/图片协议，带当前 Prompt 与同会话公开历史；不能支持时安全请求文字补充，不转人工。图片 URL 下载保护见 [SECURITY](SECURITY.md)。默认本地 Embedder由 AnythingLLM 管理，不需要另外的 API Key，不把聊天模型当 Embedding。升级已有模型设置须考虑全索引重建，不能只改显示名称。

`data/runtime/session-*.json` 中的可选 `image_context` 保留最多 3 份视觉摘要，每份 2000 字符、24 小时；后续问答只有匹配该会话近期公开附件才使用，避免依赖模型在公开回答里复述全部细节。它是受限会话数据，不是业务配置，不导出至迁移包；旧会话无此字段仍兼容，不重置原人工状态。

## 3. Prompt

`config/prompt.md` 保留原文，不加入内部版本号或 hash。文件、单行、多行粘贴和应用上限均为 262144 个 UTF-8 字节（256 KiB）；空、全空白、无效 UTF-8 或 NUL 拒绝覆盖。菜单保存会应用并回读；直接编辑则必须显式 `apply`。n8n 使用已发布投影中的正文。当前 conversation 的新问题使用新 Prompt，公开历史仅作背景，不能覆盖当前知识与系统护栏。

默认规则要求知识优先、不编造、不泄露内部配置、不声称执行未做操作、必要时追问、图片结合上下文。Prompt 不能修改鉴权、总开关、按钮授权和人工状态，不因为模型不确定自动接管。

## 4. 多知识库及真实索引

`knowledge/catalog.json` 的 `schema_version=2`，每库有稳定 `kb_*` ID、中文名称、enabled、revision、documents、status、last_sync、error。文档有稳定 `doc_*` ID、原名、source、projection、sha256；sources 为原文，投影名包含归属避免跨库同名覆盖。

所有启用库共同用于一个 `ANYTHINGLLM_WORKSPACE`（默认 `crisp-support`）；停用库保留原文但移出新检索，删除指定库/条目不改其他库。相同库同名文件更新原条目；跨库相同内容保持独立引用与所有权。导入目录中的同名文件即使来自不同子目录，也会被拒绝，先重命名以免归属混淆。

以下是生产校验上限，不是建议上传量或机器容量保证；模型上下文窗口、token 计费和向量检索质量另受实际模型/资源影响：

| 入口或对象 | 实际限制 |
| --- | --- |
| Prompt 文件/单行/多行/直接应用 | 1～262144 字节（256 KiB），有效 UTF-8，拒空白和 NUL。 |
| 向导或菜单粘贴知识 | 最多 8388608 字节（8 MiB），含每行换行；更大资料用文件导入。 |
| 单文档导入、直接应用、迁移 | 1～52428800 字节（50 MiB）；MD/TXT/PDF/DOCX，格式也要通过预检。 |
| 知识目录导入 | 最深 16 层、扫描成员最多 20000 个、普通文件最多 10000 个；拒绝链接、控制字符和危险文件名。目录中的不支持格式不入库，所有普通文件仍计入扫描上限。 |
| 知识定义 | 最多 100 库、每库 10000 条；库名最多 100 个 UTF-8 字节、文档名最多 255 字节。 |
| 应用配置与运行投影 | 每份业务配置最多 1 MiB、catalog 最多 512 MiB、运行投影/来源映射最多 16 MiB；这些上限不能用来绕过文档/库数量限制。 |
| 业务迁移归档 | 压缩包最多 128 MiB、总展开最多 512 MiB、最多 20000 个成员；还须通过全部内容校验。 |

字节与字数不同：`人工客服` 是 4 个汉字、12 个 UTF-8 字节；Emoji 和换行也占字节。`wc -c < '资料.md'` 查看实际文件字节数，不等于模型 token 数。PDF 头或 DOCX 容器校验成功只说明可以进入解析尝试，不保证文档可提取文字；扫描 PDF 未做 OCR 时应先转文字，再检查真实索引和来源。

`data/knowledge-manifest.json` 保存 hash、远端文档位置和 pending/garbage 对账；`data/runtime/knowledge-map.json` 仅将已启用的有效位置映射回库/文档。上传、workspace 加入和索引回读分开处理。超时但服务端继续索引时保留 pending，重跑同步有限对账，不立即删远端工作。

默认目录升级幂等迁移为 `kb_default`，保留原映射，避免重装重复 N 份。删索引不会擦除旧聊天中已经出现的知识；事实变更以当前库优先，冲突时应澄清，不拼接矛盾政策。检索预览应看中文问题结果与来源，不凭模拟 Provider 的固定回答判断检索质量。

## 5. 关键词、菜单与人工控制

`keyword.yaml` 使用 `schema_version=2` 和 `rules[]`。字段为 id/name/enabled、keywords、exclude_keywords、match_mode（contains/exact）、priority、cooldown_seconds、offer_ttl_seconds、action、正文和按钮文案。人工动作只有 `show_handoff_offer`，不能配置关键词直接暂停。新装人工按钮模板启用，排除明确否定，默认冷却 60 秒、TTL 600 秒。直接编辑后的规则与其他资料一样，应用成功才被 runtime 使用。

每张卡片保存随机 offer、网站+会话、fingerprint、允许 choices、配置/会话代次、有效期与消费状态。关键词本条仅展示 picker，不附普通 AI 答案；未来普通问题继续 AI。合法点击原子消费并先暂停再确认；取消、未知、跨会话、过期、重复和纯文本冒充都不能暂停。`message:updated` 使用事件类型+选择摘要去重，不因同 fingerprint 已见而丢弃。

只有有效确认按钮或真实人工公开回复自动进入 human。控制状态 key 为网站+session 的 hash，保存 mode、generation、last_human_at、resume_at、pause_reason 及控制水位；全局 enabled 不写成共享会话模式。`handoff.resume_after_seconds` 新装 1800，0 永久；真人新公开回复重计、访客/机器人/重复旧事件不重计。到期递增代次并只处理新消息，5 秒持久扫描加惰性校验，不发恢复通知。

普通任务在模型前记录 revision/generation，模型后与发送前复核；可信人工控制先落盘，不等待长请求。尚未 POST 的旧结果作废，不能保证撤回远端已经接收的 POST。人工状态不按普通缓存期限淘汰。

## 6. 欢迎、反馈、标签

`menu.yaml` 的 welcome 默认 `enabled=true/trigger=first_message/auto_open=false/show_menu=true`。另支持 widget_load/chat_open，需无密钥 SDK + `session:sync:events`。菜单树用 root/menus/options，动作 reply/prompt/menu/show_handoff_offer；返回父级用受限 back 标记。最多 100 个节点，每节点最多 12 个选项（含配置中的返回项），从根最多向下跳转 8 次；普通下级禁止环和无效引用。

`feedback.yaml` 定义启停、提示、正负文案、有效期及保留；反馈绑定已发送回答并防重复，“否”只有存在有效反馈上下文时才消费。负反馈不接管。`retention_days` 默认 30，允许 1～3650；调度检测保留期变化后执行清理，平时每小时检查，范围仅统计活动文件及五份轮转，不删除人工状态。默认 `retain_text=false`，不留明文问题，仅保留限长指纹/脱敏摘要。

`tags.yaml` 的 `ai_replied` 表示已回复，不自动 resolved。标签读取现有 segments 后并集写回，失败跳过，不中断正文。知识命中使用实际 sources；可观察查询才参与命中分母，未知单列，按库来源归属但每问题总数只计一次。

## 7. Crisp 与安装事实

Token tier 与 Hook mode 分开；Website URL Secret、Plugin Signing Secret、Crisp API Key互不替用。`.env` 中 PUBLIC_WEBHOOK_URL 为 base，WEBHOOK_PRODUCTION_URL 为最终生产路由。受管 HTTPS/已有反代仅公开 Hook 与无秘密 SDK/UI 配置，详见 [CRISP](CRISP.md)。

安装 marker 保存单一分层 facts；runtime 收件/往返观察绑定当前凭据与 Hook，不能拿旧账户记录或协议模拟端点变成真实 Crisp 通过。菜单 10→12 读取观察，doctor 合并实际结果。收到 Hook、REST 可用、公网可达、真实回答成功是不同检查。

## 8. 导出、升级和恢复

业务包 `ai-support-business-v2` 包含非敏感 Provider、业务配置、Prompt、多库原文、workflow模板、版本和 SHA 清单；排除 `.env`、秘密 Header、会话和本机日志策略。导入前完整校验与数字确认，保留本机秘密，自动应用后回读；失败恢复旧配置。包上限压缩 128 MiB/展开 512 MiB，不能在导入时执行其中的代码。v1.2.0 的普通 `backup.sh` 在存在 catalog 时也复用同一完整多库业务导出；`restore.sh` 识别该格式后走同一导入/应用链。`--skip-restart` 仅供旧业务包离线兼容，不会让新版业务包跳过真实应用回读。

本机快照 `ai-support-snapshot-v3` 与完整备份包含 `.env`、PostgreSQL dump、AnythingLLM/n8n/runtime、程序配置和历史镜像身份；用于可信本机一致性恢复。旧 v2 快照按原边界兼容，不假称其含后来新增的秘密和状态。升级保留旧自定义设置，将 handoff 动作迁移成按钮、单知识迁移默认库；不统一重置人工。密钥和数据恢复保护见 [SECURITY](SECURITY.md)。

## 9. 日志保留与实际应用

`config/logging.yaml` 保存运维日志策略及应用代次。新装默认 7 天、每份 10 MiB、最多 5 份；v1.1.x 升级缺失新字段时保留旧 Docker 3 份语义，已有合法自定义策略优先。允许天数 1～3650、单份容量 1～1024 MiB、份数 1～20。容量轮转的份数包含当前文件，例如 5 份表示当前文件加最多 4 份历史；自检历史是独立快照集合，最多保留该数量。通过 `15 → 6` 预览并确认后，程序写入项目 Compose 参数、重建本项目容器，并回读每容器 logging 配置及 n8n 环境；只改文件不算生效。

文件维护日志/诊断历史按到期时间清理；Docker 仅使用 `max-size`/`max-file` 容量轮转，不提供精确 N 天保留承诺，也不直接改 Docker `LogPath`。n8n 执行数据由官方 pruning 处理，成功与失败执行正文默认均不保存，保留上限按天数换算小时。运行任务/WAL、人工状态、统计和知识原文均不属于运维日志清理范围；统计保留仍由菜单 11 单独控制。依据：[Docker JSON 日志驱动](https://docs.docker.com/engine/logging/drivers/json-file/)。

系统级 `crispai-log-maintenance-*.timer` 按实例目录绑定，开机约 5 分钟后和随后每小时调度，并有最多 5 分钟随机延迟；不依赖管理员 SSH 在线或临时用户 cron。用 `crispai logs status` 查看归属、启用状态、最近和下次调度及清理摘要；`doctor` 默认只读核对。设置成功不等于已经发生一次真实清理，部署验收须看到实际调度结果。
