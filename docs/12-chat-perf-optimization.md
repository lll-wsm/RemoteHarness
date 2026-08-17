# 12 聊天性能优化实施方案(流式降级 + 智能滚动)

> 2026-08-17。本文是 docs/11 中 M2 两项的**细化设计**:§3.4 方案 B(流式降级)与 §4(智能滚动),另记录已完成的布局调整。
> 目标:消灭流式期间的两大卡顿/干扰源——① 每 chunk 全量重解析 Markdown;② 无条件钉底滚动打断上滑回看。

## 0. 现状与问题(代码位置)

| 问题 | 位置 | 影响 |
|---|---|---|
| 流式每 chunk 重建 `ChatMarkdownRenderSnapshot`(全量解析整条文本) | `MessageBubble.swift` 助手分支 | 长回复呈 O(n²) 解析,尾段掉帧 |
| `onChange(of: last.text)` 无条件 `scrollToLast`(带动画) | `ChatView.swift` `MessageList` | 用户上滑回看被不断拉回底部 |
| 消息列/输入栏 `maxWidth: 720` 居中 | `ChatView.swift`(已修复) | iPad 上整列悬浮屏幕中间 |

## 1. 布局调整(已完成)

- 移除 `MessageList` 与 `InputBar` 的 `.frame(maxWidth: 720)`,改为 `maxWidth: .infinity`;气泡左右内边距 12pt(贴屏幕边)。
- 涉及:`ChatView.swift`;构建已通过;真机观感待确认。
- 注意:超长行在宽屏可读性下降,若观感不佳可改回限宽(如 1000)或等 iPad 双栏(P1-2)再定。

---

## 2. 流式降级(方案 B 细化)

### 2.1 方案

`MessageBubble.swift` 助手分支由「始终 Markdown 渲染」改为按流式状态切换:

```swift
} else {
    VStack(alignment: .leading, spacing: 4) {
        if message.isStreaming {
            // 流式:纯文本 + 光标(零解析开销;光标回到文本尾,纯文本无解析风险)
            Text(message.text + "▌")
                .textSelection(.enabled)
        } else {
            // 完成:一次性 Markdown 渲染
            ChatMarkdownRenderer(
                text: message.text,
                context: .assistant,
                variant: .compact,
                theme: .default,
                isComplete: true)
        }
    }
    .padding(10)
    .background(Color(.secondarySystemBackground))
    .foregroundStyle(.primary)
    .clipShape(RoundedRectangle(cornerRadius: 14))
}
```

切换时机完全由 `ChatStore` 的 `isStreaming` 驱动(`finalizeTurn()` 置 false),`MessageBubble` 不引入新状态。

### 2.2 收益

- 流式期间 **0 次** Markdown 解析;完成时整条只解析 **1 次**(O(n),毫秒级);
- 流式中不完整代码围栏/表格的闪烁消失(纯文本无分块器参与);
- 历史回放消息(`isStreaming == false`)直接完整渲染,路径不变。

### 2.3 边界与取舍

- 纯文本 → 排版在完成瞬间切换,会有一次视觉跳变——主流做法(ChatGPT/Claude 均如此),接受;
- 完成瞬间对超大消息的 1 次解析若造成可感知停顿(>100ms),可叠加 docs/11 §3.4 方案 A+(snapshot 缓存),实现顺序:先降级,实测后再定;
- 空文本/纯空白:纯文本分支直接显示光标,无崩溃;
- 思考块 `ThoughtBlockView` 不受影响(仍是完成态折叠)。

### 2.4 涉及文件

- `Bilink/Bilink/Views/MessageBubble.swift`

### 2.5 验收标准

- 长回复流式全程滑动不掉帧(目测 + Time Profiler 对比:解析调用次数从「每 chunk 一次」降为「完成时一次」);
- 代码块/表格在流式结束时一次性渲染,无中间闪烁;
- 历史回放、会话切换、思考块折叠回归正常。

