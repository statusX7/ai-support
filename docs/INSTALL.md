# 安装说明

## 前置条件

- 64 位 Linux 主机与 root 权限。
- 已启动的 Docker Engine 和 Docker Compose v2。
- `curl`、`jq`、`openssl`、`tar`、`git`、`flock`、`realpath`、`stat`、`df`、`du`、`awk`、`base64` 和 `sha256sum`。
- 可用的 Crisp Website Token 或 Plugin Token，以及对应 Website ID。
- 支持 OpenAI Compatible `/v1/chat/completions` 的 Provider；`/v1/responses` 为可选能力。
- 带有效 TLS 证书的公网域名，用于接收 Crisp Webhook。

n8n 和 AnythingLLM 默认只绑定 `127.0.0.1`。生产环境必须通过 HTTPS 反向代理公开 Webhook，并限制 n8n、AnythingLLM 管理页面的访问来源。

使用 Crisp Plugin Token 时，至少授予 `website:conversation:messages` 与 `website:conversation:sessions` 的 read、write 权限：前者用于读取上下文和发送回复，后者用于读取并合并 conversation 标签。Website Token 应直接在目标 workspace 中生成。不要为了安装扩大到无关 CRM 或坐席权限。

## 一键安装

```bash
git clone https://github.com/statusX7/ai-support.git
cd ai-support
sudo ./install.sh
```

默认部署目录是 `/opt/crisp-ai`。安装程序会完成以下工作：

1. 检查 Docker Compose 和 Docker daemon。
2. 创建受限目录、随机密钥和实际配置文件。
3. 请求 Provider `/v1/models`，选择模型并实际探测 Chat Completions、Responses 和图片输入能力。
4. 启动 PostgreSQL、AnythingLLM 和 n8n。
5. 如果未预先提供 AnythingLLM Developer API Key，自动登录本机 AnythingLLM，创建名为 `ai-support` 的 Key。
6. 检查或创建工作区，默认 slug 为 `crisp-support`，同步 Prompt。
7. 导入并发布 n8n workflow，重启 n8n 后执行完整健康检查。
8. 所有必需检查通过后，才把安装状态提交为 `ready`。

任一步失败都会返回非零状态。安装不会把 API Key、Token 或 Secret 打印到日志。

指定其他部署目录：

```bash
sudo ./install.sh --deploy-dir /srv/crisp-ai
```

## 安装状态与重试

安装标记使用四种状态：

- `installing`：配置或验收尚未完成。
- `staged`：使用 `--skip-start` 只暂存了文件，服务尚未启动和验收。
- `ready`：容器、工作流和完整健康检查均已通过。
- `uninstalled-data-kept`：程序已卸载，但配置和数据被保留。

只有 `ready` 部署可以使用管理、更新和日常健康检查。安装中断后，从源码目录重新运行同一条 `install.sh` 命令即可安全续跑。不要通过手工编辑安装标记绕过验收。

`--skip-start` 仅用于暂存文件，不代表安装完成。完成部署时必须不带该参数重新运行：

```bash
sudo ./install.sh --deploy-dir /opt/crisp-ai
```

重复安装会保留 `.env`、实际业务配置、知识文件和运行数据。需要重新配置 Provider 或 Crisp 时使用：

```bash
sudo ./install.sh --deploy-dir /opt/crisp-ai --reconfigure
```

`install.sh` 只允许初始化或重复执行同一版本。检测到源码版本与现有 `ready` 部署不同时会拒绝直接覆盖，必须使用下文的 `update.sh`，以确保先创建数据库与 AnythingLLM 一致性快照。

安装、更新、备份、恢复、快照、回滚和卸载使用同一个非阻塞维护锁；检测到另一项维护任务正在运行时会安全中止。

## 配置 Crisp Hook

两种 Hook 模式都必须订阅：

- `message:send`：接收访客消息。
- `message:received`：接收公开的 operator 回复，并立即关闭该 conversation 的 AI。

不要订阅或使用 `session:set_opened` 触发欢迎语；该事件表示 operator 打开会话，不表示访客打开聊天窗口。

### Website Hook

