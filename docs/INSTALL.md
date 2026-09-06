# 从完整发布包安装 CrispAI

正常支持系统的依赖由安装脚本自动补齐，不需预先手工安装 Docker、Compose、jq、AnythingLLM 或 n8n。需要自己准备的只有有效第三方 AI 凭据、Crisp 凭据和有权配置的公网接入信息。源码发布不代表已替使用者完成账号授权或 Hook 登记。

## 1. 系统、权限和资源

| 系统/架构 | 项目实现与验证等级 |
| --- | --- |
| Debian 12 amd64、systemd | 主要部署验收平台；本轮真实结果以 [v1.1.0 报告](reports/v1.1.0-report.md) 的逐项证据为准 |
| Debian 13 amd64、Ubuntu 22.04/24.04 amd64 | 自动包管理分支覆盖，未据此宣称同等级整机实测 |
| 上述系统 arm64 | 架构分支与镜像能力检查，不冒充实际 arm64 整机验收 |
| RHEL-like、衍生发行版、非 systemd、远程 Docker daemon | 当前自动安装不支持，不会乱套用 Debian 软件源 |

使用 root，或能正常 sudo 的管理员。建议至少 2 CPU、4 GiB 内存及 25 GiB 可用磁盘；镜像、首次 Embedding、知识和完整快照需要额外空间，较大知识库按实际增长预留。虚拟机须提供镜像支持的真实 CPU 能力；不将受限容器嵌套 dockerd 或不稳定 TCG 当作正常部署保证。

目标机应可访问其发行版仓库、Docker 官方仓库与镜像源、本地 Embedding 模型源，以及自己的 AI/Crisp HTTPS 服务。80/443 已有网站时使用已有反代分支；不要停掉其他网站给安装器让端口。

## 2. 获取私有发布包

