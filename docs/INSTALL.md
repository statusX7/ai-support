# CrispAI 新手安装教程

本页按第一次使用服务器的顺序说明：准备资料 → 一行安装 → 十项填写 → 域名与 Crisp Hook → 第一条真实回复。示例中的域名、ID、Key、模型和业务内容均为虚构，不能直接用于部署。

| 先准备什么 | 从哪里取得、怎样确认 |
| --- | --- |
| 服务器和管理账号 | 从自己的云服务器控制台取得 SSH 登录方式；账号须为 root 或能执行 sudo。不要把密码发到公开聊天或 Issue。 |
| 支持的系统 | Debian 12/13、Ubuntu 22.04/24.04 的正常服务器；Debian 12 amd64 有完整空机实测，其他系统有安装分支，不代表同等级整机实测。受限容器不等于可运行 Docker daemon 的服务器。 |
| 资源与网络 | 规划起点为至少 2 CPU、4 GiB 内存、25 GiB 可用磁盘；知识多时需要更多空间。须能访问 GitHub、Docker 镜像、Embedding 模型源、自己的 Provider 和 Crisp。 |
| 第三方 AI | 在供应商控制台取得 Base URL、API Key 和可用模型 ID，确认该 Key 有余额或可用配额。安装时会发少量合成能力请求，可能计费。 |
| Crisp 工作区 | 工作区拥有者准备 Website ID 和同一组 Website Token Identifier / Secret Key；来源见下方第 4～6 项，不要求注册 Marketplace Plugin。 |
| 专用客服域名 | 在自己的域名/DNS控制台准备一个子域名，例如 `support.example.com`；确定由本项目 Caddy 管理 HTTPS，还是接入已有网站反代。详见第 5 节。 |
| Prompt 与知识 | 可先用默认 Prompt 和空库，之后补充；也可准备 UTF-8 正文或有效 MD/TXT/PDF/DOCX。客户数据和内部政策不要作为公开测试资料。 |

Docker、Compose、`jq`、Python/PyYAML 和其他运行依赖由安装器补齐。无需预先安装这些软件，也无需登录 n8n 或 AnythingLLM 设置内部参数。

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

第 2、5、6 项是隐藏输入，不显示文字或星号；粘贴后按回车即可。下文 `3 → 2` 表示安装后先运行 `crispai`，选主菜单 3，再选子菜单 2。尚未确认安装时，可在第 10 项选 `2` 返回对应步骤修改。

### 1/10：第三方 AI Base URL

这是服务器调用模型的 API 地址，从供应商的 API 接入文档取得，不能填网页版聊天地址。格式例子：`https://api.example.com/proxy/v1`；合法根地址或已有 `/v1` 都可，程序保留代理前缀。地址通常不是密钥，但私有网关地址也不要公开。

验证：第 3 项会探测所选模型，装好后用 `3 → 7` 检查实际容器调用。填错用 `3 → 2`；整家供应商更换用 `3 → 10` 一起更换地址、Key 和模型。

### 2/10：AI API Key

这是供应商给程序的调用凭据，从同一供应商控制台的 API Keys 页面创建。虚构格式例子：`sk-demo-not-a-real-key`，实际格式以供应商为准。它是秘密，输入隐藏；不要填写 Crisp Token、账号密码或把 Key 发给 GitHub。

验证：安装的少量能力请求须得到有效正文；401/403 要先核对权限，模型列表不能单独证明推理可用。填错用 `3 → 3`，再 `3 → 7` 验证。

### 3/10：模型

这是该 Key 获准调用的模型 ID，来自供应商模型列表或文档。优先按实际列表数字选择；虚构格式例子：`demo-chat-model`。模型 ID 通常不是秘密。列表可搜索/翻页；供应商不提供列表时允许手填，不能猜一个名字当成验证成功。

验证：向导检查 Chat Completions / Responses 的实际回答，装好后 `3 → 7` 复核，图片能力用 `3 → 8`。填错用 `3 → 4` 重选或 `3 → 5` 手填。

### 4/10：Crisp Website ID

这是目标工作区的唯一 ID，从 Crisp 的 `Settings → Workspace Settings → Setup Instructions` 取得。虚构格式例子：`11111111-1111-4111-8111-111111111111`；它不是邮箱、域名或 Token。ID 本身通常会出现在网页初始化代码中，但关联信息仍按私密部署资料保管。

