// Bilink 客户端验证(与 App 使用相同的 ACPClient / ChatStore):
//   bilink-acp-test connect <ws://url> <token>   — 鉴权门:initialize 握手/错误分类
//   bilink-acp-test chat    <ws://url> <token>   — 聊天:建会话 → 发消息 → 流式组装
import Foundation

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "connect"
let url = args.count > 2 ? args[2] : "ws://127.0.0.1:8777"
let token = args.count > 3 ? args[3] : "test-token"

func fail(_ error: Error) -> Never {
    if let acp = error as? ACPError {
        print("❌ \(acp.errorDescription ?? String(describing: acp))")
    } else {
        print("❌ \(error)")
    }
    exit(1)
}

Task {
    let client = ACPClient()
    do {
        try await client.start(url: url, token: token, timeout: 5)
    } catch {
        fail(error)
    }

    if mode == "chat" {
        let chat = ChatStore(client: client, connectionURL: "cli-test://local")
        // 等会话就绪(session/new 或 session/load 完成)
        for _ in 0..<50 where !chat.isSessionReady {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        print("会话: chatID=\(chat.chatID ?? "无") isSessionReady=\(chat.isSessionReady)")
        if let error = chat.errorMessage { print("⚠️ 会话错误: \(error)") }

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
        if chat.messages.contains(where: { $0.role == .assistant && !$0.text.isEmpty }) {
            print("✅ 聊天链路验证通过")
            exit(0)
        } else {
            print("❌ 未收到助手回复")
            exit(1)
        }
    } else {
        print("✅ 握手成功 isReady=\(client.isReady) connected=\(client.connectionInfo ?? "")")
        exit(0)
    }
}

RunLoop.main.run()
