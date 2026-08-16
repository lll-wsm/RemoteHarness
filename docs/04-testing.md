# 04 测试方法

> iPad App 本质是「WebSocket + JSON-RPC 客户端」,没有 iPad 也能完整测试桥——用脚本/工具扮演它。

## 1. 测试矩阵

| 层 | 测什么 | 命令 | 预期 |
|---|---|---|---|
| T1 冒烟 | 语法/工具链 | `cd bridge && npm run check`、`npm run -s gen-token` | 全过;输出 43 字符 token |
| T2 本地桥 | 鉴权全链路 | healthz / smoke / e2e / 限流 | 401/200、initialize 版本、流式、429 |
| T3 隧道公网 | 公网入口 | start.sh → 公网 healthz / e2e(wss) | URL 可用,带 token 通过 |
| T4 真实 grok | 完整 ACP 流程 | e2e(桥已连 agent serve) | 流式事件 + end_turn 响应 |

## 2. 快速命令

```sh
cd bridge && npm install

# T1
npm run check
npm run -s gen-token

# T2(本地桥,无 grok 也能测到鉴权/initialize)
BRIDGE_TOKEN=<token> node src/index.js &
curl -s "http://127.0.0.1:8777/healthz?token=<token>"
BRIDGE_TOKEN=<token> node scripts/smoke.mjs ws://127.0.0.1:8777

# T3+T4(需要 grok agent serve)
grok -m opencode-deepseek-v4-flash agent serve --bind 127.0.0.1:2419 --secret <SECRET> &
cd bridge
BRIDGE_TOKEN=<token> GROK_SERVE_SECRET=<SECRET> ./scripts/start.sh
BRIDGE_TOKEN=<token> node scripts/e2e.mjs ws://127.0.0.1:8777 "你好"
```

## 3. 各脚本职责

| 脚本 | 作用 |
|---|---|
| `scripts/smoke.mjs` | 冒烟:连桥 → initialize → 打印响应后退出 |
| `scripts/e2e.mjs` | 模拟 iPad 完整流程:initialize → session/new → session/prompt → 打印全部流式事件与最终响应 |
| `scripts/gen-token.mjs` | 生成 128-bit 随机 token |
| `scripts/start.sh` | 一键启动:桥(固定安全参数)+ cloudflared(固定指向桥端口),Ctrl+C 一起关闭 |

## 4. 无 iPad 的手动测试

```sh
npm i -g wscat
wscat -c "wss://<公网URL>?token=<token>"
# 连上后依次发送:
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","id":2,"method":"session/new","params":{}}
{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"prompt":"你好"}}
```

## 5. 判断标准

1. healthz `grokConnected:true` → 桥 ↔ grok 通;
2. e2e 的 `session/prompt` 后出现 `[event]` 流(agent_thought_chunk / agent_message_chunk)→ ACP 端到端全通,这些事件就是 iPad 将来渲染的内容;
3. 最终 `[session/prompt 响应]` 带 `stopReason:"end_turn"` → 轮次完整结束。

## 6. 常用模型档位(本机配置)

`-m` 参数取 `~/.grok/config.toml` 的段名(2026-08-16 实测):

| -m 值 | 实际模型 | 端点 | 状态 |
|---|---|---|---|
| `glm-5-2` | GLM-5.2 | 火山方舟 | 周配额(会重置) |
| `deepseek-v4-flash` / `deepseek-v4-pro` | DeepSeek | api.deepseek.com | 需余额 |
| `opencode-deepseek-v4-flash` | DeepSeek(OpenCode) | opencode.ai | ✅ 可用 |
| `opencode-glm-5.2` | GLM-5.2(OpenCode) | opencode.ai | 未测(大概率可用) |
