# 测试与验收

本章供维护者复现测试；正常管理员使用[在线安装命令](INSTALL.md)和 `crispai doctor`，不需要准备开发用 E2E 环境变量。v1.2.1 当前完成度见[发布说明](releases/v1.2.1.md)，最终数量由该版报告及独立发布回执记录；公开仓库中的 [v1.2.0 报告](https://github.com/statusX7/ai-support/blob/main/docs/reports/v1.2.0-report.md)仅是历史证据，数字不累计。

## 层级与门禁

| 层级 | 能证明什么 | 不能替代什么 |
| --- | --- | --- |
| STATIC | Bash/ShellCheck、schema、工作流引用、Compose 解析、归档、密钥扫描 | 容器运行、依赖实际安装 |
| UNIT/CONTRACT | 生产函数、Shell/PTY、事件 fixture、协议服务、可控时钟的分支 | 真实 Crisp、真实模型或真实向量检索 |
| REAL-LOCAL | 真实 Docker、PostgreSQL、AnythingLLM、n8n、实际索引、生产入口和归档安装 | 用户自有公网/账户授权 |
| PUBLIC-DISTRIBUTION | 无认证读取公开 repo/raw/Latest/固定资产并执行推荐命令 | Crisp/模型外部业务 E2E |
| TARGET-A | 本轮授权故障机上的命令、组件、候选/正式包与恢复验证（公开仅用代号） | 另一台机器或没有发生的客户往返 |
| REAL-EXTERNAL | 真实 Crisp 测试访客、真实第三方模型、公网 HTTPS 与实际页面 | 合成 Hook、仅 REST 写权限、构造的真人事件；旧套件名 EXTERNAL-E2E 保留兼容 |

真实空机引导作为 REAL-LOCAL 的独立硬门槛报告：初始无 Docker/Compose，生产安装器自行补齐。不得挂宿主 Docker socket、隐藏 PATH、手工先装 Docker或复用旧版本报告冒充本次实测。协议服务可以配合真实本地应用，但须写为“真实应用 + 模拟 Crisp/Provider”，不能写为“真实模型回答通过”。

运行主驱动的计数与单项复跑分开；嵌套脚本中的多条断言不重复累加到主驱动总数。跳过或证据不足不计通过，失败修复后记录最后复跑及原始原因。

v1.2.1 发布顺序是硬门槛：完整冻结候选先完成本地真实组件与授权 TARGET-A 验收，之后才能 push、tag、创建草稿或上传 Release 资产；不能先发一个待验证版本再拿目标机补票。发布后的匿名下载/空机安装和 TARGET-A 正式同包核对仍要做，但不能替代发布前目标机门槛。

## 自动测试

从开发仓库运行：

```bash
bash tests/run.sh
bash tests/test_get.sh
bash tests/test_doctor.sh
bash tests/test_public_distribution.sh --local
bash tests/test_manage_contract.sh
bash tests/test_wizard.sh
bash tests/test_provider_menu.sh
bash tests/test_caddy_callers.sh
bash tests/test_caddy_routing.sh
node tests/test_configuration_protocol.js
bash tests/test_workflow_contract.sh
bash tests/test_workflow_runtime.sh
node tests/test_provider_adapter.js
node tests/test_provider_pool.js
node tests/test_feedback_runtime.js
node tests/test_crisp_auth.js
node tests/test_knowledge_context.js
node tests/test_knowledge_lexical.js
node tests/test_knowledge_hybrid.js
node tests/test_knowledge_runtime.js
python3 tests/test_knowledge_profile.py
bash tests/test_knowledge_profile_integration.sh
python3 tests/test_launcher.py
python3 tests/test_docs_acceptance.py
python3 tests/test_rag_context.py
python3 tests/test_snapshot_live.py
node tests/test_materials_apply.js
node tests/test_material_limits.js
bash tests/test_logs.sh
```

生产发布归档包含可复现的测试源码，不包含开发工具二进制、运行日志或私密测试配置；普通安装不执行测试驱动。主驱动自行枚举当前正式专项，避免人工漏跑。

ShellCheck、PTY 驱动和 Node.js 是维护者测试依赖，不是宿主客服运行依赖。普通安装所需的 Python 3/PyYAML、jq、Docker/Compose 等仍由生产安装器补齐。主驱动对全部生产脚本逐文件执行 ShellCheck `-x`；两个会递归载入整套 doctor 夹具的测试驱动改做非递归静态检查，其引用的生产模块仍独立 `-x` 检查，且后续动态专项会真实执行完整夹具。这样可避免 4 GiB 验收机与真实组件并存时出现分析器内存峰值，同时不减少生产文件、规则或动态失败项。

`test_docs_acceptance.py` 独立核对活跃链接、唯一推荐命令原样、18 项菜单标题、帮助/版本的无副作用执行，以及资料限制和反代日志文档接线；不执行在线安装，也不能替代真实组件与 Crisp 验收。资料应用及强制同步的生产 PTY 分支由 `test_manage_contract.sh` 覆盖。

`test_wizard.sh` 覆盖 `collecting` 状态再次进入时的继续、重新开始和取消：继续必须从记录步骤恢复；重新开始只能删除身份、权限、链接数、命名和目录都属于该向导的临时草稿，不能碰正式配置、知识或外部链接目标。`test_provider_pool.js` 与 `test_provider_menu.sh` 分别核对 `/api`→`/api/v1`、已有 `/api/v1` 不重复、候选验证/原子回读/失败恢复，以及九类安全中文错误；模型列表夹具不能替代最终 Chat/Responses 推理验证。

`test_caddy_callers.sh` 以调用契约检查 Crisp 设置与恢复流程：候选须在提交/停服前验证，运行对账失败须恢复旧 `.env`、Caddyfile 与模式，恢复完成前不能报告成功。`test_caddy_routing.sh` 使用真实 Caddy 容器核对配置语法、路由、last-good、原子替换后的挂载摘要、失败回滚和 `managed_https`↔`external_proxy` 转换；这只证明本项目受管反代，不替代公网 DNS、ACME 证书或管理员已有外部站点验收。

`test_provider_log_redaction.py` 只用虚构秘密核对有效/历史/草稿代次的原文与编码、持续查看轮换、读取上限及异常失败关闭；`test_logs.sh` 通过生产导出路径验证诊断包排除秘密，并在隔离副本故意关闭首道过滤，确认二次扫描独立拒绝。它们不是实机日志或真实凭据泄漏测试。

消息外观须用专用 SDK 实际 DOM 核对中性昵称、正文与平台徽标，截图原件受限保存。新出站省略可选 automated 字段后，仍须验证发送前自有指纹落盘、重启/详细记录清理后的自回流识别、跨会话隔离以及真正后台人工回复；不能把旧带徽标消息的观察当作新发消息已去标识。

追加回归覆盖缺省 automated/type 的真实操作者结构、即时暂停、默认 3600 秒与显式旧值/0 秒保护；网站级 REST 写入不冒充后台真人。旧错误计划和有效响应中的精确旧默认整句均不能作为答案出站；图片失败不写入成功识图记忆。窗口事务测试包含原文/有效投影、组件实际预算、失败恢复、期间问题按新代恢复一次、真人或总关时取消，以及全文 Prompt 保真；上述 helper 合成测试不代替真实 AnythingLLM 回读。在线快照测试验证消失的临时锁与权限/链接/特殊文件错误的区别，真正停写后的复制仍须严格检查。

`test_feedback_runtime.js` 还直接驱动生产 `send()` 的未知回执恢复：列表滞后但精确 fingerprint 已存在时，文字及 picker 均不得再次 POST；远端确定缺席须经过两次至少间隔 5 秒的精确负查，精确 404 与 200 空结果都覆盖；鉴权、服务或网络查询失败保持原任务且零补发；五分钟耗尽须写入脱敏 `delivery_failed`。人工确认通知另验证 human 模式下的同指纹恢复，以及总开关/代次变化仍禁止补发。这些是 Crisp 协议夹具，不是远端平台绝对 exactly-once 保证。`workflow-runtime.test.js` 另在缺少原生 `AbortController` 的 Code 沙箱运行生成核心，避免宿主 Node 测试掩盖生产 n8n 全局差异。

人工控制容量专项保留旧代码在 128 条积压时返回 503 的负例；修后验证 127/128 普通队列、混合/纯控制及未知身份对账积压、总开关和窗口事务保护。确定真人不等待网络或普通队列，迟到答案不能出站；有效按钮只允许一个第 129 个优先确认，重复/过期/跨会话/伪造选择不能占用，未终态时手动恢复也不能不断新建人工 offer。原有未知发送和控制任务保持，普通及未知身份请求仍有容量限制。

`node tests/test_runtime_missing_reply_p0.js` 直接驱动生产 runtime：验证写前字节背压不覆盖旧状态、旧高水位仍优先落盘真人暂停、坏 JSON/超限/坏 envelope 及内层 `outgoing.body` 只隔离所属会话、operator 重试耗尽和旧孤儿屏障恢复、单会话不挤占整批、超过 16 个会话跨重启公平轮转、控制优先仍保留普通名额、scheduler 心跳重建和 scan lock 崩溃残件/并发所有权。全局配置损坏的对照仍必须让扫描失败，不能被错误降格为单会话隔离。

`test_feedback_runtime.js` 的图片阶段回归先保留旧请求失败：前问仍作为活动用户消息时，受控契约夹具返回前问答案。修后分别检查 Chat/Responses 的独立事实提取指令、原 Prompt、真实图像字段、只读历史和同会话摘要/重启后指代；另测视觉期间真人或总开关取消后不保存摘要、不续 RAG、不出站。这是请求/状态契约证据，不是视觉模型能力测试。实机必须另外核对原图可见内容、模型摘要及最终回复，不能仅凭非空或 HTTP 200 通过。

`node tests/test_knowledge_context.js` 与 `node tests/test_knowledge_runtime.js` 验证固定 `/vector-search` 的实际结构、纯当前问题、完整片段与 Prompt、启用来源归属、上下文隔离、检索中人工取消及管理员同链。`test_knowledge_lexical.js` 实际从虚构 parsed 正文构建/验证补召回索引；当前 28 组还覆盖紧义中文同义改写、双问句/礼貌前缀，以及引用、元指令、混合主题、城市/品牌/编号/孤立字符冲突、危险分隔符和 4096 字节边界。`test_knowledge_hybrid.js` 的 18 组再通过生产 runtime 和生成的 Code node 覆盖 strong 命中跳过向量、非 strong 同义候选仍先走向量且只在 miss 后补充、向量故障降级、长文尾 FAQ、合并去重、部分覆盖、三层篡改、旧投影及生成中真人取消。缺少唯一实体的泛问必须继续走纯向量。测试只用虚构资料；正文断言解析实际 JSON 后逐字比较，不能用转义形式相似代替保真。HTTP 200 错误、未知来源不能算未命中。runtime 热路验证 materials/map/lexical/profile/settings 与迁移门禁；manifest/cache 摘要由 profile 和 Shell 集成套件另行验证，不把两层证据混成“每问实时扫描向量缓存”。

`test_knowledge_profile.py` 与 `test_knowledge_profile_integration.sh` 验证模型/切块代次、完整组件保全、失败恢复、权限和会话状态保护。另在固定真实 AnythingLLM Embedding 环境比较中文原问与改写的排名、token 保留和完整答案片段；多语言模型、400 字符块的实测只证明检索层，最终还必须由真实模型根据送入的事实正确回答。UNIT 协议夹具、真实本地 Embedding 和 TARGET-A 最终回答是三个不同证据层级，不能合并计数。

发布模式必须指定隔离真实部署，不能把本地集成缺失当外部豁免：

```bash
AI_SUPPORT_INTEGRATION_DEPLOY_DIR=/绝对路径/隔离验收实例 \
AI_SUPPORT_RELEASE_TEST=1 \
AI_SUPPORT_EXTERNAL_VALIDATION_PENDING=1 \
bash tests/run.sh
```

通用外部驱动缺少额外测试资源时可单独标 `External Validation Pending`，但不能豁免已授权 TARGET-A 的真实候选门槛，也不能把失败写成未配置。STATIC、UNIT/CONTRACT、REAL-LOCAL 的关键失败或跳过阻止发布；上述环境变量不改变已执行测试的失败结果。

`tests/test_deployment_integration.sh` 检查真实目录归属、容器、应用健康和工作流，但单独一次错误 Secret 的 401 不证明正确消息能回复；还必须执行下面的真实故事及归档生命周期验收。

`tests/workflow-local-integration.js` 使用受限测试配置连接真实 n8n 和隔离协议服务，覆盖按钮、两会话、真实计时、重启、在途取消及发送未知对账。`tests/test_web_chat_browser.js` 在真实 Chromium 中运行生产 SDK 片段，通过实际 n8n 公共路由和 Hook 核验欢迎/展开的七种控制场景；它使用合成 Crisp SDK，不冒充真实 Crisp 页面。后者仅供维护者，依赖 Chromium、Node.js、`ws` 和 OpenSSL，测试配置、浏览器 profile 与 localhost TLS 密钥均留在被忽略的受限工作目录。

## 最小真实验收故事

在支持 Docker 的隔离 Debian 12 amd64 VM 创建无配置环境，保存发行版、架构、PID 1、初始包清单和命令可用情况。测试数据全部虚构，禁止录制密钥或真实客户正文。

1. 在无登录的干净 VM 原样执行 README/INSTALL 中同一条推荐命令，由入口取得并校验最终正式包，PTY 自动进入安装器。文件来源快速路径记录十个主要输入，确认后额外必答为零；多行粘贴逐行计数，不把输入行数误称十次按键。
2. 确认安装器实际安装缺失包、Docker/Compose，启用 daemon 并运行容器；自动创建内部 Key/workspace，读回 Prompt、文档索引和已发布工作流。
3. 从 `/`、`/tmp` 和新 shell 调用 `crispai`。通过真实菜单换配置、粘贴中文 Prompt，检查当前 AnythingLLM Prompt 与容器内配置一致。
4. 创建“订阅使用”“电脑排障”“手机排障”三个命名库；使用有效 MD/TXT/PDF/DOCX。分别用完整 FAQ 原问与中文同义改写走菜单 5 的同一生产问答链：原问强命中可跳过向量，改写必须保留真实向量路径；核对来源正文和最终答案都采用明确事实。停用其中一库后重测，该库不得出现于新来源。不以协议模型固定答复作为检索证据。
5. 停用中间库、更新同名文件、重同步、重新启用、单库重建、删除条目；确认其他库的文档映射未被覆盖或误删。
6. A/B 两位测试访客正常聊天。A 输入“人工”仅见原生 picker，不点继续业务问答仍有 AI；A 点击确认后仅 A 暂停并收到一次确认，B 持续正常。
7. 设置 10 秒恢复；真人再次公开回复 A 更新 A 截止时间。用慢模型验证人工事件已落盘后旧结果不出站；访客消息不重置计时，期限到后只答新问题。
8. 重启后检查人工状态、截止时间、未过期 offer；另测 0 秒永久人工、旧按钮回放、重复/乱序事件和跨会话伪造。
9. 停用客服：在途结果、关键词和欢迎均静默，仍记录真人事件；重新启用不清空 A 的人工状态、不补答停用期间历史。自动评价邀请无论总开关状态均不得新增。
10. 欢迎启停、加载/打开事件、自动展开分别验证，并比对实际欢迎字段与总开关，不能只看一个 enabled。页面 SDK 不含密钥。普通是/否继续咨询，图片失败和知识未知不转人工。
11. 通过菜单导出完整业务配置和知识原文，校验无秘密，再预览导入、应用并读回；另外验证完整本机备份与故障回滚。
12. 从真实 v1.2.0 正式实例升级到 v1.2.1，保留密钥、Prompt、知识、人工及原有开关，迁移单接口并停用旧评价邀请；在隔离实例测试失败回滚、再次升级、安全卸载、同路径重装、完整清理与同名命令/外部占网保护。不要卸载授权目标机凑测试。更旧版本由明确的回归覆盖，历史实测不算本轮新实测。
13. 从正式 GitHub Release 回下载归档和 SHA256SUMS，重新校验、独立解压并检查入口。报告的验收代码应与发布资产相同。

没有真实 Crisp 时，上述消息故事必须通过真正运行的 n8n 生产 Webhook 和隔离协议服务执行。模拟回复、回调和前端 SDK 的本地测试分别标注，不能称为真实 Crisp UI 或真实第三方模型验收。

## v1.2.1 本轮验收清单

以下是待逐项记录证据的场景分组，不预填通过。F8 + A28 + U12 + R14 = **62 项**；主驱动实际执行数、分组场景数和内嵌断言数不是同一计数，不能相加制造通过数。

| 分组 | 数量 | 必须观察的要点 |
| --- | --- | --- |
| F01～F08 自动评价停用 | 8 | 新装/升级/重复初始化/旧包导入不产生邀请；旧 pending 不消费是/否；保留历史统计、人工 offer、普通任务；迟到/重试计划不带旧后缀。 |
| A01～A28 主备池 | 28 | 1 主20备/停用计数、角色交换、顺序/草稿/秘密分代；文本与图片实际经过同一池；额度/限流/认证/超时/模型错误分类；安全拒绝不切换；两阶段共享时间/次数、冷却、上下文筛选、取消、重启与真实组件链。 |
| U01～U12 中文界面 | 12 | 18 主菜单和菜单3的11项、数字返回/取消、模型翻页搜索、隐藏秘密、欢迎真实回读、失败及部分完成、普通界面无裸结构化正文、显式 JSON 纯净、窄屏/EOF/SIGINT；主提示 30 轮及多行首提示 120 轮即时中断压力覆盖 reader/TTY 清理。 |
| R01～R14 回归与交付 | 14 | 十项主接口初始化、Prompt/知识/人工/图片回归、完整升级与故障回滚、来源/状态/秘密保留、同包 TARGET-A、断开新 SSH、日志真实 timer、隐私与公开分发门槛。 |

主备协议测试使用虚构 Key 和受控服务，覆盖 21 条容量不等于拥有 21 套真实付费账号。真实目标只有单接口时先明确记录；经授权添加的同一账户模型只能证明对应模型/路径，不能冒称独立供应商或独立额度。运行健康、宿主探测或管理测试也不能替代真实 AnythingLLM 文本路径和图片最终回答路径。

候选验收需保存：完整包与成员清单、真实升级前一致快照、源/有效配置前后值、运行容器文件和 active workflow 绑定、普通菜单完整结果、新登录入口、官方 Hook/任务/出站与原 SDK 同指纹关联。故障注入只作用于隔离访客和明确受管候选，不改真实用户 Prompt/知识、不清人工或旧任务，结束后回读并恢复原开关/策略。

新增备用前明确其数据披露和计费授权。先验证安全拒绝属于终态，再在可恢复故障中核对实际下一接口和共享预算；不得向普通客户注入故障，也不得为等一个绿灯循环重发模型问题。每个必要真实请求分别记录是否计费调用、是否同会话收件与未完成原因。

## 保留的 v1.2.0 实机与维护闭环矩阵

以下历史分组继续作为回归参考，不代表 v1.2.1 已执行。每次失败保留脱敏负例、文件/函数根因和复测结果；`--help` 可用不等于客服回复可用。真实目标的 IP、账号、域名、会话身份和业务正文不得写进测试源码、公开日志或报告。

| v1.2.0 ID | 关键可观察断言 | 实际入口/层级 |
| --- | --- | --- |
| R01～R06 | 分别复现 crisp/crispai；root/sudo、新登录、陌生 cwd、坏链接、WARN/EOF/SIGINT；入口完全损坏可同版救援 | `test_launcher.py`、`test_get.sh`、生产 PTY、TARGET-A |
| R07～R10 | 修前保全、候选升级、断开新登录、最终包逐文件核对；保留真实配置和人工状态 | 完整备份/升级器、隔离 VM、TARGET-A |
| I01～I07 | 匿名原样命令、依赖先补、十项/零额外、续装、TTY与坏包、无.git归档 | get/wizard/bootstrap/归档专项、真实 Debian VM、PUBLIC-DISTRIBUTION |
| W01～W05 | 稳定资料路径、UTF-8 bytes/N+1、父链接/递归、编辑应用、坏候选不替换有效版 | materials/limits/wizard 专项及生产菜单、实际 API |
| W06～W08 | 三命名库真实索引/停用/更新、pending 对账、迁移/回滚根目录 inode 与原文保持 | knowledge/protocol/timeout、真实 AnythingLLM、隔离升级/恢复 |
| L01～L05 | 来源/容量、限量查看、follow中断、并发轮转、期限清理与数字取消 | `test_logs.sh`、真实菜单 PTY、系统级 timer 至少一个实际周期 |
| L06～L10 | Docker/n8n独立保留；业务状态不清；假秘密落盘/导出；JSON/时间预算/关闭客服/永久人工 | 日志与 doctor 专项、故障注入隔离 VM |
| C01～C04 | Basic/tier/配对/轮换、错误 HTTP/200错误JSON、最终 Chat/Responses 路由、Crisp 出站字段 | auth/adapter/runtime 专项、真实模型和官方 Crisp 受限测试 |
| C05～C08 | 反代路由次序、DNS代理/TLS/挑战HTML、SDK真实往返、原生picker及更新 | Caddy真实容器对照、TARGET-A/REAL-EXTERNAL |
| B01～B06 | 真人优先/迟到结果取消、A/B与N/0/重启、开关欢迎、图像记忆、失败不handoff、发送未知对账 | runtime全部既有断言、真实n8n协议集成、独立实际访客 |
| P01～P08 | 文档/限制/菜单、旧版升级/坏包回滚/数字卸载、隐私扫描、publicLatest/匿名取包、目标正式内容 | 固定包门禁、隔离VM、公共发行、最终TARGET-A |

真实 REST 202 只证明写权限；必须由 SDK 访客发言、Crisp 公网 Hook 到生产工作流、当前模型生成并回到同一窗口，才记录真实往返。人工后台操作不可得时，API 构造 `automated:false` 仅算协议场景，不能冒称真人实测。旧 Caddy 404 与自定义出站 properties 被官方拒绝的现场负例均应先复现再回归；不能把固定协议服务的宽松接受当成官方支持。

## 保留的历史验收矩阵

v1.1.1 的 I01～I15、D01～D16、R01～R07、P01～P07 在公开仓库的 [v1.1.1 历史报告](https://github.com/statusX7/ai-support/blob/main/docs/reports/v1.1.1-report.md)记录。它们作为回归继续保留，不与本轮重用编号混淆，主要驱动如下：

| 验收组 | 实际入口与断言 |
| --- | --- |
| I01～I15 | `tests/test_get.sh` 的完整 HTTP/PTY 入口、坏包/限流/重定向/旧版恢复；干净 VM 原样命令确认真实依赖和十项初始化 |
| D01～D16 | `tests/test_doctor.sh` 的受控协议故障；真实隔离实例逐项停止组件、修改无效候选/工作流、心跳停滞并恢复；默认自检前后业务 hash 对比 |
| R01～R07 | `tests/run.sh` 生命周期、实际 v1.1.0 升级/回滚、安全卸载/重装，以及生产 n8n 两会话、Prompt/知识/图片/协议集成 |
| P01～P07 | 历史/资产/协作公开面审查；`tests/test_public_distribution.sh --remote` 无认证访问并比较 main/tag/包；最终干净 VM 公开安装 |

doctor 故障测试必须核对错误组件 ID、状态和退出码；恢复后重新检查，不只看输出含 PASS。D14 比较 .env、config、knowledge、会话文件，排除诊断缓存和实际运行扫描的正常时间变化；不把正常服务的自主心跳误归因于自检。D12 同时验证无客户流量仍有心跳、停止扫描后变旧；0 秒人工状态不清理。

下面仅指公开资产的匿名远端核验，在正式发布后执行；TARGET-A 的候选门槛必须已经完成：

```bash
bash tests/test_public_distribution.sh --remote
```

该驱动用匿名 HTTP 客户端核对分发，不代替最终推荐命令在干净 VM 的实装。下面 T01～T50 是保留的 v1.1.0 功能回归映射。

本表是应执行的场景，不预填通过；对应版本报告记录命令、退出码、证据和实际结果。

| ID | 场景及关键断言 | 必需最高本地证据 |
| --- | --- | --- |
| T01 | 最终归档、无 Docker/Compose/jq 自动引导真实 daemon | REAL-LOCAL 空机 |
| T02 | 文件来源向导十项，确认后零额外必答 | REAL-LOCAL PTY |
| T03 | 多行中文/Emoji/特殊字符 Prompt 原样且实际生效 | REAL-LOCAL 菜单 + API |
| T04 | EOF/SIGINT、下载和包管理失败有界且可恢复 | CONTRACT + REAL-LOCAL |
| T05 | 重复安装/重装不重生成密钥或丢失知识 | REAL-LOCAL |
| T06 | 任意 cwd、新 shell、root/sudo 快捷入口 | REAL-LOCAL |
| T07 | 宽屏双栏、窄屏、dumb、无色/Emoji 降级 | 生产 PTY |
| T08 | 18 主菜单、全部子菜单和取消路径 | 生产 PTY + REAL-LOCAL |
| T09 | 模型列表成功/空/404/401/429/超时 | CONTRACT |
| T10 | 路径前缀、loopback 宿主与容器实际请求 | REAL-LOCAL + 协议服务 |
| T11 | Chat-only/Responses-only 最终推理路径 | REAL-LOCAL + 协议服务 |
| T12 | Provider 整组修改与失败回滚、运行时读回 | REAL-LOCAL |
| T13 | 三命名库中文不同事实的真实索引/来源 | REAL-LOCAL |
| T14 | 跨库同名文件、幂等同步、独立删除 | REAL-LOCAL |
| T15 | 启停后的实际 workspace/新检索 | REAL-LOCAL |
| T16 | 索引超时后 pending 对账不误删 | CONTRACT + REAL-LOCAL |
| T17 | 四种有效格式、中文近义检索 | REAL-LOCAL |
| T18 | 关键词只展示，A 仍 AI、B 不变 | REAL-LOCAL n8n |
| T19 | 点击后只暂停 A、确认一次 | REAL-LOCAL n8n |
| T20 | 取消/未点击后业务问答继续 | REAL-LOCAL n8n |
| T21 | 无 from/type 的同 fingerprint 更新 | REAL-LOCAL n8n |
| T22 | 重放/过期/跨会话/伪造按钮拒绝 | CONTRACT + REAL-LOCAL |
| T23 | 规则启停、排除词、预演与实际读新配置 | CONTRACT + REAL-LOCAL |
| T24 | 真人公开文字/文件立即暂停 | REAL-LOCAL n8n |
| T25 | 全部 automated 出站回流不自判真人 | REAL-LOCAL n8n |
| T26 | note/输入中/在线/operator opened 不接管 | CONTRACT |
| T27 | 慢模型期间人工控制优先、迟到答案丢弃 | REAL-LOCAL n8n |
| T28 | A 人工、B/C 独立并发及上下文 | REAL-LOCAL n8n |
| T29 | N 秒与新真人延长、访客不延长 | 可控时钟 + 真实短计时 |
| T30 | 0 秒、重复乱序、长期人工不被清理 | CONTRACT + REAL-LOCAL |
| T31 | 容器/工作流重启及升级持久状态 | REAL-LOCAL |
| T32 | 总开关关闭屏蔽所有自动出站及在途任务 | REAL-LOCAL n8n |
| T33 | 再启用保留人工期限、不补旧消息 | REAL-LOCAL n8n |
| T34 | 欢迎启停、正文、刷新多标签页去重 | CONTRACT + REAL-LOCAL |
| T35 | SDK 加载/打开/自动展开正确事件链 | 本地 SDK + 实际 n8n |
| T36 | 多级菜单、父级返回、无环引用校验 | CONTRACT + REAL-LOCAL |
| T37 | 图片及后续指代关联当前会话 | REAL-LOCAL + 协议视觉 |
| T38 | 过期/非图片/超大/私网或恶意 URL 拒绝 | CONTRACT |
| T39 | 收件持久化、重放、重启、发送未知对账 | CONTRACT + REAL-LOCAL |
| T40 | 标签/统计失败不阻断正文，保留外部标签 | REAL-LOCAL + 协议服务 |
| T41 | 命中/未知分母、反馈关联与差评不转人工 | CONTRACT + REAL-LOCAL |
| T42 | 全部业务配置与多库原文迁移、保留本机秘密 | REAL-LOCAL |
| T43 | 恶意归档/schema/应用失败拒绝并恢复 | CONTRACT + REAL-LOCAL |
| T44 | v1.0.1 升级、按钮迁移、人工保留 | REAL-LOCAL 旧正式包 |
| T45 | 自动/手动回滚、再升级、镜像/挂载/入口 | REAL-LOCAL |
| T46 | 数字取消、安全卸载、重装、完整清理 | REAL-LOCAL |
| T47 | 外部占网、同名非受管命令保护 | CONTRACT + REAL-LOCAL |
| T48 | 最终归档、版本、菜单/文档一致 | STATIC + REAL-LOCAL |
| T49 | 文件、diff、完整历史、归档与转录密钥扫描 | STATIC |
| T50 | 真实两访客：文本、图片、按钮、人工及恢复 | EXTERNAL-E2E |

## 外部验收及证据安全

外部测试只在账户持有人授权的隔离 Website/专用访客上进行。优先 Website Token + Website Hook，至少订阅 `message:send`、`message:received`、`message:updated`；SDK 欢迎另需 `session:sync:events`。Plugin 只按实例已有模式测契约，不要求普通用户另外建立一套 Plugin。

`tests/test_external_e2e.sh` 属于维护者显式授权的外部测试驱动，从指定受限部署读取已经配置的凭据和实际协议；默认只需两个独立访客会话，不要求四套会话或额外重填全部秘密。驱动的启用/隔离确认、部署目录、两会话和受控图片参数是测试输入，不是安装或上线必填项目。API 合成的 picker 选择及 Hook 回流不能代替真实浏览器点击体验，需分别记录。真实接入按 [Crisp 接入](CRISP.md) 完成；不要在终端历史中输入凭据，不向随机生产客户发送验收消息。

只有 current 配置的实际事实通过才可更新接入状态。协议端点成功、模型列表 200、workflow active、错误 Secret 的 401、健康容器均不得单独提升为“真实会话已接入”。详见 [安装状态](INSTALL.md)。

通用转录用虚构知识并设 0600；真实目标的原始材料留授权现场或 0700 私密目录。公开报告只留目标代号、软件/资产 hash、白名单错误类别和计数，不含连接资料、业务端点、真实/测试会话身份、秘密及其不必要 hash、客户正文、图片或完整本机备份。原始敏感资料不进入 Git 或 Release。
