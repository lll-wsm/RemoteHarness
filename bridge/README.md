# RemoteHarness Bridge(远程桥)

把 iPad 上的 MoCi 通过 ACP 连接到远程 Mac/Linux 上的 grok。

```
iPad (MoCi, ACP 客户端)
  │  ACP JSON-RPC over WebSocket + token
  ▼
bridge daemon (本仓库,跑在远程机器上,与 grok 同机)
  │  内部 ACP 客户端(server-key 鉴权)
  ▼
grok agent serve (127.0.0.1:2419)
```

## 前置

- Node.js >= 18
- 远程机器上已登录的 grok(Grok Build CLI),支持 `agent serve`

## 启动 grok agent serve

```sh
grok agent serve --bind 127.0.0.1:2419 --secret <SERVER_SECRET>
# 或
GROK_AGENT_SECRET=<SERVER_SECRET> grok agent serve
```

启动时会打印 WebSocket URL:`ws://127.0.0.1:2419/ws?server-key=<SERVER_SECRET>`。

## 一键启动/停止(推荐)

把「桥固定安全参数 + cloudflared 只能指向桥」固化成一条命令,避免每次手敲 `--url` 指向错误端口:

```sh
cd bridge
BRIDGE_TOKEN=$(npm run -s gen-token) GROK_SERVE_SECRET=<SERVER_SECRET> ./scripts/start.sh
# 桥就绪后自动起隧道,打印公网地址;按 Ctrl+C 同时关闭桥与隧道
```

- 脚本内 `--url` 写死为 `http://127.0.0.1:${BRIDGE_PORT}`(默认 8777),不会指向其他服务;
- 未设置 `BRIDGE_TOKEN` / `GROK_SERVE_SECRET` 时拒绝启动(fail-closed);
- 等桥就绪(healthz 带 token 探测)后才起隧道;退出时 trap 清理两个进程(已实测)。

## 启动桥

```sh
cd bridge
npm install
BRIDGE_TOKEN=<桥自己的token> GROK_SERVE_SECRET=<SERVER_SECRET> node src/index.js
```

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `BRIDGE_PORT` | `8777` | 桥监听端口 |
| `BRIDGE_BIND` | `127.0.0.1` | 监听网卡;局域网暴露用 `0.0.0.0` |
| `BRIDGE_TOKEN` | 空(不鉴权) | iPad 连接 token;公网/隧道场景必须设置 |
| `GROK_SERVE_URL` | `ws://127.0.0.1:2419` | grok agent serve 地址 |
| `GROK_SERVE_SECRET` | 空(必填) | agent serve 的 secret |
| `BRIDGE_REGISTRY_FILE` | `sessions.json` | chatID 会话注册表持久化文件 |

## 内网穿透(不依赖局域网)

桥就是监听本地端口(`BRIDGE_PORT`,默认 `8777`)的 WebSocket/HTTP 服务,任何能把公网地址转发到本地端口的隧道工具都能暴露它,桥本身无需改动。iPad 连隧道地址 + token 即可。

| 隧道 | 命令(在远程机器上执行) | iPad 连接地址 |
|---|---|---|
| Tailscale | `tailscale serve --bg 8777` | `ws://<machine>.ts.net:443?token=...`(自动 HTTPS) |
| SSH -R | `ssh -R 8777:127.0.0.1:8777 user@公网服务器` | `ws://公网服务器:8777?token=...`(裸 ws,靠 token 保护) |
| ngrok | `ngrok http 8777`(或 `ngrok tcp 8777`) | `wss://xxxx.ngrok-free.app?token=...`(自动 HTTPS) |
| frp | 客户端配置 `remote_port` 转发到 `127.0.0.1:8777` | `ws://服务器:remote_port?token=...` |

注意事项:
- 隧道场景视为**公网**,`BRIDGE_TOKEN` 必须设置(无 token 一律 401);
- HTTPS 类隧道(Tailscale / ngrok / cloudflared)自动带 TLS;裸 TCP 隧道(SSH -R / frp tcp 模式)是明文 `ws://`,鉴权靠 token,请自行评估传输层加密需求;
- 桥默认只监听 `127.0.0.1`,隧道客户端与桥同机转发回环端口即可,无需把 `BRIDGE_BIND` 改成 `0.0.0.0`。

## 安全(公网/隧道暴露时)

暴露公网意味着任何人都可能扫到你的隧道地址,而 grok 在远程机器上能执行命令、改文件,所以必须分层防御:

