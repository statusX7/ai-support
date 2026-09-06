# 测试与验收

本章供维护者复现测试；正常管理员接入只需安装向导和 `crispai doctor`，不需要准备开发用 E2E 环境变量。每次发布的实际数量、证据路径和限制以对应 [发布报告](reports/v1.1.0-report.md) 为准。

## 层级与门禁

| 层级 | 能证明什么 | 不能替代什么 |
| --- | --- | --- |
| STATIC | Bash/ShellCheck、schema、工作流引用、Compose 解析、归档、密钥扫描 | 容器运行、依赖实际安装 |
| UNIT/CONTRACT | 生产函数、Shell/PTY、事件 fixture、协议服务、可控时钟的分支 | 真实 Crisp、真实模型或真实向量检索 |
| REAL-LOCAL | 真实 Docker、PostgreSQL、AnythingLLM、n8n、实际索引、生产入口和归档安装 | 用户自有公网/账户授权 |
| EXTERNAL-E2E | 真实 Crisp 测试访客、真实第三方模型、公网 HTTPS 与实际页面 | 未执行的其他发行版、账户和渠道 |

真实空机引导作为 REAL-LOCAL 的独立硬门槛报告：初始无 Docker/Compose，生产安装器自行补齐。不得挂宿主 Docker socket、隐藏 PATH、手工先装 Docker或复用旧版本报告冒充本次实测。协议服务可以配合真实本地应用，但须写为“真实应用 + 模拟 Crisp/Provider”，不能写为“真实模型回答通过”。

运行主驱动的计数与单项复跑分开；嵌套脚本中的多条断言不重复累加到主驱动总数。跳过或证据不足不计通过，失败修复后记录最后复跑及原始原因。

## 自动测试

从开发仓库运行：

```bash
bash tests/run.sh
bash tests/test_manage_contract.sh
node tests/test_configuration_protocol.js
bash tests/test_workflow_contract.sh
bash tests/test_workflow_runtime.sh
node tests/test_provider_adapter.js
```

生产发布归档包含可复现的测试源码，不包含开发工具二进制、运行日志或私密测试配置；普通安装不执行测试驱动。主驱动自行枚举当前正式专项，避免人工漏跑。

ShellCheck、PTY 驱动和 Node.js 是维护者测试依赖，不是宿主客服运行依赖。普通安装所需的 Python 3/PyYAML、jq、Docker/Compose 等仍由生产安装器补齐。

发布模式必须指定隔离真实部署，不能把本地集成缺失当外部豁免：

```bash
AI_SUPPORT_INTEGRATION_DEPLOY_DIR=/绝对路径/隔离验收实例 \
AI_SUPPORT_RELEASE_TEST=1 \
AI_SUPPORT_EXTERNAL_VALIDATION_PENDING=1 \
bash tests/run.sh
```

只有无法取得的私有 Crisp、第三方模型或 DNS/站点权限可以使 EXTERNAL-E2E 标记 `External Validation Pending`。STATIC、UNIT/CONTRACT、REAL-LOCAL 的关键失败或跳过都会阻止发布。开启上述变量不改变已执行测试的失败结果。

`tests/test_deployment_integration.sh` 检查真实目录归属、容器、应用健康和工作流，但单独一次错误 Secret 的 401 不证明正确消息能回复；还必须执行下面的真实故事及归档生命周期验收。

`tests/workflow-local-integration.js` 使用受限测试配置连接真实 n8n 和隔离协议服务，覆盖按钮、两会话、真实计时、重启、在途取消及发送未知对账。`tests/test_web_chat_browser.js` 在真实 Chromium 中运行生产 SDK 片段，通过实际 n8n 公共路由和 Hook 核验欢迎/展开的七种控制场景；它使用合成 Crisp SDK，不冒充真实 Crisp 页面。后者仅供维护者，依赖 Chromium、Node.js、`ws` 和 OpenSSL，测试配置、浏览器 profile 与 localhost TLS 密钥均留在被忽略的受限工作目录。

## 最小真实验收故事

在支持 Docker 的隔离 Debian 12 amd64 VM 创建无配置环境，保存发行版、架构、PID 1、初始包清单和命令可用情况。测试数据全部虚构，禁止录制密钥或真实客户正文。

1. 校验最终归档，解压后用 PTY 执行 `bash install.sh`。文件来源快速路径记录十个主要输入，确认后额外必答为零；多行粘贴逐行计数，不把输入行数误称十次按键。
2. 确认安装器实际安装缺失包、Docker/Compose，启用 daemon 并运行容器；自动创建内部 Key/workspace，读回 Prompt、文档索引和已发布工作流。
3. 从 `/`、`/tmp` 和新 shell 调用 `crispai`。通过真实菜单换配置、粘贴中文 Prompt，检查当前 AnythingLLM Prompt 与容器内配置一致。
4. 创建“订阅使用”“电脑排障”“手机排障”三个命名库；使用有效 MD/TXT/PDF/DOCX。用中文改写问题检查真实向量搜索的来源、内容、排名，不以协议模型固定答复作为检索证据。
5. 停用中间库、更新同名文件、重同步、重新启用、单库重建、删除条目；确认其他库的文档映射未被覆盖或误删。
6. A/B 两位测试访客正常聊天。A 输入“人工”仅见原生 picker，不点继续业务问答仍有 AI；A 点击确认后仅 A 暂停并收到一次确认，B 持续正常。
7. 设置 10 秒恢复；真人再次公开回复 A 更新 A 截止时间。用慢模型验证人工事件已落盘后旧结果不出站；访客消息不重置计时，期限到后只答新问题。
8. 重启后检查人工状态、截止时间、未过期 offer；另测 0 秒永久人工、旧按钮回放、重复/乱序事件和跨会话伪造。
9. 停用客服：在途结果、关键词、欢迎、反馈均静默，仍记录真人事件；重新启用不清空 A 的人工状态、不补答停用期间历史。
10. 欢迎启停、加载/打开事件、自动展开分别验证；页面 SDK 不含密钥。负反馈、图片失败和知识未知都不转人工。
11. 通过菜单导出完整业务配置和知识原文，校验无秘密，再预览导入、应用并读回；另外验证完整本机备份与故障回滚。
12. 从真实 v1.0.1 归档升级，保留密钥、Prompt、知识和既有人工状态；再安全卸载、同路径重装、完整清理及同名命令/外部占网保护。
13. 从正式 GitHub Release 回下载归档和 SHA256SUMS，重新校验、独立解压并检查入口。报告的验收代码应与发布资产相同。

没有真实 Crisp 时，上述消息故事必须通过真正运行的 n8n 生产 Webhook 和隔离协议服务执行。模拟回复、回调和前端 SDK 的本地测试分别标注，不能称为真实 Crisp UI 或真实第三方模型验收。

## T01～T50 追踪矩阵

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

转录用虚构知识并设 0600；报告只留摘要、匿名标识、hash、HTTP 分类和计数，不包含 URL Secret、API Key、客户正文、图片或完整本机备份。原始敏感资料不进入 Git 或 Release。
