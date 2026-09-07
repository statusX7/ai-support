# 架构与运行契约

## 组件职责

| 组件 | 职责 |
| --- | --- |
| Crisp | 访客聊天框、公开消息、真人界面与事件 |
| n8n | 已鉴权持久接收、短事务控制、规则/欢迎、发送与恢复扫描 |
| AnythingLLM | 文档解析、Embedding、workspace 向量检索和聊天编排 |
| Provider 适配器 | 同一项目的 Chat 转发或 Chat→Responses 最小兼容，不自建 RAG |
| 第三方 AI | 实际文本与可选视觉推理 |
| PostgreSQL | n8n 配置、工作流与其必要数据库 |
| 可选 Caddy | 受管 HTTPS，仅开放指定 Hook/SDK/UI 路由 |
| Shell 管理器 | 单一配置权威、应用/回读、安装维护与全局 crispai |

不增加 CRM、多租户、坐席调度、Redis/Kafka、另一套向量库或管理网站。

## 安装链路

```text
匿名 get.sh → 锁定正式 tag/完整包校验/安全解压
→ install.sh 参数/帮助 → root/sudo → 最小工具自动补齐
→ 识别首次/续装/已部署 → 十项向导 → 用户确认
→ Docker/Compose/daemon/实际容器能力
→ 受管目录和内部密钥 → 固定镜像与服务
→ AnythingLLM Key/workspace/Prompt/多库索引
→ n8n import/publish/生产节点 → 配置回读与代次
→ crispai/可选 crisp 入口与系统级日志 timer
→ 本地/Provider/Crisp/公网/会话分层事实
```

所有持久数据在选择的部署目录，默认 `/opt/crisp-ai`；程序来源解压目录可删除。系统包、Docker 服务、受管命令和本项目 `/etc/systemd/system/crispai-log-maintenance-*.{service,timer}` 是明确受控的系统位置例外，不依赖临时排障用户的 HOME/登录或用户 cron。帮助/版本不要求完整配置或外部探测。`get.sh --repair` 用同版完整正式包校验后修复命令归属，不初始化/替换客户资料；完整程序更新仍走显式 `--update`。

## 事件、控制与发送

```text
Crisp Webhook
  → Secret/签名、website/session、大小与事件去重
  → 持久保存任务；人工/合法按钮控制短事务优先提交
  → HTTP 确认
  → 持久任务处理：总开关 → 会话模式/到期 → 反馈/菜单/关键词
  → 公开上下文 + AnythingLLM 检索/模型（或已验证视觉路径）
  → 全局 revision + 会话 generation + 当前人工状态再次检查
  → 统一 automated sender / 预登记 fingerprint
  → 发送确认后统计、可选标签；超时未知先对账
```

另有 n8n 5 秒 Schedule 恢复未完成任务与到期状态。`runtime.js` 为唯一生产实现，由 `build-workflow.js` 内联进工作流，并由容器 CLI 复用；生成校验防止 JSON 模板与逻辑分叉。

控制状态 `data/runtime/session-SHA256(website+NUL+session).json` 使用短 mkdir 锁、fsync/原子写。每会话普通消息队列有序，不在长 LLM 请求期间持锁，不同会话独立。全局开关来自资料投影中的 runtime.enabled，不是共享人工状态。无限人工不受已完成任务缓存淘汰影响。生成投影损坏、资料应用中或知识映射代次不一致时，不继续用半份原文发送普通回复；人工事件仍走持久控制路径。

关键词只发 offer，仍处 AI；有效点击先暂停再确认，真人公开回复无需按钮立即暂停。倒计时从最近有效真人/首次确认开始，0 永久，用户消息不延长；到期只允许新问题，不补历史、不发恢复提示。自己的 automated operator、note、在线、输入和后台 opened 均不当真人。

## Prompt、知识与上下文

各命名库用 catalog/document ID/hash 管理，全部启用库汇入一个 workspace。原文、投影、远端位置与 runtime 来源映射分离；停用库真实移除检索关系但保留原文，删除或更新不误操作其他库。pending 对账承接服务端索引超时，不能只看 HTTP 上传成功。

