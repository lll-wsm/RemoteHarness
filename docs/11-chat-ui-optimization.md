# 11 聊天 UI 优化实施方案

> 2026-08-17。本文是 docs/09「P0-2 智能滚动 / P0-3 失败重试 / P0-4 输入换行 / P0-5 时间戳 + P1-1 Markdown 渲染」的**细化执行方案**。
> 与 09 的一个差异:**Markdown 渲染库由 MarkdownUI 改为 SwiftUIChatMarkdown**(github.com/lll-wsm,自研),依赖可用性已验证(见阶段 0)。
> 阶段 0-1 为本次迭代核心;阶段 2-5 按顺序推进,每阶段可独立交付。
> 范围注:docs/09 的 P0-1(WebSocket 心跳)不在本文,桥+客户端改动与本迭代零冲突,**另行排期并行推进,勿遗漏**。
> 二审修订(同日):ChatMessage 解码兼容改为自定义 init(from:)(合成 Codable 不认属性默认值,直接加字段会丢旧历史);status 流转改乐观更新;重试先移除失败条目防重复;§3.4 缓存方案重排;锁 revision 提前至 M4。

## 0. 背景与目标

当前聊天 UI 状态(已具备):左右气泡布局、思考过程折叠、流式 ▌光标、自动滚底、空态页、错误横幅、720pt 居中限宽。

核心短板(本文解决):

| # | 问题 | 位置 |
|---|------|------|
| 1 | 助手消息纯 `Text` 显示,Markdown/代码/表格全是原始符号 | `MessageBubble.swift:16-21` |
| 2 | 流式期间强制滚底,用户上滑回看会被拉回 | `ChatView.swift` MessageList `scrollToLast` |
| 3 | 回车即发送,无法输入换行(长任务提示词必多行) | `InputBar.swift:13-19` |
| 4 | 发送失败只有顶部横幅,消息无状态、无重试入口 | `ChatStore.swift` `send()` |
| 5 | 消息无时间戳;思考块折叠标签只看 `isExpanded`,完成态仍显示「思考中…」 | `MessageBubble.swift:45-48` |

目标:一次迭代(阶段 0-5 全部落地)后,聊天页达到「专业 agent 客户端」观感与可用性。

---

## 1. 总体方案

| 阶段 | 内容 | 依赖前置 |
|---|---|---|
| 0 | 依赖接入 + iOS 18 部署目标(**已验证**) | 无 |
| 1 | Markdown 渲染(核心,含代码块复制、流式、性能缓存) | 阶段 0 |
| 2 | 智能滚动(离底暂停跟随 + 「回到最新」按钮) | iOS 18 API |
| 3 | 输入栏换行(键盘工具条 + 硬件键盘快捷键) | 无 |
| 4 | 消息状态 pending/sent/failed + 失败重试 + 发送防抖 | 阶段 1(重试按钮在气泡菜单) |
| 5 | 时间戳/日期分隔、思考块状态修正 | 无 |

P2 项(工具活动卡片、用量显示、iPad 双栏)不在此次迭代,见 docs/09。

---

## 2. 阶段 0:依赖接入(已完成验证)

### 2.1 现状结论

- 依赖要求 **iOS 18.0+**(`Package.swift` platforms),Bilink 当前部署目标 **17.0**,必须升级。
- Xcode GUI 添加不可靠:工程是 xcodegen 生成的;实测 GUI 添加后 Xcode 26 把工程升级到 objectVersion 77,包解析成功但**进不了依赖图**(`Target dependency graph (1 target)`),`import` 报 `Unable to find module dependency`,且下次 `xcodegen generate` 会冲掉 GUI 添加。**结论:必须写进 `project.yml`,由 xcodegen 生成。**
- 已验证(xcodegen 重生成后):依赖图 17 targets,`import SwiftUIChatMarkdown` 编译通过、静态链接进 App,`BUILD SUCCEEDED`。

### 2.2 变更清单

`Bilink/project.yml`(已改,未提交):

```yaml
options:
  deploymentTarget:
    iOS: "18.0"          # 17.0 → 18.0(包的最低要求)
packages:
  SwiftUIChatMarkdown:
    url: https://github.com/lll-wsm/SwiftUIChatMarkdown
    branch: main
targets:
  Bilink:
    dependencies:
      - package: SwiftUIChatMarkdown
```

