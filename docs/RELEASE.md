# 正式发布与回滚

本仓库 `statusX7/ai-support` 自 2026-09-06 起保持 Public。本轮唯一版本为 v1.1.1；维护者复用现有 GitHub CLI 身份与 SSH origin。公开读取无需登录，提交/tag/Release 仍需真实写权限。历史报告的 private 是当时事实，不改写历史 tag 或覆盖旧资产。

## 发布门槛

在线入口、自检、菜单、既有客服行为和生命周期必须有当前版本可观察证据。STATIC、UNIT/PROTOCOL、REAL-LOCAL 关键失败不得跳过；没有私人 Crisp/Provider/DNS/站点权限的 EXTERNAL-E2E 可披露为 `External Validation Pending`。公共匿名取包与安装不能用该豁免跳过。

先确认 main、工作树、v1.1.0 tag 与核验回执，检查 v1.1.1 未被其他内容占用。正常本地 commit，不 force push，不移动或删除已发布 tag。详情见 [测试说明](TESTING.md) 和 [v1.1.1 报告](reports/v1.1.1-report.md)。

## 公开面与秘密检查

扫描当前树及远端所有可达分支/tag 历史、Release 说明/附件、Actions 日志/制品，以及实际存在的 Issues/PR/其他公开协作内容。保护性证据只留 `.work/v1.1.1/`，不上传 .env、数据库、完整备份、客户内容、Prompt/知识或转录。发现真实秘密先处理撤销/轮换，不能只改 HEAD 后继续公开。

使用默认 gh 配置，不创建空 `GH_CONFIG_DIR`，不打印 Token。已是 public 时幂等确认，未来版本不改回 private：

```bash
gh auth status --active --hostname github.com
gh repo view statusX7/ai-support --json nameWithOwner,isPrivate,defaultBranchRef,viewerPermission
gh repo edit statusX7/ai-support --visibility public --accept-visibility-change-consequences
```

GitHub 的[可见性说明](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility)解释历史/Actions 暴露影响；检查应覆盖实际对象，并记录不可读范围。

## 固定源码与可重复打包

同步 `VERSION`、`config/app.yaml`、get.sh、运行时出站版本、CHANGELOG、发布说明和报告；运行 `node n8n/build-workflow.js` 生成工作流。报告记录已验收代码 commit，最终 tag 用 `git rev-parse 'v1.1.1^{commit}'` 解析，避免报告包含自己的 hash。

```bash
bash tests/run.sh
git diff --check
bash scripts/package-release.sh
```

正式打包只允许干净提交和固定已跟踪清单，产物为 `dist/ai-support-v1.1.1.tar.gz`、只含该包一条记录的 `dist/SHA256SUMS`，以及供审计的 `dist/get.sh`。包包含全部生产模块/模板/文档，排除 .git、.work、真实配置/知识、日志、数据、备份和测试工具二进制。两次构建应得到相同 SHA。

main/get.sh 是公共入口，默认解析一次 Latest 正式 tag，再固定同版归档和清单；不得分别使用两个 latest/download 地址或回退 main 归档。主推荐命令从 README 的标记后提取，与 INSTALL 和该版 release notes 逐字一致。

## 推送、组装与发布

仅在核对远端无冲突且门禁完成后执行。以下是维护者流程：

```bash
git tag -a v1.1.1 -m "v1.1.1: add public online installer and component diagnostics"
git push --atomic origin main v1.1.1
gh release create v1.1.1 \
  dist/ai-support-v1.1.1.tar.gz dist/SHA256SUMS dist/get.sh \
  --repo statusX7/ai-support --verify-tag --draft \
  --title v1.1.1 --notes-file docs/releases/v1.1.1.md
```

先核验 draft 内资产名称、大小与回下载 SHA，再正式发布，避免 Latest 指向半成品：

```bash
gh release edit v1.1.1 --repo statusX7/ai-support --draft=false --prerelease=false --latest
gh release view v1.1.1 --repo statusX7/ai-support --json tagName,url,isDraft,isPrerelease,assets
```

使用当前 gh 的 [create](https://cli.github.com/manual/gh_release_create) / [edit](https://cli.github.com/manual/gh_release_edit) 契约。若 draft 已存在，先核对后幂等补齐，不能覆盖已发布内容。

## 匿名验收与回执

已登录 gh 下载只用于发布者核验。正式发布后必须在无登录、Cookie、netrc 或额外认证头的隔离上下文用 `curl -q` 读取 repo、main/get.sh、Release 页面和固定 tag 资产。检查非 draft、非 prerelease、Latest=v1.1.1、包内 VERSION、安全路径、关键脚本与 --help/--version。

最后在干净 Debian 12 amd64 VM 原样运行文档推荐命令，完成十项向导和本地应用初始化。记录初始缺失依赖、自动安装、TTY/隐藏输入、命令生命周期与外部待接入事实。测试源码必须与发布资产一致。

发布后事实写入独立 `v1.1.1-verification.md` 并附加到同一 Release，包含 SHA、tag commit、public/Latest 状态及匿名实装结果。它不要求移动已发布 tag，也不能在未拿到远端结果前写“已发布”。

## 管理员更新与恢复

v1.1.1 使用 `crispai → 14 → 1` 匿名检查并更新正式版，数字确认后复用 get.sh 固定版本下载与原更新器。v1.1.0 升级、固定版本和可信离线包维护见 [高级维护](ADVANCED.md)；新手从 [一条命令安装](INSTALL.md) 开始。

更新前一致性快照包含所需配置/数据/秘密和历史镜像身份；失败恢复完整代际并重建正确 bind mount。local-ready 外部待接入不等同本地故障。完整恢复中断后的混合数据保护不得被自检或 --fix 强行解除；按错误页恢复成套材料。卸载、保留数据重装和完整清理仍由菜单 18 数字确认执行。
