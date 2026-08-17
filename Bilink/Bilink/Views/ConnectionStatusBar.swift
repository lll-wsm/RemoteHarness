import SwiftUI

/// 顶部状态条:绿点=已连接,红点=断开/失败;detail 显示排队状态或地址。
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
