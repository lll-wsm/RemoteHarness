import SwiftUI

/// 底部输入栏:多行输入;回复中显示停止按钮,否则显示发送按钮。
struct InputBar: View {
    @Binding var text: String
    let canSend: Bool
    let isResponding: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("输入消息…", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit {
                    if canSend, !isResponding { onSend() }
                }
            if isResponding {
                Button(action: onStop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("停止")
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(!canSend)
                .accessibilityLabel("发送")
            }
        }
        .padding()
    }
}
