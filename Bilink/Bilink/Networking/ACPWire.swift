import Foundation

/// 任意 JSON 值的 Codable 包装,用于 ACP 消息里不确定形状的字段。
enum AnyCodable: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AnyCodable])
    case array([AnyCodable])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([AnyCodable].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: AnyCodable].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法解码任意值")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }

    /// 便捷取值
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var objectValue: [String: AnyCodable]? { if case .object(let o) = self { return o }; return nil }
    var arrayValue: [AnyCodable]? { if case .array(let a) = self { return a }; return nil }
}

/// JSON-RPC 请求
struct RPCRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: [String: AnyCodable]?
}

/// JSON-RPC 响应(有 id)
struct RPCResponse: Decodable {
    let id: Int
    let result: AnyCodable?
    let error: RPCError?
}

/// JSON-RPC 错误对象
struct RPCError: Decodable {
    let code: Int
    let message: String
}

/// JSON-RPC 通知(无 id,method 为 session/update 或 _x.ai/* 系列)
struct RPCNotification: Decodable {
    let method: String
    let params: AnyCodable?
}

/// ACP 参数便捷构造
extension Dictionary where Key == String, Value == AnyCodable {
    static func acp(_ pairs: [String: Any]) -> [String: AnyCodable] {
        var out: [String: AnyCodable] = [:]
        for (k, v) in pairs {
            switch v {
            case let s as String: out[k] = .string(s)
            case let b as Bool: out[k] = .bool(b)
            case let n as Double: out[k] = .number(n)
            case let i as Int: out[k] = .number(Double(i))
            case let a as [Any]: out[k] = .array(a.map { anyToAnyCodable($0) })
            case let d as [String: Any]: out[k] = .object(Self.acp(d))
            case Optional<Any>.none: out[k] = .null
            default: out[k] = .string(String(describing: v))
            }
        }
        return out
    }

    private static func anyToAnyCodable(_ value: Any) -> AnyCodable {
        switch value {
        case let s as String: return .string(s)
        case let b as Bool: return .bool(b)
        case let n as Double: return .number(n)
        case let i as Int: return .number(Double(i))
        case let a as [Any]: return .array(a.map(anyToAnyCodable))
        case let d as [String: Any]: return .object(acp(d))
        default: return .string(String(describing: value))
        }
    }
}