### 2.3 版本锁定(发布前必做)

当前引用 `branch: main`,Package.resolved 位于 gitignored 的 `Bilink.xcodeproj/` 内,**不会随仓库提交**,其他人 clone 后解析的是 main 最新,可能漂移。**本迭代收尾(M4)即改为锁 revision**(包仓库仍在快速变动,main 每次 push 都可能改变行为,不宜拖到发布前):

```yaml
packages:
  SwiftUIChatMarkdown:
    url: https://github.com/lll-wsm/SwiftUIChatMarkdown
    revision: 0d5fc4a   # 当前验证过的提交;包升级时手动更新
```

### 2.4 验收标准

- `xcodegen generate && xcodebuild build`(模拟器)通过;
- 真机 arm64 构建通过;
- 不需要 `import` 时构建也通过(依赖静默链接,无副作用)。

---

## 3. 阶段 1:Markdown 渲染(核心)

### 3.1 集成边界(重要决策)

**只用 `ChatMarkdownRenderer` 一个视图**。**不用**该包的 `ChatSessionEngine` / `ChatSessionView` / `SQLiteChatMessageCache`——那会替换掉我们基于 ACP 的 ChatStore、会话管理、本地持久化架构,是倒退。

包内各组件用途判定:

| 组件 | 用 | 原因 |
|---|---|---|
| `ChatMarkdownRenderer` | ✅ | 独立可嵌的 Markdown 块渲染视图,流式感知(`isComplete`) |
| `ChatMarkdownRenderSnapshot` | ✅ | 渲染快照,配合缓存(3.4) |
| `SDKMarkdownTheme` | ✅ | 主题定制(3.6) |
| `ChatStreamingRevealState` / `step()` | ❌ | 打字机渐显效果,与现有 ▌光标重复,暂不引入 |
| `ChatSessionEngine` / `ChatSessionView` | ❌ | 整套会话架构 |
| `SQLiteChatMessageCache` | ❌ | 我们已有自己的持久化 |

### 3.2 MessageBubble 改造

`MessageBubble.swift` 中 `Text(displayText)` 分支:

- **助手消息**:`ChatMarkdownRenderer(text: message.text, context: .assistant, variant: .compact, theme: theme, isComplete: !message.isStreaming)`
- **用户消息**:保持纯 `Text`(决策点,见 3.7-①)。背景为 accent 主色 + 白字,Markdown 块级元素(代码块、引用块、表格)在彩色背景上视觉冲突大,且用户消息通常为短文本;`textSelection(.enabled)` 保留。
- 气泡容器不变:padding 10 + 圆角背景。注意 renderer 内部块级元素自带背景(代码块/表格有独立圆角卡片),嵌套在气泡内为「卡片中卡片」,视觉可接受;验收时重点看。
- 思考块 `ThoughtBlockView` 不动(可选增强见阶段 5)。

### 3.3 流式与光标

- 渲染器传 `isComplete: !message.isStreaming`:包的分块器对未完成代码围栏/列表做降级渲染(不完整围栏按代码块显示),流式安全。
- **▌光标从 `displayText` 移除**(塞进文本会破坏 Markdown 解析,如代码围栏内)。改为:流式时在 renderer 下方追加一个独立 `Text("▌")`(与气泡文字对齐,`.foregroundStyle(.secondary)`)。
- 流式期间每条 chunk 触发 renderer 重建(见 3.4 缓存与降级路径)。

### 3.4 性能:snapshot 缓存(关键)

`ChatMarkdownRenderSnapshot(text:isComplete:)` 每次 init **全量解析**。MessageList 的 `ForEach` 在每次 store 变更时重建全部气泡,若每气泡都重新解析,流式时 O(消息数 × 文本长度) 的重复工作会卡 UI。

**方案 A(首选:无缓存直建,依赖 SwiftUI 值相等跳过)**:`ChatMessage` 是 `Equatable`,ForEach 重建的只是 struct 值,SwiftUI 对值相等的子视图会**跳过 body 重算**--流式时只有正在变化的那条气泡 body 会重新执行。因此第一步直接在 body 里构造 snapshot,不做任何缓存:

