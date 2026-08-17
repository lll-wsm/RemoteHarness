# 09 专业化优化方案(UI / 体验 / 功能)

> 2026-08-17,基于 M2.5 代码全量 review。目标:把 Bilink 从「原型可用」升级为「专业远程 agent 客户端」。
> 每项含:现状问题(附代码位置)-> 方案 -> 涉及文件。P0 建议先做,P1/P2 按迭代推进。

## 0. 现状小结

已具备:鉴权门、流式聊天、思考折叠、会话目录(切换/新建/删除)、本地历史持久化、断线自动重连(指数退避)、错误分类与横幅、排队状态。

核心短板(按影响排序):**无 WebSocket 心跳**(空闲断连)、**流式期间强制滚底**(用户无法回看)、**无 Markdown/代码块渲染**(coding agent 客户端的硬伤)、**无工具活动渲染**(grok 在干什么看不见)、**无发送失败重试**、单连接单会话、消息无时间戳/用量。

---

## P0 可靠性与基础体验(先做,1 个迭代)

### P0-1 WebSocket 心跳(桥 + 客户端都要)

**问题**:客户端(`ACPClient.swift`)与桥(`acp-server.js`)均无 ping/pong。iOS 会在连接空闲后挂起网络、cloudflared 对空闲连接有超时,表现为「放着不动就莫名重连」。`grep ping` 全仓无心跳逻辑。

**方案**:
- 客户端:`ACPClient` 加每 30s `task.sendPing`;连续 2 次失败视为断线触发 `onDisconnect`;
- 桥:`ws` server 对客户端连接同样定时 ping(`ws.ping()`,监听 pong 清除标记,超时 terminate);grok-client 对 grok 侧同理(Node ws 默认有心跳只在自己实现时生效,`ws` 库需手动)。
- 注意:ping 不算消息,不影响 JSON-RPC 分发。

**涉及**:`ACPClient.swift`、`bridge/src/acp-server.js`、`bridge/src/grok-client.js`。

### P0-2 智能自动滚动(停止强制钉底)

**问题**:`ChatView.swift:146-150` 流式期间每次 text 变化都 `scrollToLast`,用户上滑回看历史会被不断拉回底部——聊天 App 大忌。

**方案**:记录用户是否「钉在底部」:
- 监听 scroll geometry(或拖拽手势)判断用户离开底部(如距底 > 120pt 即视为离底);
- 离底时:不再自动滚动,并在底部悬浮一个「↓ 回到最新」按钮(带新消息提示点);
- 用户回到底部后恢复自动跟随。
- iPad 键盘弹出引起的 scroll 也应视为离底不拉扯。

**涉及**:`ChatView.swift`(MessageList 重构,可能新增 `ScrollViewState` 辅助)。

### P0-3 消息级发送状态与失败重试

**问题**:`ChatStore.send()` 失败只弹横幅,用户消息留在列表里但没有任何标记,无法重发;断线时 `isResponding` 挂起。(`ChatStore.swift:163-180`)

**方案**:
- `ChatMessage` 增加 `status: pending / sent / failed`(Codable,注意旧历史文件解码兼容,给默认值);
- 发送 -> `pending`;响应正常 -> `sent`;抛错 -> `failed`,气泡尾部显示红色感叹号,点击重试(重试复用同文本);
- 失败的轮次不参与 `finalizeTurn` 的保存逻辑混乱问题:failed 用户消息保留,下一条助手回复到达前先清掉残留流式状态。

**涉及**:`ChatMessage.swift`、`ChatStore.swift`、`MessageBubble.swift`。

### P0-4 输入栏换行能力

**问题**:`InputBar.swift:13-19` 用 `axis: .vertical` + `onSubmit`,回车即发送,iPad 外接键盘/软键盘都**无法输入换行**;长提示词(给 agent 下任务)必然多行,这是实际使用硬伤。

**方案**(二选一,推荐 a):
- a. 键盘上方工具条:`undo/重试 · 换行 · 发送`——「换行」按钮向 TextField 插入 `\n`(通过 FocusState + 手动拼接);回车行为改为「发送」保持不变;iPad 硬件键盘 `Cmd+Enter` 发送、`Option+Enter`/`Shift+Enter` 换行(`.keyboardShortcut`);
- b. 设置项「回车发送/回车换行」开关。

**涉及**:`InputBar.swift`、`ConnectView`(设置入口可后置)。

### P0-5 历史持久化防抖 + ChatMessage 加时间戳

**问题**:
- `saveLocalHistory()` 每轮全量 encode 全部消息写文件,千条消息会卡主线程(`ChatStore.swift:153-159`);
- `SessionStore.touch` 每次 `save()` 全量写 index.json(`SessionStore.swift:66`);
- `ChatMessage` 无 `createdAt`,回放/历史列表都无法显示时间。

**方案**:
- `ChatMessage` 加 `createdAt: Date`(默认 `Date()`,解码兼容);
- 写盘放到 `Task.detached(priority: .utility)` + 防抖(如 500ms 合并);或改为追加式 jsonl;
- `SessionStore.save` 同样防抖,`SessionMeta` 冗余 `lastMessageAt` 已有 `updatedAt`,够用。