安装时选择 `CRISP_HOOK_MODE=website`。将 URL 配置为：

```text
https://support.example.com/webhook/crisp-webhook?key=<CRISP_WEBSITE_HOOK_SECRET>
```

Website Hook 没有 Crisp 签名，工作流只接受查询参数中的随机 URL Secret。不得把该 Secret 用作 Plugin 签名 Secret。

Website Hook 没有可靠的“访客打开窗口”事件，因此欢迎语会与该 conversation 的第一条访客消息一起发送。

### Plugin Hook

安装时选择 `CRISP_HOOK_MODE=plugin`，并输入 Crisp 为该 Plugin Hook 提供的 Signing Secret。URL 不携带查询 Secret：

```text
https://support.example.com/webhook/crisp-webhook
```

Plugin 模式强制校验原始请求体、`X-Crisp-Request-Timestamp` 和 `X-Crisp-Signature`，拒绝超过五分钟的签名，也不会降级为 Website URL Secret。若需在会话创建时主动欢迎，可额外订阅 `session:request:initiated`。

`CRISP_TOKEN_TIER` 表示 REST API Token 类型，`CRISP_HOOK_MODE` 表示 Webhook 校验方式；应分别按 Crisp 中实际创建的凭据和 Hook 类型配置。

## 反向代理

反向代理应只公开 `/webhook/crisp-webhook`，启用 HTTPS，并正确传递 `Host`、`X-Forwarded-For` 和 `X-Forwarded-Proto`。不要把 n8n 编辑器或 AnythingLLM 管理页面直接暴露到公网。

## 日常管理

```bash
sudo /opt/crisp-ai/manage.sh
```

完整健康检查会验证容器、已发布 workflow、Provider 所选模型、Crisp REST API、AnythingLLM Key、工作区、Prompt 和一次工作区 Chat：

```bash
sudo /opt/crisp-ai/scripts/healthcheck.sh
```

静态检查和本地检查：

```bash
sudo /opt/crisp-ai/scripts/healthcheck.sh --offline
sudo /opt/crisp-ai/scripts/healthcheck.sh --local
```

`--offline` 不访问 Docker 或 API；`--local` 不访问外部 Provider 或 Crisp。二者都不能替代完整健康检查和真实 Crisp 验收。

## 更新与回滚

管理菜单中的“更新系统”或 `update.sh` 会：

1. 获取源码并校验新 Compose 配置。
2. 在停机前拉取新镜像。
3. 预检快照容量，短暂停止 n8n 与 AnythingLLM。
4. 创建不含密钥的迁移备份，以及包含 AnythingLLM 数据和 n8n PostgreSQL 逻辑备份的一致性版本快照。
5. 更新文件、启动服务、重新同步 Prompt、发布 workflow 并执行健康检查。
6. 成功后提交 `ready` 状态；失败时自动回滚。

更新不支持 `--skip-start`，因为数据库和 AnythingLLM 数据必须保持一致。

查看历史和手动回滚：

```bash
sudo /opt/crisp-ai/scripts/rollback.sh --list
sudo /opt/crisp-ai/scripts/rollback.sh --snapshot <快照ID>
```

回滚要求 Docker daemon、PostgreSQL 和快照记录的历史镜像都可用。脚本在修改当前文件前检查历史镜像；恢复时原子切换 AnythingLLM 数据、恢复 n8n 数据库、发布 workflow，并在健康检查通过后重新提交 `ready`。现有 `.env`、匿名统计和版本历史不会被快照覆盖。

`.env` 中的 `SNAPSHOT_MIN_FREE_MB` 默认是 `1024`，`SNAPSHOT_RETENTION_COUNT` 默认是 `10`。任一值设为 `0` 会关闭对应限制。自动清理会永久删除超出数量上限的最旧有效快照，回滚目标在操作期间受到保护。

从旧部署升级时，应从独立的新源码目录执行：

```bash
sudo ./update.sh \
  --deploy-dir /opt/crisp-ai \
  --source-dir /path/to/new/ai-support \
  --no-pull
```

正式升级和故障回滚必须先在隔离环境按 [测试说明](TESTING.md) 演练。