公开 Crisp 历史是上下文来源，按当前会话限定与截断；人工回复显式加入，内部 note 和控件不当业务问题。AnythingLLM stable sessionId + reset 避免重复内部聊天记录。当前 Prompt 写入 workspace，图片请求读取同一生效投影中的完整正文，不再独自截成 30000 字符。文件上限不等于模型 token 上限，过长请求仍受当前模型/应用预算限制。Provider 协议和容器访问地址必须通过实际调用；第三方缺失时协议服务只能证明格式接线，不证明真实模型语义。

## 欢迎网页边界

first_message 无需网页变更。widget_load/chat_open 模式用一次性无密钥 SDK：session:loaded/chat:opened → session:event → Crisp session:sync:events Hook → 后端受控欢迎。chat:open 独立控制展开；公开配置仅白名单字段并结合会话人工状态，不能匿名接管或向别的会话发送。

## 配置和维护

业务 YAML/JSON、Prompt 与多库原文是权威源，秘密单独 `.env`。`materials.sh` 统一菜单与直接编辑的应用：严格 UTF-8/大小/schema/引用校验→有效版本备份→规范化候选→实际 API 同步→组件回读→发布 `config/materials-applied.json`。用户无需编辑 manifest 或 Code。Prompt/索引慢同步先发布 `applying` 代次，使旧 AI 结果失效；失败恢复上一份有效资料和外部应用，回退未确认则保持保护状态。配置/知识根目录原 inode 保留，避免容器仍绑定被挪走的旧目录。

| 内容 | 稳定位置 | 修改方式/消费者 |
| --- | --- | --- |
| Prompt / 业务规则 | `config/prompt.md`、受支持 `config/*.yaml` | 管理员编辑；materials 校验生成投影，运行时只读已应用版本 |
| 命名库原文 | `knowledge/kb_*/sources/` | 菜单或直接编辑现有条目；新增/删除用知识管理保持归属 |
| 库定义 | `knowledge/catalog.json` | 可编辑已登记库名/启用状态；稳定 ID/source/projection 由管理程序维护 |
| 索引关系 | `data/knowledge-manifest.json` | 实际索引对账，由程序维护，不手改 |
| 生效资料 / 检索来源映射 | `config/materials-applied.json`、`data/runtime/knowledge-map.json` | 应用后原子发布，运行时验证映射代次 |
| 秘密 / 会话控制与任务 | `.env`、`data/runtime/` | 受限解析/短事务；不是日志清理对象 |
| 维护事件 / 诊断历史 | `logs/` | 白名单事件、脱敏导出与系统级 timer |
| 恢复资料 | `backups/` | 完整敏感快照与业务迁移包分开，不上传 |

普通 `apply` 对无变化原文快速返回；显式 `--force-external` 同步并回读现有 Prompt 与启用知识的受管位置关系，不默认全量重索引，也不承诺逐字审计远端解析正文或删除非受管文档。维护串行锁与会话控制锁分开。完整本机快照包含秘密与运行状态；业务迁移包含全部库原文而不带会话/Key。旧关键词迁移为按钮确认，旧哈希人工记录惰性迁移不清空。

## 日志与保留

Shell 生命周期只记录操作/阶段/退出码等白名单字段，不 tee 隐藏输入或 HTTP 原文。运行时异常在落盘前归类，不保存客户端异常对象；n8n 工作流关闭成功/错误执行正文和进度保存。容器使用受管 `json-file` 大小/份数策略，变化要重建本实例容器并回读。受管 Caddy 不启用访问日志，并过滤默认运行错误日志的请求 URI/认证头；外部反代的日志保护需管理员实际合入、重载并验证，见 [CRISP](CRISP.md)。应用日志、Docker 容量日志、n8n execution 数据与 analytics 是不同来源，策略不能互相冒充。

`logs.sh` 与菜单 15 共用来源白名单、预览/数字确认、轮转、过期清理与脱敏包。系统级 timer 在开机后及周期内调用同一清理器，不依赖 n8n 是否运行。它不删除 Docker LogPath、系统 journal、数据库 WAL、向量索引、备份、客户任务或永久人工状态。

安全卸载移除项目容器/网络/程序与所属全局命令，保留数据；完整清理先外部完整备份再数字双确认。回滚重建数据目录绑定容器，保留历史镜像身份。任何容器、库、网络、Key 或账户缺失不能靠改状态标志变成成功；外部验收分层见 [TESTING](TESTING.md)。
