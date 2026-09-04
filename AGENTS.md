# AGENTS.md

## 项目范围

- 项目名称：`ai-support`。
- 所有项目操作只能在 `/root/projects/crispai` 内进行。
- 运行时组合 Crisp、n8n、AnythingLLM 与 OpenAI Compatible API，不重复实现 RAG、向量数据库、文档解析或 LLM 管理。

## 开发规则

- 使用简体中文编写新增的用户界面、操作说明和文档。
- 保持代码标识符、协议字段、配置键、环境变量和第三方产品名称的英文原名。
- 所有 shell 脚本使用 Bash，并包含 `set -euo pipefail`。
- 脚本必须幂等、可重复执行、妥善处理错误，且不得破坏既有环境。
- 不得提交 Token、Webhook Secret、用户数据、真实配置或含凭据的日志。
- 不得在日志中输出 API Key；输入、路径和 Webhook 必须进行安全校验。
- 保持目录结构和文件命名清晰，不创建临时式或带序号的替代脚本。

## 版本与提交

- 每批修改必须同步更新 `VERSION` 和 `CHANGELOG.md`。
- Git commit message 使用英文，并以版本号开头，例如 `v0.1.1 add ai provider detection`。
- 按 Phase 1 至 Phase 6 分阶段实现、验证和提交。

## 验证

- shell 脚本须通过 `shellcheck`。
- Docker 配置须通过 `docker compose config`。
- 测试不得使用真实凭据或真实用户数据。
