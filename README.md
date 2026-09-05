# ai-support

用于自部署 Crisp AI 自动客服，组合 n8n、AnythingLLM 与 OpenAI Compatible API。

支持 Debian 12/13、Ubuntu 22.04/24.04（amd64/arm64）。从完整发布包解压后运行：

```bash
sudo bash ./install.sh
```

安装器会自动补齐普通运行依赖与 Docker Engine/Compose，并通过十项中文输入完成初始化。需要准备自己的 AI API、Crisp 凭据和公网域名或现有 HTTPS Webhook 地址。

详细安装、配置和安全说明见 [`docs/`](docs/INSTALL.md)。