```swift
var body: some View {
    let snapshot = ChatMarkdownRenderSnapshot(text: message.text,
                                              isComplete: !message.isStreaming)
    ChatMarkdownRenderer(snapshot: snapshot, context: .assistant,
                         variant: .compact, theme: theme)
}
```

- 先用 `Time Profiler` 实测流式长文本,**不达标再升级**;不要一上来就加缓存--在 body 求值中给 `@State` 赋值是 "Modifying state during view update" 反模式,必须避开;
- **方案 A+(缓存,仅在 A 实测不达标时)**:MessageBubble 持 `@State private var snapshot: ChatMarkdownRenderSnapshot?`,写入只放在 `.onChange(of: message)` / `.task`,body 只读;
- **方案 B(降级路径)**:流式中(最后一条且 `isStreaming`)降级为纯 `Text` + 光标,`response_completed` 后切回渲染器--这是聊天 App 常见做法,代价是流式期间看不到 Markdown 排版;
- 方案 C:包内对同一 text 前缀复用解析结果(需改包,先不做)。

### 3.5 代码块复制按钮(包缺口)

`ChatCodeBlockView` 有语法高亮、语言标签、横向滚动,**但没有复制按钮**(README 声称有一键复制,实际代码里没有)。

方案(包是自研仓库,优先改包):

1. 在 SwiftUIChatMarkdown 加 PR:代码块右上角「复制」按钮(`ChatCodeBlockView` 内,`UIPasteboard`/`NSPasteboard`),并暴露 `onCopyCode: ((String) -> Void)?` 回调让宿主感知(可加复制 toast);
2. 包未发布前,Bilink 先做**气泡级过渡**:长按 context menu「复制全文」(阶段 5 的菜单项提前到本阶段)。

### 3.6 主题与视觉

- `SDKMarkdownTheme` 用 `.default` 基础上微调:气泡内字体 `theme.font = .body` 默认即可;`codeBackgroundColor` 默认 `secondarySystemBackground`,与现有助手气泡底色一致;
- 链接色:`.assistant` 上下文默认 `accentColor`,无需改;
- 深浅色:包的主题色均为 dynamic color,自适应,无需处理。

### 3.7 边界情况与决策点