验证：装好后 `10 → 6` 检查当前工作区与 Token 的 REST 身份。填错用 `10 → 2`；换工作区连同 Token 一起用 `10 → 11`。上述路径来自 [Crisp 官方 Website Token 文档](https://docs.crisp.chat/guides/rest-api/authentication/website-token/)。

### 5/10：Crisp Token Identifier

这是 Website Token 密钥对的第一部分，由工作区拥有者在 `Settings → Workspace Settings → Advanced configuration → API Token → Generate Token` 取得，与第 6 项同次生成。虚构格式例子：`22222222-2222-4222-8222-222222222222`，不要据示例猜值。它按秘密处理、隐藏输入。

验证：`10 → 6` 使用整对凭据检查；填错用 `10 → 3`，新整对 Token 用 `10 → 11`。不需要注册 Plugin，也不需要自己构造请求 Header。

### 6/10：Crisp Token Key

这是同一密钥对的 Secret Key，从第 5 项页面同次生成，官方说明仅显示一次。虚构格式例子：`demo-crisp-secret-not-real`，真实格式以后台为准。它是秘密；妥善保存，勿发给在线 Base64 网站。

程序自动把 Identifier 与 Key 编码为 Basic 认证，并设置对应 `X-Crisp-Tier`；默认 Website Token 使用 `website`。验证用 `10 → 6`，填错用 `10 → 4`。中文版定位词、权限与配额说明见 [Crisp 接入](CRISP.md)。

### 7/10：公网域名或已有 HTTPS 生产地址

这是 Crisp 向本项目投递事件的公网入口，从自己的域名控制台或现有网站管理员取得。空闲服务器可填 `support.example.com`，由受管 Caddy 申请 HTTPS；已有反代则填以生产路径结尾的完整地址，例如 `https://support.example.com/webhook/crisp-webhook`。有代理前缀时保留前缀。不填查询串、URL Secret 或 `/webhook-test/`。

域名通常不是秘密；安装后生成的完整 Hook URL 含秘密。验证用 `10 → 6` 和 `crispai doctor`；填错用 `10 → 5`，改后重新登记 `10 → 7` 显示的准确 Hook。80/443 已占用时按提示接入现有反代，具体操作见第 5 节。

### 8/10：客服 Prompt

这是客服的身份、语气、业务边界和回答要求，由你编写。可直接回车采用安全默认；也可输入一句正文、普通文件路径，或输入 `::PASTE::` 粘贴多行。虚构正文例子：`优先依据当前知识回答；资料不足时简短追问。`；路径例子：`./客服资料/客服 提示.md`。内容属于业务资料，不公开。

Prompt 必须为有效 UTF-8、非空且非全空白，不含 NUL；上限 262144 字节（256 KiB），文件、单行和多行均按字节检查。验证看 `4 → 1` 的应用状态，`4 → 7` 可用虚构问题验证。填错用 `4 → 2` 粘贴或 `4 → 3` 导入；直接编辑稳定文件后须执行本页第 6 节的应用操作。

### 9/10：知识库

这是供检索的产品/规则/排障原文，从你有权使用的业务资料整理。回车允许空库，但空库不能证明客服懂你的业务。可填单文件或目录，例如 `./客服资料/排障 说明.PDF`；`::PASTE::` 会询问库名后粘贴正文；`::LIBRARIES::` 可逐个添加命名库，输入 `0` 结束添加。知识原文即使没有 Key 也可能敏感。

支持 MD/TXT/PDF/DOCX，扩展名不区分大小写；MD/TXT 须为 UTF-8，文件须为普通非空文件，单文档最多 52428800 字节（50 MiB）。粘贴知识正文最多 8388608 字节（8 MiB）；粘贴不是上传二进制 PDF/DOCX 的方式。目录层级/数量及稳定原文路径见 [配置限制](CONFIG.md)。扫描 PDF 没有可提取文字时，本项目不提供 OCR 保证；先自行转为可检索文字，再核对实际解析结果。

验证：`5 → 1` 查看索引，`5 → 12` 用自己的中文问题检查真实来源；上传成功不代表已经可检索。填错用 `5 → 5` 重新导入，误添条目用 `5 → 6`，索引待处理用 `5 → 10` 对账。

### 10/10：核对并确认

这是前九项的脱敏摘要，由程序生成，无需再找一个参数。核对地址、模型、Website ID 和资料来源；示例输入 `1` 开始安装，`2` 返回修改、`0` 取消。摘要隐藏 Key，但私有地址也不宜截图公开。

验证：确认后逐阶段检查会显示完成、待外部接入或明确故障。若尚未确认就发现错误，选 `2` 再输入 `1～9` 的步骤号；安装后按上述对应菜单修正，不重置全部配置。

文件来源的正常路径仍是十项主要输入；第 10 项确认后不会再问数据库密码、AnythingLLM Developer Key/workspace、n8n 凭据、内部端口、Embedding Key 或 Webhook Secret。多行正文与多个库属于第 8/9 项内的自选扩展，实际输入行数自然多于十次按键。

直接粘贴 Prompt 或知识时，输入 `::PASTE::` 后粘贴正文，最后单独一行输入 `::END::`；`::CANCEL::` 放弃。正文需要这两个字面量时写 `\::END::` 或 `\::CANCEL::`。中文、Emoji、空行、Markdown、引号、反斜线和 `$` 都按数据保存，不作为 Shell 执行。

字节数不等于汉字数或模型 token 数：`人工客服` 是 4 个汉字、UTF-8 下 12 字节；多行粘贴每行还计入换行。Shell 中可用 `wc -c < './客服资料/客服 提示.md'` 查看文件字节数。向导输入路径时直接粘贴含中文和空格的路径，不加 Shell 引号；路径按执行安装命令时所在目录解析，不按临时解压目录解析，文件不能是符号链接。

新装默认启用客服、欢迎语和人工确认按钮，人工自动恢复为 1800 秒，页面自动展开关闭。`0` 秒表示保持人工直至管理员恢复，不是立即恢复。升级会保留已有合法自定义值。

## 3. 确认后安装器自动做什么

确认后无需再执行内部部署命令。安装器会按顺序：

- 补齐运行依赖，安装或复用 Docker Engine、CLI、containerd 与 Compose，并验证 daemon 和真实测试容器；
- 创建受管目录和内部密钥，启动 PostgreSQL、AnythingLLM、n8n、需要的 Provider adapter，以及按配置启用的 Caddy；
- 创建/复用 AnythingLLM Developer Key 与 workspace，应用并回读 Prompt；
- 同步全部启用知识库，核对上传、pending 和实际索引；
- 导入、发布并验证生产 n8n workflow；
- 建立受管资料生效投影，安装 `/usr/local/bin/crispai`，运行本地分层检查并保存真实安装事实；
- 初始化日志保留策略和本项目系统级 systemd timer；已有合法自定义策略保留。

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

### 先让专用域名到达正确服务器

在自己的 DNS 控制台为 `support.example.com` 建 A 记录，记录值填服务器公网 IPv4。存在 AAAA 时必须指向同一服务可用的 IPv6；没有可用 IPv6 就由有权限的管理员删除该专用域名的错误 AAAA。不要复制示例 IP，也不要改其他站点记录。

新服务器且 80/443 未占用：第 7 项填裸域名，允许公网访问本项目所需 80/443，安装器生成受管 Caddy 和证书。它只公开生产 Hook 与无密钥网页路由；根路径返回 404 是预期。Caddy 的默认 ACME 验证依赖正确 A/AAAA 与外部可达的 80 或 443，运行状态不代表证书已签发。依据：[Caddy 自动 HTTPS](https://caddyserver.com/docs/automatic-https)。

已有 Nginx、宝塔或 Caddy：第 7 项填完整生产 HTTPS 地址。管理员按安装生成的 `config/crispai-nginx.conf` 或 `config/crispai-caddy.conf` 合入对应站点，保留实际前缀、上游端口和受限路由，再用该反代的配置检查命令验证后重载。生成片段不代表已经生效；还须按 [Crisp 接入的日志保护](CRISP.md)处理包含 Secret 的反代错误日志，外部 Caddy 尤其需要管理员合并全局过滤。程序不替你覆盖原站点或抢占端口；不要把整个 n8n 编辑器暴露到公网。

Cloudflare 使用者：灰云 `DNS only` 让请求直达源站，可用于核对专用客服域名的 DNS/TLS；橙云 `Proxied` 经 Cloudflare，公开解析显示 Cloudflare IP 属正常现象。若使用橙云，源站 HTTPS 就绪后选 `Full (strict)`，保持有效且匹配域名的源站证书。不能用 `Flexible` 或关闭校验掩盖源站 TLS 故障。灰云会公开源站 IP，是否切换由域名管理员决定。依据：[代理状态](https://developers.cloudflare.com/dns/proxy-status/)、[Full (strict)](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/)。

Hook 是机器发起的 JSON POST，Crisp 无法像访客浏览器一样完成 JavaScript Challenge、验证码或交互登录；Cloudflare Challenge 若覆盖该路径会返回 HTML 并阻断接入。仅由有权限的管理员核对该专用主机和确切 Hook/SDK 路径，调整必要的挑战、缓存或重定向规则；保留项目 Secret 鉴权，不关闭全站防护。本项目不自动登录云账户或修改 DNS/WAF。依据：[Cloudflare Challenge 兼容性](https://developers.cloudflare.com/cloudflare-challenges/challenge-types/challenge-pages/)。

### 登记 Hook，再验证真实消息

1. 在私密终端运行 `crispai → 10 → 7`，确认后复制本实例完整生产 Hook URL。它带随机秘密，不要截图或公开。
2. Crisp 后台选择目标工作区，在 `Settings → Workspace Settings → Advanced configuration → Web Hooks → Add a Web Hook` 填名称和该 URL；勾选 `message:send`、`message:received`、`message:updated`，点 `Add Hook Target`。不使用 `/webhook-test/`。详细中文定位见 [Crisp 接入](CRISP.md)，英文路径已按[官方步骤](https://docs.crisp.chat/guides/web-hooks/website-hooks/)核对。
3. 回服务器运行 `crispai doctor`。默认不调用模型；需要额外少量合成模型验证才用 `crispai doctor --full`，可能计费。REST 认证、公网响应、真实 Hook 收件要分别看。
4. 用自己的网站聊天框新建专用测试访客 A，问一句已入库的虚构问题。确认后台收到访客消息、`10 → 12` 出现当前配置的可信 Hook/往返观察、聊天框收到本项目 AI 回复，再用 `5 → 12` 核对知识来源。仅有容器 healthy、REST 200、生产端点的鉴权 401 或后台访客消息，均不能算完整接待通过。
5. 再用独立浏览器配置文件建访客 B。A 输入“人工”应只显示按钮；未点按钮时 A 的下一问仍可 AI 回复。A 点击确认后只暂停 A，B 继续 AI；后台对 A 真人公开回复维持人工。恢复秒数、总开关及图片后续问答按 [最小验收](CRISP.md) 继续核对。

Hook 后台的最后调用状态可能延迟刷新。没收到真实 AI 回复时保留隔离验收条件，按[排障](TROUBLESHOOTING.md)查订阅、地址、Secret 和反代；不以手工向 Hook 注入请求代替 Crisp 官方投递，也不因 `local-ready` 就删除验收所需账号。

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

`status` 快速读取本地事实；普通 `doctor` 做有界只读检查，不推理；`--local` 不访问外部业务服务；`--full` 额外执行极少量可能计费的合成模型检查。默认自检不会给客户发消息、打开客服、解除人工、重建知识或重启容器。自动修复必须显式选择 `doctor --fix` 或菜单中的修复项，并受其安全边界限制。

通过 `16 → 8` 查看实际资料路径。默认 Prompt 为 `/opt/crisp-ai/config/prompt.md`，知识定义为 `/opt/crisp-ai/knowledge/catalog.json`，原文保存在 `knowledge/kb_*/sources`。建议用菜单 4/5 修改；熟悉文件编辑的管理员可直接编辑已有原文，完成后执行：

```bash
crispai apply --check
crispai apply
```

前一条只校验，后一条才应用变更；菜单等价入口是 `16 → 6 → 1`。未编辑完的坏 JSON、空 Prompt 或超限文件不会替代上一有效生效资料。原文没变而外部 Prompt/受管索引关系偏离时，用 `16 → 6 → 2` 重新同步并回读；它不是全量重建或远端正文逐字审计。不要手改 `config/materials-applied.json`；应用失败、`applying` 或索引重建边界见 [配置说明](CONFIG.md)。

日志查看用 `crispai logs status` / `crispai logs show n8n --lines 100 --since 2h`，或菜单 15。默认新装为 7 天、每份 10 MiB、最多 5 份；Docker 是容量轮转，并非精确按天删除。调整和清理先预览再数字确认，详见[菜单 15](MENU.md)。

日常功能都在 [18 项中文菜单](MENU.md)：AI 地址/Key/模型、Prompt、多知识库、关键词 Picker、逐会话人工恢复、客服总开关、欢迎语、多级菜单、统计、配置迁移、备份、更新回滚、日志、服务维护和数字确认卸载。

客服总开关不等于停止容器、不等于把所有会话转人工，也不会隐藏 Crisp 聊天框。用户命中“人工”只看到确认按钮；只有有效按钮点击或真人公开回复才暂停当前 conversation，其他客户继续使用 AI。

## 7. 故障和高级入口

下载 403/404/429、DNS/TLS、无 TTY、checksum、Docker、模型 401/403、知识 pending、Hook 无回调或 `crispai` 找不到，按 [故障排查](TROUBLESHOOTING.md) 的对应项处理。不要使用 `curl -k`、修改 checksum、全局 Docker prune 或重新安装来掩盖配置错误。

指定正式版本、离线受控部署和旧版在线升级见 [可选高级维护](ADVANCED.md)；发布资产审计和维护者打包流程见 [发布流程](RELEASE.md)。公开仓库的匿名安装不需要 Git/gh；GitHub CLI 只用于维护者发布或高级下载，不是客服运行依赖。

公开源码不包含你的 `.env`、Token、Prompt、知识、客户消息、数据库或完整备份。诊断包与 Issue 也只能上传脱敏内容，详见 [安全说明](SECURITY.md)。
