# 07 Bilink(比邻)App 设计

> Bilink:独立 iPad/iPhone App,通过桥连接远程机器上的 grok(后续可扩展多 agent),提供与本地 chat 一致的远程聊天体验。本设计面向 M2 实现。

## 1. 目标与范围

**体验目标**:输入 → 流式输出 → 工具活动可见,与本地 chat 一致;远程机器如邻座(天涯若比邻)。

**M2 范围**:
- 连接设置 + **鉴权门**(握手成功才可操作);
- 聊天:发送消息、流式渲染、思考过程折叠;
- 会话:chatID 持久、断线重连、`session/load` 恢复;
- 安全:token 存 Keychain、证书校验默认开启。

**非目标(M2 不做的)**:文件浏览、终端 UI、会话列表多开、多 agent 逻辑(仅预留字段)、MCP/工具活动渲染(列入 M3)。

## 2. 平台决策

- **Universal App(iPad 优先,iPhone 兼容)**:SwiftUI 自适应布局——iPad 用宽屏双栏/居中聊天;iPhone 用纵向单聊;
- 最低系统:iOS 17(iPadOS 17),用现代 SwiftUI(Observable、`.onChange(of:)` 等);
- **零第三方依赖起步**:WebSocket 用原生 `URLSessionWebSocketTask`;markdown 渲染暂用原生 `AttributedString`(如体验不足,M3 再评估引入库)。

## 3. 信息架构(三个页面)

```
① 连接页 ConnectView —— 鉴权门
   连接名 / URL(wss://…) / token(密文输入,存 Keychain)/ 远程 agent(预留,默认 grok)
   [连接] → initialize 握手 → 成功进入聊天页;失败留在本页并显示具体错误
   最近连接列表(可选,UserDefaults 记住连接名与 URL,不含 token)

② 聊天页 ChatView —— 主界面
   顶部:连接状态条(已连接/重连中/失败/排队中)
   中间:消息列表(流式气泡)
   底部:输入栏(发送/停止)

③ 设置页 SettingsView(简单)
   主题、清除会话记录、关于
```

## 4. 核心流程

### 4.1 鉴权门状态机(ConnectionStore)

```
idle(连接页)
  → [点连接] → connecting(WebSocket 建立 + initialize 握手)
  → connected(进入聊天页;后续 ACP 方法可用)
  → failed(reason:401=token 错 / 超时=地址不可达 / 无法连接=URL 错误)
     → 留在连接页,展示 reason,可重试
断线重连:connected 中连接断开 → reconnecting(自动重连 + 重新握手)→ connected
重连失败累计超时 → failed,回到连接页(保留输入)
```

- **任何 ACP 方法(除 initialize)只在 connected 后可用**;未验证进不了聊天页——这是硬门槛;
- 证书校验:URLSession 默认开启,不提供"跳过证书校验"开关。

### 4.2 会话生命周期(ChatStore)

```
首次:connect(URL, token) → initialize → session/new(cwd 由桥兜底)→ 记 chatID(本地持久)
        → 后续消息走 session/prompt
重连/重进:记住的 chatID → session/load { chatID } → 恢复该会话历史(桥从 grok 端恢复)
        → 继续 session/prompt
```

- chatID 存在 UserDefaults(关联到连接名);token 只存 Keychain;
- 每个聊天连接 = 一个远程 grok 会话(与桥的 chatID 注册表对应)。

## 5. 事件 → UI 映射(依据 docs/02-acp-protocol.md)

| 事件(session/update 的 sessionUpdate) | UI 行为 |
|---|---|
| `user_message_chunk` | 把用户消息回显进气泡 |
| `agent_thought_chunk` | 追加到"思考"折叠块(默认收起,可展开) |
| `agent_message_chunk` | 追加到助手气泡,实时渲染(流式打字效果) |
| `response_completed` / `turn_completed` | 结束本轮;显示 usage 摘要(可选);允许下一条输入 |
| `_x.ai/queue/changed` | 状态条显示"排队中…"(entries 非空或 runningPromptId 出现) |
| `_x.ai/mcp/*` | 状态条显示 MCP 初始化进度(可选) |
| `_x.ai/session_notification`(turn_completed 等) | 收尾信号,同 turn_completed |

- 未知事件:静默忽略(协议向后兼容);
- 多会话事件:按 `params.sessionId` 过滤(当前连接只处理自己的会话)。

## 6. Swift 工程结构

