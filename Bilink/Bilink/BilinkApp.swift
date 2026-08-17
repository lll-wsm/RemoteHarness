import SwiftUI

@main
struct BilinkApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// 根视图:未连接时展示机器列表(profile 主页),连接成功后进入聊天页。
struct RootView: View {
    @State private var store = ConnectionStore()
    @State private var sessionStore = SessionStore()
    @State private var profileStore = ProfileStore()

    var body: some View {
        Group {
            if store.isActive, let config = store.config {
                ChatView(store: store, config: config, sessionStore: sessionStore)
            } else {
                ProfileListView(store: store, profileStore: profileStore,
                                sessionStore: sessionStore)
            }
        }
    }
}