1. **传输加密**:优先 HTTPS 类隧道(cloudflared / ngrok / Tailscale 自动 TLS);SSH -R / frp 裸 TCP 是明文 `ws://`,自行评估。
2. **强 token(第一道防线)**:`node scripts/gen-token.mjs` 生成 128-bit 随机 token;用 `Authorization: Bearer <token>` 传递(比 `?token=` 好,query 会进日志)。
3. **默认失败关闭**:未设置 `BRIDGE_TOKEN` 时桥拒绝启动;`BRIDGE_ALLOW_NO_AUTH=1` 仅限纯本地调试。
4. **失败限流 + 审计**:每 IP 窗口内失败超限临时拒绝;所有连接按结果记录 `[audit]` 日志(不记 token)。
5. **边缘访问控制(最强)**:首选 Tailscale(地址只对你自己可见,等于没有公网暴露);cloudflared 命名隧道 + Cloudflare Access 可加邮箱/设备身份认证,端点对未授权者直接不可达。
6. **token 轮换**:怀疑泄露时改 `BRIDGE_TOKEN` 重启桥即可全部失效;不用时关掉隧道进程。
7. **权限收敛**:grok 尽量以低权限用户运行;必要时用 grok 的权限/沙箱模式限制工具执行范围。

### 环境变量补充

| 变量 | 默认 | 说明 |
|---|---|---|
| `BRIDGE_ALLOW_NO_AUTH` | 未设置 | `1` = 无 token 也放行(仅限纯本地调试) |
| `BRIDGE_ALLOW_IPS` | 空(不限) | 来源 IP 白名单,逗号分隔;经隧道按 `CF-Connecting-IP` 生效。例:`BRIDGE_ALLOW_IPS=203.0.113.9,198.51.100.7` |

`/healthz` 也需要 token(Query 或 Bearer)才能访问,防信息泄露。

白名单防伪造:仅当连接来源是回环(即确实来自本机隧道进程)时才信任 `CF-Connecting-IP` 头;不走隧道直连的非回环来源忽略该头,白名单按真实对端 IP 生效。

## 可选:隧道与桥之间的鉴权代理(无域名时的入口校验)

没有域名配不了 Cloudflare Access 时,可在 cloudflared 与桥之间加一道 **HTTP Basic Auth** 校验层:

```
互联网 → cloudflared → auth-proxy(8788,Basic Auth 校验)→ 桥(8777)
```

```sh
# 启动鉴权代理(与桥同机)
AUTH_PROXY_USER=<用户名> AUTH_PROXY_PASS=<密码> node src/auth-proxy.mjs
```

- cloudflared 的 ingress 改为 `service: http://localhost:8788`;
- 客户端约定:代理层用 `Authorization: Basic ...`;桥的 token 走 `?token=`(两层凭证互不干扰);
- 校验通过前任何流量(含 healthz)都不转发;失败关闭(未设用户名/密码拒绝启动);审计日志不记密码;
- 等价于桥自身握手 token 之外的纵深防御;如后续配了 Cloudflare Access,本代理可停用。

### 环境变量补充

| 变量 | 默认 | 说明 |
|---|---|---|
| `AUTH_PROXY_PORT` | `8788` | 鉴权代理监听端口 |
| `AUTH_PROXY_USER` / `AUTH_PROXY_PASS` | 必填 | Basic Auth 凭证(未设置拒绝启动) |
| `AUTH_PROXY_TARGET` | `http://127.0.0.1:8777` | 上游(桥)地址 |

## 验证

```sh
# healthz 需要 token(Query 或 Bearer)
curl -s "http://127.0.0.1:8777/healthz?token=<token>"
BRIDGE_TOKEN=<token> node scripts/smoke.mjs ws://127.0.0.1:8777

# 模拟 iPad 完整流程(initialize → session/new → session/prompt → 流式事件)
BRIDGE_TOKEN=<token> node scripts/e2e.mjs [ws://127.0.0.1:8777] ["测试提示词"]
# 公网同样可用:把 ws://127.0.0.1:8777 换成 wss://<公网URL>
```

## 客户端协议(桥对 iPad 的 ACP 约定)

- 标准 ACP 方法(JSON-RPC 2.0 over WebSocket):`initialize`、`session/new`、`session/load`、`session/prompt`、`session/cancel`、`session/rewind`、`session/close`;
- 桥扩展:`session/new` 的响应带 `chatID`(桥生成的稳定会话键,iPad 记住它,重连时用 `session/load { chatID }` 恢复);
- 字段为 **camelCase**(ACP 0.10.4 实测):`session/prompt` 参数 `{ sessionId, prompt: [{ type: "text", text }] }`;`session/new` 参数 `{ cwd, mcpServers: [] }`(cwd 缺省用 `BRIDGE_CWD`/home);桥自动注入 sessionId,客户端可只传 `{ prompt: "..." }`;
- 流式事件:`session/update` 通知,`params.sessionId` + `params.update.sessionUpdate`(`user_message_chunk` / `agent_thought_chunk` / `agent_message_chunk` / `response_completed` 等),另有 `_x.ai/*` 系列通知(queue/changed、sessions/changed 等),桥原样透传;
- 鉴权:WebSocket 升级时 `?token=` 或 `Authorization: Bearer <token>`;
- 示例:见 `scripts/e2e.mjs`(模拟 iPad 全流程)。
