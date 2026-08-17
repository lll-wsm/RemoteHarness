import SwiftUI

/// 消息气泡:用户右侧主色,助手左侧卡片;流式期间显示光标。
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
                Text(displayText)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(isUser ? Color.accentColor : Color(.secondarySystemBackground))
                    .foregroundStyle(isUser ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            if !isUser { Spacer(minLength: 64) }
        }
    }

    private var displayText: String {
        message.text + (message.isStreaming ? "▌" : "")
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
