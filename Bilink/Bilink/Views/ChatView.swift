import SwiftUI

/// 聊天页主界面。M2.1 为占位:展示连接状态与断开入口;
/// M2.2 填充消息气泡与流式渲染。
struct ChatView: View {
    @Bindable var store: ConnectionStore
    let config: ConnectionConfig

    var body: some View {
        VStack(spacing: 0) {
            ConnectionStatusBar(isConnected: store.state == .connected, detail: config.url)
            Divider()
            Spacer()
            ContentUnavailableView(
                "已连接",
                systemImage: "checkmark.circle",
                description: Text("聊天功能开发中(M2.2)\n远程 agent: \(config.agent)")
            )
            Spacer()
            HStack {
                TextField("输入消息…", text: .constant(""))
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
                Button("发送") {}
                    .disabled(true)
            }
            .padding()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("断开") { store.disconnect() }
            }
        }
    }
}

/// 顶部连接状态条:绿点=已连接;红点=断开/失败。
struct ConnectionStatusBar: View {
    let isConnected: Bool
    let detail: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(isConnected ? "已连接" : "未连接")
                .font(.footnote)
                .fontWeight(.medium)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
