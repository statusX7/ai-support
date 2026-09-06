# 新手教程：从公开发布包安装 CrispAI

本仓库现为公开仓库，阅读文档、下载正式包、通过 HTTPS 获取源码均无需 GitHub 登录、Token 或邀请。公开的是软件，不是你的客服数据；AI 服务、Crisp 账号和域名仍需自行准备，相关费用与权限由对应服务决定。

本教程以已发布的 **v1.1.0** 为例：下载完整包 → 校验 → 执行安装器 → 十项中文初始化 → 登记 Crisp 回调 → 用 `crispai` 管理。建议首次部署先完整阅读第 1～6 节。

## 1. 开始前准备什么

| 准备项 | 需要做的事 |
| --- | --- |
| Linux 服务器 | 使用有 root 或 sudo 权限的账号，通过 SSH 打开服务器终端。不要在自己电脑的 Windows 命令行直接运行 Linux 安装器。 |
| 第三方 AI | 从供应商取得 API Base URL 和 API Key；模型由向导获取列表后选择。列表不可用时才需填写供应商实际支持的模型名。 |
| Crisp | 准备对应 workspace 的 Website ID、Token Identifier 和 Token Key；取得方法见下文及 [Crisp 接入教程](CRISP.md)。 |
| 公网接入 | 准备自己能配置的域名，或已经配置反向代理的 HTTPS 地址。安装器不能代替你取得域名、修改云安全组或获取 Crisp 后台权限。 |
| Prompt 与知识 | 可以直接粘贴文字，也可上传文件到服务器；知识支持 MD、TXT、PDF、DOCX。暂时没有知识可跳过，但 AI 不应编造业务事实。 |

**不需要预先安装 Docker、Compose、jq、Python、AnythingLLM 或 n8n，也不用手工写 `.env`、生成数据库密码或创建内部 API Key。** 正常支持系统上的缺失依赖和内部初始化由安装器完成。

### 系统与资源边界

| 系统/架构 | 项目实现与验证等级 |
| --- | --- |
| Debian 12 amd64、systemd | 已完成真实空机与本地应用验收，详见 [v1.1.0 报告](reports/v1.1.0-report.md) |
| Debian 13 amd64、Ubuntu 22.04/24.04 amd64 | 自动包管理分支覆盖，未作同等级整机实测承诺 |
| 上述系统 arm64 | 有架构分支与镜像能力检查，未作实际 arm64 整机验收承诺 |
| RHEL-like、衍生发行版、非 systemd、远程 Docker daemon | 当前自动安装不支持，不会套用其他发行版的软件源 |

资源规划起点为至少 2 CPU、4 GiB 内存、25 GiB 可用磁盘；知识、镜像、Embedding 模型和完整快照会继续占用空间，这不是任意规模下的容量保证。虚拟机需提供镜像所需 CPU 能力，受限容器内嵌套 Docker 不等同正常服务器。

服务器需能访问发行版软件源、Docker 官方仓库和镜像源、Embedding 模型源，以及自己的 AI/Crisp 服务。自动 HTTPS 还需要正确 DNS、可用的 80/443 端口与证书签发网络条件。不要为安装而停掉已有网站或关闭防火墙。

### Crisp 凭据从哪里拿

