# 测试说明

## 自动测试

运行完整测试：

```bash
./tests/run.sh
```

测试使用本地桩命令和临时部署目录，不访问真实 Crisp、AnythingLLM 或 AI Provider，也不使用真实凭据。临时目录始终位于项目目录内，测试结束后自动清理。

测试覆盖安装、重复安装、Docker daemon 失败、Provider 成功与失败检测、在线与离线健康检查、Crisp API 失败、配置备份恢复、快照容量与保留策略、更新失败自动回滚、手动回滚、卸载以及敏感字段拒绝逻辑。统计测试验证总问题、AI 回复、知识库命中与未命中、转人工、好评率和高频失败问题。

工作流契约测试始终执行，检查 Webhook、消息方向、防循环、图片、关键词、菜单、上下文、配置化标签和人工接管边界。若系统提供 Node.js，测试还会直接执行 n8n Code node 中的 JavaScript，验证 operator 关闭 AI、用户明确转人工、知识库命中与未命中、低置信度保持 AI、反馈脱敏和标签合并行为；否则该项明确标记为跳过。若系统提供 Docker Compose v2，会使用测试环境文件运行实际的 `docker compose config`；否则明确标记为跳过，其他测试仍继续。

## 真实部署验收

桩测试不能替代以下预发布验收。只在隔离的 Crisp 测试会话和非生产知识文件中执行，不得把 Token、Secret、消息正文或用户数据复制到报告。

1. 在部署目录运行 `docker version`、`docker compose version`、`docker compose config --quiet`、`docker compose up -d` 和 `docker compose ps`，随后运行 `scripts/healthcheck.sh`。三项服务必须运行且本地与外部 API 检查均通过。
2. 在 `data/anythingllm/` 创建唯一的非敏感测试标记，记录 SHA-256，执行 `docker compose restart` 并等待 `scripts/healthcheck.sh --local` 通过；重启后校验标记哈希一致并删除标记。该步骤验证 bind mount 重启持久化，不替代 AnythingLLM 自身数据一致性检查。
3. 通过管理菜单分别导入只含虚构内容的 Markdown、TXT、PDF 和 DOCX，执行同步与重新索引。为每个文件设置唯一事实并从 Crisp 提问，确认索引查询正确；对比“知识库分析”中的总问题、命中、未命中和命中率增量。
4. 从 Crisp 测试网站发送两轮相关文本，确认只回复一次、第二轮能引用同一 conversation 上下文。让 operator 回复后再次发访客消息，确认 AI 停止；在新 conversation 发送“转人工”，确认提示完全等于“正在为您转接人工客服，请稍候。”且合并 `human_required` 标签而不删除既有标签。
5. 临时移除 Token 的 conversation meta 权限，确认标签更新被跳过但正文回复仍成功；恢复权限后验证 `ai_resolved`、`knowledge_miss`、`low_confidence` 和 `human_required`。
6. 从 Crisp 发送一张无敏感内容的测试图片。视觉模型应正常回复；关闭 `AI_SUPPORTS_VISION` 后重试，应明确提示切换视觉模型且 workflow 不崩溃。
7. 记录当前 AnythingLLM 测试数据哈希，执行一次正常更新和健康检查。再在隔离环境注入不可用镜像或失败健康条件，确认自动回滚、版本历史和 AnythingLLM 数据哈希；完成后恢复有效配置。

每项应记录时间、版本、匿名测试会话标识和通过/失败状态。缺少 Docker daemon、公开 Webhook、真实凭据或测试会话时必须标记“未验收”，不得用自动测试结果代替。
