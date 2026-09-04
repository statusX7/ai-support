# 安装说明

## 前置条件

- 64 位 Linux 主机与 root 权限。
- Docker Engine、Docker Compose v2、`curl`、`jq`、`openssl`、`tar`、`git` 和 `sha256sum`。
- 一个可用的 Crisp Website Token 或 Plugin Token。
- 一个支持 OpenAI Compatible API 的服务。
- 一个带有效 TLS 证书的公网域名，用于接收 Crisp Webhook。

## 安装

```bash
git clone https://github.com/statusX7/ai-support.git
cd ai-support
sudo ./install.sh
```

默认部署到 `/opt/crisp-ai`。安装程序会依次要求 API Base URL 和 API Key，调用 `/v1/models` 后显示模型列表，再检测 `/v1/responses` 与 `/v1/chat/completions`。只有模型列表检测失败时，才会提供手动模型或默认模型选项。

指定其他目录：

```bash
sudo ./install.sh --deploy-dir /srv/crisp-ai
```

重复执行安装是安全的：程序文件会更新，`.env`、实际业务配置、知识文件和运行数据会保留。需要重新走配置流程时增加 `--reconfigure`。

## 首次初始化 AnythingLLM

1. 通过本机端口或受保护的反向代理打开 AnythingLLM，默认端口为 `3001`。
2. 使用安装时生成并保存在 `.env` 中的 `ANYTHINGLLM_AUTH_TOKEN` 登录。
3. 创建 `crisp-support` 工作区。
4. 在 AnythingLLM 的 Developer API 页面创建独立 API Key。
5. 运行 `sudo /opt/crisp-ai/manage.sh`，依次选择“修改AI配置”和“配置 AnythingLLM API 与工作区”。

管理脚本会同步 Prompt、导入并发布 n8n workflow。发布前 Crisp Webhook 不会进入生产处理链路。

## 配置 Crisp

单工作区优先使用 Website Token。进入 Crisp 工作区设置的高级配置，创建 Website Hook，至少订阅 `message:send`，并使用以下地址：

```text
https://support.example.com/webhook/crisp-webhook?key=<CRISP_WEBHOOK_SECRET>
```

`CRISP_WEBHOOK_SECRET` 位于部署目录的 `.env`，不要通过聊天、工单或公开日志传输。

Plugin Hook 可以额外订阅 `message:received`、`session:set_opened` 和 `session:request:initiated`。Plugin Hook 不使用查询参数 Secret，而是由工作流验证 Crisp 提供的 HMAC-SHA256 签名。

## 反向代理

n8n 和 AnythingLLM 默认只监听 `127.0.0.1`。反向代理应只公开所需入口，启用 HTTPS，正确传递 `Host`、`X-Forwarded-For` 和 `X-Forwarded-Proto`，并限制 AnythingLLM 与 n8n 管理页面的访问来源。

## 日常管理

```bash
sudo /opt/crisp-ai/manage.sh
```

完整健康检查：

```bash
sudo /opt/crisp-ai/scripts/healthcheck.sh
```

不访问容器或外部 API 的静态检查：

```bash
sudo /opt/crisp-ai/scripts/healthcheck.sh --offline
```

只检查容器与本地健康接口：

```bash
sudo /opt/crisp-ai/scripts/healthcheck.sh --local
```

## 更新与回滚

管理菜单中的“更新系统”会先停止 n8n 与 AnythingLLM 写入，创建迁移备份和本机版本快照，再执行源码拉取、镜像拉取、重启、workflow 发布和本地健康检查。任何关键步骤失败都会自动恢复更新前快照。

从旧版升级时，脚本会幂等补齐 `handoff.yaml` 的新字段，并只把 `v0.6.0` 的旧默认关键词和默认提示迁移为新语义；自定义关键词、恢复时间与自定义提示会保留。

版本快照包含配置、Prompt、workflow、知识文件、程序文件、AnythingLLM 数据以及可用的本地镜像 ID，不包含 `.env`、PostgreSQL、n8n 数据库、统计事件或日志。可在管理菜单查看历史并选择回滚，也可运行：

```bash
sudo /opt/crisp-ai/scripts/rollback.sh --list
sudo /opt/crisp-ai/scripts/rollback.sh --snapshot <快照ID>
```

回滚保留现有 `.env`、PostgreSQL、n8n 数据库、匿名统计和历史快照。如果对应历史镜像已从本机删除，脚本只能恢复文件与数据，可能仍需从镜像仓库重新取得旧镜像。

从不含快照脚本的 `v0.6.0` 首次升级到本版本时，应从独立的新源码目录运行新版 `update.sh --deploy-dir <现有部署目录> --source-dir <新源码目录> --no-pull`；新版脚本会从源码调用首个快照工具。旧版 `update.sh` 本身无法预先提供新增的自动回滚能力。
