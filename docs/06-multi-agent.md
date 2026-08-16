# 06 多 Agent 调研(2026-08-16)

> 结论:桥可扩展为多 AgentBackend,对 iPad(Bilink)协议不变。三个候选 agent 的协议支持差异极大,接法分层。

## 1. 对比(基于源码核实)

| Agent | ACP 支持 | 远程/服务模式 | 桥接入难度 | 体验上限 |
|---|---|---|---|---|
| grok | ✅ 原生 | `grok agent serve`(WebSocket) | ✅ 已实现 | 最高:流式、工具、Plan/Rewind、会话持久化 |
| deepseek-harness | ✅ 有 ACP 服务端 | `@deepseek-ai/dsh-acp`:JSON-RPC **stdio**,`pnpm run demo:acp` | 中(桥 spawn + stdio) | 低:仅整块提交、无流式、无恢复 |
| codex | ❌ 无(Cargo.lock 零引用) | 私有 `app-server` 协议 / `exec`+`resume` / `mcp-server` | 高 | 中~高(取决于接法) |

## 2. deepseek-harness(`packages/acp/acp/README.md`)

- ACP 服务器,stdio 传输(桥需 spawn 进程、管 stdin/stdout,无需端口/密钥);
- 方法:initialize / authenticate(no-op)/ session/new / session/prompt / session/cancel / session/update / session/request_permission;
- **硬限制**:fresh sessions only(无 load/list/resume/fork);baseline prompts only(拒绝非空 additionalDirectories / mcpServers);**committed answers only**(每提交文本块一条 agent_message_chunk,无 token 级流式、无推理/工具活动上协议);connection-owned 生命周期(一连接释放全部会话);
- 结论:可作第二个 agent 验证桥抽象,但达不到"与本地 chat 一致"体验目标。

## 3. codex(`codex-rs/Cargo.lock` + `codex app-server --help`)

无 ACP。三条接法:

| 接法 | 做法 | 体验 | 工作量 |
|---|---|---|---|
| A. app-server 私有协议 | 对接 daemon/控制 socket(`generate-ts`/`generate-json-schema` 可生成协议绑定) | 流式、会话完整 | 大 |
| B. exec + resume | `codex exec` 一次性 + `codex resume --last` 恢复 | 有连续性,流式/工具弱 | 小 |
| C. mcp-server | codex 暴露为 MCP 工具 | 工具调用模型,非 chat 流 | 小,不符合目标 |

## 4. 架构影响

```
AgentBackend 接口
├─ grok:            ACP over WebSocket(已实现)
├─ deepseek-harness: ACP over stdio(协议同一套,传输不同)
└─ codex:           私有协议 / exec+resume(需单独适配)
```

- 会话注册表扩展:`chatID → {agent, sessionId}`;
- Bilink 连接设置加"远程 agent"字段(默认 grok),协议与 UI 不变。

## 5. 建议

1. M2 先专注 grok 单 agent(Bilink 跑通产品体验);
2. 多 agent 接入顺序:deepseek-harness(同为 ACP,加 stdio 传输后端即可)→ codex(工作量大,先 exec+resume 验证再评估 app-server);
3. 多 agent 方向暂不写代码,仅在架构与 UI 预留接缝。