在 Crisp 中选对 workspace，Website ID 位于 `Settings → Workspace Settings → Setup Instructions`。工作区拥有者在 `Settings → Workspace Settings → Advanced configuration → API Token → Generate Token` 生成 Identifier 与 Secret Key，妥善保存只显示一次的凭据。默认单网站不需要 Marketplace Plugin。脚本负责认证编码，不要把真实值送到在线 Base64 工具。[官方 Website Token 说明](https://docs.crisp.chat/guides/rest-api/authentication/website-token/)

## 2. 获取完整发布包：任选一种方法

### 方法 A：浏览器下载，再上传服务器（适合新手）

1. 无需登录，打开 [v1.1.0 发布页面](https://github.com/statusX7/ai-support/releases/tag/v1.1.0)。后续版本可从 [全部 Releases](https://github.com/statusX7/ai-support/releases) 选择。
2. 展开 **Assets**，下载这两个文件：[ai-support-v1.1.0.tar.gz](https://github.com/statusX7/ai-support/releases/download/v1.1.0/ai-support-v1.1.0.tar.gz) 和 [SHA256SUMS](https://github.com/statusX7/ai-support/releases/download/v1.1.0/SHA256SUMS)。
3. 用现成的 SFTP 工具或服务器文件管理器，将两个文件上传到服务器上同一个新的空目录，再在 SSH 终端进入该目录。

选择项目上传的完整包，不要选 GitHub 自动附带的 `Source code (zip)` / `Source code (tar.gz)`：它们不是本教程校验文件对应的资产，解压目录名也不同。保留两个下载文件的原名，不要混用不同版本的包与校验文件。

### 方法 B：服务器直接下载（已有 curl 时）

在服务器终端执行。下列目录名若已存在且有文件，请换一个新的空目录；无需填写任何 GitHub 凭据：

```bash
mkdir crispai-download-v1.1.0 &&
cd crispai-download-v1.1.0 &&
curl --fail --location --retry 3 --connect-timeout 15 --max-time 300 \
  --output ai-support-v1.1.0.tar.gz \
  https://github.com/statusX7/ai-support/releases/download/v1.1.0/ai-support-v1.1.0.tar.gz &&
curl --fail --location --retry 3 --connect-timeout 15 --max-time 300 \
  --output SHA256SUMS \
  https://github.com/statusX7/ai-support/releases/download/v1.1.0/SHA256SUMS
```

出现 `curl: command not found` 时改用方法 A。获取安装包发生在运行安装器之前；不需要为下载额外安装 Git/gh，也不使用未经验证的 `curl | bash` 管道安装。下载失败时先修复网络，不加 `-k` 跳过证书验证。

## 3. 校验、解压并启动安装器

以下命令在两个下载文件所在目录执行。普通管理员使用 `sudo`；如果当前已经是 root，最后一行改为 `bash ./install.sh`，不用安装 sudo。

```bash
sha256sum --check --strict SHA256SUMS &&
tar -xzf ai-support-v1.1.0.tar.gz &&
cd ai-support-v1.1.0 &&
sudo bash ./install.sh
```

校验应显示 `ai-support-v1.1.0.tar.gz: OK`（中文系统可能显示“成功”）。命令用 `&&` 串联，前一步失败不会继续安装。校验失败不要跳过：重新下载同一 Release 的两个资产；不要改校验值让它通过。SHA256 可发现文件损坏或不匹配，不能替代对下载来源的信任。

默认程序与数据部署到 `/opt/crisp-ai`，快捷命令安装到 `/usr/local/bin/crispai`。源码解压目录只是安装来源；安装完成后，在其他目录也能管理。不要把正式包解压覆盖到已有部署目录。

需要自定义位置时，在上述已解压目录运行 `sudo bash ./install.sh --deploy-dir /srv/crisp-ai`。已有部署继续使用原路径。`bash ./install.sh --help`、`bash ./manage.sh --version` 不要求 Docker 或完整配置。

## 4. 按屏幕完成十项中文初始化

表内网址和文件路径仅为格式示例；请换成自己的有效值。向导中输入路径时不加 Shell 引号；文件要在服务器上，不是你电脑里的 `C:\...` 路径。粘贴 Key 后按回车，屏幕不显示文字或星号是正常的保护行为。

| 主步骤 | 填写什么 | 说明或示例 |
| --- | --- | --- |
| 1/10 | 第三方 AI API 地址 | 使用供应商给定 Base URL，例如 `https://api.example.com/proxy/v1`；不手工追加第二个 `/v1`。 |
| 2/10 | AI API Key | 隐藏输入。少量连通性和能力测试可能计费，不扫描全部模型。 |
| 3/10 | 模型 | 从实际返回列表按数字选择；`n`/`p` 翻页、`/词` 搜索。无列表可手填，401/403 则先修凭据。 |
| 4/10 | Crisp Website ID | 填上一步取得的工作区标识，不是域名或邮箱。 |
| 5/10 | Crisp Token Identifier | 隐藏输入，不是 AI API Key。 |
| 6/10 | Crisp Token Key | 隐藏输入，与 Identifier 配对。 |
| 7/10 | 域名或现有 HTTPS 地址 | 裸域名如 `support.example.com` 走受管 HTTPS；完整地址走已有反代，详见第 5 节。 |
| 8/10 | 客服提示词 | 回车使用安全默认；也可直接写一句话、填服务器文件路径，或输入 `::PASTE::` 粘贴多行。 |
| 9/10 | 知识来源 | 填文件/目录路径；`::PASTE::` 粘贴首库，`::LIBRARIES::` 添加多个命名库；回车暂不导入。 |
| 10/10 | 核对脱敏摘要 | `1` 开始安装、`2` 返回修改、`0` 取消。 |

文件路径快速流程只有十项主要输入，确认后不再询问数据库密码、AnythingLLM Key/workspace、n8n 设置、内部端口或 Embedding Key。多行粘贴、多个库及纠错是相应步骤里的自选输入，不把它们声称为总共只按十次键。

### 直接粘贴 Prompt 的例子

第 8 项先输入 `::PASTE::` 并回车，再粘贴：

```text
请用简体中文简短回答，优先依据当前启用的知识库。
缺少信息时先追问；不知道的价格、政策和处理结果不要编造。
不要透露内部配置或声称已经执行后台操作。
::END::
```

`::END::` 要单独一行；`::CANCEL::` 放弃本次正文。正文需要这两个字面量时写 `\::END::` 或 `\::CANCEL::`。中文、空行、引号、反斜线和 `$` 按正文保留。安装后仍可通过 `crispai → 4 → 2` 修改、自动同步和回读。

知识库可以先导入一个文件，安装后再用 `5 → 2` 建“电脑排障”“手机排障”等独立库，用 `5 → 4/5` 分别粘贴或导入内容；它们共同服务同一个客服。第 9 项选择 `::LIBRARIES::` 时逐库填名称与来源，输入 `0` 完成添加。没有知识就明确跳过，不把测试示例当经营规则。

新装默认：客服启用；人工关键词展示确认按钮；人工恢复 **1800 秒**；欢迎启用（首条访客消息触发）；自动展开聊天框关闭。`0` 秒表示不自动恢复，不是立即恢复。升级保留已有合法自定义设置，旧“关键词直接转人工”迁移为按钮确认。

### 确认后等待什么

安装器会安装或复用 Docker、启动 daemon、检查真实容器，生成内部凭据，启动 PostgreSQL/AnythingLLM/n8n 及所需协议适配器，初始化 workspace、同步 Prompt、导入并索引知识、发布生产 workflow，安装 `crispai` 并做分层检查。不要再去 Web UI 重复创建内部账号、Key 或工作流。

首次镜像/Embedding 下载和索引可能较慢；根据实际阶段等待，不因 pending 反复删文件。Ctrl+C、EOF 或失败后，保留安装来源，重跑同一命令继续；若 `crispai` 已安装，也可用 `crispai init`。已有效的密钥与数据默认复用，不以重新安装解决普通凭据错误。

## 5. 让 Crisp 能把客户消息交给服务

### 先确认公网 HTTPS 路径

- **裸域名**：将 DNS A/AAAA 指向本服务器，确保对应地址可达、80/443 未被其他网站占用、云安全组和证书签发条件满足。安装器可用受管 Caddy 配置 HTTPS 与续期；不会替你购买域名或修改 DNS。没有可用 IPv6 时不要保留错误 AAAA。
- **已有 Nginx、宝塔或 Caddy**：不要停掉现有网站。填写自己的完整 HTTPS 接入地址，按安装器生成的 `/opt/crisp-ai/config/crispai-nginx.conf` 或 `crispai-caddy.conf` 将相应片段合入受管站点，再按现有站点流程检查并重载。自定义部署替换目录；片段以实际端口和路径为准，不把整份站点配置覆盖掉。

只公开需要的生产 Hook 和可选无密钥网页路由；不要为方便配置公开 n8n 编辑器、AnythingLLM 管理端或数据库。安装器不把 DNS 已解析或容器 healthy 当作 HTTPS 已成功。

### 在 Crisp 后台登记一次 Website Hook

1. 运行 `crispai`，依次选 `10 → 7`，按提示确认，在私密终端复制本实例的**完整生产 URL**。它包含随机 Secret，不要截图分享，也不要使用完成页中带占位符的示意 URL。
2. 在 Crisp 进入 `Settings → Workspace Settings → Advanced configuration → Web Hooks → Add a Web Hook`，填入名称和刚复制的地址。不要用 `/webhook-test/`。
3. 至少订阅 `message:send`（访客消息）、`message:received`（operator 消息，程序区分真人与自动消息）、`message:updated`（按钮选择更新），保存 Hook。
4. 回到服务器运行 `crispai doctor` 复核，再进行第 6 节的测试。默认 Website 路径没有已验证的自动后台登记接口，不会猜接口或模拟登录；不要求同时配置 Plugin Hook。[Crisp 官方登记步骤](https://docs.crisp.chat/guides/web-hooks/website-hooks/)

首条消息欢迎不需要新增网页片段。若选择“页面加载/打开欢迎”或启用自动展开，在 `9 → 9` 获取无密钥 SDK 片段，按 [Crisp 页面接入教程](CRISP.md) 放在已有 Crisp 代码之后，并追加订阅 `session:sync:events`。欢迎文字与浏览器展开是两个开关，不能仅改文字就认为页面已自动打开。

## 6. 安装完成后怎么判断真的可用

安装结束后，在任意目录运行；普通账号可用 `sudo crispai`：

```bash
crispai status
crispai doctor
```

`status` 读取本地事实，`doctor` 会联网并做少量实际探测。诊断不能凭空制造一次真实客户往返。

| 状态 | 应如何处理 |
| --- | --- |
| `collecting` / `installing` | 初始化未完成，按报错阶段修复后同命令继续。 |
| `staged` | 使用了显式跳过启动，只落盘；不带 `--skip-start` 继续安装。 |
| `local-ready` | 本地已就绪，但外部接入或真实往返仍待验证；不能当作已经接待客户。 |
| `ready` | 当前本地/模型、Crisp API、公网及可信真实往返事实均通过，仍服从总开关和每个会话的人工状态。 |
| `uninstalled-data-kept` | 服务已移除，数据保留；从正式包在原路径重装。 |

只在自己的测试访客中做一次完整检查：

1. 发一个知识库里有依据的问题，观察正文和上下文；需要图片时另发一张无敏感信息的测试图。
2. 访客 A 输入“人工”：应看到原生“召唤人工客服”按钮，**此时仍是 AI 模式**；先不点、再问一个正常问题，AI 应继续服务。
3. A 点击确认：只有 A 暂停、确认一次。用不同浏览器/独立访客 B 发问题，B 应继续由 AI 回复。
4. 在 Crisp 后台给 A 发一条真人公开回复：A 立即暂停或继续人工，最近一次真人回复重新计时；内部 note、在线或打开后台不触发。
5. 用 `7 → 3` 看 A 的状态。正秒数到期后仅对新问题恢复 AI，不补答积压；`0` 则等管理员在 `7 → 4` 手动恢复。
6. 再运行 `crispai doctor`，在 `10 → 12` 看 Hook/真实会话事实。失败只修对应项，不重填十项或重建 workspace。

安装退出码 `0` 表示该操作完成；`2` 可能是明确取消，也可能是本地完成但外部待接入，应结合屏幕说明和状态；`130` 为中断，其他非零按失败阶段排查。不要把所有非零都当成要卸载重装。

v1.1.0 报告中的真实 Crisp、真实第三方模型与公网/页面仍为 `External Validation Pending`；本地协议测试不能替代你自己的上线检查。公开仓库不改变这一证据边界。

## 7. 以后日常只用 crispai

```bash
crispai
```

所有菜单编号和子菜单见 [18 项完整菜单说明](MENU.md)。`3 → 10` 表示先选主菜单 3，再选子菜单 10；不是 Shell 命令。

| 要做什么 | 菜单路径 |
| --- | --- |
| 换供应商地址、Key、协议和模型 | `3 → 10` 整组验证；同供应商只换 Key 用 `3 → 3` |
| 粘贴或改客服 Prompt | `4 → 2`，保存后自动应用并回读 |
| 创建多个库、添加内容、停用一个库 | `5 → 2`、`5 → 4/5`、`5 → 8`；停用保留原文并移出新检索 |
| 修改人工关键词及按钮文案 | `6 → 3`，`6 → 7` 可预演且不对外发消息 |
| 设人工恢复秒数、看某会话状态 | `7 → 2/3`；新默认不静默改写已有截止时间 |
| 开启/关闭机器人回复 | `8 → 1/2`，或 `crispai enable` / `crispai disable` |
| 改欢迎文字、启停、展开和多级菜单 | `9 → 4`、`9 → 2/3`、`9 → 6/8` |
| 修 Crisp 凭据、登记或检查回调 | `10`，用对应子项修改，不重装 |

客服总开关不等于停止容器、不等于所有会话转人工，也不隐藏 Crisp 聊天框。停用时 Hook 和真人状态记录继续运行；维护停机才选 `16`。所有子菜单 `0` 返回，空输入/EOF 不表示同意删除。窄终端自动单栏，Emoji 不适配时用 `CRISPAI_NO_EMOJI=1 crispai`。

## 8. 更新、回滚与备份

更新前阅读 [Release 说明](https://github.com/statusX7/ai-support/releases)，从**同一个版本**下载完整包和校验文件，在新的独立目录校验并解压。不要直接拉取开发中的 `main` 覆盖部署。

已有 `crispai` 时选择 `14 → 1`，填写新版解压目录的绝对路径（可在该目录运行 `pwd` 获取），数字确认后升级。也可在新版解压目录执行下面命令；从 v1.0.1 升级优先用此目标版本入口：

```bash
sudo bash ./update.sh --deploy-dir /opt/crisp-ai --source-dir "$PWD" --no-pull
```

使用自定义部署目录时替换 `/opt/crisp-ai`。升级会创建一致性快照、迁移知识与按钮规则并验证，期间有服务中断；失败按快照回滚。用 `14 → 3/4` 查看与恢复历史，完成后运行 `crispai doctor`。旧人工状态、Key、Prompt 与知识不会统一清空。v1.0.1 的旧仅哈希会话枚举边界见 [菜单说明](MENU.md)。

- **迁移业务配置**用 `12`：包含全部库原文和规则，不含 Key、客户会话、数据库；新实例先准备自己的凭据。即使无 Token，知识正文也不应公开上传。
- **本机完整备份/恢复**用 `13`：包含 `.env`、内部密码、数据库及人工状态，是敏感灾难恢复资产。创建/恢复需短暂停止有关应用；备份失败必须先修复，不能假定已有安全副本。

完整备份的等价命令如下；先创建并确认成功，只有确实要覆盖恢复时才运行第二条：

```bash
sudo bash /opt/crisp-ai/scripts/backup.sh --deploy-dir /opt/crisp-ai \
  --full --output /opt/crisp-ai/backups/full-manual.tar.gz
```

```bash
sudo bash /opt/crisp-ai/scripts/restore.sh --deploy-dir /opt/crisp-ai \
  --full --input /opt/crisp-ai/backups/full-manual.tar.gz
```

## 9. 卸载与保留数据重装

运行 `crispai uninstall` 或选择 `18`。菜单提供 `1 安全卸载 / 2 完整清理 / 0 返回`，危险操作再用数字确认。

- **安全卸载**移除本实例服务/程序及自己的 `crispai` 入口，保留 `.env`、`config`、`knowledge`、`data`、`backups`、`logs`。以后从完整包用原 `--deploy-dir` 安装，会验证并复用数据、重建命令，不要求重新准备所有内部密码。
- **完整清理**先显示精确删除范围，在删除范围外创建含秘密的完整备份，再确认删除本实例数据。保存屏幕给出的外部备份路径；恢复参考 [故障排查](TROUBLESHOOTING.md)。

两种方式都不卸载 Docker、不全局 prune、不删其他容器或网站。备份失败、外部容器占用网络或不能证明归属时会停止。安全卸载后 `crispai` 找不到是预期现象，不要用重复手建 alias 代替重装。

## 10. 常见卡点与求助

下载 404、校验失败、凭据 401/403、按钮点击无反应、计时、索引、`crispai` 找不到等，见 [故障排查](TROUBLESHOOTING.md)。当前包中的旧文档或菜单可能仍提到“私有仓库”：那是公开前的文字，不再代表访问限制。历史 tag/包不因文档更新重写，以 [main 上的安装教程](https://github.com/statusX7/ai-support/blob/main/docs/INSTALL.md) 为最新操作说明。

可以在 [公开 Issues](https://github.com/statusX7/ai-support/issues) 提交脱敏问题（发表评论需要 GitHub 账号，下载不需要）。只提供版本、系统、步骤、错误摘要和已脱敏诊断；不要上传 `.env`、完整 Hook URL、Key、知识、聊天、截图或完整备份。发现凭据泄露先撤销/轮换，再按 [安全说明](SECURITY.md) 处理。

## 附录：其他获取方式与系统变更

### 已安装 Git 的使用者：HTTPS clone

这不是新手必选步骤。不用 SSH key、GitHub Token 或私有仓库授权；固定到已发布 tag，不直接安装未验收的 `main`：

```bash
git clone --depth 1 --branch v1.1.0 \
  https://github.com/statusX7/ai-support.git ai-support-source-v1.1.0 &&
cd ai-support-source-v1.1.0 &&
sudo bash ./install.sh
```

看到 detached HEAD 提示是检出固定 tag 的正常现象。此路径不是 Release 资产下载，不对 Git 工作区运行资产的 `SHA256SUMS`；Git 缺失时用前述发布包方案，不让用户为了部署强行安装 Git。

已有正常登录的 GitHub CLI 也可执行 `gh release download v1.1.0 --repo statusX7/ai-support --pattern ai-support-v1.1.0.tar.gz --pattern SHA256SUMS`。这是可选客户端用法；公共浏览器/HTTPS 下载本身无需登录，不应只为装客服配置 gh。

### 安装器会自动修改哪些位置

实际依赖包括发行版 `ca-certificates/curl/jq/openssl/tar/gzip`、基础工具、`diffutils/cmp`、`util-linux/flock`、`iproute2/ss`、Python 3/`python3-yaml`，以及 Docker 官方源的 Engine、CLI、containerd、Compose plugin。确认前可先补向导工具，确认后准备服务。不要求宿主 Node/npm 或全局 pip，不使用 `--break-system-packages`。

受控系统变更包括缺失包、Docker 专用 apt source/keyring、Docker systemd 启动/启用、部署目录、`/usr/local/bin/crispai`；裸域名模式另有 Caddy 容器与持久证书目录。已有健康 Docker 复用，不为升级而重启其他容器，不执行整机 dist-upgrade、关闭 TLS/签名校验或清空 Docker 数据。

Provider 保留 URL 前缀；宿主 loopback 使用独立探测地址，容器通过 host gateway 访问，供应商服务仍需允许该受控连接。Chat/Responses 由随包适配器接到实际协议；本地 Embedding 不需要额外 Key。具体字段与高级配置见 [CONFIG](CONFIG.md)，不要把宿主 curl 成功当成容器已能调用。
