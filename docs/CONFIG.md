# 配置说明

## 配置分层

- `.env` 保存部署路径、端口和密钥，仅允许部署账户读取，不得提交到 Git。
- `config/provider.yaml` 保存 Provider 类型、地址、模型和能力检测结果，不保存 API Key。
- `config/prompt.md` 保存客服系统提示词。
- `config/keyword.yaml`、`config/menu.yaml` 和 `config/handoff.yaml` 保存业务规则。
- 带 `.example` 后缀的文件是可公开提交的模板，不得填入真实凭据。

## AI Provider

配置入口只要求输入 API Base URL 和 API Key。管理脚本会规范化地址、请求 `/v1/models` 并显示检测到的模型；模型列表请求失败时才提供手动输入或默认模型选项。

管理脚本还会分别探测 `/v1/responses` 与 `/v1/chat/completions`，把可用接口记录到 `config/provider.yaml`。API Key 只写入 `.env` 的 `AI_API_KEY`。

AnythingLLM 使用 `generic-openai` Provider、原生 Embedding 与内置 LanceDB。基础地址应包含 API 的 `/v1` 前缀；脚本会自动避免重复拼接 `/v1`。

## AnythingLLM 初始化

首次启动后，在本机访问 AnythingLLM 管理页面，创建名为 `crisp-support` 的工作区，并在“Developer API”中创建独立 API Key。随后通过 `./manage.sh` 保存该 Key。不同 Crisp conversation 使用各自的 `sessionId`，避免会话历史串线。

## Prompt

首次安装会从 `config/prompt.md.example` 创建 `config/prompt.md`。可通过管理菜单修改、导入或导出；导入文件必须是普通文件且位于允许的路径中。

## 知识库

支持 Markdown、TXT、PDF 和 DOCX。管理脚本只接受这些扩展名，并拒绝符号链接和路径穿越。AnythingLLM 负责解析、自动分块、向量化、检索和重新索引。
