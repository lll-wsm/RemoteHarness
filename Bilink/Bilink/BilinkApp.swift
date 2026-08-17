import SwiftUI

@main
struct BilinkApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// 根视图:按连接状态在「连接页(鉴权门)」与「聊天页」之间切换。
struct RootView: View {
    @State private var store = ConnectionStore()
    @State private var sessionStore = SessionStore()

    var body: some View {
        Group {
            if store.isActive, let config = store.config {
                ChatView(store: store, config: config, sessionStore: sessionStore)
            } else {
                ConnectView(store: store)
            }
        }
    }
}
