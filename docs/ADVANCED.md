# 高级安装与维护（可选）

普通新用户只需 [INSTALL](INSTALL.md) 顶部的一行命令。本页用于指定版本、自定义目录、旧版在线升级或已有离线资产的维护环境。

## 单独使用完整 get.sh

先安全取得入口。此维护示例假设 curl/CA 已存在；缺工具的普通路径仍用 INSTALL 推荐命令。下载和语法检查失败时不会执行：

```bash
crispai_get_file=$(mktemp /tmp/crispai-maintenance.XXXXXXXX) && \
curl -q --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 300 \
  https://raw.githubusercontent.com/statusX7/ai-support/main/get.sh -o "$crispai_get_file" && \
bash -n "$crispai_get_file" && test "$(tail -n 1 "$crispai_get_file")" = '# crispai-get-end' && \
bash "$crispai_get_file" --deploy-dir /opt/crisp-ai --update --release v1.2.0
```

这也适用于 v1.1.0/v1.1.1 升级：独立 get.sh 下载并校验指定 v1.2.0 后调用兼容更新链。必须在真实交互终端执行，原目录须有有效受管标记。操作完成后可删除刚创建的临时入口文件；部署内的入口不依赖它。

已有 get.sh 可使用 `--release v1.2.0` 固定版本、`--deploy-dir /opt/my-crisp-ai` 自定义目录、`--update` 明确升级。默认已有完整实例打开菜单；低于已装版本的目标被拒绝，回滚使用快照。

## 命令损坏时的独立救援

`crispai`/管理入口不可达时，使用上面相同的安全获取步骤，把最后一条命令换为：

```bash
bash "$crispai_get_file" --deploy-dir /opt/crisp-ai --repair
```

救援会读取本机版本并校验**同一个正式版本**的完整包，只恢复受管启动器和命令归属；不依赖损坏的 `crispai`，不询问十项、不改 Key、Prompt、知识或人工状态。`--repair` 与 `--update` 不可混用，也不跨版本。若实例本体程序缺失/归属不明，会明确拒绝；完整程序更新使用上面的 `--update --release v1.2.0` 或可信完整恢复，不无声重装。兼容 `crisp` 存在外来程序时保留对方命令。

## 可信离线完整包

只使用目标 Release 的完整 `ai-support-vX.Y.Z.tar.gz` 与同版 `SHA256SUMS`，不要使用 GitHub 自动生成的 Source code 包。包无须 Git/gh 或 .git 才能安装：

```bash
sha256sum -c SHA256SUMS && \
tar -xzf ai-support-v1.2.0.tar.gz && \
sudo bash ai-support-v1.2.0/install.sh --deploy-dir /opt/crisp-ai
```

手工解压仅针对已信任且校验通过的正式资产。在线引导器另有路径/链接/成员数/展开大小检查；不把不可信上传包直接交给 tar。SHA256 是完整性检查，不是独立签名。

离线更新用 `crispai → 14 → 2` 输入完整包解压目录，仍自动快照和失败回滚。高级 Git 路径只供保留原工作区的维护者使用。

## 完整恢复

业务迁移包不含秘密或数据库。灾难恢复需要含 .env、数据库、应用数据和人工状态的完整可信备份。入口可用时用 `13 → 3`；程序存在但入口缺失时：

```bash
sudo bash /opt/crisp-ai/scripts/restore.sh --deploy-dir /opt/crisp-ai --full --input /绝对路径/完整备份.tar.gz
```

恢复中断时遵循失败页的成套恢复步骤，避免启动混合数据。不得仅更换 POSTGRES_PASSWORD、只换一个目录或用 --fix 解除保护。安全卸载后重跑在线命令复用资料；完整清理前生成的外部备份为敏感副本，须妥善保管。

`scripts/backup.sh` 的默认业务备份在命名库实例复用 v2 迁移格式，包含全部库原文而不含秘密；`--full` 才是完整灾难恢复包。`restore.sh --skip-restart` 仅兼容旧 v1 单目录业务备份的离线文件恢复，新业务包必须实际应用和回读。v2 业务包限制为压缩 128 MiB/展开 512 MiB/20000 成员；旧 v1 恢复预检上限为压缩 512 MiB/展开 4 GiB/20000 成员，30 秒格式预检预算。完整敏感备份使用独立快照/归档校验及容量规则，不混用这些业务迁移上限。
