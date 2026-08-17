# 05 进度与下一步

> 记录当前完成进度、遗留事项与后续计划。最后更新:2026-08-17。

## 1. 已完成

### 决策与设计
- [x] 协议定稿:路线 A(ACP 端到端),不做路线 B;
- [x] 桥形态:厚桥(Node.js daemon,跑在远程 Mac/Linux);
- [x] grok 驱动方式:`grok agent serve`(ACP),非 headless;
- [x] 会话语义:一个 remote chat = 一个持续 grok 会话(chatID 稳定标识);
- [x] 客户端定位:Bilink(比邻,独立 iPad App;不并入 MoCi,MoCi 已在用);
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
- [ ] **会话恢复后远程上下文校验**:本地历史 + session/load 双通道已验证;桥重启导致注册表丢失时,客户端保留本地历史并提示新建(已实现),远程上下文随之丢失属预期;
- [ ] **限流/白名单经真实 cloudflared 的端到端**:本地模拟已验证,真实隧道下按 CF-Connecting-IP 生效需在公网实测;
- [ ] 邮箱 OTP 入口验证(Cloudflare Access):被「无域名/无外卡」卡住;备选 Tailscale / auth-proxy;
- [ ] 第三方 API 计费影响:DeepSeek 直连 / opencode 网关余额不足时返回 402,客户端会显示"API 额度不足"错误横幅;GLM Ark(glm-5-2)当前可用。**注意:`grok agent serve` 的模型由 `~/.grok/config.toml` 的 `[models].default` 决定,`-m` 参数不生效**(原配置已备份 config.toml.bak,default 现为 glm-5-2)。

## 3. 下一步(M2 起)

### M2:Bilink(比邻)独立 iPad App(下一个里程碑)
- [x] **M2.1 骨架 + 鉴权门(2026-08-17)**:Xcode 工程(xcodegen/project.yml,Universal,iOS 17+)、ConnectView(URL+token+agent)、ConnectionStore 状态机(idle/connecting/connected/failed)、ACPClient(URLSessionWebSocketTask + Bearer 鉴权 + initialize 握手 + healthz 前置探测分类错误);实测:正确 token 握手成功、错 token=401、端口关闭=不可达、不可路由=超时;模拟器安装启动无崩溃;
- [x] **M2.2 聊天(2026-08-17)**:ChatStore(session/new → chatID、session/prompt 发送、session/cancel 停止、流式事件组装:user_message_chunk 忽略回显 / agent_thought_chunk→思考 / agent_message_chunk→文本 / turn_completed→收尾、_x.ai/queue/changed→排队状态);UI:消息气泡(用户右/助手左)、流式光标、思考折叠块、多行输入栏(发送/停止)、自动滚动;**实测(CLI 驱动真 ChatStore + 真 grok)**:建会话 → 发消息 → 助手回复"OK"+ 思考块,链路通过;
- [x] **M2.3 会话持久与断线重连(2026-08-17)**:chatID 按连接 URL 持久化 UserDefaults,重进/重连后 `session/load {chatID}` 恢复(实测:两次运行加载同一 chatID,对话延续);断线自动重连(指数退避 1s→30s,重连后重新握手 + 会话恢复),状态条显示"重连中"(橙点);连接页记忆上次 URL/名称;**实测**:CLI 两次运行同 chatID 恢复通过;重连运行时行为待实体机验证(断隧道→重连中→恢复);
- [x] **M2.4 打磨(2026-08-17)**:token 存 Keychain(按连接 URL 分键,首次解锁后可用、不同步 iCloud;连接页切换地址自动带出已存 token);错误态:session/send 前置清理、聊天页错误横幅可关闭;iPad 宽屏布局:聊天列与输入栏最大宽度 720pt 居中;
- [x] **M2.5 会话管理(2026-08-17)**:多历史会话目录(SessionStore,index.json 持久化标题/摘要/时间/条数)+ 历史会话列表 UI(切换/新建/滑动删除);ChatStore 重构:恢复最近会话(目录优先,UserDefaults 兼容旧版)、切换/新建会话、**session/load 失败保留本地历史并提示(不静默新建)**;本地消息记录持久化 BilinkSessions/<chatID>.json;桥转发通知注入 chatID,**切换会话防跨会话串流**;API 错误透传(`_x.ai/session_notification` retry_state → 错误横幅,如"API 额度不足");**实测(真 grok,GLM 模型)**:清空状态两次运行——首次新建会话+流式回复、第二次重开恢复**同一 chatID 未新建**、本地历史(👤+🤖)完整还原并继续对话累积、目录索引跨进程持久;
- [ ] **M3(候选)**:工具活动渲染、隧道预设;

