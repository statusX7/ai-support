# 测试说明

运行完整测试：

```bash
./tests/run.sh
```

测试使用本地桩命令和临时部署目录，不访问真实 Crisp、AnythingLLM 或 AI Provider，也不使用真实凭据。临时目录始终位于项目目录内，测试结束后自动清理。

测试覆盖安装、重复安装、Provider 成功与失败检测、在线与离线健康检查、Crisp API 失败、配置备份恢复、更新、卸载以及敏感字段拒绝逻辑。工作流契约测试始终执行，检查 Webhook、消息方向、防循环、图片、关键词、菜单、上下文和人工接管路径。

若系统提供 Node.js，测试还会直接执行 n8n Code node 中的 JavaScript，验证消息路由和低置信度转人工行为；否则该项明确标记为跳过。若系统提供 Docker Compose v2，会使用测试环境文件运行实际的 `docker compose config`；否则明确标记为跳过，其他测试仍继续。
