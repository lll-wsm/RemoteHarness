import SwiftUI

/// 连接页(鉴权门):输入 URL + token → 连接 → initialize 握手。
/// 失败(401/超时/无法连接)留在本页并显示具体错误;成功由 RootView 切到聊天页。
struct ConnectView: View {
    @Bindable var store: ConnectionStore
    @State private var name = "我的远程机器"
    @State private var url = ""
    @State private var token = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("远程连接") {
                    TextField("连接名(可选)", text: $name)
                    TextField("地址", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .placeholder(when: url.isEmpty) {
                            Text("wss://xxx.trycloudflare.com 或 ws://192.168.x.x:8777")
                        }
                    SecureField("token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Text("远程 agent")
                        Spacer()
                        Text("grok(默认)")
                            .foregroundStyle(.secondary)
                    }
                }

                if case .failed(let error) = store.state {
                    Section {
                        Label(error.errorDescription ?? "未知错误",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await store.connect(ConnectionConfig(name: name, url: url, token: token)) }
                    } label: {
                        if store.state == .connecting {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                        } else {
                            Text("连接").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(store.state == .connecting || url.isEmpty || token.isEmpty)
                } footer: {
                    Text("连接将先完成 ACP 握手(initialize),验证通过后才可进行操作。")
                }
            }
            .navigationTitle("Bilink 连接")
        }
    }
}

extension View {
    func placeholder<Content: View>(when show: Bool,
                                    @ViewBuilder placeholder: () -> Content) -> some View {
        overlay(alignment: .leading) {
            if show {
                placeholder().foregroundStyle(.tertiary).padding(.leading, 4)
            }
        }
    }
}
