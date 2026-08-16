# 02 ACP 0.10.4 协议实测校准记录

> 本文件记录桥对接真实 grok(`agent serve`)时校准出的 ACP 协议细节。所有结论均来自对真实 grok 的实测(非文档猜测),是实现客户端(MoCi)的参考依据。

## 1. 传输与握手

- WebSocket URL:`ws://<host>:<port>/ws?server-key=<secret>`(secret 即 `agent serve` 的 `--secret` / `GROK_AGENT_SECRET`);
- **必须先发 `initialize`**(带 `protocolVersion` + `clientCapabilities`),之后才能调用 session 方法;
- JSON-RPC 2.0 framing:`{"jsonrpc":"2.0","id":N,"method":"...","params":{...}}`;
- 通知(无 id)与请求响应(有 id)在同一连接上混流。

## 2. 字段命名:camelCase(重要)

ACP 0.10.4 的 JSON 字段是 **camelCase**,不是 Rust 源码里的 snake_case:

| 写 | 错(会报 Invalid params) |
|---|---|
| `sessionId` | `session_id` |
| `mcpServers` | `mcp_servers` |
| `protocolVersion` | `protocol_version` |

错误响应会带 `data` 字段说明缺哪个字段,例如:
`{"code":-32602,"message":"Invalid params","data":"missing field \`mcpServers\` at line 1 column 37"}`

## 3. 方法参数(实测形状)

### initialize
```json
{ "protocolVersion": "0.10.4", "clientCapabilities": {} }
```
响应返回 agent 能力(loadSession、promptCapabilities、mcpCapabilities 等)。

### session/new
```json
{ "cwd": "/absolute/path", "mcpServers": [] }
```
- `cwd` 必填(绝对路径);`mcpServers` 必填数组(可空);
- 响应 `result.sessionId` 是**后续所有请求的会话标识**;另带 `models`(可用模型列表)与 `_meta`(工作目录等)。

### session/prompt
```json
{ "sessionId": "<id>", "prompt": [ { "type": "text", "text": "你好" } ] }
```
- `sessionId` 必填;
- `prompt` 是 **ContentBlock 数组**(不是字符串);文本块形状 `{"type":"text","text":"..."}`;
- 响应在整轮结束后返回:`{"stopReason":"end_turn","_meta":{...,"usage":{...}}}`。

### session/load
```json
{ "sessionId": "<id>", "cwd": "/absolute/path", "mcpServers": [] }
```

### session/cancel / session/close
```json
{ "sessionId": "<id>" }
```

## 4. 流式事件(通知)

- 核心事件:`method: "session/update"`,`params.sessionId` + `params.update.sessionUpdate`:
  - `user_message_chunk` — 用户消息回显;
  - `agent_thought_chunk` — 思考过程增量(逐字);
  - `agent_message_chunk` — 回复内容增量(逐字,客户端渲染的主体);
  - `response_completed` / `turn_completed` — 轮次结束(带 usage);
  - `available_commands_update` / `session_info_update` 等 — 会话状态。
- 扩展事件:`_x.ai/queue/changed`(排队状态)、`_x.ai/sessions/changed`、`_x.ai/mcp/*`(MCP 初始化进度)、`_x.ai/session_notification`(session_summary_generated、turn_completed 等)。
- 客户端应按 `params.sessionId` 区分会话;`_x.ai/*` 事件对 UI(排队/工具/MCP 状态)有价值,建议透传或选择性渲染。

## 5. 桥对客户端的简化(客户端只需遵守这些)

桥在转发时自动做两件事,客户端可以更省事:

1. **自动注入 `sessionId`**:客户端只传 `{ "prompt": "..." }` 即可(桥按当前连接的 chatID 从注册表解析 grok 会话);
2. **prompt 归一**:客户端传字符串或 ContentBlock 数组都行,桥统一转成数组。

客户端完整流程:`initialize` → `session/new`(记下响应里的 `chatID`)→ 若干次 `session/prompt` → 重连时 `session/load { chatID }` 恢复。

## 6. 会话持久化

会话数据在 grok 侧:`~/.grok/sessions/<cwd>/<session_id>/`(`chat_history.jsonl`、`updates.jsonl`、`summary.json`、`plan.json` 等)。上下文压缩、Plan Mode、Rewind 全部由 grok 的 SessionActor 处理,桥与客户端无需关心。
