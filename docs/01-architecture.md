# 01 架构与关键决策

> 记录 RemoteHarness 的总体架构与开发过程中作出的关键决策及其理由。

## 1. 目标与定位

在 iPad 上获得一个「远程 chat」体验:连接远程电脑(Mac/Linux),驱动远程的 `grok`(Grok Build CLI)执行任务、输入提示、查看输出,交互体验与本地 chat 一致(输入 → 流式输出 → 工具活动可见)。

项目性质:独立原型,验证协议与体验后决定是否并入 MoCi。

## 2. 总体架构(定稿)

```
iPad (Bilink, ACP 客户端)
  │  ACP JSON-RPC over WebSocket + token 鉴权
  ▼
远程桥 (daemon, Mac/Linux, Node.js)
  ├─ ACP 服务端(对 iPad):initialize / session/new / session/load /
  │    session/prompt / session/cancel / session/rewind / session/close
  ├─ 会话管理:chatID → grok 会话 映射,持久化到 sessions.json,桥重启可恢复
  ├─ token 鉴权 + 审计 + 限流 + IP 白名单
  └─ 内部 ACP 客户端 → grok agent serve(127.0.0.1:2419,server-key 鉴权)
  ▼
grok 会话(远程文件系统/终端/工具;Plan Mode / Rewind / 持久化 / 压缩全在 grok 侧)

连接方式:
  局域网:   mac.local:PORT / IP:PORT
  内网穿透: Tailscale / SSH -R / frp / ngrok / cloudflared 暴露同一 PORT
```

## 3. 关键决策记录

| # | 决策 | 内容 | 理由 |
|---|---|---|---|
| D1 | **协议:路线 A(ACP 端到端)** | 客户端实现 ACP 客户端直连桥,不做路线 B(OpenAI 兼容 SSE)过渡 | 一步到位,避免后续协议迁移的双重成本;ACP 是 grok 官方为外部客户端设计的 JSON-RPC 协议,体验上限最高 |
| D2 | **桥形态:厚桥** | 桥自己实现 ACP 服务端与会话管理(而非薄代理) | 对会话生命周期、鉴权、审计有完全控制权,适合长期演进 |
| D3 | **桥语言:Node.js** | 跨 Mac/Linux 的守护进程;WebSocket + JSON-RPC 生态成熟 | 协议胶水代码开发最快;不依赖 grok-build 的 Rust crate,按协议通信即可 |
| D4 | **grok 驱动:agent serve** | 桥作为 ACP 客户端连 grok 自带的 `grok agent serve`(`ws://127.0.0.1:2419/ws?server-key=<secret>`) | SessionActor(会话持久化/压缩/Plan Mode/Rewind)全部复用,桥不重复实现 |
| D5 | **会话语义** | 一个「远程 chat」= 远程一个持续 grok 会话(chatID 为稳定标识) | 与本地 chat 的持续会话一致;桥重启后按 chatID 经 session/load 恢复 |
| D6 | **客户端 = Bilink(比邻,独立 iPad App)** | 新建独立 SwiftUI App,不并入 MoCi(MoCi 已在用);「天涯若比邻」——远程机器如邻座 | 不影响 MoCi 现有功能;独立演进、独立发布 |
| D7 | **第三方 API 鉴权** | grok 用第三方 OpenAI 兼容端点 + env_key(如 OPENCODE_API_KEY),不登录 xAI | 服务器/CI 场景不需要浏览器 OAuth;经 `grok -m <模型段名> agent serve` 指定模型 |

## 4. 桥组件职责(bridge/src)

| 文件 | 职责 |
|---|---|
| `index.js` | 入口:HTTP(healthz)+ WebSocket 升级;失败关闭启动检查 |
| `config.js` | 环境变量配置(端口/监听网卡/token/白名单/grok 地址/默认 cwd) |
| `auth.js` | token 鉴权(常数时间比较)、IP 白名单、透传头信任(仅回环来源) |
| `acp-server.js` | ACP 服务端:JSON-RPC 分发;会话方法注入 sessionId;prompt 归一 ContentBlock;通知按会话路由 |
| `session-manager.js` | chatID → grok 会话注册表,sessions.json 持久化 |
| `grok-client.js` | 到 agent serve 的长连接;initialize 握手;断线指数退避重连 |
| `rate-limiter.js` | 每 IP 失败限流 |
| `auth-proxy.mjs` | 可选:隧道与桥之间的 HTTP Basic Auth 校验层(无域名时的入口校验) |

## 5. 部署形态

- 桥跑在**被远程控制的那台机器**上(Mac/Linux),与 grok 同机;
- iPad 上的 MoCi 是纯客户端,不跑桥;
- 公网可达:cloudflared quick tunnel / Tailscale / SSH -R / frp / ngrok 暴露桥的本地端口(默认 8777);
- 一键启动:`bridge/scripts/start.sh`(桥固定安全参数 + cloudflared 固定指向桥端口 + Ctrl+C 一起关闭)。
