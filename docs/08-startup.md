# 08 启动与测试手册

> 记录完整启动流程、验证点与自动化测试命令,供后续联调/回归使用。最后更新:2026-08-17(适用 M2.5)。

## 1. 架构与运行进程

一条聊天链路共 4 个进程/端:

```
[iPad/iPhone Bilink]  ──wss──►  [cloudflared 隧道](可选,公网)
                                    │
[iPad/iPhone Bilink]  ──ws───►  [桥 bridge]  ──ws──►  [grok agent serve]
   ({url,token})         127.0.0.1:8777        127.0.0.1:2419
```

- **grok agent serve**:被控端上的 ACP 服务(第三方模型,无需 xAI 登录);
- **桥(node src/index.js)**:iPad 的 ACP 服务端 + grok 的 ACP 客户端,会话注册表(chatID → grok 会话)持久化到 `sessions.json`(可用 `BRIDGE_REGISTRY_FILE` 改路径);
- **隧道(可选)**:cloudflared quick tunnel,把桥的 8777 暴露成 `https://*.trycloudflare.com`;iPad 填 wss 地址。

## 2. 前置条件

| 项 | 说明 |
|---|---|
| Node.js ≥ 18 | `node -v` 确认;桥依赖 `ws`,首次需 `cd bridge && npm install` |
| grok CLI | 本机可 `grok -m <模型段名> -p "hi"` 直接对话 |
| cloudflared | 公网测试才需要(`which cloudflared`) |
| 模型 API Key | 环境变量(见 `~/.grok/config.toml` 的 `env_key`):`DEEPSEEK_API_KEY` / `OPENCODE_API_KEY` / `ANTHOER_ARK_API_KEY` 等;余额不足会 402,当前推荐 `glm-5-2`(Ark) |

## 3. 启动流程

### 3.1 一键启动完整链路(start-all.sh,推荐)

`bridge/scripts/start-all.sh` 依次启动 **grok agent serve + 桥 + cloudflared 隧道**,自动完成密钥处理、就绪检查、公网地址获取;Crtl+C 同时关闭全部进程。

```sh
cd RemoteHarness/bridge
./scripts/start-all.sh
```

环境变量(均有默认值):

| 变量 | 默认 | 说明 |
|---|---|---|
| `GROK_SERVE_SECRET` | 自动生成 | serve 与桥共用;脚本启动时打印长度,复用请显式传入 |
| `BRIDGE_TOKEN` | 自动生成 | **启动时打印,填到 iPad 连接页**;复用请显式传入 |
| `GROK_MODEL` | 读取 `~/.grok/config.toml` 的 `[models].default` | **serve 实际模型由 `[models].default` 决定,`-m` 参数不生效**;换模型改配置文件后重启 serve(脚本打印的"模型"会随之显示) |
| `PROBE` | 0 | `PROBE=1` 时先用 `grok -p` 探测模型可用性(余额不足提前报错) |
| `TUNNEL` | 1 | `TUNNEL=0` 跳过 cloudflared,仅局域网 |
| `BRIDGE_PORT` / `GROK_SERVE_PORT` | 8777 / 2419 | 端口 |
| `BRIDGE_ENCRYPT_KEY` | 空 | **`.encrypt-key` 文件驱动**:文件存在即开启「加密必需」模式并每次启动打印密钥;`auto` = 无文件时自动生成并持久化;显式值 = 直接使用;三者都无 = 明文并提示启用方式。密钥经 HKDF→AES-256-GCM 端到端加密会话内容(见 docs/03 §5),App 档案需配置同一密钥 |

就绪后打印:模型、桥地址、**公网 wss 地址**、BRIDGE_TOKEN、healthz 与 e2e 测试命令、各进程日志路径。

> 若需跳过 serve/隧道单独起桥,用 `scripts/start.sh`(桥 + 隧道,`BRIDGE_TOKEN`/`GROK_SERVE_SECRET` 必填)。

### 3.2 分步启动 grok agent serve

```sh
GROK_SERVE_SECRET=<你自己生成的密钥,≥20字符>   # 例如 openssl rand -base64 32
grok -m glm-5-2 agent serve --bind 127.0.0.1:2419 --secret "$GROK_SERVE_SECRET" &
```

- `-m` 选模型段名(`--list-models` 或 config.toml 的 `[model.xxx]`);serve 需要模型可正常出回复,换模型前先用 `grok -m <段名> -p "hi"` 探余额;
- 启动成功会打印 `WebSocket URL: ws://127.0.0.1:2419/ws?server-key=<SECRET>`。

### 3.3 分步启动桥

```sh
cd RemoteHarness/bridge
BRIDGE_TOKEN=$(npm run -s gen-token)          # 128-bit,每次新生成
GROK_SERVE_SECRET=$GROK_SERVE_SECRET \
BRIDGE_REGISTRY_FILE=/tmp/rh-sessions.json \
  node src/index.js &
```

