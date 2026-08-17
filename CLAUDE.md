# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

RemoteHarness:让 iPad/iPhone 上的 Bilink(比邻)App 远程驱动 Mac/Linux 上的 grok(Grok Build CLI),获得与本地一致的流式聊天体验。三个组成部分:

- `bridge/` — Node.js 桥(daemon,跑在远程机器上,与 grok 同机)
- `Bilink/` — SwiftUI iOS App(ACP 客户端,iOS 18+,XcodeGen 工程)
- `docs/` — 开发文档(中文),`HANDOFF.md` 为交接总览;协议细节见 `docs/02-acp-protocol.md`,启动/测试手册见 `docs/08-startup.md`

文档与 commit message 均使用中文。

## 架构

```
Bilink (ACP 客户端)
  │  ACP JSON-RPC over WebSocket + token 鉴权(ws 局域网 / wss 隧道)
  ▼
bridge (ACP 服务端对 iPad + 内部 ACP 客户端)   127.0.0.1:8777
  │  server-key 鉴权
  ▼
grok agent serve (ACP)                          127.0.0.1:2419
```

关键设计(已定稿,勿轻易更改):路线 A(Bilink 直连桥,无 OpenAI 兼容 SSE 过渡层)、厚桥(桥自己实现 ACP 服务端与会话管理,非薄代理)、一个远程 chat = 一个持续 grok 会话。

### 桥(bridge/src/)

- `index.js` — 入口:HTTP `/healthz`(需 token)+ WebSocket 服务;fail-closed:未设 `BRIDGE_TOKEN` 且未显式 `BRIDGE_ALLOW_NO_AUTH=1` 时拒绝启动
- `acp-server.js` — 对 iPad 的 ACP 服务端,JSON-RPC 分发,流式事件(`session/update`、`_x.ai/*`)从 grok 原样透传
- `session-manager.js` — chatID(桥生成的稳定会话键)-> grok 会话注册表,持久化到 `sessions.json`,桥重启可恢复
- `grok-client.js` — 内部 ACP 客户端连 `grok agent serve`,断线自动重连
- `auth.js` / `rate-limiter.js` — token 常数时间比较、IP 白名单(经隧道按 `CF-Connecting-IP`,仅信任回环来源)、每 IP 失败限流
- `auth-proxy.mjs` — 可选的 cloudflared 与桥之间的 Basic Auth 层(端口 8788)

### Bilink App(Bilink/Bilink/)

- 鉴权门是硬门槛:`ProfileListView` 里点机器 → initialize 握手成功才进 `ChatView`,失败留在机器列表并提示;`ConnectionStore` 管状态机(idle/connecting/connected/reconnecting/failed)
- `ACPClient`/`ACPWire`/`ACPError`(Networking)基于原生 `URLSessionWebSocketTask`,零第三方依赖;可选应用层加密(`encryptionKey` 非空时 HKDF→AES-256-GCM 全帧加解密,与桥 `BRIDGE_ENCRYPT_KEY` 一致,见 `secure-channel.js`)
- `ChatStore` 聊天循环、`SessionStore` 会话持久化(`~/Library/Application Support/BilinkSessions/`),token 只存 Keychain(`KeychainService`),证书校验不提供跳过开关
- Markdown 渲染:SPM 依赖 `SwiftUIChatMarkdown`(自研,github.com/lll-wsm/SwiftUIChatMarkdown,iOS 18+),**只集成 `ChatMarkdownRenderer`**(不用其 Engine/View/SQLite 缓存),见 docs/11;工程依赖必须写 `project.yml` 再 xcodegen 生成,**勿用 Xcode GUI 添加**(实测 GUI 添加的包进不了依赖图)
- Xcode 工程由 XcodeGen 从 `project.yml` 生成;改工程配置要改 `project.yml` 再重新生成,不要直接编辑 `.xcodeproj`

### ACP 协议要点(0.10.4 实测校准)

