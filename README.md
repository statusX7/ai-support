# CrispAI / ai-support

自用 Crisp AI 客服：n8n + AnythingLLM + PostgreSQL，中文 Shell 初始化与日常管理。

从有权访问的 [私有 Release](https://github.com/statusX7/ai-support/releases) 下载完整包和 `SHA256SUMS`，上传服务器后：

```bash
sha256sum --check SHA256SUMS
tar -xzf ai-support-v1.1.0.tar.gz
cd ai-support-v1.1.0
sudo bash ./install.sh
crispai
```

安装器补齐受支持 Linux 的依赖；准备自己的 AI/Crisp 凭据和公网接入信息。关键词只展示人工按钮，点击才暂停本会话；真人公开回复立即暂停。源码发布不替代真实账号与 Hook 验证。

[部署](docs/INSTALL.md) · [18 项菜单](docs/MENU.md) · [Crisp 接入](docs/CRISP.md) · [配置](docs/CONFIG.md) · [排障](docs/TROUBLESHOOTING.md) · [安全](docs/SECURITY.md) · [发布报告](docs/reports/v1.1.0-report.md)