### 聊天 UI 优化 M1(Markdown 渲染,2026-08-17,方案见 docs/11)
- [x] **依赖接入**:SwiftUIChatMarkdown(自研,github.com/lll-wsm)进 project.yml(xcodegen 正路),部署目标 iOS **17→18**(包最低要求);GUI 添加实测进不了依赖图(解析成功但 `Target dependency graph` 只有 app,`import` 报 Unable to find module dependency),必须写 project.yml;已验证:xcodegen 重生成后依赖图 17 targets、静态链接、构建通过;
- [x] **MessageBubble 重构**:助手消息 `ChatMarkdownRenderer`(`.assistant`/`.compact`/`.default`,`isComplete: !isStreaming` 流式降级);用户消息保持纯文本(accent 背景上块级元素视觉冲突);**▌光标移出文本**改为渲染器下方独立光标(避免破坏 Markdown 解析);长按气泡「复制全文」菜单(代码块复制按钮待包 PR);
- [x] **headless 解析断言**(链接构建产物模块直接测试):标题/引用/代码/表格/列表块全部识别;流式不完整代码围栏(isComplete=false)安全降级为 code 块;流式纯文本正常 prose;空文本 0 块;
- [x] **模拟器冒烟**:App 安装启动无崩溃、进程存活;渲染 harness(复刻气泡结构)截图像素分析:检出蓝(user 气泡)+ 淡灰/内容区,配色预期;
- [ ] **后续**:M2 智能滚动、M3 失败重试+时间戳/思考块修正、M4 锁 revision+收尾(见 docs/11 阶段 2-5);代码块复制按钮走 SwiftUIChatMarkdown 包 PR。

### M3.1 多连接多会话(2026-08-17,已实现)
- [x] **桥扩展**:`sessions/list`(只读注册表,过滤不可恢复孤儿)+ `sessions/remove`(尽力关闭 grok 会话,失败不阻塞)+ `handleSessionNew` 失败回滚(不再产生 grokSessionId=null 孤儿);
- [x] **多连接 Profile**:`ConnectionProfile`/`ProfileStore`(profiles.json,token 存 Keychain 键 `bilink.token.profile.<id>`),`SessionMeta` 归属键由 URL 改为 **profileID**,新增 `isRemoteOnly`;`SessionStore` 支持 rename/removeProfile 级联/mergeRemote 跨 profile 按 chatID 去重;
- [x] **三级恢复**:重开优先本地最近会话 → 无则桥上远端发现(sessions/list 合并,isRemoteOnly 条目打开走 grok 回放,首条消息后翻转并补全标题)→ 无则新建;**重装 App 后自动接回桥上原会话,不再盲目新建**;
- [x] **会话管理入口**:deleteSession(在线:桥+本地同步删,当前会话删后自动新建)、renameSession、syncRemoteSessions(会话列表打开时同步);switchTo 前先 session/cancel 旧会话在途 turn;
- [x] **UI**:机器列表主页(增删改连、滑动编辑/删除级联确认、连接失败横幅)、ProfileEditView(token 只写不读)、会话列表两段(本地/桥上发现)+ 搜索 + 重命名 + 滑动删除;
- [x] **实测(CLI,真 grok)**:首次新建 / 重开恢复同一会话+历史 / 重装远端发现恢复(chcatID 与桥一致)/ 第二 profile 隔离 / 在线删除桥+本地同步清理,全部通过;xcodebuild 通过。

### M3:会话与工具增强
- chatID 持久会话 UI(会话列表/恢复);
- 工具活动/终端输出渲染;
- token 配置 UI;
- 隧道连接预设(局域网 IP / Tailscale / cloudflared URL)。

### M4:发布与迭代决策
- 验证 OK 后进入正式发布准备(TestFlight / App Store);视评估决定是否提供 Mac 客户端等延伸。

## 4. 启动与测试

完整启动流程、验证点、自动化测试命令与常见问题,见 **docs/08-startup.md**。要点:

```sh
# 1) grok agent serve(第三方模型,无需 xAI 登录;余额可用时选 glm-5-2)
grok -m glm-5-2 agent serve --bind 127.0.0.1:2419 --secret <SECRET> &

# 2) 桥 + 隧道(一键)
cd RemoteHarness/bridge
BRIDGE_TOKEN=$(npm run -s gen-token) GROK_SERVE_SECRET=<SECRET> ./scripts/start.sh

# 3) 测试(详见 08):e2e.mjs / swiftc CLI 双跑回归(重开恢复同一会话)
BRIDGE_TOKEN=$BRIDGE_TOKEN node scripts/e2e.mjs ws://127.0.0.1:8777 "你好"
```
