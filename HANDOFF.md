# RemoteHarness 交接文档

**创建日期**: 2026-08-16
**状态**: **M1 完成(ACP 端到端已实测通过)** —— 关键决策已确认(路线 A、厚桥、Node.js);桥骨架 + 安全加固 + 一键启动脚本就绪;真实 grok(第三方模型 opencode-deepseek)端到端流式验证通过
**项目性质**: 独立原型(先不并入 MoCi),用于验证「iPad 远程控制 Mac/Linux 上的 grok」

---

## 1. 目标

在 iPad 上获得一个「远程 chat」体验:连接远程电脑( Mac / Linux ),驱动远程的 `grok`(Grok Build CLI)执行任务、输入提示、查看输出,交互体验与本地 chat 一致。

---

## 2. 背景调研

### 2.1 grok-build(grok CLI)的关键能力

源码位置:`/Users/lll/Projects.localized/GitHubProjects/grok-build`(Rust,SpaceXAI 的终端 AI coding agent)。

三种运行方式:
1. **交互 TUI** —— 全屏终端界面,远程驱动需要终端渲染,不推荐作为对接方式;
2. **headless**(脚本/CI 一次性执行)—— 支持 `-r/--resume`、`-c/--continue`、`-s/--session-id` 恢复会话,可作为过渡,但每次起新进程、加载成本高;
3. **ACP(Agent Client Protocol)** —— **官方为编辑器嵌入设计的 JSON-RPC 协议**,grok 有完整 ACP 会话实现(`crates/codegen/xai-grok-shell/src/session/acp_session*.rs`,`SessionActor` 管理 turn/提示队列/Plan Mode/Rewind),支持**通过 ACP WebSocket 多路复用终端 I/O**。这是「外部客户端驱动 grok 并看输出」的官方接口,体验上限最高。grok 自带 `agent serve` 子命令:监听 `127.0.0.1:2419`,`--secret`/`GROK_AGENT_SECRET` 鉴权,WebSocket URL 为 `ws://<addr>/ws?server-key=<secret>`(见 `xai-grok-pager-bin/src/main.rs::print_serve_startup_info`)。

### 2.2 MoCi 现状(参考:聊天 UX 与 Provider 抽象思路)

- iPad-only、SwiftUI、BYOK、无后端,工作区为纯文本文件;
- 已有聊天基础设施:`.chat` 文件、`ChatStore`(多轮工具循环、流式)、`MessageBubble` UI、`LLMProvider` 抽象(OpenAI 兼容 / Anthropic);
- 已有 MCP 客户端(`MCPToolRegistry`),无 SSH 客户端;iOS 13+ 自带 `URLSessionWebSocketTask` 可做 WebSocket。

---

## 3. 已确认的需求

- **远程环境**:Mac / Linux 均可;
- **网络**:局域网直连 **与** 内网穿透(Tailscale / SSH -R / frp / ngrok)都要支持 → 桥必须监听一个本地端口,可被隧道暴露;
- **安全**:公网可达场景必须 **token 鉴权**,不允许无鉴权裸奔;
- **会话语义(已确认)**:一个「远程 chat」对应远程一个**持续 grok 会话**(记住历史/计划模式,连续对话);
- **体验目标**:与本地 chat 一致(输入 → 流式输出 → 工具活动可见);
- **鉴权门(已确认)**:客户端必须先通过身份验证才能操作——连接 → ACP initialize 握手 → 成功才进入聊天界面;失败(401/token 错/超时)留在连接页,不进入任何操作;断线重连重新鉴权;客户端须正常校验证书,不做"跳过证书校验"开关。

---

## 4. 架构(已定稿:路线 A,ACP 端到端,厚桥)

