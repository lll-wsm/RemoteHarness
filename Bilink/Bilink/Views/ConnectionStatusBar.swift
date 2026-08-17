import SwiftUI

/// 顶部状态条:绿点=已连接,橙点=重连中,红点=断开/失败;detail 显示排队状态或地址。
struct ConnectionStatusBar: View {
    let state: ConnectionState
    let detail: String

    private var color: Color {
        switch state {
        case .connected: return .green
        case .reconnecting, .connecting: return .orange
        default: return .red
        }
    }

    private var label: String {
        switch state {
        case .connected: return "已连接"
        case .reconnecting: return "重连中"
        case .connecting: return "连接中"
        default: return "未连接"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
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