仓库保持 private。推荐在已有授权的浏览器打开 [Releases](https://github.com/statusX7/ai-support/releases)，下载 `ai-support-v1.1.0.tar.gz` 和 `SHA256SUMS`，上传到服务器的同一目录。不能匿名访问私有包，也不要把 Token 嵌入 URL。

若获取文件的机器已经安装并登录 GitHub CLI，可用：

```bash
gh release download v1.1.0 --repo statusX7/ai-support \
  --pattern ai-support-v1.1.0.tar.gz --pattern SHA256SUMS
```

Git/gh 仅用于取得私有代码或维护发布，不是归档安装及客服运行依赖。获取文件发生在安装器之前；没有相关下载命令时使用浏览器上传，而不是声称脚本能提前替你安装 Git。

## 3. 校验并运行

在两个资产所在目录：

```bash
sha256sum --check SHA256SUMS
tar -xzf ai-support-v1.1.0.tar.gz
cd ai-support-v1.1.0
sudo bash ./install.sh
```

root 执行 `bash ./install.sh`。校验失败不要继续；发布包解压后不含 `.git` 也能工作。未宣传未经验证的远程 `curl | bash` 管道交互安装。

默认部署目录 `/opt/crisp-ai`，自定义使用 `sudo bash ./install.sh --deploy-dir /srv/crisp-ai`。安装器保存持久程序到部署目录，`crispai` 不指向临时解压目录。已有部署继续原路径，不强制迁移。`--help`、`--version` 在无 Docker 或配置时也可用。

## 4. 十项快速初始化

| 主步骤 | 实际输入 | 系统行为 |
| --- | --- | --- |
| 1/10 | AI API 地址 | 保留合法代理前缀、已有 `/v1`，规范尾斜线 |
| 2/10 | AI API Key | 隐藏输入；说明少量探测可能计费 |
| 3/10 | 选择模型 | 远端列表去重、数字/分页/搜索；无列表时可手填后验证 |
| 4/10 | Crisp Website ID | 保存对应网站标识，不重复询问 |
| 5/10 | Crisp Token Identifier | 隐藏输入，与 Key 分开 |
| 6/10 | Crisp Token Key | 隐藏输入 |
| 7/10 | 域名或已有 HTTPS 生产地址 | 受管 Caddy 或已有反代分流 |
| 8/10 | 客服 Prompt | 回车安全默认、普通文件路径或多行粘贴 |
| 9/10 | 知识来源 | 文件/目录、粘贴或多个命名库；允许暂时空库 |
| 10/10 | 脱敏核对 | `1 开始 / 2 修改 / 0 取消` |

路径快速流程十项主要输入，确认后不再问数据库密码、AnythingLLM Key/workspace、n8n owner/workflow、内部端口或 Embedding Key。多行或多库是用户主动展开的输入过程，不称为总共只按十次键。多行结束/取消方式及原文示例见 [MENU](MENU.md)。

新装默认客服启用、人工关键词按钮启用、人工恢复 1800 秒、欢迎启用、自动展开关闭；摘要会显示。升级保留已有自定义值，旧“关键词直接转人工”迁移为按钮确认。空知识库会明确提示没有业务知识，默认 Prompt 不编造价格、政策或已执行操作。

EOF、Ctrl+C 或失败保留受限进度，重跑原命令或 `crispai init` 继续；不会重新生成有效密钥。已有有效配置时可选择保留检查或重配置。自动化 `--non-interactive` 是高级入口，不是普通人的唯一安装方式。

## 5. 自动完成的事情与系统变更

确认前先补齐向导所需工具；确认后按顺序安装/复用 Docker、检查 daemon 与实际测试容器、创建受管目录/密钥、渲染 Compose、拉固定镜像、启动数据库/应用、初始化 AnythingLLM、同步 Prompt/知识、导入发布 n8n、安装全局命令和分层检查。

依赖取自实际生产调用：发行版 `ca-certificates/curl/jq/openssl/tar/gzip`、基础工具、`diffutils/cmp`、`util-linux/flock`、`iproute2/ss`、Python 3/`python3-yaml`；Docker 官方源提供 Engine、CLI、containerd、Compose plugin。不强加宿主 Node/npm 或全局 pip，第三方 Python 库不使用 `--break-system-packages`。Compose 按能力与运行结果检查，不限定必须恰好 v2。

系统级变更限于缺失包、Docker 专用 apt source/keyring、Docker systemd 启动/启用、受管目录及 `/usr/local/bin/crispai`；裸域名模式另有受管 Caddy 容器和持久证书目录。无整机 dist-upgrade、TLS/签名降级、全局 prune 或 Docker 数据目录清空。已有健康 Docker/其他容器不重装、不随意重启。

内部密码、n8n 加密密钥、AnythingLLM 初始认证、Developer API Key、单一客服 workspace、原生本地 Embedder、知识 manifest 与生产 workflow 均自动创建或复用。文件上传后还要实际索引、读回；workflow 导入成功后还要发布和生产节点检查。服务账号 UID/GID 与私密文件权限由脚本处理，不使用全目录 chmod 777。

## 6. Provider 的真正路径

只列模型不等于能调用，HTTP 200 也要有有效正文。Chat-only 与 Responses-only 都通过实际选择协议验证；AnythingLLM 的 Generic OpenAI 请求由随包部署的最小适配器接到所选协议，图片路径同样验证。切换供应商使用 `3 → 10` 整组候选，不用先破坏旧配置。

宿主 `localhost`/`127.0.0.1` 会保存为独立 probe 地址，容器用 `host.docker.internal` 与 host gateway；供应商服务仍需实际允许该受控网络访问。普通远端须 HTTPS，不跟随重定向转发 Token。模型不支持视觉时文本仍可用，访客应补充文字，不自动转人工。

## 7. 公网接入与 Crisp 最小动作

裸域名：DNS A/AAAA 指向正确服务器，80/443 空闲且入站与证书签发条件满足时，受管 Caddy 自动处理 HTTPS 与续期。任何 AAAA 必须真的可达，不只验证 A。条件不足保持 pending，不伪称 HTTPS 成功。

完整 HTTPS URL：使用自己的已有反代。安装器生成 `config/crispai-nginx.conf` 和 `config/crispai-caddy.conf`，内容采用当前实际端口/前缀；管理员将适用片段合入已有站点，不覆盖整份配置。只转发生产 Hook 及可选无密钥 SDK/公开 UI 配置路由，n8n 编辑器、AnythingLLM 管理端和数据库不公开。

在 `crispai → 10 → 7` 私密显示带随机 Secret 的生产 URL，在 Crisp 高级设置登记 Website Hook，至少订阅 `message:send`、`message:received`、`message:updated`。使用网页加载/打开欢迎另订阅 `session:sync:events` 并接一次无密钥网页片段。详细凭据取得路径和按钮测试见 [CRISP](CRISP.md)。没有已验证官方自动登记接口时不模拟后台登录；无需另外创建 Marketplace Plugin。

## 8. 如何读完成结果

| 状态/事实 | 意义 |
| --- | --- |
| collecting / installing | 向导或初始化未完成，可恢复 |
| staged | 显式跳过启动，只落盘，不是安装成功 |
| local-ready | 本地依赖、应用与必要配置已完成，外部接入或实际客户链路仍待验证；尚不能声称接待客户 |
| ready | 当前配置的本地/Provider、Crisp API、公网入口及可信真实会话往返事实均通过；协议服务不能产生真实会话通过事实 |
| uninstalled-data-kept | 服务/程序已移除，数据和秘密保留，同路径可重装 |

完成页列部署目录、版本、服务、知识、回调、日志与管理入口。`crispai status` 读已有事实；`doctor` 发实际探测。正常安装不要求 21 项开发 E2E 变量。凭据修复或 Hook 登记后从菜单继续验证，不需要重填十项或重装内部组件。

安装退出码：`0` 为该操作完成；`2` 可表示本地完成但外部待接入，或用户取消，须结合本次明确文案与状态；`130` 是中断。其他非零看具体失败阶段。同一个“2”不能据此自动删除数据或显示所有步骤失败。

## 9. 日常入口、更新与恢复

```bash
crispai
crispai status
crispai doctor
```

18 项及各子菜单见 [MENU](MENU.md)。全局开关不停止容器；长期维护停机另选 16。密钥、Prompt、知识与配置通过菜单实际应用和回读。

从 v1.0.1 升级，校验并解压新版，在新版目录运行：

```bash
sudo bash ./update.sh --deploy-dir /opt/crisp-ai --source-dir "$PWD" --no-pull
```

或 `crispai → 14 → 1` 输入该绝对目录。自动创建一致性快照、迁移单知识目录和按钮规则、验证应用；失败按快照回滚。`14 → 3/4` 查看/恢复历史，更新及回滚后修复受管 `crispai`。旧人工状态不会统一清零；旧仅哈希会话状态的可枚举边界见 MENU。

业务迁移用选项 12：包含多库原文，不含秘密/客户会话，新实例先准备自己的凭据。完整本机备份用选项 13：包含秘密、数据库和运行状态，需当敏感恢复资产，不上传。命令等价入口：

```bash
sudo bash /opt/crisp-ai/scripts/backup.sh --deploy-dir /opt/crisp-ai \
  --full --output /opt/crisp-ai/backups/full-manual.tar.gz
sudo bash /opt/crisp-ai/scripts/restore.sh --deploy-dir /opt/crisp-ai \
  --full --input /opt/crisp-ai/backups/full-manual.tar.gz
```

## 10. 卸载与同路径恢复

`crispai → 18` 或 `crispai uninstall`：数字选安全卸载/完整清理/返回，危险操作再确认。安全卸载移除本实例服务/程序及自己的全局命令，保留 `.env/config/knowledge/data/backups/logs`。从新完整包使用同一 `--deploy-dir` 重装，验证并复用数据，再创建命令。

完整清理先显示精确删除范围，并将敏感完整备份存于删除范围外；确认后只清本实例。不卸载 Docker、不 prune、不删外部容器。备份失败、网络外部占用或无法证明所有权时停止，不能误报清理完成。具体恢复资产内容和远端竞态边界见 [SECURITY](SECURITY.md)，排障见 [TROUBLESHOOTING](TROUBLESHOOTING.md)。
