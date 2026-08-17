// Bilink 客户端验证(与 App 使用相同的 ACPClient / ChatStore / SessionStore / ProfileStore):
//   bilink-acp-test connect <ws://url> <token>                    — 鉴权门:initialize 握手/错误分类
//   bilink-acp-test chat    <ws://url> <token> <profile名>         — 聊天:建/恢复会话 → 流式回复;验证目录与重开恢复
//   bilink-acp-test chat    <ws://url> <token> <profile名> --recover — 模拟重装:清本地索引,验证桥上远端发现恢复
//   bilink-acp-test delete  <ws://url> <token> <chatID>           — 在线删除:桥 + 本地同步清理
import Foundation

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "connect"
let url = args.count > 2 ? args[2] : "ws://127.0.0.1:8777"
let token = args.count > 3 ? args[3] : "test-token"
let profileArg = args.count > 4 ? args[4] : "CLI 测试机"
let recoverFlag = args.contains("--recover")
// 应用层加密密钥(与桥 BRIDGE_ENCRYPT_KEY 一致):--key <值>
let encryptionKey: String? = {
    if let i = args.firstIndex(of: "--key"), args.count > i + 1 {
        return args[i + 1]
    }
    return nil
}()

func fail(_ error: Error) -> Never {
    if let acp = error as? ACPError {
        print("❌ \(acp.errorDescription ?? String(describing: acp))")
    } else {
        print("❌ \(error)")
    }
    exit(1)
}

func failMessage(_ message: String) -> Never {
    print("❌ \(message)")
    exit(1)
}

/// 清空本地会话索引与消息文件(模拟 App 重装/换设备;profile 与桥注册表保留)。
func wipeLocalIndex() {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BilinkSessions", isDirectory: true)
    let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    for name in contents where name.hasSuffix(".json") {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }
}

func printCatalog(_ sessionStore: SessionStore, _ profile: ConnectionProfile) {
    let list = sessionStore.sessions(for: profile.id)
    print("会话目录: \(list.count) 个")
    for meta in list {
        let tag = meta.isRemoteOnly ? " [远端]" : ""
        print("  ・\(meta.title)\(tag) | \(meta.messageCount) 条 | \(meta.preview ?? "-")")
    }
}

Task {
    // delete 模式不依赖 profile/会话
    if mode == "delete" {
        let sessionStore = SessionStore()
        let profile = ProfileStore().add(name: "临时", url: url, token: token)
        let client = ACPClient()
        do {
            try await client.start(url: url, token: token, timeout: 5, encryptionKey: encryptionKey)
        } catch {
            fail(error)
        }
        let chat = ChatStore(client: client, profileID: profile.id, sessionStore: sessionStore)
        await chat.deleteSession(chatID: profileArg)
        if let error = chat.errorMessage {
            failMessage(error)
        }
        let result = try await client.send("sessions/list", params: .acp([:]))
        let ids = result?.objectValue?["sessions"]?.arrayValue?
            .compactMap { $0.objectValue?["chatID"]?.stringValue } ?? []
        if ids.contains(profileArg) {
            failMessage("桥注册表仍包含该会话")
        }
        if sessionStore.meta(chatID: profileArg) != nil {
            failMessage("本地目录仍包含该会话")
        }
        print("✅ 删除成功:桥注册表与本地目录均已清理")
        exit(0)
    }

    // connect 模式:纯握手验证,不触碰 profile/会话存储
    if mode == "connect" {
        let client = ACPClient()
        do {
            try await client.start(url: url, token: token, timeout: 5, encryptionKey: encryptionKey)
        } catch {
            fail(error)
        }
        print("✅ 握手成功 isReady=\(client.isReady) connected=\(client.connectionInfo ?? "")")
        exit(0)
    }

    if recoverFlag {
        print("模拟重装:清空本地会话索引(--recover)")
        wipeLocalIndex() // 必须在读入内存目录之前:重装=新进程,内存应为空
    }

    let profileStore = ProfileStore()
    let sessionStore = SessionStore()
    let isReopen = profileStore.profiles.contains { $0.name == profileArg }
    let profile: ConnectionProfile
    if let existing = profileStore.profiles.first(where: { $0.name == profileArg }) {
        profile = existing
    } else {
        profile = profileStore.add(name: profileArg, url: url, token: token)
    }
    let useToken = profileStore.token(for: profile.id) ?? token

    print("profile: \(profile.name) id=\(profile.id.uuidString.prefix(8)) 已有会话=\(sessionStore.sessions(for: profile.id).count)")

    let client = ACPClient()
    do {
        try await client.start(url: url, token: useToken, timeout: 5, encryptionKey: encryptionKey)
    } catch {
        fail(error)
    }

    let chat = ChatStore(client: client, profileID: profile.id, sessionStore: sessionStore)
    // 等会话就绪(本地恢复 / 远端发现 / session/new)
    for _ in 0..<60 where !chat.isSessionReady {
        try await Task.sleep(nanoseconds: 200_000_000)
    }
    let remoteEntry = sessionStore.latestRemoteOnly(for: profile.id)
    print("会话: chatID=\(chat.chatID ?? "无") isSessionReady=\(chat.isSessionReady) 远端发现=\(remoteEntry ?? "-")")
    if let error = chat.errorMessage {
        print("⚠️ 会话错误: \(error)")
    }

    if isReopen && !recoverFlag {
        if let latest = sessionStore.latest(for: profile.id), chat.chatID != latest {
            failMessage("重开未恢复最近会话: 当前=\(chat.chatID ?? "-") 期望=\(latest)")
        }
        print("✅ 重开恢复了最近会话(未新建)")
    }
    if recoverFlag, let remote = remoteEntry, chat.chatID != remote {
        failMessage("远端恢复路径异常: 当前=\(chat.chatID ?? "-") 应为远端条目=\(remote)")
    }
    if recoverFlag {
        print("✅ 重装后经桥上远端发现恢复(未盲目新建)")
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
    if isReopen && !recoverFlag && historyCount < 1 {
        failMessage("重开未恢复本地历史记录")
    }

    await chat.send("你好,只回复:OK")
    for _ in 0..<300 where chat.isResponding {
        try await Task.sleep(nanoseconds: 200_000_000)
    }
    print("回复结束: isResponding=\(chat.isResponding) 消息数=\(chat.messages.count)")
    for message in chat.messages {
        print("\(message.role == .user ? "👤 用户" : "🤖 助手"): \(message.text)")
    }
    if let error = chat.errorMessage {
        print("⚠️ 会话错误: \(error)")
    }
    if chat.messages.contains(where: { $0.role == .assistant && !$0.text.isEmpty }) {
        print("✅ 聊天链路验证通过")
    } else {
        failMessage("未收到助手回复")
    }
    // 远端条目首条消息后应翻转 isRemoteOnly
    if let remote = remoteEntry, sessionStore.meta(chatID: remote)?.isRemoteOnly == true {
        failMessage("远端条目未在首条消息后翻转 isRemoteOnly")
    }
    printCatalog(sessionStore, profile)
    exit(0)
}

RunLoop.main.run()