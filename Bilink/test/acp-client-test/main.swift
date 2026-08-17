// Bilink 客户端验证(与 App 使用相同的 ACPClient / ChatStore / SessionStore):
//   bilink-acp-test connect <ws://url> <token>   — 鉴权门:initialize 握手/错误分类
//   bilink-acp-test chat    <ws://url> <token>   — 聊天:恢复最近会话 → 发消息 → 流式组装;验证会话目录
// 第二次运行(检测到已有会话)时断言:重开恢复同一会话而非新建,且本地历史已还原。
import Foundation

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "connect"
let url = args.count > 2 ? args[2] : "ws://127.0.0.1:8777"
let token = args.count > 3 ? args[3] : "test-token"

let connectionKey = "cli-test://local"

func fail(_ error: Error) -> Never {
    if let acp = error as? ACPError {
        print("❌ \(acp.errorDescription ?? String(describing: acp))")
    } else {
        print("❌ \(error)")
    }
    exit(1)
}

func printCatalog(_ sessionStore: SessionStore) {
    let list = sessionStore.sessions(for: connectionKey)
    print("会话目录: \(list.count) 个会话")
    for meta in list {
        print("  ・\(meta.title) | \(meta.messageCount) 条 | \(meta.preview ?? "-")")
    }
}

Task {
    let sessionStore = SessionStore()
    let catalog = sessionStore.sessions(for: connectionKey)
    let isReopen = !catalog.isEmpty
    if isReopen {
        print("检测到已有会话 → 模拟 App 重开:应恢复最近会话而非新建")
        printCatalog(sessionStore)
    }

    let client = ACPClient()
    do {
        try await client.start(url: url, token: token, timeout: 5)
    } catch {
        fail(error)
    }

    if mode == "chat" {
        let chat = ChatStore(client: client, connectionURL: connectionKey, sessionStore: sessionStore)
        // 等会话就绪(session/new 或 session/load 完成)
        for _ in 0..<50 where !chat.isSessionReady {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        print("会话: chatID=\(chat.chatID ?? "无") isSessionReady=\(chat.isSessionReady)")
        if let error = chat.errorMessage {
            print("⚠️ 会话错误: \(error)")
            exit(1)
        }

        if isReopen {
            let latest = sessionStore.latest(for: connectionKey)
            if chat.chatID != latest {
                print("❌ 重开没有恢复最近会话:当前=\(chat.chatID ?? "-") 期望=\(latest ?? "-")")
                exit(1)
            }
            print("✅ 重开恢复了最近会话(未新建)")
        }

        // 等历史回放结束(load 路径)
        if chat.isReplayingHistory {
            print("历史回放中…")
            for _ in 0..<30 where chat.isReplayingHistory {
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        let historyCount = chat.messages.count
        print("恢复后消息数: \(historyCount)")
        for message in chat.messages {
            print("  历史 \(message.role == .user ? "👤" : "🤖"): \(message.text.prefix(40))")
        }
        if isReopen && historyCount < 1 {
            print("❌ 重开未恢复本地历史记录")
            exit(1)
        }

        await chat.send("你好,只回复:OK")
        // 等回复结束(通知流式组装中)
        for _ in 0..<300 where chat.isResponding {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        print("回复结束: isResponding=\(chat.isResponding) 消息数=\(chat.messages.count)")
        for message in chat.messages {
            let thought = message.thought.isEmpty ? "" : " [思考:\(message.thought.prefix(40))…]"
            print("\(message.role == .user ? "👤 用户" : "🤖 助手"): \(message.text)\(thought)")
        }
        if let error = chat.errorMessage {
            print("⚠️ 会话错误: \(error)")
        }
        if chat.messages.contains(where: { $0.role == .assistant && !$0.text.isEmpty }) {
            print("✅ 聊天链路验证通过")
        } else {
            print("❌ 未收到助手回复")
            exit(1)
        }
        printCatalog(sessionStore)
        exit(0)
    } else {
        print("✅ 握手成功 isReady=\(client.isReady) connected=\(client.connectionInfo ?? "")")
        exit(0)
    }
}

RunLoop.main.run()