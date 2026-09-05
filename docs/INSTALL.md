# 安装说明

## 支持范围

本版本的自动依赖分支支持 64 位 `amd64`/`arm64`：

- Debian 12、13
- Ubuntu 22.04、24.04

Debian 12 `amd64` 已完成从无 Docker 的 systemd 虚拟机真实安装。其他列出的系统完成了发行版与包管理分支自动测试；正式使用前仍建议在同发行版预演。RHEL-like、非 systemd 主机、容器内启动 dockerd 和远程 Docker context 不在自动安装支持范围内，脚本会在变更前说明原因。

安装脚本会自动补齐 `ca-certificates`、`curl`、`jq`、`openssl`、`tar`、`gzip`、`flock`、`ss` 等实际运行工具，以及 Docker Engine、CLI、containerd 与 Compose 插件。不会要求宿主机安装 Node.js、npm、GitHub CLI、Python 包或全局 pip 依赖，也不会执行整机升级、关闭 TLS/签名校验、清理 `/var/lib/docker` 或停止其他容器。

使用者只需准备：

- 具备 Chat Completions 能力的 OpenAI Compatible API 地址与 Key；
- 目标 Crisp Website ID、Token Identifier 与 Token Key；
- 自己掌握的公网域名，或已经反向代理到本项目的 HTTPS 完整 Webhook 地址。

数据库密码、n8n 加密密钥、Webhook URL Secret、AnythingLLM 登录凭据、Developer API Key、工作区和内部端口都由安装器生成或配置。

## 获取完整发布包

仓库为 private。取得源码需要自己的 GitHub 访问权限，运行客服本身不依赖 Git 或 GitHub CLI。

推荐从 GitHub Release 下载 `ai-support-v1.0.1.tar.gz` 和 `SHA256SUMS`，上传到服务器后执行：

```bash
sha256sum --check SHA256SUMS
tar -xzf ai-support-v1.0.1.tar.gz
cd ai-support-v1.0.1
sudo bash ./install.sh
```

也可以在已配置私有仓库访问权限的机器上克隆：

```bash
git clone https://github.com/statusX7/ai-support.git
cd ai-support
sudo bash ./install.sh
```

不要把 GitHub Token 放进下载 URL。未测试从标准输入管道执行交互安装；请先取得完整发布包再运行文件。

## 十项快速初始化

无有效安装实例时，`bash install.sh` 自动进入同一个十项向导：

1. `AI API 地址`：可含 `/v1` 或受信任路径前缀；非本机地址必须使用 HTTPS。
2. `AI API Key`：无回显输入，只用于少量连通性与能力请求。
3. `选择模型`：从 `/v1/models` 去重列表中数字选择，支持翻页和搜索；接口不支持时可手动输入，但仍须通过真实 Chat 请求。
4. `Crisp Website ID`。
5. `Crisp Token Identifier`：无回显。
6. `Crisp Token Key`：无回显。
7. `公网域名或现有 HTTPS Webhook 地址`：裸域名进入受管 Caddy HTTPS；完整地址进入已有反向代理分支。
8. `客服提示词`：回车使用安全默认值，也可输入本机普通文件路径或选择粘贴。
9. `知识库文件或目录`：支持 Markdown、TXT、PDF、DOCX；回车允许空知识库并明确提示没有业务知识。
10. `核对并开始`：只显示脱敏摘要，选择 `1 开始安装 / 2 返回修改 / 0 取消`。

正常路径共十次输入；确认后不再询问数据库、端口、AnythingLLM、n8n 或 Embedding 参数。EOF、Ctrl+C 或安装失败会保留权限为 `0600` 的进度，重新运行同一命令继续；配置与本地应用成功落盘后，含外部凭据的向导临时文件会删除。

自定义部署目录属于高级用法：

```bash
sudo bash ./install.sh --deploy-dir /srv/crisp-ai
```

自动化可以使用 `--non-interactive` 和相应环境变量；它不是普通安装的默认入口。`--help` 与 `--version` 在 Docker、jq 等依赖缺失时仍可使用。

## 自动安装与初始化顺序

安装器先只依赖 Bash、基础系统命令和包管理器识别系统，然后补齐向导所需工具。用户确认后才执行：

1. 幂等配置 Docker 官方 apt 软件源，安装或复用 Engine、CLI、containerd 与满足项目能力要求的 Compose 插件。
2. 通过 systemd 启用并启动 daemon，等待 `docker info`，检查本地 socket/context、Engine 版本和架构，再运行 `hello-world`。
3. 创建 `/opt/crisp-ai` 的受限目录，生成或复用内部密钥，并验证 Compose。
4. 启动 PostgreSQL、AnythingLLM 和 n8n，等待真实健康接口。
5. 自动登录 AnythingLLM，创建或复用 `ai-support` Developer API Key 与 `crisp-support` 工作区，同步 Prompt。
6. 复制所选知识文件，上传、加入工作区并核对索引清单；空知识库也生成明确的空清单。
7. 在固定 n8n 容器中导入、发布 workflow，重启后导出并检查 `active=true`。
8. 检查 Provider、AnythingLLM Chat、Crisp REST API 和公网 Webhook；保存分层状态并创建首次可维护状态。

