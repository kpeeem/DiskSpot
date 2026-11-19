import Foundation

enum MCPInfo {
    static let serverName = "diskspotmcp"
    static let version = "1.0"
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
}

struct ToolFailure: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }

    var errorDescription: String? { message }
}

func logToStderr(_ message: String) {
    let line = "[diskspotmcp] " + message + "\n"
    FileHandle.standardError.write(Data(line.utf8))
}

struct Params {
    let raw: [String: Any]

    init(_ raw: [String: Any]) { self.raw = raw }

    private func present(_ key: String) -> Any? {
        guard let value = raw[key], !(value is NSNull) else { return nil }
        return value
    }

    func string(_ key: String) -> String? {
        guard let value = present(key) else { return nil }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = string(key) else { throw ToolFailure("\(key) is required") }
        return value
    }

    func number(_ key: String) throws -> Double? {
        guard let value = present(key) else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String, let parsed = Double(text) { return parsed }
        throw ToolFailure("\(key) must be a number")
    }

    func integer(_ key: String) throws -> Int? {
        guard let value = try number(key) else { return nil }
        return Int(value)
    }

    func seconds(_ key: String, fallback: Double, limit: Double) throws -> Double {
        guard let value = try number(key) else { return fallback }
        guard value > 0 else { throw ToolFailure("\(key) must be greater than zero") }
        return min(value, limit)
    }

    func count(_ key: String, fallback: Int, limit: Int) throws -> Int {
        guard let value = try integer(key) else { return fallback }
        guard value > 0 else { throw ToolFailure("\(key) must be greater than zero") }
        return min(value, limit)
    }

    func flag(_ key: String, fallback: Bool) throws -> Bool {
        guard let value = present(key) else { return fallback }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            switch text.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: throw ToolFailure("\(key) must be true or false")
            }
        }
        throw ToolFailure("\(key) must be true or false")
    }

    func list(_ key: String) -> [String] {
        guard let value = present(key) else { return [] }
        if let array = value as? [Any] {
            return array.compactMap { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue }
        }
        if let text = value as? String {
            return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return []
    }

    func choice(_ key: String, options: [String], fallback: String) throws -> String {
        guard let value = string(key)?.lowercased() else { return fallback }
        guard options.contains(value) else {
            throw ToolFailure("\(key) must be one of " + options.joined(separator: ", "))
        }
        return value
    }
}

enum Schema {
    static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    static func text(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    static func number(_ description: String) -> [String: Any] {
        ["type": "number", "description": description]
    }

    static func integer(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description]
    }

    static func boolean(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    static func choice(_ description: String, _ values: [String]) -> [String: Any] {
        ["type": "string", "description": description, "enum": values]
    }

    static func size(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }
}

final class StdioTransport {
    var onMessage: (([String: Any]) -> Void)?
    var onClose: (() -> Void)?

    private let writeLock = NSLock()
    private var buffer = Data()

    func run() {
        let input = FileHandle.standardInput
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                deliver(line)
            }
        }
        onClose?()
    }

    private func deliver(_ line: Data) {
        guard !line.isEmpty else { return }
        guard let parsed = try? JSONSerialization.jsonObject(with: line), let message = parsed as? [String: Any] else {
            logToStderr("ignored a line that is not a JSON-RPC object")
            return
        }
        onMessage?(message)
    }

    func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            logToStderr("could not serialize a response")
            return
        }
        data.append(0x0a)
        writeLock.lock()
        defer { writeLock.unlock() }
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}
