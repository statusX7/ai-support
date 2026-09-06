# 正式发布与回滚

本项目源码版本、真实本地部署与用户外部接入分别验收。`statusX7/ai-support` 自 2026-09-06 起保持公开（Public）：读文档、下载资产和 HTTPS clone 不需要仓库授权；提交、推送和创建 Release 仍需维护者权限。本章只供维护者使用，新手请看 [安装教程](INSTALL.md)，普通服务器运行不依赖 Git 或 gh。

## 公开后的文档与发布约定

- 新教程以无需认证的 Release 资产下载为主，提供浏览器上传后安装的路径；不将 gh 登录、SSH key 或访问邀请设为普通用户的安装前提。
- 示例下载 URL 固定到同一个正式版本；更新版本时同时修改 tag、包名、解压目录和校验文件来源，不混用 `latest` 与旧文件名。
- 只更正文档不另造软件版本，不替换已发布资产、重算旧包校验值或移动旧 tag。历史报告里的 private 表示当时事实；旧包内教程由 `main` 的最新说明补充。
- 日常改写依照 `AGENTS.md` 先本地提交；获得文档同步授权后才推送。若同步 GitHub Release 的说明文字，仅更新教程和当前公开访问提示，保留原 tag、资产与验证结果。
- Git 历史、Release 说明与附件、公开 Issue 都必须按公共资料审查；实例 `.env`、知识、日志、会话与备份不因仓库公开而纳入发布。

## v1.1.0 发布门禁

- 18 项生产管理菜单实际可达，`crispai` 指向持久实例；十项快速初始化和缺依赖自动安装没有退化。
- 关键词仅展示原生 picker，真实有效选择才暂停该会话；真人立即暂停、0/N 秒恢复、全局开关及迟到答案复核有实际运行证据。
- Provider Chat/Responses 最终协议、Prompt 直接粘贴、多库索引/启停和完整业务迁移实际生效。
- STATIC、UNIT/CONTRACT 与 REAL-LOCAL 核心测试无失败或关键跳过；至少一套初始无 Docker/Compose 的隔离系统从最终包完成生产安装。
- v1.0.1 升级、人工状态保留、故障回滚、卸载/重装及受管入口生命周期经验证。
- 版本、schema、workflow、CHANGELOG、文档和资产一致；当前文件、diff、完整 Git 历史、归档、转录无真实秘密。
- 只缺真正的 Crisp/Provider/DNS/站点权限时，可将 EXTERNAL-E2E 标记 `External Validation Pending`，不豁免本地代码、应用初始化或部署失败。

准确层级、命令和 T01～T50 矩阵见 [测试说明](TESTING.md)。对应发布实际结果写入 [完整报告](reports/v1.1.0-report.md) 和 [发布说明](releases/v1.1.0.md)。

## 检查基线与权限

复用默认 GitHub CLI 登录，不新建空 `GH_CONFIG_DIR`，不根据 `GH_TOKEN` 是否设置推断登录，不把 Token 放进 URL：

```bash
git status --short
git remote -v
git log -5 --oneline
git tag --list
gh auth status --hostname github.com
gh repo view statusX7/ai-support --json nameWithOwner,isPrivate,defaultBranchRef
gh release list --repo statusX7/ai-support --limit 5
git ls-remote --heads --tags origin
```

保留现有维护者认证和 SSH remote，核对 `isPrivate` 为 `false`，不得擅自改回 private。公开读权限不代表推送权限。日志不记录认证内容；检查输出前脱敏。v1.1.0 已发布，下面同名命令仅作当时流程示例，不得照抄重发；正式新版本必须选择未占用 tag，禁止移动/删除历史 tag 或 force push。

## 验收及一致性

在已经安装的隔离真实实例上运行，不得使用正式客服：

```bash
AI_SUPPORT_INTEGRATION_DEPLOY_DIR=/绝对路径/隔离验收实例 \
AI_SUPPORT_RELEASE_TEST=1 \
AI_SUPPORT_EXTERNAL_VALIDATION_PENDING=1 \
bash tests/run.sh
git diff --check
bash tests/test_static_security.sh
```

有全部外部测试资源时，配置受限测试环境后去掉外部 pending 参数。无论哪种模式，独立干净系统引导、最终归档实装、生产菜单、旧版本升级和回滚证据都应另行对账。

确认 `VERSION`、`config/app.yaml`、生成工作流中的版本、CHANGELOG、`docs/releases/v1.1.0.md` 和 `docs/reports/v1.1.0-report.md` 一致。工作流通过 `node n8n/build-workflow.js` 从受管源码生成，禁止只改生成 JSON 留下不一致源码。