重复执行会复用密钥、工作区、知识和已发布 workflow，不会重复添加 apt 源或重置数据。已有健康 Docker 会直接复用；安装器不会因为版本字符串不是恰好 `v2` 就拒绝兼容 Compose，而是检查实际命令能力。

## Provider 与容器网络

地址规范化只补一个 `/v1`，不会形成 `/v1/v1`。模型列表成功不等于模型可调用；所选模型必须实际通过 `/v1/chat/completions`，因为 AnythingLLM 当前的 `generic-openai` 运行路径依赖它。Responses 与图片能力单独探测并记录； Responses-only 配置会被拒绝，不会把无人使用的模式写成成功。

宿主机 `localhost` Provider 会在容器配置中改为 `host.docker.internal`，Compose 同时设置 `host-gateway`；宿主探测地址单独保存。非本机 HTTP Provider 会被拒绝，Bearer Token 不跟随重定向发送到其他主机。

## Webhook 与 Crisp 后台

裸域名模式仅在 80/443 未被占用时启用本项目 Caddy，并只公开 `/webhook/crisp-webhook`。证书与数据持久化在部署目录。DNS、80/443 入站权限或证书签发不满足时，安装器保留本地服务并把 Webhook 标为 `pending`，不会声称公网接入成功。

若 80/443 已由 Nginx、Caddy、宝塔或其他服务占用，安装器不会停止或覆盖它。请先让现有 HTTPS 反向代理把一个准确路径转发到 `http://127.0.0.1:5678/webhook/crisp-webhook`，然后在第 7 项输入完整 HTTPS 地址。切换出受管 HTTPS 时，只停止并删除本 Compose 项目的 Caddy，不影响外部服务。

默认 Website Hook 必须在 Crisp 后台登记：

```text
https://你的域名/webhook/crisp-webhook?key=<CRISP_WEBSITE_HOOK_SECRET>
```

同时订阅：

- `message:send`：访客消息；
- `message:received`：公开 operator 回复。

URL Secret 可在受控终端从部署 `.env` 获取，不会写入文档、Release、普通日志或统计。Crisp 后台登记属于账户权限边界；无法通过明确官方 API 幂等登记时，安装器只输出上述最小操作，不模拟登录。Plugin Token/签名 Hook 保留为管理菜单中的高级兼容模式。

n8n、AnythingLLM 与 PostgreSQL 不默认暴露公网；前两者绑定 `127.0.0.1`，数据库只在项目网络内。受管 Caddy 对其他路径返回 404。

## 安装状态

- `collecting`：十项向导未确认或可恢复；
- `installing`：配置或本地初始化正在进行；
- `staged`：显式 `--skip-start`，不能视为部署完成；
- `local-ready`：Docker、本地服务、Provider、AnythingLLM、知识与 workflow 已通过，Crisp 外部凭据或接入仍待处理；
- `ready`：本地应用及 Crisp REST 凭据已通过；WebHook 和真实会话仍由各自 fact 独立表示；
- `uninstalled-data-kept`：安全卸载后数据和 `.env` 保留。

完成页会列出实际部署目录、状态、Webhook、管理命令和剩余外部动作。只有收到并成功回写真实 Crisp 消息后，才可把会话链路视为已验收。

## 管理、更新与卸载

```bash
sudo /opt/crisp-ai/manage.sh
```

管理工具提供十项中文分组：快速初始化、状态、AI、Prompt/知识、业务规则、标签/统计、日志/依赖修复、备份恢复、更新回滚和卸载。未安装时也能从第 1 项进入同一安装器；“依赖修复”会实际执行引导而非只打印缺失项。

从 v1.0.0 升级必须从独立的新版本完整发布包运行新版入口，避免旧进程使用旧复制清单：

```bash
cd /path/to/ai-support-v1.0.1
sudo bash ./update.sh \
  --deploy-dir /opt/crisp-ai \
  --source-dir "$PWD" \
  --no-pull
```

更新前自动执行容量检查、迁移备份和包含 n8n PostgreSQL/AnythingLLM 数据的版本快照；失败自动回滚。新健康检查还能从升级源码补齐旧版清单遗漏的 v1.0.1 运行模块。

默认安全卸载先备份并删除本实例容器、网络和程序，保留 `.env`、`config`、`knowledge`、`data`、`backups` 与 `logs`，且不会卸载宿主 Docker。完整清理在管理菜单中需要两次数字 `1` 确认；直接调用 `uninstall.sh --purge` 仍兼容 `PURGE` 高级确认。完整清理备份位于部署目录之外。

## 排障

```bash
sudo /opt/crisp-ai/scripts/bootstrap.sh --check
sudo /opt/crisp-ai/scripts/bootstrap.sh --all
sudo /opt/crisp-ai/scripts/healthcheck.sh --local
sudo /opt/crisp-ai/scripts/healthcheck.sh --application
sudo /opt/crisp-ai/scripts/healthcheck.sh
```

包管理器锁最多等待有限时间，不删除锁文件；下载与 Docker 等待都有超时和重试。无 root/sudo、软件仓库或网络不可达、systemd 不可用、远程 Docker context、CPU/镜像不兼容时会保留真实退出码和安装进度。不要用手工修改状态标记、删除 Docker 数据或关闭系统安全机制绕过错误。
