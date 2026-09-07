# CrispAI / ai-support

自用 Crisp AI 客服：n8n + AnythingLLM + PostgreSQL，提供中文快速初始化与 Shell 管理。

在 Debian 12/13 或 Ubuntu 22.04/24.04 服务器终端执行唯一推荐命令（普通用户会调用 `sudo`）：

<!-- CRISPAI_RECOMMENDED_INSTALL_COMMAND -->
```bash
bash -c 'set -euo pipefail; u=https://raw.githubusercontent.com/statusX7/ai-support/main/get.sh; t=$(mktemp /tmp/crispai-get.XXXXXXXX); cleanup(){ r=$?; trap - EXIT; rm -f -- "$t"; exit "$r"; }; trap cleanup EXIT; f=; if [[ -s /etc/ssl/certs/ca-certificates.crt ]] && command -v curl >/dev/null 2>&1; then f=curl; elif [[ -s /etc/ssl/certs/ca-certificates.crt ]] && command -v wget >/dev/null 2>&1; then f=wget; else command -v apt-get >/dev/null 2>&1 || { printf "错误：当前系统无法自动安装安全下载工具。\n" >&2; exit 1; }; p=(); if (( EUID != 0 )); then command -v sudo >/dev/null 2>&1 || { printf "错误：需要 root 或 sudo 补齐安全下载工具。\n" >&2; exit 1; }; p=(sudo --); fi; "${p[@]}" env DEBIAN_FRONTEND=noninteractive apt-get -q -o APT::Color=0 -o Dpkg::Use-Pty=0 -o DPkg::Lock::Timeout=180 -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update; "${p[@]}" env DEBIAN_FRONTEND=noninteractive apt-get -q -o APT::Color=0 -o Dpkg::Use-Pty=0 -o DPkg::Lock::Timeout=180 -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 install --yes --no-install-recommends ca-certificates curl; f=curl; fi; if [[ "$f" == curl ]]; then curl -q --fail --location --silent --show-error --max-redirs 5 --proto "=https" --proto-redir "=https" --tlsv1.2 --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 --output "$t" "$u"; else wget --no-config --no-netrc --https-only --secure-protocol=TLSv1_2 --timeout=30 --tries=3 --output-document="$t" "$u"; fi; e=; while IFS= read -r l || [[ -n "$l" ]]; do e=$l; done < "$t"; [[ -s "$t" && "$e" == "# crispai-get-end" ]] && bash -n "$t" || { printf "错误：get.sh 下载不完整或语法无效。\n" >&2; exit 1; }; chmod 0700 "$t"; bash "$t"'
```

命令会匿名下载并校验同一稳定版本的完整正式包，随后进入十项中文初始化；无需 Git、GitHub 登录、手工解压或预装 Docker。该命令已在 v1.1.1 的独立 Debian 12 空机完成匿名实装；每版完整验收以对应发布回执为准。

先按[新手教程](docs/INSTALL.md)准备自己的 AI/Crisp 凭据和域名；`local-ready` 表示本地已就绪。还要登记 Crisp Hook、运行自检并收到第一条真实访客 AI 回复，才能确认接待链路。

装好后，在任意目录运行 `crispai`。日常检查用 `crispai doctor`；查看日志用 `crispai logs status`；编辑资料后先 `crispai apply --check`，再 `crispai apply`。资料路径和完整操作见[配置说明](docs/CONFIG.md)。

[新手安装](docs/INSTALL.md) · [18 项菜单](docs/MENU.md) · [Crisp 接入](docs/CRISP.md) · [配置](docs/CONFIG.md) · [排障](docs/TROUBLESHOOTING.md) · [安全](docs/SECURITY.md) · [发布说明](docs/releases/v1.2.0.md)
