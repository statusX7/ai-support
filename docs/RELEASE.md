# 发布说明

## 结果分层

源码发布、真实本地安装和用户外部实例验收分别记录：

- `STATIC` 与 `UNIT-STUB` 必须无失败；
- `REAL-BOOTSTRAP` 必须至少在一套初始无 Docker/Compose 的受支持 systemd Linux 上通过；
- `REAL-LOCAL-INTEGRATION` 必须使用真实 PostgreSQL、AnythingLLM、n8n 和生产 workflow；
- 缺少用户自有 Crisp/Provider/DNS 时，`EXTERNAL-E2E` 可标记 `External Validation Pending`，不得写成通过。

外部账号不能阻塞源码修复发布，但依赖自动安装、Docker daemon、本地容器和内部应用初始化不能豁免。详细定义见 [测试说明](TESTING.md)。

## v1.0.1 发布门禁

- `VERSION`、`config/app.yaml`、n8n 出站版本、CHANGELOG、release notes 与报告一致；
- `install.sh` 实际按“最小依赖 → 十项向导 → Docker → 配置 → 应用初始化 → 分层检查”运行；
- Bash 语法、ShellCheck、配置解析、Bootstrap/Wizard/管理/业务回归通过；
- Debian 12 干净 VM 从无 Docker 到本地应用完成的真实证据可追溯；
- 从 v1.0.0 更新、重复安装、重启持久化、故障回滚、安全卸载和同路径恢复经过隔离验收；
- 发布包从干净提交的固定已跟踪清单生成，不包含 `.git`、`.env`、实际配置、知识数据、备份、日志、测试缓存或开发工具；
- 当前树、Git diff、Git 历史、发布包和脱敏转录未命中真实密钥；
- `docs/reports/v1.0.1-report.md` 如实列出每个测试层及外部待验证项。

自动回归：

```bash
./tests/run.sh
./tests/test_release_package.sh
```

缺少外部账户时，既有源码测试的显式分层模式仍可使用：

```bash
AI_SUPPORT_RELEASE_TEST=1 \
AI_SUPPORT_EXTERNAL_VALIDATION_PENDING=1 \
./tests/run.sh
```

该变量不会把真实失败改写为跳过，也不能代替独立 VM 验收。

## 一致性检查

```bash
test "$(< VERSION)" = v1.0.1
grep -Fq 'version: v1.0.1' config/app.yaml
grep -Fq "ai_support_version: 'v1.0.1'" n8n/workflow.json
grep -Fq '## v1.0.1' CHANGELOG.md
test -f docs/reports/v1.0.1-report.md
test -f docs/releases/v1.0.1.md
git diff --check
./tests/test_static_security.sh
```

## 构建正式资产

打包器要求工作树和 index 无修改，只收录显式清单中的已跟踪文件：

```bash
./scripts/package-release.sh --output-dir dist
cd dist
sha256sum --check SHA256SUMS
```

必须在另一目录解压资产并再次运行 `--help`、版本检查、静态/配置检查和可执行安装入口。发布后还要从远端下载同一资产，核对 SHA-256、顶层目录、关键模块与版本。

## GitHub 发布

目标为 private repository `statusX7/ai-support`。使用 GitHub CLI 默认登录状态；不要创建空 `GH_CONFIG_DIR`，也不要仅根据 `GH_TOKEN` 是否为空判断权限：

```bash
gh auth status
test "$(gh api user --jq .login)" = statusX7
test "$(gh repo view statusX7/ai-support --json visibility --jq .visibility)" = PRIVATE
git ls-remote --heads --tags origin
```

保留 v1.0.0，不 force push。完成报告和最终提交后：

```bash
git tag -a v1.0.1 -m "v1.0.1"
git push --atomic origin main v1.0.1
gh release create v1.0.1 \
  dist/ai-support-v1.0.1.tar.gz \
  dist/SHA256SUMS \
  --repo statusX7/ai-support \
  --verify-tag \
  --title "v1.0.1" \
  --notes-file docs/releases/v1.0.1.md
```

发布后核对 Release 非 draft/prerelease、资产大小和摘要；若 push 已成功而 Release 创建失败，只重试创建 Release，不移动远端 tag。
