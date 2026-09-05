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

管理菜单集中提供以下入口：

| 编号 | 功能 | 说明 |
| --- | --- | --- |
| 1 | 查看状态 | 查看容器状态、执行健康检查或查看历史版本。 |
| 2 | 修改 AI 配置 | 检测 Provider、配置 AnythingLLM 或 Crisp，并重新发布 workflow。 |
| 3 | 修改 Prompt | 查看、编辑、导入、导出并同步 Prompt。 |
| 4 | 管理知识库 | 查看、添加、删除、同步或重新索引知识文件。 |
| 5 | 查看统计 | 查看知识库命中分析或 AI 回答质量反馈。 |
| 6 | 查看日志 | 显示最近容器日志；日志可能含会话内容。 |
| 7 | 备份 | 创建不含密钥的迁移备份。 |
| 8 | 恢复 | 从迁移备份恢复业务配置、workflow 和知识文件。 |
| 9 | 更新 | 创建备份及一致性快照后更新。 |
| 10 | 回滚 | 选择一致性版本快照回滚。 |
| 11 | 卸载系统 | 选择安全卸载或需要 `PURGE` 确认的完整清理。 |

菜单中的变更操作会复用维护锁；同一部署已有维护任务时不会并发执行。

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

## 安全卸载与恢复

管理菜单的“卸载”以及不带清理参数的 `uninstall.sh` 默认执行安全卸载：

```bash
sudo /opt/crisp-ai/uninstall.sh
```

脚本先在 `backups/uninstall-backup-<UTC时间>-<随机值>.tar.gz` 创建一份不含密钥的迁移备份，再停止并删除本项目容器和 Compose 网络。Docker 操作成功后，才删除 Compose 服务定义、根级程序文件、程序脚本、workflow 副本、程序文档和临时目录。以下内容保留在原部署目录：

- 权限保持为 `0600` 的 `.env`，用于解密保留的 n8n 数据库并继续使用原 PostgreSQL 密码；它仍包含敏感凭据。
- 实际业务 `config/`、`knowledge/`、`data/`、`backups/` 和 `logs/`。
- 标记为 `uninstalled-data-kept` 的安装状态，用于阻止把已卸载目录误判为可运行服务。

`--keep-data` 是默认安全模式的兼容别名；自动化环境可用 `--keep-data --yes` 跳过这一模式的普通确认，但不会改变保留范围。

恢复时，从一份新的可信源码副本对原目录重新安装：

```bash
git clone https://github.com/statusX7/ai-support.git /path/to/new/ai-support
cd /path/to/new/ai-support
sudo ./install.sh --deploy-dir /opt/crisp-ai
```

安装程序会先校验保留的 `.env` 与实际配置，再复用密钥、业务配置和数据；不需要重新传入 Provider/Crisp 环境变量。保留项缺失、不一致或包含占位值时，安装会在恢复程序文件前非零退出并明确要求 `--reconfigure`；损坏的实际配置应先从备份恢复，或移除损坏文件后重新配置。只有健康检查全部通过后才重新进入 `ready`。如需迁移到其他主机，应先在目标主机完成安装、重新输入凭据，再通过管理菜单“恢复”导入自动生成的迁移备份。迁移备份不含 `.env`、数据库或运行时会话数据。

只有确认不再需要本机数据时才执行完整清理：

```bash
sudo /opt/crisp-ai/uninstall.sh --purge
```

完整清理会先要求输入 `y` 或 `yes`，再要求精确输入 `PURGE`；`--yes` 也不能跳过这两次确认。确认后会删除 `.env`、配置、知识、数据库、AnythingLLM 数据、部署内备份和日志，以及整个部署目录。脚本始终会先在部署目录同级创建 `crisp-ai-purge-backup-<UTC时间>-<随机值>.tar.gz` 并显示路径；该迁移备份不含密钥、数据库或 AnythingLLM 运行数据。

如果 Docker daemon、Compose 或 `docker compose down` 失败，脚本会返回非零并在删除程序或数据前安全中止；此前生成的迁移备份会保留。即使 `docker compose down` 返回 0，脚本也会按 Compose 项目标签再次核验容器和网络；外部 Provider 等容器仍占用项目网络时必须中止，且绝不代为删除外部容器。脚本不提供绕过 Docker 检查的强制离线选项。先分离外部占用者或修复 Docker 状态，再重新执行；不得以手工删除目录代替这一检查。