```
Bilink/
├── BilinkApp.swift
├── Models/
│   ├── ConnectionConfig.swift   # url/token/agentName
│   ├── ChatMessage.swift        # 消息:role(user/assistant)/内容/时间/流式状态
│   ├── ThoughtBlock.swift       # 思考块(可折叠)
│   └── ACPTypes.swift           # JSON-RPC 消息、事件类型(解码用 Codable)
├── Networking/
│   ├── ACPClient.swift          # URLSessionWebSocketTask + JSON-RPC framing + initialize 握手
│   └── ACPError.swift           # 错误分类(unauthorized/timeout/unreachable/protocol)
├── Stores/
│   ├── ConnectionStore.swift    # 连接状态机 + 断线重连
│   └── ChatStore.swift          # 消息列表、流式追加、会话恢复、发送/停止
├── Views/
│   ├── ConnectView.swift        # 鉴权门(URL/token/agent/连接/错误)
│   ├── ChatView.swift           # 聊天主界面 + 状态条
│   ├── MessageBubble.swift      # 气泡(用户/助手)
│   ├── ThoughtBlockView.swift   # 思考折叠块
│   ├── InputBar.swift           # 输入 + 发送/停止
│   └── ConnectionStatusBar.swift# 连接/排队状态
├── Services/
│   └── KeychainService.swift    # token 存取(Keychain)
└── Resources/
```

MVVM:Views 持有 `@StateObject` Stores;Stores 驱动 ACPClient;Models 纯值类型。

## 7. 数据模型要点

```swift
struct ConnectionConfig: Codable { var name: String; var url: String; var agent: String = "grok" }
struct ChatMessage: Identifiable { let id: UUID; let role: Role; var text: String; var isStreaming: Bool }
enum Role { case user, assistant }
struct ThoughtBlock: Identifiable { let id: UUID; var text: String; var isExpanded: Bool = false }
```

ChatStore 内部:消息数组 `[ChatMessage]` + 进行中的助手消息引用(流式期间原地更新 text)。

## 8. UI 设计要点

- **气泡**:用户右侧(主色调)、助手左侧(浅色卡片);流式期间光标闪烁提示;
- **思考**:助手回复前的浅灰折叠块,"思考中…"或展开后显示内容;流式期间自动展开、完成后默认收起;
- **状态条**:顶部细条——已连接(绿点)/重连中(黄,转圈)/失败(红,文案)/排队中(进度文案);
- **输入栏**:多行输入、发送禁用条件(未连接/正在回复中)、停止按钮(发 `session/cancel`);
- **空态**:连接成功后无消息时显示引导文案;
- **iPad 布局**:聊天居中最大宽度(如 700pt),两侧留白;iPhone:全宽。

## 9. 错误处理

| 场景 | 表现 |
|---|---|
| initialize 返回 401 / token 错 | 连接页显示"token 错误",清空 token 输入 |
| 握手超时(如 10s) | "连接超时,检查地址或网络" |
| 无法连接(URL 错/隧道未开) | "无法连接,检查 URL" |
| 桥可达但 grok 未连(grokConnected:false) | 连接页警告"远程 grok 未就绪",仍允许进入(桥会报 -32603) |
| 发送时未连接 | 输入栏禁用 |

## 10. M2 内部里程碑

| 阶段 | 内容 | 验收 |
|---|---|---|
| M2.1 骨架+鉴权门 | 工程、ConnectView、ConnectionStore 状态机、ACPClient 的 initialize | 本地/公网握手成功/失败均符合状态机 |
| M2.2 聊天 | ChatView、气泡、流式渲染、发送/停止 | 与桥 e2e 一致:流式逐字显示 |
| M2.3 会话 | chatID 持久、断线重连、session/load 恢复 | 杀 App 重进恢复历史 |
| M2.4 打磨 | 思考折叠、状态条、错误态、Keychain、iPad/iPhone 布局 | 全流程走查 |

## 11. 与桥的对接核对清单(实现时对照)

- [ ] initialize 参数 `{protocolVersion:"0.10.4", clientCapabilities:{}}`(桥本地应答);
- [ ] session/new → 响应 `chatID`(桥生成),非 grok 的 sessionId(桥内部映射);
- [ ] session/prompt 只传 `{prompt:"..."}`,桥自动注入 sessionId、归一 ContentBlock;
- [ ] session/load 传 `{chatID}` 恢复;
- [ ] 事件:session/update 的 `params.update.sessionUpdate` 字段;`_x.ai/*` 事件透传;
- [ ] 认证:WebSocket 升级用 `Authorization: Bearer <token>`(不用 query,避免日志泄露)。