先保留可解析的“验收代码 commit”，再写最终报告和发布提交。报告不要试图包含自身最终 hash；用 `git rev-parse v1.1.0^{commit}` 核对发布 tag。远端下载回执可作为 Release 附件或独立脱敏交付记录，不能因此移动 tag。

## 确定归档

打包器要求已修改/暂存文件全部提交，仅收录固定的已跟踪生产清单：

```bash
bash scripts/package-release.sh --output-dir dist
(cd dist && sha256sum --check SHA256SUMS)
bash tests/test_release_package.sh
```

产物为 `dist/ai-support-v1.1.0.tar.gz` 和仅含当前包的 `dist/SHA256SUMS`。生产模块、模板、workflow、页面脚本和文档必须完整；不包含 `.git`、`.work`、`.env`、实际业务配置/知识、运行数据、备份、日志或测试模型。

在项目忽略目录下新建隔离解压目录，检查安全条目、版本、`--help/--version` 后执行正式安装入口。不是在工作树测试完成就默认归档也成功。最终打包后的内容发生任何变动都必须重新生成 hash 并复验。

## 推送及真正创建 Release

以下假设已核实默认分支为 `main`、v1.1.0 不存在且工作树干净。提交前先审查待提交清单，不将受限测试资料添加进 Git。

```bash
git tag -a v1.1.0 -m "v1.1.0: complete Shell management and conversation control"
git push --atomic origin main v1.1.0
gh release create v1.1.0 \
  dist/ai-support-v1.1.0.tar.gz dist/SHA256SUMS \
  --repo statusX7/ai-support \
  --verify-tag \
  --title "v1.1.0" \
  --notes-file docs/releases/v1.1.0.md
gh release view v1.1.0 --repo statusX7/ai-support \
  --json url,isDraft,isPrerelease,tagName,assets
```

使用正式非 draft、非 prerelease。若原子 push 不被服务端支持，先验证分支再推 tag；任何远端冲突先停止核对，不能覆盖用户提交。push 成功但创建 Release 失败时，仅幂等完成尚未完成的 Release；不要重新打一个指向不同代码的同名 tag。命令语义见 [GitHub CLI 创建 Release](https://cli.github.com/manual/gh_release_create)。

## 远端回下载核验

公开仓库除下述维护者 gh 检查外，还应按 [新手教程](INSTALL.md) 在不发送 GitHub 认证信息的情况下下载资产、核对 SHA256、解压并测试 `--help/--version`。匿名只读检查失败时先排查资产名称、发布状态和网络，不让新手用 Token 绕过错误下载地址。

用新的项目内受限目录下载当前两个资产：

```bash
release_receipt_dir=$(mktemp -d /root/projects/crispai/.work/release-receipt.XXXXXX)
gh release download v1.1.0 --repo statusX7/ai-support \
  --pattern ai-support-v1.1.0.tar.gz --pattern SHA256SUMS \
  --dir "$release_receipt_dir"
(cd "$release_receipt_dir" && sha256sum --check SHA256SUMS)
tar -tzf "$release_receipt_dir/ai-support-v1.1.0.tar.gz"
tar -xzf "$release_receipt_dir/ai-support-v1.1.0.tar.gz" -C "$release_receipt_dir"
bash "$release_receipt_dir/ai-support-v1.1.0/install.sh" --help
bash "$release_receipt_dir/ai-support-v1.1.0/manage.sh" --version
git rev-parse 'v1.1.0^{commit}'
git ls-remote origin 'refs/tags/v1.1.0*'
```

维护目录不在上述路径时，改为自己的项目内忽略目录；不得指向已有部署。先检查条目及 SHA256 再解压，不把未校验的陌生包当脚本执行。记录真实 URL、资产名/大小/SHA256、远端 tag commit 和入口结果。[GitHub CLI 下载资产](https://cli.github.com/manual/gh_release_download)

## 部署升级及回滚

管理员使用 `crispai → 14 更新与回滚`，选择可信离线包；v1.0.1 也可用其已有更新入口。升级前创建一致性快照、核对容量与镜像，成功后读回配置及应用，重建正确数据挂载并修复快捷命令。

故障时使用同菜单的历史回滚，或按 [部署文档](INSTALL.md) 的恢复命令。完整本机 v3 备份包含内部秘密和数据库，必须 0600 保存，不上传 Release。业务迁移包不含秘密，不等价于完整灾难恢复快照；旧 v2 备份的恢复要求见 [配置与迁移](CONFIG.md)。

发布地址只有远端实际成功后才能报告。认证真的过期或权限被撤销时，保留本地成果和明确失败命令，说明需要账户持有人恢复哪项授权，不能虚构 Release 链接。
