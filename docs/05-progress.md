# 05 进度与下一步

> 记录当前完成进度、遗留事项与后续计划。最后更新:2026-08-16。

## 1. 已完成

### 决策与设计
- [x] 协议定稿:路线 A(ACP 端到端),不做路线 B;
- [x] 桥形态:厚桥(Node.js daemon,跑在远程 Mac/Linux);
- [x] grok 驱动方式:`grok agent serve`(ACP),非 headless;
- [x] 会话语义:一个 remote chat = 一个持续 grok 会话(chatID 稳定标识);
- [x] 客户端定位:MoCi(LLMProvider 抽象为接缝);
- [x] 无 xAI 登录:grok 走第三方 OpenAI 兼容端点(env_key 配置,`-m` 选模型)——已实测。

### 桥(RemoteHarness/bridge)
- [x] M1 ACP 端到端:**已实测通过**(真实 grok + opencode-deepseek 模型,流式回复逐字到达);
- [x] ACP 协议校准:字段 camelCase、initialize 握手、session/new 参数、prompt ContentBlock 形状、事件路由(见 02-acp-protocol.md);
- [x] 安全加固:失败关闭、强 token、常数时间比较、限流、审计、healthz 加锁、IP 白名单(防伪造头)、可选 auth-proxy;
- [x] 会话注册表:chatID → grok 会话,sessions.json 持久化;
- [x] 一键启动/停止:`scripts/start.sh`;
- [x] 公网验证:cloudflared quick tunnel 端到端(healthz / wss initialize / 401 拒绝)。

### 工具与文档
- [x] git 仓库初始化;
- [x] docs/ 文档(本目录);
- [x] 测试脚本:smoke.mjs / e2e.mjs / gen-token.mjs。

## 2. 遗留事项(技术债/待确认)

- [ ] **grok 工具层验证**:目前验证了文本对话流式;工具调用(查文件、跑命令)在第三方模型(DeepSeek/GLM)上的函数调用格式是否被 grok 正确序列化,**尚未完整验证**(e2e 中 MCP codegraph 初始化正常,可作为部分依据);
- [ ] **Plan Mode / Rewind 透传**:协议层面支持(agentCapabilities 已声明),未实测;
- [ ] **会话恢复实测**:`session/load { chatID }` 跨桥重启恢复未端到端验证;
- [ ] **限流/白名单经真实 cloudflared 的端到端**:本地模拟已验证,真实隧道下按 CF-Connecting-IP 生效需在公网实测;
- [ ] 邮箱 OTP 入口验证(Cloudflare Access):被「无域名/无外卡」卡住;备选 Tailscale / auth-proxy。

## 3. 下一步(M2 起)

### M2:MoCi ACP 客户端(下一个里程碑)
1. MoCi 实现 ACP 客户端(`URLSessionWebSocketTask`),含:
   - **鉴权门**:连接设置页(URL + token)→ initialize 握手 → 成功才进入聊天,失败留在连接页显示具体错误(401=token 错 / 超时=地址不可达);
   - **流式渲染**:把 `session/update` 事件(user_message_chunk / agent_thought_chunk / agent_message_chunk)映射到 ChatStore / MessageBubble;
   - **会话管理**:记住 chatID,断线重连后 `session/load` 恢复;重连重新鉴权;
   - **证书校验**:正常校验证书,不提供"跳过证书校验"开关;
   - token 存 Keychain;
2. 局域网先跑通,再测公网(隧道);
3. 渲染工具活动(`_x.ai/queue/changed`、`_x.ai/mcp/*`、tool_call 事件)。

### M3:会话与工具增强
- chatID 持久会话 UI(会话列表/恢复);
- 工具活动/终端输出渲染;
- token 配置 UI;
- 隧道连接预设(局域网 IP / Tailscale / cloudflared URL)。

### M4:并入决策
- 验证 OK 后,把客户端并入 MoCi(或按评估继续独立)。

## 4. 常用启动流程(备忘)

```sh
# 1) grok agent serve(第三方模型,无需 xAI 登录)
grok -m opencode-deepseek-v4-flash agent serve --bind 127.0.0.1:2419 --secret <SECRET> &

# 2) 桥 + 隧道(一键)
cd RemoteHarness/bridge
export BRIDGE_TOKEN=$(npm run -s gen-token)
export GROK_SERVE_SECRET=<SECRET>
./scripts/start.sh          # Ctrl+C 停止

# 3) 测试
BRIDGE_TOKEN=$BRIDGE_TOKEN node scripts/e2e.mjs ws://127.0.0.1:8777 "你好"
BRIDGE_TOKEN=$BRIDGE_TOKEN node scripts/e2e.mjs wss://<公网URL> "你好"
```