```
iPad (独立 App, ACP 客户端)
  │  ACP JSON-RPC over WebSocket + token 鉴权
  ▼
远程桥 (daemon, Mac/Linux, Node.js)
  ├─ ACP 服务端(对 iPad):initialize / session/new / session/load /
  │    session/prompt / session/cancel / session/rewind / session/close
  ├─ 会话管理:chatID → grok 会话 映射,持久化到 sessions.json,桥重启可恢复
  ├─ token 鉴权 + 审计
  └─ 内部 ACP 客户端 → grok agent serve(127.0.0.1:2419,server-key 鉴权)
  ▼
grok 会话(远程文件系统/终端/工具;Plan Mode / Rewind / 持久化 / 压缩全在 grok 侧)

连接方式:
  局域网:   mac.local:PORT / IP:PORT
  内网穿透: Tailscale / SSH -R / frp / ngrok 暴露同一 PORT
```

**协议决策(2026-08-16 确认)**:
- 采用**路线 A**:客户端(独立 App)实现 ACP 客户端直连桥,**一步到位,不做路线 B**(OpenAI 兼容 SSE)过渡,避免后续协议迁移的双重成本;
- 桥采用**厚桥**:自己实现 ACP 服务端与会话管理(而非薄代理);
- 桥实现语言:**Node.js**;
- grok 驱动方式:桥作为 ACP 客户端连 grok 自带的 `agent serve`;
- 客户端 = **独立 iPad App(不并入 MoCi;MoCi 已在用)**,名称待定(工程目录 `ios-app/`)。

---

## 5. 工程结构

```
RemoteHarness/
├── HANDOFF.md          # 交接总览(本文件)
├── docs/               # 开发文档(架构/协议校准/安全/测试/进度)
│   └── README.md       # 文档索引;详细内容见 01~05
└── bridge/            # 远程桥(Node.js daemon,Mac/Linux)
    ├── src/
    │   ├── index.js            # 入口:HTTP(healthz)+ WebSocket 服务
    │   ├── config.js           # 配置(环境变量)
    │   ├── auth.js             # token 鉴权 / IP 白名单 / 透传头信任
    │   ├── acp-server.js       # ACP 服务端:JSON-RPC 分发(对 iPad)
    │   ├── session-manager.js  # chatID → grok 会话 注册表(JSON 持久化)
    │   ├── grok-client.js      # ACP 客户端:连 grok agent serve(initialize 握手)
    │   ├── rate-limiter.js     # 失败限流
    │   └── auth-proxy.mjs      # 可选:隧道与桥之间的 Basic Auth 校验层
    ├── scripts/
    │   ├── start.sh            # 一键启动/停止(桥+隧道)
    │   ├── smoke.mjs           # initialize 冒烟
    │   ├── e2e.mjs             # 模拟 iPad 完整流程(流式)
    │   └── gen-token.mjs       # 128-bit 强 token 生成
    └── README.md
└── ios-app/           # 独立 iPad App(ACP 客户端,名称待定)—— M2 起
```

---

## 6. 里程碑

1. **M1 桥(ACP 端到端)✅ 完成(2026-08-16)**:bridge 起 ACP WebSocket 服务 + token 鉴权;内部 ACP 客户端连 grok agent serve;跑通 initialize → session/new → session/prompt → session/update 流式;真实 grok(opencode-deepseek-v4-flash)逐字流式回复验证通过。**校准要点**:ACP 0.10.4 JSON 字段为 camelCase(`sessionId`/`mcpServers`/`protocolVersion`);`initialize` 必须带 `protocolVersion`+`clientCapabilities`;`session/prompt` 参数为 `{sessionId, prompt:[{type:"text",text}]}`;流式事件为 `session/update` 通知(`params.sessionId` + `params.update.sessionUpdate` 区分 user_message_chunk/agent_thought_chunk/agent_message_chunk 等);会话持久化在 grok 侧(`~/.grok/sessions/<cwd>/<session_id>/`);
2. **M2 独立 iPad App(ACP 客户端)**:新建 SwiftUI App;实现 ACP 客户端(URLSessionWebSocketTask);**鉴权门**:连接设置页(URL + token)→ initialize 握手 → 成功才进入聊天,失败留在连接页显示错误;局域网先跑通;
3. **M3 会话与工具**:chatID 持久会话、工具活动/终端输出渲染、token 配置 UI、隧道连接;
4. **M4 发布决策**:验证 OK 后进入正式发布准备(TestFlight / App Store);视评估决定是否延伸 Mac 客户端。