- JSON-RPC 字段为 **camelCase**;`initialize` 必须带 `protocolVersion` + `clientCapabilities`
- `session/prompt` 参数 `{ sessionId, prompt: [{ type: "text", text }] }`;桥自动注入 sessionId,客户端可只传 `{ prompt: "..." }`
- `session/new` 响应带桥扩展字段 `chatID`,客户端重连时用 `session/load { chatID }` 恢复
- 流式事件为 `session/update` 通知(`params.update.sessionUpdate` 区分 `user_message_chunk` / `agent_thought_chunk` / `agent_message_chunk` / `response_completed` 等)

## 常用命令

### 桥

```sh
cd bridge
npm install
npm run check            # 语法自检(全部 src + scripts 文件,node --check)
npm run -s gen-token     # 生成 128-bit token

# 一键启动完整链路(grok agent serve + 桥 + cloudflared 隧道),Ctrl+C 全部关闭
./scripts/start-all.sh   # 启动时打印 BRIDGE_TOKEN 与公网 wss 地址

# 只起桥 + 隧道(BRIDGE_TOKEN / GROK_SERVE_SECRET 必填)
BRIDGE_TOKEN=$(npm run -s gen-token) GROK_SERVE_SECRET=<SECRET> ./scripts/start.sh
```

### 测试(无测试框架,靠脚本验证;矩阵见 docs/04-testing.md)

```sh
# 健康检查(healthz 也需要 token)
curl -s "http://127.0.0.1:8777/healthz?token=$BRIDGE_TOKEN"

# 冒烟:连桥 -> initialize
BRIDGE_TOKEN=$BRIDGE_TOKEN node scripts/smoke.mjs ws://127.0.0.1:8777

# 端到端(模拟 iPad 完整流程:initialize -> session/new -> prompt -> 流式事件)
BRIDGE_TOKEN=$BRIDGE_TOKEN node scripts/e2e.mjs ws://127.0.0.1:8777 "你好"
# 公网:把地址换成 wss://<隧道URL>
```

通过判定:e2e 出现 `[event]` 流(`agent_message_chunk` 等)且最终响应带 `stopReason:"end_turn"`。

### Bilink CLI 测试(驱动真 ChatStore/SessionStore/ProfileStore,无需模拟器)

```sh
cd Bilink
swiftc -swift-version 5 -o /tmp/bilink-acp-test \
  Bilink/Networking/ACPError.swift Bilink/Networking/ACPWire.swift Bilink/Networking/ACPClient.swift \
  Bilink/Services/KeychainService.swift \
  Bilink/Models/ChatMessage.swift Bilink/Models/SessionMeta.swift Bilink/Models/ConnectionProfile.swift Bilink/Models/ConnectionConfig.swift \
  Bilink/Stores/SessionStore.swift Bilink/Stores/ProfileStore.swift Bilink/Stores/ChatStore.swift Bilink/Stores/ConnectionStore.swift \
  test/acp-client-test/main.swift

# 鉴权门验证
/tmp/bilink-acp-test connect ws://127.0.0.1:8777 "$BRIDGE_TOKEN"
# 会话管理回归:第一次新建+回复,第二次重开恢复同一会话+本地历史
/tmp/bilink-acp-test chat ws://127.0.0.1:8777 "$BRIDGE_TOKEN" "测试机"
# 模拟重装:清本地索引,验证桥上远端发现恢复(不盲目新建)
/tmp/bilink-acp-test chat ws://127.0.0.1:8777 "$BRIDGE_TOKEN" "测试机" --recover
# 在线删除:桥注册表 + 本地目录同步清理
/tmp/bilink-acp-test delete ws://127.0.0.1:8777 "$BRIDGE_TOKEN" <chatID>
```

注意:新增 Swift 源文件时要同步更新上面 swiftc 的文件列表(CLI 测试不走 Xcode 工程)。

## 安全红线

- fail-closed:无 token 拒绝启动;`/healthz` 需 token;隧道场景视为公网
- 日志与审计(`[audit]`)不得输出 token/密码
- token 用 `Authorization: Bearer` 传递优于 `?token=`(query 会进日志)

## 当前状态(2026-08)

M1(桥端到端)与 M2/M2.5(Bilink 鉴权门、聊天、会话恢复)已完成;下一步 M3(工具活动渲染、多会话)。模型配额问题:serve 所用模型(`GROK_MODEL`,默认 `glm-5-2`)余额/配额耗尽会 402,换 `~/.grok/config.toml` 里的其他段名。