**涉及**:`ChatMessage.swift`、`ChatStore.swift`、`SessionStore.swift`。

---

## P1 UI 专业化(第 2 个迭代)

### P1-1 Markdown 渲染 + 专业代码块(最高优先的 UI 项)

**问题**:助手消息是纯 `Text`(`MessageBubble.swift:16-21`)。grok 是 coding agent,回复大量 markdown(代码、列表、表格),现在全是原始符号。

**方案**:
- 引入 **MarkdownUI**(swift-markdown-ui,纯 SwiftUI、活跃维护)——「零第三方依赖」是 M2 起步原则,M3 阶段引入渲染库是合理的(自建 markdown + 代码高亮工作量远大于收益);
- 自定义代码块主题:等宽字体、语言标签(右上角)、一键复制、横向滚动、深浅色适配;
- 流式期间按现有方式整段重渲染(MarkdownUI 对增量文本性能可接受,必要时流式中降级为纯文本、`response_completed` 后切换渲染,这是常见做法);
- `textSelection(.enabled)` 保留。

**涉及**:`MessageBubble.swift` 重构、新增 `MarkdownContent.swift`;`project.yml` 加 SPM 依赖(XcodeGen)。

### P1-2 iPad 双栏布局(会话侧栏)

**问题**:会话列表是 sheet 弹窗(`ChatView.swift:41`),iPad 大屏浪费;`maxWidth: 720` 居中已是雏形。

**方案**:
- `NavigationSplitView`:侧栏 = 连接信息 + 会话列表(替代 sheet,直接切换);详情 = 聊天;
- iPhone 侧栏自动退化为 `NavigationStack` push(SplitView 自适应);
- 侧栏会话行支持右键菜单(iPad 触控板):重命名、删除、复制 chatID;
- `SessionMeta` 增加 `title` 可编辑(当前标题锁定为首条消息,`SessionStore.swift:48`),长按/右键「重命名」。

**涉及**:`ChatView.swift`、`SessionListView.swift`、`SessionStore.swift`(rename API)、`SessionMeta.swift`。

### P1-3 多连接管理(多台远程机器)

**问题**:只记住单个 URL(`UserDefaults` 两个 key,`ConnectView.swift:14-16`),token 按 URL 存 Keychain;换机器要手改。

**方案**:
- 引入 `ConnectionProfile` 模型(name/url/token/createdAt/lastUsedAt),存 Keychain(token)+ UserDefaults/文件(元数据);连接页变为「连接列表 + 新增/编辑」,点击即连;
- 连接页支持**剪贴板识别**:检测到 `ws://|wss://` 开头的剪贴板内容时提示一键填充(URL 与 token 可用 `|` 或换行分隔的约定格式,桥打印连接信息时可输出该格式);
- 每个连接独立的会话空间(`SessionStore` 已按 `connectionURL` 过滤,天然支持)。

**涉及**:`ConnectionConfig.swift` 扩展、新增 `ConnectionProfileStore.swift`、`ConnectView.swift` 重构、`KeychainService.swift`(枚举/删除)。

### P1-4 消息气泡与状态细节打磨

- 时间戳:气泡 hover/长按可见,或列表每 5 分钟插入时间分隔线(推荐后者,`createdAt` 就绪后做);
- 长按 context menu:复制全文、复制代码块(渲染后按块)、重发(failed 时)、回退到此(P2 联动);
- 头像/角色标识:助手侧小 logo(项目已有 logo 资产),用户侧 initials;
- 思考块增强:流式中显示计时(`思考中 12s`),完成后显示「已深度思考」摘要行(参考主流做法),展开动画;
- Haptics:发送成功/失败/轮次完成轻触反馈(`UIImpactFeedbackGenerator`);
- 错误横幅加「重试」按钮(发送类错误)而不只是关闭。

**涉及**:`MessageBubble.swift`、`ThoughtBlockView`、`ChatView.swift`、`ChatStore.swift`。

---

## P2 功能专业化(第 3 个迭代起,「agent 客户端」的差异化)

### P2-1 工具活动渲染(最重要的一项功能)

**问题**:grok 执行终端命令/文件工具时,客户端只能看到 thought 与最终 text,中间的工具调用完全不可见。ACP 标准有 `tool_call` / `tool_call_update` sessionUpdate(`agentCapabilities` 桥已声明,`acp-server.js:86`),桥侧透传已就绪,但 `ChatStore.handleOnMain` 没有处理,`ChatMessage` 也没有承载结构。

**方案**:
1. **先实测事件形状**:`e2e.mjs` 让 grok 执行一条会触发工具的指令(如「列出当前目录文件」),记录真实 `tool_call` 序列(名称、参数、输出字段命名),补充进 `docs/02-acp-protocol.md`;
2. 数据模型:`ChatMessage` 增加 `toolCalls: [ToolCall]`(`id/kind/title/input/output/status`,Codable);
3. UI:工具卡片(等宽字体显示命令与输出,折叠默认收起、流式中展开显示 spinner、完成显示 ✓/✗ 与耗时);插在 thought 与 text 之间按时间序渲染;
4. 回放历史同样处理(工具卡片参与本地持久化)。

