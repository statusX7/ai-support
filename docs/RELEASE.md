# 正式发布与回滚

本仓库 `statusX7/ai-support` 自 2026-09-06 起保持 Public。本轮目标版本为 v1.2.1；维护者复用现有 GitHub CLI 身份与 SSH origin。公开读取无需登录，提交/tag/Release 仍需真实写权限。历史报告的 private 是当时事实，不改写历史 tag 或覆盖旧资产。本页是操作流程，不表示这些发布动作已经执行。

## 发布门槛

在线入口、自检、中文菜单、资料/接口池应用、评价停用、主备路由、日志及既有客服行为必须有当前版本证据。STATIC、UNIT/CONTRACT、REAL-LOCAL 关键失败不得跳过。v1.2.1 的额外硬门槛是：**完整冻结候选先通过 TARGET-A，之后才可 push、tag、创建 draft 或上传任何 Release 资产。** 不能先发布待验证版，再补目标机验收。

真实后台人工操作不可得等外部边界需单列，不能构造真人事件冒称通过；也不能用 `External Validation Pending` 豁免已经授权的目标机往返、欢迎状态、同包升级或故障切换检查。真实备用资源不足时准确报告验证层级，不把同一账号的多个模型当成独立账号。公共匿名取包和空机安装仍是发布后的独立门槛。