环境变量(均可省略,有默认值):

| 变量 | 默认 | 说明 |
|---|---|---|
| `BRIDGE_TOKEN` | 空(无 token 拒绝启动) | 客户端 Bearer token;`npm run -s gen-token` 生成 |
| `GROK_SERVE_SECRET` | 空 | 必须与 3.2 一致 |
| `BRIDGE_PORT` | 8777 | 监听端口 |
| `BRIDGE_BIND` | 127.0.0.1 | 监听地址 |
| `BRIDGE_ALLOW_IPS` | 空 | 逗号分隔 IP 白名单(公网暴露强烈建议) |
| `BRIDGE_REGISTRY_FILE` | sessions.json | 会话注册表持久化文件 |

### 3.4 (可选)公网隧道

```sh
cloudflared tunnel --url http://127.0.0.1:8777 --no-autoupdate
# 输出里找: https://xxxxxxxx.trycloudflare.com
```

iPad 端连接地址填 `wss://xxxxxxxx.trycloudflare.com`,token 不变。

## 4. 启动后的验证

```sh
# 桥健康检查(token 鉴权)
curl -s "http://127.0.0.1:8777/healthz?token=$BRIDGE_TOKEN"
# → {"ok":true,"grokConnected":true,"sessions":N}

# 桥语法自检
cd bridge && npm run check

# 端到端文本对话(走完整 ACP 链路)
BRIDGE_TOKEN=$BRIDGE_TOKEN node scripts/e2e.mjs ws://127.0.0.1:8777 "你好"
BRIDGE_TOKEN=$BRIDGE_TOKEN node scripts/e2e.mjs wss://<公网URL> "你好"
```

## 5. 自动化测试(CLI,驱动真 ChatStore / SessionStore)

编译(需与 App 同源,含 M2.5 会话管理):

```sh
cd Bilink
swiftc -swift-version 5 -o /tmp/bilink-acp-test \
  Bilink/Networking/ACPError.swift \
  Bilink/Networking/ACPWire.swift \
  Bilink/Networking/ACPClient.swift \
  Bilink/Models/ChatMessage.swift \
  Bilink/Models/SessionMeta.swift \
  Bilink/Stores/SessionStore.swift \
  Bilink/Stores/ChatStore.swift \
  test/acp-client-test/main.swift
```

运行:

```sh
source <含 BRIDGE_TOKEN 的 env 文件>   # 或直接 export

# 鉴权门验证(initialize 握手/错误分类)
/tmp/bilink-acp-test connect ws://127.0.0.1:8777 "$BRIDGE_TOKEN"

# 会话管理回归:清空本地状态后连跑两次
defaults delete bilink-acp-test 2>/dev/null
rm -f ~/Library/Application\ Support/BilinkSessions/index.json \
      ~/Library/Application\ Support/BilinkSessions/*.json

# 第一次:应新建会话 + 流式回复(消息数=2,有助手 OK)
/tmp/bilink-acp-test chat ws://127.0.0.1:8777 "$BRIDGE_TOKEN"

# 第二次:应恢复同一 chatID(未新建)+ 本地历史还原(消息数=4)
/tmp/bilink-acp-test chat ws://127.0.0.1:8777 "$BRIDGE_TOKEN"
```

通过判定:两次均打印 `✅ 聊天链路验证通过`;第二次打印 `✅ 重开恢复了最近会话(未新建)` 与历史消息。

## 6. 停止

```sh
# 桥/隧道是 start.sh 起的 → 直接 Ctrl+C
# 手动起的:
kill <bridge_pid> <grok_serve_pid>   # cloudflared 同理会话结束才停
```

## 7. 常见问题

| 现象 | 原因与处理 |
|---|---|
| 会话错误横幅 "API 额度不足" | 模型账户余额耗尽(402);换可用模型:`~/.grok/config.toml` 的 `[models].default` 改为有余额的段名(如 `glm-5-2`)后重启 serve。**`grok -m` 只影响交互 CLI,对 `agent serve` 无效**。DeepSeek 直连 / opencode 网关当前均欠费,GLM Ark(glm-5-2)可用 |
| `session/new` 返回 Invalid params | 客户端会话未创建成功(M2.5 之前的 isPreparing 拦截 bug 已修);确认桥日志无异常、serve 已就绪 |
| 重开 App 变"新会话" | 老版本行为;M2.5 起恢复最近会话,`session/load` 失败也会保留本地历史并提示 |
| 桥启动即退出 | 未设 `BRIDGE_TOKEN`/`GROK_SERVE_SECRET`(fail-closed);检查环境变量 |
| 图标显示旧样式 | iOS 图标缓存;重装后重启设备或切换壁纸刷新 |