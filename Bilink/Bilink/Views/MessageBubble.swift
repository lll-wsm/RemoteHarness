import SwiftUI
import SwiftUIChatMarkdown

/// 消息气泡:用户右侧主色(纯文本),助手左侧卡片(Markdown 渲染);流式期间渲染器下方显示光标。
/// Markdown 渲染只用于助手消息:用户消息背景为 accent 主色 + 白字,块级元素视觉冲突大,保持纯文本。
struct MessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom) {
            if isUser { Spacer(minLength: 64) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if !isUser, !message.thought.isEmpty {
                    ThoughtBlockView(text: message.thought)
                }
                bubbleContent
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = message.text
                        } label: {
                            Label("复制全文", systemImage: "doc.on.doc")
                        }
                    }
            }
            if !isUser { Spacer(minLength: 64) }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if isUser {
            Text(message.text)
                .textSelection(.enabled)
                .padding(10)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        } else {
            VStack(alignment: .leading, spacing: 4) {
                // 流式:isComplete=false 让分块器对不完整围栏/列表降级渲染;
                // 光标单独放在渲染器下方,避免插入文本破坏 Markdown 解析。
                ChatMarkdownRenderer(
                    text: message.text,
                    context: .assistant,
                    variant: .compact,
                    theme: .default,
                    isComplete: !message.isStreaming
                )
                if message.isStreaming {
                    Text("▌")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .foregroundStyle(.primary)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

/// 思考过程折叠块:流式期间由 ChatStore 追加,完成后默认收起。
struct ThoughtBlockView: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text(isExpanded ? "思考过程" : "思考中…(点开查看)")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if isExpanded {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
