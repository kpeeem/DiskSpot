import Foundation

struct Tool {
    let name: String
    let description: String
    let schema: [String: Any]
    let run: (Params, @escaping (Result<Any, Error>) -> Void) -> Void
}

enum JSONSafe {
    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    static func clean(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.mapValues { clean($0) }
        case let array as [Any]:
            return array.map { clean($0) }
        case let date as Date:
            return isoFormatter.string(from: date)
        case let string as String:
            return string
        case let number as NSNumber:
            return number.doubleValue.isFinite ? number : NSNull()
        case is NSNull:
            return value
        default:
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                guard let inner = mirror.children.first?.value else { return NSNull() }
                return clean(inner)
            }
            return String(describing: value)
        }
    }
}

final class MCPServer {
    private let transport = StdioTransport()
    private let tools: [Tool]
    private let index: [String: Tool]
    private let queue: DispatchQueue
    private let instructions: String

    init(tools: [Tool], queue: DispatchQueue, instructions: String) {
        self.tools = tools
        self.index = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        self.queue = queue
        self.instructions = instructions
    }

    func run() {
        transport.onMessage = { [weak self] message in
            guard let self = self else { return }
            self.queue.async { self.handle(message) }
        }
        transport.onClose = { exit(0) }
        transport.run()
    }

    private func handle(_ message: [String: Any]) {
        let id = message["id"]
        guard let method = message["method"] as? String else { return }
        switch method {
        case "initialize":
            let requested = (message["params"] as? [String: Any])?["protocolVersion"] as? String ?? ""
            let version = MCPInfo.supportedProtocolVersions.contains(requested) ? requested : MCPInfo.supportedProtocolVersions[0]
            reply(id, [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": MCPInfo.serverName, "version": MCPInfo.version],
                "instructions": instructions,
            ])
        case "ping":
            reply(id, [String: Any]())
        case "tools/list":
            reply(id, ["tools": tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema] }])
        case "tools/call":
            call(message, id: id)
        case "resources/list":
            reply(id, ["resources": [Any]()])
        case "prompts/list":
            reply(id, ["prompts": [Any]()])
        default:
            if method.hasPrefix("notifications/") { return }
            guard id != nil else { return }
            fail(id, code: -32601, message: "Unknown method \(method)")
        }
    }

    private func call(_ message: [String: Any], id: Any?) {
        guard let params = message["params"] as? [String: Any], let name = params["name"] as? String else {
            fail(id, code: -32602, message: "tools/call needs a tool name")
            return
        }
        guard let tool = index[name] else {
            fail(id, code: -32602, message: "Unknown tool \(name)")
            return
        }
        let arguments = params["arguments"] as? [String: Any] ?? [String: Any]()
        tool.run(Params(arguments)) { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                switch result {
                case .success(let payload):
                    self.replyContent(id, payload: payload, isError: false)
                case .failure(let error):
                    self.replyContent(id, payload: ["error": error.localizedDescription], isError: true)
                }
            }
        }
    }

    private func replyContent(_ id: Any?, payload: Any, isError: Bool) {
        let text: String
        if let data = try? JSONSerialization.data(withJSONObject: JSONSafe.clean(payload), options: [.sortedKeys, .withoutEscapingSlashes]) {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = "{\"error\":\"the result could not be serialized\"}"
        }
        reply(id, ["content": [["type": "text", "text": text]], "isError": isError])
    }

    private func reply(_ id: Any?, _ result: [String: Any]) {
        guard let id = id else { return }
        transport.send(["jsonrpc": "2.0", "id": id, "result": JSONSafe.clean(result)])
    }

    private func fail(_ id: Any?, code: Int, message: String) {
        guard let id = id else { return }
        transport.send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }
}
