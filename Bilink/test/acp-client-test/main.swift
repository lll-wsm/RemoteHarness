// M2.1 鉴权门验证:用与 App 相同的 ACPClient 直连桥做握手测试。
// 用法:swift run 或 swiftc 编译后执行:
//   bilink-acp-test <ws://url> <token>
// 期待:正确 token → 握手成功;错误 token → 401(unauthorized)。
import Foundation

let url = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ws://127.0.0.1:8777"
let token = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "test-token"

let client = ACPClient()
Task {
    do {
        try await client.start(url: url, token: token, timeout: 5)
        print("✅ 握手成功 isReady=\(client.isReady) connected=\(client.connectionInfo ?? "")")
        exit(0)
    } catch let error as ACPError {
        print("❌ 握手失败: \(error.errorDescription ?? String(describing: error))")
        exit(error == .unauthorized ? 2 : 3)
    } catch {
        print("❌ 其他错误: \(error)")
        exit(1)
    }
}
RunLoop.main.run()
