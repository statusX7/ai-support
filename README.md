# CrispAI / ai-support

自用 Crisp AI 客服：n8n + AnythingLLM + PostgreSQL，提供中文快速初始化与 Shell 管理。

在 Debian 12/13 或 Ubuntu 22.04/24.04 服务器终端执行唯一推荐命令（普通用户会调用 `sudo`）：

<!-- CRISPAI_RECOMMENDED_INSTALL_COMMAND -->
```bash
bash -c 'set -euo pipefail; u=https://raw.githubusercontent.com/statusX7/ai-support/main/get.sh; t=$(mktemp /tmp/crispai-get.XXXXXXXX); cleanup(){ r=$?; trap - EXIT; rm -f -- "$t"; exit "$r"; }; trap cleanup EXIT; f=; if [[ -s /etc/ssl/certs/ca-certificates.crt ]] && command -v curl >/dev/null 2>&1; then f=curl; elif [[ -s /etc/ssl/certs/ca-certificates.crt ]] && command -v wget >/dev/null 2>&1; then f=wget; else command -v apt-get >/dev/null 2>&1 || { printf "错误：当前系统无法自动安装安全下载工具。\n" >&2; exit 1; }; p=(); if (( EUID != 0 )); then command -v sudo >/dev/null 2>&1 || { printf "错误：需要 root 或 sudo 补齐安全下载工具。\n" >&2; exit 1; }; p=(sudo --); fi; "${p[@]}" env DEBIAN_FRONTEND=noninteractive apt-get -q -o APT::Color=0 -o Dpkg::Use-Pty=0 -o DPkg::Lock::Timeout=180 -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update; "${p[@]}" env DEBIAN_FRONTEND=noninteractive apt-get -q -o APT::Color=0 -o Dpkg::Use-Pty=0 -o DPkg::Lock::Timeout=180 -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 install --yes --no-install-recommends ca-certificates curl; f=curl; fi; if [[ "$f" == curl ]]; then curl -q --fail --location --silent --show-error --max-redirs 5 --proto "=https" --proto-redir "=https" --tlsv1.2 --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 --output "$t" "$u"; else wget --no-config --no-netrc --https-only --secure-protocol=TLSv1_2 --timeout=30 --tries=3 --output-document="$t" "$u"; fi; e=; while IFS= read -r l || [[ -n "$l" ]]; do e=$l; done < "$t"; [[ -s "$t" && "$e" == "# crispai-get-end" ]] && bash -n "$t" || { printf "错误：get.sh 下载不完整或语法无效。\n" >&2; exit 1; }; chmod 0700 "$t"; bash "$t"'
```

命令会匿名下载并校验 Latest 正式包，随后进入十项中文初始化；无需 Git、GitHub 登录、手工解压或预装 Docker。安装完成后，在任意目录运行 `crispai`，状态检查用 `crispai doctor`。

请准备自己的 AI/Crisp 凭据与公网接入信息；`local-ready` 表示本地已就绪，仍需按教程完成 Crisp Hook 或其他外部授权。

[新手安装](docs/INSTALL.md) · [18 项菜单](docs/MENU.md) · [Crisp 接入](docs/CRISP.md) · [配置](docs/CONFIG.md) · [排障](docs/TROUBLESHOOTING.md) · [安全](docs/SECURITY.md) · [发布说明](docs/releases/v1.1.1.md)
