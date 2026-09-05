# 发布说明

## 原则

`v1.0.0` 只有在代码、真实部署和外部端到端链路全部验收通过后才能发布。自动桩测试、Compose 配置解析或文档完成都不能替代真实 Docker、Crisp、AnythingLLM 和 Provider 验收。

任何门禁结果为 FAIL、SKIP、未执行、无法确认或只在桩环境通过时，立即停止发布；不得创建 tag、push 或 GitHub Release，也不得在报告中写成已通过。

本文定义发布流程，不是验收结果。没有写入 `docs/reports/v1.0.0-report.md` 的有效证据一律视为未验收。

## 必须全部通过的门禁

- 版本与文档：`VERSION`、`config/app.yaml`、CHANGELOG 和 `docs/reports/v1.0.0-report.md` 一致。
- 静态与桩测试：发布模式 `STATIC`、`STUB` 无失败、无跳过。
- 真实 Docker：Compose 配置、镜像拉取、容器启动、健康检查、重启和持久化全部 PASS。
- 真实安装：新目录一键安装、自动 AnythingLLM bootstrap、工作区、Prompt 和 workflow 发布全部 PASS，最终状态为 `ready`。
- 真实 Provider：模型列表、Chat Completions、Responses 能力选择、失败路径和视觉能力检测全部 PASS。
- 真实 Crisp：Website Hook、Plugin Hook、文本、上下文、防重复、operator 接管、发送前竞态复核、精确转人工和标签并集全部 PASS。
- 真实知识库：内容有效的 Markdown、TXT、PDF、DOCX 导入、索引、查询、重新索引和删除全部 PASS。
- 真实图片：支持视觉与不支持视觉两条路径全部 PASS。
- 统计反馈：命中、未命中、转人工、发送失败、好评、差评和脱敏全部 PASS。
- 迁移与维护：配置导出导入、维护锁、成功更新、故障注入自动回滚、n8n 数据库和 AnythingLLM 数据一致性、默认安全卸载及同路径恢复、隔离环境完整清理全部 PASS。
- 安全：工作树、未忽略文件和完整 Git 历史无真实 Secret、Token、用户数据或运行时文件。
- GitHub：目标仓库确认是 `statusX7/ai-support` 且可见性为 `PRIVATE`，发布账号确认是 `statusX7`。

详细操作和证据要求见 [测试说明](TESTING.md)。

## 本地发布检查

先完成版本文件、CHANGELOG 和开发报告，再检查工作树：

```bash
test "$(< VERSION)" = v1.0.0
grep -Fq 'version: v1.0.0' config/app.yaml
grep -Fq '## v1.0.0' CHANGELOG.md
test -f docs/reports/v1.0.0-report.md
git diff --check
./tests/test_static_security.sh
```

按 [测试说明](TESTING.md) 安全注入专用环境的全部 E2E 变量，再在 Website Hook 和 Plugin Hook 配置下分别运行发布模式测试：

```bash
AI_SUPPORT_RELEASE_TEST=1 ./tests/run.sh
```

两次命令都必须无失败、无跳过。然后按 [测试说明](TESTING.md) 完成脚本未覆盖的真实负向、更新和回滚验收，把每一项的时间、版本、匿名测试标识和 PASS/FAIL 写入 `docs/reports/v1.0.0-report.md`。报告禁止包含凭据、完整消息正文或真实用户数据。

所有修改完成后创建本地英文 commit，例如：

```bash
git add --all
git commit -m "v1.0.0 release ai support"
git status --short --branch
git log -1 --show-signature --oneline
```

提交后必须重新运行密钥扫描和与提交内容相关的最终检查。工作树必须干净。

## GitHub 前置检查

推荐通过当前进程的 `GH_TOKEN` 提供短期凭据，不把 Token 写入仓库、命令历史或 remote URL。先确认登录账号和仓库：

```bash
gh auth status
test "$(gh api user --jq .login)" = statusX7
gh repo view statusX7/ai-support \
  --json nameWithOwner,visibility,defaultBranchRef
test "$(gh repo view statusX7/ai-support --json visibility --jq .visibility)" = PRIVATE
```

若仓库尚不存在，只能创建 private repository：

```bash
gh repo create statusX7/ai-support --private --source=. --remote=origin
```

若仓库已存在但本地尚无 remote：

```bash
git remote add origin git@github.com:statusX7/ai-support.git
```

检查 remote 不含嵌入式凭据，并确认远端分支和 tag 状态：

```bash
test "$(git remote get-url origin)" = git@github.com:statusX7/ai-support.git
git ls-remote --heads --tags origin
```

如果远端已有不同内容或已有 `v1.0.0` tag，停止发布并人工核对；禁止 force push、覆盖 tag 或删除未知远端内容。

## 创建正式发布

仅在全部门禁 PASS、报告已提交、工作树干净且远端状态确认后执行：

```bash
git tag -a v1.0.0 -m "v1.0.0"
git push --atomic origin main v1.0.0
gh release create v1.0.0 \
  --repo statusX7/ai-support \
  --verify-tag \
  --title "v1.0.0" \
  --notes-file docs/reports/v1.0.0-report.md
```

发布后只读核验：

```bash
gh release view v1.0.0 \
  --repo statusX7/ai-support \
  --json url,isDraft,isPrerelease,tagName,targetCommitish
git ls-remote --heads --tags origin
```

确认 Release 不是 draft 或 prerelease、tag 是 `v1.0.0`，并把 Release URL 写入最终交付结果。

## 发布失败处理

- tag 或 push 前失败：修复后重新执行全部受影响门禁，不创建发布对象。
- push 已成功但 Release 创建失败：不要改写 tag；确认 tag 指向的提交正确后重试 `gh release create`。
- 发现凭据或用户数据：立即停止，轮换凭据，清理 Git 历史，再从静态安全门禁重新开始。
- 真实服务验收失败：保留匿名失败证据，在开发报告中写明风险和未完成项；不得把候选版本标记为正式发布。