**涉及**:`ChatMessage.swift`、`ChatStore.swift`(新增 case)、`MessageBubble.swift`(新增 `ToolCallCard`)、docs/02。

### P2-2 Plan Mode 确认卡片

桥已声明 `plan: true`;grok 的 plan.json 在会话侧。待实测 plan 模式下的事件流(`session/request_permission` 或 grok 自定义通知),UI 做确认卡片(Approve / Reject / 修改),这是「驾驶 agent」的关键交互。同 P2-1 一样先抓事件再定 UI。

### P2-3 Rewind(回退到某条消息)

`session/rewind` 桥已直接转发(`acp-server.js:13-18`)。UI:长按任意用户消息 ->「回退到此处」-> 确认后调 `session/rewind`,本地截断消息列表并保存。注意与本地历史一致性:rewind 成功后本地 `messages` 直接 `Array.prefix`,不依赖回放。

**涉及**:`ChatStore.swift`(rewind API)、`MessageBubble`(菜单项)。

### P2-4 用量与连接信息面板

- `response_completed` 带 usage(docs/02 已确认 `_meta.usage`),解析后在轮次结束处显示小字(token 用量);
- 连接面板(侧栏底部或设置):模型名(可让桥在 initialize 响应或新增 `bridge/info` 扩展方法里返回)、协议版本、RTT(定期 ping 耗时)、grokConnected 状态;
- 桥侧小改:`initialize` 响应里附加 `{ bridge: { version, model, grokConnected } }`(向后兼容,客户端可选展示)。

**涉及**:`acp-server.js`、`ACPClient.swift`、`ChatStore.swift`、`ConnectionStatusBar.swift`。

### P2-5 后台任务完成通知

**问题**:切后台后 iOS 挂起 WebSocket,长任务(跑几分钟的 agent 任务)结果错过,回来只剩重连。

**方案**(务实组合):
- 前台:已 OK;
- 短后台(<30s):`UIApplication.beginBackgroundTask` 续命接收完成事件;
- 更长:不可靠是 iOS 本质,接受「回来后重连 + 历史已本地保存」的现状,但在 `response_completed` 到达且 App 在后台时发 **本地通知**「远程任务已完成」(需后台任务存活才触发;配合上一条);
- 远期:桥侧支持推送(apns 代理)——列为远期,不承诺。

**涉及**:`ChatStore` + `ConnectionStore`(生命周期钩子)、Info.plist 权限。

### P2-6 URL Scheme 一键连接

`bilink://connect?url=...&token=...` + 连接页「从链接导入」。桥的 `start-all.sh` 打印连接信息时可同时输出该 scheme 链接(甚至终端二维码,`qrencode`),iPad 相机扫码即连,极大降低配置成本。

**涉及**:`BilinkApp.swift`(onOpenURL)、`ConnectView`、`start-all.sh`(可选输出)。

---

## P3 工程质量(伴随各迭代)

1. **单元测试(XCTest / swift-testing)**:`ChatStore` 事件组装(chunk 合并、回放窗口、错误翻译)、`SessionStore`、`AnyCodable`、prompt 归一化——这些是纯逻辑,可直接测;`ACPClient` 用协议抽象 + mock WebSocket 测请求配对/断线清理。CLI harness(`test/acp-client-test`)保留做集成回归,**新增 Swift 文件记得同步 swiftc 文件列表**(CLAUDE.md 已记录)。
2. **桥侧测试**:vitest:`session-manager` 持久化、`acp-server` 的 prompt 归一/路由/mock grok 连接;`npm test` 脚本。
3. **SettingsView**(docs/07 规划过未实现):主题、回车行为(P0-4)、清除全部会话数据、关于/版本。
4. **i18n 预留**:文案集中到 `L10n`(暂不拆多语言,发布前再做 zh-Hans/en);错误文案目前散在 `ACPError`/`ChatStore`,可统一。
5. **iCloud 同步会话目录**(远期):目前 Application Support 不随备份走(`FileManager` 默认不排除,实际会进备份,但换设备不迁移);发布前评估。

---

## 落地顺序建议

| 迭代 | 内容 | 价值 |
|---|---|---|
| 迭代 1(P0) | 心跳、智能滚动、失败重试、换行、持久化防抖+时间戳 | 消灭「用着难受」的可靠性/输入硬伤 |
| 迭代 2(P1) | Markdown/代码块、iPad 双栏、多连接、气泡打磨 | UI 达到「专业 App」观感 |
| 迭代 3(P2 前半) | 工具活动渲染 + 实测补协议文档、用量显示 | agent 客户端核心差异化 |
| 迭代 4(P2 后半) | Plan Mode、Rewind、后台通知、URL Scheme | 驾驶体验完整 |
| 持续(P3) | 单测、桥测试、设置页、i18n | 可维护性 |

风险提示:P2-1/P2-2 依赖 grok 真实事件形状,文档当前未覆盖 tool_call 细节,**动手前先用 e2e 抓包**;MarkdownUI 引入后注意流式重渲染性能,准备降级路径。
