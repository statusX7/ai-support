# Crisp 接入：凭据、Hook、按钮与欢迎网页

本页针对一个 Crisp workspace 的自部署客服，默认 Website Token + Website Hook；不要求 Marketplace、两套 Hook 或新的聊天前端。项目源码和 [新手安装教程](INSTALL.md) 已公开，下载不需 GitHub 授权；这不改变你在 Crisp 中所需的工作区管理权限，也不会公开实例凭据。2026-09-07 核对下列官方英文资料；真实账号权限、界面与消息投递以实际账户为准，源码协议测试不能替代真实 Crisp 验收。

## 1. 获取三项凭据

用工作区拥有者账号登录 Crisp：

1. `Settings → Workspace Settings → Setup Instructions` 取得对应 Website ID。
2. `Settings → Workspace Settings → Advanced configuration → API Token → Generate Token` 生成 Website Token。
3. 分别保存 Identifier 和 Secret Key；它们只显示一次。拥有者才能生成、轮换或撤销；没有入口时先核对权限与所选 workspace，不要拿其他类型 Token 冒充。

以下简繁中文仅是英文关键词的定位释义，不声称是实测账户里的逐字界面翻译；实际后台版本或语言不同仍按英文路径核对：

| 官方英文定位词 | 简体释义 | 繁體釋義 |
| --- | --- | --- |
| Settings / Workspace Settings | 设置 / 工作区设置 | 設定 / 工作區設定 |
| Setup Instructions | 安装说明 | 安裝說明 |
| Advanced configuration | 高级配置 | 進階設定 |
| API Token / Generate Token | API 令牌 / 生成令牌 | API 權杖 / 產生權杖 |
| Identifier / Secret Key | 标识符 / 秘密密钥 | 識別碼 / 秘密金鑰 |
| Web Hooks / Add a Web Hook | Web Hooks / 添加回调 | Web Hooks / 新增回呼 |
| Add Hook Target | 添加回调目标 | 新增回呼目標 |