---

## 7. 安全要求

- 桥默认只监听本地回环或指定网卡;由用户显式决定暴露范围;
- 所有请求必须携带 token(Header 或 Query),token 由远程启动桥时生成/配置;
- 隧道场景视为公网:无 token 拒绝;失败重试/速率限制可选;
- 日志不得输出 token。
- **已实现(2026-08-16)**:未设置 token 默认拒绝启动(失败关闭);token 比较常数时间;每 IP 失败限流(超限临时拒绝);`[audit]` 审计日志(结果+来源 IP,不记 token);`scripts/gen-token.mjs` 生成 128-bit 强 token;经隧道按 `CF-Connecting-IP` 取真实客户端 IP;**`/healthz` 需 token 访问(防信息泄露);可选来源 IP 白名单 `BRIDGE_ALLOW_IPS`(即使 URL 泄露,非白名单 IP 连入口都进不来)**。
- **建议的运维层防御**:Tailscale 优先(无公网暴露);cloudflared 命名隧道 + Cloudflare Access;token 定期轮换;grok 以低权限用户运行。

---

## 8. 开放问题(2026-08-16 更新)

1. ~~独立 App 定位~~ → **已定**:客户端 = **独立 iPad App**(不并入 MoCi;MoCi 已在用),名称待定;
2. ~~会话语义~~ → **已确认**:一个 remote chat = 一个持续 grok 会话;
3. ~~桥的语言~~ → **已定**:Node.js;
4. ~~协议取舍~~ → **已定**:路线 A(ACP 端到端),不做路线 B;
5. 鉴权细节(进行中):iPad 侧 token 生成/配置/传递方式待细化;桥默认只监听回环或指定网卡(安全要求见第 7 节);
6. ~~远程 grok 的启动方式~~ → **已定**:grok `agent serve`(ACP),非 headless。

---

## 9. 关键参考

- grok-build:`/Users/lll/Projects.localized/GitHubProjects/grok-build`
  - ACP 会话实现:`crates/codegen/xai-grok-shell/src/session/acp_session*.rs`
  - 终端经 ACP WebSocket 复用:`crates/codegen/xai-grok-shell/src/terminal/pty_session.rs`
  - `agent serve` 子命令:`crates/codegen/xai-grok-pager/src/app/cli.rs`(ServeArgs,默认 `127.0.0.1:2419`);WebSocket URL `ws://<addr>/ws?server-key=<secret>`(`crates/codegen/xai-grok-pager-bin/src/main.rs`)
  - headless 会话恢复(备用):`-r/--resume`、`-c/--continue`、`-s/--session-id`(`app/cli.rs` PagerArgs)
  - 项目文档:`docs/project-guide/11-session.md`(会话/持久化)、`06-compaction.md`(上下文压缩)、`17-terminal.md`
- MoCi:`/Users/lll/Projects.localized/SwiftProjects/MoCi`
  - 聊天:`MoCi/Sources/Chat/`(`ChatStore`、`ChatView`)
  - Provider 抽象:`MoCi/Sources/LLM/LLMProvider.swift`、`OpenAICompatProvider.swift`
  - MCP 客户端:`MoCi/Sources/MCP/MCPToolRegistry.swift`

---

## 10. 下一步建议

1. 完成 M1:在远程机器启动 `grok agent serve`,跑通 bridge 的 ACP 端到端验证(initialize → session/new → prompt → update 流);
2. 验证通过后进入 M2:独立 iPad App(ACP 客户端)。
