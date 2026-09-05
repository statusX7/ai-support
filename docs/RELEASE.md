# 发布说明

## 发布模型

项目区分两类结果：

- **源码发布**：确认版本文件、部署脚本、配置模板、workflow、静态检查和桩测试达到可交付状态，可创建正式源码 tag。
- **部署实例验收**：使用部署方自己的 Crisp、Provider、AnythingLLM、公网 HTTPS Webhook 和隔离 conversation 验证真实链路。

缺少用户自有的外部账号或凭据不阻止源码发布，但必须在发布报告中标记 `External Validation Pending`，逐项列出未执行内容。未执行、跳过和失败都不得写成通过。

GitHub 权限只决定能否把已经完成的本地 release 推送到远端；没有权限时仍应完成本地 commit、annotated tag、release notes 和安全的推送说明。

## 源码发布门禁

正式源码版本必须满足：

- `VERSION`、`config/app.yaml`、workflow 回复版本、CHANGELOG 和开发报告版本一致。
- `install.sh`、`manage.sh`、`update.sh`、`uninstall.sh` 均通过 Bash 语法和 ShellCheck。
- `docker compose config`、JSON/YAML 校验、管理菜单与 workflow 契约通过。
- `STATIC` 和 `STUB` 测试无失败、无跳过。
- 工作树、未忽略文件和完整 Git 历史不含真实 Token、Secret、用户数据或运行文件。
- `docs/reports/v1.0.0-report.md` 如实区分已验证结果和 `External Validation Pending`。
- `docs/releases/v1.0.0.md` 可直接用作 GitHub Release notes。

源码发布豁免模式只允许 `INTEGRATION` 层因部署方外部资源缺失而跳过：

```bash
AI_SUPPORT_RELEASE_TEST=1 \
AI_SUPPORT_EXTERNAL_VALIDATION_PENDING=1 \
./tests/run.sh
```

该模式不会放宽 `STATIC` 或 `STUB`。外部测试实际返回失败时仍会立即失败；只有显式返回“未配置”的测试才能记录为待验证。

## 部署实例验收

部署方获得真实配置后，应执行不带豁免的完整发布测试：

```bash
AI_SUPPORT_RELEASE_TEST=1 ./tests/run.sh
```

完整实例验收包括：

- Docker 容器启动、健康检查、重启和数据持久化。
- 全新安装、重复安装、中断恢复和最终 `ready` 状态。
- Provider 模型列表、Chat Completions、Responses、错误降级和视觉能力。
- Website Hook 与 Plugin Hook 的签名/Secret、文本、上下文、防重复和欢迎语。
- operator 主动回复关闭 AI、精确关键词转人工以及配置化标签合并。
- Markdown、TXT、PDF、DOCX 上传、索引、查询、重新索引和删除。
- 图片理解与不支持视觉时的明确提示。
- 统计反馈、迁移备份、成功更新、失败自动回滚、安全卸载与恢复。

详细变量与证据要求见 [测试说明](TESTING.md)。

## 本地 release 准备

```bash
test "$(< VERSION)" = v1.0.0
grep -Fq 'version: v1.0.0' config/app.yaml
grep -Fq "ai_support_version: 'v1.0.0'" n8n/workflow.json
grep -Fq '## v1.0.0' CHANGELOG.md
test -f docs/reports/v1.0.0-report.md
test -f docs/releases/v1.0.0.md
git diff --check
./tests/test_static_security.sh
```

提交并创建本地 annotated tag：

```bash
git add --all
git commit -m "v1.0.0 release ai support"
git tag -a v1.0.0 -m "v1.0.0"
git status --short --branch
```

tag 创建后重新运行密钥扫描，并确认 `git rev-list -n 1 v1.0.0` 指向预期提交。

## GitHub 发布

远端 URL 不得嵌入凭据。目标仓库固定为 private repository `statusX7/ai-support`：

```bash
git remote add origin https://github.com/statusX7/ai-support.git
```

有短期 `GH_TOKEN` 时先确认身份和仓库：

```bash
gh auth status
test "$(gh api user --jq .login)" = statusX7
gh repo view statusX7/ai-support --json nameWithOwner,visibility,defaultBranchRef
test "$(gh repo view statusX7/ai-support --json visibility --jq .visibility)" = PRIVATE
```

仓库不存在时创建 private repository；已存在时先检查远端分支和 tag，禁止 force push 或覆盖未知内容：

```bash
gh repo create statusX7/ai-support --private
git ls-remote --heads --tags origin
git push --atomic origin main v1.0.0
gh release create v1.0.0 \
  --repo statusX7/ai-support \
  --verify-tag \
  --title "v1.0.0" \
  --notes-file docs/releases/v1.0.0.md
```

发布后用 `gh release view v1.0.0 --repo statusX7/ai-support` 核验 Release 不是 draft 或 prerelease。

没有 GitHub 权限时不得伪造 Release URL。保留本地 tag，授权后执行上述远端检查、push 和 `gh release create` 即可。

## 发布失败处理

- tag 或 push 前失败：修复后重新执行受影响门禁。
- push 成功但 Release 创建失败：不改写远端 tag，核对提交后重试创建 Release。
- 发现凭据或用户数据：停止发布、轮换凭据并清理历史。
- 外部实例测试失败：记录实际失败并修复；不得改写为 `External Validation Pending`。
