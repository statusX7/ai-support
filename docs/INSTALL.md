# CrispAI 新手安装教程

这条路径适用于 Debian 12/13、Ubuntu 22.04/24.04 的正常服务器。准备一个拥有 root 或 `sudo` 权限的账号、可访问 GitHub/Docker/模型源的网络，以及你自己的第三方 AI、Crisp 和公网接入信息。Docker、Compose、`jq`、Python 等运行依赖由安装器补齐。

Debian 12 amd64 是完整空机实测平台；其他列出的系统具有安装分支，但不代表同等级整机实测。建议至少准备 2 CPU、4 GiB 内存和 25 GiB 可用磁盘。不要在受限容器里把不能启动 Docker daemon 当作普通服务器环境。

## 1. 执行唯一推荐安装命令

在 SSH 或服务器本机的交互终端复制并执行下面这一整行。无需 Git、GitHub 账号、Token、手工下载、上传、解压或切换到源码目录：

<!-- CRISPAI_RECOMMENDED_INSTALL_COMMAND -->
```bash
bash -c 'set -euo pipefail; u=https://raw.githubusercontent.com/statusX7/ai-support/main/get.sh; t=$(mktemp /tmp/crispai-get.XXXXXXXX); cleanup(){ r=$?; trap - EXIT; rm -f -- "$t"; exit "$r"; }; trap cleanup EXIT; f=; if [[ -s /etc/ssl/certs/ca-certificates.crt ]] && command -v curl >/dev/null 2>&1; then f=curl; elif [[ -s /etc/ssl/certs/ca-certificates.crt ]] && command -v wget >/dev/null 2>&1; then f=wget; else command -v apt-get >/dev/null 2>&1 || { printf "错误：当前系统无法自动安装安全下载工具。\n" >&2; exit 1; }; p=(); if (( EUID != 0 )); then command -v sudo >/dev/null 2>&1 || { printf "错误：需要 root 或 sudo 补齐安全下载工具。\n" >&2; exit 1; }; p=(sudo --); fi; "${p[@]}" env DEBIAN_FRONTEND=noninteractive apt-get -q -o APT::Color=0 -o Dpkg::Use-Pty=0 -o DPkg::Lock::Timeout=180 -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update; "${p[@]}" env DEBIAN_FRONTEND=noninteractive apt-get -q -o APT::Color=0 -o Dpkg::Use-Pty=0 -o DPkg::Lock::Timeout=180 -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 install --yes --no-install-recommends ca-certificates curl; f=curl; fi; if [[ "$f" == curl ]]; then curl -q --fail --location --silent --show-error --max-redirs 5 --proto "=https" --proto-redir "=https" --tlsv1.2 --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 --output "$t" "$u"; else wget --no-config --no-netrc --https-only --secure-protocol=TLSv1_2 --timeout=30 --tries=3 --output-document="$t" "$u"; fi; e=; while IFS= read -r l || [[ -n "$l" ]]; do e=$l; done < "$t"; [[ -s "$t" && "$e" == "# crispai-get-end" ]] && bash -n "$t" || { printf "错误：get.sh 下载不完整或语法无效。\n" >&2; exit 1; }; chmod 0700 "$t"; bash "$t"'
```

这条命令只先补齐取得 `get.sh` 必需的 CA/下载工具，然后把脚本保存到随机受限临时文件，检查完整结束标记和 Bash 语法后运行。`get.sh` 会：

1. 从公开仓库解析一个具体的 Latest 稳定 tag；
2. 把完整包与 `SHA256SUMS` 固定到同一个 tag 下载；
3. 严格核对唯一目标文件的 SHA-256，检查归档顶层目录、路径、文件类型、重复成员和展开上限；
4. 只有全部检查通过后，才从完整包调用原有生产安装器并进入 `1/10`。

整个下载过程不读取 GitHub Token，也不会把 AI/Crisp 凭据发往 GitHub。HTTPS 和 SHA-256 能验证传输与 Release 清单一致；它们不是独立代码签名，信任边界仍包括 GitHub 上的本仓库和维护者发布流程。

必须在交互终端运行。无 TTY、`curl | bash`、下载中断、HTTP 错误、HTML 登录页、校验不符或不安全归档都会在执行包内代码前失败，不会静默跳过检查。按提示修复网络或权限后，重新执行同一行即可。

### 如果 Prompt 或知识已经在服务器上

先进入这些文件所在的目录，再执行同一行命令。在线引导会记住调用时的真实目录；即使内部在 `/tmp` 下载和解压，向导中的相对路径仍以你的原目录为准。也可以直接在第 8/9 项粘贴正文，不准备文件。