- ① **用户消息是否渲染**:本阶段不渲染(理由见 3.2)。可选扩展:检测文本含 ``` 时也渲染(代码粘贴场景)。
- ② **空文本/纯空白**:renderer 对空串解析为空 VStack,无崩溃;`displayText` 逻辑中的空串保护保留。
- ③ **Mermaid 代码块**:包在 `isComplete` 时用 WebView 渲染图表(`MermaidDiagramView`),流式中按代码块显示;接受,不需要额外处理。
- ④ **数学公式**:SwiftMath 渲染失败时包已降级为原文显示,无需处理。
- ⑤ **历史回放消息**:`isStreaming == false` → `isComplete: true`,完整渲染;回放窗口逻辑不变。
- ⑥ **超长内容**:代码块、表格、公式均由包内 `ScrollView(.horizontal)` 兜底,气泡宽度受 720pt 限制。

### 3.8 涉及文件

- `Bilink/Bilink/Views/MessageBubble.swift`(重构:renderer + 缓存 + 光标)
- 新增 `Bilink/Bilink/Views/MarkdownTheme.swift`(主题常量,可选,或内联)
- `project.yml`(阶段 0,已完成)
- `CLAUDE.md`(收尾时更新依赖说明)

### 3.9 验收标准

- 助手消息渲染:标题、列表、引用、表格、代码块(高亮+语言标签)正确;
- 流式:不完整代码围栏不闪乱,▌光标在文本末尾跟随;
- 代码块复制按钮可用(包 PR 或气泡菜单过渡);
- 长历史会话打开不卡顿(仪器验证 3.4 方案 A 有效);
- 深浅色模式视觉正常;历史回放渲染一致。

---

## 4. 阶段 2:智能滚动

### 4.1 现状

`ChatView.swift` MessageList:`onChange(of: messages.count / last?.text)` 无条件 `scrollToLast`,用户上滑回看历史会被不断拉回底部。

### 4.2 方案(iOS 18 原生 API)

部署目标已升 18,用 `ScrollView` 的 `.onScrollGeometryChange`(iOS 18+)替代手写 PreferenceKey:

- 维护 `@State isPinned: Bool`(距底 ≤ 120pt 视为钉底,**初始 `true`** 即默认跟随)、`@State hasNewBelow: Bool`;
- `scrollToLast` 仅当 `isPinned` 时执行;流式期间新 chunk 到达且离底时,置 `hasNewBelow = true`;
- 离底时底部悬浮「↓ 回到最新」按钮(`Material` 圆角胶囊,带红点提示);点击后 `scrollToLast` 并复位 `isPinned`;
- 键盘弹出引起的内容偏移视为离底但不提示「回到最新」(仅恢复跟随,不打断)。

### 4.3 涉及文件

- `ChatView.swift`(MessageList 重构,新增 `@State`;悬浮按钮 overlay)

### 4.4 验收标准

- 流式中上滑到历史,消息继续流式但不跳动;底部出现「回到最新」;
- 点「回到最新」立即回底并恢复跟随;
- 回底后新 chunk 正常滚动(无抖动);键盘弹收不影响体验。

---

## 5. 阶段 3:输入栏换行

### 5.1 方案(采用 docs/09 P0-4 方案 a)

回车保持「发送」(聊天 App 习惯),补充两条换行途径:

1. **键盘上方工具条**(`InputBar` 内,TextField 上方):「换行」按钮(插入 `\n`)+ 发送/停止按钮上移;
2. **硬件键盘快捷键**(iPad 外接键盘,`InputBar` 挂 `.keyboardShortcut`):`Cmd+Enter` = 发送、`Shift+Enter` / `Option+Enter` = 换行;软键盘回车仍为发送。

插入换行实现:TextField 绑定 + `FocusState`,用 `text.insert("\n", at: text.endIndex)` 保持光标在尾部(当前实现输入即发送后清空,无复杂光标场景)。

### 5.2 涉及文件

- `Bilink/Bilink/Views/InputBar.swift`

### 5.3 验收标准

- 软键盘:回车发送;工具条「换行」可插入空行,多行文本原样发送;
- iPad 硬件键盘:`Cmd+Enter` 发送、`Shift+Enter` 换行;
- 5 行后 TextField 高度封顶可滚动(现有 `lineLimit(1...5)` 保留)。

---

## 6. 阶段 4:消息状态与失败重试

### 6.1 现状

`ChatStore.send()` 失败只弹横幅,用户消息留在列表无标记,无重发入口。

### 6.2 方案

- `ChatMessage` 增加 `status: MessageStatus`(`enum MessageStatus: String, Codable { case sending, sent, failed }`),`createdAt: Date`(阶段 5)一并加;
- **解码兼容(硬性要求)**:Swift 合成 Codable **不会**使用属性默认值--直接加带默认值的属性,旧历史文件(缺 status/createdAt key)会解码整体失败,`loadLocalHistory()` 的 `try?` 返回 nil -> 历史被判空,**所有旧会话打开变空白**。必须手写 `init(from decoder:)`,用 `decodeIfPresent(...) ?? 默认值`(status 默认 `.sent`、createdAt 默认 `Date()`);
- 状态流转(乐观更新):发起到请求写出为 `.sending`(瞬时态)-> 请求已写出且无立即错误即 `.sent`;**只有 RPC 抛错才 `.failed`**。注意 ACP 的 `session/prompt` 响应在**整轮结束**才返回,不能把整轮完成当 `.sent` 时机,否则用户气泡会挂「发送中」数分钟;
- 气泡 UI:`.failed` 时消息尾部红感叹号 + 点击/长按「重试」;**重试必须先移除 failed 条目再以原文本重发**(直接调 `send()` 会 append 新消息,列表出现两条重复)——提供 `retry(messageID:)`:定位 -> 移除 -> 复用原文本重走发送;
- `failed` 的轮次不进入 `finalizeTurn` 的保存混乱:失败用户消息保留,清理残留流式状态(与现有 `stop()` 清理逻辑一致);
- 发送防抖(低优先级):现有 `onSend` 同步清空输入、`canSend` 立即 false,双击本身已难触发;800ms 禁用可加但非必需。

### 6.3 涉及文件

- `Bilink/Bilink/Models/ChatMessage.swift`(status 字段)
- `Bilink/Bilink/Stores/ChatStore.swift`(状态流转、重试 API)
- `Bilink/Bilink/Views/MessageBubble.swift`(状态指示 + 重试菜单)
- `Bilink/Bilink/Views/InputBar.swift`(防抖)

### 6.4 验收标准

- 断网发送:消息出现失败标记,横幅提示;点重试后成功;
- 旧历史文件(无 status/createdAt 字段)解码正常(自定义 `init(from:)` 生效,历史不丢);
- 用户消息不因长回复长时间显示「发送中」(.sent 为乐观更新);
- 连点发送只产生一条消息。

---

## 7. 阶段 5:时间戳 / 日期分隔 / 思考块修正

### 7.1 内容

- `ChatMessage` 增加 `createdAt: Date`(解码兜底在 §6.2 的自定义 `init(from:)` 中一并处理);消息气泡下小字时间(仅显示时分,同会话内可每条显示,复用 docs/09 建议);
- 思考块修正(小 bug):折叠标签现在只看 `isExpanded`(`MessageBubble.swift:45-48`),思考**完成**后折叠仍显示「思考中…(点开查看)」。改为区分状态:流式中「思考中…」、完成后「思考过程(点开查看)」;顺带在标题显示思考耗时(`response_completed` 或首次 chunk 到完成的时间差,本地计时即可);
- (可选)长按菜单:复制全文 / 重试(failed 时)——阶段 1 若已做「复制全文」过渡则此处合并。

### 7.2 涉及文件

- `ChatMessage.swift`、`MessageBubble.swift`(ThoughtBlockView 状态 + 耗时)
- `ChatStore.swift`(计时起点)

### 7.3 验收标准

- 历史会话每条消息显示时间;
- 思考完成的折叠标签正确显示「思考过程」,且带耗时;
- 流式中思考标签为「思考中…」。

---

## 8. 验证方案

| 项 | 方式 |
|---|---|
| 构建 | `xcodegen generate` + 模拟器/真机 arm64 `xcodebuild` |
| 功能 | 模拟器真机手动:流式 Markdown(代码/表格/列表/引用)、复制、智能滚动、重试、换行、思考块状态 |
| 回归 | 历史回放、会话切换/新建/删除、断线重连、加密通道、错误横幅、空态 |
| 性能 | 流式长文本:`Time Profiler` 确认 snapshot 解析开销;方案 A 不达标则启用 3.4 降级路径 |
| 兼容 | 旧历史文件(无 status/createdAt 字段)解码;深浅色;iPhone + iPad 尺寸 |

桥侧无改动,CLI harness 不需要扩展(纯 UI 迭代)。

---

## 9. 风险与权衡

| 风险 | 影响 | 对策 |
|---|---|---|
| iOS 18 门槛 | 设备需 iOS 18+(docs/07 原定 17,升级是显式产品决策) | 确认常用设备均 ≥ 18;真机验证 |
| 依赖体积/构建时间 | SwiftMath/mermaid/swift-markdown 三个传递依赖,首构建 +30s 左右 | 接受;发布时砍掉用不到的 math/mermaid?包不支持按需裁剪,维持现状 |
| main 分支漂移 | 依赖内容不可控 | M4 收尾锁 revision(2.3) |
| 流式重解析性能 | 长文本流式卡顿 | 3.4 缓存 + 降级路径 |
| 包内视觉(卡片中卡片) | 气泡内嵌块级卡片观感 | 验收时以实际效果为准,必要时调气泡 padding/背景 |
| 复制按钮缺失 | 包缺口 | 3.5:改包 PR,过渡期气泡菜单 |

---

## 10. 落地顺序与里程碑

| 里程碑 | 内容 | 完成标准 |
|---|---|---|
| M1 | 阶段 0-1 | Markdown 渲染上线(含缓存/复制/光标),构建+模拟器验收 |
| M2 | 阶段 2-3 | 智能滚动 + 换行 |
| M3 | 阶段 4-5 | 重试/防抖 + 时间戳/思考块 |
| M4 | 收尾 | 锁 revision、docs/05 进度更新、CLAUDE.md、提交 |

## 11. 收尾事项

- `docs/05-progress.md` 补 M1-M3 条目;
- `CLAUDE.md`:依赖说明(SPM 包 + iOS 18)、swiftc 文件列表如有新增文件需同步;
- 阶段 3.5 包 PR 单独跟进(SwiftUIChatMarkdown 仓库);
- 提交信息中文,按阶段拆分提交(每阶段可独立回退)。