---

## 3. 智能滚动(M2 §4 细化)

### 3.1 状态机

```
isPinned: Bool       // 是否钉在底部;初始 true(默认跟随)
hasNewBelow: Bool    // 离底期间有新内容,提示「回到最新」
```

- `isPinned` 由滚动几何实时计算,不手动置位;
- `hasNewBelow` 只在「流式新 chunk 到达且当前未钉底」时置位(见 3.2 触发点)。

### 3.2 实现(iOS 18 `onScrollGeometryChange`)

`MessageList` 的 ScrollView 挂:

```swift
.onScrollGeometryChange(for: ScrollGeometry.self) { $0 } { _, new in
    // 距底 = 内容高 - (偏移 + 视口高);≤120pt 视为钉底
    let distanceToBottom = new.contentSize.height
        - new.contentOffset.y - new.containerSize.height
    isPinned = distanceToBottom <= 120
}
```

自动滚动收窄:

```swift
.onChange(of: chatStore.messages.last?.text) { _, _ in
    guard chatStore.messages.last?.isStreaming == true else { return }
    if isPinned {
        scrollToLast(proxy)          // 钉底:正常跟随
    } else {
        hasNewBelow = true           // 离底:不拉扯,只提示
    }
}
.onChange(of: chatStore.messages.count) { _, _ in
    if isPinned { scrollToLast(proxy) }
}
```

「回到最新」悬浮按钮(overlay,底部居中):

```swift
.overlay(alignment: .bottom) {
    if hasNewBelow {
        Button { scrollToLast(proxy); hasNewBelow = false } label: {
            Label("回到最新", systemImage: "arrow.down")
                .font(.footnote)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
        }
        .overlay(alignment: .topTrailing) { 红点提示 }
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
```

### 3.3 关键细节

- **滚动防抖**:`scrollToLast` 保持 `withAnimation(.easeOut(0.15))` 但仅在钉底时执行;高频 chunk 下动画重入 SwiftUI 会自行合并,若仍抖动,改为钉底时用 `proxy.scrollTo(..., anchor: .bottom)` 无动画、只有「回到最新」点击才带动画;
- **键盘弹出**:键盘改变视口 → 距底变化,可能短暂把 `isPinned` 置 false;`hasNewBelow` 只在消息变化时置位,键盘不会触发提示,恢复跟随无副作用——无需额外处理;
- **初始定位**:进会话/切会话后仍走一次 `scrollToLast`(消息变化时 `isPinned=true` 即跟随),回放期间不滚动(现有 `isReplayingHistory` 分支保留)。

### 3.4 涉及文件

- `Bilink/Bilink/Views/ChatView.swift`(MessageList 重构,新增两个 `@State` + geometry + overlay)

### 3.5 验收标准

- 流式中上滑到历史:消息继续流式但不跳动,底部出现「回到最新」+ 红点;
- 点按钮:立即回底并恢复跟随,红点消失;
- 回底后新 chunk 正常滚动(无抖动);
- 键盘弹收不触发「回到最新」提示、不打断跟随;
- 历史回放 / 会话切换 / 断线重连回归正常。

---

## 4. 实现顺序与提交

| 步骤 | 内容 | 提交 |
|---|---|---|
| 1 | 布局:移除 720 限宽(已完成) | 待提交 |
| 2 | 流式降级(§2) | 独立提交,可独立回退 |
| 3 | 智能滚动(§3) | 独立提交,可独立回退 |

每步:构建(模拟器)→ 手动验收(§2.5 / §3.5)→ 提交(中文 message)。

## 5. 后续待定(未批准,不实施)

- **历史加载方案 A(渲染窗口)**:docs/11 §4 讨论过,用户暂未选择;数据量上来(单会话数千条)再评估;
- **方案 A+ snapshot 缓存**:仅在流式降级后仍卡顿时启用;
- **iPad 双栏(P1-2)**:与布局观感相关,独立迭代。