把这些值填入安装向导第 4～6 项；安装后换整组凭据用 `crispai → 10 → 11`，修一个错误值用 `10 → 2/3/4`。脚本自动用 Identifier + Key 构造 Basic 认证和 `X-Crisp-Tier: website`；用户无需写 Header、拼接字符串或在线 Base64 编码。Website Token 只访问所属 workspace；官方核对时配额为每天 10000 次，仍以账户实际限制为准，避免高频轮询。依据：[Website Token 官方说明](https://docs.crisp.chat/guides/rest-api/authentication/website-token/)。

## 2. 公网 HTTPS 与登记 Hook

先完成安装。裸域名在 DNS、80/443 和网络条件满足时使用受管 Caddy；已有 Nginx/宝塔/Caddy 使用安装器生成的反代片段，不覆盖原网站。证书必须有效，不接受跳过 TLS 校验。DNS A/AAAA、灰云/橙云、Full (strict) 和精确路径配置按 [安装教程第 5 节](INSTALL.md) 完成；Crisp 机器 POST 不能通过 Cloudflare Challenge 或网页登录验证。只有域名管理员调整所需规则，脚本不改云账户。

反代日志保护也必须生效：仅关闭访问日志不足以防止上游故障时将完整 Hook URL 写进错误日志。受管 Caddy 模板对默认运行日志替换请求 URI、移除 Authorization/Cookie。生成的 Nginx 片段在本项目三个精确 `location` 中同时设置 `access_log off` 与 `error_log /dev/null`，代价是这些路由不再保留原始上游错误日志，改用 doctor 和应用脱敏日志排查；其他站点不受该片段影响。

外部 Caddy 的站点片段不能替管理员改全局日志；还须由有权限的人把下列过滤合并到现有全局块及 `log default`，不要盲目追加第二份全局定义。过滤作用于该 Caddy 的默认运行日志，需评估同实例其他站点的诊断需求；检查配置并重载后，用虚构请求验证错误日志不含敏感 URI/请求头。已有自定义访问日志也须关闭敏感路由记录或单独脱敏；不要用真实 Hook Secret 做日志试验。

```caddyfile
{
  log default {
    format filter {
      request>uri replace [REDACTED]
      request>headers>Authorization delete
      request>headers>Cookie delete
    }
  }
}
```

过滤语法和运行日志作用域依据：[Caddy 日志过滤](https://caddyserver.com/docs/caddyfile/directives/log#filter)、[全局日志选项](https://caddyserver.com/docs/caddyfile/options#log)。

在私密终端进入 `crispai → 10 → 7`，确认后复制本实例准确生产 URL。它包含随机 URL Secret，不要截图、写公开文档或放进网页。示意结构为 `https://support.example.com/webhook/crisp-webhook?key=<本机生成值>`；以本机实际输出为准，不能把示意地址用于部署，也不能使用 `/webhook-test/`。

进入 `Settings → Workspace Settings → Advanced configuration → Web Hooks → Add a Web Hook`，填写名称和刚复制的 URL，订阅下表事件后选择 `Add Hook Target`。本版未发现可凭默认 Website Token 自动登记的已验证官方接口，因此不会猜接口或模拟后台登录；这里只需管理员登记一次。依据：[Website Hooks 官方步骤](https://docs.crisp.chat/guides/web-hooks/website-hooks/)。

| 事件 | 本项目用途 | 默认路径 |
| --- | --- | --- |
| `message:send` | 访客消息、图片及支持的选择回流 | 必选 |
| `message:received` | operator 公开消息，区分真人与 automated 出站 | 必选 |
| `message:updated` | picker 选择更新，可能没有 from/type | 必选，v1.0.1 升级必须补查 |
| `session:sync:events` | 可选网页 SDK 的加载/打开欢迎信号 | 使用相应欢迎模式时增加 |

这四项当前均支持 Website Hook。不要订阅 `session:set_opened` 来表示访客开聊天框，它表示 operator 打开会话；在线、输入、已读也不代表真人回复。Website Hook 无签名，依靠随机 URL Secret 与网站/会话校验；Plugin Hook 使用签名，两者不得混用。官方对 Website Hook 不提供 Plugin 相同的失败重试保证，维护停机不能承诺追回所有未收到消息。依据：[Web Hooks 事件与可用模式](https://docs.crisp.chat/references/web-hooks/v1/)。

登记后执行 `crispai doctor` 或 `10 → 6`。REST 认证、公网端点和真实 Hook 收件是不同事实；错误 Secret 返回项目特有 401 只能证明生产接收节点存在，不能证明 Crisp 已真实投递。Crisp 官方接受成功的 2xx 响应，重定向不算成功；后台最后调用状态可能延迟约一分钟。还要按下一节发送测试消息，核对 `10 → 12` 的当前配置观察。若后台看不到登记情况，不能仅凭 REST 身份 200 推断 Hook 已建好。依据：[官方 Hook 检查说明](https://docs.crisp.chat/guides/web-hooks/website-hooks/)。

## 3. 两位访客的最小验收

使用自己掌握的测试会话和两个独立浏览器配置文件 A/B，不向随机客户发测试。避免旧商业机器人和本项目同时回复测试会话；只处理冲突的旧自动化，不关闭 Crisp 正常人工功能。

先完成最小闭环：真实网页聊天框的 A 发一句虚构业务问题，后台确实收到该访客消息，项目 `10 → 12` 有可信 Hook/AI 往返事实，A 的聊天框收到 AI 回答。缺任何一环仍为 `External Validation Pending`；手工 POST 项目 Hook、容器 healthy 或模拟 SDK 都不能替代这一项。

1. A/B 各问一个虚构知识问题，确认答案和上下文不混用；A 再发一张不含隐私的图片并追问。
2. A 输入“人工”：应看到原生“召唤人工客服 / 继续 AI 客服”选择卡片；不点击，A 再问普通问题仍得到 AI 回复，B 不变。
3. A 真正点击确认：只暂停 A，确认只发一次；B 继续自动回答。重复点击不重复通知、不重置时间。
4. 在 Crisp 后台对 A 发公开文字或图片：立即维持 A 人工模式，最近真人回复更新 A 截止时间；内部 note 不触发。用 `7 → 3` 查看。
5. 暂设恢复 10 秒；真人在第 6 秒再回复，A 应在第 16 秒后下一问恢复。访客消息不延长；设为 0 后必须管理员明确恢复。
6. 用 `crispai disable` 关闭：所有自动出站静默，真人继续工作；重新启用后保留各会话人工状态，不补答历史。

原生控件采用 Crisp `picker` 的 id/text/choices/value/label/selected。项目动作不写入官方只支持 link/frame 的 `choice.action.type`；发送标记 automated 并绑定 fingerprint。按钮有效性还受本机会话、期限、代次和消费记录限制，手打按钮文字不会接管。依据：[Crisp REST 消息契约](https://docs.crisp.chat/references/rest-api/v1/)。

## 4. 欢迎消息与自动展开是两项配置

`crispai → 9` 管理欢迎。默认欢迎启用、首条访客消息触发，自动展开关闭；首条消息模式无需修改网页。欢迎每会话持久去重，人工期间或总开关关闭不发送。

页面加载/打开时欢迎，或自动展开聊天框，需要一次性接入无密钥脚本：

1. `9 → 9` 显示本实例生成的 script 标签。
2. 将其放在站点已有 Crisp 初始化代码之后，不再复制第二份 Crisp 安装代码；若有 CSP，允许自己的客服 HTTPS 源脚本和配置请求。
3. 反代允许 `GET /webhook/crispai-web-chat` 和 `GET /webhook/crispai-public-config`；受管 Caddy 由安装器配置，已有反代使用 `config/crispai-nginx.conf` 或 `config/crispai-caddy.conf` 的实际路由、前缀与端口，不覆盖原站点。
4. Hook 增加 `session:sync:events`；再到 `9 → 5` 选加载/打开模式，`9 → 6` 单独控制自动展开。

以下只是不含密钥的结构示例，实际 URL 使用菜单生成值：

```html
<script src="https://support.example.com/webhook/crispai-web-chat"
        data-config-url="https://support.example.com/webhook/crispai-public-config"
        defer></script>
```

脚本用 `session:loaded`、`chat:opened` 监听，通过 `session:event` 给 Crisp 上报；后端只接收经 Hook 校验的当前会话信号。展开用 `chat:open`，并先读取白名单 UI 配置；配置不可取、全局停用或该会话人工时不强制展开。页面不能读取 Prompt、知识、Token 或 Hook Secret，也不能匿名向其他会话发欢迎。以后修改文案/开关只用 Shell，不重复修改网页。依据：[官方 Web Chat SDK](https://docs.crisp.chat/guides/chatbox-sdks/web-sdk/dollar-crisp/)。

在自己有权限的网站检查加载、手动打开、刷新和多标签页：欢迎不应重复，自动展开关闭时不强开。没有网页编辑权限时只能完成本地 SDK/协议检查，真实站点仍标 `External Validation Pending`。

## 5. 已有 Plugin 配置的高级兼容

`10 → 9` 分别设置 Token tier 和 Hook mode，二者不必相同。已有 Plugin Token 使用 Basic + `X-Crisp-Tier: plugin`；Plugin Hook 另外需要对应 Signing Secret，并严格校验原始 body 的 HMAC 与时间窗，不降级成 Website Secret。

如确需建立 Plugin，按官方的 Marketplace 私有插件、Production Token 申请及安装到目标 workspace 步骤操作，不复用 Website Token。最低权限按实际使用核对：`website:conversation:messages` 读/写（历史、原消息、发消息），`website:conversation:sessions` 读/写（metadata 标签并集），欢迎页面事件需 `website:conversation:events` 读。基础诊断 `GET /v1/website/{website_id}` 官方当前未单列专用 scope，仍须授权关联该 workspace；不要因此猜造 `website:information` 权限。仅启用所需范围，不申请无关坐席、支付或路由权限。依据：[Plugin Token 官方流程](https://docs.crisp.chat/guides/rest-api/authentication/plugin-token/)、[各 REST 路由 scope](https://docs.crisp.chat/references/rest-api/v1/)。

## 6. 常见问题

401/403 先核对 Website ID、Token 两部分、tier 和账户授权；404 核对生产路径、实际反代顺序和 workflow。Caddy 的兜底 `respond 404` 不应先拦截合法 Hook；v1.2.0 受管模板用互斥 `handle` 路由，修改后须先验证配置。TLS/超时检查 DNS 的 A/AAAA、证书、反代和外网访问；HTML Challenge 不是项目 JSON 响应。卡片出现但不暂停优先检查 `message:updated`；AI 自己回流被误判时看 automated/fingerprint 对账和事件配置。不要用关闭鉴权、公开管理端或删除数据“修复”接入。完整入口见 [故障排查](TROUBLESHOOTING.md)。