先确认 main、工作树、v1.2.0 tag 与独立核验回执，检查 v1.2.1 未被其他内容占用。允许开发阶段正常本地 commit，不 force push，不移动或删除已发布 tag。详情见 [测试说明](TESTING.md)、[本轮发布说明](releases/v1.2.1.md)和公开仓库保留的 [v1.2.0 报告](https://github.com/statusX7/ai-support/blob/main/docs/reports/v1.2.0-report.md)。

## 公开面与秘密检查

扫描当前树、index、新增未忽略文件及远端可达分支/tag 历史、Release 说明/全部附件、Actions 日志/制品与实际存在的协作内容。通用证据留 `.work/v1.2.1/`；实机材料留 0700 的 `.work/v1.2.1-private/`，文件 0600，不覆盖 v1.2.0 现场原件。受限连接和 known_hosts 原位复用，敏感对照只在内存合并本轮增量。扫描字面值及常见编码只输出命中数/文件位置；不公开连接、业务端点、会话身份、秘密、数据库、完整备份及 Prompt/知识。含连接附录的任务书全文不能提交。发现真实秘密先处理撤销/轮换，不能只改 HEAD 后继续公开。

使用默认 gh 配置，不创建空 `GH_CONFIG_DIR`，不打印 Token。已是 public 时幂等确认，未来版本不改回 private：

```bash
gh auth status --active --hostname github.com
gh repo view statusX7/ai-support --json nameWithOwner,isPrivate,defaultBranchRef,viewerPermission
gh repo edit statusX7/ai-support --visibility public --accept-visibility-change-consequences
```

GitHub 的[可见性说明](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility)解释历史/Actions 暴露影响；检查应覆盖实际对象，并记录不可读范围。

## 固定源码与可重复打包

同步 `VERSION`、`config/app.yaml`、get.sh、工作流 meta 版本、CHANGELOG、发布说明和报告；运行 `node n8n/build-workflow.js` 生成工作流。出站只使用 Crisp 支持的消息字段，不为写版本添加任意 properties。报告记录已验收代码 commit，最终 tag 用 `git rev-parse 'v1.2.1^{commit}'` 解析，避免报告包含自己的 hash。

```bash
bash tests/run.sh
git diff --check
bash scripts/package-release.sh
```

正式打包只允许干净提交和固定已跟踪清单，产物为 `dist/ai-support-v1.2.1.tar.gz`、只含该包一条记录的 `dist/SHA256SUMS`，以及供审计的 `dist/get.sh`。包须包含 provider pool/router/envelope、中文呈现/主备菜单模块，以及本轮知识链的 `n8n/admin-query.js`、`n8n/knowledge-lexical.js`、`scripts/knowledge-component.js`、`scripts/knowledge-lexical.py`、`scripts/knowledge-profile.py`、`scripts/knowledge-profile.sh` 和已有 materials/logs 等完整生产文件；排除 .git、.work、真实配置/知识、秘密代次、日志、数据、备份和测试工具二进制。两次构建应得到相同 SHA。

main/get.sh 是公共入口，默认解析一次 Latest 正式 tag，再固定同版归档和清单；不得分别使用两个 latest/download 地址或回退 main 归档。主推荐命令从 README 的标记后提取，与 INSTALL 和该版 release notes 逐字一致。

## 发布前候选与 TARGET-A

向唯一远程写操作者交付冻结提交、完整归档和精确校验清单。先保全现场及正式一致快照，再由完整包的生产升级器部署；同版复验走保留配置的完整安装流程，不散装拷贝源码或强制降级。读取新版程序清单动态逐文件核对，不沿用旧版固定文件数。

核对真实配置/原文、人工/offer/jobs、主接口迁移与秘密代次保留，四核心、实际容器文件、active workflow、资料/池投影、日志 timer 的真实触发、新 SSH 双入口和专用 SDK 原窗口往返。取消评价、完整 FAQ 原问的明确事实答案、中文改写、欢迎真回读与受控切换须有本轮证据；故障注入后恢复用户参数，不清状态凑成功。发布回执中的 `exact_knowledge_answer_verified` 必须来自该冻结包的实机问答，不能用协议固定回复代替。

任何生产文件变化都使旧候选结论需要重新核对，仍使用完整冻结包复验。只有满足本轮门槛后才能进入下面的发布动作；后台真人未观察、仅格式断言失败等边界分别保留，不能用历史成功覆盖当前失败。

## 推送、组装与发布

仅在核对远端无冲突且门禁完成后执行。唯一远程操作者在受限工作区生成 0600 的脱敏验收回执，字段与 `scripts/release-gate.py` 一致；每个检查项必须来自实际验收。门禁核对当前干净提交、完整包 SHA、get 审计副本及 7 天内的同包 TARGET-A 回执。它不是数字签名，也不能代替真实测试。缺失、失败、身份不符或源码改动时必须阻止后续动作，不能伪造回执或绕过检查。以下是维护者流程：

```bash
set -euo pipefail
python3 scripts/release-gate.py --artifacts dist \
  --target-receipt .work/v1.2.1-private/target-release-gate.json
git tag -a v1.2.1 -m "v1.2.1: add bounded provider failover and remove automatic rating invitations"
git push --atomic origin main v1.2.1
gh release create v1.2.1 \
  dist/ai-support-v1.2.1.tar.gz dist/SHA256SUMS dist/get.sh \
  --repo statusX7/ai-support --verify-tag --draft \
  --title v1.2.1 --notes-file docs/releases/v1.2.1.md
```

先核验 draft 内资产名称、大小与回下载 SHA，再正式发布，避免 Latest 指向半成品：

```bash
gh release edit v1.2.1 --repo statusX7/ai-support --draft=false --prerelease=false --latest
gh release view v1.2.1 --repo statusX7/ai-support --json tagName,url,isDraft,isPrerelease,assets
```

使用当前 gh 的 [create](https://cli.github.com/manual/gh_release_create) / [edit](https://cli.github.com/manual/gh_release_edit) 契约。若 draft 已存在，先核对后幂等补齐，不能覆盖已发布内容。

## 匿名验收与回执

已登录 gh 下载只用于发布者核验。正式发布后必须在无登录、Cookie、netrc 或额外认证头的隔离上下文用 `curl -q` 读取 repo、main/get.sh、Release 页面和固定 tag 资产。检查非 draft、非 prerelease、Latest=v1.2.1、包内 VERSION、安全路径、关键脚本与 --help/--version。

最后在干净 Debian 12 amd64 VM 原样运行文档推荐命令，完成十项向导和本地应用初始化。记录初始缺失依赖、自动安装、TTY/隐藏输入、命令生命周期与外部待接入事实。测试源码必须与发布资产一致。

TARGET-A 也必须通过正式包的维护路径运行相同生产文件；候选或临时救援不能代替最终逐文件对齐。断开排障连接后新登录核验命令、组件、资料/日志与真实访客往返；不为测试卸载用户目标机。临时账号由用户在整体验收后自行撤销，运行组件不得依赖它。

发布后事实写入独立 `v1.2.1-verification.md` 并附加到同一 Release，包含 SHA、tag commit、public/Latest、匿名实装和目标机正式内容核验的非敏感结论。它不要求移动已发布 tag，也不能在未拿到远端结果前写“已发布”。私密交付说明留受限工作区，不能作为 Release 附件。

## 管理员更新与恢复

v1.1.1 及以上使用 `crispai → 14 → 1` 匿名检查并更新正式版，数字确认后复用 get.sh 固定版本下载与原更新器。旧版本升级、入口救援、固定版本和可信离线包维护见 [高级维护](ADVANCED.md)；新手从 [一条命令安装](INSTALL.md) 开始。

更新前一致性快照包含所需配置/数据/秘密和历史镜像身份；失败恢复完整代际并重建正确 bind mount。local-ready 外部待接入不等同本地故障。完整恢复中断后的混合数据保护不得被自检或 --fix 强行解除；按错误页恢复成套材料。卸载、保留数据重装和完整清理仍由菜单 18 数字确认执行。

安装、重复安装、升级和回滚会刷新 adapter 及受管 Caddy 的单文件挂载；本版新增 router/envelope 同样须核对实际容器内容，外部反代不在自动重建范围。受管 Caddy 使用新挂载先执行配置验证，且预检早于第一次 `up`，再重建本实例服务。doctor 比较容器与磁盘文件，只输出匹配结果，不输出配置正文或秘密摘要。不能以普通 `up -d` 返回成功证明原子替换后的文件已加载：[Compose 重建语义](https://docs.docker.com/reference/cli/docker/compose/up/)、[Caddy 配置验证](https://caddyserver.com/docs/command-line#caddy-validate)。旧 inode 故障属于 v1.2.0 已记录根因，新版仍需回归，不能引用历史结果代替本轮实测。