## 2. 完成十项中文初始化

表中的地址与内容仅为格式示例，请填写自己的真实配置。Key 输入不回显文字或星号，这是正常的保护行为。

| 步骤 | 输入 | 说明 |
| --- | --- | --- |
| 1/10 | 第三方 AI Base URL | 可填根地址、已有 `/v1` 或合法代理前缀，例如 `https://api.example.com/proxy/v1`。 |
| 2/10 | AI API Key | 隐藏输入；只做少量有界能力请求。 |
| 3/10 | 模型 | 从实际模型列表按数字选择；可搜索/翻页，列表不支持时可手填。401/403 会提示先修凭据。 |
| 4/10 | Crisp Website ID | 对应目标 workspace，不是域名或邮箱。 |
| 5/10 | Crisp Token Identifier | 隐藏输入，与 AI Key 不同。 |
| 6/10 | Crisp Token Key | 隐藏输入，与 Identifier 配对。 |
| 7/10 | 公网域名或现有 HTTPS 地址 | 裸域名走受管 HTTPS；完整生产地址走已有反代。 |
| 8/10 | 客服 Prompt | 回车用安全默认；可直接输入、填文件路径，或输入 `::PASTE::` 粘贴多行。 |
| 9/10 | 知识库 | 支持文件/目录、`::PASTE::` 粘贴首库或 `::LIBRARIES::` 添加多个命名库；回车允许空库。 |
| 10/10 | 脱敏摘要 | `1` 确认安装、`2` 返回修改、`0` 取消。 |

文件来源的正常路径仍是十项主要输入；第 10 项确认后不会再问数据库密码、AnythingLLM Developer Key/workspace、n8n 凭据、内部端口、Embedding Key 或 Webhook Secret。多行正文与多个库属于第 8/9 项内的自选扩展，实际输入行数自然多于十次按键。

直接粘贴 Prompt 时，输入 `::PASTE::` 后粘贴正文，最后单独输入 `::END::`；`::CANCEL::` 放弃。正文需要这两个字面量时写 `\::END::` 或 `\::CANCEL::`。中文、Emoji、空行、Markdown、引号、反斜线和 `$` 都按数据保存，不作为 Shell 执行。

新装默认启用客服、欢迎语和人工确认按钮，人工自动恢复为 1800 秒，页面自动展开关闭。`0` 秒表示保持人工直至管理员恢复，不是立即恢复。升级会保留已有合法自定义值。

## 3. 确认后安装器自动做什么

确认后无需再执行内部部署命令。安装器会按顺序：

- 补齐运行依赖，安装或复用 Docker Engine、CLI、containerd 与 Compose，并验证 daemon 和真实测试容器；
- 创建受管目录和内部密钥，启动 PostgreSQL、AnythingLLM、n8n、需要的 Provider adapter，以及按配置启用的 Caddy；
- 创建/复用 AnythingLLM Developer Key 与 workspace，应用并回读 Prompt；
- 同步全部启用知识库，核对上传、pending 和实际索引；
- 导入、发布并验证生产 n8n workflow；
- 安装 `/usr/local/bin/crispai`，运行本地分层检查并保存真实安装事实。

默认部署目录是 `/opt/crisp-ai`。安装过程可因首次镜像、Embedding 模型下载和知识索引持续较长时间。Ctrl+C、EOF 或网络失败后，向导进度和已生成的有效密钥保存在受限部署状态中；重跑同一命令继续，不需要卸载或重新填写已完成项。

在线入口会按本机状态分流：

| 当前状态 | 再次执行同一命令 |
| --- | --- |
| 未安装 | 下载当前稳定正式包并直接初始化。 |
| 初始化中断 | 固定到记录的原版本并继续进度，防止混入另一版本。 |
| 同版本或旧版本已完整安装 | 直接打开受管 `crispai` 菜单，不静默升级或重问十项。 |
| 安全卸载且资料保留 | 用原版本包验证并恢复原路径、Prompt、知识和内部密钥。 |
| 目录非空但不属于本项目 | 下载前拒绝，不覆盖或删除该目录。 |

显式在线升级由 `crispai → 14. 更新与回滚` 完成；该入口同样使用固定 Release 与校验逻辑。降级必须走现有快照回滚，`get.sh` 不会静默安装低版本。

## 4. 看懂安装结果

安装完成会分别显示依赖、本地服务、应用配置、Provider、Crisp API、公网 Hook 和真实会话事实：

