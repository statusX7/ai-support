# CrispAI / ai-support

自用 Crisp AI 客服：n8n + AnythingLLM + PostgreSQL，中文 Shell 初始化与日常管理。

公开仓库，无需 GitHub 登录或 Token。[新手安装教程](docs/INSTALL.md)提供浏览器下载、服务器直链下载和逐项填写说明。

从 [v1.1.0 Release](https://github.com/statusX7/ai-support/releases/tag/v1.1.0) 下载 `ai-support-v1.1.0.tar.gz` 和 `SHA256SUMS`，上传服务器同一目录后（root 去掉 `sudo`）：

```bash
sha256sum --check --strict SHA256SUMS &&
tar -xzf ai-support-v1.1.0.tar.gz &&
cd ai-support-v1.1.0 &&
sudo bash ./install.sh
```

安装器自动补齐依赖；日常管理在任意目录输入 `crispai`。请准备自己的 AI/Crisp 凭据和公网接入信息，按教程登记 Hook；`local-ready` 只表示本地就绪，不能当作已接待客户。公开源码不包含你的凭据、知识或数据。

[部署](docs/INSTALL.md) · [18 项菜单](docs/MENU.md) · [Crisp 接入](docs/CRISP.md) · [配置](docs/CONFIG.md) · [排障](docs/TROUBLESHOOTING.md) · [安全](docs/SECURITY.md) · [发布报告](docs/reports/v1.1.0-report.md)