| 状态 | 含义 |
| --- | --- |
| `ready` | 当前本地组件及已配置外部链路均有足够的本次证据；实际回复仍服从总开关与单会话人工状态。 |
| `local-ready` | 本地服务、Prompt、知识和 workflow 已就绪，但 Crisp、DNS/HTTPS、Hook 或真实往返仍待完成/验证。 |
| `collecting` / `installing` | 初始化未完成，按屏幕所示阶段修复后重跑同一命令。 |
| `uninstalled-data-kept` | 程序已安全移除，配置和数据保留，可从原路径恢复。 |

退出码 `0` 表示所选操作完成；`2` 可表示用户明确取消，或本地安装成功但外部仍待接入，需结合屏幕文字与状态判断；`64` 是参数错误；`130` 是中断；其他非零代表对应阶段失败。`local-ready` 不会被冒充为已经接待客户，也无需因此重装本地组件。

## 5. 完成 Crisp 最小外部接入

脚本不能替你取得 Crisp 账号权限、购买域名、修改 DNS 或接管已有网站。

1. 在 Crisp 的 `Settings → Workspace Settings → Setup Instructions` 找到 Website ID。
2. 由 workspace owner 在 `Settings → Workspace Settings → Advanced configuration → API Token` 生成 Website Token 的 Identifier 与 Secret Key。不要发送给在线 Base64 网站。
3. 运行 `crispai`，在 Crisp 接入菜单的私密显示项取得本实例完整生产 Hook URL。
4. 在 Crisp 的 `Advanced configuration → Web Hooks` 登记该 URL，至少订阅 `message:send`、`message:received` 和 `message:updated`；不要使用 `/webhook-test/`。
5. 回服务器执行 `crispai doctor --full`，再只用自己的测试访客完成文本、按钮、真人暂停和另一个会话不受影响的验证。

裸域名只有在 DNS 正确、80/443 可用且证书签发网络正常时，安装器才能完成受管 Caddy。已有 Nginx、宝塔或 Caddy 时不会停站抢端口；按安装器生成的精确片段合入现有站点，再复查公网状态。凭据取得、Hook、Picker 按钮、欢迎页面 SDK 和故障排查见 [Crisp 接入教程](CRISP.md)。

真实 Crisp、真实第三方模型、DNS/TLS 和站点页面权限属于部署者的外部资源。缺少时源码与本地安装仍可交付，但报告必须标记 `External Validation Pending`，协议服务测试不能冒充真实客户往返。

## 6. 安装后只用 crispai

在任意目录执行：

```bash
crispai
```

常用非交互入口：

```bash
crispai status
crispai doctor
crispai doctor --local
crispai doctor --full
```

`status` 快速读取本地事实；普通 `doctor` 是非破坏检查；`--local` 不访问外部业务服务；`--full` 才执行已配置外部连接和极少量可能计费的合成模型检查。默认自检不会给客户发消息、打开客服、解除人工、重建知识或重启容器。自动修复必须显式选择 `doctor --fix` 或菜单中的修复项，并受其安全边界限制。

日常功能都在 [18 项中文菜单](MENU.md)：AI 地址/Key/模型、Prompt、多知识库、关键词 Picker、逐会话人工恢复、客服总开关、欢迎语、多级菜单、统计、配置迁移、备份、更新回滚、日志、服务维护和数字确认卸载。

客服总开关不等于停止容器、不等于把所有会话转人工，也不会隐藏 Crisp 聊天框。用户命中“人工”只看到确认按钮；只有有效按钮点击或真人公开回复才暂停当前 conversation，其他客户继续使用 AI。

## 7. 故障和高级入口

下载 403/404/429、DNS/TLS、无 TTY、checksum、Docker、模型 401/403、知识 pending、Hook 无回调或 `crispai` 找不到，按 [故障排查](TROUBLESHOOTING.md) 的对应项处理。不要使用 `curl -k`、修改 checksum、全局 Docker prune 或重新安装来掩盖配置错误。

指定正式版本、离线受控部署、发布资产人工审计和维护者打包流程属于高级操作，见 [发布与维护](RELEASE.md)。公开仓库的匿名安装不需要 Git/gh；GitHub CLI 只用于维护者发布或高级下载，不是客服运行依赖。

公开源码不包含你的 `.env`、Token、Prompt、知识、客户消息、数据库或完整备份。诊断包与 Issue 也只能上传脱敏内容，详见 [安全说明](SECURITY.md)。
